#!/usr/bin/env bash
# tunnel_dpf.sh — SSH reverse tunnel for DPF → BF3 kubeadm join across subnets
#
# PROBLEM
# ───────
# The DPF Operator VM (10.4.5.136) and the BF3 OOB (10.20.13.249) are on different
# subnets. ICMP (ping) works between them, but TCP is blocked by the lab firewall:
#
#   BF3 (10.20.13.249) ──TCP─→ BLOCKED ──→ DPF VM (10.4.5.136)
#   DPF VM (10.4.5.136) ──TCP─→ ALLOWED ──→ x86 host (10.20.13.207)
#
# The BF3's kubeadm-join.service must reach the Kamaji TenantControlPlane at
# 10.4.5.136:6443 to join the DPU cluster. This fails with "no route to host".
#
# SOLUTION
# ────────
# Use the one-way TCP that DOES work (DPF VM → x86 host) to create a reverse
# SSH tunnel. This exposes Kamaji's API server on the x86 host's IP, which the
# BF3 can reach:
#
#   ┌─────────────────────────────────────────────────────────────────┐
#   │  DPF VM (10.4.5.136)                                            │
#   │    Kamaji ClusterIP: 10.43.62.50:6443                           │
#   │    SSH client → reverse tunnel → x86 host 0.0.0.0:6443         │
#   └───────────────────────────────┬─────────────────────────────────┘
#                                   │ SSH reverse tunnel (TCP allowed)
#   ┌───────────────────────────────▼─────────────────────────────────┐
#   │  x86 host (10.20.13.207)                                        │
#   │    sshd listening: 0.0.0.0:6443 → tunnel → Kamaji              │
#   └───────────────────────────────┬─────────────────────────────────┘
#                                   │ same 10.20.13.x subnet
#   ┌───────────────────────────────▼─────────────────────────────────┐
#   │  BF3 (10.20.13.249)                                             │
#   │    kubeadm join 10.4.5.136:6443 (in bfcfg)                     │
#   │    iptables OUTPUT DNAT: 10.4.5.136:6443 → 10.20.13.207:6443  │
#   │    → TLS validates against 10.4.5.136 (cert SAN matches) ✓     │
#   └─────────────────────────────────────────────────────────────────┘
#
# TLS CERTIFICATE NOTE
# ────────────────────
# The Kamaji TLS cert has SAN: 10.4.5.136, 10.96.0.1, 127.0.0.1.
# If kubeadm connects to 10.20.13.207:6443 directly, TLS fails:
#   "certificate valid for 10.4.5.136, not 10.20.13.207"
#
# Fix: keep the kubeadm endpoint as 10.4.5.136:6443 (matching the cert), and
# add an iptables OUTPUT DNAT on the BF3 that transparently redirects that
# connection to the tunnel on 10.20.13.207:6443. The kernel rewrites the
# destination AFTER the application sets up TLS, so kubeadm's TLS stack
# validates against 10.4.5.136 and the cert passes.
#
# USAGE (run from DPF Operator VM: 10.4.5.136)
# ─────
#   ./tunnel_dpf.sh start    — set up tunnel (run before bringup_dpf.sh --rshim-install)
#   ./tunnel_dpf.sh status   — check if tunnel is active
#   ./tunnel_dpf.sh stop     — tear down tunnel
#   ./tunnel_dpf.sh bf3      — print BF3-side iptables commands to run on the BF3

set -euo pipefail

# ─── Configuration (defaults = S4; override per server via flags) ───────────────
SERVER_NAME="s4"                 # DPU cluster name prefix → <server>-dpu-cluster svc
X86_HOST_IP="10.20.13.207"       # x86 host — on same subnet as BF3, reachable from DPF VM
X86_HOST_USER="aviz"
X86_HOST_PASS="aviz@123"

KAMAJI_CLUSTER_IP=""             # auto-discovered from <server>-dpu-cluster svc if empty
KAMAJI_PORT="6443"               # Kamaji API server port

