#!/usr/bin/env bash
# test_static_routing_rest.sh — Configure static routing via NVUE REST API and verify end-to-end
# Run from any machine with SSH access to BF3, ToR, and Host.
# Requires: sshpass (apt install sshpass), curl, python3
set -uo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
BF3_IP="10.20.13.247";   BF3_USER="ubuntu"; BF3_PASS="Aviz@AIF12345"
TOR_IP="10.20.13.214";   TOR_USER="admin";  TOR_PASS="Aviz@123"
HOST_IP="10.20.13.13";   HOST_USER="admin"; HOST_PASS="Aviz@AIF123"
REST_USER="nvidia";      REST_PASS="nvidia"; REST_PORT="8765"

BF3_P0_IFACE="p0_if";       BF3_P0_IP="6.6.6.6/24";         BF3_P0_ADDR="6.6.6.6"
BF3_PF0_IFACE="pf0hpf_if";  BF3_PF0_IP="192.168.201.2/24";  BF3_PF0_ADDR="192.168.201.2"
TOR_IFACE="Ethernet72";      TOR_IFACE_IP="6.6.6.1/24";      TOR_PEER="6.6.6.1"; TOR_SUBNET="6.6.6.0/24"
HOST_IFACE="enp65s0f0np0"; HOST_IFACE_IP="192.168.201.1/24"; HOST_PEER="192.168.201.1"

# Test prefixes for static routes — non-connected, nexthop reachable via connected subnets
# 10.10.1.0/24 represents a network "behind" the ToR, reached via 6.6.6.1
# 10.10.2.0/24 represents a network "behind" the Host, reached via 192.168.201.1
STATIC_PREFIX1="10.10.1.0/24"; STATIC_PREFIX1_ENC="10.10.1.0%2F24"; STATIC_NH1="${TOR_PEER}"
STATIC_PREFIX2="10.10.2.0/24"; STATIC_PREFIX2_ENC="10.10.2.0%2F24"; STATIC_NH2="${HOST_PEER}"
PING_COUNT=3
SETUP=false

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

ok()      { printf "${GREEN}[OK]${NC}   %s\n" "$*"; }
fail()    { printf "${RED}[FAIL]${NC} %s\n" "$*"; FAILURES=$((FAILURES+1)); }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
info()    { printf "${CYAN}[INFO]${NC} %s\n" "$*"; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

FAILURES=0

# ─── Arg parsing ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --setup)       SETUP=true ;;
    --bf3-ip)      BF3_IP="$2"; shift ;;
    --tor-ip)      TOR_IP="$2"; shift ;;
    --host-ip)     HOST_IP="$2"; shift ;;
    --rest-user)   REST_USER="$2"; shift ;;
    --rest-pass)   REST_PASS="$2"; shift ;;
    --ping-count)  PING_COUNT="$2"; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --setup              Configure ToR and Host IPs + routes via SSH before testing
  --bf3-ip <IP>        BF3 OOB IP (default: $BF3_IP)
  --tor-ip <IP>        ToR switch IP (default: $TOR_IP)
  --host-ip <IP>       x86 host IP (default: $HOST_IP)
  --rest-user <user>   NVUE REST API username (default: $REST_USER)
  --rest-pass <pass>   NVUE REST API password (default: $REST_PASS)
  --ping-count <n>     Pings per path (default: $PING_COUNT)

Examples:
  $0
  $0 --setup
  $0 --setup --bf3-ip 10.20.13.228 --ping-count 5
EOF
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

REST_BASE="https://${BF3_IP}:${REST_PORT}/nvue_v1"
REST_AUTH="${REST_USER}:${REST_PASS}"

# ─── Log file ────────────────────────────────────────────────────────────────
LOG_FILE="hbn_rest_test_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG_FILE") 2>&1

# ─── SSH helpers (same pattern as validate_routing.sh) ───────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=no"

ssh_cmd() {
  local user="$1" pass="$2" host="$3" cmd="$4"
  sshpass -p "$pass" ssh $SSH_OPTS "${user}@${host}" "$cmd" 2>/dev/null
}

