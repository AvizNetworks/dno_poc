#!/usr/bin/env bash
# dump_cluster.sh — Full cluster state dump to HTML
# Run from DPF Operator VM
#
# Usage:
#   ./dump_cluster.sh              # standard cluster overview
#   ./dump_cluster.sh --detailed   # adds DPF Deep Dive + BF3 ARM Deep Dive tabs

set -euo pipefail

KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
DPU_KUBECONFIG="/tmp/dpu-tc-kubeconfig"
DPF_NAMESPACE="dpf-operator-system"
OUTPUT="${HOME}/dpf_summary/cluster-dump.html"
mkdir -p "${HOME}/dpf_summary"
DETAILED=false
[[ "${1:-}" == "--detailed" ]] && DETAILED=true

echo "Collecting cluster data..." >&2

# Fetch DPU kubeconfig
kubectl --kubeconfig "${KUBECONFIG}" get secret s4-dpu-cluster-admin-kubeconfig \
  -n "${DPF_NAMESPACE}" \
  -o jsonpath='{.data.admin\.conf}' 2>/dev/null | base64 -d > "${DPU_KUBECONFIG}" || true

DPU_KUBE_AVAILABLE=false
[[ -s "${DPU_KUBECONFIG}" ]] && DPU_KUBE_AVAILABLE=true

kube()  { kubectl --kubeconfig "${KUBECONFIG}" "$@" 2>/dev/null || echo "(no resources or error)"; }
dkube() { kubectl --kubeconfig "${DPU_KUBECONFIG}" "$@" 2>/dev/null || echo "(no resources or error)"; }

# Collect data before redirecting stdout
echo "  k3s nodes..." >&2;       K3S_NODES=$(kube get nodes -o wide)
echo "  k3s pods..." >&2;        K3S_PODS=$(kube get pods -A -o wide)
echo "  k3s pods json..." >&2;   K3S_PODS_JSON=$(kube get pods -A -o json)
echo "  services..." >&2;        K3S_SVC=$(kube get svc -A)
echo "  pvcs..." >&2;            K3S_PVC=$(kube get pvc -A -o wide)
echo "  pvs..." >&2;             K3S_PV=$(kube get pv -o wide)
echo "  storageclasses..." >&2;  K3S_SC=$(kube get storageclass)
echo "  DPU..." >&2;             DPF_DPU=$(kube get dpu -A -o wide)
echo "  DPUServices..." >&2;     DPF_SVC=$(kube get dpuservice -A)
echo "  DPUCluster..." >&2;      DPF_CLUSTER=$(kube get dpucluster -A)
echo "  BFB..." >&2;             DPF_BFB=$(kube get bfb -A)
echo "  ArgoCD apps..." >&2;     ARGO_APPS=$(kube get applications -A 2>/dev/null || echo "(none)")
echo "  svc-controller logs..." >&2
SVC_LOGS=$(kube logs -n "${DPF_NAMESPACE}" \
  "$(kube get pods -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null | grep servicechainset-controller | awk '{print $1}' | head -1)" \
  --tail=30 2>/dev/null || echo "(no logs)")

if [[ "${DPU_KUBE_AVAILABLE}" == "true" ]]; then
  echo "  BF3 nodes..." >&2;    BF3_NODES=$(dkube get nodes -o wide)
  echo "  BF3 pods..." >&2;     BF3_PODS=$(dkube get pods -A -o wide)
  echo "  BF3 pods json..." >&2; BF3_PODS_JSON=$(dkube get pods -A -o json)
  echo "  BF3 services..." >&2;  BF3_SVC=$(dkube get svc -A)
else
  BF3_NODES="TenantControlPlane kubeconfig not available"
  BF3_PODS="TenantControlPlane kubeconfig not available"
  BF3_PODS_JSON='{"items":[]}'
  BF3_SVC="N/A"
fi

# Derived status flags
BF3_FLANNEL_RUNNING=$(echo "$BF3_PODS" | grep -cE "flannel.*Running" || true)
BF3_MULTUS_RUNNING=$(echo "$BF3_PODS"  | grep -cE "multus.*Running"  || true)
BF3_OVSCNI_RUNNING=$(echo "$BF3_PODS"  | grep -cE "ovs-cni.*Running" || true)
BF3_IPAM_RUNNING=$(echo "$BF3_PODS"    | grep -cE "ipam.*Running"    || true)
BF3_SRIOV_RUNNING=$(echo "$BF3_PODS"   | grep -cE "sriov.*Running"   || true)
BF3_HBN_RUNNING=$(echo "$BF3_PODS"     | grep -cE "doca-hbn.*Running"|| true)
BF3_COREDNS_CC=$(echo "$BF3_PODS"      | grep -cE "coredns.*ContainerCreating" || true)
DPUSVC_PENDING_COUNT=$(kube get dpuservice -A 2>/dev/null | tail -n +2 | grep -c "Pending" || true)
SVC_CTRL_RESTARTS=$(kube get pod -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null \
  | grep servicechainset | awk '{print $4}' | head -1 || echo "0")
ETCD_DEFRAG_STUCK=$(kube get pods -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null \
  | grep -c "defrag.*ContainerCreating" || true)

_arch_item() {
  local run="${1:-0}" name="$2" ok="${3:-Running}" fail="${4:-NOT deployed}"
  if [[ "${run}" -gt 0 ]]; then
    printf '<div class="arch-item"><span class="dot dot-g"></span><span class="name">%s</span><span class="role ok">%s</span></div>' "${name}" "${ok}"
  else
    printf '<div class="arch-item"><span class="dot dot-r"></span><span class="name" style="color:var(--muted)">%s</span><span class="role warn">%s</span></div>' "${name}" "${fail}"
  fi
}
_ARCH_COREDNS=$([[ "${BF3_COREDNS_CC:-0}" -gt 0 ]] \
  && echo '<div class="arch-item"><span class="dot dot-r"></span><span class="name" style="color:var(--red)">coredns (x2)</span><span class="role fail">ContainerCreating</span></div>' \
  || echo '<div class="arch-item"><span class="dot dot-g"></span><span class="name">coredns (x2)</span><span class="role ok">Running</span></div>')
_ARCH_FLANNEL=$(_arch_item "${BF3_FLANNEL_RUNNING}" "flannel (CNI)")
_ARCH_MULTUS=$(_arch_item  "${BF3_MULTUS_RUNNING}"  "multus")
_ARCH_OVSCNI=$(_arch_item  "${BF3_OVSCNI_RUNNING}"  "ovs-cni")
_ARCH_IPAM=$(_arch_item    "${BF3_IPAM_RUNNING}"    "nvidia-k8s-ipam")
_ARCH_SRIOV=$(_arch_item   "${BF3_SRIOV_RUNNING}"   "sriov-device-plugin")
_ARCH_HBN=$(_arch_item     "${BF3_HBN_RUNNING}"     "doca-hbn")

if [[ "${BF3_HBN_RUNNING:-0}" -gt 0 ]]; then
  _ARCH_BF3_STATUS_PANEL='<div class="arch-node">
      <div class="arch-node-title"><span style="color:var(--green)">&#x2713;</span> <span class="ok">HBN Active</span></div>
      <div class="arch-items">
        <div class="arch-item" style="background:#0a2e1e;border:1px solid var(--green)">
          <span class="dot dot-g"></span><span class="name" style="color:var(--green)">doca-hbn</span>
          <span class="role ok">1/1 Running</span>
        </div>
        <div style="font-size:11px;color:var(--muted);padding:8px 4px;line-height:1.6">
          FRR routing daemons active.<br>NVUE REST API on port 8765.<br>OVS-DPDK br-hbn: 16 ports.
        </div>
      </div>
    </div>'
elif [[ "${SVC_CTRL_RESTARTS:-0}" -gt 100 ]]; then
  _ARCH_BF3_STATUS_PANEL="<div class=\"arch-node\">
      <div class=\"arch-node-title\"><span style=\"color:var(--yellow)\">&#x26a0;</span> <span class=\"warn\">Blocker</span></div>
      <div class=\"arch-items\">
        <div class=\"arch-item\" style=\"background:#1a1000;border:1px solid var(--yellow)\">
          <span class=\"dot dot-r\"></span><span class=\"name\" style=\"color:var(--red)\">servicechainset-controller</span>
        </div>
        <div style=\"font-size:11px;color:var(--muted);padding:8px 4px;line-height:1.6\">
          ${SVC_CTRL_RESTARTS}+ CrashLoopBackOff restarts.<br>Blocks DPUService deployment.
        </div>
      </div>
    </div>"
else
  _ARCH_BF3_STATUS_PANEL='<div class="arch-node">
      <div class="arch-node-title"><span style="color:var(--muted)">&#x25cb;</span> <span class="info">Provisioning</span></div>
      <div class="arch-items">
        <div style="font-size:11px;color:var(--muted);padding:8px 4px">DPUServices being deployed...</div>
      </div>
    </div>'
fi

if [[ "${SVC_CTRL_RESTARTS:-0}" -gt 100 ]]; then
  _ARCH_SVC_CTRL="<div class=\"arch-item\"><span class=\"dot dot-r\"></span><span class=\"name\" style=\"color:var(--red)\">servicechainset-ctrl</span><span class=\"role\" style=\"color:var(--red)\">CrashLoop ${SVC_CTRL_RESTARTS}x</span></div>"
else
  _ARCH_SVC_CTRL='<div class="arch-item"><span class="dot dot-g"></span><span class="name">servicechainset-ctrl</span><span class="role ok">Running</span></div>'
fi