DPF_VM_IP="10.4.5.136"          # DPF Operator VM (this machine) — in kubeadm bfcfg endpoint
BF3_OOB_IP="10.20.13.249"       # BF3 OOB IP
BF3_OOB_PASS="Aviz@AIF12345"    # BF3 ubuntu password
DPF_NAMESPACE="dpf-operator-system"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
[[ -r "${KUBECONFIG_PATH}" ]] || KUBECONFIG_PATH="${HOME}/.kube/config"
# ──────────────────────────────────────────────────────────────────────────────

# ─── Per-server presets ─────────────────────────────────────────────────────────
# Flags override these. Example: ./tunnel_dpf.sh --server s1 start
apply_server_preset() {
  case "${SERVER_NAME}" in
    s1) X86_HOST_IP="10.20.13.13";  X86_HOST_USER="admin"; X86_HOST_PASS="Aviz@AIF123";
        BF3_OOB_IP="10.20.13.247";  BF3_OOB_PASS="Aviz@AIF12345" ;;
    s2) X86_HOST_IP="10.20.13.12";  X86_HOST_USER="admin"; X86_HOST_PASS="Aviz@AIF123";
        BF3_OOB_IP="10.20.13.228";  BF3_OOB_PASS="Aviz@AIF12345" ;;
    s4) X86_HOST_IP="10.20.13.207"; X86_HOST_USER="aviz";  X86_HOST_PASS="aviz@123";
        BF3_OOB_IP="10.20.13.249";  BF3_OOB_PASS="Aviz@AIF12345" ;;
  esac
}