# Run a command inside the doca-hbn container's network namespace (for ip/ping)
bf3_cont_cmd() {
  local cmd="$1"
  ssh_cmd "$BF3_USER" "$BF3_PASS" "$BF3_IP" "
    CONT=\$(sudo crictl ps -q --name doca-hbn 2>/dev/null | head -1)
    PID=\$(sudo crictl inspect \"\$CONT\" 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d.get('info',{}).get('pid',''))\")
    sudo nsenter -t \"\$PID\" -n -- $cmd
  "
}

# Run one or more vtysh commands via stdin pipe (avoids TTY and -c quoting issues)
# Usage: bf3_vtysh "cmd1" "cmd2" ...
bf3_vtysh() {
  local cmds
  cmds=$(printf '%s\n' "$@")
  ssh_cmd "$BF3_USER" "$BF3_PASS" "$BF3_IP" \
    "CONT=\$(sudo crictl ps -q --name doca-hbn 2>/dev/null | head -1)
     printf '${cmds}\n' | sudo crictl exec -i \"\$CONT\" vtysh 2>/dev/null"
}

parse_loss() {
  echo "$1" | grep -oP '\d+(?=% packet loss)' | head -1 || echo "100"
}

# ─── REST helpers ─────────────────────────────────────────────────────────────
rest_get() {
  curl -sk -u "$REST_AUTH" "${REST_BASE}${1}"
}

rest_patch() {
  local path="$1" body="$2"
  curl -sk -u "$REST_AUTH" -X PATCH \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${REST_BASE}${path}"
}

rest_post() {
  local path="$1"
  curl -sk -u "$REST_AUTH" -X POST "${REST_BASE}${path}"
}

# Returns 0 if resp is a valid NVUE object, 1 if it's an error response
check_rest_resp() {
  local resp="$1" label="$2"
  if echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if isinstance(d, dict) and 'status' in d and 'title' in d:
        sys.exit(1)
    sys.exit(0)
except:
    sys.exit(0)
" 2>/dev/null; then
    ok "$label"
  else
    warn "$label — response: $resp"
    return 1
  fi
}

# ─── Header ──────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo -e "  ${BOLD}HBN Static Routing Test — NVUE REST API${NC}"
echo "  $(date)"
echo "============================================================"
echo ""
printf "  %-12s %s\n" "BF3:"  "${BF3_IP}  (p0_if=${BF3_P0_IP}, pf0hpf_if=${BF3_PF0_IP})"
printf "  %-12s %s\n" "ToR:"  "${TOR_IP}  (${TOR_IFACE}=${TOR_IFACE_IP})"
printf "  %-12s %s\n" "Host:" "${HOST_IP}  (${HOST_IFACE}=${HOST_IFACE_IP})"
printf "  %-12s %s\n" "REST:"  "${REST_BASE}  (user=${REST_USER})"
[[ "$SETUP" == "true" ]] && printf "  %-12s %s\n" "Mode:" "--setup (will configure ToR and Host)"
echo ""

# ─── Phase 0: Prerequisites ───────────────────────────────────────────────────
section "Prerequisites"

if ! command -v sshpass &>/dev/null; then
  echo -e "${RED}ERROR:${NC} sshpass not found. Install with: sudo apt install sshpass"
  exit 1
fi
ok "sshpass available"

HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -u "$REST_AUTH" "${REST_BASE}/system" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
  ok "NVUE REST API reachable (HTTP $HTTP_CODE)"
elif [[ "$HTTP_CODE" == "401" ]]; then
  fail "REST API reachable but credentials rejected (HTTP 401) — check --rest-user/--rest-pass"
  exit 1
else
  fail "REST API not reachable at ${REST_BASE} (HTTP $HTTP_CODE) — is doca-hbn running?"
  exit 1
fi

# ─── Phase 1: Configure BF3 via REST API ─────────────────────────────────────
section "Phase 1: Configure BF3 via NVUE REST API"

info "Creating revision..."
REV_RESP=$(rest_post "/revision")
REV=$(echo "$REV_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(list(d.keys())[0])" 2>/dev/null || true)
if [[ -z "$REV" ]]; then
  fail "Could not create revision. Response: $REV_RESP"
  exit 1
fi
ok "Revision created: $REV"

info "Setting ${BF3_P0_IFACE} IP = ${BF3_P0_IP}..."
rest_patch "/interface/${BF3_P0_IFACE}/ip/address?rev=${REV}" \
  "{\"${BF3_P0_IP}\": {}}" > /dev/null
ok "${BF3_P0_IFACE} IP staged"

info "Setting ${BF3_PF0_IFACE} IP = ${BF3_PF0_IP}..."
rest_patch "/interface/${BF3_PF0_IFACE}/ip/address?rev=${REV}" \
  "{\"${BF3_PF0_IP}\": {}}" > /dev/null
ok "${BF3_PF0_IFACE} IP staged"

info "Staging static route: ${STATIC_PREFIX1} via ${STATIC_NH1} (network behind ToR)..."
RESP=$(rest_patch "/vrf/default/router/static/${STATIC_PREFIX1_ENC}?rev=${REV}" \
  "{\"via\": {\"${STATIC_NH1}\": {}}}")
check_rest_resp "$RESP" "Static route ${STATIC_PREFIX1} staged"

info "Staging static route: ${STATIC_PREFIX2} via ${STATIC_NH2} (network behind Host)..."
RESP=$(rest_patch "/vrf/default/router/static/${STATIC_PREFIX2_ENC}?rev=${REV}" \
  "{\"via\": {\"${STATIC_NH2}\": {}}}")
check_rest_resp "$RESP" "Static route ${STATIC_PREFIX2} staged"

info "Applying config via 'nv config apply --assume-yes' inside container..."
APPLY_OUT=$(ssh_cmd "$BF3_USER" "$BF3_PASS" "$BF3_IP" \
  "CONT=\$(sudo crictl ps -q --name doca-hbn 2>/dev/null | head -1)
   sudo crictl exec \"\$CONT\" nv config apply --assume-yes 2>&1" || true)
[[ -n "$APPLY_OUT" ]] && echo "$APPLY_OUT" | sed 's/^/         /'
sleep 3

# Poll until ?rev=applied shows the route (max 30s)
APPLIED=false
for i in $(seq 1 6); do
  ROUTE_CHECK=$(rest_get "/vrf/default/router/static/${STATIC_PREFIX1_ENC}?rev=applied")
  if echo "$ROUTE_CHECK" | python3 -c "
import sys,json
d=json.load(sys.stdin)
sys.exit(0 if isinstance(d,dict) and 'via' in d else 1)
" 2>/dev/null; then
    ok "NVUE applied — routes visible at ?rev=applied"
    APPLIED=true
    break
  fi
  sleep 5
done

if [[ "$APPLIED" != "true" ]]; then
  warn "NVUE apply did not commit — falling back to vtysh for all BF3 config"

  info "Configuring ${BF3_P0_IFACE} = ${BF3_P0_IP} via kernel..."
  OLD_P0=$(bf3_cont_cmd "ip addr show ${BF3_P0_IFACE} 2>/dev/null" \
    | grep "inet " | awk '{print $2}' | head -1 || echo "")
  bf3_cont_cmd "ip link set ${BF3_P0_IFACE} up" > /dev/null 2>&1 || true
  if [[ -n "$OLD_P0" && "$OLD_P0" != "${BF3_P0_IP}" ]]; then
    bf3_cont_cmd "ip addr del ${OLD_P0} dev ${BF3_P0_IFACE}" > /dev/null 2>&1 || true
  fi
  bf3_cont_cmd "ip addr add ${BF3_P0_IP} dev ${BF3_P0_IFACE}" > /dev/null 2>&1 || true
  ok "${BF3_P0_IFACE} = ${BF3_P0_IP}"

  info "Configuring ${BF3_PF0_IFACE} = ${BF3_PF0_IP} via kernel..."
  OLD_PF0=$(bf3_cont_cmd "ip addr show ${BF3_PF0_IFACE} 2>/dev/null" \
    | grep "inet " | awk '{print $2}' | head -1 || echo "")
  bf3_cont_cmd "ip link set ${BF3_PF0_IFACE} up" > /dev/null 2>&1 || true
  if [[ -n "$OLD_PF0" && "$OLD_PF0" != "${BF3_PF0_IP}" ]]; then
    bf3_cont_cmd "ip addr del ${OLD_PF0} dev ${BF3_PF0_IFACE}" > /dev/null 2>&1 || true
  fi
  bf3_cont_cmd "ip addr add ${BF3_PF0_IP} dev ${BF3_PF0_IFACE}" > /dev/null 2>&1 || true
  ok "${BF3_PF0_IFACE} = ${BF3_PF0_IP}"

  info "Configuring static routes via vtysh..."
  VT_OUT=$(bf3_vtysh \
    "configure terminal" \
    "ip route ${STATIC_PREFIX1} ${STATIC_NH1}" \
    "ip route ${STATIC_PREFIX2} ${STATIC_NH2}" \
    "end" \
    "write memory")
  [[ -n "$VT_OUT" ]] && echo "$VT_OUT" | sed 's/^/         /'
  ok "Interfaces and static routes configured via vtysh fallback"
fi

# Always ensure interfaces are up (may go DOWN after NVUE apply)
bf3_cont_cmd "ip link set ${BF3_P0_IFACE} up" > /dev/null 2>&1 || true
bf3_cont_cmd "ip link set ${BF3_PF0_IFACE} up" > /dev/null 2>&1 || true

# ─── Phase 2: Configure ToR and Host (--setup) ────────────────────────────────
if [[ "$SETUP" == "true" ]]; then
  section "Phase 2: Configure ToR and Host (--setup)"

  info "Configuring ToR ${TOR_IFACE} = ${TOR_IFACE_IP} and static route for Host subnet..."
  ssh_cmd "$TOR_USER" "$TOR_PASS" "$TOR_IP" "
    sudo config interface ip add ${TOR_IFACE} ${TOR_IFACE_IP} 2>/dev/null || true
    sudo config interface startup ${TOR_IFACE} 2>/dev/null || true
    sudo vtysh -c 'configure terminal' \
               -c 'no ip route 192.168.201.0/24' \
               -c 'ip route 192.168.201.0/24 ${BF3_P0_ADDR}' \
               -c 'end' -c 'write memory' 2>/dev/null || \
    sudo ip route replace 192.168.201.0/24 via ${BF3_P0_ADDR} 2>/dev/null || true
  " > /dev/null
  TOR_RT=$(ssh_cmd "$TOR_USER" "$TOR_PASS" "$TOR_IP" \
    "show ip route 192.168.201.0/24 2>/dev/null || ip route show 192.168.201.0/24 2>/dev/null" || true)
  if [[ -n "$TOR_RT" ]]; then
    ok "ToR: ${TOR_IFACE}=${TOR_IFACE_IP}, route 192.168.201.0/24 via ${BF3_P0_ADDR} confirmed"
  else
    fail "ToR: route 192.168.201.0/24 missing — cross-subnet pings will fail"
  fi

  info "Configuring Host ${HOST_IFACE} = ${HOST_IFACE_IP} and static route for ToR subnet..."
  ssh_cmd "$HOST_USER" "$HOST_PASS" "$HOST_IP" "
    echo '${HOST_PASS}' | sudo -S ip addr add ${HOST_IFACE_IP} dev ${HOST_IFACE} 2>/dev/null || true
    echo '${HOST_PASS}' | sudo -S ip link set ${HOST_IFACE} up 2>/dev/null || true
    echo '${HOST_PASS}' | sudo -S ip route add ${TOR_SUBNET} via ${BF3_PF0_ADDR} 2>/dev/null || true
  " > /dev/null
  HOST_RT=$(ssh_cmd "$HOST_USER" "$HOST_PASS" "$HOST_IP" \
    "ip route show ${TOR_SUBNET} 2>/dev/null" || true)
  if [[ -n "$HOST_RT" ]]; then
    ok "Host: ${HOST_IFACE}=${HOST_IFACE_IP}, route ${TOR_SUBNET} via ${BF3_PF0_ADDR} confirmed"
  else
    fail "Host: route ${TOR_SUBNET} missing — add manually: sudo ip route add ${TOR_SUBNET} via ${BF3_PF0_ADDR}"
  fi

  info "Enabling IP forwarding inside doca-hbn container..."
  ssh_cmd "$BF3_USER" "$BF3_PASS" "$BF3_IP" "
    CONT=\$(sudo crictl ps -q --name doca-hbn 2>/dev/null | head -1)
    sudo crictl exec \"\$CONT\" sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
  " && ok "IP forwarding enabled in doca-hbn" || warn "Could not enable IP forwarding in doca-hbn"
else
  section "Phase 2: ToR / Host Setup"
  warn "Skipping ToR and Host configuration (pass --setup to auto-configure)"
fi

# ─── Phase 3: Verify via REST API ─────────────────────────────────────────────
section "Phase 3: Verify Configuration via REST API"

# Check p0_if IP (operational state — no ?rev needed for interface addresses)
P0_ADDRS=$(rest_get "/interface/${BF3_P0_IFACE}/ip/address?rev=applied" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(d.keys()))" 2>/dev/null || echo "")
if [[ -z "$P0_ADDRS" || "$P0_ADDRS" == *"detail"* ]]; then
  # Fallback: verify from kernel routing table via nsenter
  P0_KERN=$(bf3_cont_cmd "ip addr show ${BF3_P0_IFACE} 2>/dev/null" | grep "inet " | awk '{print $2}' || echo "")
  if echo "$P0_KERN" | grep -q "${BF3_P0_ADDR}"; then
    ok "Kernel: ${BF3_P0_IFACE} IP = ${P0_KERN} [confirmed via ip addr]"
  else
    fail "Kernel: ${BF3_P0_IFACE} IP not set (got: ${P0_KERN:-none})"
  fi
elif echo "$P0_ADDRS" | grep -q "${BF3_P0_IP}"; then
  ok "REST: ${BF3_P0_IFACE} IP = ${BF3_P0_IP} [confirmed]"
else
  fail "REST: ${BF3_P0_IFACE} IP not set (got: ${P0_ADDRS:-none})"
fi

# Check pf0hpf_if IP
PF0_ADDRS=$(rest_get "/interface/${BF3_PF0_IFACE}/ip/address?rev=applied" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(d.keys()))" 2>/dev/null || echo "")
if [[ -z "$PF0_ADDRS" || "$PF0_ADDRS" == *"detail"* ]]; then
  PF0_KERN=$(bf3_cont_cmd "ip addr show ${BF3_PF0_IFACE} 2>/dev/null" | grep "inet " | awk '{print $2}' || echo "")
  if echo "$PF0_KERN" | grep -q "${BF3_PF0_ADDR}"; then
    ok "Kernel: ${BF3_PF0_IFACE} IP = ${PF0_KERN} [confirmed via ip addr]"
  else
    fail "Kernel: ${BF3_PF0_IFACE} IP not set (got: ${PF0_KERN:-none})"
  fi
elif echo "$PF0_ADDRS" | grep -q "${BF3_PF0_IP}"; then
  ok "REST: ${BF3_PF0_IFACE} IP = ${BF3_PF0_IP} [confirmed]"
else
  fail "REST: ${BF3_PF0_IFACE} IP not set (got: ${PF0_ADDRS:-none})"
fi

# Check static routes — query per-prefix to avoid list-parse issues
check_rest_route() {
  local prefix_enc="$1" prefix_display="$2"
  local resp
  resp=$(rest_get "/vrf/default/router/static/${prefix_enc}?rev=applied")
  if echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # A valid route response has 'via' key; error has 'status'/'title'
    if isinstance(d, dict) and 'via' in d:
        sys.exit(0)
    sys.exit(1)
except:
    sys.exit(1)
" 2>/dev/null; then
    ok "REST: static route ${prefix_display} present (via: $(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(d.get('via',{}).keys()))" 2>/dev/null))"
  else
    warn "REST: static route ${prefix_display} not confirmed — response: $resp"
  fi
}

