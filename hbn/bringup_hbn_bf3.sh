#!/usr/bin/env bash
# bringup_hbn_bf3.sh — Idempotent HBN bringup for BlueField-3 DPU (DOCA 3.3.0)
# Run on BF3 with sudo: sudo ./bringup_hbn_bf3.sh [options]
set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
BF3_PCI0="0000:03:00.0"
BF3_PCI1="0000:03:00.1"
HBN_POD_SPEC="/etc/kubelet.d/doca_hbn.yaml"
MLX_SF_CONF="/etc/mellanox/mlnx-sf.conf"
LOG_DIR="/var/log/doca/hbn"
WAIT_TIMEOUT=300
ENABLE_BGP=false
REST_USER="nvidia"
REST_PASS="nvidia"
HBN_SCRIPTS_DIR=""
SKIP_DNS_FIX=false

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  --enable-bgp               Enable bgpd in FRR daemons (default: off)
  --rest-user <user>         REST API username (default: nvidia)
  --rest-pass <pass>         REST API password (default: nvidia)
  --hbn-scripts-dir <path>   Path to directory containing hbn-dpu-setup.sh
  --skip-dns-fix             Skip adding nameserver 8.8.8.8 to resolv.conf
  -h, --help                 Show this help

Examples:
  sudo $0
  sudo $0 --enable-bgp --rest-user admin --rest-pass MyPass123
  sudo $0 --hbn-scripts-dir /home/ubuntu/hbn-scripts
EOF
  exit 0
}

# ─── Arg parsing ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --enable-bgp)       ENABLE_BGP=true ;;
    --rest-user)        REST_USER="$2"; shift ;;
    --rest-pass)        REST_PASS="$2"; shift ;;
    --hbn-scripts-dir)  HBN_SCRIPTS_DIR="$2"; shift ;;
    --skip-dns-fix)     SKIP_DNS_FIX=true ;;
    -h|--help)          usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

[[ $EUID -ne 0 ]] && fail "This script must be run as root (sudo)"

echo ""
echo "============================================================"
echo "  HBN BF3 Bringup — DOCA 3.3.0"
echo "  $(date)"
echo "============================================================"
echo ""

# ─── Step 1: eswitch switchdev mode ──────────────────────────────────────────
info "Step 1/11 — Verifying eswitch switchdev mode"
for BF3_PCI in "$BF3_PCI0" "$BF3_PCI1"; do
  if devlink dev eswitch show "pci/$BF3_PCI" 2>/dev/null | grep "^pci/$BF3_PCI" | grep -q "mode switchdev"; then
    ok "pci/$BF3_PCI eswitch mode: switchdev"
  else
    fail "pci/$BF3_PCI eswitch NOT in switchdev mode. Run: devlink dev eswitch set pci/$BF3_PCI mode switchdev"
  fi
done

# ─── Step 2: DNS fix ─────────────────────────────────────────────────────────
info "Step 2/11 — Checking DNS"
if [[ "$SKIP_DNS_FIX" == "true" ]]; then
  warn "Skipping DNS fix (--skip-dns-fix)"
elif grep -q "8.8.8.8" /etc/resolv.conf 2>/dev/null; then
  ok "DNS already has 8.8.8.8"
else
  echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  ok "Added nameserver 8.8.8.8 to /etc/resolv.conf"
fi

# ─── Step 3: apparmor-utils ──────────────────────────────────────────────────
info "Step 3/11 — Checking apparmor-utils"
if dpkg -l apparmor-utils 2>/dev/null | grep -q "^ii"; then
  ok "apparmor-utils already installed"
else
  info "Installing apparmor-utils..."
  apt-get install -y apparmor-utils
  ok "apparmor-utils installed"
fi

# ─── Step 4: hostPath directories ────────────────────────────────────────────
info "Step 4/11 — Creating hostPath directories"
mkdir -p \
  /var/lib/hbn/etc/nvue.d \
  /var/lib/hbn/etc/frr \
  /var/lib/hbn/etc/network \
  /var/lib/hbn/etc/cumulus \
  /var/lib/hbn/etc/hbn-users \
  /var/lib/hbn/etc/supervisor/conf.d \
  /var/lib/hbn/var/lib/nvue \
  /var/lib/hbn/var/support \
  /var/log/doca/hbn
ok "hostPath directories ready"

# ─── Step 5: Pull container image ────────────────────────────────────────────
info "Step 5/11 — Checking doca_hbn container image"
if crictl images 2>/dev/null | grep -q "doca_hbn\|doca-hbn"; then
  ok "doca_hbn image already present"
else
  if [[ -f "$HBN_POD_SPEC" ]]; then
    IMAGE=$(grep -i "image:" "$HBN_POD_SPEC" | head -1 | awk '{print $2}')
    info "Pulling $IMAGE ..."
    crictl pull "$IMAGE"
    ok "Image pulled"
  else
    warn "Pod spec $HBN_POD_SPEC not found — skipping image pull"
  fi
fi

# ─── Step 6: Provision SFs ───────────────────────────────────────────────────
info "Step 6/11 — Checking SF provisioning (sfnum 2, 3, 1514, 1515)"
if devlink port show 2>/dev/null | grep -q "sfnum 2"; then
  ok "SFs already provisioned"
