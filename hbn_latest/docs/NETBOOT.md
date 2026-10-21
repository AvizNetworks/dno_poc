# DPU Netboot — install or live-boot the x86 host from its own BlueField-3

`netboot.sh` turns a BlueField-3 (DPU mode) into a DHCP / TFTP / HTTP boot server
for the x86 host it is plugged into. The host PXE-boots over the PCIe link to the DPU
(`pf0hpf` on the DPU, `enp*np0` on the host), downloads iPXE, and gets a menu:

| Menu item | What happens | Touches host disks? |
|---|---|---|
| `local` (default after 10 s) | iPXE exits, firmware continues to the next boot entry (local disk) | no |
| `live` | Ubuntu 24.04 live-server runs from RAM (ISO streamed from the DPU) | no |
| `install` | Unattended Ubuntu 24.04 install onto the **smallest** disk, then reboot | **yes** (smallest disk only) |
| `shell` | iPXE shell | no |

Nothing outside the DPU and the host is needed: no site DHCP server, no PXE
infrastructure, no controller. The DPU NATs the host-PF subnet out through its own
OOB port, so the live system and the installer have internet access.

Validated on an ASUS ESC4000A-E10 (AMI UEFI) with a BF3 B3220 on bf-bundle 3.4.x.

---

## 1. Prerequisites

**On the DPU (BlueField-3 ARM, Ubuntu bf-bundle):**

- DPU mode (not NIC mode) with the host-PF representor `pf0hpf` present.
- `pf0hpf` **not** attached to an OVS bridge. If HBN/SFC owns it the script refuses
  to run (it will not steal the port). Use `ovs-vsctl port-to-br pf0hpf` to check.
- Internet reachable from the DPU OOB port (`oob_net0`) for the one-time downloads:
  Ubuntu ISO (~3 GB), and `dnsmasq` / `ipxe` packages if not already installed.
  To work offline, pre-place the files (section 3) before running.
- ~4 GB free under `/srv`.
- `sudo`.

**On the host BIOS (one time):**

| Setting | Value | Why |
|---|---|---|
| Network Stack | Enabled | UEFI network boot drivers |
| IPv4 PXE Support | **Enabled** | classic PXE path (DHCP + TFTP) |
| IPv4 HTTP Support | Disabled (recommended) | many AMI firmwares only HTTP-boot from **https://** URLs and silently stall on plain http; PXE avoids that |
| IPv6 PXE / HTTP | Disabled | not used |
| CSM | Disabled | UEFI-only boot |
| Secure Boot | Disabled | iPXE `snponly.efi` is unsigned |

After a save + reset the firmware adds a boot entry named like
**`UEFI: PXE IP4 Nvidia Network Adapter - <host PF MAC>`**. Note its `BootXXXX` id.

**On the host BMC:** nothing is required, but having KVM or Serial-over-LAN access
is strongly recommended to watch the first boot.

---

## 2. Run it

Copy `netboot.sh` to the DPU and run it with sudo. It is idempotent; re-run it any
time to repair or change settings.

```bash
scp netboot.sh ubuntu@<dpu-oob-ip>:
ssh ubuntu@<dpu-oob-ip>
sudo ./netboot.sh
```

What it does, in order (all automatic):

1. Installs `dnsmasq` if missing.
2. Reads the host PF MAC from the eswitch (`devlink port show`) for a fixed DHCP lease.
3. Creates `/srv/http` and `/srv/tftp`; fetches `snponly.efi` (iPXE) from the `ipxe`
   package or boot.ipxe.org; downloads the Ubuntu ISO; loop-mounts it to extract
   `vmlinuz` and `initrd`; writes `boot.ipxe` (the menu) and
   `autoinstall/user-data` (the unattended profile).
4. Installs three systemd units, enabled at boot:

| Unit | Role |
|---|---|
| `dpu-netboot-net` | `192.168.200.1/24` on `pf0hpf`, IP forwarding, MASQUERADE out of `oob_net0` |
| `dpu-netboot-dhcp` | dnsmasq: DHCP + TFTP on `pf0hpf` only (standalone config in `/etc/dpu-netboot/`, never touches `/etc/dnsmasq.conf`) |
| `dpu-netboot-http` | HTTP server on `192.168.200.1:80` serving `/srv/http` |

5. Self-check and a status dump.

Other commands:

```bash
sudo ./netboot.sh --status              # state, listeners, files, leases; changes nothing
sudo ./netboot.sh --remove              # stop + disable units, remove address/NAT (keeps /srv/http)
sudo ./netboot.sh --regen-autoinstall   # rewrite autoinstall/user-data from the NB_* / LAN_* variables
```

### Variables (set on the command line, all optional)