check_rest_route "$STATIC_PREFIX1_ENC" "$STATIC_PREFIX1"
check_rest_route "$STATIC_PREFIX2_ENC" "$STATIC_PREFIX2"

# ─── Phase 4: Verify via FRR (vtysh) ─────────────────────────────────────────
section "Phase 4: Verify FRR Routing Table (inside doca-hbn container)"

info "FRR static routes (vtysh: show ip route static):"
FRR_STATIC=$(bf3_vtysh "show ip route static" || echo "")
[[ -z "$FRR_STATIC" ]] && FRR_STATIC=$(bf3_vtysh "show ip route" || echo "")
if [[ -n "$FRR_STATIC" ]]; then
  echo "$FRR_STATIC" | grep -E "S>|[0-9]+\.[0-9]" | sed 's/^/         /' || true
  if echo "$FRR_STATIC" | grep -q "${STATIC_PREFIX1%%/*}"; then
    ok "FRR: ${STATIC_PREFIX1} static route active (S>*)"
  else
    warn "FRR: ${STATIC_PREFIX1} not found as active static route"
  fi
  if echo "$FRR_STATIC" | grep -q "${STATIC_PREFIX2%%/*}"; then
    ok "FRR: ${STATIC_PREFIX2} static route active (S>*)"
  else
    warn "FRR: ${STATIC_PREFIX2} not found as active static route"
  fi
