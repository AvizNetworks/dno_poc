#!/usr/bin/env bash
# dpu_netboot_server.sh — turn a BF3 (DPU mode) into a PXE / HTTP boot server
# for its own x86 host, over the host-PF link (pf0hpf <-> host enp*np0).
#
# Validated 2026-10-21 (ASUS/AMI host + BF3 B3220): the host boots the "UEFI: PXE
# IP4 Nvidia Network Adapter" entry; the DPU answers DHCP on pf0hpf and serves
# iPXE over TFTP; iPXE fetches a menu over HTTP (default: continue to local disk)
# that can live-boot or unattended-install Ubuntu live-server straight from the
# DPU. The DPU NATs the host-PF subnet out through oob_net0. (UEFI HTTP boot is
# also answered, but AMI firmware only follows https:// URLs — prefer PXE.)
#
# Run ON THE BF3 with sudo. Idempotent — safe to re-run. Reversible with --remove.
#
#   sudo ./dpu_netboot_server.sh                 # set up (downloads ISO if missing)
#   sudo ./dpu_netboot_server.sh --status        # show state, no changes
#   sudo ./dpu_netboot_server.sh --remove        # tear down (keeps downloaded files)
#   sudo ./dpu_netboot_server.sh --regen-autoinstall   # rewrite autoinstall/user-data from the NB_* vars
#
# Unattended-install identity (menu item "install") — set on the command line, e.g.
#   sudo NB_HOSTNAME=node1 NB_USER=admin NB_PASSWORD='S3cret' LAN_MAC=aa:bb:cc:dd:ee:ff LAN_IP=10.0.0.5/24 LAN_GW=10.0.0.1 ./dpu_netboot_server.sh
#
# Then on the host: select the "UEFI: PXE IP4 Nvidia Network Adapter" boot entry
# (efibootmgr -n <id> && reboot, or BIOS boot menu). See README.
# Watch:  journalctl -fu dpu-netboot-dhcp   and   journalctl -fu dpu-netboot-http
set -euo pipefail

REP_IF="${REP_IF:-pf0hpf}"                 # host-PF representor on the DPU
UPLINK_IF="${UPLINK_IF:-oob_net0}"         # where NAT egresses
SUBNET="${SUBNET:-192.168.200.0/24}"
DPU_IP="${DPU_IP:-192.168.200.1}"
HOST_IP="${HOST_IP:-192.168.200.10}"       # fixed lease for the host PF
RANGE="${RANGE:-192.168.200.100,192.168.200.110,12h}"
HTTP_PORT="${HTTP_PORT:-80}"            # port 80: some AMI UEFI HTTP-boot stacks ignore non-default ports
HTTP_ROOT=/srv/http
TFTP_ROOT=/srv/tftp
ISO_URL="${ISO_URL:-https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-amd64.iso}"
ISO_NAME="${ISO_NAME:-ubuntu.iso}"
DNS_UPSTREAM="${DNS_UPSTREAM:-8.8.8.8}"
HOST_PF_MAC="${HOST_PF_MAC:-}"             # auto-detected from the rep if empty
MENU_DEFAULT="${MENU_DEFAULT:-local}"      # local | live | install  — what the iPXE menu boots after the timeout
MENU_TIMEOUT_MS="${MENU_TIMEOUT_MS:-10000}"
# unattended-install profile (only used by menu item "install"; written once, see --regen-autoinstall)
NB_HOSTNAME="${NB_HOSTNAME:-netboot-host}"
NB_USER="${NB_USER:-admin}"
NB_PASSWORD="${NB_PASSWORD:-changeme}"       # hashed with openssl passwd -6 at run time; NB_PASSWORD_HASH overrides
NB_PASSWORD_HASH="${NB_PASSWORD_HASH:-}"
LAN_MAC="${LAN_MAC:-}"                       # onboard/management NIC of the host (optional). Empty = only the DPU link is configured
LAN_IP="${LAN_IP:-}"                         # e.g. 10.0.0.5/24 -> static; empty with LAN_MAC set -> DHCP on that NIC
LAN_GW="${LAN_GW:-}"
REGEN_AUTOINSTALL=0

