#!/usr/bin/env bash
# port_map.sh — interactive BF3 HBN port-mapping diagram (ToR → physical → eswitch
# → OVS br-hbn → FRR container → x86 host), rendered per server with LIVE values.
#
#   ./dpf/scripts/port_map.sh --server s4      # → ~/dpf_summary/port-map-s4.html
#   ./dpf/scripts/port_map.sh --server s2
#
# Structure (ports, sfnum mapping) is fixed by the DPUFlavor; IPs/status/host NIC
# names/MACs are pulled live. Run from the DPF Operator VM.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.yaml"
LOCAL_FILE="${SCRIPT_DIR}/../config.local.yaml"
DPF_NS="dpf-operator-system"
SUMMARY="${HOME}/dpf_summary"; mkdir -p "${SUMMARY}"

if [[ -n "${KUBECONFIG:-}" ]]; then :;
elif [[ -r /etc/rancher/k3s/k3s.yaml ]]; then export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
else export KUBECONFIG="${HOME}/.kube/config"; fi

SERVER="s4"
while [[ $# -gt 0 ]]; do case "$1" in
  --server) SERVER="$2"; shift ;;
  *) echo "usage: $0 --server <sX>"; exit 1 ;;
esac; shift; done

python3 -c 'import yaml' 2>/dev/null || { echo "needs python3-yaml"; exit 1; }
TMP="$(mktemp -d "${HOME}/.portmap.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT

# ── per-server config ──────────────────────────────────────────────────────────
eval "$(python3 - "$CONFIG_FILE" "$LOCAL_FILE" "$SERVER" <<'PY'
import os,shlex,sys,yaml
cfg,lcl,srv=sys.argv[1],sys.argv[2],sys.argv[3]
def load(p):
    return (yaml.safe_load(open(p)) or {}) if os.path.exists(p) else {}
def merge(a,b):
    for k,v in b.items():
        a[k]=merge(a.get(k,{}),v) if isinstance(v,dict) and isinstance(a.get(k),dict) else v
    return a
c=merge(load(cfg),load(lcl))
w=next((x for x in (c.get("workers") or []) if x.get("server")==srv or x.get("name")==srv),{})
cred={}
for k in (w.get("name"),w.get("server")):
    if k and isinstance(c.get(k),dict): cred=c[k]; break
def e(k,v): print(f'{k}={shlex.quote(str(v or ""))}')
e("W_NAME",w.get("name",srv)); e("OOB",w.get("oob_ip","")); e("BMC",w.get("bmc_ip",""))
e("XIP",w.get("x86_host_ip","")); e("XUSER",cred.get("x86_host_user",""))
e("XPASS",cred.get("x86_host_password","")); e("ARMPASS",cred.get("arm_password",""))
PY
)"

# ── live: FRR interface brief (name status vrf addr) ────────────────────────────
KC="${TMP}/kc"
kubectl get secret "${SERVER}-dpu-cluster-admin-kubeconfig" -n "${DPF_NS}" \
  -o jsonpath='{.data.admin\.conf}' 2>/dev/null | base64 -d > "${KC}" || true
POD=""
[[ -s "${KC}" ]] && POD=$(kubectl --kubeconfig "${KC}" get pod -n doca-hbn -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${POD}" ]]; then
  kubectl --kubeconfig "${KC}" exec -n doca-hbn "${POD}" -- vtysh -c "show interface brief" \
    2>/dev/null > "${TMP}/frr.txt" || true
else
  echo "(HBN pod not reachable)" > "${TMP}/frr.txt"
fi

# ── live: host PF NIC names + VF presence (best-effort) ─────────────────────────
echo "" > "${TMP}/host.txt"
if [[ -n "${XPASS}" && -n "${XIP}" ]]; then
  sshpass -p "${XPASS}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "${XUSER}@${XIP}" '
    for pf in $(lspci -Dn -d 15b3:a2dc 2>/dev/null | awk "{print \$1}"); do
      case "$pf" in *.0) n=$(ls /sys/bus/pci/devices/$pf/net 2>/dev/null|head -1); nv=$(cat /sys/bus/pci/devices/$pf/sriov_numvfs 2>/dev/null); echo "PF0 $n ${nv:-NA}";; \
                     *.1) n=$(ls /sys/bus/pci/devices/$pf/net 2>/dev/null|head -1); echo "PF1 $n";; esac
    done
    echo "VFS $(ip -br link 2>/dev/null | grep -oE "^vf[0-9]+" | sort -u | tr "\n" " ")"
  ' > "${TMP}/host.txt" 2>/dev/null || true
fi

OUT="${SUMMARY}/port-map-${SERVER}.html"
python3 "${SCRIPT_DIR}/.port_map_render.py" \
  "${SERVER}" "${W_NAME}" "${OOB}" "${BMC}" "${XIP}" "${TMP}/frr.txt" "${TMP}/host.txt" "${OUT}"
echo "wrote ${OUT}" >&2
