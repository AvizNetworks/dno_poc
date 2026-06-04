#!/usr/bin/env bash
# status_dpf.sh — DPF + DPU cluster health check
# Run from any machine with kubectl access to the DPF Operator k3s cluster.
set -euo pipefail

DPF_KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
DPF_NAMESPACE="dpf-operator-system"
BF3_OOB_IP="10.20.13.249"
BF3_OOB_PASS="Aviz@AIF12345"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }

kube() { kubectl --kubeconfig="${DPF_KUBECONFIG}" "$@"; }

echo ""
echo "============================================================"
echo "  DPF Status Check — $(date)"
echo "============================================================"
echo ""

# ─── DPF Operator ─────────────────────────────────────────────────────────────
echo "--- DPF Operator ---"
op_ready=$(kube get deployment dpf-operator-controller-manager -n "${DPF_NAMESPACE}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${op_ready}" -ge 1 ]]; then
  ok "dpf-operator-controller-manager: ${op_ready} replica(s) ready"
else
  fail "dpf-operator-controller-manager: not ready"
fi

# ─── Kamaji ───────────────────────────────────────────────────────────────────
echo ""
echo "--- Kamaji (DPU cluster control plane — kamaji-system) ---"
kamaji_pods=$(kube get pods -n "kamaji-system" \
  --no-headers 2>/dev/null || echo "")
if [[ -z "$kamaji_pods" ]]; then
  warn "No Kamaji pods found in kamaji-system — run: helm install kamaji clastix/kamaji -n kamaji-system --set etcd.deploy=true"
else
  echo "$kamaji_pods" | while read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $3}')
    if [[ "$status" == "Running" ]]; then
      ok "${name}: ${status}"
    else
      warn "${name}: ${status}"
    fi
  done
fi

# ─── BFB ──────────────────────────────────────────────────────────────────────
echo ""
echo "--- BFB Resources ---"
kube get bfb -n "${DPF_NAMESPACE}" \
  -o custom-columns="NAME:.metadata.name,PHASE:.status.phase" \
  --no-headers 2>/dev/null | \
  while read -r name phase; do
    if [[ "$phase" == "Ready" ]]; then
      ok "BFB ${name}: ${phase}"
    else
      warn "BFB ${name}: ${phase}"
    fi
  done || warn "No BFB resources found"

# ─── DPU provisioning ─────────────────────────────────────────────────────────
echo ""
echo "--- DPU Provisioning ---"
kube get dpu -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null | \
  while read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    phase=$(echo "$line" | awk '{print $3}')
    if [[ "$phase" == "Ready" ]]; then
      ok "DPU ${name}: ${phase}"
    elif [[ "$phase" == "Error" ]]; then
      fail "DPU ${name}: ${phase}"
    else
      info "DPU ${name}: ${phase} (provisioning in progress)"
    fi
  done || warn "No DPU resources found"

kube get dpunode -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null | \
  while read -r line; do
    info "DPUNode: ${line}"
  done

kube get dpudevice -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null | \
  while read -r line; do
    info "DPUDevice: ${line}"
  done

# ─── DPU cluster ──────────────────────────────────────────────────────────────
echo ""
echo "--- DPU Cluster ---"
clusters=$(kube get dpuclusters -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null || echo "")
if [[ -z "$clusters" ]]; then
  warn "No DPUCluster resources found yet"
else
  echo "$clusters" | while read -r line; do
    info "DPUCluster: ${line}"
  done

  # Try to get DPU cluster kubeconfig and list its nodes
  secret_name=$(kube get secret -n "${DPF_NAMESPACE}" \
    -o name 2>/dev/null | grep "dpu-cluster-kubeconfig" | head -1 || echo "")
  if [[ -n "$secret_name" ]]; then
    TMPKUBE=$(mktemp /tmp/dpu-kubeconfig-XXXXXX)
    kube get "${secret_name}" -n "${DPF_NAMESPACE}" \
      -o jsonpath='{.data.admin\.conf}' 2>/dev/null | base64 -d > "${TMPKUBE}" 2>/dev/null || true
    if [[ -s "${TMPKUBE}" ]]; then
      echo ""
      echo "--- DPU Cluster Nodes ---"
      kubectl --kubeconfig="${TMPKUBE}" get nodes -o wide 2>/dev/null \
        || warn "Could not reach DPU cluster API"
    fi
    rm -f "${TMPKUBE}"
  fi
fi

# ─── BF3 OOB reachability ─────────────────────────────────────────────────────
echo ""
echo "--- BF3 OOB Reachability (${BF3_OOB_IP}) ---"
if ping -c 1 -W 2 "${BF3_OOB_IP}" &>/dev/null; then
  ok "BF3 OOB ${BF3_OOB_IP}: reachable"
  # Check if kubelet is active via SSH
  _kubelet_status=$(sshpass -p "${BF3_OOB_PASS}" \
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    "ubuntu@${BF3_OOB_IP}" "systemctl is-active kubelet" 2>/dev/null || echo "unknown")
  if [[ "$_kubelet_status" == "active" ]]; then
    ok "BF3 kubelet: active"
  else
    warn "BF3 kubelet: ${_kubelet_status} (run: systemctl is-active kubelet on BF3)"
  fi
else
  warn "BF3 OOB ${BF3_OOB_IP}: unreachable (may be rebooting during provisioning)"
fi

# ─── Stuck etcd-defrag jobs ───────────────────────────────────────────────────
echo ""
stuck=$(kube get jobs -n "${DPF_NAMESPACE}" \
  -l app.kubernetes.io/component=etcd-defrag \
  --field-selector=status.successful=0 \
  --no-headers 2>/dev/null | wc -l)
[[ $stuck -gt 0 ]] \
  && warn "${stuck} stuck etcd-defrag jobs — run bringup_dpf.sh to clean up" \
  || ok "No stuck etcd-defrag jobs"

echo ""