if [ "$HTTP_PORT" = 80 ]; then HTTP_BASE="http://$DPU_IP"; else HTTP_BASE="http://$DPU_IP:$HTTP_PORT"; fi
log(){ echo "[netboot] $*"; }
die(){ echo "[netboot] ERROR: $*" >&2; exit 1; }
case "${1:-}" in -h|--help) sed -n '2,24p' "$0" | sed "s/dpu_netboot_server\.sh/$(basename "$0")/g"; exit 0;; esac
[ "$(id -u)" = 0 ] || die "run with sudo"

# host PF MAC: the rep's phys port maps to the host PF; read it from the eswitch
detect_host_mac(){
  [ -n "$HOST_PF_MAC" ] && { echo "$HOST_PF_MAC"; return; }
  # On BF3 the host PF MAC is the base MAC of PF0 as seen by the host; devlink
  # exposes it as the "hw_addr" of the PF port function.
  # (the "function: hw_addr" line follows the port line, hence -A2)
  devlink port show 2>/dev/null | grep -A2 -E "netdev $REP_IF " | grep -oE 'hw_addr [0-9a-f:]+' | awk '{print $2}' | head -1
}

status(){
  echo "== rep $REP_IF:";      ip -br addr show "$REP_IF" 2>/dev/null || echo "  (missing)"
  echo "== nat:";              iptables -t nat -S POSTROUTING | grep -- "-s $SUBNET" || echo "  (none)"
  echo "== forward:";          sysctl -n net.ipv4.ip_forward
  echo "== dhcp:";             systemctl is-active dpu-netboot-dhcp 2>/dev/null || true; ss -lunp | grep -E ':67 ' || echo "  (no DHCP listener)"
  echo "== http:";             systemctl is-active dpu-netboot-http 2>/dev/null || true; ss -ltnp | grep -E ":$HTTP_PORT " || echo "  (no HTTP listener)"
  echo "== files:";            ls -la "$HTTP_ROOT" 2>/dev/null | grep -E 'ipxe|efi|vmlinuz|initrd|iso' || echo "  (none)"
  echo "== autoinstall:";      [ -s "$HTTP_ROOT/autoinstall/user-data" ] && grep -E '^\s+(hostname|username):' "$HTTP_ROOT/autoinstall/user-data" || echo "  (not written yet)"
  echo "== ovs owner of $REP_IF:"; ovs-vsctl port-to-br "$REP_IF" 2>/dev/null || echo "  (none — free)"
  echo "== leases:";           cat /var/lib/dpu-netboot/dnsmasq.leases 2>/dev/null || true
  echo "== host PF MAC:";      detect_host_mac || true
}

remove(){
  systemctl disable --now dpu-netboot-http dpu-netboot-dhcp dpu-netboot-net 2>/dev/null || true
  rm -f /etc/dpu-netboot/dnsmasq.conf /etc/systemd/system/dpu-netboot-http.service /etc/systemd/system/dpu-netboot-dhcp.service /etc/systemd/system/dpu-netboot-net.service
  iptables -t nat -D POSTROUTING -s "$SUBNET" -o "$UPLINK_IF" -j MASQUERADE 2>/dev/null || true
  ip addr del "$DPU_IP/24" dev "$REP_IF" 2>/dev/null || true
  systemctl daemon-reload
  log "removed (downloaded files in $HTTP_ROOT kept)"
}

case "${1:-}" in
  --status) status; exit 0;;
  --remove) remove; exit 0;;
  --regen-autoinstall) REGEN_AUTOINSTALL=1;;
  "") ;;
  *) die "usage: $0 [--status|--remove|--regen-autoinstall|--help]";;
esac

