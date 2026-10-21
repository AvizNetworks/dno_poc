#!/usr/bin/env bash
# status_hbn.sh — HBN stack health check for BlueField-3 DPU
# Run on BF3 with sudo: sudo ./status_hbn.sh
set -uo pipefail

BF3_PCI0="0000:03:00.0"
BF3_PCI1="0000:03:00.1"
SFC_CONF="/etc/mellanox/sfc.conf"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

pass()  { printf "${GREEN}[OK]${NC}   %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[FAIL]${NC} %s\n" "$*"; FAILURES=$((FAILURES+1)); }
section() { echo -e "\n${CYAN}── $* ──${NC}"; }

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0"; exit 1; }

# HBN port layout = sfc.conf MAPPINGS — written by the bringup, read by init-sfs, so
# it covers dual-port, single-port and --no-pf alike. Entry format:
#   "br-hbn~<eswitch port>~<SF rep>~<container netdev>~<SF rep>"
# Falls back to the classic dual-port layout when sfc.conf is missing.
load_layout() {
  HBN_PORTS=(); HBN_REPS=(); HBN_IFACES=()
  local _br port rep iface _rest
  while IFS='~' read -r _br port rep iface _rest; do
    [[ -n "$iface" ]] || continue
    HBN_PORTS+=("$port"); HBN_REPS+=("$rep"); HBN_IFACES+=("$iface")
  done < <(grep -v '^[[:space:]]*#' "$SFC_CONF" 2>/dev/null | grep -oE '"br-hbn~[^"]+"' | tr -d '"')
  if [[ ${#HBN_IFACES[@]} -eq 0 ]]; then
    HBN_PORTS=(p0 p1 pf0hpf pf1hpf)
    HBN_REPS=(p0_if_r p1_if_r pf0hpf_if_r pf1hpf_if_r)
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

FAILURES=0
load_layout

echo ""
echo "============================================================"
echo "  HBN Status Check — $(date)"
echo "  Layout: ${HBN_IFACES[*]}"
echo "  (from ${LAYOUT_SRC})"
echo "============================================================"

# ─── 1. eswitch ──────────────────────────────────────────────────────────────
section "eswitch mode"
ESW_PCIS=("$BF3_PCI0")
[[ -e "/sys/bus/pci/devices/$BF3_PCI1" ]] && ESW_PCIS+=("$BF3_PCI1")   # absent on single-port cards
for BF3_PCI in "${ESW_PCIS[@]}"; do
  if devlink dev eswitch show "pci/$BF3_PCI" 2>/dev/null | grep "^pci/$BF3_PCI" | grep -q "mode switchdev"; then
    pass "pci/$BF3_PCI eswitch mode: switchdev"
  else
    MODE=$(devlink dev eswitch show "pci/$BF3_PCI" 2>/dev/null | grep "^pci/$BF3_PCI" | grep -o "mode [a-z]*" | awk '{print $2}' || true)
    fail "pci/$BF3_PCI eswitch mode: ${MODE:-unknown} (expected switchdev)"
  fi
done

# ─── 2. SubFunctions ─────────────────────────────────────────────────────────
section "SubFunctions (SFs)"
SF_PORTS=$(devlink port show 2>/dev/null || true)
for iface in "${HBN_IFACES[@]}"; do
  sfnum=$(sfnum_of "$iface")
  [[ -n "$sfnum" ]] || continue
  if echo "$SF_PORTS" | grep -qE "sfnum ${sfnum}( |$)"; then
    pass "sfnum $sfnum present ($iface)"
  else
    fail "sfnum $sfnum ($iface) MISSING — run: sudo bash /etc/mellanox/mlnx-sf.conf"
  fi
done

# ─── 3. Containers ───────────────────────────────────────────────────────────
section "Containers"
CONT=$(crictl ps -q --name doca-hbn 2>/dev/null | head -1 || true)
if [[ -n "$CONT" ]]; then
  UPTIME=$(crictl ps 2>/dev/null | awk -v id="$CONT" '$1==id {print $6, $7}')
  pass "doca-hbn Running (ID: $CONT, up: $UPTIME)"
else
  fail "doca-hbn NOT Running"
  echo "       Check: journalctl -u kubelet | grep hbn"
fi
if crictl ps 2>/dev/null | grep -q "init-sfs"; then
  warn "init-sfs container still visible (may be completed/restarting)"
fi

# ─── 4. SF representors ──────────────────────────────────────────────────────
section "SF Representors (kernel netdevs)"
for rep in "${HBN_REPS[@]}"; do
  if ip link show "$rep" &>/dev/null; then
    STATE=$(ip link show "$rep" | grep -o "state [A-Z]*" | awk '{print $2}')
    pass "$rep exists (state: $STATE)"
  else
    fail "$rep not found — SFs may not be provisioned"
  fi
done

# ─── 5. OVS bridge ───────────────────────────────────────────────────────────
section "OVS Bridge (br-hbn)"
if ovs-vsctl show 2>/dev/null | grep -q "br-hbn"; then
  pass "br-hbn bridge exists"
  OVS_SHOW=$(ovs-vsctl show 2>/dev/null)
  # p0/p1 "Invalid argument" is expected on BF3 switchdev — physical uplinks are
  # owned by the eswitch firmware; OVS-DPDK cannot bind them as netdev ports.
  # enp3s0f0sN "No such device" is expected when VFs are enabled — init-sfs moves
  # these SF function netdevs into the doca-hbn container; OVS loses the kernel
  # interface but traffic still flows via eswitch TC flower rules (nl2docad).
  REAL_ERRORS=$(echo "$OVS_SHOW" | grep -E "No such device|error:|could not" \
    | grep -v "could not add network device p[01] to ofproto" \
    | grep -v "enp[0-9]*s[0-9]*f[0-9]*s[0-9]*" \
    | wc -l | tr -d ' ' || true)
  REAL_ERRORS=${REAL_ERRORS:-0}
  VF_SF_ERRORS=$(echo "$OVS_SHOW" | grep -c "enp[0-9]*s[0-9]*f[0-9]*s[0-9]*" || true)
  P01_ERRORS=$(echo "$OVS_SHOW" | grep -c "could not add network device p[01] to ofproto" || true)
  if [[ "$REAL_ERRORS" -gt 0 ]]; then
    fail "OVS has $REAL_ERRORS port error(s) — run: sudo systemctl restart openvswitch-switch"
    echo "$OVS_SHOW" | grep -E "No such device|error:|could not" \
      | grep -v "could not add network device p[01] to ofproto" \
      | grep -v "enp[0-9]*s[0-9]*f[0-9]*s[0-9]*" | while read -r line; do
      echo "       error: $line"
    done
  else
    PORTS=$(ovs-vsctl list-ports br-hbn 2>/dev/null | tr '\n' ' ')
    pass "OVS ports: $PORTS"
    MISSING_PORTS=()
    for p in "${HBN_PORTS[@]}" "${HBN_REPS[@]}"; do
      [[ " $PORTS " == *" $p "* ]] || MISSING_PORTS+=("$p")
    done
    [[ ${#MISSING_PORTS[@]} -gt 0 ]] && \
      fail "br-hbn missing mapped port(s): ${MISSING_PORTS[*]} — run: sudo systemctl restart sfc.service"
    [[ "$P01_ERRORS" -gt 0 ]] && \
      warn "p0/p1 uplinks report 'Invalid argument' — expected on BF3 switchdev (benign, eswitch firmware owns physical ports)"
    [[ "${VF_SF_ERRORS:-0}" -gt 0 ]] && \
      warn "VF SF function netdevs (enp3s0f0sN) show 'No such device' — expected, init-sfs moved them to container"
  fi
else
  fail "br-hbn bridge not found"
fi


# ─── Get container PID for nsenter ───────────────────────────────────────────
CONT_PID=""
if [[ -n "$CONT" ]]; then
  CONT_PID=$(crictl inspect "$CONT" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('info',{}).get('pid',''))" 2>/dev/null || true)
fi

# ─── 6. FRR daemons ──────────────────────────────────────────────────────────
section "FRR Daemons"
if [[ -n "$CONT_PID" ]]; then
  # Check FRR processes via /proc (no exec needed)
  for daemon in zebra staticd bfdd bgpd; do
    if grep -rl "^${daemon}$" /proc/*/comm 2>/dev/null | head -1 | grep -q .; then
      pass "$daemon running"
    elif [[ "$daemon" == "bgpd" ]]; then
      warn "bgpd not running (use --enable-bgp in bringup_hbn_bf3.sh)"
    else
      fail "$daemon not running"
    fi
  done
  # Try vtysh via nsenter (non-fatal)
  DAEMONS=$(nsenter -t "$CONT_PID" -n -m -- /usr/bin/vtysh -c "show daemons" 2>/dev/null | tr -d '\r' || true)
  [[ -n "$DAEMONS" ]] && pass "vtysh: $DAEMONS"
else
  warn "Skipping FRR check (container not running)"
fi

# ─── 7. Interfaces inside container ──────────────────────────────────────────
section "HBN Interfaces (inside doca-hbn container)"
if [[ -n "$CONT_PID" ]]; then
  # Every container netdev in the layout, plus VF netdevs present in the container but
  # not in sfc.conf (older boxes wired VFs outside sfc.conf — e.g. S1)
  CHECK_IFACES=("${HBN_IFACES[@]}")
  for _PFX in pf0vf pf1vf; do
    for ((_N=0; _N<128; _N++)); do
      _VIF="${_PFX}${_N}_if"
      nsenter -t "$CONT_PID" -n -- ip link show "$_VIF" &>/dev/null || break
      [[ " ${CHECK_IFACES[*]} " == *" $_VIF "* ]] || CHECK_IFACES+=("$_VIF")
    done
  done

  for iface in "${CHECK_IFACES[@]}"; do
    INFO=$(nsenter -t "$CONT_PID" -n -- ip addr show "$iface" 2>/dev/null || true)
    if [[ -z "$INFO" ]]; then
      fail "$iface not found inside container netns"
      continue
    fi
    STATE=$(echo "$INFO" | grep -o "state [A-Z]*" | awk '{print $2}')
    IP=$(echo "$INFO" | grep "inet " | awk '{print $2}' | head -1)
    IP_STR=${IP:-"(no IP)"}
    if [[ "$STATE" == "UP" ]]; then
      pass "$iface  state=$STATE  ip=$IP_STR"
    else
      warn "$iface  state=$STATE  ip=$IP_STR  (run: ip link set $iface up)"
    fi
  done
else
  warn "Skipping interface check (container not running)"
fi

# ─── 8. REST API ─────────────────────────────────────────────────────────────
section "NVUE REST API"
OOB_IP=$(ip addr show oob_net0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || echo "localhost")
CONT_IP=""
if [[ -n "$CONT_PID" ]]; then
  CONT_IP=$(nsenter -t "$CONT_PID" -n -- ip addr show eth0 2>/dev/null \
    | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | tr -d '[:space:]' || true)
fi
if [[ -z "$CONT_IP" ]]; then
  fail "REST API: could not determine container IP — is doca-hbn running?"
else
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -u "nvidia:nvidia" \
    "https://${CONT_IP}:8765/nvue_v1/system" 2>/dev/null)
  if [[ "$HTTP_CODE" == "200" ]]; then
    pass "REST API reachable at https://${OOB_IP}:8765/nvue_v1/ (HTTP $HTTP_CODE)"
  elif [[ "$HTTP_CODE" == "401" ]]; then
    warn "REST API reachable but credentials wrong (HTTP 401) — run bringup_hbn_bf3.sh with --rest-user/--rest-pass"
  else
    fail "REST API not reachable (HTTP $HTTP_CODE) — run hbn-dpu-setup.sh -e"
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
if [[ $FAILURES -eq 0 ]]; then
  echo -e "  ${GREEN}All checks passed.${NC} HBN stack is healthy."
else
  echo -e "  ${RED}$FAILURES check(s) failed.${NC} Review the FAIL lines above."
fi
echo "============================================================"
echo ""
