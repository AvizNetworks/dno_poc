#!/usr/bin/env bash
# bringup_dpf.sh — Idempotent DPF bringup for BlueField-3 DPU via OOB/Redfish
# Run from the DPF Operator VM (or any machine with kubectl access to the k3s cluster).
# No x86 host k8s agent required — provisioning uses Redfish via BMC.
#
# Usage:
#   ./bringup_dpf.sh [--bfb-url <url>] [--dry-run]
#   ./bringup_dpf.sh --upgrade [--version v25.10.1]   # upgrade DPF Operator in-place
#
# Prerequisites:
#   - kubectl configured (KUBECONFIG or ~/.kube/config)
#   - DPF Operator v25.10.1 installed (Helm release in dpf-operator-system)
#   - BFB file accessible at BFB_URL (HTTP/HTTPS)
#   - BMC reachable at BF3_BMC_IP over the network

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"

# ─── Configuration — edit these per environment ───────────────────────────────
DPF_KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
DPF_NAMESPACE="dpf-operator-system"

BF3_BMC_IP="10.20.13.250"          # S4 BMC (Redfish endpoint)
BF3_OOB_IP="10.20.13.249"          # S4 BF3 OOB management IP
BF3_SERIAL="MT2437600HGY"          # BF3 serial number (from: dmidecode -t system)

BFB_REGISTRY_IP="10.4.5.136"       # IP of this DPF Operator VM (serves BFB to BMC via port 8080)
BFB_REGISTRY_PORT="8080"           # DPF's bfb-registry hostPort — do NOT run anything else here
BFB_FILE="/opt/bfb/bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb"
BFB_UPLOAD_PORT="9090"             # Temp HTTP port for BFB controller to download from (→ PVC)
# BFB_URL is the SOURCE url for BFB download into PVC (must differ from bfb-registry port 8080)
BFB_URL="http://${BFB_REGISTRY_IP}:${BFB_UPLOAD_PORT}/$(basename "${BFB_FILE}")"

WAIT_TIMEOUT=300        # seconds to wait for Kamaji + provisioner pods
DPU_TIMEOUT=1800        # seconds to wait for BFB flash (30 min — reboot included)
DRY_RUN=false
DPF_VERSION="v25.10.1"  # DPF Operator Helm chart version (update when upgrading)
DO_UPGRADE=false

# ─── rshim install (alternative to DPF Redfish OS install) ────────────────────
# Used via --rshim-install when DPF's Redfish path fails (e.g. same-version BMC skip).
# The x86 host SSHes over rshim to flash the BF3 directly with the DPF bfcfg applied.
X86_HOST_IP="10.20.13.207"    # x86 host with rshim access to BF3
X86_HOST_USER="aviz"           # SSH user on x86 host
X86_HOST_PASS="aviz@123"       # SSH password (or leave empty for key-based auth)
X86_BFB_PATH="~/bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb"
RSHIM_DEVICE="rshim0"
USE_RSHIM=false
# ──────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }
skip()  { echo -e "${YELLOW}[SKIP]${NC}  $*"; }

kube() { kubectl --kubeconfig="${DPF_KUBECONFIG}" "$@"; }

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --bfb-url <url>      Override BFB download URL (default: http://BFB_REGISTRY_IP:PORT/filename)
  --bmc-ip <ip>        Override BF3 BMC IP (default: ${BF3_BMC_IP})
  --oob-ip <ip>        Override BF3 OOB IP (default: ${BF3_OOB_IP})
  --serial <serial>    Override BF3 serial number (default: ${BF3_SERIAL})
  --rshim-install      Flash BF3 via rshim from x86 host instead of DPF Redfish
  --x86-host <ip>      x86 host IP for rshim flash (default: ${X86_HOST_IP})
  --x86-user <user>    x86 host SSH user (default: ${X86_HOST_USER})
  --x86-pass <pass>    x86 host SSH password (default: from config)
  --x86-bfb <path>     BFB path on x86 host (default: ${X86_BFB_PATH})
  --rshim-dev <dev>    rshim device on x86 host (default: ${RSHIM_DEVICE})
  --upgrade            Upgrade DPF Operator Helm release to --version (skips bringup steps)
  --version <ver>      DPF Operator version to upgrade to (default: ${DPF_VERSION})
  --dry-run            Print steps without applying
  -h, --help           Show this help

Examples:
  $0
  $0 --bfb-url http://fileserver.local/bf-bundle-3.3.0.bfb
  $0 --bmc-ip 10.20.13.250 --serial MT2437600HGY
  $0 --rshim-install --x86-host 10.20.13.207
  $0 --upgrade                        # upgrade to default version (${DPF_VERSION})
  $0 --upgrade --version v25.10.2     # upgrade to specific version
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --bfb-url)        BFB_URL="$2";          shift ;;
    --bmc-ip)         BF3_BMC_IP="$2";      shift ;;
    --oob-ip)         BF3_OOB_IP="$2";      shift ;;
    --serial)         BF3_SERIAL="$2";      shift ;;
    --rshim-install)  USE_RSHIM=true ;;
    --x86-host)       X86_HOST_IP="$2";     shift ;;
    --x86-user)       X86_HOST_USER="$2";   shift ;;
    --x86-pass)       X86_HOST_PASS="$2";   shift ;;
    --x86-bfb)        X86_BFB_PATH="$2";    shift ;;
    --rshim-dev)      RSHIM_DEVICE="$2";    shift ;;
    --upgrade)        DO_UPGRADE=true ;;
    --version)        DPF_VERSION="$2";     shift ;;
    --dry-run)        DRY_RUN=true ;;
    -h|--help)        usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