discover_kamaji_ip() {
  [[ -n "${KAMAJI_CLUSTER_IP}" ]] && return 0
  local ip
  ip=$(KUBECONFIG="${KUBECONFIG_PATH}" kubectl get svc "${SERVER_NAME}-dpu-cluster" \
        -n "${DPF_NAMESPACE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  [[ -n "${ip}" && "${ip}" != "None" ]] \
    || fail "Could not auto-discover Kamaji ClusterIP from svc '${SERVER_NAME}-dpu-cluster' (ns ${DPF_NAMESPACE}). Is the DPUCluster created yet? Pass --kamaji-ip <IP> explicitly."
  KAMAJI_CLUSTER_IP="${ip}"
  info "Discovered Kamaji ClusterIP: ${KAMAJI_CLUSTER_IP} (svc ${SERVER_NAME}-dpu-cluster)"
}

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

_ssh() { sshpass -p "${X86_HOST_PASS}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${X86_HOST_USER}@${X86_HOST_IP}" "$@"; }

cmd_start() {
  echo ""
  echo "============================================================"
  echo "  DPF SSH Tunnel Setup"
  echo "  DPF VM (this host) : ${DPF_VM_IP}"
  echo "  x86 relay host     : ${X86_HOST_IP}"
  echo "  Kamaji ClusterIP   : ${KAMAJI_CLUSTER_IP}:${KAMAJI_PORT}"
  echo "============================================================"
  echo ""

  command -v sshpass &>/dev/null || fail "sshpass not installed — apt install sshpass"
  discover_kamaji_ip

  # Step 1: Enable GatewayPorts on x86 host sshd
  # By default, SSH reverse tunnels only bind on 127.0.0.1 of the remote host.
  # GatewayPorts yes makes them bind on 0.0.0.0, so the BF3 (a third machine)
  # can connect to the forwarded port on the x86 host.
  info "Step 1 — Enabling GatewayPorts on x86 host sshd (${X86_HOST_IP})..."
  if _ssh 'grep -q "^GatewayPorts yes" /etc/ssh/sshd_config'; then
    ok "GatewayPorts already enabled"
  else
    _ssh "echo '${X86_HOST_PASS}' | sudo -S sed -i 's/#GatewayPorts no/GatewayPorts yes/' /etc/ssh/sshd_config"
    _ssh 'grep -q "^GatewayPorts yes" /etc/ssh/sshd_config' \
      || fail "Failed to set GatewayPorts — check /etc/ssh/sshd_config on ${X86_HOST_IP}"
    _ssh "echo '${X86_HOST_PASS}' | sudo -S sh -c 'systemctl restart ssh 2>/dev/null || systemctl restart sshd'"
    ok "GatewayPorts enabled and sshd restarted"
  fi

  # Step 2: Kill only THIS server's existing tunnel (match destination ClusterIP,
  # not just the port) so a second DPU's tunnel on the same VM is left alone.
  pkill -f "ssh.*-R 0.0.0.0:${KAMAJI_PORT}:${KAMAJI_CLUSTER_IP}:" 2>/dev/null || true

  # Step 3: Open reverse tunnel
  # -N         : no remote command — tunnel only
  # -f         : background after auth
  # -R addr:port:host:port
  #              On the remote host (x86), listen on 0.0.0.0:6443.
  #              Forward each connection back through this SSH session to
  #              10.43.62.50:6443 (Kamaji ClusterIP, reachable from this DPF VM).
  # ExitOnForwardFailure=yes : fail immediately if the port is already in use
  info "Step 2 — Starting reverse tunnel: ${X86_HOST_IP}:${KAMAJI_PORT} → ${KAMAJI_CLUSTER_IP}:${KAMAJI_PORT}..."
  sshpass -p "${X86_HOST_PASS}" ssh \
    -N -f \
    -o StrictHostKeyChecking=no \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=10 \
    -R "0.0.0.0:${KAMAJI_PORT}:${KAMAJI_CLUSTER_IP}:${KAMAJI_PORT}" \
    "${X86_HOST_USER}@${X86_HOST_IP}"

  sleep 1

  # Step 4: Verify tunnel is listening on 0.0.0.0 (not just 127.0.0.1)
  info "Step 3 — Verifying tunnel..."
  listen_addr=$(_ssh "ss -tlnp | grep :${KAMAJI_PORT}" 2>/dev/null || echo "")
  if echo "${listen_addr}" | grep -q "0.0.0.0:${KAMAJI_PORT}"; then
    ok "Tunnel active: ${X86_HOST_IP}:${KAMAJI_PORT} → ${KAMAJI_CLUSTER_IP}:${KAMAJI_PORT}"
  else
    fail "Tunnel port not listening on 0.0.0.0 — check GatewayPorts and sshd on ${X86_HOST_IP}"
  fi

  echo ""
  ok "Tunnel is ready."
  echo ""
  echo "  Next step: run the BF3-side iptables rule so kubeadm TLS works:"
  echo ""
  echo "    ./tunnel_dpf.sh bf3"
  echo ""
}

cmd_stop() {
  discover_kamaji_ip
  info "Stopping reverse tunnel for ${SERVER_NAME} (Kamaji ${KAMAJI_CLUSTER_IP})..."
  if pkill -f "ssh.*-R 0.0.0.0:${KAMAJI_PORT}:${KAMAJI_CLUSTER_IP}:" 2>/dev/null; then
    ok "Tunnel process killed"
  else
    warn "No tunnel process found for ${SERVER_NAME}"
  fi
}

cmd_status() {
  discover_kamaji_ip
  echo ""
  echo "--- Tunnel process (this DPF VM) for ${SERVER_NAME} → ${KAMAJI_CLUSTER_IP} ---"
  if pgrep -a -f "ssh.*-R 0.0.0.0:${KAMAJI_PORT}:${KAMAJI_CLUSTER_IP}:" 2>/dev/null; then
    ok "SSH tunnel process running"
  else
    warn "No SSH tunnel process found for ${SERVER_NAME}"
  fi

  echo ""
  echo "--- x86 host listening (${X86_HOST_IP}) ---"
  command -v sshpass &>/dev/null || { warn "sshpass not installed — cannot check remote"; return; }
  listen=$(_ssh "ss -tlnp | grep :${KAMAJI_PORT}" 2>/dev/null || echo "")
  if echo "${listen}" | grep -q "0.0.0.0:${KAMAJI_PORT}"; then
    ok "Port ${KAMAJI_PORT} listening on 0.0.0.0 at ${X86_HOST_IP} ✓"
  elif echo "${listen}" | grep -q "127.0.0.1:${KAMAJI_PORT}"; then
    warn "Port ${KAMAJI_PORT} listening on 127.0.0.1 only — GatewayPorts not active"
  else
    warn "Port ${KAMAJI_PORT} not listening on ${X86_HOST_IP}"
  fi

  echo ""
  echo "--- TCP reachability from DPF VM ---"
  if timeout 3 bash -c "echo >/dev/tcp/${X86_HOST_IP}/${KAMAJI_PORT}" 2>/dev/null; then
    ok "TCP ${X86_HOST_IP}:${KAMAJI_PORT} reachable from this host"
  else
    warn "TCP ${X86_HOST_IP}:${KAMAJI_PORT} not reachable from this host"
  fi
  echo ""
}

cmd_bf3() {
  # Print the commands to run on the BF3 (ubuntu@10.20.13.249).
  # These cannot be run automatically because the DPF VM can't SSH to the BF3
  # (TCP from 10.4.5.x to 10.20.13.x is blocked).
  #
  # WHY DNAT instead of just changing the kubeadm endpoint to 10.20.13.207:6443:
  #   If kubeadm connects to 10.20.13.207:6443, TLS fails because the Kamaji cert
  #   only has SAN for 10.4.5.136. By keeping the endpoint as 10.4.5.136:6443 and
  #   transparently redirecting at the kernel level with OUTPUT DNAT, kubeadm's TLS
  #   stack validates against 10.4.5.136 — which IS in the cert. The DNAT rewrite
  #   happens below the TLS layer, so the application never sees the real destination.
  echo ""
  echo "============================================================"
  echo "  BF3-side iptables setup"
  echo "  Run these commands on: ubuntu@${BF3_OOB_IP}"
  echo "============================================================"
  echo ""
  echo "  NOTE: These rules are ONLY needed when DPF VM and BF3 are on different"
  echo "  subnets (e.g. 10.4.5.x vs 10.20.13.x). Same-network deployments: skip."
  echo "  All 3 rules are lost on BF3 reboot — re-run this after each reboot."
  echo ""
  echo "  ── Rule 1: kubeadm join (run BEFORE bringup_dpf.sh --rshim-install) ──"
  echo "  # Redirects kubeadm's TLS connection through the tunnel."
  echo "  # Keeps endpoint as ${DPF_VM_IP}:${KAMAJI_PORT} so TLS cert SAN matches."
  echo ""
  echo "  sudo iptables -t nat -I OUTPUT 1 -d ${DPF_VM_IP} -p tcp --dport ${KAMAJI_PORT} \\"
  echo "    -j DNAT --to-destination ${X86_HOST_IP}:${KAMAJI_PORT}"
  echo ""
  echo "  ── Rule 2: host processes → API server (run AFTER BF3 boots) ─────────"
  echo "  # Redirects flannel, kubelet, host binaries connecting to"
  echo "  # 10.96.0.1:443 (kubernetes.default.svc ClusterIP) through the tunnel."
  echo "  # kube-proxy would DNAT 10.96.0.1 → ${DPF_VM_IP}:${KAMAJI_PORT} (unreachable)."
  echo "  # This rule fires first (position 1 in OUTPUT) and bypasses kube-proxy."
  echo ""
  echo "  sudo iptables -t nat -I OUTPUT 1 -d 10.96.0.1 -p tcp --dport 443 \\"
  echo "    -j DNAT --to-destination ${X86_HOST_IP}:${KAMAJI_PORT}"
  echo ""
  echo "  ── Rule 3: pod traffic → API server (run AFTER BF3 boots) ───────────"
  echo "  # Same fix for traffic FROM pods (uses PREROUTING, not OUTPUT)."
  echo "  # Without this: flannel, sfc-controller, nvidia-ipam pods CrashLoopBackOff."
  echo ""
  echo "  sudo iptables -t nat -I PREROUTING 1 -d 10.96.0.1 -p tcp --dport 443 \\"
  echo "    -j DNAT --to-destination ${X86_HOST_IP}:${KAMAJI_PORT}"
  echo ""
  echo "  ── Verify all 3 rules ─────────────────────────────────────────────────"
  echo "  sudo iptables -t nat -L OUTPUT -n --line-numbers | head -6"
  echo "  sudo iptables -t nat -L PREROUTING -n --line-numbers | head -4"
  echo "  curl -k --max-time 5 https://10.96.0.1/version | grep gitVersion"
  echo ""

  # Offer to run these automatically on the BF3 via x86 host relay
  # (DPF VM → x86 host → ??? — direct SSH to BF3 not possible from here)
  echo "  NOTE: The DPF VM cannot SSH directly to the BF3 (TCP blocked)."
  echo "  Copy and paste the commands above into your BF3 terminal."
  echo ""
}

ACTION=""
# Explicit-override holders (empty = not set on command line)
_o_x86_host=""; _o_x86_user=""; _o_x86_pass=""; _o_bf3_oob=""; _o_bf3_pass=""; _o_dpf_vm=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)    SERVER_NAME="$2"; shift 2 ;;
    --x86-host)  _o_x86_host="$2"; shift 2 ;;
    --x86-user)  _o_x86_user="$2"; shift 2 ;;
    --x86-pass)  _o_x86_pass="$2"; shift 2 ;;
    --bf3-oob)   _o_bf3_oob="$2"; shift 2 ;;
    --bf3-pass)  _o_bf3_pass="$2"; shift 2 ;;
    --kamaji-ip) KAMAJI_CLUSTER_IP="$2"; shift 2 ;;
    --dpf-vm)    _o_dpf_vm="$2"; shift 2 ;;
    start|stop|status|bf3) ACTION="$1"; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# Preset first (by --server), then explicit flags win.
