#!/usr/bin/env bash
# topology_hbn.sh — Show HBN interface reference for teams configuring FRR/NVUE
# Run on BF3 with sudo: sudo ./topology_hbn.sh
# Output is shown live AND saved to /var/log/doca/hbn/topology-<timestamp>.txt
set -euo pipefail

LOG_DIR="/var/log/doca/hbn"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_FILE="$LOG_DIR/topology-${TIMESTAMP}.txt"

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0"; exit 1; }

mkdir -p "$LOG_DIR"

# ─── Helpers ─────────────────────────────────────────────────────────────────
get_iface_info() {
  local cont="$1" iface="$2"
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

# ─── Gather data ─────────────────────────────────────────────────────────────
BF3_OS=$(cat /etc/mlnx-release 2>/dev/null || grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")
OOB_IP=$(ip addr show oob_net0 2>/dev/null | grep "inet " | awk '{print $2}' | head -1 || echo "unknown")
OOB_MAC=$(ip link show oob_net0 2>/dev/null | grep "link/ether" | awk '{print $2}' | head -1 || echo "unknown")

IFS='|' read -r P0_IF_IP P0_IF_STATE P0_IF_MAC     <<< "$(get_iface_info "$CONT" p0_if)"
IFS='|' read -r P1_IF_IP P1_IF_STATE P1_IF_MAC     <<< "$(get_iface_info "$CONT" p1_if)"
IFS='|' read -r PF0_IP  PF0_STATE  PF0_MAC         <<< "$(get_iface_info "$CONT" pf0hpf_if)"
IFS='|' read -r PF1_IP  PF1_STATE  PF1_MAC         <<< "$(get_iface_info "$CONT" pf1hpf_if)"

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

  [3] Host Facing 0       → connects to host NIC enp193s0f0np0
      FRR Interface : pf0hpf_if
      MAC           : $PF0_MAC
      IP Address    : $PF0_IP
      Link State    : $PF0_STATE

  [4] Host Facing 1       → connects to host NIC enp193s0f1np1
      FRR Interface : pf1hpf_if
      MAC           : $PF1_MAC
      IP Address    : $PF1_IP
      Link State    : $PF1_STATE

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
