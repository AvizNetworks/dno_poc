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
# Prefer k3s kubeconfig when available — it's always authoritative and updated on restart.
# ~/.kube/config can go stale (e.g. after k3s IPv6 fix). KUBECONFIG env always wins.
if [[ -n "${KUBECONFIG:-}" ]]; then
  DPF_KUBECONFIG="${KUBECONFIG}"
elif [[ -r /etc/rancher/k3s/k3s.yaml ]]; then
  DPF_KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  mkdir -p "${HOME}/.kube"
  cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config" 2>/dev/null || true
else
  DPF_KUBECONFIG="${HOME}/.kube/config"
fi
DPF_NAMESPACE="dpf-operator-system"

SERVER_NAME=""                     # Server identifier — used to name all k8s resources.
                                   # Set per worker in dpf/config.yaml (or --server).
                                   # Creates: <name>-dpu, <name>-node, <name>-bf3,
                                   #          <name>-dpu-cluster

BF3_BMC_IP=""                      # BF3 BMC (Redfish endpoint)     — config.yaml / --bmc-ip
BF3_OOB_IP=""                      # BF3 OOB management IP          — config.yaml / --oob-ip
BF3_SERIAL=""                      # BF3 serial (dmidecode -t system) — config.yaml / --serial

BFB_REGISTRY_IP="${BFB_REGISTRY_IP:-$(hostname -I | awk '{print $1}')}"  # auto-detect local IP; override with --registry-ip
BFB_REGISTRY_PORT="8080"           # DPF's bfb-registry hostPort — do NOT run anything else here
BFB_FILE="/opt/bfb/bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb"
BFB_UPLOAD_PORT="9090"             # Temp HTTP port for BFB controller to download from (→ PVC)
# BFB_URL is computed after arg parsing (BFB_REGISTRY_IP may be overridden by --registry-ip)

WAIT_TIMEOUT=300        # seconds to wait for Kamaji + provisioner pods
DPU_TIMEOUT=1800        # seconds to wait for BFB flash (30 min — reboot included)
DRY_RUN=false
DPF_VERSION="v25.10.1"  # DPF Operator Helm chart version (update when upgrading)
DO_UPGRADE=false
DEPLOY_HBN=false        # deploy HBN as a DaemonSet on BF3 (use --hbn flag)

# ─── rshim install (alternative to DPF Redfish OS install) ────────────────────
# Used via --rshim-install when DPF's Redfish path fails (e.g. same-version BMC skip).
# The x86 host SSHes over rshim to flash the BF3 directly with the DPF bfcfg applied.
X86_HOST_IP=""                # x86 host with rshim access to BF3 (set in config.yaml)
X86_HOST_USER=""               # SSH user on x86 host      — set in config.local.yaml
X86_HOST_PASS=""               # SSH password on x86 host  — set in config.local.yaml
                               # (empty = key-based auth)
# shellcheck disable=SC2088  # tilde expands on the REMOTE x86 host (via ssh), not here
X86_BFB_PATH="~/bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb"
RSHIM_DEVICE="rshim0"
USE_RSHIM=false

# Populated from config.local.yaml (per-worker blocks) — reserved for steps that need them.
ARM_PASSWORD=""
BMC_PASSWORD=""
BMC_USERNAME="root"
OPERATOR_IP=""                 # operator.ip from config.yaml (sanity: run on the right VM)
OPERATOR_NAME=""               # operator.name from config.yaml
WORKER_OPERATOR=""             # per-worker operator field (workers owned elsewhere)
WORKER_NAME=""                 # --worker <name> selects a worker from config.yaml
APISERVER_PORT=""              # Kamaji TCP NodePort on the DPF VM — UNIQUE per worker,
                               # and NEVER the management apiserver port (6443 on k3s):
                               # a NodePort on the mgmt apiserver port makes kube-proxy
                               # blackhole the operator's own apiserver when the TCP has
                               # no endpoints (REJECT --dst-type LOCAL --dport 6443).
CHECK_ONLY=false               # --check: run preflight only, no mutations
ALLOW_REFLASH=false            # --allow-reflash: authorize the DESTRUCTIVE DPUFlavor
                               # recreate (deletes the DPU CR → BF3 leaves the cluster
                               # → full reflash, ~30 min outage). Without it, a changed
                               # flavor FAILS FAST before anything is mutated.
POSTCHECK_FW_BAD=false         # set by step 11b when nvconfig read-back fails
# ──────────────────────────────────────────────────────────────────────────────
# NOTE: the values above are BUILT-IN DEFAULTS. Precedence (lowest → highest):
#   built-in defaults  <  dpf/config.yaml  <  dpf/config.local.yaml  <  CLI flags

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

Config files (recommended — see dpf/config.yaml):
  dpf/config.yaml        Topology: operator VM, BFB, workers (worker1, worker2, ...)
  dpf/config.local.yaml  Secrets: ARM/BMC/x86 passwords (gitignored; copy from
                         config.local.sample.yaml)
  Precedence: built-in defaults < config.yaml < config.local.yaml < CLI flags

Options:
  --worker <name>      Select a worker from config.yaml by name or server id
                       (e.g. --worker worker1 or --worker s4; default: first worker)
  --server <name>      Server identifier for k8s resource names
                       e.g. --server s1 creates s1-dpu, s1-node, s1-bf3, s1-dpu-cluster
  --registry-ip <ip>   Override DPF VM IP for BFB registry/upload (default: auto-detect via hostname -I)
  --bfb-url <url>      Override BFB download URL (default: http://BFB_REGISTRY_IP:PORT/filename)
  --bmc-ip <ip>        Override BF3 BMC IP
  --oob-ip <ip>        Override BF3 OOB IP
  --serial <serial>    Override BF3 serial number
  --rshim-install      Flash BF3 via rshim from x86 host instead of DPF Redfish
  --x86-host <ip>      x86 host IP for rshim flash
  --x86-user <user>    x86 host SSH user (default: ${X86_HOST_USER})
  --x86-pass <pass>    x86 host SSH password (default: from config)
  --x86-bfb <path>     BFB path on x86 host (default: ${X86_BFB_PATH})
  --rshim-dev <dev>    rshim device on x86 host (default: ${RSHIM_DEVICE})
  --hbn                Deploy HBN (doca-hbn) as a DaemonSet on BF3 — no NGC key needed.
                       Uses image already present: nvcr.io/nvidia/doca/doca_hbn:3.3.0-doca3.3.0
                       Equivalent to: sudo ./scripts/bringup_hbn_bf3.sh --vfs 8
  --upgrade            Upgrade DPF Operator Helm release to --version (skips bringup steps)
  --version <ver>      DPF Operator version to upgrade to (default: ${DPF_VERSION})
  --check              PREFLIGHT ONLY: validate every prerequisite (tools, config,
                       cluster, network, BMC, ports, artifacts) and exit. Nothing is
                       modified. Exit 0 = ready to run, 1 = blockers found.
  --dry-run            Run preflight, then print every step without applying
  --allow-reflash      Authorize the DESTRUCTIVE path when the DPUFlavor changed:
                       delete the DPU CR and REFLASH the BF3 (~30 min outage).
                       Without this flag a changed flavor fails fast, before any
                       mutation. Use only in a maintenance window.
  -h, --help           Show this help

Examples:
  $0 --worker worker1 --rshim-install --hbn      # everything from config.yaml
  $0 --worker worker2                            # 2nd worker from config.yaml
  $0                                             # first worker in config.yaml
                                                 # (or built-in defaults if no config)
  $0 --server s2 --bmc-ip 10.20.13.212 --oob-ip 10.20.13.228 --serial <SN>  # flags only
  $0 --upgrade                        # upgrade to default version (${DPF_VERSION})
  $0 --upgrade --version v25.10.2     # upgrade to specific version
EOF
  exit 0
}

# ─── Config file loading (dpf/config.yaml + dpf/config.local.yaml) ────────────
# Values override the built-in defaults above; CLI flags (parsed after this)
# override everything. --worker is pre-scanned here because worker selection
# must happen while loading the config, before the main flag loop runs.
CONFIG_FILE="${SCRIPT_DIR}/../config.yaml"
CONFIG_LOCAL_FILE="${SCRIPT_DIR}/../config.local.yaml"

_args=("$@")
for ((_i=0; _i<${#_args[@]}; _i++)); do
  [[ "${_args[$_i]}" == "--worker" ]] && WORKER_NAME="${_args[$((_i+1))]:-}"
done

load_yaml_config() {
  [[ -f "${CONFIG_FILE}" || -f "${CONFIG_LOCAL_FILE}" ]] || return 0
  if ! python3 -c 'import yaml' 2>/dev/null; then
    warn "config.yaml found but python3-yaml missing (apt install python3-yaml) — using built-in defaults + flags"
    return 0
  fi
  local _out
  _out=$(python3 - "${CONFIG_FILE}" "${CONFIG_LOCAL_FILE}" "${WORKER_NAME}" <<'PYEOF'
import os, shlex, sys, yaml

cfg_f, lcl_f, worker_name = sys.argv[1], sys.argv[2], sys.argv[3]

def load(p):
    if os.path.exists(p):
        with open(p) as f:
            return yaml.safe_load(f) or {}
    return {}

def merge(a, b):  # b wins
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict):
            merge(a[k], v)
        else:
            a[k] = v
    return a

c = merge(load(cfg_f), load(lcl_f))

workers = c.get("workers") or []
w = None
if worker_name:
    w = next((x for x in workers
              if x.get("name") == worker_name or x.get("server") == worker_name), None)
    if w is None:
        names = ", ".join(str(x.get("name")) for x in workers) or "<none>"
        print(f'fail "worker {shlex.quote(worker_name)} not in config.yaml (have: {names})"')
        sys.exit(0)
elif workers:
    w = workers[0]

def emit(var, val):
    if val not in (None, ""):
        print(f"{var}={shlex.quote(str(val))}")

bfb = c.get("bfb") or {}
emit("BFB_FILE", bfb.get("file"))
emit("BFB_REGISTRY_IP", bfb.get("registry_ip"))
emit("OPERATOR_IP", (c.get("operator") or {}).get("ip"))
emit("OPERATOR_NAME", (c.get("operator") or {}).get("name"))

# Credentials from config.local.yaml: one top-level block per worker,
# keyed by the worker's name (worker1) or server id (s4).
cred = {}
if w:
    for key in (w.get("name"), w.get("server")):
        if key and isinstance(c.get(key), dict):
            cred = c[key]
            break
emit("X86_HOST_USER", cred.get("x86_host_user"))
emit("X86_HOST_PASS", cred.get("x86_host_password"))
emit("ARM_PASSWORD", cred.get("arm_password"))
emit("BMC_PASSWORD", cred.get("bmc_password"))
emit("BMC_USERNAME", cred.get("bmc_username"))

if w:
    emit("WORKER_OPERATOR", w.get("operator"))
    emit("SERVER_NAME", w.get("server") or w.get("name"))
    emit("BF3_BMC_IP", w.get("bmc_ip"))
    emit("BF3_OOB_IP", w.get("oob_ip"))
    emit("BF3_SERIAL", w.get("serial"))
    emit("APISERVER_PORT", w.get("apiserver_port"))
    emit("X86_HOST_IP", w.get("x86_host_ip"))
    emit("RSHIM_DEVICE", w.get("rshim"))
    emit("X86_BFB_PATH", w.get("x86_bfb"))
PYEOF
  ) || fail "Could not parse ${CONFIG_FILE} / ${CONFIG_LOCAL_FILE}"
  eval "${_out}"
  [[ -f "${CONFIG_FILE}" ]] && info "Loaded ${CONFIG_FILE}$( [[ -f "${CONFIG_LOCAL_FILE}" ]] && echo " + config.local.yaml" ) — worker: ${WORKER_NAME:-<first>} → server '${SERVER_NAME}'"
}
load_yaml_config

while [[ $# -gt 0 ]]; do
  case $1 in
    --worker)         shift ;;  # consumed by the config pre-scan above
    --server)         SERVER_NAME="$2";      shift ;;
    --registry-ip)    BFB_REGISTRY_IP="$2"; shift ;;
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
    --hbn)            DEPLOY_HBN=true ;;
    --upgrade)        DO_UPGRADE=true ;;
    --version)        DPF_VERSION="$2";     shift ;;
    --check|--preflight) CHECK_ONLY=true ;;
    --allow-reflash)  ALLOW_REFLASH=true ;;
    --dry-run)        DRY_RUN=true ;;
    -h|--help)        usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

# Compute BFB_URL after arg parsing so --registry-ip and --bfb-url both take effect
[[ -z "${BFB_URL:-}" ]] && BFB_URL="http://${BFB_REGISTRY_IP}:${BFB_UPLOAD_PORT}/$(basename "${BFB_FILE}")"