_CARD_CNI=$([[ "${BF3_FLANNEL_RUNNING:-0}" -gt 0 ]] && echo '<span class="ok">Running</span>'  || echo '<span class="fail">NOT deployed</span>')
_CARD_HBN=$([[ "${BF3_HBN_RUNNING:-0}"     -gt 0 ]] && echo '<span class="ok">Running</span>'  || echo '<span class="fail">NOT deployed</span>')

_FAILING_ROWS=""
[[ "${SVC_CTRL_RESTARTS:-0}" -gt 100 ]] && \
  _FAILING_ROWS+="<div class=\"card-stat\"><span class=\"stat-label\">servicechainset-ctrl</span><span class=\"fail\">CrashLoop ${SVC_CTRL_RESTARTS}x</span></div>"
[[ "${BF3_COREDNS_CC:-0}" -gt 0 ]] && \
  _FAILING_ROWS+="<div class=\"card-stat\"><span class=\"stat-label\">CoreDNS on BF3</span><span class=\"fail\">No CNI</span></div>"
[[ "${ETCD_DEFRAG_STUCK:-0}" -gt 0 ]] && \
  _FAILING_ROWS+="<div class=\"card-stat\"><span class=\"stat-label\">etcd-defrag jobs</span><span class=\"warn\">Stuck (${ETCD_DEFRAG_STUCK})</span></div>"
if [[ -z "${_FAILING_ROWS}" ]]; then
  _ACTION_CARD='<div class="card" style="border-top:3px solid var(--green)">
  <div class="card-title ok">All Systems OK</div>
  <div class="card-sub">No critical issues detected</div>
  <div class="card-stat"><span class="stat-label">doca-hbn</span><span class="ok">Running</span></div>
  <div class="card-stat"><span class="stat-label">Cluster health</span><span class="ok">Healthy</span></div>
</div>'
else
  _ACTION_CARD="<div class=\"card\" style=\"border-top:3px solid var(--red)\">
  <div class=\"card-title fail\">Action Required</div>
  <div class=\"card-sub\">Issues detected</div>
  ${_FAILING_ROWS}
</div>"
fi

if [[ "${DPUSVC_PENDING_COUNT:-0}" -gt 0 ]] && [[ "${SVC_CTRL_RESTARTS:-0}" -gt 100 ]]; then
  _DPUSVC_BOX="<div class='warn-box'>&#x26a0; ${DPUSVC_PENDING_COUNT} DPUService(s) Pending &mdash; servicechainset-controller CrashLoopBackOff (${SVC_CTRL_RESTARTS} restarts). Fix this first.</div>"
else
  _DPUSVC_BOX="<div class='info-box'>DPUServices deployed by DPF via ArgoCD &mdash; flannel, multus, ovs-cni, nvidia-k8s-ipam, sriov-device-plugin, doca-hbn.</div>"
fi

if [[ "${BF3_FLANNEL_RUNNING:-0}" -gt 0 ]]; then
  _FLOW7_CLASS="done"; _FLOW7_STATUS='<div class="flow-status ok">&#x2713; Complete &mdash; flannel, multus, ovs-cni, ipam, sriov-device-plugin running on BF3</div>'
else
  _FLOW7_CLASS="fail"; _FLOW7_STATUS='<div class="flow-status fail">&#x2717; BLOCKED &mdash; fix servicechainset-controller first</div>'
fi
if [[ "${BF3_HBN_RUNNING:-0}" -gt 0 ]]; then
  _FLOW8_CLASS="done"; _FLOW8_STATUS='<div class="flow-status ok">&#x2713; Complete &mdash; doca-hbn Running (FRR + NVUE REST API + OVS-DPDK)</div>'
else
  _FLOW8_CLASS="todo"; _FLOW8_STATUS='<div class="flow-status" style="color:var(--muted)">&#x25cb; Pending &mdash; depends on step 7</div>'
fi

_fcls() { [[ "${1:-0}" -gt 0 ]] && echo "done" || echo "todo"; }
_fst()  {
  local run="${1:-0}" ok="$2" pend="$3"
  [[ "${run}" -gt 0 ]] \
    && printf '<div class="flow-status ok">&#x2713; Running &mdash; %s</div>' "${ok}" \
    || printf '<div class="flow-status" style="color:var(--muted)">&#x25cb; %s</div>' "${pend}"
}
_FL_CLS=$(_fcls "${BF3_FLANNEL_RUNNING}"); _FL_ST=$(_fst "${BF3_FLANNEL_RUNNING}" "vxlan overlay active" "NOT deployed — blocking everything")
_MT_CLS=$(_fcls "${BF3_MULTUS_RUNNING}");  _MT_ST=$(_fst "${BF3_MULTUS_RUNNING}"  "Multi-NIC support active" "Pending flannel")
_OV_CLS=$(_fcls "${BF3_OVSCNI_RUNNING}");  _OV_ST=$(_fst "${BF3_OVSCNI_RUNNING}"  "Pod interfaces wired into br-hbn" "Pending flannel + multus")
_IP_CLS=$(_fcls "${BF3_IPAM_RUNNING}");    _IP_ST=$(_fst "${BF3_IPAM_RUNNING}"    "IP pools active for OVS/VF ports" "Pending")
_SR_CLS=$(_fcls "${BF3_SRIOV_RUNNING}");   _SR_ST=$(_fst "${BF3_SRIOV_RUNNING}"   "SFs advertised as k8s resources" "Pending")
_HB_CLS=$(_fcls "${BF3_HBN_RUNNING}");     _HB_ST=$(_fst "${BF3_HBN_RUNNING}"     "FRR routing + NVUE REST API active" "Target state — not yet deployed")
_BF3_KUBELET_DNS=$([[ "${BF3_COREDNS_CC:-0}" -gt 0 ]] && echo "&#x2717; coredns: ContainerCreating (no CNI)<br>" || echo "&#x2713; coredns: Running<br>")
_BF3_KUBELET_FL=$([[ "${BF3_FLANNEL_RUNNING:-0}" -gt 0 ]] && echo "&#x2713; flannel: Running<br>"  || echo "&#x2717; flannel: Not deployed<br>")
_BF3_KUBELET_HBN=$([[ "${BF3_HBN_RUNNING:-0}"   -gt 0 ]] && echo "&#x2713; doca-hbn: Running<br>" || echo "&#x2717; doca-hbn: Not deployed<br>")