apply_server_preset
[[ -n "${_o_x86_host}" ]] && X86_HOST_IP="${_o_x86_host}"
[[ -n "${_o_x86_user}" ]] && X86_HOST_USER="${_o_x86_user}"
[[ -n "${_o_x86_pass}" ]] && X86_HOST_PASS="${_o_x86_pass}"
[[ -n "${_o_bf3_oob}"  ]] && BF3_OOB_IP="${_o_bf3_oob}"
[[ -n "${_o_bf3_pass}" ]] && BF3_OOB_PASS="${_o_bf3_pass}"
[[ -n "${_o_dpf_vm}"   ]] && DPF_VM_IP="${_o_dpf_vm}"

case "${ACTION}" in
  start)  cmd_start ;;
  stop)   cmd_stop  ;;
  status) cmd_status ;;
  bf3)    cmd_bf3   ;;
  *)
    echo "Usage: $0 [--server s1|s2|s4] [--x86-host IP] [--x86-user U] [--x86-pass P]"
    echo "          [--bf3-oob IP] [--bf3-pass P] [--kamaji-ip IP] [--dpf-vm IP] {start|stop|status|bf3}"
    echo ""
    echo "  start   — enable GatewayPorts on x86 host and open reverse SSH tunnel"
    echo "  stop    — kill the tunnel process"
    echo "  status  — check tunnel health"
    echo "  bf3     — print iptables DNAT commands to run on the BF3"
    echo ""
    echo "  --server applies a preset (x86 host/user/pass + BF3 OOB). Explicit flags override."
    echo "  Kamaji ClusterIP is auto-discovered from <server>-dpu-cluster svc unless --kamaji-ip given."
    echo ""
    echo "  Example (S1 from DPF VM 10.4.5.136):"
    echo "    ./tunnel_dpf.sh --server s1 start"
    echo ""
    echo "Run 'start' before bringup_dpf.sh --rshim-install on a fresh BF3."
    exit 1
    ;;
esac