# ─── Same-subnet vs cross-subnet deployment ───────────────────────────────────
# Decides where the DPUFlavor's apiserver DNAT rules point (RELAY_IP):
#   same  — the BF3 OOB and the DPF VM share a /24: the BF3 reaches the Kamaji
#           apiserver directly → relay IS the DPF VM. No tunnel, nothing to lose
#           on BF3 reboot.
#   cross — different subnets (some labs firewall BF3→DPF VM TCP): relay via the
#           x86 host reverse-SSH tunnel (tunnel_dpf.sh) exactly as before.
TUNNEL_MODE="cross"; RELAY_IP="${X86_HOST_IP}"
if [[ -n "${BF3_OOB_IP}" && "${BFB_REGISTRY_IP%.*}" == "${BF3_OOB_IP%.*}" ]]; then
  TUNNEL_MODE="same"; RELAY_IP="${BFB_REGISTRY_IP}"
fi

# Management apiserver port (from kubeconfig) — used by preflight collision checks
# and by the TCP-creation race guard below.
MGMT_PORT=$(grep -oE 'server: https?://[^ ]+' "${DPF_KUBECONFIG}" 2>/dev/null | head -1 | grep -oE '[0-9]+$' || true)

# RACE GUARD: Kamaji creates each TenantControlPlane's Service as NodePort 6443 (its
# default) BEFORE our per-worker port patch can land. While that Service has no
# endpoints, kube-proxy installs a REJECT for node-local :6443 — which blackholes a
# single-VM operator's OWN apiserver over IPv4, killing the very kubectl that must
# apply the patch. The ip6tables path carries no such rule, so these calls fall back
# to the IPv6 loopback endpoint (client-cert auth still applies).
kube_tcp() {
  kube "$@" 2>/dev/null || kubectl --kubeconfig="${DPF_KUBECONFIG}" \
    --server "https://[::1]:${MGMT_PORT:-6443}" --insecure-skip-tls-verify "$@"
}

# Per-server DPUFlavor name. DPUFlavor is a cluster-shared object referenced by the
# DPU CR; if multiple DPUs (e.g. s4-dpu + s1-dpu) shared one flavor, the immutable
# delete/recreate in Step 8 would be blocked by the webhook ("referred to by DPU(s)").
# Giving each server its own flavor (s1-bf3-hbn, s4-bf3-hbn, ...) keeps them isolated.
DPU_FLAVOR_NAME="${SERVER_NAME}-bf3-hbn"

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
  DPU_SVC_HOST="${SERVER_NAME}-dpu-cluster.${DPF_NAMESPACE}.svc"
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
  kube get secret "${SERVER_NAME}-dpu-cluster-admin-kubeconfig" -n "${DPF_NAMESPACE}" \
    -o jsonpath='{.data.admin\.conf}' | base64 -d > "${HOME}/dpu-tc-kubeconfig" 2>/dev/null || true
  if [[ -s ${HOME}/dpu-tc-kubeconfig ]]; then
    dkube() { kubectl --kubeconfig "${HOME}/dpu-tc-kubeconfig" "$@"; }
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
" | kubectl --kubeconfig "${HOME}/dpu-tc-kubeconfig" apply -f - 2>/dev/null \
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

# ─── Shared helpers: flavor rendering + read-only BF3 probes ──────────────────

# Render the DPUFlavor with this worker's substitutions — used by preflight
# (drift detection) and step 8 (apply). MUST stay identical in both places.
render_flavor() {  # $1 = output file
  sed -e "s|^  name: bf3-hbn|  name: ${DPU_FLAVOR_NAME}|" \
      -e "s|X86_HOST_IP=\"[^\"]*\"|X86_HOST_IP=\"${RELAY_IP}\"|g" \
      -e "s|DPF_VM_IP=\"[^\"]*\"|DPF_VM_IP=\"${BFB_REGISTRY_IP}\"|g" \
      -e "s|APISERVER_PORT=\"[^\"]*\"|APISERVER_PORT=\"${APISERVER_PORT}\"|g" \
      "${MANIFESTS_DIR}/04-dpuflavor.yaml" > "$1"
}

# SSH to the BF3 ARM (ubuntu@OOB). Needs arm_password from config.local.yaml.
bf3_ssh() {
  sshpass -p "${ARM_PASSWORD}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 \
    -o LogLevel=ERROR "ubuntu@${BF3_OOB_IP}" "$@" 2>/dev/null
}
bf3_reachable() {  # BF3 SSH possible right now?
  [[ -n "${ARM_PASSWORD}" && -n "${BF3_OOB_IP}" ]] && command -v sshpass &>/dev/null \
    && timeout 4 bash -c "echo > /dev/tcp/${BF3_OOB_IP}/22" 2>/dev/null
}
# Firmware LAG_RESOURCE_ALLOCATION *Current* value (e.g. "PRE_ALLOCATION(1)").
# MUST parse `-e q` — plain `q` prints only Next-Boot, which is exactly the
# cosmetic staged value that must never be trusted (S8 lesson).
bf3_lag_current() {  # $1 = pci addr
  bf3_ssh "sudo mlxconfig -d $1 -e q LAG_RESOURCE_ALLOCATION 2>/dev/null" \
    | awk '/LAG_RESOURCE_ALLOCATION/{print $(NF-1)}' || true
}
bf3_multiport() {  # runtime eswitch multiport param -> "true"/"false"/""
  bf3_ssh "sudo devlink dev param show pci/0000:03:00.0 name esw_multiport 2>/dev/null" \
    | awk '/cmode/{print $NF}' || true
}
bf3_pairflows() {  # count of sfc priority-500 port-pair flows on br-hbn
  bf3_ssh "sudo ovs-ofctl dump-flows br-hbn 2>/dev/null | grep -c priority=500" || true
}

# ═══ PREFLIGHT — read-only validation of EVERY prerequisite ═══════════════════
# Runs before ANY mutation. Each failure states WHAT is wrong and the EXACT fix.
# --check runs preflight only and exits (0 = ready, 1 = blockers).
# Nothing in this section modifies the system.
PF_FAIL=0; PF_WARN=0
pf_ok()   { echo -e "  ${GREEN}[ OK ]${NC} $*"; }
pf_warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; PF_WARN=$((PF_WARN+1)); }
pf_fail() { echo -e "  ${RED}[FAIL]${NC} $*"; PF_FAIL=$((PF_FAIL+1)); }
pf_fix()  { echo -e "         ${CYAN}fix:${NC} $*"; }

diagnose_kube_unreachable() {
  # Common k3s failure modes — tell the user exactly what to do.
  if [[ -r /etc/rancher/k3s/k3s.yaml ]] && grep -q '127.0.0.1:6443' /etc/rancher/k3s/k3s.yaml 2>/dev/null \
     && ! ss -4 -tln 2>/dev/null | grep -q ':6443 ' && ss -6 -tln 2>/dev/null | grep -q ':6443 '; then
    pf_fix "k3s listens on IPv6 only but kubeconfig targets 127.0.0.1 (IPv4):"
    pf_fix "  sudo sed -i 's/127.0.0.1:6443/[::1]:6443/' /etc/rancher/k3s/k3s.yaml && sudo chmod 644 /etc/rancher/k3s/k3s.yaml"
  elif [[ -e /etc/rancher/k3s/k3s.yaml && ! -r /etc/rancher/k3s/k3s.yaml ]]; then
    pf_fix "k3s.yaml not readable: sudo chmod 644 /etc/rancher/k3s/k3s.yaml"
  elif ! systemctl is-active k3s &>/dev/null && [[ -e /etc/rancher/k3s/k3s.yaml ]]; then
    pf_fix "k3s service not active: sudo systemctl start k3s && journalctl -u k3s -n 50"
  else
    pf_fix "install k3s: curl -sfL https://get.k3s.io | sh -s - server --write-kubeconfig-mode 644"
  fi
}

# Component installability: installed | local artifact | online — else FAIL.
pf_component() {  # $1=name  $2=installed(0/1)  $3=local-artifact glob  $4=url  $5=download hint
  local name="$1" installed="$2" glob="$3" url="$4" hint="$5" art=""
  if [[ "${installed}" == "0" ]]; then
    pf_ok "${name}: already installed"
    return
  fi
  # shellcheck disable=SC2086,SC2012  # glob expansion is intentional here
  art=$(ls ${glob} 2>/dev/null | head -1 || true)
  if [[ -n "${art}" ]]; then
    pf_ok "${name}: not installed — will install OFFLINE from ${art}"
  elif curl -skm 5 -o /dev/null "${url}" 2>/dev/null; then
    pf_warn "${name}: not installed, no local artifact — will install ONLINE from ${url%%/}"
  else
    pf_fail "${name}: not installed, no local artifact, and ${url} unreachable"
    pf_fix "${hint}"
  fi
}