# Detailed data (only when --detailed)
if [[ "${DETAILED}" == "true" ]]; then
  echo "  [detailed] DPU describe..." >&2;       DPF_DPU_DETAIL=$(kube describe dpu s4-dpu -n "${DPF_NAMESPACE}")
  echo "  [detailed] DPUService describe..." >&2; DPF_SVC_DETAIL=$(kube describe dpuservice -A -n "${DPF_NAMESPACE}")
  echo "  [detailed] DPUCluster detail..." >&2;   DPF_CLUSTER_DETAIL=$(kube describe dpucluster s4-dpu-cluster -n "${DPF_NAMESPACE}")
  echo "  [detailed] ServiceChains..." >&2;       DPF_CHAINS=$(kube get servicechains -A 2>/dev/null || echo "(none)")
  echo "  [detailed] ServiceInterfaceSets..." >&2; DPF_IFSETS=$(kube get serviceinterfacesets -A 2>/dev/null || echo "(none)")
  echo "  [detailed] DPUServiceIPAMs..." >&2;     DPF_IPAM=$(kube get dpuserviceipam -A 2>/dev/null || echo "(none)")
  echo "  [detailed] BF3 node describe..." >&2
  BF3_NODE_DETAIL=$(dkube describe node s4-dpu 2>/dev/null || echo "(unavailable)")
  echo "  [detailed] BF3 events..." >&2
  BF3_EVENTS=$(dkube get events -A --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || echo "(none)")
  echo "  [detailed] k3s events..." >&2
  K3S_EVENTS=$(kube get events -n "${DPF_NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || echo "(none)")
fi

# Stats
TOTAL_PODS=$(echo "$K3S_PODS" | tail -n +2 | wc -l)
RUNNING_PODS=$(echo "$K3S_PODS" | grep -c "Running" || true)
FAILING_PODS=$(echo "$K3S_PODS" | grep -cE "CrashLoop|Error|ContainerCreating" || true)
PENDING_PODS=$(echo "$K3S_PODS" | grep -c "Pending" || true)
BF3_TOTAL=$(echo "$BF3_PODS" | tail -n +2 | wc -l || echo 0)
BF3_RUNNING=$(echo "$BF3_PODS" | grep -c "Running" || true)
DPU_PHASE=$(kube get dpu s4-dpu -n "${DPF_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")

echo "  Writing HTML..." >&2

# ── Now redirect stdout to file ──────────────────────────────────────────────
exec > "${OUTPUT}"

cat <<'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>DPF Cluster Dump</title>
<style>
:root {
  --bg:#0d0f18; --s1:#141722; --s2:#1c2035; --s3:#232842;
  --border:#2a3055; --text:#dde3f0; --muted:#7a85a0;
  --green:#10d97e; --red:#ff4f6a; --yellow:#ffb627;
  --blue:#4d9dff; --purple:#b06eff; --cyan:#00d4ff;
  --orange:#ff8c42; --pink:#ff6eb4;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,sans-serif;font-size:13px;line-height:1.5}
a{color:var(--cyan);text-decoration:none}

/* Layout */
.layout{display:flex;min-height:100vh}
.sidebar{width:240px;background:var(--s1);border-right:1px solid var(--border);
  position:fixed;top:0;left:0;height:100vh;overflow-y:auto;z-index:100}
.sidebar-header{padding:18px 16px 12px;border-bottom:1px solid var(--border)}
.sidebar-header h1{font-size:14px;font-weight:700;color:var(--cyan);letter-spacing:.04em}
.sidebar-header p{font-size:11px;color:var(--muted);margin-top:3px}
.nav-group{font-size:10px;font-weight:700;color:var(--muted);text-transform:uppercase;
  letter-spacing:.12em;padding:14px 16px 4px}
.sidebar a{display:flex;align-items:center;gap:8px;padding:6px 16px;color:var(--muted);
  font-size:12px;border-left:2px solid transparent;transition:all .12s}
.sidebar a:hover,.sidebar a.active{color:var(--text);background:var(--s2);border-left-color:var(--cyan)}
.sidebar a .dot{width:6px;height:6px;border-radius:50%;flex-shrink:0}

.main{margin-left:240px;padding:28px 36px;max-width:1500px}
.ts{color:var(--muted);font-size:11px;margin-bottom:28px;
  background:var(--s1);border:1px solid var(--border);border-radius:6px;
  padding:8px 14px;display:inline-block}

/* Headings */
h2{font-size:18px;font-weight:700;margin:36px 0 14px;padding-bottom:8px;
  border-bottom:2px solid var(--border);display:flex;align-items:center;gap:10px}
h3{font-size:13px;font-weight:600;margin:20px 0 8px;
  display:flex;align-items:center;gap:8px;color:var(--text)}
.h2-icon{width:28px;height:28px;border-radius:6px;display:flex;align-items:center;
  justify-content:center;font-size:15px;flex-shrink:0}

/* Badges */
.badge{display:inline-block;padding:2px 8px;border-radius:4px;font-size:10px;
  font-weight:700;text-transform:uppercase;letter-spacing:.06em}
.bg-k3s{background:#0e2a4a;color:var(--blue)}
.bg-bf3{background:#0a2e1e;color:var(--green)}
.bg-dpf{background:#1e0e3a;color:var(--purple)}
.bg-net{background:#0a2a2e;color:var(--cyan)}
.bg-store{background:#2e1e0a;color:var(--yellow)}
.bg-warn{background:#2e1a0a;color:var(--orange)}
.bg-fail{background:#2e0a0a;color:var(--red)}

/* Status */
.ok{color:var(--green);font-weight:600}
.fail{color:var(--red);font-weight:600}
.warn{color:var(--yellow);font-weight:600}
.info{color:var(--blue)}
.purple{color:var(--purple)}
.cyan{color:var(--cyan)}

/* Pre */
pre{background:var(--s1);border:1px solid var(--border);border-radius:8px;
  padding:14px 16px;overflow-x:auto;font-family:'Cascadia Code','Fira Code',
  'Consolas',monospace;font-size:11.5px;line-height:1.65;color:#c8d0e8;
  white-space:pre;word-break:normal}

/* Summary cards */
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px;margin-bottom:24px}
.card{background:var(--s1);border:1px solid var(--border);border-radius:10px;
  padding:16px;transition:border-color .2s}
.card:hover{border-color:var(--cyan)}
.card-title{font-size:13px;font-weight:700;margin-bottom:4px}
.card-sub{font-size:11px;color:var(--muted);margin-bottom:10px}
.card-stat{display:flex;justify-content:space-between;padding:4px 0;
  border-top:1px solid var(--border);font-size:12px}
.card-stat:first-of-type{border-top:none}
.stat-label{color:var(--muted)}

/* Pod grid */
.pod-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:10px;margin-bottom:16px}
.pod-card{background:var(--s1);border:1px solid var(--border);border-radius:8px;padding:12px;
  border-left:3px solid var(--border)}
.pod-card.running{border-left-color:var(--green)}
.pod-card.failing{border-left-color:var(--red)}
.pod-card.pending{border-left-color:var(--yellow)}
.pod-card.succeeded{border-left-color:var(--blue)}
.pod-name{font-weight:700;font-size:12px;word-break:break-all;margin-bottom:2px}
.pod-ns{font-size:10px;color:var(--muted);margin-bottom:6px}
.pod-phase{font-size:11px;margin-bottom:8px}
.containers{padding-top:8px;border-top:1px solid var(--border)}
.ctr{display:flex;align-items:center;gap:7px;padding:3px 0;font-size:11px}
.ctr-name{color:var(--cyan);font-family:monospace}
.ctr-image{color:var(--muted);font-size:10px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:160px}
.dot{width:7px;height:7px;border-radius:50%;flex-shrink:0}
.dot-g{background:var(--green);box-shadow:0 0 4px var(--green)}
.dot-r{background:var(--red);box-shadow:0 0 4px var(--red)}
.dot-y{background:var(--yellow);box-shadow:0 0 4px var(--yellow)}
.restarts{color:var(--orange);font-size:10px;margin-left:4px}

/* Architecture */
.arch{display:flex;flex-direction:column;gap:12px;margin-bottom:20px}
.arch-cluster{background:var(--s1);border:2px solid var(--blue);border-radius:12px;padding:16px}
.arch-cluster-title{font-size:13px;font-weight:700;color:var(--blue);margin-bottom:12px;
  display:flex;align-items:center;gap:8px}
.arch-nodes{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.arch-node{background:var(--s2);border:1px solid var(--border);border-radius:8px;padding:14px}
.arch-node-title{font-size:12px;font-weight:700;margin-bottom:10px;
  display:flex;align-items:center;gap:8px}
.arch-items{display:flex;flex-direction:column;gap:4px}
.arch-item{display:flex;align-items:center;gap:8px;padding:5px 8px;
  background:var(--s3);border-radius:5px;font-size:11px}
.arch-item .name{font-family:monospace;font-weight:600}
.arch-item .role{color:var(--muted);font-size:10px;margin-left:auto}
.arch-separator{text-align:center;color:var(--muted);font-size:18px;line-height:1}

.info-box{background:var(--s2);border-left:3px solid var(--blue);border-radius:0 8px 8px 0;
  padding:10px 14px;margin-bottom:14px;font-size:12px;color:var(--muted)}
.warn-box{background:#1a1000;border-left:3px solid var(--yellow);border-radius:0 8px 8px 0;
  padding:10px 14px;margin-bottom:14px;font-size:12px;color:var(--yellow)}
.error-box{background:#1a0000;border-left:3px solid var(--red);border-radius:0 8px 8px 0;
  padding:10px 14px;margin-bottom:14px;font-size:12px;color:var(--red)}
hr{border:none;border-top:1px solid var(--border);margin:28px 0}

/* Tabs */
.tabs{display:flex;gap:4px;margin-bottom:28px;background:var(--s1);
  padding:6px;border-radius:10px;border:1px solid var(--border);width:fit-content}
.tab-btn{padding:8px 20px;border-radius:7px;border:none;background:transparent;
  color:var(--muted);font-size:12px;font-weight:600;cursor:pointer;transition:all .15s;
  display:flex;align-items:center;gap:7px;font-family:inherit}
.tab-btn:hover{color:var(--text);background:var(--s2)}
.tab-btn.active{background:var(--s2);color:var(--text);border:1px solid var(--border)}
.tab-btn.active.t-overview{color:var(--blue);border-color:var(--blue)}
.tab-btn.active.t-dpf{color:var(--purple);border-color:var(--purple)}
.tab-btn.active.t-bf3{color:var(--green);border-color:var(--green)}
.tab-panel{display:none}.tab-panel.active{display:block}

/* Deep dive styles */
.flow{display:flex;flex-direction:column;gap:0;margin-bottom:20px}
.flow-step{display:flex;align-items:flex-start;gap:14px;padding:12px 0;
  border-left:2px solid var(--border);margin-left:16px;padding-left:20px;position:relative}
.flow-step::before{content:'';width:10px;height:10px;border-radius:50%;
  background:var(--border);position:absolute;left:-6px;top:16px;flex-shrink:0}
.flow-step.done::before{background:var(--green);box-shadow:0 0 6px var(--green)}
.flow-step.fail::before{background:var(--red);box-shadow:0 0 6px var(--red)}
.flow-step.warn::before{background:var(--yellow)}
.flow-step.todo::before{background:var(--muted)}
.flow-title{font-weight:700;font-size:13px;margin-bottom:3px}
.flow-desc{font-size:11px;color:var(--muted);line-height:1.5}
.flow-status{font-size:10px;font-weight:700;margin-top:4px}

.crd-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:10px;margin-bottom:20px}
.crd-card{background:var(--s1);border:1px solid var(--border);border-radius:8px;padding:14px}
.crd-name{font-family:monospace;font-weight:700;font-size:12px;color:var(--purple);margin-bottom:4px}
.crd-kind{font-size:10px;color:var(--muted);margin-bottom:8px;text-transform:uppercase;letter-spacing:.06em}
.crd-desc{font-size:11px;color:var(--text);line-height:1.5;margin-bottom:8px}
.crd-fields{font-size:10px;color:var(--muted);font-family:monospace;line-height:1.6}

.nic-diagram{background:var(--s1);border:1px solid var(--border);border-radius:8px;
  padding:18px;font-family:monospace;font-size:11px;line-height:2;margin-bottom:16px}
</style>
</head>
<body>
<div class="layout">
<nav class="sidebar">
  <div class="sidebar-header">
    <h1>&#x2388; DPF Cluster</h1>
    <p>NVIDIA DPF v25.10.1</p>
  </div>
  <div class="nav-group">Overview</div>
  <a href="#arch"><span class="dot" style="background:var(--cyan)"></span>Architecture</a>
  <a href="#summary"><span class="dot" style="background:var(--blue)"></span>Summary</a>
  <div class="nav-group">k3s Cluster</div>
  <a href="#k3s-nodes"><span class="dot" style="background:var(--blue)"></span>Nodes</a>
  <a href="#k3s-pods"><span class="dot" style="background:var(--green)"></span>Pods &amp; Containers</a>
  <a href="#k3s-net"><span class="dot" style="background:var(--cyan)"></span>Networking</a>
  <a href="#k3s-storage"><span class="dot" style="background:var(--yellow)"></span>Storage</a>
  <div class="nav-group">DPF Resources</div>
  <a href="#dpf-dpu"><span class="dot" style="background:var(--purple)"></span>DPU</a>
  <a href="#dpf-svcs"><span class="dot" style="background:var(--purple)"></span>DPUServices</a>
  <a href="#dpf-cluster"><span class="dot" style="background:var(--purple)"></span>DPUCluster</a>
  <a href="#dpf-bfb"><span class="dot" style="background:var(--purple)"></span>BFB</a>
  <a href="#dpf-argo"><span class="dot" style="background:var(--orange)"></span>ArgoCD</a>
  <div class="nav-group">BF3 (TenantCP)</div>
  <a href="#bf3-nodes"><span class="dot" style="background:var(--green)"></span>Nodes</a>
  <a href="#bf3-pods"><span class="dot" style="background:var(--green)"></span>Pods &amp; Containers</a>
  <a href="#bf3-net"><span class="dot" style="background:var(--cyan)"></span>Networking</a>
</nav>
<main class="main">
HTMLHEAD

echo "<div class='ts'>&#x23F0; Generated: $(date) &nbsp;|&nbsp; DPF VM: 10.4.5.136</div>"

# Tab navigation
if [[ "${DETAILED}" == "true" ]]; then
cat <<'TABS'
<div class="tabs">
  <button class="tab-btn t-overview active" onclick="switchTab('overview')">&#x1f5fa; Cluster Overview</button>
  <button class="tab-btn t-dpf" onclick="switchTab('dpf')">&#x1f9e0; DPF Deep Dive</button>
  <button class="tab-btn t-bf3" onclick="switchTab('bf3arm')">&#x1f4f0; BF3 ARM Deep Dive</button>
</div>
TABS
fi

echo "<div id='tab-overview' class='tab-panel active'>"

# ── Architecture ──────────────────────────────────────────────────────────────
echo "<h2 id='arch'><div class='h2-icon' style='background:#0e1e3a'>&#x2638;</div> Architecture</h2>"
cat <<ARCH
<div class="arch">
  <div class="arch-cluster">
    <div class="arch-cluster-title">
      <span class="badge bg-k3s">k3s</span>
      k3s Cluster &mdash; DPF Operator VM (10.4.5.136)
    </div>
    <div class="arch-nodes">
      <div class="arch-node">
        <div class="arch-node-title">
          <span style="color:var(--blue)">&#x2b1b;</span>
          <span class="cyan">Control Plane</span> (k3s-server)
        </div>
        <div class="arch-items">
          <div class="arch-item"><span class="dot dot-g"></span><span class="name">API Server</span><span class="role">kubectl talks here</span></div>
          <div class="arch-item"><span class="dot dot-g"></span><span class="name">Scheduler</span><span class="role">picks which node</span></div>
          <div class="arch-item"><span class="dot dot-g"></span><span class="name">etcd</span><span class="role">cluster state DB</span></div>
          <div class="arch-item"><span class="dot dot-g"></span><span class="name">Controller Manager</span><span class="role">reconcile loop</span></div>
        </div>
      </div>
      <div class="arch-node">
        <div class="arch-node-title">
          <span style="color:var(--cyan)">&#x25a6;</span>
          <span class="cyan">Worker Node: dpu-vm</span>
        </div>
        <div class="arch-items">
          <div class="arch-item"><span class="dot dot-g"></span><span class="name">dpf-operator</span><span class="role">DPU lifecycle</span></div>
          <div class="arch-item"><span class="dot dot-g"></span><span class="name">dpf-provisioning</span><span class="role">Redfish / rshim</span></div>
          <div class="arch-item"><span class="dot dot-g"></span><span class="name">dpuservice-controller</span><span class="role">deploy to BF3</span></div>
          ${_ARCH_SVC_CTRL}
          <div class="arch-item"><span class="dot dot-g"></span><span class="name">bfb-registry (nginx)</span><span class="role">serves BFB HTTP</span></div>
          <div class="arch-item"><span class="dot dot-g"></span><span class="name">kamaji etcd (x3)</span><span class="role">TenantCP state</span></div>
          <div class="arch-item"><span class="dot dot-g"></span><span class="name">s4-dpu-cluster (x3)</span><span class="role">virtual CP for BF3</span></div>
          <div class="arch-item"><span class="dot dot-g"></span><span class="name">argocd</span><span class="role">GitOps deployments</span></div>
        </div>
      </div>
    </div>
  </div>
  <div style="text-align:center;color:var(--muted);font-size:22px;line-height:1">&#x2193;</div>
  <div class="arch-cluster" style="border-color:var(--green)">
    <div class="arch-cluster-title" style="color:var(--green)">
      <span class="badge bg-bf3">TenantCP</span>
      s4-dpu-cluster &mdash; Virtual k8s for BF3 (runs as pods on DPF VM)
    </div>
    <div class="arch-nodes">
      <div class="arch-node">
        <div class="arch-node-title">
          <span style="color:var(--green)">&#x25a6;</span>
          <span class="ok">Worker Node: s4-dpu</span>
          &nbsp;<span class="badge bg-bf3">BF3 ARM &mdash; 10.20.13.249</span>
        </div>
        <div class="arch-items">
          <div class="arch-item"><span class="dot dot-g"></span><span class="name">kube-proxy</span><span class="role ok">Running</span></div>
          ${_ARCH_COREDNS}
          ${_ARCH_FLANNEL}
          ${_ARCH_MULTUS}
          ${_ARCH_OVSCNI}
          ${_ARCH_IPAM}
          ${_ARCH_SRIOV}
          ${_ARCH_HBN}
        </div>
      </div>
      ${_ARCH_BF3_STATUS_PANEL}
    </div>
  </div>
</div>
ARCH

# ── Summary ───────────────────────────────────────────────────────────────────
echo "<h2 id='summary'><div class='h2-icon' style='background:#0e1e3a'>&#x1f4ca;</div> Summary</h2>"
echo "<div class='cards'>"

DPU_COLOR="ok"; [[ "$DPU_PHASE" != "Ready" ]] && DPU_COLOR="fail"
cat <<HTML
<div class="card" style="border-top:3px solid var(--blue)">
  <div class="card-title cyan">k3s Cluster</div>
  <div class="card-sub">DPF Operator VM &mdash; 10.4.5.136</div>
  <div class="card-stat"><span class="stat-label">Nodes</span><span class="ok">1 (dpu-vm)</span></div>
  <div class="card-stat"><span class="stat-label">Total pods</span><span class="info">$TOTAL_PODS</span></div>
  <div class="card-stat"><span class="stat-label">Running</span><span class="ok">$RUNNING_PODS</span></div>
  <div class="card-stat"><span class="stat-label">Failing</span><span class="fail">$FAILING_PODS</span></div>
  <div class="card-stat"><span class="stat-label">Pending</span><span class="warn">$PENDING_PODS</span></div>
</div>
<div class="card" style="border-top:3px solid var(--green)">
  <div class="card-title ok">BF3 TenantControlPlane</div>
  <div class="card-sub">s4-dpu &mdash; 10.20.13.249</div>
  <div class="card-stat"><span class="stat-label">Node status</span><span class="ok">Ready</span></div>
  <div class="card-stat"><span class="stat-label">Total pods</span><span class="info">$BF3_TOTAL</span></div>
  <div class="card-stat"><span class="stat-label">Running</span><span class="ok">$BF3_RUNNING</span></div>
  <div class="card-stat"><span class="stat-label">CNI (flannel)</span>${_CARD_CNI}</div>
  <div class="card-stat"><span class="stat-label">doca-hbn</span>${_CARD_HBN}</div>
</div>
<div class="card" style="border-top:3px solid var(--purple)">
  <div class="card-title purple">DPU Provisioning</div>
  <div class="card-sub">s4-dpu &mdash; MT2437600HGY</div>
  <div class="card-stat"><span class="stat-label">Phase</span><span class="$DPU_COLOR">$DPU_PHASE</span></div>
  <div class="card-stat"><span class="stat-label">BMC</span><span class="info">10.20.13.250</span></div>
  <div class="card-stat"><span class="stat-label">OOB</span><span class="info">10.20.13.249</span></div>
  <div class="card-stat"><span class="stat-label">Flash method</span><span class="warn">rshim</span></div>
</div>
${_ACTION_CARD}
HTML
echo "</div>"

# ── Two Clusters Explained ────────────────────────────────────────────────────
cat <<'TWOCLUSTERS'
<div style="display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-bottom:28px">
  <div class="card" style="border:2px solid var(--blue)">
    <div class="card-title" style="color:var(--blue);font-size:15px">&#x2460; k3s Cluster</div>
    <div class="card-sub">Management plane &mdash; runs on DPF VM (10.4.5.136)</div>
    <div style="font-size:12px;line-height:1.7;color:var(--muted);margin-top:8px">
      This is the <strong style="color:var(--text)">infrastructure cluster</strong>. It manages the
      DPF Operator, Kamaji, ArgoCD and all the tooling that <em>provisions and manages</em> the BF3.<br><br>
      <strong style="color:var(--text)">Nodes:</strong> 1 (dpu-vm)<br>
      <strong style="color:var(--text)">Kubeconfig:</strong> ~/.kube/config<br>
      <strong style="color:var(--text)">Access:</strong> kubectl get pods -A<br><br>
      You interact with this cluster to deploy DPUServices, check DPU status, manage BFBs.
    </div>
  </div>
  <div class="card" style="border:2px solid var(--green)">
    <div class="card-title" style="color:var(--green);font-size:15px">&#x2461; DPU Cluster (TenantControlPlane)</div>
    <div class="card-sub">Workload plane &mdash; BF3 ARM cores (10.20.13.249)</div>
    <div style="font-size:12px;line-height:1.7;color:var(--muted);margin-top:8px">
      This is the <strong style="color:var(--text)">BF3 workload cluster</strong>. The BF3's kubelet
      joins this cluster. DPUServices (HBN, flannel, OVS-CNI) run here as pods on the BF3.<br><br>
      <strong style="color:var(--text)">Nodes:</strong> 1 (s4-dpu = BF3)<br>
      <strong style="color:var(--text)">Kubeconfig:</strong> /tmp/dpu-tc-kubeconfig<br>
      <strong style="color:var(--text)">Access:</strong> kubectl --kubeconfig /tmp/dpu-tc-kubeconfig get pods -A<br><br>
      Its control plane (apiserver + etcd) runs as <em>pods inside</em> Cluster 1 (powered by Kamaji).
      Two clusters, one physical VM hosting the control planes of both.
    </div>
  </div>
</div>
TWOCLUSTERS

# ── k3s Nodes ─────────────────────────────────────────────────────────────────
echo "<h2 id='k3s-nodes'><div class='h2-icon' style='background:#0e1e3a'>&#x1f5a5;</div> k3s Cluster &mdash; Nodes <span class='badge bg-k3s'>k3s</span></h2>"
echo "<pre>$K3S_NODES</pre>"

# ── k3s Pods & Containers ─────────────────────────────────────────────────────
echo "<h2 id='k3s-pods'><div class='h2-icon' style='background:#0a2e1e'>&#x1f4e6;</div> k3s Cluster &mdash; Pods &amp; Containers <span class='badge bg-k3s'>k3s</span></h2>"
echo "<div class='info-box'>Each card is one Pod. The coloured left border and dots show health. All pods run on <strong>dpu-vm</strong> (the DPF VM).</div>"
echo "<div class='pod-grid'>"

echo "$K3S_PODS_JSON" | python3 -c "
import json, sys

# Pod descriptions — keyed by name prefix
POD_DESC = {
  'argocd-application-controller': 'GitOps engine — watches Git repos and syncs k8s resources',
  'argocd-applicationset-controller': 'Generates ArgoCD Applications from templates (used by DPF for DPUServices)',
  'argocd-dex-server': 'SSO/auth provider for ArgoCD UI login',
  'argocd-notifications-controller': 'Sends alerts when ArgoCD sync succeeds or fails',
  'argocd-redis': 'Cache for ArgoCD — stores app state and session data',
  'argocd-repo-server': 'Clones Git repos and renders Helm/Kustomize manifests',
  'argocd-server': 'ArgoCD API server + web UI (port 443)',
  'cert-manager': 'Issues and renews TLS certificates automatically (used by Kamaji, DPF)',
  'cert-manager-cainjector': 'Injects CA bundles into webhook configs so TLS trust works',
  'cert-manager-webhook': 'Validates Certificate resources when they are applied',
  'grpcurl-debug': 'Debug pod for testing gRPC endpoints (leftover from earlier testing)',
  'pod-a': 'Test pod from earlier work (can be deleted)',
  'pod-b': 'Test pod from earlier work (can be deleted)',
  'bfb-registry': 'nginx serving the BFB OS image over HTTP (port 8080) — BMC downloads from here',
  'dpf-dpu-detector': 'Detects BF3 hardware on nodes and labels them for DPF scheduling',
  'dpf-operator-controller-manager': 'DPF brain — reconciles DPU, DPUDevice, DPUNode CRs, drives provisioning lifecycle',
  'dpf-operator-kamaji-etcd-defrag': 'Periodic etcd defrag job — keeps Kamaji etcd healthy. Stuck = secret missing',
  'dpf-provisioning-controller-manager': 'Handles OS install — calls BMC Redfish API or coordinates rshim flash',
  'dpuservice-controller-manager': 'Translates DPUService CRs into ArgoCD Applications that deploy onto the BF3',
  'kamaji-cm-controller-manager': 'Kamaji ConfigMap controller — syncs cluster config to TenantControlPlanes',
  's4-dpu-cluster': 'Virtual k8s control plane for BF3 (3 pods = HA). Contains kube-apiserver + scheduler + controller-manager',
  'servicechainset-controller-manager': 'Manages OVS traffic steering chains on BF3 — watches DPUServiceChain CRs and programs OpenFlow rules',
  'istio-egressgateway': 'Istio: controls outbound traffic from the mesh',
  'istio-ingressgateway': 'Istio: entry point for inbound traffic into the mesh',
  'istiod': 'Istio control plane — manages service mesh config, mTLS certs',
  'etcd-0': 'Kamaji etcd node 0 — stores state for all TenantControlPlanes',
  'etcd-1': 'Kamaji etcd node 1 — HA replica',
  'etcd-2': 'Kamaji etcd node 2 — HA replica',
  'kamaji': 'Kamaji controller — creates/manages virtual k8s control planes (TenantControlPlanes) as pods',
  'coredns': 'DNS server for the k3s cluster — resolves service names to IPs',
  'helm-install-traefik': 'One-time Helm install job for Traefik (completed)',
  'local-path-provisioner': 'Creates PersistentVolumes from local disk (used for bfb-pvc)',
  'metrics-server': 'Collects CPU/memory metrics from nodes (for kubectl top)',
  'svclb-istio': 'k3s load balancer for Istio ingress (Pending = no external IP assigned)',
  'svclb-traefik': 'k3s load balancer for Traefik ingress',
  'traefik': 'Ingress controller — routes external HTTP/HTTPS into the cluster',
  'node-feature-discovery-gc': 'Cleans up stale node feature labels',
  'node-feature-discovery-master': 'Collects hardware feature labels from nodes (CPU, GPU, etc.)',
  'node-feature-discovery-worker': 'Runs on each node, detects hardware features, reports to master',
}

# Container descriptions
CTR_DESC = {
  'kube-apiserver': 'REST API server — all kubectl commands go here',
  'kube-scheduler': 'Decides which node each pod runs on',
  'kube-controller-manager': 'Runs control loops (deployments, replicasets, etc.)',
  'manager': 'Main controller binary for this operator',
  'nginx': 'Web server serving BFB files over HTTP',
  'dpu-detector': 'Scans for BF3 hardware and adds node labels',
  'etcd': 'Key-value store for all cluster state',
  'etcd-defrag': 'Compacts etcd database to reclaim space',
  'argocd-application-controller': 'Syncs desired state from Git to cluster',
  'argocd-applicationset-controller': 'Generates Applications from templates',
  'argocd-repo-server': 'Renders Helm/Kustomize from Git',
  'argocd-server': 'API server + web UI',
  'dex': 'OAuth2/OIDC provider for SSO',
  'redis': 'In-memory cache for ArgoCD session data',
  'cert-manager-controller': 'Issues certificates from configured issuers',
  'cert-manager-cainjector': 'Injects CA trust bundles into webhook configs',
  'cert-manager-webhook': 'Validates Certificate resource specs',
  'istiod': 'Manages mTLS, service discovery, traffic policy',
  'istio-proxy': 'Envoy sidecar — intercepts all pod network traffic',
  'discovery': 'Istio pilot — pushes config to all Envoy proxies',
  'local-path-provisioner': 'Creates PVs backed by local node disk',
  'metrics-server': 'Scrapes kubelet for resource usage metrics',
  'traefik': 'Reverse proxy and ingress controller',
  'coredns': 'DNS resolution for .cluster.local service names',
  'helm': 'Runs helm install/upgrade for k3s built-in charts',
  'master': 'Aggregates node feature labels',
  'worker': 'Detects hardware features on this node',
  'gc': 'Garbage collects stale feature labels',
  'grpcurl': 'gRPC testing tool',
  'container-a': 'Test container',
  'container-b': 'Test container',
  'lb-tcp-80': 'Load balances port 80',
  'lb-tcp-443': 'Load balances port 443',
  'lb-tcp-15021': 'Load balances Istio health check port',
  'lb-tcp-31400': 'Load balances Istio TCP port',
  'lb-tcp-15443': 'Load balances Istio mTLS port',
}

def get_desc(name, lookup):
    for k, v in lookup.items():
        if name.startswith(k) or name == k:
            return v
    return ''

data = json.load(sys.stdin)
for pod in data['items']:
    ns    = pod['metadata']['namespace']
    name  = pod['metadata']['name']
    phase = pod.get('status', {}).get('phase', 'Unknown')
    cs    = pod.get('status', {}).get('containerStatuses', [])
    specs = pod['spec']['containers']
    cls   = {'Running':'running','Pending':'pending','Succeeded':'succeeded'}.get(phase,'failing')
    pcol  = {'Running':'ok','Pending':'warn','Succeeded':'info'}.get(phase,'fail')
    desc  = get_desc(name, POD_DESC)
    print(f'<div class=\"pod-card {cls}\">')
    print(f'<div class=\"pod-name\">{name}</div>')
    print(f'<div class=\"pod-ns\">{ns}</div>')
    if desc:
        print(f'<div style=\"font-size:10px;color:var(--muted);margin-bottom:6px;line-height:1.4\">{desc}</div>')
    print(f'<div class=\"pod-phase\">Phase: <span class=\"{pcol}\">{phase}</span></div>')
    print(f'<div class=\"containers\">')
    for i, c in enumerate(specs):
        cname = c['name']
        img   = c['image'].split('/')[-1][:38]
        ready = False; restarts = 0; state = 'waiting'
        if i < len(cs):
            ready    = cs[i].get('ready', False)
            restarts = cs[i].get('restartCount', 0)
            st = cs[i].get('state', {})
            state = 'running' if 'running' in st else ('terminated' if 'terminated' in st else 'waiting')
        dot  = 'dot-g' if ready else ('dot-y' if state == 'terminated' else 'dot-r')
        rw   = f'<span class=\"restarts\">&#9650; {restarts}</span>' if restarts > 3 else ''
        cdesc = get_desc(cname, CTR_DESC)
        ctip = f' title=\"{cdesc}\"' if cdesc else ''
        print(f'<div class=\"ctr\"{ctip}><div class=\"dot {dot}\"></div><span class=\"ctr-name\">{cname}</span><span class=\"ctr-image\">{img}</span>{rw}</div>')
        if cdesc:
            print(f'<div style=\"font-size:10px;color:var(--muted);padding:1px 0 3px 22px;line-height:1.3\">{cdesc}</div>')
    print('</div></div>')
"

echo "</div>"

echo "<h3>All Pods &mdash; Table View</h3>"
echo "<pre>$K3S_PODS</pre>"

# ── Networking ────────────────────────────────────────────────────────────────
echo "<h2 id='k3s-net'><div class='h2-icon' style='background:#0a2a2e'>&#x1f310;</div> k3s Cluster &mdash; Networking <span class='badge bg-net'>net</span></h2>"
echo "<h3>Services</h3><pre>$K3S_SVC</pre>"

# ── Storage ───────────────────────────────────────────────────────────────────
echo "<h2 id='k3s-storage'><div class='h2-icon' style='background:#2e1e0a'>&#x1f4be;</div> k3s Cluster &mdash; Storage <span class='badge bg-store'>storage</span></h2>"
echo "<h3>PersistentVolumeClaims</h3><pre>$K3S_PVC</pre>"
echo "<h3>PersistentVolumes</h3><pre>$K3S_PV</pre>"
echo "<h3>StorageClasses</h3><pre>$K3S_SC</pre>"

# ── DPF Resources ─────────────────────────────────────────────────────────────
echo "<h2 id='dpf-dpu'><div class='h2-icon' style='background:#1e0e3a'>&#x1f9e0;</div> DPF &mdash; DPU Provisioning <span class='badge bg-dpf'>dpf</span></h2>"
echo "<h3>DPU</h3><pre>$DPF_DPU</pre>"

echo "<h2 id='dpf-svcs'><div class='h2-icon' style='background:#1e0e3a'>&#x1f527;</div> DPF &mdash; DPUServices <span class='badge bg-dpf'>dpf</span></h2>"
echo "${_DPUSVC_BOX}"
echo "<h3>DPUServices</h3><pre>$DPF_SVC</pre>"
echo "<h3>servicechainset-controller Logs</h3>"
echo "<div class='error-box'>&#x1f525; This pod is blocking all DPUService deployments</div>"
echo "<pre>$SVC_LOGS</pre>"

echo "<h2 id='dpf-cluster'><div class='h2-icon' style='background:#1e0e3a'>&#x1f517;</div> DPF &mdash; DPUCluster <span class='badge bg-dpf'>dpf</span></h2>"
echo "<h3>DPUCluster</h3><pre>$DPF_CLUSTER</pre>"

echo "<h2 id='dpf-bfb'><div class='h2-icon' style='background:#1e0e3a'>&#x1f4e6;</div> DPF &mdash; BFB <span class='badge bg-dpf'>dpf</span></h2>"
echo "<h3>BFB Resources</h3><pre>$DPF_BFB</pre>"

echo "<h2 id='dpf-argo'><div class='h2-icon' style='background:#2a1000'>&#x1f504;</div> DPF &mdash; ArgoCD <span class='badge bg-warn'>argocd</span></h2>"
echo "<h3>Applications</h3><pre>$ARGO_APPS</pre>"

# ── BF3 TenantControlPlane ────────────────────────────────────────────────────
echo "<h2 id='bf3-nodes'><div class='h2-icon' style='background:#0a2e1e'>&#x1f4f0;</div> BF3 TenantControlPlane &mdash; Nodes <span class='badge bg-bf3'>bf3</span></h2>"
if [[ "${DPU_KUBE_AVAILABLE}" == "true" ]]; then
  echo "<pre>$BF3_NODES</pre>"
else
  echo "<div class='warn-box'>TenantControlPlane kubeconfig not available</div>"
fi

echo "<h2 id='bf3-pods'><div class='h2-icon' style='background:#0a2e1e'>&#x1f4e6;</div> BF3 TenantControlPlane &mdash; Pods &amp; Containers <span class='badge bg-bf3'>bf3</span></h2>"
if [[ "${DPU_KUBE_AVAILABLE}" == "true" ]]; then
  if [[ "${BF3_COREDNS_CC:-0}" -gt 0 ]]; then
    echo "<div class='error-box'>&#x274c; CoreDNS stuck in ContainerCreating &mdash; flannel CNI not deployed yet.</div>"
  elif [[ "${BF3_HBN_RUNNING:-0}" -gt 0 ]]; then
    echo "<div class='info-box'>&#x2705; All BF3 pods healthy &mdash; doca-hbn Running, flannel CNI active.</div>"
  fi
  echo "<div class='pod-grid'>"
  echo "$BF3_PODS_JSON" | python3 -c "
import json, sys

BF3_POD_DESC = {
  'kube-proxy':  'Runs on every node — manages iptables rules for Service routing (ClusterIP, NodePort)',
  'coredns':     'DNS server for the BF3 cluster — resolves .cluster.local service names. Requires flannel CNI to start.',
  'flannel':     'CNI network plugin — gives each pod a unique IP. Must deploy first before any other pod works',
  'multus':      'Multi-NIC CNI — lets HBN pod have separate mgmt + data plane interfaces',
  'ovs-cni':     'Connects pod interfaces directly into the OVS-DPDK bridge (br-hbn)',
  'nvidia-k8s-ipam': 'IPAM for OVS/SR-IOV ports — assigns data plane IPs to pods',
  'sriov-device-plugin': 'Exposes BF3 SubFunctions (SFs) as schedulable Kubernetes resources',
  'doca-hbn':    'HBN workload — runs FRR routing + OVS + NVUE REST API for data plane networking',
}

BF3_CTR_DESC = {
  'kube-proxy':  'Watches Services and updates iptables/IPVS rules',
  'coredns':     'Resolves .cluster.local DNS names to pod/service IPs',
  'flannel':     'Sets up vxlan overlay and writes CNI config to /etc/cni/net.d/',
  'kube-multus': 'Meta-CNI delegating to multiple CNI plugins per pod',
  'ovs-cni':     'Attaches pod veth into OVS bridge port',
  'ipam':        'Allocates IPs for OVS and SR-IOV interfaces',
  'kube-sriovdp': 'Advertises available VFs/SFs as node resources',
}

def get_desc(name, lookup):
    for k, v in lookup.items():
        if name.startswith(k) or name == k:
            return v
    return ''

data = json.load(sys.stdin)
for pod in data['items']:
    ns    = pod['metadata']['namespace']
    name  = pod['metadata']['name']
    phase = pod.get('status', {}).get('phase', 'Unknown')
    cs    = pod.get('status', {}).get('containerStatuses', [])
    specs = pod['spec']['containers']
    cls   = {'Running':'running','Pending':'pending','Succeeded':'succeeded'}.get(phase,'failing')
    pcol  = {'Running':'ok','Pending':'warn','Succeeded':'info'}.get(phase,'fail')
    desc  = get_desc(name, BF3_POD_DESC)
    print(f'<div class=\"pod-card {cls}\">')
    print(f'<div class=\"pod-name\">{name}</div>')
    print(f'<div class=\"pod-ns\">{ns}</div>')
    if desc:
        print(f'<div style=\"font-size:10px;color:var(--muted);margin-bottom:6px;line-height:1.4\">{desc}</div>')
    print(f'<div class=\"pod-phase\">Phase: <span class=\"{pcol}\">{phase}</span></div>')
    print(f'<div class=\"containers\">')
    for i, c in enumerate(specs):
        cname = c['name']
        img   = c['image'].split('/')[-1][:38]
        ready = False; restarts = 0
        if i < len(cs):
            ready    = cs[i].get('ready', False)
            restarts = cs[i].get('restartCount', 0)
        dot   = 'dot-g' if ready else 'dot-r'
        rw    = f'<span class=\"restarts\">&#9650; {restarts}</span>' if restarts > 3 else ''
        cdesc = get_desc(cname, BF3_CTR_DESC)
        print(f'<div class=\"ctr\"><div class=\"dot {dot}\"></div><span class=\"ctr-name\">{cname}</span><span class=\"ctr-image\">{img}</span>{rw}</div>')
        if cdesc:
            print(f'<div style=\"font-size:10px;color:var(--muted);padding:1px 0 3px 22px;line-height:1.3\">{cdesc}</div>')
    print('</div></div>')
"
  echo "</div>"
  echo "<h3>All Pods &mdash; Table View</h3><pre>$BF3_PODS</pre>"
fi

echo "<h2 id='bf3-net'><div class='h2-icon' style='background:#0a2a2e'>&#x1f310;</div> BF3 TenantControlPlane &mdash; Networking <span class='badge bg-net'>net</span></h2>"
if [[ "${DPU_KUBE_AVAILABLE}" == "true" ]]; then
  echo "<h3>Services</h3><pre>$BF3_SVC</pre>"
fi

# Close overview tab
echo "</div>"

# ── DPF Deep Dive Tab ────────────────────────────────────────────────────────
if [[ "${DETAILED}" == "true" ]]; then
echo "<div id='tab-dpf' class='tab-panel'>"

cat <<DPFTAB
<h2><div class='h2-icon' style='background:#1e0e3a'>&#x1f9e0;</div> DPF Deep Dive <span class='badge bg-dpf'>dpf</span></h2>

<div class='info-box'>
  DPF (DPU Provisioning Framework) is a Kubernetes operator that manages the full lifecycle of BlueField DPUs —
  from OS flashing to workload deployment. You interact with DPF by creating Kubernetes Custom Resources (CRDs).
  DPF reconciles them against the actual state of the hardware.
</div>

<h3>How DPF CRDs Relate to Each Other</h3>
<div class='crd-grid'>
  <div class='crd-card' style='border-top:2px solid var(--blue)'>
    <div class='crd-name'>DPFOperatorConfig</div>
    <div class='crd-kind'>Global Config</div>
    <div class='crd-desc'>The master switch. One per cluster. Tells DPF which install method to use (Redfish/rshim), where the BFB registry is, and bootstraps all sub-controllers including bfb-registry DaemonSet and provisioning controller.</div>
    <div class='crd-fields'>spec.provisioningController.installInterface.installViaRedfish<br>spec.bfbRegistryAddress</div>
  </div>
  <div class='crd-card' style='border-top:2px solid var(--cyan)'>
    <div class='crd-name'>BFB</div>
    <div class='crd-kind'>OS Image</div>
    <div class='crd-desc'>Points to a .bfb file URL. DPF downloads it into the bfb PVC. The bfb-registry nginx pod then serves it to the BMC over HTTP. One BFB can be shared across many DPUs.</div>
    <div class='crd-fields'>spec.url: http://10.4.5.136:9090/bf-bundle.bfb<br>status.phase: Ready | Downloading | Failed</div>
  </div>
  <div class='crd-card' style='border-top:2px solid var(--yellow)'>
    <div class='crd-name'>DPUFlavor</div>
    <div class='crd-kind'>Hardware Profile</div>
    <div class='crd-desc'>Hardware configuration template — hugepages, CPU affinity, OVS mode (raw/kernel), NUMA settings. Applied to the BF3 during provisioning. Think of it as the "server profile" for the DPU.</div>
    <div class='crd-fields'>spec.grub.kernelParameters<br>spec.ovs.rawMode</div>
  </div>
  <div class='crd-card' style='border-top:2px solid var(--purple)'>
    <div class='crd-name'>DPUCluster</div>
    <div class='crd-kind'>Virtual k8s Cluster</div>
    <div class='crd-desc'>Tells DPF to create a virtual Kubernetes control plane (TenantControlPlane via Kamaji) for this group of DPUs. The BF3 kubelet joins this cluster. One DPUCluster per tenant/environment.</div>
    <div class='crd-fields'>spec.type: kamaji<br>spec.version: 1.33.0<br>status.phase: Ready</div>
  </div>
  <div class='crd-card' style='border-top:2px solid var(--muted)'>
    <div class='crd-name'>DPUNode</div>
    <div class='crd-kind'>x86 Host Reference</div>
    <div class='crd-desc'>Represents the x86 host server. In OOB-only mode (your setup), this is optional — the x86 host does NOT join k8s. Used only to link the host server identity to a DPU device.</div>
    <div class='crd-fields'>spec.kubeNodeRef (optional in OOB mode)</div>
  </div>
  <div class='crd-card' style='border-top:2px solid var(--orange)'>
    <div class='crd-name'>DPUDevice</div>
    <div class='crd-kind'>Physical BF3 Identity</div>
    <div class='crd-desc'>Represents the physical BF3 card. Links the serial number to the BMC IP. Immutable once set — serial number and BMC IP cannot be changed without deleting and recreating.</div>
    <div class='crd-fields'>spec.serialNumber: MT2437600HGY<br>spec.bmcIp: 10.20.13.250 (immutable)</div>
  </div>
  <div class='crd-card' style='border-top:2px solid var(--red)'>
    <div class='crd-name'>DPU</div>
    <div class='crd-kind'>Provisioning Trigger</div>
    <div class='crd-desc'>The top-level resource that ties everything together. References BFB, DPUFlavor, DPUCluster, DPUNode, DPUDevice. Creating a DPU CR triggers the full provisioning pipeline — OS flash + cluster join.</div>
    <div class='crd-fields'>spec.bfb / dpuFlavor / dpuCluster<br>status.phase: Initializing → Ready | Error<br>status.bfCFGFile: path to cloud-init config</div>
  </div>
  <div class='crd-card' style='border-top:2px solid var(--green)'>
    <div class='crd-name'>DPUService</div>
    <div class='crd-kind'>BF3 Workload</div>
    <div class='crd-desc'>A Helm chart to deploy onto the BF3 via ArgoCD. DPF translates each DPUService CR into an ArgoCD Application which deploys the chart onto the TenantControlPlane. flannel, multus, HBN are all DPUServices.</div>
    <div class='crd-fields'>spec.helmChart.source.repoURL<br>spec.helmChart.values<br>status.phase: Ready | Pending | Error</div>
  </div>
</div>

<h3>Provisioning Flow — Current State</h3>
<div class='flow'>
  <div class='flow-step done'>
    <div><div class='flow-title'>1. DPFOperatorConfig created</div>
    <div class='flow-desc'>Bootstraps bfb-registry DaemonSet and provisioning controller. Configures Redfish endpoint and BFB registry address.</div>
    <div class='flow-status ok'>&#x2713; Complete</div></div>
  </div>
  <div class='flow-step done'>
    <div><div class='flow-title'>2. BFB downloaded into PVC</div>
    <div class='flow-desc'>DPF downloaded bf-bundle-3.3.0-202 from http://10.4.5.136:9090 into the bfb-pvc (30Gi local-path). bfb-registry nginx now serves it at http://10.4.5.136:8080/bfb/&lt;filename&gt;.</div>
    <div class='flow-status ok'>&#x2713; Complete — BFB phase: Ready</div></div>
  </div>
  <div class='flow-step done'>
    <div><div class='flow-title'>3. DPUCluster created — TenantControlPlane bootstrapped</div>
    <div class='flow-desc'>Kamaji created 3 replica pods (s4-dpu-cluster-*) each running kube-apiserver + kube-scheduler + kube-controller-manager. This is the virtual k8s cluster the BF3 joins.</div>
    <div class='flow-status ok'>&#x2713; Complete — 3/3 pods Running</div></div>
  </div>
  <div class='flow-step done'>
    <div><div class='flow-title'>4. DPF generated bfcfg (cloud-init user-data)</div>
    <div class='flow-desc'>DPF generated a cloud-init config containing the kubeadm join command and systemd service definitions. Stored in the BFB PVC at bfcfg/dpf-operator-system_s4-dpu_&lt;uid&gt;. Injected into BF3 via bfb-install --config.</div>
    <div class='flow-status ok'>&#x2713; Complete — status.bfCFGFile present</div></div>
  </div>
  <div class='flow-step warn'>
    <div><div class='flow-title'>5. OS Flash via Redfish</div>
    <div class='flow-desc'>DPF called BMC Redfish API to stage and flash the BFB. FAILED — BMC has only ~444MB RAM storage, BFB is 1.5GB. BMC cannot stage the file. Redfish is NOT viable on this hardware.</div>
    <div class='flow-status warn'>&#x26a0; Skipped — BMC storage too small. Used rshim instead.</div></div>
  </div>
  <div class='flow-step done'>
    <div><div class='flow-title'>5b. OS Flash via rshim (workaround)</div>
    <div class='flow-desc'>bfb-install run on x86 host (10.20.13.207) via PCIe rshim connection. Flashed BFB + injected bfcfg. BF3 rebooted into new Ubuntu OS with kubeadm-join.service enabled.</div>
    <div class='flow-status ok'>&#x2713; Complete — bf-bundle-3.3.0-202 installed</div></div>
  </div>
  <div class='flow-step done'>
    <div><div class='flow-title'>6. BF3 joined TenantControlPlane</div>
    <div class='flow-desc'>kubeadm-join.service ran on first boot. kubeadm joined 10.4.5.136:6443 (via SSH tunnel workaround — TCP from 10.20.13.x to 10.4.5.x is blocked by lab firewall). BF3 kubelet now connected.</div>
    <div class='flow-status ok'>&#x2713; Complete — s4-dpu node Ready, kubelet v1.34.4</div></div>
  </div>
  <div class='flow-step ${_FLOW7_CLASS}'>
    <div><div class='flow-title'>7. DPUServices deploy to BF3</div>
    <div class='flow-desc'>DPF deploys flannel, multus, ovs-cni, nvidia-k8s-ipam, sriov-device-plugin onto the BF3 via ArgoCD. Requires servicechainset-controller healthy on management cluster.</div>
    ${_FLOW7_STATUS}</div>
  </div>
  <div class='flow-step ${_FLOW8_CLASS}'>
    <div><div class='flow-title'>8. Deploy HBN as DPUService</div>
    <div class='flow-desc'>doca-hbn DaemonSet running on BF3 ARM. FRR handles routing (static + BGP). NVUE REST API on port 8765. OVS-DPDK br-hbn connects p0/p1 uplinks to host PFs and VFs.</div>
    ${_FLOW8_STATUS}</div>
  </div>
</div>

<h3>DPU Current Conditions</h3>
DPFTAB
echo "<pre>${DPF_DPU_DETAIL}</pre>"

echo "<h3>DPUServices Detail</h3>"
echo "<pre>${DPF_SVC_DETAIL}</pre>"

echo "<h3>DPUCluster Detail</h3>"
echo "<pre>${DPF_CLUSTER_DETAIL}</pre>"

echo "<h3>ServiceChains</h3><pre>${DPF_CHAINS}</pre>"
echo "<h3>ServiceInterfaceSets</h3><pre>${DPF_IFSETS}</pre>"
echo "<h3>DPUServiceIPAM</h3><pre>${DPF_IPAM}</pre>"
echo "<h3>Recent Events (dpf-operator-system)</h3><pre>${K3S_EVENTS}</pre>"

echo "</div>"

# ── BF3 ARM Deep Dive Tab ────────────────────────────────────────────────────
echo "<div id='tab-bf3arm' class='tab-panel'>"

cat <<BF3TAB
<h2><div class='h2-icon' style='background:#0a2e1e'>&#x1f4f0;</div> BF3 ARM Deep Dive <span class='badge bg-bf3'>bf3</span></h2>

<div class='info-box'>
  The BlueField-3 DPU contains two independent compute environments on one card:
  ARM cores (running Ubuntu + kubelet) and the NIC ASIC (handling packet forwarding in hardware).
  DPF manages the ARM side. HBN configures the NIC/data-plane side.
</div>

<h3>What the BF3 Actually Is</h3>
<div style='display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:20px'>
  <div class='crd-card' style='border-top:2px solid var(--green)'>
    <div class='crd-name' style='color:var(--green)'>ARM Side (Compute)</div>
    <div class='crd-kind'>DPF manages this</div>
    <div class='crd-desc' style='line-height:1.8'>
      &#x25a6; 8x ARM Cortex-A72 cores<br>
      &#x25a6; Ubuntu 24.04 (64k page kernel)<br>
      &#x25a6; kubelet — joins TenantControlPlane<br>
      &#x25a6; containerd — runs pods<br>
      &#x25a6; OVS-DPDK — packet forwarding<br>
      &#x25a6; OOB IP: 10.20.13.249 (management)<br>
      &#x25a6; BMC IP: 10.20.13.250 (Redfish API)
    </div>
  </div>
  <div class='crd-card' style='border-top:2px solid var(--cyan)'>
    <div class='crd-name' style='color:var(--cyan)'>NIC Side (Data Plane)</div>
    <div class='crd-kind'>HBN configures this</div>
    <div class='crd-desc' style='line-height:1.8'>
      &#x25a6; ConnectX-7 ASIC (400GbE)<br>
      &#x25a6; p0, p1 — physical ports to ToR switch<br>
      &#x25a6; eswitch — hardware packet steering<br>
      &#x25a6; switchdev mode — SR-IOV + offload<br>
      &#x25a6; SubFunctions (SFs) — virtual NICs for pods<br>
      &#x25a6; pf0hpf, pf1hpf — PCIe link to x86 host
    </div>
  </div>
</div>

<h3>Network Interface Architecture on BF3</h3>
<div class='nic-diagram'>
<span style='color:var(--cyan)'>ToR Switch (10.20.13.214)</span>
    |                    |
<span style='color:var(--orange)'>p0 (physical)        p1 (physical)</span>         &larr; 400GbE uplinks
    |                    |
<span style='color:var(--yellow)'>[BF3 eswitch — switchdev mode — hardware offload]</span>
    |                    |
<span style='color:var(--purple)'>p0_if_r              p1_if_r</span>                &larr; representors in OVS
    \                  /
     <span style='color:var(--green)'>OVS-DPDK (br-hbn)</span>                       &larr; software bridge
     /        |        \
<span style='color:var(--cyan)'>pf0hpf_if_r   SF_r    pf1hpf_if_r</span>          &larr; host/pod representors
    |                    |
<span style='color:var(--blue)'>pf0hpf               pf1hpf</span>                 &larr; PCIe SubFunctions
    |                    |
<span style='color:var(--text)'>x86 host (enp193s0f0np0)   (enp193s0f0np1)</span>  &larr; host sees these as NICs

Inside doca-hbn pod (runs on BF3 ARM):
<span style='color:var(--green)'>p0_if, p1_if, pf0hpf_if</span>                    &larr; pod-side interfaces
FRR (zebra, staticd, bgpd) + NVUE REST :8765 &larr; routing daemons
</div>

<h3>How Pods Work on the BF3 (CNI stack)</h3>
<div class='flow'>
  <div class='flow-step ${_FL_CLS}'>
    <div><div class='flow-title'>1. flannel — Pod overlay network (CNI)</div>
    <div class='flow-desc'>Every pod needs an IP address. flannel creates a vxlan overlay network (10.244.0.0/16) and writes the CNI config to /etc/cni/net.d/. Without this, no pod can start — kubelet creates the container but cannot set up networking.</div>
    ${_FL_ST}</div>
  </div>
  <div class='flow-step ${_MT_CLS}'>
    <div><div class='flow-title'>2. multus — Multiple network interfaces per pod</div>
    <div class='flow-desc'>Normal k8s gives each pod one interface. Multus is a meta-CNI that lets a pod attach multiple interfaces via NetworkAttachmentDefinitions. HBN needs: eth0 (flannel, management) + net1 (ovs-cni, data plane).</div>
    ${_MT_ST}</div>
  </div>
  <div class='flow-step ${_OV_CLS}'>
    <div><div class='flow-title'>3. ovs-cni — Connect pods to OVS bridge</div>
    <div class='flow-desc'>ovs-cni attaches a pod's network interface directly into the OVS-DPDK bridge (br-hbn). When the doca-hbn pod starts, ovs-cni wires net1 into br-hbn so HBN's FRR can see physical traffic from p0/p1.</div>
    ${_OV_ST}</div>
  </div>
  <div class='flow-step ${_IP_CLS}'>
    <div><div class='flow-title'>4. nvidia-k8s-ipam — Data plane IP management</div>
    <div class='flow-desc'>Manages IP address pools for OVS ports and SR-IOV VFs/SFs. Assigns IPs to PFs and VFs for the data plane interfaces.</div>
    ${_IP_ST}</div>
  </div>
  <div class='flow-step ${_SR_CLS}'>
    <div><div class='flow-title'>5. sriov-device-plugin — Expose SFs as k8s resources</div>
    <div class='flow-desc'>Discovers BF3 SubFunctions (SFs) and advertises them as schedulable Kubernetes resources (nvidia.com/bf3_sf). Pods can request an SF like a GPU — k8s assigns it exclusively to that pod.</div>
    ${_SR_ST}</div>
  </div>
  <div class='flow-step ${_HB_CLS}'>
    <div><div class='flow-title'>6. doca-hbn — HBN workload pod</div>
    <div class='flow-desc'>The actual networking workload. Runs FRR (BGP, static routing), OVS-DPDK configuration, and the NVUE REST API. Connected to br-hbn via ovs-cni. Manages p0, p1, pf0hpf interfaces.</div>
    ${_HB_ST}</div>
  </div>
</div>

<h3>kubelet → TenantControlPlane Connection</h3>
<div style='display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:20px'>
  <div class='crd-card'>
    <div class='crd-name' style='color:var(--green)'>How it connects</div>
    <div class='crd-desc' style='line-height:1.8'>
      1. bfcfg (cloud-init) runs kubeadm join<br>
      2. kubeadm contacts TenantControlPlane at 10.4.5.136:6443<br>
      3. <span style='color:var(--yellow)'>Lab note: TCP from 10.20.13.x → 10.4.5.x is blocked</span><br>
      4. Workaround: SSH reverse tunnel DPF VM → x86 host<br>
         x86 host listens 0.0.0.0:6443 → forwards to Kamaji<br>
      5. BF3 iptables OUTPUT DNAT: 10.4.5.136:6443 → 10.20.13.207:6443<br>
         (keeps TLS cert valid — cert has SAN for 10.4.5.136)
    </div>
  </div>
  <div class='crd-card'>
    <div class='crd-name' style='color:var(--cyan)'>Current state</div>
    <div class='crd-desc' style='line-height:1.8'>
      &#x2713; kubelet active (systemd service)<br>
      &#x2713; Node s4-dpu: Ready, v1.34.4<br>
      &#x2713; kube-proxy: Running<br>
      ${_BF3_KUBELET_DNS}
      ${_BF3_KUBELET_FL}
      ${_BF3_KUBELET_HBN}<br>
      <span style='color:var(--muted)'>Tunnel must be active for kubelet to stay connected:<br>
      tunnel_dpf.sh start</span>
    </div>
  </div>
</div>
BF3TAB

echo "<h3>BF3 Node Detail</h3>"
echo "<pre>${BF3_NODE_DETAIL}</pre>"
echo "<h3>BF3 Recent Events</h3>"
echo "<pre>${BF3_EVENTS}</pre>"

echo "</div>" # close bf3arm tab

fi # end DETAILED

cat <<'HTMLFOOT'
</main>
</div>
<script>
function switchTab(name) {
  document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  document.getElementById('tab-' + name).classList.add('active');
  document.querySelector('.tab-btn.t-' + (name === 'bf3arm' ? 'bf3' : name)).classList.add('active');
  window.scrollTo(0, 0);
}
// Highlight active sidebar link on scroll (overview tab only)
const sections = document.querySelectorAll('h2[id]');
const links = document.querySelectorAll('.sidebar a');
window.addEventListener('scroll', () => {
  let cur = '';
  sections.forEach(s => { if (window.scrollY >= s.offsetTop - 80) cur = s.id; });
  links.forEach(l => {
    l.classList.toggle('active', l.getAttribute('href') === '#' + cur);
  });
});
</script>
</body>
</html>
HTMLFOOT

echo "" >&2
echo "✅  Done: ${OUTPUT}" >&2
echo "    Open: http://$(hostname -I | awk '{print $1}'):7777/cluster-dump.html" >&2
echo "" >&2