# ---------- preflight ----------
ip link show "$REP_IF" >/dev/null 2>&1 || die "$REP_IF not found — is the BF3 in DPU/switchdev mode?"
if ovs-vsctl port-to-br "$REP_IF" >/dev/null 2>&1; then
  die "$REP_IF is attached to OVS bridge $(ovs-vsctl port-to-br "$REP_IF") — HBN/SFC owns it; refusing to steal it"
fi
command -v dnsmasq >/dev/null || { log "installing dnsmasq"; apt-get install -y -qq dnsmasq; }
command -v python3 >/dev/null || die "python3 missing"
HOST_PF_MAC="$(detect_host_mac || true)"
[ -n "$HOST_PF_MAC" ] && log "host PF MAC: $HOST_PF_MAC" || log "host PF MAC not detected — fixed lease skipped (dynamic range still works)"

# ---------- 1. link address + NAT (persisted as a oneshot unit) ----------
cat >/etc/systemd/system/dpu-netboot-net.service <<EOF
[Unit]
Description=DPU netboot: address on $REP_IF + NAT via $UPLINK_IF
After=network-online.target sfc.service
Wants=network-online.target
Before=dpu-netboot-dhcp.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip link set $REP_IF up; ip addr replace $DPU_IP/24 dev $REP_IF; sysctl -qw net.ipv4.ip_forward=1; iptables -t nat -C POSTROUTING -s $SUBNET -o $UPLINK_IF -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s $SUBNET -o $UPLINK_IF -j MASQUERADE'
ExecStop=/bin/sh -c 'iptables -t nat -D POSTROUTING -s $SUBNET -o $UPLINK_IF -j MASQUERADE 2>/dev/null || true; ip addr del $DPU_IP/24 dev $REP_IF 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

# ---------- 2. boot payloads ----------
mkdir -p "$HTTP_ROOT" "$TFTP_ROOT"
if [ ! -s "$HTTP_ROOT/snponly.efi" ]; then
  if [ -s /usr/lib/ipxe/snponly.efi ]; then cp /usr/lib/ipxe/snponly.efi "$HTTP_ROOT/"
  elif apt-get install -y -qq ipxe >/dev/null 2>&1 && [ -s /usr/lib/ipxe/snponly.efi ]; then cp /usr/lib/ipxe/snponly.efi "$HTTP_ROOT/"
  else log "fetching snponly.efi from boot.ipxe.org"; curl -fsSL -o "$HTTP_ROOT/snponly.efi" https://boot.ipxe.org/snponly.efi; fi
fi
ln -sf "$HTTP_ROOT/snponly.efi" "$TFTP_ROOT/snponly.efi"

if [ ! -s "$HTTP_ROOT/$ISO_NAME" ]; then
  log "downloading $ISO_URL (~3 GB) — this takes a while"
  curl -fL --progress-bar -o "$HTTP_ROOT/$ISO_NAME.part" "$ISO_URL" && mv "$HTTP_ROOT/$ISO_NAME.part" "$HTTP_ROOT/$ISO_NAME"
fi
if [ ! -s "$HTTP_ROOT/vmlinuz" ] || [ ! -s "$HTTP_ROOT/initrd" ]; then
  log "extracting kernel/initrd from the ISO"
  mnt=$(mktemp -d); mount -o loop,ro "$HTTP_ROOT/$ISO_NAME" "$mnt"
  cp "$mnt/casper/vmlinuz" "$HTTP_ROOT/vmlinuz"; cp "$mnt/casper/initrd" "$HTTP_ROOT/initrd"
  umount "$mnt"; rmdir "$mnt"
fi