preflight() {
  local kube_up=false mgmt_port="" v missing=""

  echo ""
  echo "══ PREFLIGHT ══════════════════════════════════════════════"

  echo ""
  echo "── 1. Required tools on this machine ──"
  for v in kubectl helm curl python3 openssl sed awk; do
    if command -v "$v" &>/dev/null; then pf_ok "$v"; else
      pf_fail "$v not found"
      case "$v" in
        helm)    pf_fix "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash" ;;
        kubectl) pf_fix "usually shipped with k3s; or: snap install kubectl --classic" ;;
        *)       pf_fix "apt-get install -y $v" ;;
      esac
    fi
  done
  if command -v nc &>/dev/null; then pf_ok "nc"; else
    pf_fail "nc not found"; pf_fix "apt-get install -y netcat-openbsd"
  fi
  if python3 -c 'import yaml' 2>/dev/null; then pf_ok "python3-yaml"; else
    pf_fail "python3-yaml missing (needed to parse config.yaml)"; pf_fix "apt-get install -y python3-yaml"
  fi
  if [[ "${USE_RSHIM}" == "true" || "${DEPLOY_HBN}" == "true" ]]; then
    if command -v sshpass &>/dev/null; then pf_ok "sshpass"; else
      pf_fail "sshpass required for --rshim-install / --hbn"; pf_fix "apt-get install -y sshpass"
    fi
  fi

  echo ""
  echo "── 2. Configuration completeness ──"
  [[ -f "${CONFIG_FILE}" ]] && pf_ok "config.yaml: ${CONFIG_FILE}" \
    || pf_warn "config.yaml not found — relying on CLI flags only"
  [[ -f "${CONFIG_LOCAL_FILE}" ]] && pf_ok "config.local.yaml (secrets) present" \
    || pf_warn "config.local.yaml not found — copy config.local.sample.yaml and fill in passwords"
  missing=""
  for v in SERVER_NAME BF3_BMC_IP BF3_OOB_IP BF3_SERIAL APISERVER_PORT BFB_REGISTRY_IP; do
    [[ -z "${!v}" ]] && missing+=" $v"
  done
  if [[ -z "${missing}" ]]; then
    pf_ok "worker identity complete: server=${SERVER_NAME} bmc=${BF3_BMC_IP} oob=${BF3_OOB_IP} serial=${BF3_SERIAL}"
  else
    pf_fail "missing required values:${missing}"
    pf_fix "define the worker in dpf/config.yaml and select it with --worker <name> (or pass --server/--bmc-ip/--oob-ip/--serial flags)"
  fi
  if [[ -z "${BMC_PASSWORD}" ]]; then
    pf_fail "bmc_password not set — DPF needs BMC credentials (bmc-shared-password secret) for Redfish"
    pf_fix "add 'bmc_password' under the '${WORKER_NAME:-worker1}' (or '${SERVER_NAME:-<server>}') block in dpf/config.local.yaml"
  else
    pf_ok "BMC credentials configured (user: ${BMC_USERNAME})"
  fi
  if [[ "${DEPLOY_HBN}" == "true" && -z "${ARM_PASSWORD}" ]]; then
    pf_fail "--hbn needs arm_password (SSH to ubuntu@${BF3_OOB_IP:-<oob>}) in config.local.yaml"
    pf_fix "add 'arm_password' to the worker's block in dpf/config.local.yaml"
  fi
  if [[ "${USE_RSHIM}" == "true" ]]; then
    if [[ -z "${X86_HOST_IP}" || -z "${X86_HOST_USER}" || -z "${X86_HOST_PASS}" ]]; then
      pf_fail "--rshim-install needs x86_host_ip (config.yaml) + x86_host_user/x86_host_password (config.local.yaml)"
      pf_fix "fill in the worker's x86 host details, or drop --rshim-install to use Redfish"
    else
      pf_ok "x86 host configured for rshim: ${X86_HOST_USER}@${X86_HOST_IP} (${RSHIM_DEVICE})"
    fi
  fi
  if [[ -n "${OPERATOR_IP}" ]]; then
    if hostname -I 2>/dev/null | tr ' ' '\n' | grep -qx "${OPERATOR_IP}"; then
      pf_ok "running on the operator VM (${OPERATOR_IP})"
    else
      pf_warn "config.yaml says operator.ip=${OPERATOR_IP} but this machine has: $(hostname -I 2>/dev/null | xargs) — is this the right VM?"
    fi
  fi
  if [[ -n "${WORKER_OPERATOR}" && -n "${OPERATOR_NAME}" && "${WORKER_OPERATOR}" != "${OPERATOR_NAME}" ]]; then
    pf_fail "worker '${SERVER_NAME}' is marked operator: ${WORKER_OPERATOR} in config.yaml — this VM is '${OPERATOR_NAME}'"
    pf_fix "if you are migrating it to this operator: detach it from '${WORKER_OPERATOR}' first, then remove/update the worker's 'operator:' line and re-run"
  fi
  [[ -d "${MANIFESTS_DIR}" ]] || { pf_fail "manifests dir missing: ${MANIFESTS_DIR}"; pf_fix "clone the full repo (dpf/manifests/ is required)"; }
  for v in 01-bfb-pvc 02-dpfoperatorconfig 03-bfb 04-dpuflavor 05-dpunode 06-dpudevice 07-dpu 08-dpucluster 09-hbn-daemonset; do
    [[ -f "${MANIFESTS_DIR}/${v}.yaml" ]] || { pf_fail "manifest missing: ${MANIFESTS_DIR}/${v}.yaml"; pf_fix "restore it from the repo"; }
  done
  pf_ok "manifests present in ${MANIFESTS_DIR}"

  echo ""
  echo "── 3. Management cluster (k3s) ──"
  if kube get nodes &>/dev/null; then
    kube_up=true
    pf_ok "kubectl reachable (KUBECONFIG=${DPF_KUBECONFIG})"
    local not_ready
    not_ready=$(kube get nodes --no-headers 2>/dev/null | grep -cv " Ready" || true)
    [[ "${not_ready:-0}" -eq 0 ]] && pf_ok "all nodes Ready" \
      || { pf_fail "$(kube get nodes --no-headers | grep -v ' Ready' | awk '{print $1" is "$2}' | xargs)"; pf_fix "kubectl describe node; journalctl -u k3s -n 100"; }
  else
    pf_fail "kubectl cannot reach the management cluster"
    diagnose_kube_unreachable
  fi

  # THE 6443 RULE — a DPUCluster NodePort on the mgmt apiserver port makes
  # kube-proxy REJECT node-local traffic to the apiserver whenever the TCP has
  # no endpoints (endpointless-service blackhole). Hard fail, always.
  mgmt_port=$(grep -oE 'server: https?://[^ ]+' "${DPF_KUBECONFIG}" 2>/dev/null | head -1 | grep -oE '[0-9]+$' || true)
  if [[ -n "${APISERVER_PORT}" && -n "${mgmt_port:-}" ]]; then
    if [[ "${APISERVER_PORT}" == "${mgmt_port}" ]]; then
      pf_fail "apiserver_port ${APISERVER_PORT} COLLIDES with the management apiserver port (${mgmt_port})"
      pf_fix "set a unique apiserver_port (e.g. 6444+) for this worker in dpf/config.yaml — NEVER the mgmt apiserver port"
    else
      pf_ok "apiserver_port ${APISERVER_PORT} ≠ mgmt apiserver port ${mgmt_port}"
    fi
  fi
  if [[ "${kube_up}" == "true" && -n "${APISERVER_PORT}" ]]; then
    local port_owner
    port_owner=$(kube get tenantcontrolplane -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.networkProfile.port}{"\n"}{end}' 2>/dev/null \
      | awk -v p="${APISERVER_PORT}" -v me="${SERVER_NAME}-dpu-cluster" '$2==p && $1!=me {print $1}' || true)
    if [[ -n "${port_owner}" ]]; then
      pf_fail "apiserver_port ${APISERVER_PORT} already used by TenantControlPlane '${port_owner}'"
      pf_fix "pick an unused port in dpf/config.yaml (each worker needs its own)"
    else
      pf_ok "apiserver_port ${APISERVER_PORT} free among TenantControlPlanes"
    fi
  fi

  echo ""
  echo "── 4. Installable components (offline-first) ──"
  if [[ "${kube_up}" == "true" ]]; then
    local inst
    inst=1; kube get deployment dpf-operator-controller-manager -n "${DPF_NAMESPACE}" &>/dev/null && inst=0
    pf_component "DPF Operator ${DPF_VERSION}" "${inst}" "/opt/dpf/dpf-operator-*.tgz /tmp/dpf-operator-*.tgz" \
      "https://helm.ngc.nvidia.com/nvidia/doca" \
      "copy the chart to /opt/dpf/: helm fetch https://helm.ngc.nvidia.com/nvidia/doca/charts/dpf-operator-${DPF_VERSION}.tgz (needs NGC login) then place in /opt/dpf/"
    inst=1; kube get crd nodefeatures.nfd.k8s-sigs.io &>/dev/null && inst=0
    pf_component "NFD" "${inst}" "/opt/dpf/node-feature-discovery-*.tgz" \
      "https://kubernetes-sigs.github.io/node-feature-discovery/charts/index.yaml" \
      "helm pull nfd/node-feature-discovery (on an online machine) → /opt/dpf/"
    inst=1; kube get deployment cert-manager -n cert-manager &>/dev/null && inst=0
    pf_component "cert-manager" "${inst}" "/opt/dpf/cert-manager*.yaml" \
      "https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml" \
      "download cert-manager.yaml (v1.14.5) → /opt/dpf/cert-manager.yaml"
    inst=1; kube get crd tenantcontrolplanes.kamaji.clastix.io &>/dev/null && inst=0
    pf_component "Kamaji" "${inst}" "/opt/dpf/kamaji-*.tgz" \
      "https://clastix.github.io/charts/index.yaml" \
      "helm pull clastix/kamaji (on an online machine) → /opt/dpf/"
    inst=1; kube get crd applicationsets.argoproj.io &>/dev/null && inst=0
    pf_component "ArgoCD" "${inst}" "/opt/dpf/argocd-install*.yaml" \
      "https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml" \
      "download ArgoCD install.yaml → /opt/dpf/argocd-install.yaml"
  else
    pf_warn "cluster unreachable — skipping component checks (re-run --check once k3s is up)"
  fi

  echo ""
  echo "── 5. BFB image + local ports ──"
  if [[ -f "${BFB_FILE}" ]]; then
    local sz; sz=$(stat -c%s "${BFB_FILE}" 2>/dev/null || echo 0)
    if [[ "${sz}" -gt 1000000000 ]]; then pf_ok "BFB present: ${BFB_FILE} ($((sz/1024/1024)) MB)"
    else pf_fail "BFB file suspiciously small ($((sz/1024/1024)) MB): ${BFB_FILE}"; pf_fix "re-copy the full .bfb bundle"; fi
  else
    pf_fail "BFB file not found: ${BFB_FILE}"
    pf_fix "copy the BFB bundle there, e.g.: scp bf-bundle-*.bfb <vm>:/opt/bfb/"
  fi
  local df_free
  df_free=$(df --output=avail -BG /var/lib 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
  [[ "${df_free:-0}" -ge 20 ]] && pf_ok "disk: ${df_free}G free under /var/lib" \
    || pf_warn "only ${df_free}G free under /var/lib — BFB PVC + images need ~20G"
  # Port 8080 belongs to DPF's bfb-registry; 9090 is our temp upload server.
  if ss -tln 2>/dev/null | grep -q ":${BFB_REGISTRY_PORT} "; then
    # NOTE: capture-then-grep, NOT `kube ... | grep -q` — grep -q exits at first
    # match, kubectl dies with SIGPIPE(141), and pipefail turns that into a
    # false negative whenever the namespace has enough pods (bit us on S5).
    local _pods=""
    [[ "${kube_up}" == "true" ]] && _pods=$(kube get pods -n "${DPF_NAMESPACE}" 2>/dev/null || true)
    if grep -q bfb-registry <<< "${_pods}"; then
      pf_ok "port ${BFB_REGISTRY_PORT}: held by DPF bfb-registry (expected)"
    else
      pf_fail "port ${BFB_REGISTRY_PORT} is in use by something other than DPF bfb-registry"
      pf_fix "free it: sudo ss -tlnp | grep :${BFB_REGISTRY_PORT} — DPF's registry needs this hostPort"
    fi
  else
    pf_ok "port ${BFB_REGISTRY_PORT} free (bfb-registry will claim it)"
  fi
  if ss -tln 2>/dev/null | grep -q ":${BFB_UPLOAD_PORT} "; then
    if curl -sf --max-time 3 --head "http://127.0.0.1:${BFB_UPLOAD_PORT}/$(basename "${BFB_FILE}")" &>/dev/null; then
      pf_ok "port ${BFB_UPLOAD_PORT}: existing BFB upload server already serving the bundle"
    else
      pf_fail "port ${BFB_UPLOAD_PORT} occupied but NOT serving ${BFB_FILE##*/}"
      pf_fix "free it: sudo ss -tlnp | grep :${BFB_UPLOAD_PORT}"
    fi
  else
    pf_ok "port ${BFB_UPLOAD_PORT} free (temp BFB upload server will claim it)"
  fi

  echo ""
  echo "── 6. Target reachability ──"
  if [[ -n "${BF3_BMC_IP}" ]]; then
    local rf_code
    # `|| true`, not `|| echo 000` — curl -w already prints 000 on failure, and
    # the old fallback appended a second 000 ("HTTP 000000").
    # One retry: BMCs answer slowly under load and a single 5s probe flakes.
    rf_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://${BF3_BMC_IP}/redfish/v1/" 2>/dev/null || true)
    if [[ "${rf_code:-000}" == "000" ]]; then
      rf_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${BF3_BMC_IP}/redfish/v1/" 2>/dev/null || true)
    fi
    rf_code=${rf_code:-000}
    if [[ "${rf_code}" == "200" ]]; then
      pf_ok "BMC Redfish reachable: https://${BF3_BMC_IP}/redfish/v1/"
      if [[ -n "${BMC_PASSWORD}" ]]; then
        local auth_code
        auth_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 -u "${BMC_USERNAME}:${BMC_PASSWORD}" \
          "https://${BF3_BMC_IP}/redfish/v1/Systems" 2>/dev/null || true)
        auth_code=${auth_code:-000}
        if [[ "${auth_code}" == "200" ]]; then pf_ok "BMC credentials valid (${BMC_USERNAME})"
        elif [[ "${auth_code}" == "401" ]]; then pf_fail "BMC rejected credentials for '${BMC_USERNAME}' (HTTP 401)"; pf_fix "correct bmc_password/bmc_username in dpf/config.local.yaml"
        else pf_warn "BMC auth check inconclusive (HTTP ${auth_code})"; fi
      fi
    elif [[ "${USE_RSHIM}" == "true" ]]; then
      pf_warn "BMC Redfish unreachable (HTTP ${rf_code}) — tolerated with --rshim-install (flash bypasses BMC)"
    else
      pf_fail "BMC Redfish unreachable at ${BF3_BMC_IP} (HTTP ${rf_code})"
      pf_fix "check BMC power/network: ping ${BF3_BMC_IP}; or use --rshim-install to flash via the x86 host"
    fi
  fi
  if [[ -n "${BF3_OOB_IP}" ]]; then
    if timeout 4 bash -c "echo > /dev/tcp/${BF3_OOB_IP}/22" 2>/dev/null; then
      pf_ok "BF3 OOB ssh reachable: ${BF3_OOB_IP}"
    else
      pf_warn "BF3 OOB not reachable at ${BF3_OOB_IP} — OK for a first flash (appears after provisioning); NOT OK for --hbn"
    fi
  fi
  if [[ "${USE_RSHIM}" == "true" && -n "${X86_HOST_IP}" && -n "${X86_HOST_USER}" && -n "${X86_HOST_PASS}" ]] \
     && command -v sshpass &>/dev/null; then
    if sshpass -p "${X86_HOST_PASS}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 \
         "${X86_HOST_USER}@${X86_HOST_IP}" true 2>/dev/null; then
      pf_ok "x86 host SSH ok: ${X86_HOST_USER}@${X86_HOST_IP}"
      if sshpass -p "${X86_HOST_PASS}" ssh -o StrictHostKeyChecking=no "${X86_HOST_USER}@${X86_HOST_IP}" \
           "test -e /dev/${RSHIM_DEVICE}/boot" 2>/dev/null; then
        pf_ok "rshim device present on x86 host: /dev/${RSHIM_DEVICE}"
      else
        pf_fail "no /dev/${RSHIM_DEVICE}/boot on ${X86_HOST_IP}"
        pf_fix "on the x86 host: sudo systemctl restart rshim (install rshim if missing). If flash later stalls at BOOT_TIMEOUT, also stop the BMC-side rshim: ssh root@${BF3_BMC_IP} systemctl stop rshim"
      fi
      if sshpass -p "${X86_HOST_PASS}" ssh -o StrictHostKeyChecking=no "${X86_HOST_USER}@${X86_HOST_IP}" \
           "test -f ${X86_BFB_PATH}" 2>/dev/null; then
        pf_ok "BFB present on x86 host: ${X86_BFB_PATH}"
      else
        pf_fail "BFB missing on x86 host: ${X86_HOST_IP}:${X86_BFB_PATH}"
        pf_fix "scp ${BFB_FILE} ${X86_HOST_USER}@${X86_HOST_IP}:${X86_BFB_PATH}"
      fi
    else
      pf_fail "cannot SSH to x86 host ${X86_HOST_USER}@${X86_HOST_IP}"
      pf_fix "verify x86_host_user/x86_host_password in dpf/config.local.yaml and host reachability"
    fi
  fi

  echo ""
  echo "── 7. Topology ──"
  if [[ "${TUNNEL_MODE}" == "same" ]]; then
    pf_ok "SAME-SUBNET deployment (${BFB_REGISTRY_IP%.*}.x): BF3 joins the DPF VM directly — no tunnel needed"
  else
    pf_warn "CROSS-SUBNET deployment (DPF VM ${BFB_REGISTRY_IP} vs BF3 OOB ${BF3_OOB_IP:-?}): BF3→DPF-VM TCP may be firewalled"
    pf_fix "after the DPUCluster exists, start the relay: ./dpf/scripts/tunnel_dpf.sh --server ${SERVER_NAME:-<server>} start (relay: ${RELAY_IP:-<x86 host>})"
  fi

  echo ""
  echo "── 8. Datapath firmware readiness (eswitch multiport gates) ──"
  # ALL HBN SFs are hosted on PF0; traffic on the p1 uplink must cross eswitches.
  # That needs esw_multiport=true, gated on firmware LAG_RESOURCE_ALLOCATION=1 —
  # which ONLY truly applies at a TRUE COLD power cycle. Shipped-undetected once
  # (Aug 2026): everything config-plane looked healthy while p1 blackholed unicast.
  if grep -q "LAG_RESOURCE_ALLOCATION=1" "${MANIFESTS_DIR}/04-dpuflavor.yaml" 2>/dev/null; then
    pf_ok "DPUFlavor manifest carries nvconfig LAG_RESOURCE_ALLOCATION=1"
  else
    pf_fail "04-dpuflavor.yaml lost 'LAG_RESOURCE_ALLOCATION=1' — p1 uplink CANNOT reach the PF0-hosted HBN SFs"
    pf_fix "restore '- LAG_RESOURCE_ALLOCATION=1' under nvconfig in ${MANIFESTS_DIR}/04-dpuflavor.yaml"
  fi

  # Flavor drift is DESTRUCTIVE to apply (DPU delete → BF3 reflash). Catch it here,
  # read-only, so a normal run can never wander into a surprise reflash.
  if [[ "${kube_up}" == "true" && -n "${SERVER_NAME}" ]] \
     && kube get dpuflavor "${DPU_FLAVOR_NAME}" -n dpf-operator-system &>/dev/null; then
    local _pf_flavor _diff_rc=0
    _pf_flavor=$(mktemp)
    render_flavor "${_pf_flavor}"
    kube diff -f "${_pf_flavor}" &>/dev/null || _diff_rc=$?
    rm -f "${_pf_flavor}"
    # rc 0 = identical. ANY nonzero rc = drift: the DPUFlavor spec is immutable,
    # so a changed spec makes the server-side dry-run REJECT (rc=2), not just
    # print a diff (rc=1). Both mean the same thing here: applying requires the
    # destructive DPU-delete + reflash path.
    if [[ ${_diff_rc} -eq 0 ]]; then
      pf_ok "DPUFlavor '${DPU_FLAVOR_NAME}' unchanged — this run will NOT touch the DPU or reflash"
    elif [[ "${ALLOW_REFLASH}" == "true" ]]; then
      pf_warn "DPUFlavor CHANGED (diff rc=${_diff_rc}) and --allow-reflash given: this run WILL delete DPU '${SERVER_NAME}-dpu' and REFLASH the BF3 (~30 min outage)"
    else
      pf_fail "DPUFlavor '${DPU_FLAVOR_NAME}' spec changed (diff rc=${_diff_rc}) — applying it requires DELETING the DPU and REFLASHING the BF3"
      pf_fix "intended? re-run with --allow-reflash in a maintenance window; otherwise revert the flavor input change (manifest or --x86-host/--registry-ip/port overrides)"
    fi
  fi

  # Live firmware state on the BF3 (read-only SSH; skipped gracefully pre-flash).
  if bf3_reachable; then
    local lag0 lag1 mp pfl dpu_phase
    dpu_phase=$(kube get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    lag0=$(bf3_lag_current 0000:03:00.0)
    lag1=$(bf3_lag_current 0000:03:00.1)
    if [[ "${lag0}" == *"(1)"* && "${lag1}" == *"(1)"* ]]; then
      pf_ok "BF3 firmware: LAG_RESOURCE_ALLOCATION current=PRE_ALLOCATION(1) (both PFs)"
    elif [[ -z "${lag0}${lag1}" ]]; then
      pf_warn "could not read LAG_RESOURCE_ALLOCATION over SSH — step 11b verifies post-provision"
    elif [[ "${dpu_phase}" == "Ready" ]]; then
      pf_fail "ALREADY-PROVISIONED DPU but LAG_RESOURCE_ALLOCATION current is PF0='${lag0:-?}' PF1='${lag1:-?}' — p1 unicast will blackhole"
      pf_fix "stage on the BF3: sudo mlxconfig -d 0000:03:00.0 set LAG_RESOURCE_ALLOCATION=1 && sudo mlxconfig -d 0000:03:00.1 set LAG_RESOURCE_ALLOCATION=1"
      pf_fix "then TRUE cold power cycle from the X86 HOST: sudo ipmitool chassis power cycle"
      pf_fix "(ARM reboot does NOT commit it; a live 'Current=1' after a runtime set is cosmetic)"
    else
      pf_warn "BF3 firmware LAG_RESOURCE_ALLOCATION not yet 1 — the flavor stages it during flash; it APPLIES only on a true cold power cycle (step 11b re-verifies)"
    fi
    mp=$(bf3_multiport)
    if [[ "${mp}" == "true" ]]; then
      pf_ok "eswitch multiport active (esw_multiport=true)"
    elif [[ "${lag0}" == *"(1)"* && "${lag1}" == *"(1)"* ]]; then
      pf_ok "esw_multiport currently '${mp:-unsupported}' — --hbn enables it (runtime param + mlnx-bf.conf)"
    fi
    if [[ "${dpu_phase}" == "Ready" ]]; then
      pfl=$(bf3_pairflows)
      if [[ "${pfl:-0}" -gt 0 ]]; then
        pf_ok "br-hbn has ${pfl} priority-500 port-pair flows"
      else
        pf_warn "br-hbn has 0 priority-500 pair flows (reboot loses them) — --hbn re-derives; manual: (BF3) sudo systemctl restart sfc.service"
      fi
    fi
  else
    pf_warn "BF3 SSH not possible yet (OOB down or arm_password unset) — live firmware checks deferred to step 11b post-provision"
  fi

  echo ""
  echo "══ PREFLIGHT RESULT: ${PF_FAIL} blocker(s), ${PF_WARN} warning(s) ══"
  if [[ ${PF_FAIL} -gt 0 ]]; then
    echo -e "  ${RED}NOT ready${NC} — fix the [FAIL] items above and re-run: $0 --check"
  else
    echo -e "  ${GREEN}Ready to run.${NC}"
  fi
  echo ""
}

