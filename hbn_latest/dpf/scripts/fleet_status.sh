#!/usr/bin/env bash
# fleet_status.sh — one-shot status of ALL DPUs managed by this DPF operator VM.
# Reads the worker list from dpf/config.yaml and shows, per worker:
#   operator view  (DPU phase, cluster endpoint/port)
#   cluster view   (node, doca-hbn pod)
#   --frr          additionally exec into each HBN pod for interface counts (slower)
#
# Usage (on the DPF Operator VM):
#   ./dpf/scripts/fleet_status.sh
#   ./dpf/scripts/fleet_status.sh --frr
#   ./dpf/scripts/fleet_status.sh --worker worker2      # single worker

set -uo pipefail   # NOTE: no -e — a down cluster must not abort the fleet report

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.yaml"
DPF_NAMESPACE="dpf-operator-system"

if [[ -n "${KUBECONFIG:-}" ]]; then :;
elif [[ -r /etc/rancher/k3s/k3s.yaml ]]; then export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
else export KUBECONFIG="${HOME}/.kube/config"; fi

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
bad()  { echo -e "${RED}✗${NC} $*"; }
hdr()  { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

SHOW_FRR=false
ONLY_WORKER=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --frr)    SHOW_FRR=true ;;
    --worker) ONLY_WORKER="$2"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

[[ -f "${CONFIG_FILE}" ]] || { echo "config.yaml not found at ${CONFIG_FILE}"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "python3-yaml required (apt install python3-yaml)"; exit 1; }

# name<TAB>server<TAB>oob_ip<TAB>port<TAB>operator per worker (+ local operator on line 1)
WORKERS_RAW=$(python3 - "${CONFIG_FILE}" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1])) or {}
me = (c.get("operator") or {}).get("name", "")
print(me)
for w in c.get("workers") or []:
    print(f'{w.get("name","?")}\t{w.get("server","?")}\t{w.get("oob_ip","?")}\t{w.get("apiserver_port",6443)}\t{w.get("operator") or me}')
PY
)
LOCAL_OPERATOR=$(head -1 <<< "${WORKERS_RAW}")
WORKERS=$(tail -n +2 <<< "${WORKERS_RAW}")
[[ -n "${WORKERS}" ]] || { echo "no workers in config.yaml"; exit 1; }

hdr "Operator view (${DPF_NAMESPACE})"
kubectl get dpu -n "${DPF_NAMESPACE}" 2>/dev/null || bad "cannot reach operator cluster"

while IFS=$'\t' read -r NAME SERVER OOB PORT WOP; do
  [[ -n "${ONLY_WORKER}" && "${ONLY_WORKER}" != "${NAME}" && "${ONLY_WORKER}" != "${SERVER}" ]] && continue

  # Workers owned by another operator (config.yaml `operator:` field) are not queryable
  # from this VM — show a one-line note instead of false ✗ failures.
  if [[ -n "${WOP}" && "${WOP}" != "${LOCAL_OPERATOR}" ]]; then
    hdr "${NAME} (${SERVER}) — managed by '${WOP}', not this operator (${LOCAL_OPERATOR:-unknown})"
    [[ "${WOP}" == "none" ]] && echo "  not provisioned via DPF yet" \
      || echo "  run fleet_status.sh on the '${WOP}' operator VM to see it"
    continue
  fi

  hdr "${NAME} (${SERVER}) — OOB ${OOB} · apiserver :${PORT}"

  # operator-level objects for this server
  kubectl get dpu "${SERVER}-dpu" -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null \
    | awk '{printf "  DPU      : phase=%s ready=%s\n", $3, $2}' || bad "  DPU ${SERVER}-dpu not found"
  kubectl get tcp "${SERVER}-dpu-cluster" -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null \
    | awk '{printf "  Cluster  : %s @ %s\n", $3, $4}'

  # per-cluster view via fresh kubeconfig
  KC=$(mktemp)
  if kubectl get secret "${SERVER}-dpu-cluster-admin-kubeconfig" -n "${DPF_NAMESPACE}" \
       -o jsonpath='{.data.admin\.conf}' 2>/dev/null | base64 -d > "${KC}" && [[ -s "${KC}" ]]; then
    NODE=$(kubectl --kubeconfig "${KC}" get nodes --no-headers 2>/dev/null | head -1)
    [[ -n "${NODE}" ]] && echo "  Node     : ${NODE}" || bad "  Node     : none joined"
    HBN=$(kubectl --kubeconfig "${KC}" get pods -n doca-hbn --no-headers 2>/dev/null | head -1)
    [[ -n "${HBN}" ]] && echo "  HBN pod  : ${HBN}" || bad "  HBN pod  : not deployed"
    NOTREADY=$(kubectl --kubeconfig "${KC}" get pods -A --no-headers 2>/dev/null \
      | grep -vcE 'Running|Completed')
    [[ "${NOTREADY:-0}" -eq 0 ]] && ok "  All pods Running" || bad "  ${NOTREADY} pod(s) not Running"

    if [[ "${SHOW_FRR}" == "true" ]]; then
      POD=$(kubectl --kubeconfig "${KC}" get pod -n doca-hbn -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
      if [[ -n "${POD}" ]]; then
        IFS_UP=$(kubectl --kubeconfig "${KC}" exec -n doca-hbn "${POD}" -- \
          vtysh -c "show interface brief" 2>/dev/null | grep -c '_if.*up')
        VFS=$(kubectl --kubeconfig "${KC}" exec -n doca-hbn "${POD}" -- \
          vtysh -c "show interface brief" 2>/dev/null | grep -cE 'pf[0-9]vf[0-9]+_if')
        echo "  FRR      : ${IFS_UP:-0} interfaces up, ${VFS:-0} VF interfaces"
      fi
    fi
  else
    bad "  kubeconfig secret not found (cluster not created yet?)"
  fi
  rm -f "${KC}"
done <<< "${WORKERS}"
echo ""