else
  warn "Could not retrieve FRR static routes — check: crictl exec <cont> vtysh -c 'show ip route static'"
fi

info "Kernel routing table (ip route show inside container):"
KERN_RT=$(bf3_cont_cmd "ip route show 2>/dev/null" || echo "")
if [[ -n "$KERN_RT" ]]; then
  echo "$KERN_RT" | sed 's/^/         /'
else
  warn "Could not retrieve kernel routing table"
fi

# ─── Phase 5: Ping Validation ─────────────────────────────────────────────────
section "Phase 5: Ping Validation (count=${PING_COUNT})"

declare -A PING_RESULTS

ping_test() {
  local label="$1" cmd="$2"
  info "Ping: ${label}"
  local out
  out=$(eval "$cmd" 2>&1 || echo "ping failed")
  echo "$out" | grep -E "packets|rtt" | sed 's/^/         /' || true
  local loss
  loss=$(parse_loss "$out")
  PING_RESULTS["$label"]="$loss"
  if [[ "$loss" == "0" ]]; then
    ok "${label}: 0% loss"
  else
    fail "${label}: ${loss}% loss"
  fi
}

ping_test "BF3→ToR (p0_if→${TOR_PEER})" \
  "bf3_cont_cmd 'ping -I ${BF3_P0_IFACE} -c ${PING_COUNT} -W 2 ${TOR_PEER} 2>&1'"

