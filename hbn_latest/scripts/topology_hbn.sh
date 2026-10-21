#!/usr/bin/env bash
# topology_hbn.sh — Show HBN interface reference for teams configuring FRR/NVUE
# Run on BF3 with sudo: sudo ./topology_hbn.sh [--host-ip <IP>]
# Output is shown live AND saved to /var/log/doca/hbn/topology-<timestamp>.txt
set -euo pipefail

LOG_DIR="/var/log/doca/hbn"
SFC_CONF="/etc/mellanox/sfc.conf"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_FILE="$LOG_DIR/topology-${TIMESTAMP}.txt"

HOST_IP=""
HOST_USER="admin"
HOST_PASS=""      # required with --host-ip (pass via --host-pass; never hardcode)
HOST_PCI_BUS=""   # manual override: PCIe bus on host (e.g. "41" or "c2")

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0"; exit 1; }

# ─── Arg parsing ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --host-ip)       HOST_IP="$2";       shift ;;
    --host-user)     HOST_USER="$2";     shift ;;
    --host-pass)     HOST_PASS="$2";     shift ;;
    --host-pci-bus)  HOST_PCI_BUS="$2";  shift ;;
    -h|--help)
      cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  --host-ip      <IP>   SSH to host and auto-discover BF3 NIC interface names
  --host-user    <user> Host SSH username (default: admin)
  --host-pass    <pass> Host SSH password (required with --host-ip)
  --host-pci-bus <bus>  Manual PCIe bus override on host (e.g. 41 or c2)
                        Use when auto-discovery fails (multiple BF3s, no rshim)

Examples:
  sudo $0
  sudo $0 --host-ip 10.20.13.13
  sudo $0 --host-ip 10.20.13.13 --host-user admin --host-pass <password>
  sudo $0 --host-ip 10.20.13.13 --host-pci-bus 41
EOF
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

mkdir -p "$LOG_DIR"

# ─── Helpers ─────────────────────────────────────────────────────────────────
# HBN port layout = sfc.conf MAPPINGS (written by the bringup, read by init-sfs):
# field 4 is the container netdev. Covers dual-port, single-port and --no-pf;
# falls back to the classic dual-port layout when sfc.conf is missing.
load_layout() {
  HBN_IFACES=()
  local _br _port _rep iface _rest
  while IFS='~' read -r _br _port _rep iface _rest; do
    [[ -n "$iface" ]] && HBN_IFACES+=("$iface")
  done < <(grep -v '^[[:space:]]*#' "$SFC_CONF" 2>/dev/null | grep -oE '"br-hbn~[^"]+"' | tr -d '"' || true)
  if [[ ${#HBN_IFACES[@]} -eq 0 ]]; then
    HBN_IFACES=(p0_if p1_if pf0hpf_if pf1hpf_if)
    LAYOUT_SRC="default dual-port layout (${SFC_CONF} not found)"
  else
    LAYOUT_SRC="${SFC_CONF}"
  fi
}

# container netdev -> sfnum (core map + authoritative VF ranges 1001+N / 1257+N)
sfnum_of() {
  local n
  case "$1" in
    p0_if) echo 2 ;; p1_if) echo 3 ;; pf0hpf_if) echo 1514 ;; pf1hpf_if) echo 1515 ;;
    pf0vf*_if) n="${1#pf0vf}"; echo $((1001 + ${n%_if})) ;;
    pf1vf*_if) n="${1#pf1vf}"; echo $((1257 + ${n%_if})) ;;
  esac
}

get_iface_info() {
  local iface="$1"
  local ip state mac

  ip=$(nsenter -t "$CONT_PID" -n -- ip addr show "$iface" 2>/dev/null \
    | grep "inet " | awk '{print $2}' | head -1)
  [[ -z "$ip" ]] && ip="(not configured)"

  state=$(nsenter -t "$CONT_PID" -n -- ip link show "$iface" 2>/dev/null \
    | grep -o "state [A-Z]*" | awk '{print $2}' | head -1)
  [[ -z "$state" ]] && state="UNKNOWN"

  mac=$(nsenter -t "$CONT_PID" -n -- ip link show "$iface" 2>/dev/null \
    | grep "link/ether" | awk '{print $2}' | head -1)
  [[ -z "$mac" ]] && mac="unknown"

  echo "$ip|$state|$mac"
}

