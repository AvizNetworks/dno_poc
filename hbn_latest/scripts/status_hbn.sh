#!/usr/bin/env bash
# status_hbn.sh — HBN stack health check for BlueField-3 DPU
# Run on BF3 with sudo: sudo ./status_hbn.sh
set -uo pipefail

BF3_PCI0="0000:03:00.0"
BF3_PCI1="0000:03:00.1"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

pass()  { printf "${GREEN}[OK]${NC}   %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[FAIL]${NC} %s\n" "$*"; FAILURES=$((FAILURES+1)); }
section() { echo -e "\n${CYAN}── $* ──${NC}"; }

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0"; exit 1; }

FAILURES=0

echo ""
echo "============================================================"
echo "  HBN Status Check — $(date)"
echo "============================================================"

# ─── 1. eswitch ──────────────────────────────────────────────────────────────
section "eswitch mode"
for BF3_PCI in "$BF3_PCI0" "$BF3_PCI1"; do
  if devlink dev eswitch show "pci/$BF3_PCI" 2>/dev/null | grep "^pci/$BF3_PCI" | grep -q "mode switchdev"; then
    pass "pci/$BF3_PCI eswitch mode: switchdev"
  else
    MODE=$(devlink dev eswitch show "pci/$BF3_PCI" 2>/dev/null | grep "^pci/$BF3_PCI" | grep -o "mode [a-z]*" | awk '{print $2}' || true)
    fail "pci/$BF3_PCI eswitch mode: ${MODE:-unknown} (expected switchdev)"
  fi
done

# ─── 2. SubFunctions ─────────────────────────────────────────────────────────
section "SubFunctions (SFs)"
for sfnum in 2 3 1514 1515; do
  if devlink port show 2>/dev/null | grep -q "sfnum $sfnum"; then
    pass "sfnum $sfnum present"
  else
    fail "sfnum $sfnum MISSING — run: sudo bash /etc/mellanox/mlnx-sf.conf"
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
for rep in p0_if_r p1_if_r pf0hpf_if_r pf1hpf_if_r; do
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
  # Build interface list: always check PF interfaces, discover VF interfaces dynamically
  CHECK_IFACES=(p0_if p1_if pf0hpf_if pf1hpf_if)
  for _PFX in pf0vf pf1vf; do
    for _N in 0 1 2 3 4 5 6 7; do
      _VIF="${_PFX}${_N}_if"
      nsenter -t "$CONT_PID" -n -- ip link show "$_VIF" &>/dev/null 2>&1 && \
        CHECK_IFACES+=("$_VIF") || break
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