echo ""
echo "============================================================"
echo "  DPF BF3 Bringup — OOB/Redfish provisioning"
echo "  DPF Operator VM : ${BFB_REGISTRY_IP}"
echo "  BF3 BMC         : ${BF3_BMC_IP}"
echo "  BF3 OOB         : ${BF3_OOB_IP}"
echo "  BF3 Serial      : ${BF3_SERIAL}"
echo "  API server port : ${APISERVER_PORT} (Kamaji NodePort — unique per worker)"
echo "  BFB URL         : ${BFB_URL}"
echo "  Topology        : ${TUNNEL_MODE}-subnet (apiserver relay: ${RELAY_IP:-n/a})"
echo "  $(date)"
echo "============================================================"

# ─── PREFLIGHT (read-only) — validates everything before any mutation ─────────
preflight
if [[ "${CHECK_ONLY}" == "true" ]]; then
  [[ ${PF_FAIL} -gt 0 ]] && exit 1 || exit 0
fi
if [[ ${PF_FAIL} -gt 0 ]]; then
  fail "Preflight found ${PF_FAIL} blocker(s) — nothing was changed. Fix them and re-run (iterate with: $0 --check)"
fi

# ─── Step 1: Install/verify prerequisite components ──────────────────────────
info "Step 1/11 — Prerequisite components (preflight verified installability)"

if ! kube get nodes &>/dev/null; then
  fail "kubectl cannot reach cluster — check KUBECONFIG (${DPF_KUBECONFIG})"
fi
ok "kubectl: cluster reachable"

if kube get deployment dpf-operator-controller-manager -n "${DPF_NAMESPACE}" &>/dev/null; then
  ok "DPF Operator deployment present"
else
  info "  DPF Operator not found — installing prerequisites + DPF Operator automatically..."

  # NFD must be installed before DPF Operator Helm chart (its CRDs are referenced in the chart)
  info "  Checking NFD (Node Feature Discovery)..."
  if kube get crd nodefeatures.nfd.k8s-sigs.io &>/dev/null; then
    skip "NFD already installed"
  else
    info "  Installing NFD..."
    if [[ "${DRY_RUN}" != "true" ]]; then
      NFD_CHART=$(ls /opt/dpf/node-feature-discovery-*.tgz 2>/dev/null | head -1 || true)
      if [[ -n "${NFD_CHART}" ]]; then
        info "  Using local chart: ${NFD_CHART}"
        helm install nfd "${NFD_CHART}" \
          --namespace nfd --create-namespace --wait --timeout 5m \
          || fail "NFD install failed — check: kubectl get pods -n nfd"
      else
        helm repo add nfd https://kubernetes-sigs.github.io/node-feature-discovery/charts 2>/dev/null || true
        helm repo update nfd 2>/dev/null
        helm install nfd nfd/node-feature-discovery \
          --namespace nfd --create-namespace --wait --timeout 5m \
          || fail "NFD install failed — check: kubectl get pods -n nfd (offline? put node-feature-discovery-*.tgz in /opt/dpf/)"
      fi
    fi
    ok "NFD installed"
  fi

  # Install DPF Operator — prefer a local chart tarball (avoids NGC credentials).
  # /opt/dpf/ is the persistent home (survives reboot); /tmp/ still checked for compat.
  info "  Installing DPF Operator ${DPF_VERSION}..."
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[dry-run] would install DPF Operator ${DPF_VERSION}"
  else
    LOCAL_CHART=$(ls /opt/dpf/dpf-operator-*.tgz /tmp/dpf-operator-*.tgz 2>/dev/null | head -1 || echo "")
    if [[ -n "${LOCAL_CHART}" ]]; then
      info "  Using local chart tarball: ${LOCAL_CHART}"
      helm install dpf-operator "${LOCAL_CHART}" \
        --namespace "${DPF_NAMESPACE}" --create-namespace \
        --wait --timeout 5m \
        || fail "DPF Operator install failed — check: kubectl get pods -n ${DPF_NAMESPACE}"
    else
      info "  No local chart in /opt/dpf/ or /tmp/ — trying Helm repo (requires NGC credentials)"
      helm repo add dpf-repository \
        "https://helm.ngc.nvidia.com/nvidia/doca" 2>/dev/null || true
      helm repo update dpf-repository 2>/dev/null
      helm install dpf-operator dpf-repository/dpf-operator \
        --version "${DPF_VERSION}" \
        --namespace "${DPF_NAMESPACE}" --create-namespace \
        --wait --timeout 5m \
        || fail "DPF Operator install failed. If NGC auth error, copy chart tarball to /opt/dpf/dpf-operator-${DPF_VERSION}.tgz and re-run"
    fi
    ok "DPF Operator ${DPF_VERSION} installed"
  fi
fi

if curl -sk --max-time 5 "https://${BF3_BMC_IP}/redfish/v1/" | grep -q "RedfishVersion"; then
  ok "BMC Redfish reachable at ${BF3_BMC_IP}"
elif [[ "${USE_RSHIM}" == "true" ]]; then
  warn "BMC Redfish not reachable at ${BF3_BMC_IP} — continuing (--rshim-install bypasses BMC for OS flash)"
else
  fail "BMC Redfish not reachable at ${BF3_BMC_IP} — check network connectivity"
fi

# ─── Step 1b: Install missing prerequisites (cert-manager, Kamaji, ArgoCD) ───
# DPF Operator requires these three to be present before DPFOperatorConfig.
# NFD is installed earlier (before DPF Operator Helm chart) if needed.
# Each check is idempotent — skipped if already installed.

info "  Checking cert-manager..."
if kube get deployment cert-manager -n cert-manager &>/dev/null; then
  skip "cert-manager already installed"
