#!/usr/bin/env bash
# validate_routing.sh — Basic L3 routing validation for HBN BF3 setup
# Run from any machine that can SSH to all 3 devices.
# Requires: sshpass (apt install sshpass)
set -uo pipefail

# ─── Device credentials ───────────────────────────────────────────────────────
TOR_IP="10.20.13.214";   TOR_USER="admin";  TOR_PASS="Aviz@123"
BF3_IP="10.20.13.228";   BF3_USER="ubuntu"; BF3_PASS="Aviz@AIF12345"
HOST_IP="10.20.13.12";   HOST_USER="admin"; HOST_PASS="Aviz@AIF123"

# ─── Interface/IP config ─────────────────────────────────────────────────────
TOR_IFACE="Ethernet76";  TOR_IFACE_IP="5.5.5.1/24"
BF3_P0_IP="5.5.5.6";    BF3_P0_IFACE="p0_if"
BF3_PF0_IP="192.168.201.2"; BF3_PF0_IFACE="pf0hpf_if"
HOST_IFACE="enp193s0f0np0"; HOST_IFACE_IP="192.168.201.1/24"

PING_COUNT=3
SETUP=false

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

ok()      { printf "${GREEN}[OK]${NC}   %s\n" "$*"; }
fail()    { printf "${RED}[FAIL]${NC} %s\n" "$*"; FAILURES=$((FAILURES+1)); }
info()    { printf "${CYAN}[INFO]${NC} %s\n" "$*"; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

FAILURES=0

# ─── Arg parsing ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --setup)             SETUP=true ;;
    --tor-ip)            TOR_IP="$2"; shift ;;
    --bf3-ip)            BF3_IP="$2"; shift ;;
    --host-ip)           HOST_IP="$2"; shift ;;
    --ping-count)        PING_COUNT="$2"; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
  shift
done

# ─── SSH helpers ─────────────────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=no"

ssh_cmd() {
  local user="$1" pass="$2" host="$3" cmd="$4"
  sshpass -p "$pass" ssh $SSH_OPTS "${user}@${host}" "$cmd" 2>/dev/null
}