ping_test "BF3→Host (pf0hpf_if→${HOST_PEER})" \
  "bf3_cont_cmd 'ping -I ${BF3_PF0_IFACE} -c ${PING_COUNT} -W 2 ${HOST_PEER} 2>&1'"

ping_test "ToR→BF3 (${TOR_PEER}→${BF3_P0_ADDR})" \
  "ssh_cmd '$TOR_USER' '$TOR_PASS' '$TOR_IP' 'ping ${BF3_P0_ADDR} -c ${PING_COUNT} -W 2 2>&1'"

ping_test "Host→BF3 (${HOST_PEER}→${BF3_PF0_ADDR})" \
  "ssh_cmd '$HOST_USER' '$HOST_PASS' '$HOST_IP' 'ping ${BF3_PF0_ADDR} -c ${PING_COUNT} -W 2 2>&1'"

if [[ "$SETUP" == "true" ]]; then
  ping_test "ToR→Host (cross-subnet: ${TOR_PEER}→${HOST_PEER})" \
    "ssh_cmd '$TOR_USER' '$TOR_PASS' '$TOR_IP' 'ping ${HOST_PEER} -c ${PING_COUNT} -W 2 2>&1'"

  ping_test "Host→ToR (cross-subnet: ${HOST_PEER}→${TOR_PEER})" \
    "ssh_cmd '$HOST_USER' '$HOST_PASS' '$HOST_IP' 'ping ${TOR_PEER} -c ${PING_COUNT} -W 2 2>&1'"