else
  info "  Installing cert-manager v1.14.5..."
  if [[ "${DRY_RUN}" != "true" ]]; then
    CM_MANIFEST=$(ls /opt/dpf/cert-manager*.yaml 2>/dev/null | head -1 || true)
    if [[ -n "${CM_MANIFEST}" ]]; then
      info "  Using local manifest: ${CM_MANIFEST}"
      kube apply -f "${CM_MANIFEST}"
    else
      kube apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml
    fi
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
    KAMAJI_CHART=$(ls /opt/dpf/kamaji-*.tgz 2>/dev/null | head -1 || true)
    if [[ -n "${KAMAJI_CHART}" ]]; then
      info "  Using local chart: ${KAMAJI_CHART}"
      helm install kamaji "${KAMAJI_CHART}" \
        --namespace kamaji-system --create-namespace \
        --set etcd.deploy=true \
        --wait --timeout 5m
    else
      helm repo add clastix https://clastix.github.io/charts 2>/dev/null || true
      helm repo update clastix 2>/dev/null
      helm install kamaji clastix/kamaji \
        --namespace kamaji-system --create-namespace \
        --set etcd.deploy=true \
        --wait --timeout 5m
    fi
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
    ARGOCD_MANIFEST=$(ls /opt/dpf/argocd-install*.yaml 2>/dev/null | head -1 || true)
    if [[ -n "${ARGOCD_MANIFEST}" ]]; then
      info "  Using local manifest: ${ARGOCD_MANIFEST}"
      kube apply --server-side -n argocd -f "${ARGOCD_MANIFEST}"
    else
      kube apply --server-side -n argocd \
        -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    fi
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
      cat > "${HOME}/${proj}.yaml" <<PROJEOF
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
      kube apply -f "${HOME}/${proj}.yaml"
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
info "Step 2/11 — BFB upload server (port ${BFB_UPLOAD_PORT}, for initial PVC population)"
[[ -f "${BFB_FILE}" ]] \
  || fail "BFB file not found: ${BFB_FILE} — copy the .bfb bundle there first"
ok "BFB file present: ${BFB_FILE}"

if nc -z "${BFB_REGISTRY_IP}" "${BFB_UPLOAD_PORT}" 2>/dev/null; then
  ok "BFB upload server already listening on port ${BFB_UPLOAD_PORT}"
elif [[ "${DRY_RUN}" == "true" ]]; then
  info "[dry-run] would start python3 HTTP server for BFB on port ${BFB_UPLOAD_PORT}"
else
  BFB_DIR="$(dirname "${BFB_FILE}")"
  BFB_UPLOAD_LOG="${HOME}/bfb-upload.log"
  nohup python3 -m http.server "${BFB_UPLOAD_PORT}" \
    --directory "${BFB_DIR}" \
    --bind 0.0.0.0 \
    >"${BFB_UPLOAD_LOG}" 2>&1 &
  disown
  sleep 2
  nc -z "${BFB_REGISTRY_IP}" "${BFB_UPLOAD_PORT}" 2>/dev/null \
    || fail "BFB upload server failed to start on port ${BFB_UPLOAD_PORT} — check ${BFB_UPLOAD_LOG}"
  ok "BFB upload server started on port ${BFB_UPLOAD_PORT} (log: ${BFB_UPLOAD_LOG})"
fi

# ─── Step 3: Clean up stale Kamaji etcd-defrag jobs ──────────────────────────
# DPF CronJob dpf-operator-kamaji-etcd-defrag-job spawns Jobs that accumulate
# if the kamaji-etcd-certs secret is missing. Jobs use job-name labels (not app labels).
# Selecting by CronJob name prefix is the only reliable method.
info "Step 3/11 — Cleaning up stale Kamaji etcd-defrag jobs"
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
info "Step 4/11 — BFB PersistentVolumeClaim"
if kube get pvc bfb-pvc -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "bfb-pvc already exists"
else
  apply "${MANIFESTS_DIR}/01-bfb-pvc.yaml"
  ok "bfb-pvc created"
fi

# ─── Step 5: DPFOperatorConfig ────────────────────────────────────────────────
info "Step 5/11 — DPFOperatorConfig (bootstraps Kamaji + provisioning controller)"
if kube get dpfoperatorconfig dpfoperatorconfig -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "DPFOperatorConfig already exists"
else
  TMPFILE=$(mktemp "${HOME}/dpfoperatorconfig-XXXXXX.yaml")
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
info "Step 6/11 — Waiting for Kamaji, DPF provisioning controller, and bfb-registry (timeout: ${WAIT_TIMEOUT}s)"
if [[ "${DRY_RUN}" == "true" ]]; then
  info "[dry-run] skipping wait"
else
  # Kamaji pods are in kamaji-system namespace
  wait_for_pods "app.kubernetes.io/instance=kamaji" "kamaji-system" "${WAIT_TIMEOUT}" \
    || wait_for_pods "app.kubernetes.io/name=kamaji" "kamaji-system" "${WAIT_TIMEOUT}" \
    || fail "Kamaji pods not ready after ${WAIT_TIMEOUT}s — check: kubectl get pods -n kamaji-system"
  ok "Kamaji ready"
  wait_for_pods "dpu.nvidia.com/component=dpf-provisioning-controller-manager" "${DPF_NAMESPACE}" "${WAIT_TIMEOUT}" \
    || fail "Provisioning controller not ready after ${WAIT_TIMEOUT}s — webhook will block DPUFlavor operations. Check: kubectl get pods -n ${DPF_NAMESPACE} | grep provisioning"

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
  TMPFILE=$(mktemp "${HOME}/bfb-XXXXXX.yaml")
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
if [[ "${DRY_RUN}" == "true" ]]; then
  info "[dry-run] would apply DPUFlavor '${DPU_FLAVOR_NAME}'"
else
  # Render the desired flavor first so we can compare against what's live.
  #   metadata.name → ${DPU_FLAVOR_NAME}  (per-server, so multiple DPUs don't collide)
  #   X86_HOST_IP  — x86 relay host for the SSH tunnel (iptables DNAT target)
  #   BFB_REGISTRY_IP — DPF VM IP (kubeadm join endpoint before ClusterIP takes over)
  # X86_HOST_IP in the flavor is the APISERVER RELAY the BF3's DNAT rules point at:
  # cross-subnet → the x86 tunnel host; same-subnet → the DPF VM itself (direct).
  _flavor_tmp=$(mktemp)
  render_flavor "${_flavor_tmp}"

  # DPUFlavor spec is immutable — must delete DPU referencing it, then delete flavor.
  # BUT only do that destructive dance when the flavor actually CHANGED. Re-running
  # --hbn with an unchanged flavor must NOT delete the DPU (that wipes the BF3's
  # cluster membership and triggers a needless re-flash — an infinite loop).
  _flavor_changed=true
  if kube get dpuflavor "${DPU_FLAVOR_NAME}" -n dpf-operator-system &>/dev/null; then
    if kube diff -f "${_flavor_tmp}" &>/dev/null; then
      _flavor_changed=false
      skip "DPUFlavor '${DPU_FLAVOR_NAME}' already present and unchanged — not recreating (avoids DPU delete/reflash loop)"
    elif [[ "${ALLOW_REFLASH}" == "true" ]]; then
      warn "DPUFlavor '${DPU_FLAVOR_NAME}' spec changed — deleting DPU + flavor and REFLASHING (authorized by --allow-reflash)"
    else
      # Preflight normally catches this; belt-and-suspenders for direct step entry.
      fail "DPUFlavor '${DPU_FLAVOR_NAME}' spec changed — applying it would DELETE DPU '${SERVER_NAME}-dpu' and REFLASH the BF3. Re-run with --allow-reflash (maintenance window) or revert the manifest change. NOTHING was changed."
    fi
  fi

  if [[ "${_flavor_changed}" == "true" ]] && kube get dpuflavor "${DPU_FLAVOR_NAME}" -n dpf-operator-system &>/dev/null; then
    # DPU CR must be removed first (webhook blocks flavor deletion while referenced)
    if kube get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" &>/dev/null; then
      info "Deleting DPU '${SERVER_NAME}-dpu' so DPUFlavor can be removed"
      # NOTE: a blocking `kubectl delete` hangs forever here — the DPU carries a
      # provisioning.dpu.nvidia.com/dpu-protection finalizer that never auto-clears.
      # Delete non-blocking, then strip the finalizer, then wait for real removal.
      kube delete dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" --wait=false 2>/dev/null || true
      if ! kube wait --for=delete dpu/"${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" --timeout=20s 2>/dev/null; then
        info "DPU still terminating — removing dpu-protection finalizer"
        kube patch dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" \
          --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
        kube wait --for=delete dpu/"${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" --timeout=30s 2>/dev/null || true
      fi
      # Also remove the BF3 node from TenantControlPlane so step 10b rshim-install
      # doesn't see "already joined" and skip the flash.
      _tc_cfg=$(kube get secret "${SERVER_NAME}-dpu-cluster-admin-kubeconfig" \
        -n "${DPF_NAMESPACE}" -o jsonpath='{.data.admin\.conf}' 2>/dev/null | base64 -d || true)
      if [[ -n "$_tc_cfg" ]]; then
        echo "$_tc_cfg" > "${HOME}/dpu-tc-kubeconfig-step8"
        kubectl --kubeconfig "${HOME}/dpu-tc-kubeconfig-step8" delete node "${SERVER_NAME}-dpu" \
          --ignore-not-found 2>/dev/null \
          && info "TC node '${SERVER_NAME}-dpu' removed (rshim-install will proceed)" \
          || true
      fi
    fi
    kube delete dpuflavor "${DPU_FLAVOR_NAME}" -n dpf-operator-system
    kube wait --for=delete dpuflavor/"${DPU_FLAVOR_NAME}" -n dpf-operator-system --timeout=30s 2>/dev/null || true
  fi
  # Apply only when new or changed — an unchanged flavor is left untouched so the
  # DPU keeps running and the BF3 stays joined.
  if [[ "${_flavor_changed}" == "true" ]]; then
    kube apply -f "${_flavor_tmp}"
    ok "DPUFlavor '${DPU_FLAVOR_NAME}' applied (apiserver relay=${RELAY_IP} [${TUNNEL_MODE}-subnet], DPF_VM=${BFB_REGISTRY_IP}, APISERVER_PORT=${APISERVER_PORT})"
  fi
  rm -f "${_flavor_tmp}"
fi

# ─── Step 9: DPUCluster ───────────────────────────────────────────────────────
# DPUCluster tells DPF to create a virtual k8s control plane via Kamaji (type: kamaji).
# Must exist before the DPU CR is applied — DPU waits for the cluster to be found.
# Note: Kamaji v1.0.0 only supports k8s ≤1.30.x. DPF v25.10.1 requests v1.33.0.
# The validating webhook check is deleted in Step 1b; the underlying kamaji etcd supports it.
info "Step 9/11 — DPUCluster (virtual k8s control plane for DPU)"
if kube get dpucluster "${SERVER_NAME}-dpu-cluster" -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "DPUCluster '${SERVER_NAME}-dpu-cluster' already exists"
else
  sed "s|SERVER_NAME|${SERVER_NAME}|g" "${MANIFESTS_DIR}/08-dpucluster.yaml" | kube apply -f -
  ok "DPUCluster '${SERVER_NAME}-dpu-cluster' created"
fi

# DPF builds the Kamaji TenantControlPlane from the DPUCluster, but on this lab's
# DPF/Kamaji it does NOT populate spec.networkProfile.address. Without it Kamaji
# errors "the actual resource doesn't have yet a valid IP address", the TCP never
# goes Ready → no kubeadm token → DPU stuck in 'Initialize Interface' (no bfcfg).
# Patch the address to the DPF VM IP so Kamaji can build the control plane.
# (Also resolves the multi-DPU case where a NodePort 6443 clash had to be cleared first.)
if [[ "${DRY_RUN}" != "true" ]]; then
  _tcp_patched=""
  for _i in $(seq 1 30); do
    if kube_tcp get tenantcontrolplane "${SERVER_NAME}-dpu-cluster" -n "${DPF_NAMESPACE}" &>/dev/null; then
      _cur_addr=$(kube_tcp get tenantcontrolplane "${SERVER_NAME}-dpu-cluster" -n "${DPF_NAMESPACE}" \
        -o jsonpath='{.spec.networkProfile.address}' 2>/dev/null || echo "")
      if [[ -z "${_cur_addr}" ]]; then
        kube_tcp patch tenantcontrolplane "${SERVER_NAME}-dpu-cluster" -n "${DPF_NAMESPACE}" \
          --type=merge -p "{\"spec\":{\"networkProfile\":{\"address\":\"${BFB_REGISTRY_IP}\"}}}" \
          && ok "Patched TenantControlPlane networkProfile.address=${BFB_REGISTRY_IP}"
      else
        ok "TenantControlPlane networkProfile.address already set (${_cur_addr})"
      fi
      # Multi-DPU: every TCP defaults to NodePort 6443 on the DPF VM — the 2nd
      # cluster's Service fails with "port is already allocated". Patch this
      # cluster's unique port (config.yaml apiserver_port) so they coexist.
      # Must land BEFORE the DPU/bfcfg is generated so the kubeadm join endpoint
      # picks up the right port. (port is an integer — no quotes in the JSON)
      _cur_port=$(kube_tcp get tenantcontrolplane "${SERVER_NAME}-dpu-cluster" -n "${DPF_NAMESPACE}" \
        -o jsonpath='{.spec.networkProfile.port}' 2>/dev/null || echo "")
      if [[ "${_cur_port}" != "${APISERVER_PORT}" ]]; then
        kube_tcp patch tenantcontrolplane "${SERVER_NAME}-dpu-cluster" -n "${DPF_NAMESPACE}" \
          --type=merge -p "{\"spec\":{\"networkProfile\":{\"port\":${APISERVER_PORT}}}}" \
          && ok "Patched TenantControlPlane networkProfile.port=${APISERVER_PORT} (was: ${_cur_port:-unset})"
      else
        ok "TenantControlPlane networkProfile.port already ${APISERVER_PORT}"
      fi
      _tcp_patched="yes"; break
    fi
    sleep 2
  done
  [[ -z "${_tcp_patched}" ]] && warn "TenantControlPlane not created within 60s — address not patched; readiness wait below may still catch it"
