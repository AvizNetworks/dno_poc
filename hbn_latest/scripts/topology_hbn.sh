#!/usr/bin/env bash
# topology_hbn.sh — Show HBN interface reference for teams configuring FRR/NVUE
# Run on BF3 with sudo: sudo ./topology_hbn.sh [--host-ip <IP>]
# Output is shown live AND saved to /var/log/doca/hbn/topology-<timestamp>.txt
set -euo pipefail

LOG_DIR="/var/log/doca/hbn"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_FILE="$LOG_DIR/topology-${TIMESTAMP}.txt"

HOST_IP=""
HOST_USER="admin"
HOST_PASS="Aviz@AIF123"
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
  --host-pass    <pass> Host SSH password (default: Aviz@AIF123)
  --host-pci-bus <bus>  Manual PCIe bus override on host (e.g. 41 or c2)
                        Use when auto-discovery fails (multiple BF3s, no rshim)

Examples:
  sudo $0
  sudo $0 --host-ip 10.20.13.13
  sudo $0 --host-ip 10.20.13.13 --host-user admin --host-pass Aviz@AIF123
  sudo $0 --host-ip 10.20.13.13 --host-pci-bus 41
EOF
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

mkdir -p "$LOG_DIR"

# ─── Helpers ─────────────────────────────────────────────────────────────────
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
BF3_OS=$(cat /etc/mlnx-release 2>/dev/null \
  || grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' \
  || echo "unknown")
OOB_IP=$(ip addr show oob_net0 2>/dev/null | grep "inet " | awk '{print $2}' | head -1 || echo "unknown")
OOB_MAC=$(ip link show oob_net0 2>/dev/null | grep "link/ether" | awk '{print $2}' | head -1 || echo "unknown")

IFS='|' read -r P0_IF_IP P0_IF_STATE P0_IF_MAC <<< "$(get_iface_info p0_if)"
IFS='|' read -r P1_IF_IP P1_IF_STATE P1_IF_MAC <<< "$(get_iface_info p1_if)"
IFS='|' read -r PF0_IP  PF0_STATE  PF0_MAC     <<< "$(get_iface_info pf0hpf_if)"
IFS='|' read -r PF1_IP  PF1_STATE  PF1_MAC     <<< "$(get_iface_info pf1hpf_if)"

# Discover VF interfaces dynamically
VF_IFACES=()
for _PFX in pf0vf pf1vf; do
  for _N in 0 1 2 3 4 5 6 7; do
    _VIF="${_PFX}${_N}_if"
    nsenter -t "$CONT_PID" -n -- ip link show "$_VIF" &>/dev/null 2>&1 && \
      VF_IFACES+=("$_VIF") || break
  done
done

# ─── Discover host NIC names ─────────────────────────────────────────────────
HOST_PF0_NIC="run with --host-ip to discover"
HOST_PF1_NIC="run with --host-ip to discover"
HOST_STATUS=""

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
============================================================

  [1] ToR Uplink 0        → connects to Top-of-Rack switch port 0
      FRR Interface : p0_if
      MAC           : $P0_IF_MAC
      IP Address    : $P0_IF_IP
      Link State    : $P0_IF_STATE

  [2] ToR Uplink 1        → connects to Top-of-Rack switch port 1
      FRR Interface : p1_if
      MAC           : $P1_IF_MAC
      IP Address    : $P1_IF_IP
      Link State    : $P1_IF_STATE

  [3] Host Facing 0       → connects to x86 host via PCIe (SF sfnum 1514)
      FRR Interface : pf0hpf_if
      MAC           : $PF0_MAC
      IP Address    : $PF0_IP
      Link State    : $PF0_STATE
      Host NIC      : $HOST_PF0_NIC${HOST_STATUS}

  [4] Host Facing 1       → connects to x86 host via PCIe (SF sfnum 1515)
      FRR Interface : pf1hpf_if
      MAC           : $PF1_MAC
      IP Address    : $PF1_IP
      Link State    : $PF1_STATE
      Host NIC      : $HOST_PF1_NIC${HOST_STATUS}
EOF

# VF interfaces (dynamically discovered)
if [[ ${#VF_IFACES[@]} -gt 0 ]]; then
  _IDX=5
  for _VIF in "${VF_IFACES[@]}"; do
    IFS='|' read -r _VIF_IP _VIF_STATE _VIF_MAC <<< "$(get_iface_info "$_VIF")"
    # Derive host VF name from PF NIC + VF index:
    # pf0vf0_if → enp65s0f0np0v0,  pf1vf2_if → enp65s0f1np1v2
    # VF naming: strip npX suffix from PF name, add vN
    # e.g. enp65s0f0np0 → enp65s0f0v0,  enp65s0f1np1 → enp65s0f1v0
    if [[ "$_VIF" == pf0vf*_if ]]; then
      _VF_N="${_VIF#pf0vf}"; _VF_N="${_VF_N%_if}"
      _PF_BASE="${HOST_PF0_NIC:-unknown}"; _PF_BASE="${_PF_BASE%np*}"
      _VF_HOST="${_PF_BASE}v${_VF_N}"
    elif [[ "$_VIF" == pf1vf*_if ]]; then
      _VF_N="${_VIF#pf1vf}"; _VF_N="${_VF_N%_if}"
      _PF_BASE="${HOST_PF1_NIC:-unknown}"; _PF_BASE="${_PF_BASE%np*}"
      _VF_HOST="${_PF_BASE}v${_VF_N}"
    else
      _VF_HOST="unknown"
    fi
    [[ "$HOST_PF0_NIC" == "run with --host-ip"* || -z "$HOST_IP" ]] && \
      _VF_HOST="(run with --host-ip to discover)"
    cat <<EOF

  [${_IDX}] VF Interface         → ${_VIF}
      FRR Interface : ${_VIF}
      MAC           : ${_VIF_MAC}
      IP Address    : ${_VIF_IP}
      Link State    : ${_VIF_STATE}
      Host VF       : ${_VF_HOST}
EOF
    _IDX=$((_IDX+1))
  done
fi

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