# SSH to host, find THIS BF3's NIC interfaces.
# Discovery order:
#   0. Manual --host-pci-bus override
#   1. rshim MAC match   (unique — works with multiple BF3s)
#   2. PCIe serial match (unique — works when rshim is absent)
#   3. BF3 device ID     (0xa2dc — excludes BF2, fails with multiple BF3s)
#   4. Any BlueField     (last resort)
# Returns: PF0_NIC|PF1_NIC
discover_host_nics() {
  local ip="$1" user="$2" pass="$3" oob_mac="$4" manual_bus="$5"

  if ! command -v sshpass &>/dev/null; then
    echo "unknown|unknown"
    return
  fi

  sshpass -p "$pass" ssh \
    -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=no \
    "${user}@${ip}" "BF3_OOB_MAC='${oob_mac}' MANUAL_BUS='${manual_bus}'; bash -s" \
    <<'REMOTE' 2>/dev/null || echo "unknown|unknown"

PF0="" PF1="" TARGET_BUS=""

# ── Method 0: Manual override ────────────────────────────────────────────────
if [[ -n "$MANUAL_BUS" ]]; then
  TARGET_BUS="$MANUAL_BUS"
fi

# ── Method 1: rshim MAC match ────────────────────────────────────────────────
# /dev/rshim*/info has BF_MAC = BF3 OOB MAC — unique per card
if [[ -z "$TARGET_BUS" ]]; then
  oob_norm=$(echo "$BF3_OOB_MAC" | tr '[:upper:]' '[:lower:]')
  for rshim_info in /dev/rshim*/info; do
    [[ -f "$rshim_info" ]] || continue
    bf_mac=$(grep -i "BF_MAC" "$rshim_info" 2>/dev/null \
      | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
    if [[ "$bf_mac" == "$oob_norm" ]]; then
      # rshim sysfs has domain prefix: 0000:41:00.0 → cut -d: -f2 = 41
      TARGET_BUS=$(ls /sys/bus/pci/drivers/rshim_pcie/ 2>/dev/null \
        | grep "0000:" | head -1 | cut -d: -f2)
      break
    fi
  done
fi

# ── Method 2: PCIe Device Serial Number match ────────────────────────────────
if [[ -z "$TARGET_BUS" ]]; then
  oob_clean=$(echo "$BF3_OOB_MAC" | tr -d ':' | tr '[:upper:]' '[:lower:]')
  while IFS= read -r line; do
    bdf=$(echo "$line" | awk '{print $1}')
    dsn=$(lspci -vv -s "$bdf" 2>/dev/null \
      | grep -i "Serial Number" | grep -io '[0-9a-f:]*$' \
      | tr -d ':' | tr '[:upper:]' '[:lower:]' || true)
    if [[ -n "$dsn" && -n "$oob_clean" && "$dsn" == *"$oob_clean"* ]]; then
      # lspci -n BDF has domain prefix: 0000:41:00.0 → cut -d: -f2 = 41
      TARGET_BUS=$(echo "$bdf" | cut -d: -f2)
      break
    fi
  done < <(lspci -n 2>/dev/null | grep -i "15b3:")
fi

# ── Method 3: "BlueField-3" string match ─────────────────────────────────────
# lspci (no -n) outputs "41:00.0 ..." — NO domain prefix → use cut -d: -f1
# lspci shows "BlueField-2" for BF2 and "BlueField-3" for BF3 — unambiguous.
if [[ -z "$TARGET_BUS" ]]; then
  count=$(lspci 2>/dev/null | grep -c "BlueField-3" || echo 0)
  if [[ "$count" -gt 2 ]]; then
    echo "WARN: $count BlueField-3 devices found — cannot auto-select. Use --host-pci-bus" >&2
    echo "unknown|unknown"
    exit 0
  fi
  TARGET_BUS=$(lspci 2>/dev/null | grep "BlueField-3" \
    | awk '{print $1}' | head -1 | cut -d: -f1)
fi

if [[ -z "$TARGET_BUS" ]]; then
  echo "unknown|unknown"
  exit 0
fi

# Find mlx5 interfaces at TARGET_BUS
for iface in $(ls /sys/class/net/ 2>/dev/null); do
  driver=$(ethtool -i "$iface" 2>/dev/null | grep "^driver" | awk '{print $2}')
  [[ "$driver" != "mlx5_core" ]] && continue
  bus_full=$(ethtool -i "$iface" 2>/dev/null | grep "bus-info" | awk '{print $2}')
  iface_bus=$(echo "$bus_full" | cut -d: -f2)
  [[ "$iface_bus" != "$TARGET_BUS" ]] && continue
  func=$(echo "$bus_full" | grep -oE '\.[0-9]+$' | tr -d '.')
  [[ "$func" == "0" ]] && PF0="$iface"
  [[ "$func" == "1" ]] && PF1="$iface"
done

echo "${PF0:-unknown}|${PF1:-unknown}"
REMOTE
}

# ─── Find container ──────────────────────────────────────────────────────────
CONT=$(crictl ps -q --name doca-hbn 2>/dev/null | head -1 || true)
if [[ -z "$CONT" ]]; then
  echo "ERROR: doca-hbn container not running. Run bringup_hbn_bf3.sh first."
  exit 1
fi
CONT_PID=$(crictl inspect "$CONT" 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('info',{}).get('pid',''))" 2>/dev/null || true)
if [[ -z "$CONT_PID" ]]; then
  echo "ERROR: Could not get container PID for nsenter"
  exit 1
fi

# ─── Gather BF3 interface data ───────────────────────────────────────────────
load_layout
# + VF netdevs present in the container but not in sfc.conf (older boxes wired VFs
#   outside sfc.conf — e.g. S1)
for _PFX in pf0vf pf1vf; do
  for ((_N=0; _N<128; _N++)); do
    _VIF="${_PFX}${_N}_if"
    nsenter -t "$CONT_PID" -n -- ip link show "$_VIF" &>/dev/null || break
    [[ " ${HBN_IFACES[*]} " == *" $_VIF "* ]] || HBN_IFACES+=("$_VIF")
  done
done

BF3_OS=$(cat /etc/mlnx-release 2>/dev/null \
  || grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' \
  || echo "unknown")
OOB_IP=$(ip addr show oob_net0 2>/dev/null | grep "inet " | awk '{print $2}' | head -1 || echo "unknown")
OOB_MAC=$(ip link show oob_net0 2>/dev/null | grep "link/ether" | awk '{print $2}' | head -1 || echo "unknown")

# ─── Discover host NIC names ─────────────────────────────────────────────────
HOST_PF0_NIC="run with --host-ip to discover"
HOST_PF1_NIC="run with --host-ip to discover"
HOST_STATUS=""

if [[ -n "$HOST_IP" && -z "$HOST_PASS" ]]; then
  echo "NOTE: --host-ip given without --host-pass — skipping host NIC discovery" >&2
  HOST_IP=""
fi
if [[ -n "$HOST_IP" ]]; then
  echo "Discovering host NIC interfaces via SSH to ${HOST_IP}..." >&2
  IFS='|' read -r HOST_PF0_NIC HOST_PF1_NIC <<< "$(discover_host_nics "$HOST_IP" "$HOST_USER" "$HOST_PASS" "$OOB_MAC" "$HOST_PCI_BUS")"
  if [[ "$HOST_PF0_NIC" == "unknown" && "$HOST_PF1_NIC" == "unknown" ]]; then
    HOST_STATUS=" (SSH failed or no BlueField NIC found on host)"
    HOST_PF0_NIC="not found"
    HOST_PF1_NIC="not found"
  fi
fi

# ─── Build output (tee to file) ───────────────────────────────────────────────
{
cat <<EOF

============================================================
  HBN BF3 Interface Reference
  BF3 OS  : $BF3_OS
  Generated: $(date)
============================================================

  OOB Management (SSH / REST API access)
  ───────────────────────────────────────
  Interface  : oob_net0
  IP Address : $OOB_IP
  MAC        : $OOB_MAC
  SSH Access : ssh ubuntu@$(echo "$OOB_IP" | cut -d/ -f1)
  REST API   : curl -k -u nvidia:nvidia https://$(echo "$OOB_IP" | cut -d/ -f1):8765/nvue_v1/

============================================================
  Configurable Interfaces  (use these in FRR / NVUE)
  Layout from: ${LAYOUT_SRC}
============================================================
EOF

# One card per interface HBN actually owns (sfc.conf MAPPINGS order)
_IDX=1
for _IF in "${HBN_IFACES[@]}"; do
  IFS='|' read -r _IP _STATE _MAC <<< "$(get_iface_info "$_IF")"
  _SFN=$(sfnum_of "$_IF")
  _EXTRA=""
  case "$_IF" in
    p[01]_if)
      _TITLE="ToR Uplink ${_IF:1:1}        → connects to Top-of-Rack switch (p${_IF:1:1})" ;;
    pf[01]hpf_if)
      _N="${_IF:2:1}"; _HOSTVAR="HOST_PF${_N}_NIC"
      _TITLE="Host Facing ${_N}       → connects to x86 host PF via PCIe (SF sfnum ${_SFN})"
      _EXTRA="      Host NIC      : ${!_HOSTVAR}${HOST_STATUS}" ;;
    pf[01]vf*_if)
      # Host VF name = PF NIC minus its npX suffix + vN (enp65s0f0np0 → enp65s0f0v0)
      _N="${_IF:2:1}"; _HOSTVAR="HOST_PF${_N}_NIC"
      _VF_N="${_IF#pf${_N}vf}"; _VF_N="${_VF_N%_if}"
      _PF_BASE="${!_HOSTVAR:-unknown}"; _PF_BASE="${_PF_BASE%np*}"
      _VF_HOST="${_PF_BASE}v${_VF_N}"
      [[ "$HOST_PF0_NIC" == "run with --host-ip"* || -z "$HOST_IP" ]] && \
        _VF_HOST="(run with --host-ip to discover)"
      _TITLE="VF Interface         → ${_IF}"
      _EXTRA="      Host VF       : ${_VF_HOST}" ;;
    *)
      _TITLE="Interface            → ${_IF}" ;;
  esac
  cat <<EOF

  [${_IDX}] ${_TITLE}
      FRR Interface : ${_IF}
      MAC           : ${_MAC}
      IP Address    : ${_IP}
      Link State    : ${_STATE}
EOF
  [[ -n "$_EXTRA" ]] && echo "$_EXTRA"
  _IDX=$((_IDX+1))
done

cat <<EOF

============================================================
  How to Configure
============================================================

  FRR CLI (vtysh):
    CONT=\$(sudo crictl ps | grep doca-hbn | grep -v init | awk '{print \$1}')
    sudo crictl exec -it \$CONT vtysh

  NVUE CLI:
    sudo crictl exec -it \$CONT nv show system

  REST API:
    curl -k -u nvidia:nvidia https://$(echo "$OOB_IP" | cut -d/ -f1):8765/nvue_v1/system

  Example — assign IP to p0_if and configure BGP via vtysh:
    interface p0_if
     ip address 192.168.1.1/30
     no shutdown
    !
    router bgp 65000
     neighbor 192.168.1.2 remote-as 65001
     address-family ipv4 unicast
      network 192.168.0.0/16
     exit-address-family

============================================================
  Output saved to: $OUT_FILE
============================================================

EOF
} | tee "$OUT_FILE"