# iPXE menu: default = continue to local disk, so the BF3 entry can stay first in BIOS
cat >"$HTTP_ROOT/boot.ipxe" <<EOF
#!ipxe
set base $HTTP_BASE
:menu
menu DPU netboot ($DPU_IP) — host \${net0/mac}
item --gap --  Default in 10s: local disk
item local     Boot from local disk (exit to next BIOS boot option)
item live      Ubuntu 24.04 live-server from DPU (RAM, no install)
item install   Ubuntu 24.04 autoinstall from DPU (WIPES TARGET DISK)
item shell     iPXE shell
choose --default ${MENU_DEFAULT:-local} --timeout ${MENU_TIMEOUT_MS:-10000} target && goto \${target}

:local
exit

:live
kernel \${base}/vmlinuz initrd=initrd ip=dhcp url=\${base}/$ISO_NAME console=tty0
initrd \${base}/initrd
boot || goto menu

:install
kernel \${base}/vmlinuz initrd=initrd ip=dhcp url=\${base}/$ISO_NAME autoinstall ds=nocloud-net;s=\${base}/autoinstall/ console=tty0
initrd \${base}/initrd
boot || goto menu

:shell
shell
goto menu
EOF
mkdir -p "$HTTP_ROOT/autoinstall"; touch "$HTTP_ROOT/autoinstall/meta-data"
# Unattended install profile (menu item "install"). Written only if absent (or with --regen-autoinstall),
# so local edits survive re-runs. INSTALLS ONTO THE SMALLEST DISK ONLY (other disks untouched).
# Reference: https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html
grep -q PLACEHOLDER "$HTTP_ROOT/autoinstall/user-data" 2>/dev/null && rm -f "$HTTP_ROOT/autoinstall/user-data"  # drop the old stub
if [ "$REGEN_AUTOINSTALL" = 1 ] || [ ! -s "$HTTP_ROOT/autoinstall/user-data" ]; then
  if [ -z "$NB_PASSWORD_HASH" ]; then
    [ "$NB_PASSWORD" = changeme ] && log "WARNING: NB_PASSWORD not set — autoinstall login will be $NB_USER / changeme"
    NB_PASSWORD_HASH="$(openssl passwd -6 "$NB_PASSWORD")" || die "openssl passwd -6 failed (set NB_PASSWORD_HASH instead)"
  fi
  if [ -n "$LAN_MAC" ] && [ -n "$LAN_IP" ]; then
    lan_block="      lan:                         # host management NIC (static)
        match: {macaddress: \"$LAN_MAC\"}
        addresses: [$LAN_IP]
        routes: [{to: default, via: $LAN_GW, metric: 100}]
        nameservers: {addresses: [$DNS_UPSTREAM]}
        optional: true"
    [ -n "$LAN_GW" ] || die "LAN_IP set but LAN_GW empty"
  elif [ -n "$LAN_MAC" ]; then
    lan_block="      lan:                         # host management NIC (DHCP, preferred route)
        match: {macaddress: \"$LAN_MAC\"}
        dhcp4: true
        optional: true
        dhcp4-overrides: {route-metric: 100}"
  else
    lan_block="      # LAN_MAC not set: only the DPU link is configured; add the host's management NIC here"
  fi
  cat >"$HTTP_ROOT/autoinstall/user-data" <<USERDATA
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard: {layout: us}
  refresh-installer: {update: false}
  identity:
    hostname: $NB_HOSTNAME
    username: $NB_USER
    password: "$NB_PASSWORD_HASH"
  ssh:
    install-server: true
    allow-pw: true
  storage:
    layout:
      name: direct
      match: {size: smallest}      # the OS disk; large data disks are not touched
  network:
    version: 2
    ethernets:
      dpu-pf:                      # BlueField host PF (link to the DPU)
        match: {driver: mlx5_core}
        dhcp4: true
        optional: true
        dhcp4-overrides: {route-metric: 200}
$lan_block
  packages: [openssh-server, ipmitool, pciutils, ethtool, curl]
  late-commands:
    - echo '$NB_USER ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/90-$NB_USER
    - chmod 440 /target/etc/sudoers.d/90-$NB_USER
  shutdown: reboot
USERDATA
  log "autoinstall profile written: host=$NB_HOSTNAME user=$NB_USER lan=${LAN_MAC:-none}"
fi

# ---------- 3. dnsmasq: DHCP + UEFI HTTP boot + classic PXE/TFTP on the rep only ----------
# NOTE: bf-bundle masks the system dnsmasq.service, so we run our own instance
# from a standalone config under a dedicated unit (never touches /etc/dnsmasq.conf).
mkdir -p /etc/dpu-netboot /var/lib/dpu-netboot
cat >/etc/dpu-netboot/dnsmasq.conf <<EOF
# generated by dpu_netboot_server.sh
port=0
dhcp-leasefile=/var/lib/dpu-netboot/dnsmasq.leases
user=root
interface=$REP_IF
bind-interfaces
except-interface=lo
dhcp-range=$RANGE
dhcp-option=option:router,$DPU_IP
dhcp-option=option:dns-server,$DNS_UPSTREAM
$( [ -n "$HOST_PF_MAC" ] && echo "dhcp-host=$HOST_PF_MAC,$HOST_IP,host-pf" )
# iPXE clients (option 175) -> the menu script
dhcp-match=set:ipxe,175
dhcp-boot=tag:ipxe,$HTTP_BASE/boot.ipxe
# UEFI HTTP boot clients (vendor class HTTPClient) -> iPXE over HTTP; must echo option 60
dhcp-match=set:httpboot,option:vendor-class,HTTPClient
dhcp-option-force=tag:httpboot,60,HTTPClient
dhcp-boot=tag:httpboot,tag:!ipxe,$HTTP_BASE/snponly.efi
# classic UEFI PXE clients (arch 7/9) -> iPXE over TFTP (only used if IPv4 PXE is enabled in BIOS)
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-boot=tag:efi64,tag:!ipxe,tag:!httpboot,snponly.efi
enable-tftp
tftp-root=$TFTP_ROOT
log-dhcp
EOF
dnsmasq --test --conf-file=/etc/dpu-netboot/dnsmasq.conf >/dev/null
cat >/etc/systemd/system/dpu-netboot-dhcp.service <<EOF
[Unit]
Description=DPU netboot: dnsmasq (DHCP/HTTP-boot/TFTP) on $REP_IF
After=dpu-netboot-net.service
Requires=dpu-netboot-net.service

[Service]
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/dpu-netboot/dnsmasq.conf --pid-file=/run/dpu-netboot-dnsmasq.pid
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# ---------- 4. HTTP server ----------
cat >/etc/systemd/system/dpu-netboot-http.service <<EOF
[Unit]
Description=DPU netboot: HTTP server for boot payloads
After=dpu-netboot-net.service
Requires=dpu-netboot-net.service

[Service]
WorkingDirectory=$HTTP_ROOT
ExecStart=/usr/bin/python3 -m http.server $HTTP_PORT --bind $DPU_IP
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# enable + restart (not "enable --now": that leaves an already-running unit untouched)
systemctl enable dpu-netboot-net.service dpu-netboot-dhcp.service dpu-netboot-http.service >/dev/null
systemctl restart dpu-netboot-net.service
systemctl restart dpu-netboot-dhcp.service
systemctl restart dpu-netboot-http.service
sleep 1
log "self-check:"
curl -fsS -o /dev/null "$HTTP_BASE/boot.ipxe" && log "  HTTP OK (boot.ipxe served)"
ss -lunp | grep -q ':67 ' && log "  DHCP listening on $REP_IF"
status
log "DONE. Next, on the host: sudo efibootmgr -v | grep -i nvidia  ->  sudo efibootmgr -n <id> && sudo reboot"
log "   (BIOS: Network Stack on, IPv4 PXE enabled; with no host OS use the BIOS boot menu or the BMC KVM)"
log "Then: journalctl -fu dpu-netboot-dhcp   (expect DHCPDISCOVER from the host PF, vendor class PXEClient then iPXE)"