else
  warn "Skipping cross-subnet pings (ToR↔Host) — pass --setup to enable"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo -e "  ${BOLD}Ping Summary${NC}"
echo "============================================================"
printf "  %-45s %-8s %s\n" "Path" "Loss" "Result"
printf "  %-45s %-8s %s\n" "----" "----" "------"
for label in "${!PING_RESULTS[@]}"; do
  loss="${PING_RESULTS[$label]}"
  if [[ "$loss" == "0" ]]; then
    result="${GREEN}PASS${NC}"
  else
    result="${RED}FAIL${NC}"
  fi
  printf "  %-45s %-8s " "$label" "${loss}%"
  echo -e "$result"
done | sort
echo "============================================================"
if [[ $FAILURES -eq 0 ]]; then
  echo -e "  ${GREEN}All checks passed.${NC} Static routing is working."
else
  echo -e "  ${RED}${FAILURES} check(s) failed.${NC}"
  echo ""
  echo "  Troubleshooting:"
  echo "    REST routes:  curl -sk -u ${REST_USER}:${REST_PASS} ${REST_BASE}/vrf/default/router/static | python3 -m json.tool"
  echo "    FRR routes:   CONT=\$(sudo crictl ps -q --name doca-hbn | head -1); sudo crictl exec \$CONT vtysh -c 'show ip route'"
  echo "    Interfaces:   sudo ./topology_hbn.sh"
  echo "    Full status:  sudo ./status_hbn.sh"
fi
echo "  Log saved to: ${LOG_FILE}"
echo ""
exit $((FAILURES > 0 ? 1 : 0))
