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

# ─── Configuration ────────────────────────────────────────────────────────────
X86_HOST_IP="10.20.13.207"       # x86 host — on same subnet as BF3, reachable from DPF VM
X86_HOST_USER="aviz"
X86_HOST_PASS="aviz@123"

KAMAJI_CLUSTER_IP="10.43.62.50"  # Kamaji TenantControlPlane ClusterIP (k3s internal)
KAMAJI_PORT="6443"               # Kamaji API server port

DPF_VM_IP="10.4.5.136"          # DPF Operator VM (this machine) — in kubeadm bfcfg endpoint
BF3_OOB_IP="10.20.13.249"       # BF3 OOB IP
BF3_OOB_PASS="Aviz@AIF12345"    # BF3 ubuntu password
# ──────────────────────────────────────────────────────────────────────────────

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

  # Step 1: Enable GatewayPorts on x86 host sshd
  # By default, SSH reverse tunnels only bind on 127.0.0.1 of the remote host.
  # GatewayPorts yes makes them bind on 0.0.0.0, so the BF3 (a third machine)
  # can connect to the forwarded port on the x86 host.
  info "Step 1 — Enabling GatewayPorts on x86 host sshd (${X86_HOST_IP})..."
  if _ssh 'grep -q "^GatewayPorts yes" /etc/ssh/sshd_config'; then
    ok "GatewayPorts already enabled"
  else
    _ssh 'echo "aviz@123" | sudo -S sed -i "s/#GatewayPorts no/GatewayPorts yes/" /etc/ssh/sshd_config'
    _ssh 'grep -q "^GatewayPorts yes" /etc/ssh/sshd_config' \
      || fail "Failed to set GatewayPorts — check /etc/ssh/sshd_config on ${X86_HOST_IP}"
    _ssh 'echo "aviz@123" | sudo -S systemctl restart sshd'
    ok "GatewayPorts enabled and sshd restarted"
  fi

  # Step 2: Kill any existing tunnel on this port
  pkill -f "ssh.*-R 0.0.0.0:${KAMAJI_PORT}" 2>/dev/null || true

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
  info "Stopping reverse tunnel..."
  if pkill -f "ssh.*-R 0.0.0.0:${KAMAJI_PORT}" 2>/dev/null; then
    ok "Tunnel process killed"
  else
    warn "No tunnel process found"
  fi
}

cmd_status() {
  echo ""
  echo "--- Tunnel process (this DPF VM) ---"
  if pgrep -a -f "ssh.*-R 0.0.0.0:${KAMAJI_PORT}" 2>/dev/null; then
    ok "SSH tunnel process running"
  else
    warn "No SSH tunnel process found"
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
  echo "  # Redirect kubeadm's connection to Kamaji through the tunnel on x86 host."
  echo "  # The endpoint in bfcfg is ${DPF_VM_IP}:${KAMAJI_PORT} (matching the TLS cert SAN)."
  echo "  # This DNAT rewrites the destination transparently so TLS still validates."
  echo ""
  echo "  sudo iptables -t nat -A OUTPUT -d ${DPF_VM_IP} -p tcp --dport ${KAMAJI_PORT} \\"
  echo "    -j DNAT --to-destination ${X86_HOST_IP}:${KAMAJI_PORT}"
  echo ""
  echo "  # Verify (should show DNAT rule):"
  echo "  sudo iptables -t nat -L OUTPUT -n | grep ${KAMAJI_PORT}"
  echo ""
  echo "  # Test connectivity after adding the rule:"
  echo "  timeout 3 bash -c 'echo >/dev/tcp/${DPF_VM_IP}/${KAMAJI_PORT}' && echo 'open' || echo 'closed'"
  echo ""
  echo "  # Then restart kubeadm-join:"
  echo "  sudo rm -f /opt/dpf/joined_cluster_successfully"
  echo "  sudo systemctl restart kubeadm-join.service"
  echo "  sudo journalctl -u kubeadm-join.service -f"
  echo ""
  echo "  # To undo the DNAT rule later:"
  echo "  sudo iptables -t nat -D OUTPUT -d ${DPF_VM_IP} -p tcp --dport ${KAMAJI_PORT} \\"
  echo "    -j DNAT --to-destination ${X86_HOST_IP}:${KAMAJI_PORT}"
  echo ""

  # Offer to run these automatically on the BF3 via x86 host relay
  # (DPF VM → x86 host → ??? — direct SSH to BF3 not possible from here)
  echo "  NOTE: The DPF VM cannot SSH directly to the BF3 (TCP blocked)."
  echo "  Copy and paste the commands above into your BF3 terminal."
  echo ""
}

case "${1:-}" in
  start)  cmd_start ;;
  stop)   cmd_stop  ;;
  status) cmd_status ;;
  bf3)    cmd_bf3   ;;
  *)
    echo "Usage: $0 {start|stop|status|bf3}"
    echo ""
    echo "  start   — enable GatewayPorts on x86 host and open reverse SSH tunnel"
    echo "  stop    — kill the tunnel process"
    echo "  status  — check tunnel health"
    echo "  bf3     — print iptables DNAT commands to run on the BF3"
    echo ""
    echo "Run 'start' before bringup_dpf.sh --rshim-install on a fresh BF3."
    exit 1
    ;;
esac