| Variable | Default | Meaning |
|---|---|---|
| `MENU_DEFAULT` | `local` | what the menu boots after the timeout: `local`, `live` or `install` |
| `MENU_TIMEOUT_MS` | `10000` | menu timeout |
| `NB_HOSTNAME` | `netboot-host` | hostname set by the unattended install |
| `NB_USER` | `admin` | login created by the unattended install (passwordless sudo) |
| `NB_PASSWORD` | `changeme` | its password, hashed on the DPU with `openssl passwd -6`. **Set this.** |
| `NB_PASSWORD_HASH` | | pre-made SHA-512 crypt hash; overrides `NB_PASSWORD` |
| `LAN_MAC` | | MAC of the host's management NIC. Empty = only the DPU link is configured after install |
| `LAN_IP` / `LAN_GW` | | with `LAN_MAC`: static address (`10.0.0.5/24`) and gateway. Without `LAN_IP`: DHCP on that NIC |
| `ISO_URL` | Ubuntu 24.04.3 live-server | any Ubuntu live-server ISO (casper layout) |
| `SUBNET` / `DPU_IP` / `HOST_IP` | `192.168.200.0/24` / `.1` / `.10` | host-PF link addressing; change if it collides with your network |
| `DNS_UPSTREAM` | `8.8.8.8` | DNS handed to the host |
| `REP_IF` / `UPLINK_IF` | `pf0hpf` / `oob_net0` | DPU interfaces |
| `HTTP_PORT` | `80` | keep 80: some firmware ignores non-default ports |

The autoinstall profile is written **once**; later runs keep your edits. To apply new
`NB_*` / `LAN_*` values use `--regen-autoinstall`, e.g.

```bash
sudo NB_HOSTNAME=node1 NB_PASSWORD='S3cret!' LAN_MAC=aa:bb:cc:dd:ee:ff \
     LAN_IP=10.0.0.5/24 LAN_GW=10.0.0.1 ./netboot.sh --regen-autoinstall
```

---

## 3. Files on the DPU

```
/srv/http/
  snponly.efi          iPXE for UEFI (also linked into /srv/tftp/ for classic PXE)
  boot.ipxe            the menu (regenerated on every run)
  vmlinuz, initrd      extracted from the ISO (casper/)
  ubuntu.iso           the live-server ISO, streamed to the host at boot
  autoinstall/
    user-data          unattended-install profile (cloud-config); edit freely
    meta-data          empty, required by the NoCloud datasource
/srv/tftp/snponly.efi  -> /srv/http/snponly.efi
/etc/dpu-netboot/dnsmasq.conf
/var/lib/dpu-netboot/dnsmasq.leases
```

Offline use: put `ubuntu.iso` (and optionally `snponly.efi`) in `/srv/http` before
the first run; the script skips the downloads when the files exist.

Boot flow the DPU serves (what you will see in `journalctl -fu dpu-netboot-dhcp`):

```
host firmware  DHCPDISCOVER  vendor class PXEClient:Arch:00007   -> offered snponly.efi over TFTP
host firmware  TFTP          snponly.efi  ("error 8 User aborted" first = size probe, normal)
iPXE           DHCPDISCOVER  option 175 (tag ipxe)               -> bootfile http://192.168.200.1/boot.ipxe
iPXE           HTTP GET      /boot.ipxe, then /vmlinuz, /initrd  (live / install)
initramfs      DHCP          again, then HTTP GET /ubuntu.iso
installer      DHCP          again; with "install": GET /autoinstall/user-data, meta-data
```

---

## 4. Boot the host from the DPU

The DPU entry must be the one selected; a plain "boot from network" picks the
**first** PXE-capable NIC in the boot order, which is usually an onboard NIC that will
talk to whatever DHCP/PXE server lives on your LAN instead.

**Host has an OS (one-time boot from the DPU):**

```bash
sudo efibootmgr -v | grep -i nvidia        # find the id, e.g. Boot0008* UEFI: PXE IP4 Nvidia Network Adapter - ...
sudo efibootmgr -n 0008                    # BootNext (one boot only)
sudo reboot
```

**Host has no OS:** open the BIOS boot menu from the BMC KVM (F8 / F11 depending
on vendor) and pick the Nvidia PXE entry, or put it first in the BIOS boot order.

**Make it permanent (DPU first, then local disk):**

```bash
sudo efibootmgr -o 0008,0001               # ids from efibootmgr -v
```

With the DPU entry first and `MENU_DEFAULT=local`, every boot pauses 10 s at the
menu and then continues to the local disk, so you can re-image a host at any time
from the DPU without touching BIOS again.

**Remote reset via the BMC (IPMI):**