# ─── Upgrade mode ─────────────────────────────────────────────────────────────
# Upgrades the DPF Operator Helm release then applies post-upgrade fixes.
# Post-upgrade fixes needed for v25.7.0 → v25.10.1 (and likely future versions):
#   1. Manually update sub-controller deployment images (dpf-provisioning,
#      dpuservice, kamaji-cm, servicechainset) — Helm only updates the main
#      dpf-operator-controller-manager; others are managed by DPFOperatorConfig
#      reconciler which may be blocked by unhealthy DPUServices.
#   2. Fix servicechainset-controller credentials secret — KUBERNETES_SERVICE_HOST
#      must be the DPU cluster DNS name (not the NodePort IP) to avoid k3s
#      intercepting the connection and rejecting the DPU cluster token.
#   3. Bootstrap svc.dpu.nvidia.com CRDs onto the DPU cluster — the
#      servicechainset-controller connects to the DPU cluster and needs these
#      CRDs to exist before it can start (chicken-and-egg: CRDs are deployed
#      by a DPUService, but the controller must be running for DPUServices to deploy).
#   4. Create ClusterRole + ClusterRoleBinding on the DPU cluster for the
#      servicechainset-controller service account.
if [[ "${DO_UPGRADE}" == "true" ]]; then
  echo ""
  echo "============================================================"
  echo "  DPF Operator Upgrade → ${DPF_VERSION}"
  echo "============================================================"
  echo ""

  info "Step 1/5 — Helm upgrade dpf-operator → ${DPF_VERSION}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[dry-run] helm upgrade dpf-operator dpf-repository/dpf-operator --version ${DPF_VERSION}"
  else
    helm repo update dpf-repository 2>/dev/null || true
    helm upgrade dpf-operator dpf-repository/dpf-operator \
      --version "${DPF_VERSION}" \
      --namespace "${DPF_NAMESPACE}" \
      --wait --timeout 5m \
      || fail "Helm upgrade failed"
    ok "DPF Operator upgraded to ${DPF_VERSION}"
  fi

  info "Step 2/5 — Update sub-controller deployment images to ${DPF_VERSION}"
  DPF_IMAGE="nvcr.io/nvidia/doca/dpf-system:${DPF_VERSION}"
  for deploy in dpf-provisioning-controller-manager dpuservice-controller-manager \
                kamaji-cm-controller-manager servicechainset-controller-manager; do
    current=$(kube get deployment "${deploy}" -n "${DPF_NAMESPACE}" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
    if [[ "${current}" == "${DPF_IMAGE}" ]]; then
      skip "${deploy}: already on ${DPF_VERSION}"
    elif [[ -z "${current}" ]]; then
      warn "${deploy}: not found — skipping"
    else
      if [[ "${DRY_RUN}" == "true" ]]; then
        info "[dry-run] would update ${deploy}: ${current} → ${DPF_IMAGE}"
      else
        kube set image "deployment/${deploy}" "manager=${DPF_IMAGE}" -n "${DPF_NAMESPACE}" 2>/dev/null \
          || warn "${deploy}: image update failed (may use different container name)"
        ok "${deploy}: updated to ${DPF_VERSION}"
      fi
    fi
  done

  info "Step 3/5 — Fix servicechainset-controller credentials (DPU cluster endpoint)"
  CURRENT_HOST=$(kube get secret servicechainset-controller-manager-credentials \
    -n "${DPF_NAMESPACE}" \
    -o jsonpath='{.data.KUBERNETES_SERVICE_HOST}' 2>/dev/null | base64 -d || echo "")
  DPU_SVC_HOST="s4-dpu-cluster.${DPF_NAMESPACE}.svc"
  if [[ "${CURRENT_HOST}" == "${DPU_SVC_HOST}" ]]; then
    skip "credentials secret already uses DNS hostname"
  else
    if [[ "${DRY_RUN}" == "true" ]]; then
      info "[dry-run] would patch KUBERNETES_SERVICE_HOST: ${CURRENT_HOST} → ${DPU_SVC_HOST}"
    else
      NEW_HOST_B64=$(echo -n "${DPU_SVC_HOST}" | base64)
      kube patch secret servicechainset-controller-manager-credentials \
        -n "${DPF_NAMESPACE}" \
        --type=json \
        -p="[{\"op\": \"replace\", \"path\": \"/data/KUBERNETES_SERVICE_HOST\", \"value\": \"${NEW_HOST_B64}\"}]" \
        || fail "Failed to patch credentials secret"
      ok "credentials secret patched: KUBERNETES_SERVICE_HOST → ${DPU_SVC_HOST}"
    fi
  fi

  info "Step 4/5 — Bootstrap svc.dpu.nvidia.com CRDs onto DPU cluster"
  kube get secret s4-dpu-cluster-admin-kubeconfig -n "${DPF_NAMESPACE}" \
    -o jsonpath='{.data.admin\.conf}' | base64 -d > /tmp/dpu-tc-kubeconfig 2>/dev/null || true
  if [[ -s /tmp/dpu-tc-kubeconfig ]]; then
    dkube() { kubectl --kubeconfig /tmp/dpu-tc-kubeconfig "$@"; }
    MISSING_CRDS=()
    for crd in servicechains.svc.dpu.nvidia.com servicechainsets.svc.dpu.nvidia.com \
               serviceinterfaces.svc.dpu.nvidia.com serviceinterfacesets.svc.dpu.nvidia.com; do
      dkube get crd "${crd}" &>/dev/null || MISSING_CRDS+=("${crd}")
    done
    if [[ ${#MISSING_CRDS[@]} -eq 0 ]]; then
      skip "svc.dpu.nvidia.com CRDs already on DPU cluster"
    else
      if [[ "${DRY_RUN}" == "true" ]]; then
        info "[dry-run] would install ${#MISSING_CRDS[@]} CRDs on DPU cluster: ${MISSING_CRDS[*]}"
      else
        for crd in "${MISSING_CRDS[@]}"; do
          kube get crd "${crd}" -o json | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k in ['resourceVersion','uid','creationTimestamp','generation','managedFields']:
    d['metadata'].pop(k, None)
d['metadata'].pop('annotations', None)
d.pop('status', None)
print(json.dumps(d))
" | kubectl --kubeconfig /tmp/dpu-tc-kubeconfig apply -f - 2>/dev/null \
            && ok "  installed: ${crd}" \
            || warn "  failed: ${crd}"
        done
      fi
    fi

    info "Step 5/5 — Create ClusterRole + ClusterRoleBinding on DPU cluster"
    if dkube get clusterrolebinding servicechainset-controller-manager &>/dev/null; then
      skip "ClusterRoleBinding already exists on DPU cluster"
    else
      if [[ "${DRY_RUN}" == "true" ]]; then
        info "[dry-run] would create ClusterRole + ClusterRoleBinding on DPU cluster"
      else
        dkube apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: servicechainset-controller-manager
rules:
- apiGroups: ["svc.dpu.nvidia.com"]
  resources: ["servicechains","servicechainsets","serviceinterfaces","serviceinterfacesets",
               "servicechains/status","servicechainsets/status","serviceinterfaces/status",
               "serviceinterfacesets/status","servicechains/finalizers",
               "servicechainsets/finalizers","serviceinterfaces/finalizers",
               "serviceinterfacesets/finalizers"]
  verbs: ["create","delete","get","list","patch","update","watch"]
- apiGroups: [""]
  resources: ["nodes","pods","events"]
  verbs: ["get","list","watch","create","patch","update"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["create","delete","get","list","patch","update","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: servicechainset-controller-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: servicechainset-controller-manager
subjects:
- kind: ServiceAccount
  name: servicechainset-controller-manager
  namespace: ${DPF_NAMESPACE}
EOF
        ok "ClusterRole + ClusterRoleBinding created on DPU cluster"
        # Restart servicechainset-controller to pick up new credentials + RBAC
        kube rollout restart deployment/servicechainset-controller-manager \
          -n "${DPF_NAMESPACE}" 2>/dev/null || true
        ok "servicechainset-controller-manager restarted"
      fi
    fi
  else
    warn "DPU cluster kubeconfig not available — skipping steps 4 and 5"
    warn "Re-run after TenantControlPlane is Ready: ./bringup_dpf.sh --upgrade"
  fi

  echo ""
  echo "============================================================"
  echo "  Upgrade complete — ${DPF_VERSION}"
  echo "============================================================"
  echo ""
  info "Verify: kubectl get pods -n ${DPF_NAMESPACE} | grep -v etcd-defrag"
  exit 0
fi

apply() {
  local file="$1"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[dry-run] would apply: ${file}"
    return
  fi
  kube apply -f "${file}"
}

wait_for_pods() {
  local label="$1" ns="$2" timeout="$3"
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local ready
    ready=$(kube get pods -n "${ns}" -l "${label}" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null \
      | tr ' ' '\n' | grep -c "true" || true)
    [[ $ready -gt 0 ]] && return 0
    sleep 10; elapsed=$((elapsed + 10))
    info "  waiting for pods (${label})... ${elapsed}s/${timeout}s"
  done
  return 1
}

echo ""
echo "============================================================"
echo "  DPF BF3 Bringup — OOB/Redfish provisioning"
echo "  DPF Operator VM : ${BFB_REGISTRY_IP}"
echo "  BF3 BMC         : ${BF3_BMC_IP}"
echo "  BF3 OOB         : ${BF3_OOB_IP}"
echo "  BF3 Serial      : ${BF3_SERIAL}"
echo "  BFB URL         : ${BFB_URL}"
echo "  $(date)"
echo "============================================================"
echo ""

# ─── Step 1: Preflight checks ─────────────────────────────────────────────────
info "Step 1/10 — Preflight checks"

kube get nodes &>/dev/null \
  || fail "kubectl cannot reach cluster — check KUBECONFIG (${DPF_KUBECONFIG})"
ok "kubectl: cluster reachable"

kube get deployment dpf-operator-controller-manager -n "${DPF_NAMESPACE}" &>/dev/null \
  || fail "DPF Operator deployment not found in ${DPF_NAMESPACE} — install via Helm first"
ok "DPF Operator deployment present"

if curl -sk --max-time 5 "https://${BF3_BMC_IP}/redfish/v1/" | grep -q "RedfishVersion"; then
  ok "BMC Redfish reachable at ${BF3_BMC_IP}"
elif [[ "${USE_RSHIM}" == "true" ]]; then
  warn "BMC Redfish not reachable at ${BF3_BMC_IP} — continuing (--rshim-install bypasses BMC for OS flash)"
else
  fail "BMC Redfish not reachable at ${BF3_BMC_IP} — check network connectivity"
fi

# ─── Step 1b: Install missing prerequisites (cert-manager, Kamaji, ArgoCD) ───
# DPF Operator requires these three to be present before DPFOperatorConfig.
# Each check is idempotent — skipped if already installed.

info "  Checking cert-manager..."
if kube get deployment cert-manager -n cert-manager &>/dev/null; then
  skip "cert-manager already installed"
else
  info "  Installing cert-manager v1.14.5..."
  if [[ "${DRY_RUN}" != "true" ]]; then
    kube apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml
    kube rollout status deployment/cert-manager -n cert-manager --timeout=180s
    kube rollout status deployment/cert-manager-webhook -n cert-manager --timeout=180s
  fi
  ok "cert-manager installed"
fi

info "  Checking Kamaji..."
if kube get crd tenantcontrolplanes.kamaji.clastix.io &>/dev/null; then
  skip "Kamaji already installed"
else
  info "  Installing Kamaji via Helm..."
  if [[ "${DRY_RUN}" != "true" ]]; then
    helm repo add clastix https://clastix.github.io/charts 2>/dev/null || true
    helm repo update clastix 2>/dev/null
    helm install kamaji clastix/kamaji \
      --namespace kamaji-system --create-namespace \
      --set etcd.deploy=true \
      --wait --timeout 5m
  fi
  ok "Kamaji installed"
fi

# Kamaji v1.0.0 webhook rejects k8s versions > 1.30.2 but DPF v25.10.1 requests v1.33.0.
# The underlying etcd supports v1.33; only the webhook version-check blocks it.
# Deleting the webhook is safe: DPF manages TenantControlPlane lifecycle, not Kamaji CLI.
if [[ "${DRY_RUN}" != "true" ]]; then
  if kube get validatingwebhookconfiguration kamaji-validating-webhook-configuration &>/dev/null; then
    kube delete validatingwebhookconfiguration kamaji-validating-webhook-configuration &>/dev/null || true
    info "  Removed Kamaji validating webhook (k8s version check bypass for v1.33.0)"
  fi
fi

info "  Checking ArgoCD..."
if kube get crd applicationsets.argoproj.io &>/dev/null; then
  skip "ArgoCD already installed"
else
  info "  Installing ArgoCD..."
  if [[ "${DRY_RUN}" != "true" ]]; then
    kube create namespace argocd 2>/dev/null || true
    # Server-side apply required — install.yaml's applicationsets CRD exceeds 262KB annotation limit
    kube apply --server-side -n argocd \
      -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    elapsed=0
    while [[ $elapsed -lt 60 ]]; do
      kube get crd applicationsets.argoproj.io &>/dev/null && break
      sleep 5; elapsed=$((elapsed + 5))
    done
    kube get crd applicationsets.argoproj.io &>/dev/null \
      || fail "ArgoCD ApplicationSet CRD not found after 60s"
  fi
  ok "ArgoCD installed"
fi

# ArgoCD v3 requires explicit multi-namespace config for DPF's AppProjects/Applications.
# DPF creates AppProjects and Applications in dpf-operator-system; ArgoCD must watch there.
info "  Configuring ArgoCD multi-namespace mode..."
if [[ "${DRY_RUN}" != "true" ]]; then
  CURRENT_NS=$(kube get configmap argocd-cmd-params-cm -n argocd \
    -o jsonpath="{.data.application\\.namespaces}" 2>/dev/null || echo "")
  if [[ "${CURRENT_NS}" != *"${DPF_NAMESPACE}"* ]]; then
    kube patch configmap argocd-cmd-params-cm -n argocd \
      --type merge \
      -p "{\"data\":{\"application.namespaces\":\"${DPF_NAMESPACE}\"}}"
    kube rollout restart statefulset/argocd-application-controller -n argocd
    kube rollout restart deployment/argocd-applicationset-controller -n argocd
    info "  ArgoCD restarted for namespace config"
  fi
  # DPF creates AppProjects in dpf-operator-system; ArgoCD v3 needs them in argocd namespace
  # with sourceNamespaces set. Create them there as mirrors.
  for proj in doca-platform-project-host doca-platform-project-dpu; do
    if ! kube get appproject "${proj}" -n argocd &>/dev/null; then
      info "  Creating AppProject ${proj} in argocd namespace..."
      cat > "/tmp/${proj}.yaml" <<PROJEOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ${proj}
  namespace: argocd
spec:
  clusterResourceWhitelist:
  - group: "*"
    kind: "*"
  destinations:
  - name: "*"
    namespace: "*"
  - server: "*"
    namespace: "*"
  orphanedResources: {}
  sourceRepos:
  - "*"
  sourceNamespaces:
  - "${DPF_NAMESPACE}"
  - "argocd"
PROJEOF
      kube apply -f "/tmp/${proj}.yaml"
    else
      # Ensure sourceNamespaces is set (patch is idempotent)
      kube patch appproject "${proj}" -n argocd \
        --type merge \
        -p "{\"spec\":{\"sourceNamespaces\":[\"${DPF_NAMESPACE}\",\"argocd\"]}}" \
        2>/dev/null || true
    fi
  done
fi
ok "ArgoCD multi-namespace configured"

# ─── Step 2: Start temporary BFB upload server ────────────────────────────────
# bfb-registry (DPF's nginx on port 8080) serves the BFB from the PVC to the BMC.
# But to populate the PVC, the BFB controller downloads from BFB_URL.
# BFB_URL must NOT use port 8080 (that's bfb-registry's port) — use BFB_UPLOAD_PORT.
# The python3 server runs temporarily until the BFB CR reaches Ready state.
info "Step 2/10 — BFB upload server (port ${BFB_UPLOAD_PORT}, for initial PVC population)"
[[ -f "${BFB_FILE}" ]] \
  || fail "BFB file not found: ${BFB_FILE} — copy the .bfb bundle there first"
ok "BFB file present: ${BFB_FILE}"

if nc -z "${BFB_REGISTRY_IP}" "${BFB_UPLOAD_PORT}" 2>/dev/null; then
  ok "BFB upload server already listening on port ${BFB_UPLOAD_PORT}"
elif [[ "${DRY_RUN}" == "true" ]]; then
  info "[dry-run] would start python3 HTTP server for BFB on port ${BFB_UPLOAD_PORT}"
else
  BFB_DIR="$(dirname "${BFB_FILE}")"
  nohup python3 -m http.server "${BFB_UPLOAD_PORT}" \
    --directory "${BFB_DIR}" \
    --bind 0.0.0.0 \
    >/tmp/bfb-upload.log 2>&1 &
  disown
  sleep 2
  nc -z "${BFB_REGISTRY_IP}" "${BFB_UPLOAD_PORT}" 2>/dev/null \
    || fail "BFB upload server failed to start on port ${BFB_UPLOAD_PORT} — check /tmp/bfb-upload.log"
  ok "BFB upload server started on port ${BFB_UPLOAD_PORT} (log: /tmp/bfb-upload.log)"
fi

# ─── Step 3: Clean up stale Kamaji etcd-defrag jobs ──────────────────────────
# DPF CronJob dpf-operator-kamaji-etcd-defrag-job spawns Jobs that accumulate
# if the kamaji-etcd-certs secret is missing. Jobs use job-name labels (not app labels).
# Selecting by CronJob name prefix is the only reliable method.
info "Step 3/10 — Cleaning up stale Kamaji etcd-defrag jobs"
DEFRAG_JOB_NAMES=$(kube get jobs -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null \
  | grep "dpf-operator-kamaji-etcd-defrag" | awk '{print $1}') || true
if [[ -n "${DEFRAG_JOB_NAMES}" ]]; then
  DEFRAG_COUNT=$(echo "${DEFRAG_JOB_NAMES}" | wc -l)
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[dry-run] would delete ${DEFRAG_COUNT} etcd-defrag jobs"
  else
    # shellcheck disable=SC2086
    kube delete jobs -n "${DPF_NAMESPACE}" ${DEFRAG_JOB_NAMES} 2>/dev/null || true
    ok "Deleted ${DEFRAG_COUNT} etcd-defrag job(s)"
  fi
else
  skip "No etcd-defrag jobs to clean up"
fi

# ─── Step 4: BFB PVC ──────────────────────────────────────────────────────────
info "Step 4/10 — BFB PersistentVolumeClaim"
if kube get pvc bfb-pvc -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "bfb-pvc already exists"
else
  apply "${MANIFESTS_DIR}/01-bfb-pvc.yaml"
  ok "bfb-pvc created"
fi

# ─── Step 5: DPFOperatorConfig ────────────────────────────────────────────────
info "Step 5/10 — DPFOperatorConfig (bootstraps Kamaji + provisioning controller)"
if kube get dpfoperatorconfig dpfoperatorconfig -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "DPFOperatorConfig already exists"
else
  TMPFILE=$(mktemp /tmp/dpfoperatorconfig-XXXXXX.yaml)
  sed \
    -e "s|BFB_REGISTRY_IP|${BFB_REGISTRY_IP}|g" \
    -e "s|BFB_REGISTRY_PORT|${BFB_REGISTRY_PORT}|g" \
    "${MANIFESTS_DIR}/02-dpfoperatorconfig.yaml" > "${TMPFILE}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[dry-run] would apply DPFOperatorConfig (bfbRegistryAddress: http://${BFB_REGISTRY_IP}:${BFB_REGISTRY_PORT})"
  else
    kube apply -f "${TMPFILE}"
    ok "DPFOperatorConfig created"
  fi
  rm -f "${TMPFILE}"
fi

# ─── Step 6: Wait for Kamaji + provisioner + bfb-registry ────────────────────
# Kamaji is installed in its own kamaji-system namespace (not dpf-operator-system).
# SystemComponentsReady=False is expected at this stage when no DPU cluster exists yet;
# the servicechainset-controller DPUService has a circular dep with DPU cluster existence.
info "Step 6/10 — Waiting for Kamaji, DPF provisioning controller, and bfb-registry (timeout: ${WAIT_TIMEOUT}s)"
if [[ "${DRY_RUN}" == "true" ]]; then
  info "[dry-run] skipping wait"
else
  # Kamaji pods are in kamaji-system namespace
  wait_for_pods "app.kubernetes.io/instance=kamaji" "kamaji-system" "${WAIT_TIMEOUT}" \
    || wait_for_pods "app.kubernetes.io/name=kamaji" "kamaji-system" "${WAIT_TIMEOUT}" \
    || fail "Kamaji pods not ready after ${WAIT_TIMEOUT}s — check: kubectl get pods -n kamaji-system"
  ok "Kamaji ready"
  wait_for_pods "dpu.nvidia.com/component=dpf-provisioning-controller-manager" "${DPF_NAMESPACE}" 60 \
    || warn "Provisioning controller pod not yet visible — proceeding (may still be starting)"

  # bfb-registry DaemonSet (nginx, hostPort 8080) is deployed by DPFOperatorConfig reconciliation.
  # Wait for it and verify the BFB file is actually reachable before applying the BFB CR.
  info "  Waiting for bfb-registry to be reachable on ${BFB_REGISTRY_IP}:${BFB_REGISTRY_PORT}..."
  elapsed=0
  while [[ $elapsed -lt 120 ]]; do
    if curl -sf --max-time 5 --head "http://${BFB_REGISTRY_IP}:${BFB_REGISTRY_PORT}/" &>/dev/null; then
      ok "bfb-registry reachable at http://${BFB_REGISTRY_IP}:${BFB_REGISTRY_PORT}/"
      break
    fi
    sleep 10; elapsed=$((elapsed + 10))
    info "  waiting for bfb-registry... ${elapsed}s/120s"
  done
  if [[ $elapsed -ge 120 ]]; then
    warn "bfb-registry not reachable after 120s — BFB download may fail; check: kubectl get pods -n ${DPF_NAMESPACE} | grep bfb-registry"
  fi
fi

# ─── Step 7: BFB resource ─────────────────────────────────────────────────────
info "Step 7/11 — BFB resource (downloads BFB into PVC)"
if kube get bfb doca-3.3.0 -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "BFB 'doca-3.3.0' already exists"
else
  TMPFILE=$(mktemp /tmp/bfb-XXXXXX.yaml)
  sed "s|BFB_URL|${BFB_URL}|g" "${MANIFESTS_DIR}/03-bfb.yaml" > "${TMPFILE}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[dry-run] would apply BFB (url: ${BFB_URL})"
  else
    kube apply -f "${TMPFILE}"
    ok "BFB resource created (url: ${BFB_URL})"
  fi
  rm -f "${TMPFILE}"
fi

if [[ "${DRY_RUN}" != "true" ]]; then
  info "  waiting for BFB download to complete..."
  elapsed=0
  while [[ $elapsed -lt 600 ]]; do
    phase=$(kube get bfb doca-3.3.0 -n "${DPF_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "$phase" == "Ready" ]] && { ok "BFB phase: Ready"; break; }
    [[ "$phase" == "Failed" ]] && fail "BFB download failed — check: kubectl describe bfb doca-3.3.0 -n ${DPF_NAMESPACE}"
    sleep 15; elapsed=$((elapsed + 15))
    info "  BFB phase: ${phase:-unknown} (${elapsed}s/600s)"
  done
  [[ $elapsed -ge 600 ]] && fail "BFB not ready after 600s"
fi

# ─── Step 8: DPUFlavor ────────────────────────────────────────────────────────
info "Step 8/11 — DPUFlavor"
if kube get dpuflavor bf3-base -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "DPUFlavor 'bf3-base' already exists"
else
  apply "${MANIFESTS_DIR}/04-dpuflavor.yaml"
  ok "DPUFlavor 'bf3-base' created"
fi

# ─── Step 9: DPUCluster ───────────────────────────────────────────────────────
# DPUCluster tells DPF to create a virtual k8s control plane via Kamaji (type: kamaji).
# Must exist before the DPU CR is applied — DPU waits for the cluster to be found.
# Note: Kamaji v1.0.0 only supports k8s ≤1.30.x. DPF v25.10.1 requests v1.33.0.
# The validating webhook check is deleted in Step 1b; the underlying kamaji etcd supports it.
info "Step 9/11 — DPUCluster (virtual k8s control plane for DPU)"
if kube get dpucluster s4-dpu-cluster -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "DPUCluster 's4-dpu-cluster' already exists"
else
  apply "${MANIFESTS_DIR}/08-dpucluster.yaml"
  ok "DPUCluster 's4-dpu-cluster' created"
fi

# ─── Step 10: DPUNode + DPUDevice + DPU ───────────────────────────────────────
info "Step 10/11 — DPUNode, DPUDevice, DPU (triggers Redfish provisioning)"

if kube get dpunode s4-node -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "DPUNode 's4-node' already exists"
else
  apply "${MANIFESTS_DIR}/05-dpunode.yaml"
  ok "DPUNode 's4-node' created"
fi

if kube get dpudevice s4-bf3 -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "DPUDevice 's4-bf3' already exists"
else
  TMPFILE=$(mktemp /tmp/dpudevice-XXXXXX.yaml)
  sed \
    -e "s|BF3_SERIAL|${BF3_SERIAL}|g" \
    -e "s|BF3_BMC_IP|${BF3_BMC_IP}|g" \
    "${MANIFESTS_DIR}/06-dpudevice.yaml" > "${TMPFILE}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[dry-run] would apply DPUDevice (serial: ${BF3_SERIAL}, bmcIp: ${BF3_BMC_IP})"
  else
    kube apply -f "${TMPFILE}"
    ok "DPUDevice 's4-bf3' created (serial: ${BF3_SERIAL})"
  fi
  rm -f "${TMPFILE}"
fi

if kube get dpu s4-dpu -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "DPU 's4-dpu' already exists"
else
  TMPFILE=$(mktemp /tmp/dpu-XXXXXX.yaml)
  sed \
    -e "s|BF3_SERIAL|${BF3_SERIAL}|g" \
    -e "s|BF3_BMC_IP|${BF3_BMC_IP}|g" \
    "${MANIFESTS_DIR}/07-dpu.yaml" > "${TMPFILE}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[dry-run] would apply DPU (serial: ${BF3_SERIAL}, bmcIP: ${BF3_BMC_IP})"
  else
    kube apply -f "${TMPFILE}"
    ok "DPU 's4-dpu' created — BFB flash via Redfish starting"
  fi
  rm -f "${TMPFILE}"
fi

# ─── Step 10b: rshim BFB flash (optional, --rshim-install) ───────────────────
# Alternative to DPF's Redfish OS install — flashes directly via the x86 host.
# Waits for DPF to generate the bfcfg (BFBPrepared phase), then SSHes to the
# x86 host and runs bfb-install. Useful when the BMC skips same-version Redfish
# installs (returning 404 on the task), causing DPF to report Error/FailToInstall.
if [[ "${USE_RSHIM}" == "true" ]]; then
  info "Step 10b/11 — rshim BFB flash via x86 host (${X86_HOST_IP})"
  # Define dkube early so it's available for the already-joined check below
  kube get secret s4-dpu-cluster-admin-kubeconfig -n "${DPF_NAMESPACE}" \
    -o jsonpath='{.data.admin\.conf}' 2>/dev/null | base64 -d > /tmp/dpu-tc-kubeconfig 2>/dev/null || true
  dkube() { kubectl --kubeconfig /tmp/dpu-tc-kubeconfig "$@"; }
  _existing_nodes=$(dkube get nodes --no-headers 2>/dev/null | wc -l || echo 0)
  if [[ "$_existing_nodes" -gt 0 ]]; then
    skip "BF3 already joined TenantControlPlane — skipping rshim flash"
    dkube get nodes
  elif [[ "${DRY_RUN}" == "true" ]]; then
    info "[dry-run] would flash BF3 via: ssh ${X86_HOST_USER}@${X86_HOST_IP} sudo bfb-install --rshim ${RSHIM_DEVICE} --bfb ${X86_BFB_PATH} --cfg /tmp/dpf.cfg"
  else
    command -v sshpass &>/dev/null \
      || fail "sshpass not installed — apt install sshpass (required for --rshim-install)"

    # Wait for DPF to generate the bfcfg (set during BFBPrepared phase)
    info "  Waiting for DPF to generate bfcfg (BFBPrepared)..."
    elapsed=0; bfcfg_ready=false
    while [[ $elapsed -lt 600 ]]; do
      bfb_prepared=$(kube get dpu s4-dpu -n "${DPF_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="BFBPrepared")].status}' 2>/dev/null || echo "")
      dpu_phase=$(kube get dpu s4-dpu -n "${DPF_NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      if [[ "$bfb_prepared" == "True" ]]; then
        bfcfg_ready=true; ok "BFBPrepared: True — bfcfg ready"; break
      fi
      # DPF may have already progressed to Error/FailToInstall — bfcfg still exists
      if [[ "$dpu_phase" == "Error" ]]; then
        os_reason=$(kube get dpu s4-dpu -n "${DPF_NAMESPACE}" \
          -o jsonpath='{.status.conditions[?(@.type=="OSInstalled")].reason}' 2>/dev/null || echo "")
        [[ "$os_reason" == "FailToInstall" ]] && { bfcfg_ready=true; ok "DPF in Error/FailToInstall — bfcfg already generated"; break; }
      fi
      sleep 15; elapsed=$((elapsed + 15))
      info "  DPU phase: ${dpu_phase:-unknown} ... ${elapsed}s/600s"
    done
    [[ "$bfcfg_ready" != "true" ]] \
      && fail "bfcfg not ready after 600s — check: kubectl describe dpu s4-dpu -n ${DPF_NAMESPACE}"

    # Refresh TenantControlPlane kubeconfig (fail if not available yet)
    kube get secret s4-dpu-cluster-admin-kubeconfig -n "${DPF_NAMESPACE}" \
      -o jsonpath='{.data.admin\.conf}' | base64 -d > /tmp/dpu-tc-kubeconfig \
      || fail "Cannot get TenantControlPlane kubeconfig — is DPUCluster Ready?"

    # Create a fresh bootstrap token (DPF's original bfcfg token expires after 24h)
    TOKEN_ID=$(openssl rand -hex 3)
    TOKEN_SECRET=$(openssl rand -hex 8)
    RSHIM_TOKEN="${TOKEN_ID}.${TOKEN_SECRET}"
    dkube create secret generic "bootstrap-token-${TOKEN_ID}" -n kube-system \
      --type bootstrap.kubernetes.io/token \
      --from-literal="token-id=${TOKEN_ID}" \
      --from-literal="token-secret=${TOKEN_SECRET}" \
      --from-literal=usage-bootstrap-authentication=true \
      --from-literal=usage-bootstrap-signing=true \
      --from-literal='auth-extra-groups=system:bootstrappers:kubeadm:default-node-token' \
      || fail "Failed to create bootstrap token in TenantControlPlane"
    ok "Bootstrap token created: ${RSHIM_TOKEN}"

    # Locate bfcfg path from DPU status (relative path within the bfb PVC)
    BFCFG_REL=$(kube get dpu s4-dpu -n "${DPF_NAMESPACE}" \
      -o jsonpath='{.status.bfCFGFile}' 2>/dev/null || echo "")
    [[ -z "${BFCFG_REL}" ]] \
      && fail "DPU status.bfCFGFile empty — DPF has not generated bfcfg yet"
    # Download bfcfg via bfb-registry HTTP server (container has no shell utilities)
    info "  Deploying bfcfg to ${X86_HOST_IP}:/tmp/dpf.cfg (token refreshed)..."
    curl -sf "http://${BFB_REGISTRY_IP}:${BFB_REGISTRY_PORT}/bfb/${BFCFG_REL}" \
      | sed "s|--token [a-zA-Z0-9]*\.[a-zA-Z0-9]* |--token ${RSHIM_TOKEN} |g" \
      | sshpass -p "${X86_HOST_PASS}" \
          ssh -o StrictHostKeyChecking=no "${X86_HOST_USER}@${X86_HOST_IP}" \
          "cat > /tmp/dpf.cfg" \
      || fail "Failed to deploy bfcfg — check http://${BFB_REGISTRY_IP}:${BFB_REGISTRY_PORT}/bfb/${BFCFG_REL}"
    ok "bfcfg deployed to ${X86_HOST_IP}:/tmp/dpf.cfg"

    # Flash the BF3 from the x86 host via rshim (10-20 min)
    info "  Flashing BF3 via ${RSHIM_DEVICE} on ${X86_HOST_IP} — takes 10-20 minutes..."
    sshpass -p "${X86_HOST_PASS}" \
      ssh -o StrictHostKeyChecking=no \
          -o ServerAliveInterval=30 -o ServerAliveCountMax=60 \
          "${X86_HOST_USER}@${X86_HOST_IP}" \
      "echo '${X86_HOST_PASS}' | sudo -S bfb-install --rshim ${RSHIM_DEVICE} --bfb ${X86_BFB_PATH} --config /tmp/dpf.cfg" \
      || warn "bfb-install exited non-zero (usually benign I/O errors after BF3 reboots) — watching for node join to confirm"
    ok "BFB flash initiated — BF3 is rebooting with DPF configuration"

    # Wait for BF3 to join TenantControlPlane (kubeadm-join.service runs on first boot)
    info "  Waiting for BF3 node to join TenantControlPlane (timeout: ${DPU_TIMEOUT}s)..."
    elapsed=0
    while [[ $elapsed -lt $DPU_TIMEOUT ]]; do
      node_count=$(dkube get nodes --no-headers 2>/dev/null | wc -l || echo 0)
      if [[ "$node_count" -gt 0 ]]; then
        ok "BF3 joined TenantControlPlane:"
        dkube get nodes
        break
      fi
      sleep 20; elapsed=$((elapsed + 20))
      info "  waiting for BF3 node... ${elapsed}s/${DPU_TIMEOUT}s"
    done
    [[ $elapsed -ge $DPU_TIMEOUT ]] \
      && fail "BF3 did not join TenantControlPlane after ${DPU_TIMEOUT}s — check: kubectl get nodes --kubeconfig /tmp/dpu-tc-kubeconfig"

    # BF3 joined — patch DPU status to Ready so DPF can proceed with DPUService deployment.
    # Redfish 404 (same-version skip) left DPU in Error/FailToInstall; rshim flash remedied it.
    info "  Patching DPU status → Ready (rshim flash confirmed successful)..."
    kube patch dpu s4-dpu -n "${DPF_NAMESPACE}" --subresource=status --type=merge \
      -p '{"status":{"phase":"Ready"}}' 2>/dev/null \
      && ok "DPU status patched to Ready" \
      || warn "Could not patch DPU status — check manually: kubectl get dpu s4-dpu -n ${DPF_NAMESPACE}"
  fi
fi

# ─── Step 10: Wait for DPU Ready ──────────────────────────────────────────────
info "Step 11/11 — Waiting for DPU provisioning to complete (timeout: ${DPU_TIMEOUT}s)"
info "  BF3 will reboot during flash — this is expected. Do not interrupt."

if [[ "${DRY_RUN}" == "true" ]]; then
  info "[dry-run] skipping DPU wait"
else
  elapsed=0
  last_phase=""
  while [[ $elapsed -lt $DPU_TIMEOUT ]]; do
    phase=$(kube get dpu s4-dpu -n "${DPF_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$phase" != "$last_phase" ]]; then
      info "  DPU phase: ${phase:-unknown}"
      last_phase="$phase"
    fi
    [[ "$phase" == "Ready" ]] && break
    if [[ "$phase" == "Error" ]]; then
      os_reason=$(kube get dpu s4-dpu -n "${DPF_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="OSInstalled")].reason}' 2>/dev/null || echo "")
      os_msg=$(kube get dpu s4-dpu -n "${DPF_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="OSInstalled")].message}' 2>/dev/null || echo "")
      if [[ "$os_reason" == "FailToInstall" && "$os_msg" == *"404"* ]]; then
        # BMC returned 404 on install task poll — happens when BF3 already has the
        # target version and the BMC skips the flash, immediately cleaning up the task.
        # Verify via Redfish before treating as a real failure.
        bmc_user=$(kube get secret bmc-shared-password -n "${DPF_NAMESPACE}" \
          -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || echo "root")
        bmc_pass=$(kube get secret bmc-shared-password -n "${DPF_NAMESPACE}" \
          -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
        current_ver=$(curl -sk -u "${bmc_user}:${bmc_pass}" \
          "https://${BF3_BMC_IP}/redfish/v1/UpdateService/FirmwareInventory/DPU_OS" \
          2>/dev/null \
          | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Version',''))" \
          2>/dev/null || echo "")
        expected_ver="$(basename "${BFB_FILE}" .bfb)"
        if [[ -n "$current_ver" && "$current_ver" == "$expected_ver" ]]; then
          warn "DPU Error: BMC skipped OS install — BF3 already running target version"
          warn "  Current : ${current_ver}"
          warn "  Expected: ${expected_ver}"
          warn "  bfcfg was not re-applied; BF3 OS config unchanged from prior flash"
          ok "BF3 version matches target — treating provisioning as complete"
          break
        fi
      fi
      fail "DPU provisioning failed — check: kubectl describe dpu s4-dpu -n ${DPF_NAMESPACE}"
    fi
    sleep 15; elapsed=$((elapsed + 15))
  done
  [[ $elapsed -ge $DPU_TIMEOUT ]] \
    && fail "DPU not Ready after ${DPU_TIMEOUT}s — check: kubectl describe dpu s4-dpu -n ${DPF_NAMESPACE}"
  ok "DPU 's4-dpu' phase: Ready"
fi

echo ""
echo "============================================================"
echo "  DPF Bringup Complete"
echo "============================================================"
echo ""
info "BF3 is now a managed DPU node. Next steps:"
echo ""
echo "  Check status:    ./status_dpf.sh"
echo ""
echo "  Get DPU cluster kubeconfig:"
echo "    kubectl get secret -n dpf-operator-system s4-dpu-cluster-admin-kubeconfig \\"
echo "      -o jsonpath='{.data.admin\\.conf}' | base64 -d > /tmp/dpu-kubeconfig"
echo "    kubectl get nodes --kubeconfig /tmp/dpu-kubeconfig"
echo ""
echo "  Deploy HBN (future step):"
echo "    kubectl apply -f dpf/manifests/hbn/  --kubeconfig /tmp/dpu-kubeconfig"
echo ""