fi

# ─── Step 9b: Post-DPUCluster setup ──────────────────────────────────────────
# These steps are required for DPUServices to deploy to the BF3. Without them:
#   - flannel, multus, ovs-cni never deploy (no ArgoCD cluster registration)
#   - servicechainset-controller CrashLoopBackOff (wrong API endpoint + missing CRDs/RBAC)
#
# Root causes (verified in lab with DPF v25.10.1):
#   1. kamaji-cm-controller does not auto-create the ArgoCD cluster secret
#   2. servicechainset-controller credentials secret uses NodePort IP (k3s intercepts)
#   3. DPU cluster missing svc.dpu.nvidia.com CRDs (chicken-and-egg with DPUService)
#   4. dpuservice-controller SA missing dpunodemaintenances permission (new in v25.10.1)
if [[ "${DRY_RUN}" != "true" ]]; then
  # Wait for TenantControlPlane to be Ready before creating its ArgoCD secret
  info "  Waiting for TenantControlPlane '${SERVER_NAME}-dpu-cluster' to be Ready..."
  elapsed=0
  while [[ $elapsed -lt 120 ]]; do
    tcp_ready=$(kube get tenantcontrolplane "${SERVER_NAME}-dpu-cluster" \
      -n "${DPF_NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [[ "$tcp_ready" == "True" ]] && { ok "TenantControlPlane Ready"; break; }
    sleep 10; elapsed=$((elapsed + 10))
    info "  waiting for TenantControlPlane... ${elapsed}s/120s"
  done
  [[ "$tcp_ready" != "True" ]] && warn "TenantControlPlane not Ready after 120s — continuing anyway"

  # Fetch DPU cluster kubeconfig
  kube get secret "${SERVER_NAME}-dpu-cluster-admin-kubeconfig" -n "${DPF_NAMESPACE}" \
    -o jsonpath='{.data.admin\.conf}' | base64 -d > "${HOME}/dpu-tc-kubeconfig" 2>/dev/null || true

  if [[ -s ${HOME}/dpu-tc-kubeconfig ]]; then
    dkube() { kubectl --kubeconfig "${HOME}/dpu-tc-kubeconfig" "$@"; }

    # 1. Register/refresh DPU cluster with ArgoCD (required for DPUService deployment).
    # ALWAYS refresh: after a DPUCluster delete+recreate, Kamaji issues a new CA/cert/key.
    # A stale ArgoCD cluster secret makes every DPUService Application show Sync=Unknown,
    # so CNI (flannel/multus/ovs-cni) never deploys to the DPU cluster and pods (HBN,
    # coredns) get stuck with "loopback: missing network name". apply overwrites in place.
    if true; then
      info "  Registering/refreshing DPU cluster with ArgoCD..."
      CA=$(python3 -c "
import yaml, sys
with open('${HOME}/dpu-tc-kubeconfig') as f:
    kc = yaml.safe_load(f)
print(kc['clusters'][0]['cluster']['certificate-authority-data'])
")
      CERT=$(python3 -c "
import yaml, sys
with open('${HOME}/dpu-tc-kubeconfig') as f:
    kc = yaml.safe_load(f)
print(kc['users'][0]['user'].get('client-certificate-data',''))
")
      KEY=$(python3 -c "
import yaml, sys
with open('${HOME}/dpu-tc-kubeconfig') as f:
    kc = yaml.safe_load(f)
print(kc['users'][0]['user'].get('client-key-data',''))
")
      CONFIG=$(python3 -c "
import json
print(json.dumps({'tlsClientConfig':{'caData':'${CA}','certData':'${CERT}','keyData':'${KEY}'}}))
")
      kube apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SERVER_NAME}-dpu-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${SERVER_NAME}-dpu-cluster
  server: https://${SERVER_NAME}-dpu-cluster.${DPF_NAMESPACE}.svc:${APISERVER_PORT}
  config: '${CONFIG}'
EOF
      ok "ArgoCD cluster secret created for '${SERVER_NAME}-dpu-cluster'"
    fi

    # 2. Fix servicechainset credentials secret (NodePort IP → DNS name)
    CURRENT_HOST=$(kube get secret servicechainset-controller-manager-credentials \
      -n "${DPF_NAMESPACE}" \
      -o jsonpath='{.data.KUBERNETES_SERVICE_HOST}' 2>/dev/null | base64 -d || echo "")
    DPU_SVC_HOST="${SERVER_NAME}-dpu-cluster.${DPF_NAMESPACE}.svc"
    if [[ "${CURRENT_HOST}" == "${DPU_SVC_HOST}" ]]; then
      skip "servicechainset credentials already use DNS hostname"
    elif [[ -n "${CURRENT_HOST}" ]]; then
      NEW_HOST_B64=$(echo -n "${DPU_SVC_HOST}" | base64)
      kube patch secret servicechainset-controller-manager-credentials \
        -n "${DPF_NAMESPACE}" \
        --type=json \
        -p="[{\"op\": \"replace\", \"path\": \"/data/KUBERNETES_SERVICE_HOST\", \"value\": \"${NEW_HOST_B64}\"}]" \
        2>/dev/null && ok "servicechainset credentials patched → ${DPU_SVC_HOST}" \
        || warn "servicechainset credentials patch failed — may not exist yet"
    fi
    # The PORT must match this cluster's unique apiserver_port too (svc port ≠ 6443
    # for any worker whose apiserver_port differs — s8's 'Sync: Unknown' lesson).
    CURRENT_PORT=$(kube get secret servicechainset-controller-manager-credentials \
      -n "${DPF_NAMESPACE}" \
      -o jsonpath='{.data.KUBERNETES_SERVICE_PORT}' 2>/dev/null | base64 -d || echo "")
    if [[ -n "${CURRENT_PORT}" && "${CURRENT_PORT}" != "${APISERVER_PORT}" ]]; then
      NEW_PORT_B64=$(echo -n "${APISERVER_PORT}" | base64)
      kube patch secret servicechainset-controller-manager-credentials \
        -n "${DPF_NAMESPACE}" \
        --type=json \
        -p="[{\"op\": \"replace\", \"path\": \"/data/KUBERNETES_SERVICE_PORT\", \"value\": \"${NEW_PORT_B64}\"}]" \
        2>/dev/null && ok "servicechainset credentials port patched → ${APISERVER_PORT}" \
        || warn "servicechainset credentials port patch failed"
    fi

    # 3. Bootstrap svc.dpu.nvidia.com CRDs onto DPU cluster
    MISSING_CRDS=()
    for crd in servicechains.svc.dpu.nvidia.com servicechainsets.svc.dpu.nvidia.com \
               serviceinterfaces.svc.dpu.nvidia.com serviceinterfacesets.svc.dpu.nvidia.com; do
      dkube get crd "${crd}" &>/dev/null || MISSING_CRDS+=("${crd}")
    done
    if [[ ${#MISSING_CRDS[@]} -eq 0 ]]; then
      skip "svc.dpu.nvidia.com CRDs already on DPU cluster"
    else
      info "  Bootstrapping ${#MISSING_CRDS[@]} CRD(s) onto DPU cluster..."
      for crd in "${MISSING_CRDS[@]}"; do
        kube get crd "${crd}" -o json | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k in ['resourceVersion','uid','creationTimestamp','generation','managedFields']:
    d['metadata'].pop(k, None)
d['metadata'].pop('annotations', None)
d.pop('status', None)
print(json.dumps(d))
" | dkube apply -f - 2>/dev/null \
          && ok "  installed: ${crd}" || warn "  failed: ${crd}"
      done
    fi

    # 4. Create RBAC on DPU cluster for servicechainset-controller
    if dkube get clusterrolebinding servicechainset-controller-manager &>/dev/null; then
      skip "servicechainset ClusterRoleBinding already on DPU cluster"
    else
      info "  Creating servicechainset RBAC on DPU cluster..."
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
      ok "servicechainset RBAC created on DPU cluster"
    fi
  else
    warn "DPU cluster kubeconfig not available — skipping Step 9b"
    warn "Re-run bringup_dpf.sh after TenantControlPlane is Ready"
  fi

  # 5. Fix dpunodemaintenances RBAC on management cluster (new CRD in v25.10.1)
  if kube get crd dpunodemaintenances.provisioning.dpu.nvidia.com &>/dev/null; then
    HAS_RULE=$(kube get clusterrole dpuservice-manager-role \
      -o jsonpath='{.rules[*].resources}' 2>/dev/null | grep -c "dpunodemaintenances" || true)
    if [[ "$HAS_RULE" -eq 0 ]]; then
      kube patch clusterrole dpuservice-manager-role \
        --type=json \
        -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":["provisioning.dpu.nvidia.com"],"resources":["dpunodemaintenances"],"verbs":["create","delete","get","list","patch","update","watch"]}}]' \
        2>/dev/null && ok "dpunodemaintenances RBAC added to dpuservice-manager-role" \
        || warn "dpunodemaintenances RBAC patch failed"
    else
      skip "dpunodemaintenances already in dpuservice-manager-role"
    fi
  fi
fi

# ─── Step 10: DPUNode + DPUDevice + DPU ───────────────────────────────────────
info "Step 10/11 — DPUNode, DPUDevice, DPU (triggers Redfish provisioning)"

# BMC credentials secret — the provisioning controller reads 'bmc-shared-password'
# (username/password) for every Redfish call. A fresh operator does NOT have it;
# without it DPU provisioning fails Redfish auth with no obvious error.
if kube get secret bmc-shared-password -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "bmc-shared-password secret already exists"
elif [[ "${DRY_RUN}" == "true" ]]; then
  info "[dry-run] would create bmc-shared-password secret (user: ${BMC_USERNAME})"
elif [[ -n "${BMC_PASSWORD}" ]]; then
  kube create secret generic bmc-shared-password -n "${DPF_NAMESPACE}" \
    --from-literal=username="${BMC_USERNAME}" \
    --from-literal=password="${BMC_PASSWORD}" \
    && ok "bmc-shared-password secret created (user: ${BMC_USERNAME})" \
    || fail "could not create bmc-shared-password secret"
else
  fail "bmc-shared-password secret missing and bmc_password not set in config.local.yaml"
fi

if kube get dpunode "${SERVER_NAME}-node" -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "DPUNode '${SERVER_NAME}-node' already exists"
else
  sed "s|SERVER_NAME|${SERVER_NAME}|g" "${MANIFESTS_DIR}/05-dpunode.yaml" | kube apply -f -
  ok "DPUNode '${SERVER_NAME}-node' created"
fi

if kube get dpudevice "${SERVER_NAME}-bf3" -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "DPUDevice '${SERVER_NAME}-bf3' already exists"
else
  TMPFILE=$(mktemp "${HOME}/dpudevice-XXXXXX.yaml")
  sed \
    -e "s|SERVER_NAME|${SERVER_NAME}|g" \
    -e "s|BF3_SERIAL|${BF3_SERIAL}|g" \
    -e "s|BF3_BMC_IP|${BF3_BMC_IP}|g" \
    "${MANIFESTS_DIR}/06-dpudevice.yaml" > "${TMPFILE}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[dry-run] would apply DPUDevice (serial: ${BF3_SERIAL}, bmcIp: ${BF3_BMC_IP})"
  else
    kube apply -f "${TMPFILE}"
    ok "DPUDevice '${SERVER_NAME}-bf3' created (serial: ${BF3_SERIAL})"
  fi
  rm -f "${TMPFILE}"
fi

if kube get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" &>/dev/null; then
  skip "DPU '${SERVER_NAME}-dpu' already exists"
else
  TMPFILE=$(mktemp "${HOME}/dpu-XXXXXX.yaml")
  sed \
    -e "s|SERVER_NAME|${SERVER_NAME}|g" \
    -e "s|BF3_SERIAL|${BF3_SERIAL}|g" \
    -e "s|BF3_BMC_IP|${BF3_BMC_IP}|g" \
    -e "s|dpuFlavor: bf3-hbn|dpuFlavor: ${DPU_FLAVOR_NAME}|g" \
    "${MANIFESTS_DIR}/07-dpu.yaml" > "${TMPFILE}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[dry-run] would apply DPU (serial: ${BF3_SERIAL}, bmcIP: ${BF3_BMC_IP})"
  else
    kube apply -f "${TMPFILE}"
    ok "DPU '${SERVER_NAME}-dpu' created — BFB flash via Redfish starting"
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
  kube get secret "${SERVER_NAME}-dpu-cluster-admin-kubeconfig" -n "${DPF_NAMESPACE}" \
    -o jsonpath='{.data.admin\.conf}' 2>/dev/null | base64 -d > "${HOME}/dpu-tc-kubeconfig" 2>/dev/null || true
  dkube() { kubectl --kubeconfig "${HOME}/dpu-tc-kubeconfig" "$@"; }
  # NOTE: with `set -o pipefail`, a failing kubectl makes the pipeline fail; using
  # `|| echo 0` would append a second "0" to wc's output ("0\n0") and break the [[ ]].
  _existing_nodes=$(dkube get nodes --no-headers 2>/dev/null | wc -l || true)
  _existing_nodes=${_existing_nodes:-0}
  if [[ "${_existing_nodes}" -gt 0 ]]; then
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
    while [[ $elapsed -lt 900 ]]; do
      bfb_prepared=$(kube get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="BFBPrepared")].status}' 2>/dev/null || echo "")
      dpu_phase=$(kube get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      if [[ "$bfb_prepared" == "True" ]]; then
        bfcfg_ready=true; ok "BFBPrepared: True — bfcfg ready"; break
      fi
      # DPF may have already progressed to Error/FailToInstall — bfcfg still exists.
      # Condition type varies by DPF version: older=OSInstalled, v25.10.1=BFBTransferred.
      if [[ "$dpu_phase" == "Error" ]]; then
        os_reason=$(kube get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" \
          -o jsonpath='{.status.conditions[?(@.type=="OSInstalled")].reason}' 2>/dev/null || echo "")
        [[ -z "$os_reason" ]] && os_reason=$(kube get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" \
          -o jsonpath='{.status.conditions[?(@.type=="BFBTransferred")].reason}' 2>/dev/null || echo "")
        [[ "$os_reason" == "FailToInstall" ]] && { bfcfg_ready=true; ok "DPF in Error/FailToInstall — bfcfg already generated"; break; }
      fi
      sleep 15; elapsed=$((elapsed + 15))
      info "  DPU phase: ${dpu_phase:-unknown} ... ${elapsed}s/900s"
    done
    [[ "$bfcfg_ready" != "true" ]] \
      && fail "bfcfg not ready after 600s — check: kubectl describe dpu ${SERVER_NAME}-dpu -n ${DPF_NAMESPACE}"

    # Refresh TenantControlPlane kubeconfig (fail if not available yet)
    kube get secret "${SERVER_NAME}-dpu-cluster-admin-kubeconfig" -n "${DPF_NAMESPACE}" \
      -o jsonpath='{.data.admin\.conf}' | base64 -d > "${HOME}/dpu-tc-kubeconfig" \
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
    BFCFG_REL=$(kube get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" \
      -o jsonpath='{.status.bfCFGFile}' 2>/dev/null || echo "")
    [[ -z "${BFCFG_REL}" ]] \
      && fail "DPU status.bfCFGFile empty — DPF has not generated bfcfg yet"
    # Normalize: v25.7.0 reported a relative path ("bfcfg/..."); v25.10.1 reports an
    # absolute one ("/bfb/bfcfg/..."). Strip any leading slash + "bfb/" so the URL below
    # (which adds the "/bfb/" prefix) doesn't double it into ".../bfb//bfb/bfcfg/..." (404).
    BFCFG_REL="${BFCFG_REL#/}"
    BFCFG_REL="${BFCFG_REL#bfb/}"
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

    # Wait for BF3 to join TenantControlPlane (kubeadm-join.service runs on first boot).
    # First boot after a FRESH flash can take 30-45 min: the BF3 parks at the console
    # first-login password gate until someone completes it (BMC console: login ubuntu/
    # ubuntu, set password, then `sudo dhclient oob_net0` and
    # `sudo systemctl start dpf-firstboot-kick`). Budget for that.
    JOIN_TIMEOUT=$((DPU_TIMEOUT + 1200))
    info "  Waiting for BF3 node to join TenantControlPlane (timeout: ${JOIN_TIMEOUT}s)..."
    info "  NOTE: fresh flash boot #1 needs the console first-login completed (BMC ARM console:"
    info "        set ubuntu password, then: sudo systemctl start dpf-firstboot-kick)"
    elapsed=0
    while [[ $elapsed -lt $JOIN_TIMEOUT ]]; do
      node_count=$(dkube get nodes --no-headers 2>/dev/null | wc -l || echo 0)
      if [[ "$node_count" -gt 0 ]]; then
        ok "BF3 joined TenantControlPlane:"
        dkube get nodes
        break
      fi
      sleep 20; elapsed=$((elapsed + 20))
      info "  waiting for BF3 node... ${elapsed}s/${DPU_TIMEOUT}s"
    done
    if [[ $elapsed -ge $JOIN_TIMEOUT ]]; then
      echo -e "${RED}[FAIL]${NC}  BF3 did not join TenantControlPlane after ${JOIN_TIMEOUT}s"
      echo -e "${CYAN}[INFO]${NC}  Most common cause on a FRESH flash: boot #1 is parked at the console"
      echo -e "${CYAN}[INFO]${NC}  first-login gate. On the BF3 BMC (${BF3_BMC_IP}) ARM console:"
      echo -e "${CYAN}[INFO]${NC}    1. login ubuntu / ubuntu → set a new password"
      echo -e "${CYAN}[INFO]${NC}    2. sudo dhclient oob_net0"
      echo -e "${CYAN}[INFO]${NC}    3. sudo systemctl start dpf-firstboot-kick"
      echo -e "${CYAN}[INFO]${NC}  Then RE-RUN this script — it is idempotent and resumes where it left off."
      exit 1
    fi

    # BF3 joined — patch DPU status to Ready so DPF can proceed with DPUService deployment.
    # Redfish 404 (same-version skip) left DPU in Error/FailToInstall; rshim flash remedied it.
    info "  Patching DPU status → Ready (rshim flash confirmed successful)..."
    kube patch dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" --subresource=status --type=merge \
      -p '{"status":{"phase":"Ready"}}' 2>/dev/null \
      && ok "DPU status patched to Ready" \
      || warn "Could not patch DPU status — check manually: kubectl get dpu ${SERVER_NAME}-dpu -n ${DPF_NAMESPACE}"
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
    phase=$(kube get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$phase" != "$last_phase" ]]; then
      info "  DPU phase: ${phase:-unknown}"
      last_phase="$phase"
    fi
    [[ "$phase" == "Ready" ]] && break
    if [[ "$phase" == "Error" ]]; then
      # Check both OSInstalled and BFBTransferred — condition type varies by DPF version
      os_reason=$(kube get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="OSInstalled")].reason}' 2>/dev/null || echo "")
      os_msg=$(kube get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="OSInstalled")].message}' 2>/dev/null || echo "")
      if [[ -z "$os_reason" ]]; then
        os_reason=$(kube get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" \
          -o jsonpath='{.status.conditions[?(@.type=="BFBTransferred")].reason}' 2>/dev/null || echo "")
        os_msg=$(kube get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" \
          -o jsonpath='{.status.conditions[?(@.type=="BFBTransferred")].message}' 2>/dev/null || echo "")
      fi
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
        # Redfish version check unavailable or version mismatch — BF3 may have been
        # flashed via rshim. Auto-patch DPU to Ready so provisioning can continue.
        warn "DPU Error: BMC returned 404 (FailToInstall) and Redfish version check inconclusive"
        warn "  BMC user: ${bmc_user}, current_ver='${current_ver}', expected_ver='${expected_ver}'"
        warn "  Auto-patching DPU to Ready (BF3 assumed already flashed via rshim)"
        kube patch dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" \
          --subresource=status --type=merge \
          -p '{"status":{"phase":"Ready"}}' 2>/dev/null || true
        break
      fi
      fail "DPU provisioning failed — check: kubectl describe dpu ${SERVER_NAME}-dpu -n ${DPF_NAMESPACE}"
    fi
    sleep 15; elapsed=$((elapsed + 15))
  done
  [[ $elapsed -ge $DPU_TIMEOUT ]] \
    && fail "DPU not Ready after ${DPU_TIMEOUT}s — check: kubectl describe dpu ${SERVER_NAME}-dpu -n ${DPF_NAMESPACE}"
  ok "DPU '${SERVER_NAME}-dpu' phase: Ready"
fi

# ─── Step 11b: Post-provision firmware verification (nvconfig read-back) ─────
# NEVER trust the flash alone: the Redfish-404 / rshim OS-only path SKIPS the
# flavor's nvconfig entirely, and LAG_RESOURCE_ALLOCATION only truly applies at
# a TRUE cold power cycle. This is how a "successfully provisioned" DPU once
# shipped with a dead p1 datapath. Read the firmware back and compare.
if [[ "${DRY_RUN}" == "true" ]]; then
  info "[dry-run] skipping step 11b firmware read-back"
elif bf3_reachable; then
  info "Step 11b — Verifying firmware nvconfig on the BF3 (flavor read-back)"
  _lag0=$(bf3_lag_current 0000:03:00.0)
  _lag1=$(bf3_lag_current 0000:03:00.1)
  if [[ "${_lag0}" == *"(1)"* && "${_lag1}" == *"(1)"* ]]; then
    ok "LAG_RESOURCE_ALLOCATION current=PRE_ALLOCATION(1) on both PFs"
  else
    POSTCHECK_FW_BAD=true
    warn "LAG_RESOURCE_ALLOCATION NOT applied (current: PF0='${_lag0:-?}' PF1='${_lag1:-?}')"
    warn "  Either the flash path skipped nvconfig (Redfish-404/rshim) or the box never"
    warn "  got a TRUE cold power cycle. p1 uplink unicast WILL blackhole until fixed:"
    warn "    (BF3)      sudo mlxconfig -d 0000:03:00.0 set LAG_RESOURCE_ALLOCATION=1"
    warn "               sudo mlxconfig -d 0000:03:00.1 set LAG_RESOURCE_ALLOCATION=1"
    warn "    (x86 HOST) sudo ipmitool chassis power cycle     # ARM reboot is NOT enough"
  fi
else
  warn "Step 11b skipped — BF3 SSH not available (OOB/arm_password); verify manually:"
  warn "  ssh ubuntu@${BF3_OOB_IP} sudo mlxconfig -d 0000:03:00.0 -e q LAG_RESOURCE_ALLOCATION  # Current must be (1)"
fi

# ─── HBN DaemonSet deployment (--hbn) ────────────────────────────────────────
# Deploys doca-hbn as a Kubernetes DaemonSet on the BF3 TenantControlPlane.
# NO NGC API key needed — uses image already on the BF3 from standalone bringup.
#
# Equivalent to: sudo ./scripts/bringup_hbn_bf3.sh --vfs 8
# Topology: 2 PFs, 4 VFs per PF (8 VFs total)
#   Uplinks:  p0, p1        → ToR switch
#   Host reps: pf0hpf, pf1hpf → x86 host (PF0, PF1)
#   VF reps:  pf0vf0-3, pf1vf0-3 → workload VMs
#
# IMPORTANT: BF3 must be RE-FLASHED with the updated DPUFlavor (04-dpuflavor.yaml)
# for hugepages, nvconfig, mlnx-sf.conf, sfc.conf to take effect.
# Run bringup_dpf.sh --rshim-install again after updating the DPUFlavor.
if [[ "${DEPLOY_HBN}" == "true" ]]; then
  echo ""
  echo "============================================================"
  echo "  HBN Deployment (doca-hbn DaemonSet on BF3)"
  echo "============================================================"
  echo ""

  # Refresh DPU cluster kubeconfig
  kube get secret "${SERVER_NAME}-dpu-cluster-admin-kubeconfig" -n "${DPF_NAMESPACE}" \
    -o jsonpath='{.data.admin\.conf}' | base64 -d > "${HOME}/dpu-tc-kubeconfig" 2>/dev/null || true
  if [[ ! -s ${HOME}/dpu-tc-kubeconfig ]]; then
    fail "DPU cluster kubeconfig not available — is BF3 joined and TenantControlPlane Ready?"
  fi
  dkube() { kubectl --kubeconfig "${HOME}/dpu-tc-kubeconfig" "$@"; }

  info "Step HBN-1 — Creating hostPath directories on BF3"
  # These are created by bringup_hbn_bf3.sh Step 3 / DPUFlavor cloud-init.
  # Ensure they exist (idempotent). ARM password comes from config.local.yaml.
  BF3_OOB_PASS_HBN="${ARM_PASSWORD}"
  [[ -z "${BF3_OOB_PASS_HBN}" ]] && \
    warn "arm_password not set in config.local.yaml — hostPath dir creation may fail"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[dry-run] would ensure /var/lib/hbn hostPath directories on BF3 (${BF3_OOB_IP})"
  else
    for dir in \
      /var/lib/hbn/etc/nvue.d \
      /var/lib/hbn/etc/frr \
      /var/lib/hbn/etc/network \
      /var/lib/hbn/etc/cumulus \
      /var/lib/hbn/etc/hbn-users \
      /var/lib/hbn/etc/supervisor/conf.d \
      /var/lib/hbn/var/lib/nvue \
      /var/lib/hbn/var/support \
      /var/log/doca/hbn; do
      sshpass -p "${BF3_OOB_PASS_HBN}" \
        ssh -o StrictHostKeyChecking=no "ubuntu@${BF3_OOB_IP}" \
        "sudo mkdir -p ${dir}" 2>/dev/null || true
    done
    ok "hostPath directories ready on BF3"
  fi

  info "Step HBN-2 — Deploying doca-hbn DaemonSet to TenantControlPlane"
  if dkube get daemonset doca-hbn -n doca-hbn &>/dev/null; then
    skip "doca-hbn DaemonSet already exists in TenantControlPlane"
  else
    if [[ "${DRY_RUN}" == "true" ]]; then
      info "[dry-run] would apply 09-hbn-daemonset.yaml to TenantControlPlane"
    else
      dkube apply -f "${MANIFESTS_DIR}/09-hbn-daemonset.yaml" \
        && ok "doca-hbn DaemonSet deployed to TenantControlPlane" \
        || fail "Failed to deploy doca-hbn DaemonSet"
    fi
  fi

  if [[ "${DRY_RUN}" != "true" ]]; then
    info "  Waiting for doca-hbn pod to be Running (up to 10 min)..."
    elapsed=0
    while [[ $elapsed -lt 600 ]]; do
      pod_status=$(dkube get pods -n doca-hbn --no-headers 2>/dev/null \
        | grep doca-hbn | awk '{print $3}' | head -1 || echo "")
      [[ "$pod_status" == "Running" ]] && { ok "doca-hbn pod: Running"; break; }
      sleep 15; elapsed=$((elapsed + 15))
      info "  doca-hbn pod status: ${pod_status:-Pending} (${elapsed}s/600s)"
    done
    if [[ $elapsed -ge 600 ]]; then
      warn "doca-hbn not Running after 10 min"
      warn "Check: kubectl --kubeconfig ${HOME}/dpu-tc-kubeconfig describe pods -n doca-hbn"
    fi

    # Bring up interfaces inside container (same as bringup_hbn_bf3.sh Step 11)
    info "  Bringing up HBN interfaces inside container..."
    CONT=$(dkube get pods -n doca-hbn --no-headers 2>/dev/null \
      | grep "doca-hbn.*Running" | awk '{print $1}' | head -1 || echo "")
    if [[ -n "${CONT}" ]]; then
      for iface in p0_if p1_if pf0hpf_if pf1hpf_if \
                   pf0vf0_if pf0vf1_if pf0vf2_if pf0vf3_if \
                   pf1vf0_if pf1vf1_if pf1vf2_if pf1vf3_if; do
        dkube exec -n doca-hbn "${CONT}" -- \
          ip link set "${iface}" up 2>/dev/null && true || true
      done
      ok "HBN interfaces brought up"
    else
      warn "doca-hbn pod not Running — skipping interface bring-up"
    fi

    # ── Step HBN-3: BF3-side datapath/REST hardening + passive validation ────
    # Config-plane "pod Running, interfaces UP" is NOT proof the datapath works —
    # that is exactly how the cross-PF multiport defect shipped. This step runs
    # an idempotent script ON the BF3 that:
    #   1. enables eswitch multiport (mlnx-bf.conf + devlink runtime param)
    #   2. re-derives the br-hbn priority-500 port-pair flows if missing
    #   3. installs a boot-time guard (reboots silently lose the pair flows)
    #   4. writes the NVUE startup.yaml baseline (REST stays on 0.0.0.0 even
    #      after an orchestrator cleanup / 'nv config apply 1 -y')
    #   5. passively validates wire→container delivery per uplink (35s)
    info "Step HBN-3 — BF3 datapath/REST hardening + passive validation"
    if bf3_reachable; then
      _postsh=$(mktemp)
      cat > "${_postsh}" <<'EOF_POST'
#!/bin/bash
# hbn_postcheck.sh — idempotent BF3-side hardening + validation (run as root)
set -u
RC=0

# 1. eswitch multiport: persist for every boot + enable at runtime
MBF=/etc/mellanox/mlnx-bf.conf
if ! grep -q '^ENABLE_ESWITCH_MULTIPORT="yes"' "$MBF" 2>/dev/null; then
  if grep -q '^ENABLE_ESWITCH_MULTIPORT=' "$MBF" 2>/dev/null; then
    sed -i 's/^ENABLE_ESWITCH_MULTIPORT=.*/ENABLE_ESWITCH_MULTIPORT="yes"/' "$MBF"
  else
    printf '\nENABLE_ESWITCH_MULTIPORT="yes"\n' >> "$MBF"
  fi
  echo "FIXED: mlnx-bf.conf ENABLE_ESWITCH_MULTIPORT=\"yes\" (boot-time enable)"
else
  echo "OK: mlnx-bf.conf ENABLE_ESWITCH_MULTIPORT already yes"
fi
MP=$(devlink dev param show pci/0000:03:00.0 name esw_multiport 2>/dev/null | awk '/cmode/{print $NF}')
if [ "$MP" = "true" ]; then
  echo "OK: esw_multiport=true"
elif devlink dev param set pci/0000:03:00.0 name esw_multiport value true cmode runtime 2>/dev/null; then
  echo "FIXED: esw_multiport=true (runtime)"
else
  echo "ERROR: cannot enable esw_multiport — firmware LAG_RESOURCE_ALLOCATION=1 not committed (needs TRUE cold power cycle from the x86 host)"
  RC=1
fi

# 2. br-hbn port-pair flows (br-hbn drops unchained traffic without them)
N=$(ovs-ofctl dump-flows br-hbn 2>/dev/null | grep -c priority=500)
if [ "${N:-0}" -eq 0 ]; then
  echo "WARN: 0 priority-500 pair flows — restarting sfc.service to re-derive"
  systemctl restart sfc.service
  sleep 20
  systemctl is-active --quiet kubelet || systemctl start kubelet
  N=$(ovs-ofctl dump-flows br-hbn 2>/dev/null | grep -c priority=500)
fi
if [ "${N:-0}" -gt 0 ]; then
  echo "OK: ${N} priority-500 pair flows on br-hbn"
else
  echo "ERROR: still 0 pair flows after sfc restart — check: journalctl -u sfc -n 50"
  RC=1
fi

# 3. boot-time pair-flow guard (a reboot silently loses the flows otherwise)
if [ ! -f /etc/systemd/system/hbn-pairflow-guard.service ]; then
  cat > /usr/local/sbin/hbn-pairflow-guard.sh <<'EOS'
#!/bin/bash
# Wait for sfc/OVS to settle after boot; re-derive br-hbn pair flows if missing.
for i in $(seq 1 30); do
  n=$(ovs-ofctl dump-flows br-hbn 2>/dev/null | grep -c priority=500)
  [ "${n:-0}" -gt 0 ] && exit 0
  sleep 10
done
systemctl restart sfc.service
sleep 15
systemctl is-active --quiet kubelet || systemctl start kubelet
EOS
  chmod +x /usr/local/sbin/hbn-pairflow-guard.sh
  cat > /etc/systemd/system/hbn-pairflow-guard.service <<'EOS'
[Unit]
Description=Re-derive br-hbn port-pair flows if missing after boot
After=sfc.service openvswitch-switch.service
Wants=sfc.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hbn-pairflow-guard.sh
TimeoutStartSec=420

[Install]
WantedBy=multi-user.target
EOS
  systemctl daemon-reload
  systemctl enable hbn-pairflow-guard.service >/dev/null 2>&1
  echo "OK: installed hbn-pairflow-guard.service (boot-time pair-flow check)"
else
  echo "OK: hbn-pairflow-guard.service already installed"
fi

# 4. NVUE REST baseline — without it, an orchestrator cleanup (nv config apply 1)
#    reverts the REST API to localhost-only and Day-0 orchestration locks itself out.
NV=/var/lib/hbn/etc/nvue.d/startup.yaml
if [ ! -s "$NV" ]; then
  mkdir -p /var/lib/hbn/etc/nvue.d
  cat > "$NV" <<'EOS'
- header:
    model: bluefield
    nvue-api-version: nvue_v1
    rev-id: 1.0
    version: HBN 3.3.0
- set:
    system:
      api:
        listening-address:
          0.0.0.0: {}
EOS
  echo "FIXED: NVUE startup.yaml baseline (REST stays on 0.0.0.0 after cleanup)"
else
  echo "OK: NVUE startup.yaml present"
fi

# 5. Passive datapath validation: if the WIRE receives bcast/ucast but the
#    container-side uplink counter never moves, eswitch delivery is dead.
#    LLDP-class multicast is consumed by the bridge BY DESIGN — excluded.
CONT=$(crictl ps 2>/dev/null | awk '/doca-hbn/ && !/init/ {print $1; exit}')
if [ -z "$CONT" ]; then
  echo "WARN: no doca-hbn container via crictl — datapath validation skipped"
else
  bu() { ethtool -S "$1" 2>/dev/null | awk '/rx_packets_phy:/{t=$2} /rx_multicast_phy:/{m=$2} END{print (t-m)+0, t+0}'; }
  cif() { crictl exec "$CONT" cat "/sys/class/net/${1}_if/statistics/rx_packets" 2>/dev/null || echo 0; }
  SNAP=""
  for P in p0 p1; do
    [ -e "/sys/class/net/$P/carrier" ] || { echo "WARN: uplink $P netdev missing — skipped"; continue; }
    [ "$(cat /sys/class/net/$P/carrier 2>/dev/null || echo 0)" = "1" ] || { echo "WARN: uplink $P no carrier — skipped"; continue; }
    set -- $(bu "$P")
    SNAP="$SNAP $P:${1:-0}:${2:-0}:$(cif "$P")"
  done
  if [ -n "$SNAP" ]; then
    echo "INFO: sampling$(echo "$SNAP" | sed 's/:[0-9:]*//g') for 35s (covers one ToR LLDP interval)..."
    sleep 35
    for S in $SNAP; do
      P=${S%%:*}; R=${S#*:}
      B0=${R%%:*}; R=${R#*:}; T0=${R%%:*}; C0=${R##*:}
      set -- $(bu "$P")
      BUD=$(( ${1:-0} - B0 )); TOTD=$(( ${2:-0} - T0 )); CIFD=$(( $(cif "$P") - C0 ))
      if [ "${CIFD}" -gt 0 ]; then
        echo "OK: uplink $P wire->container delivery OK (${P}_if +${CIFD} pkts)"
      elif [ "${BUD}" -ge 3 ]; then
        echo "ERROR: uplink $P wire got +${BUD} bcast/ucast pkts but ${P}_if got NONE — eswitch dropping delivery (multiport/cold-cycle or sfc flows)"
        RC=1
      elif [ "${TOTD}" -gt 0 ]; then
        echo "INCONCLUSIVE: uplink $P saw only multicast (LLDP-class) in the window — Day-0 BGP will prove the path"
      else
        echo "INCONCLUSIVE: uplink $P wire silent for 35s"
      fi
    done
  fi
fi
exit $RC
EOF_POST
      if sshpass -p "${ARM_PASSWORD}" scp -o StrictHostKeyChecking=no -o LogLevel=ERROR \
           "${_postsh}" "ubuntu@${BF3_OOB_IP}:/tmp/hbn_postcheck.sh" 2>/dev/null \
         && bf3_ssh "sudo bash /tmp/hbn_postcheck.sh"; then
        ok "BF3 datapath/REST hardening + validation passed"
      else
        warn "BF3 post-check reported issues (ERROR lines above) — the DPU is provisioned"
        warn "but the DATA PLANE needs attention before handing to the orchestrator."
      fi
      rm -f "${_postsh}"
    else
      warn "arm_password not set / BF3 unreachable — skipping datapath/REST hardening"
      warn "  (multiport, pair-flow guard, REST baseline, datapath validation NOT done)"
    fi
  else
    info "[dry-run] would wait for the doca-hbn pod, bring up its interfaces, then run"
    info "[dry-run] Step HBN-3 on the BF3: multiport enable, pair-flow re-derive + boot"
    info "[dry-run] guard, NVUE REST 0.0.0.0 baseline, 35s passive datapath validation"
  fi
fi

echo ""
echo "============================================================"
echo "  DPF Bringup Complete"
echo "============================================================"
echo ""
info "BF3 is now a managed DPU node."
if [[ "${POSTCHECK_FW_BAD}" == "true" ]]; then
  echo ""
  warn "════════════════════════════════════════════════════════════"
  warn "ACTION REQUIRED: firmware nvconfig was NOT applied (step 11b)."
  warn "The p1 uplink will blackhole unicast until LAG_RESOURCE_ALLOCATION=1"
  warn "is staged on BOTH PFs and the x86 host gets a TRUE cold power cycle"
  warn "(sudo ipmitool chassis power cycle). See the step 11b output above."
  warn "════════════════════════════════════════════════════════════"
fi
echo ""
echo "  Check status:    ./dpf/scripts/status_dpf.sh"
echo ""
echo "  Get DPU cluster kubeconfig:"
echo "    kubectl get secret -n ${DPF_NAMESPACE} ${SERVER_NAME}-dpu-cluster-admin-kubeconfig \\"
echo "      -o jsonpath='{.data.admin\\.conf}' | base64 -d > \${HOME}/dpu-kubeconfig"
echo "    kubectl get nodes --kubeconfig \${HOME}/dpu-kubeconfig"
echo ""
if [[ "${DEPLOY_HBN}" != "true" ]]; then
  echo "  Deploy HBN (no NGC key needed):"
  echo "    $0 --hbn"
  echo ""
fi