```bash
ipmitool -I lanplus -H <bmc-ip> -U <user> -P <pass> chassis power status
ipmitool -I lanplus -H <bmc-ip> -U <user> -P <pass> chassis power reset      # warm: DPU stays up (good)
ipmitool -I lanplus -H <bmc-ip> -U <user> -P <pass> sol activate             # serial console (exit: ~.)
```

Use `power reset`, not `power cycle`: a cold cycle also reboots the DPU and the
host's PXE request races the DPU coming back.

If the host boots into the wrong installer or you need to get back to the local
disk at once: `chassis bootdev disk options=efiboot` then `chassis power reset`.

---

## 5. Procedures

### A. Live boot (nothing written)

1. `sudo ./netboot.sh --status` on the DPU: DHCP and HTTP listening, files present.
2. Boot the host from the DPU entry (section 4).
3. At the menu choose `live` (or run the DPU with `MENU_DEFAULT=live` beforehand).
4. Kernel, initrd and then the ISO stream over the link (a few minutes); the
   installer's language screen appears. Use it as a rescue/live system.

### B. Unattended install

1. On the DPU: `sudo NB_HOSTNAME=... NB_PASSWORD=... LAN_MAC=... ./netboot.sh --regen-autoinstall`
   and review `/srv/http/autoinstall/user-data`. **The smallest disk is wiped.**
2. Optionally `sudo MENU_DEFAULT=install ./netboot.sh` so no console interaction is needed.
3. Boot the host from the DPU entry.
4. No prompts: partitioning, package install, security updates (through the DPU NAT),
   reboot. 10 to 20 minutes depending on the link to the mirrors.
5. After the reboot the host has `NB_USER` with passwordless sudo, SSH enabled, the
   DPU link on `192.168.200.10` and the LAN NIC as configured.
6. **Set the DPU back** to `sudo MENU_DEFAULT=local ./netboot.sh`, otherwise every
   DPU-first boot reinstalls. Then fix the host boot order (section 4).

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `pf0hpf not found` | BF3 in NIC mode or host PF not up | DPU mode required; check `devlink port show` |
| `pf0hpf is attached to OVS bridge ...` | HBN/SFC owns the host-PF port | run on a DPU where the host PF is free, or detach it in your SFC config |
| `dnsmasq.service is masked` style errors | bf-bundle masks the system dnsmasq | not an issue: the script runs its own instance (`dpu-netboot-dhcp`) |
| Nothing in the DHCP log when the host boots | wrong boot entry selected, or Network Stack / IPv4 PXE disabled | section 1 BIOS table; `efibootmgr -n <nvidia id>` |
| DHCP completes with vendor class `HTTPClient` then silence | firmware HTTP boot refuses plain http:// | disable IPv4 HTTP, enable IPv4 PXE in BIOS |
| Host boots some other installer / "stalling" on a foreign IP | onboard NIC booted first and found a LAN PXE server | select the Nvidia entry explicitly (section 4) |
| Kernel panic `VFS: Unable to mount root fs on unknown-block(0,0)` | initrd not passed to the EFI stub | the menu already has `initrd=initrd`; if you edited `boot.ipxe`, keep it |
| `error 8 User aborted the transfer` in the TFTP log | firmware size probe before the real transfer | normal |
| ISO download very slow / installer stalls fetching | python `http.server` has no HTTP Range support | works, but for production serve `/srv/http` with nginx on the same address and disable `dpu-netboot-http` |
| BMC KVM drops during the boot | shared BMC/host NIC (NC-SI) resets with the host NIC | benign; use a dedicated BMC port or Serial-over-LAN |
| Installer asks questions instead of installing | `install` item not chosen, or `user-data` invalid | `MENU_DEFAULT=install`; validate the YAML; check `GET /autoinstall/user-data` in the HTTP log |
| Host has no LAN address after install | `LAN_MAC` not set | `--regen-autoinstall` with `LAN_MAC` (+ `LAN_IP`/`LAN_GW`) and reinstall, or configure netplan on the host |

Logs: `journalctl -fu dpu-netboot-dhcp`, `journalctl -fu dpu-netboot-http`,
`sudo ./netboot.sh --status`. Packet-level: `tcpdump -ni pf0hpf port 67 or port 69 or port 80`.

---

## 7. Security notes

- Change `NB_PASSWORD` (or edit the hash in `user-data`) before any real install.
- The DPU NATs `192.168.200.0/24` to its OOB network while the units run. Use
  `--remove` when the feature is not needed.
- `snponly.efi` is unsigned; Secure Boot must stay off for the DPU boot path.
- Everything is served over plain HTTP on the private host-PF link only
  (`bind-interfaces` on `pf0hpf`); nothing listens on the OOB side.