else
  if [[ -f "$MLX_SF_CONF" ]]; then
    info "Running mlnx-sf.conf to provision SFs..."
    bash "$MLX_SF_CONF"
    sleep 5
    if devlink port show 2>/dev/null | grep -q "sfnum 2"; then
      ok "SFs provisioned successfully"
    else
      warn "SFs may still be initializing — continuing"
    fi
  else
    fail "$MLX_SF_CONF not found — cannot provision SFs"
  fi
fi

# ─── Step 7: Wait for doca-hbn pod ───────────────────────────────────────────
info "Step 7/11 — Waiting for doca-hbn container to be Running (timeout: ${WAIT_TIMEOUT}s)"
ELAPSED=0
while true; do
  if crictl ps 2>/dev/null | grep "doca-hbn" | grep -v init | grep -q "Running"; then
    ok "doca-hbn container is Running"
    break
  fi
  if [[ $ELAPSED -ge $WAIT_TIMEOUT ]]; then
    fail "Timed out waiting for doca-hbn pod. Check: journalctl -u kubelet -f | grep hbn"
  fi
  echo -n "."
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done
echo ""

CONT=$(crictl ps -q --name doca-hbn 2>/dev/null | head -1 || true)
[[ -z "$CONT" ]] && fail "Could not get doca-hbn container ID"
info "Container ID: $CONT"

# ─── Step 8: Bring up interfaces inside container ────────────────────────────
info "Step 8/11 — Bringing up HBN interfaces inside container"
for iface in p0_if p1_if pf0hpf_if pf1hpf_if; do
  STATE=$(crictl exec "$CONT" ip link show "$iface" 2>/dev/null | grep -o "state [A-Z]*" | awk '{print $2}')
  if [[ "$STATE" == "UP" ]]; then
    ok "$iface already UP"
  else
    crictl exec "$CONT" ip link set "$iface" up 2>/dev/null && ok "$iface brought UP" || warn "$iface: could not set UP"
  fi
done

# ─── Step 9: Enable BGP ──────────────────────────────────────────────────────
info "Step 9/11 — BGP configuration"
FRR_DAEMONS="/var/lib/hbn/etc/frr/daemons"
if [[ "$ENABLE_BGP" == "true" ]]; then
  if [[ -f "$FRR_DAEMONS" ]]; then
    if grep -q "bgpd=yes" "$FRR_DAEMONS"; then
      ok "bgpd already enabled"
    else
      sed -i 's/bgpd=no/bgpd=yes/' "$FRR_DAEMONS"
      crictl exec "$CONT" supervisorctl restart watchfrr 2>/dev/null || \
        crictl exec "$CONT" bash -c "watchfrr.sh restart bgpd 2>/dev/null" || true
      ok "bgpd enabled in $FRR_DAEMONS"
    fi
  else
    warn "$FRR_DAEMONS not found — skipping BGP enable"
  fi
else
  ok "BGP not requested (use --enable-bgp to enable)"
fi

# ─── Step 10: Enable REST API ────────────────────────────────────────────────
info "Step 10/11 — REST API setup"
if [[ -n "$HBN_SCRIPTS_DIR" && -f "$HBN_SCRIPTS_DIR/hbn-dpu-setup.sh" ]]; then
  if [[ ! -f "$HBN_SCRIPTS_DIR/encrypt_password.py" ]]; then
    warn "encrypt_password.py not found in $HBN_SCRIPTS_DIR"
  fi
  cp "$HBN_SCRIPTS_DIR/encrypt_password.py" /home/ubuntu/ 2>/dev/null || true
  (cd "$HBN_SCRIPTS_DIR" && sudo ./hbn-dpu-setup.sh -u "$REST_USER" -p "$REST_PASS" -e)
  ok "REST API enabled (user: $REST_USER)"
elif curl -sk -u "${REST_USER}:${REST_PASS}" "https://localhost:8765/nvue_v1/system" 2>/dev/null | grep -q "build"; then
  ok "REST API already accessible (user: $REST_USER)"
else
  warn "REST API not configured — re-run with --hbn-scripts-dir <path-to-hbn-dpu-setup.sh>"
fi

# ─── Step 11: Summary ────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Bringup Complete — Summary"
echo "============================================================"

OOB_IP=$(ip addr show oob_net0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || echo "unknown")

SF_COUNT=$(devlink port show 2>/dev/null | grep -c "sfnum [0-9]" || echo 0)
FLOW_COUNT=$(ovs-appctl dpctl/dump-flows type=offloaded 2>/dev/null | grep -c "actions:" || echo 0)

echo ""
printf "  %-25s %s\n" "doca-hbn container:" "Running ($CONT)"
printf "  %-25s %s\n" "SFs provisioned:" "$SF_COUNT (expect 6)"
printf "  %-25s %s\n" "OVS offloaded flows:" "$FLOW_COUNT"
printf "  %-25s %s\n" "OOB IP:" "$OOB_IP"
printf "  %-25s %s\n" "REST API:" "https://${OOB_IP}:8765/nvue_v1/"
printf "  %-25s %s\n" "REST credentials:" "${REST_USER}:${REST_PASS}"
echo ""
echo "  Next steps:"
echo "    sudo crictl exec -it $CONT vtysh          # FRR CLI"
echo "    sudo crictl exec -it $CONT nv              # NVUE CLI"
echo "    ./topology_hbn.sh                          # Interface reference"
echo "    ./status_hbn.sh                            # Full health check"
echo ""