# Run command inside doca-hbn container's network namespace on BF3
bf3_cont_cmd() {
  local cmd="$1"
  ssh_cmd "$BF3_USER" "$BF3_PASS" "$BF3_IP" "
    CONT=\$(sudo crictl ps -q --name doca-hbn 2>/dev/null | head -1)
    PID=\$(sudo crictl inspect \"\$CONT\" 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d.get('info',{}).get('pid',''))\")
    sudo nsenter -t \"\$PID\" -n -m -- $cmd
  "
}

# Parse ping output → loss percentage
parse_loss() {
  echo "$1" | grep -oP '\d+(?=% packet loss)' | head -1 || echo "100"
}

# ─── Check sshpass ───────────────────────────────────────────────────────────
if ! command -v sshpass &>/dev/null; then
  echo -e "${RED}ERROR:${NC} sshpass not found. Install with: sudo apt install sshpass"
  exit 1
fi

echo ""
echo "============================================================"
echo -e "  ${BOLD}HBN Routing Validation${NC}"
echo "  $(date)"
echo "============================================================"
echo ""
printf "  %-12s %s\n" "ToR:"  "${TOR_IP}  (${TOR_IFACE} = ${TOR_IFACE_IP})"
printf "  %-12s %s\n" "BF3:"  "${BF3_IP}  (p0_if=${BF3_P0_IP}, pf0hpf_if=${BF3_PF0_IP})"
printf "  %-12s %s\n" "Host:" "${HOST_IP}  (${HOST_IFACE} = ${HOST_IFACE_IP})"
echo ""

# ─── Phase 1: Connectivity check to all devices ──────────────────────────────
section "SSH Reachability"
for label_ip_user_pass in \
    "ToR:${TOR_IP}:${TOR_USER}:${TOR_PASS}" \
    "BF3:${BF3_IP}:${BF3_USER}:${BF3_PASS}" \
    "Host:${HOST_IP}:${HOST_USER}:${HOST_PASS}"; do
  IFS=':' read -r label ip user pass <<< "$label_ip_user_pass"
  if sshpass -p "$pass" ssh $SSH_OPTS "${user}@${ip}" "echo ok" &>/dev/null; then
    ok "$label ($ip) SSH reachable"
  else
    fail "$label ($ip) SSH UNREACHABLE — check credentials/network"
  fi
done

# ─── Phase 2: Setup IPs (optional) ───────────────────────────────────────────
if [[ "$SETUP" == "true" ]]; then
  section "IP Configuration Setup"

  info "Configuring ToR ${TOR_IFACE} = ${TOR_IFACE_IP}"
  ssh_cmd "$TOR_USER" "$TOR_PASS" "$TOR_IP" \
    "sudo config interface ip add ${TOR_IFACE} ${TOR_IFACE_IP} 2>/dev/null; sudo config interface startup ${TOR_IFACE} 2>/dev/null" \
    && ok "ToR: ${TOR_IFACE} = ${TOR_IFACE_IP}" \
    || fail "ToR: failed to configure ${TOR_IFACE}"

  info "Configuring Host ${HOST_IFACE} = ${HOST_IFACE_IP}"
  HOST_SETUP_IP="${HOST_IFACE_IP%%/*}"
  ssh_cmd "$HOST_USER" "$HOST_PASS" "$HOST_IP" "
    sudo ip link set ${HOST_IFACE} up 2>/dev/null || true
    sudo ip addr add ${HOST_IFACE_IP} dev ${HOST_IFACE} 2>/dev/null || true
  " > /dev/null
  HOST_CHECK=$(ssh_cmd "$HOST_USER" "$HOST_PASS" "$HOST_IP" \
    "ip addr show ${HOST_IFACE} 2>/dev/null | grep 'inet ${HOST_SETUP_IP}'" || true)
  if [[ -n "$HOST_CHECK" ]]; then
    ok "Host: ${HOST_IFACE} = ${HOST_IFACE_IP}"
  else
    fail "Host: ${HOST_IFACE} not configured — run manually: sudo ip addr add ${HOST_IFACE_IP} dev ${HOST_IFACE}"
  fi

  sleep 2
fi

# ─── Phase 3: Interface states ───────────────────────────────────────────────
section "Interface States"

# ToR Ethernet76
TOR_IFACE_STATE=$(ssh_cmd "$TOR_USER" "$TOR_PASS" "$TOR_IP" \
  "show interface status ${TOR_IFACE} 2>/dev/null | grep ${TOR_IFACE}" || echo "")
if echo "$TOR_IFACE_STATE" | grep -qi "up\|connected"; then
  ok "ToR ${TOR_IFACE}: UP"
else
  fail "ToR ${TOR_IFACE}: not UP — check cable/config"
fi

# BF3 container interfaces
for iface_ip in "${BF3_P0_IFACE}:${BF3_P0_IP}" "${BF3_PF0_IFACE}:${BF3_PF0_IP}"; do
  IFS=':' read -r iface ip <<< "$iface_ip"
  STATE=$(bf3_cont_cmd "ip link show $iface 2>/dev/null" | grep -o "state [A-Z]*" | awk '{print $2}' || echo "")
  ADDR=$(bf3_cont_cmd "ip addr show $iface 2>/dev/null" | grep "inet " | awk '{print $2}' || echo "")
  if [[ "$STATE" == "UP" ]]; then
    ok "BF3 ${iface}: UP  ip=${ADDR:-not configured}"
  else
    fail "BF3 ${iface}: state=${STATE:-unknown}  ip=${ADDR:-not configured}"
  fi
done

# Host enp193s0f0np0
HOST_STATE=$(ssh_cmd "$HOST_USER" "$HOST_PASS" "$HOST_IP" \
  "ip link show ${HOST_IFACE} 2>/dev/null | grep -o 'state [A-Z]*'" | awk '{print $2}' || echo "")
HOST_ADDR=$(ssh_cmd "$HOST_USER" "$HOST_PASS" "$HOST_IP" \
  "ip addr show ${HOST_IFACE} 2>/dev/null | grep 'inet '" | awk '{print $2}' || echo "")
if [[ "$HOST_STATE" == "UP" ]]; then
  ok "Host ${HOST_IFACE}: UP  ip=${HOST_ADDR:-not configured}"
else
  fail "Host ${HOST_IFACE}: state=${HOST_STATE:-unknown}  ip=${HOST_ADDR:-not configured}"
fi

# ─── Phase 4: Ping validation ─────────────────────────────────────────────────
section "Ping Validation (count=$PING_COUNT)"

declare -A PING_RESULTS

# 1. BF3 → ToR (p0_if → Ethernet76)
info "Ping: BF3 p0_if (${BF3_P0_IP}) → ToR Ethernet76 ($(echo $TOR_IFACE_IP | cut -d/ -f1))"
TOR_PEER=$(echo "$TOR_IFACE_IP" | cut -d/ -f1)
OUT=$(bf3_cont_cmd "ping -I ${BF3_P0_IFACE} -c ${PING_COUNT} -W 2 ${TOR_PEER} 2>&1" || echo "ping failed")
echo "$OUT" | grep -E "packets|rtt" | sed 's/^/         /'
LOSS=$(parse_loss "$OUT")
PING_RESULTS["BF3→ToR"]="$LOSS"
[[ "$LOSS" == "0" ]] && ok "BF3 → ToR: 0% loss" || fail "BF3 → ToR: ${LOSS}% loss"

# 2. BF3 → Host (pf0hpf_if → enp193s0f0np0)
info "Ping: BF3 pf0hpf_if (${BF3_PF0_IP}) → Host enp193s0f0np0 ($(echo $HOST_IFACE_IP | cut -d/ -f1))"
HOST_PEER=$(echo "$HOST_IFACE_IP" | cut -d/ -f1)
OUT=$(bf3_cont_cmd "ping -I ${BF3_PF0_IFACE} -c ${PING_COUNT} -W 2 ${HOST_PEER} 2>&1" || echo "ping failed")
echo "$OUT" | grep -E "packets|rtt" | sed 's/^/         /'
LOSS=$(parse_loss "$OUT")
PING_RESULTS["BF3→Host"]="$LOSS"
[[ "$LOSS" == "0" ]] && ok "BF3 → Host: 0% loss" || fail "BF3 → Host: ${LOSS}% loss"

# 3. ToR → BF3 p0_if
info "Ping: ToR Ethernet76 → BF3 p0_if (${BF3_P0_IP})"
OUT=$(ssh_cmd "$TOR_USER" "$TOR_PASS" "$TOR_IP" \
  "ping ${BF3_P0_IP} -c ${PING_COUNT} -W 2 2>&1" || echo "ping failed")
echo "$OUT" | grep -E "packets|rtt" | sed 's/^/         /'
LOSS=$(parse_loss "$OUT")
PING_RESULTS["ToR→BF3"]="$LOSS"
[[ "$LOSS" == "0" ]] && ok "ToR → BF3: 0% loss" || fail "ToR → BF3: ${LOSS}% loss"

# 4. Host → BF3 pf0hpf_if
info "Ping: Host enp193s0f0np0 → BF3 pf0hpf_if (${BF3_PF0_IP})"
OUT=$(ssh_cmd "$HOST_USER" "$HOST_PASS" "$HOST_IP" \
  "ping ${BF3_PF0_IP} -c ${PING_COUNT} -W 2 2>&1" || echo "ping failed")
echo "$OUT" | grep -E "packets|rtt" | sed 's/^/         /'
LOSS=$(parse_loss "$OUT")
PING_RESULTS["Host→BF3"]="$LOSS"
[[ "$LOSS" == "0" ]] && ok "Host → BF3: 0% loss" || fail "Host → BF3: ${LOSS}% loss"

# ─── Phase 5: Routing table ──────────────────────────────────────────────────
section "BF3 Routing Table (inside doca-hbn container)"
RT=$(bf3_cont_cmd "ip route show 2>/dev/null" || echo "")
if [[ -n "$RT" ]]; then
  echo "$RT" | sed 's/^/  /'
else
  fail "Could not retrieve routing table from BF3 container"
fi

FRR_RT=$(bf3_cont_cmd "/usr/bin/vtysh -c 'show ip route' 2>/dev/null" || echo "")
if [[ -n "$FRR_RT" ]]; then
  echo ""
  info "FRR routes:"
  echo "$FRR_RT" | grep -E "^\*|>|[0-9]+\.[0-9]" | head -20 | sed 's/^/  /'
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo -e "  ${BOLD}Ping Summary${NC}"
echo "============================================================"
printf "  %-20s %-12s %s\n" "Path" "Loss" "Result"
printf "  %-20s %-12s %s\n" "----" "----" "------"
for path in "BF3→ToR" "BF3→Host" "ToR→BF3" "Host→BF3"; do
  loss="${PING_RESULTS[$path]:-N/A}"
  if [[ "$loss" == "0" ]]; then
    result="${GREEN}PASS${NC}"
  else
    result="${RED}FAIL${NC}"
  fi
  printf "  %-20s %-12s " "$path" "${loss}%"
  echo -e "$result"
done
echo "============================================================"
if [[ $FAILURES -eq 0 ]]; then
  echo -e "  ${GREEN}All checks passed.${NC}"
else
  echo -e "  ${RED}${FAILURES} check(s) failed.${NC}"
fi
echo ""
echo "  Tip: Run with --setup to auto-configure IPs before testing."
echo ""
