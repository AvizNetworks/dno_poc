#!/usr/bin/env bash
# explain_stack.sh — Generate an educational HTML that maps the DPF + HBN stack:
#   DPU cluster → node (BF3) → pod → container → Linux namespace → interface → data plane
#
# It both EXPLAINS each concept and SHOWS the live values on the target server, so the
# team can see how Kubernetes, containers, namespaces, SubFunctions and OVS tie together.
#
# Run from the DPF Operator VM (S5). Read-only — only `kubectl get` + read-only BF3 cmds.
#
# Usage:
#   ./explain_stack.sh                          # defaults: s4
#   ./explain_stack.sh --server s4 --bf3-ip 10.20.13.249 --bf3-pass 'Aviz@AIF12345'
#
# Output: ~/dpf_summary/dpf-stack-explained.html
set -uo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
SERVER_NAME="s4"
BF3_OOB_IP="10.20.13.249"
BF3_OOB_PASS="Aviz@AIF12345"
DPF_NAMESPACE="dpf-operator-system"
HBN_NAMESPACE="doca-hbn"
HOST_KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
DPU_KUBECONFIG="${HOME}/dpu-tc-kubeconfig"
OUTPUT="${HOME}/dpf_summary/dpf-stack-explained.html"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)   SERVER_NAME="$2"; shift 2 ;;
    --bf3-ip)   BF3_OOB_IP="$2"; shift 2 ;;
    --bf3-pass) BF3_OOB_PASS="$2"; shift 2 ;;
    --out)      OUTPUT="$2"; shift 2 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done
mkdir -p "$(dirname "$OUTPUT")"

# ─── Helpers ─────────────────────────────────────────────────────────────────
hk()  { kubectl --kubeconfig "$HOST_KUBECONFIG" "$@" 2>/dev/null || echo "(unavailable)"; }
dk()  { kubectl --kubeconfig "$DPU_KUBECONFIG"  "$@" 2>/dev/null || echo "(unavailable)"; }
# HTML-escape stdin
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

echo "Collecting data for ${SERVER_NAME}…" >&2

# Refresh DPU cluster kubeconfig
hk get secret "${SERVER_NAME}-dpu-cluster-admin-kubeconfig" -n "${DPF_NAMESPACE}" \
  -o jsonpath='{.data.admin\.conf}' 2>/dev/null | base64 -d > "${DPU_KUBECONFIG}" 2>/dev/null || true

# ─── Collect: control-plane / cluster layer ─────────────────────────────────
DPUCLUSTER=$(hk get dpucluster "${SERVER_NAME}-dpu-cluster" -n "${DPF_NAMESPACE}" -o wide)
TCP=$(hk get tenantcontrolplane "${SERVER_NAME}-dpu-cluster" -n "${DPF_NAMESPACE}")
DPU_CR=$(hk get dpu "${SERVER_NAME}-dpu" -n "${DPF_NAMESPACE}" -o wide)

# ─── Collect: node + pods (DPU cluster) ─────────────────────────────────────
NODE=$(dk get node "${SERVER_NAME}-dpu" -o wide)
NODE_DETAIL=$(dk get node "${SERVER_NAME}-dpu" -o jsonpath='OS={.status.nodeInfo.osImage}{"\n"}Kernel={.status.nodeInfo.kernelVersion}{"\n"}Runtime={.status.nodeInfo.containerRuntimeVersion}{"\n"}Kubelet={.status.nodeInfo.kubeletVersion}{"\n"}Arch={.status.nodeInfo.architecture}{"\n"}')
PODS_ON_NODE=$(dk get pods -A -o wide --field-selector "spec.nodeName=${SERVER_NAME}-dpu")
HBN_POD=$(dk get pods -n "${HBN_NAMESPACE}" -o name | head -1 | sed 's|pod/||')
HBN_CONTAINERS=$(dk get pod -n "${HBN_NAMESPACE}" "${HBN_POD}" -o jsonpath='init: {range .spec.initContainers[*]}{.name} {end}| main: {range .spec.containers[*]}{.name} {end}{"\n"}')

# ─── Collect: BF3 deep dive (CRI + namespaces + netns + OVS) ─────────────────
# Ship a collector to the BF3 and run it (avoids SSH quoting hell), capture labeled output.
COLLECTOR=$(mktemp)
cat > "$COLLECTOR" <<'RSCRIPT'
#!/bin/bash
echo "@@@KUBELET@@@"; systemctl is-active kubelet 2>/dev/null
echo "@@@CRICTL_PODS@@@"; crictl pods 2>/dev/null | head -15
echo "@@@CRICTL_PS@@@"; crictl ps 2>/dev/null | head -15
C=$(crictl ps --name doca-hbn -q 2>/dev/null | head -1)
PID=$(crictl inspect "$C" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["info"]["pid"])' 2>/dev/null)
echo "@@@CONTAINER@@@"; echo "doca-hbn container id: $C"; echo "host PID: $PID"
echo "@@@NAMESPACES@@@"
for ns in net pid mnt uts ipc cgroup; do
  cid=$(readlink /proc/$PID/ns/$ns 2>/dev/null); hid=$(readlink /proc/1/ns/$ns 2>/dev/null)
  st=$([ "$cid" = "$hid" ] && echo "shared with host" || echo "ISOLATED (own)")
  printf "%-7s %-20s %s\n" "$ns" "$cid" "$st"
done
echo "@@@PODNETNS@@@"; nsenter -t "$PID" -n ip -br link 2>/dev/null | grep -E '_if|eth0|^lo'
echo "@@@HOSTREPS@@@"; ip -br link 2>/dev/null | grep _if_r
echo "@@@OVS@@@"; ovs-vsctl list-ports br-hbn 2>/dev/null
echo "@@@SFMAP@@@"; mlnx-sf -a show 2>/dev/null | grep -E 'sfnum|Representor netdev|netdev:' | head -16
echo "@@@END@@@"
RSCRIPT

BF3_RAW="(BF3 unreachable)"
if command -v sshpass >/dev/null 2>&1; then
  sshpass -p "${BF3_OOB_PASS}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 "$COLLECTOR" "ubuntu@${BF3_OOB_IP}:/tmp/_explain_collector.sh" >/dev/null 2>&1 \
  && BF3_RAW=$(sshpass -p "${BF3_OOB_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=12 "ubuntu@${BF3_OOB_IP}" "echo '${BF3_OOB_PASS}' | sudo -S bash /tmp/_explain_collector.sh" 2>/dev/null)
fi
rm -f "$COLLECTOR"

# Extract a labeled section from the collector output
sec() { awk "/@@@$1@@@/{f=1;next} /@@@/{f=0} f" <<<"$BF3_RAW"; }
KUBELET=$(sec KUBELET);   CRI_PODS=$(sec CRICTL_PODS); CRI_PS=$(sec CRICTL_PS)
CONTAINER=$(sec CONTAINER); NAMESPACES=$(sec NAMESPACES); PODNETNS=$(sec PODNETNS)
HOSTREPS=$(sec HOSTREPS);  OVS=$(sec OVS);  SFMAP=$(sec SFMAP)
[[ -z "${KUBELET}" ]] && KUBELET="(BF3 not reachable — run from the DPF VM with BF3 SSH access)"

NOW="$(date)"

echo "Writing ${OUTPUT}…" >&2

# ─── Emit HTML ───────────────────────────────────────────────────────────────
cat > "${OUTPUT}" <<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DPF + HBN Stack — Explained (${SERVER_NAME})</title>
<style>
  :root{--bg:#0d1117;--card:#161b22;--bd:#30363d;--fg:#e6edf3;--mut:#8b949e;
        --cluster:#a371f7;--node:#3fb950;--pod:#58a6ff;--cont:#f0883e;--ns:#db61a2;--if:#39c5cf;--dp:#e3b341;}
  *{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--fg);
    font:15px/1.55 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif}
  .wrap{max-width:1100px;margin:0 auto;padding:24px}
  h1{font-size:26px;margin:0 0 4px} h2{font-size:20px;margin:34px 0 10px;border-bottom:1px solid var(--bd);padding-bottom:6px}
  .sub{color:var(--mut);margin-bottom:18px}
  .chip{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;color:#0d1117}
  .card{background:var(--card);border:1px solid var(--bd);border-radius:10px;padding:14px 16px;margin:12px 0}
  .grid2{display:grid;grid-template-columns:1fr 1fr;gap:12px} @media(max-width:760px){.grid2{grid-template-columns:1fr}}
  pre{background:#010409;border:1px solid var(--bd);border-radius:8px;padding:10px 12px;overflow-x:auto;
      font:12.5px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;color:#c9d1d9;white-space:pre}
  .what{color:var(--mut);font-size:14px;margin:2px 0 10px}
  .map{background:#010409;border:1px solid var(--bd);border-radius:10px;padding:16px}
  .box{border:2px solid;border-radius:8px;padding:8px 10px;margin:8px 0}
  .box .lbl{font-weight:700;font-size:13px;letter-spacing:.3px}
  .box .meta{color:var(--mut);font-size:12px;font-family:ui-monospace,monospace}
  .inset{margin-left:18px}
  a.k{color:var(--if)} .legend span{margin-right:14px;font-size:12px;color:var(--mut)}
  .pill{font-family:ui-monospace,monospace;font-size:12px;background:#21262d;border:1px solid var(--bd);
        border-radius:6px;padding:1px 6px;margin:2px;display:inline-block}
  table{border-collapse:collapse;width:100%;font-size:13px} td,th{border:1px solid var(--bd);padding:6px 8px;text-align:left;vertical-align:top}
  th{background:#21262d}
</style></head><body><div class="wrap">

<h1>DPF + HBN Stack — Explained</h1>
<div class="sub">How a Kubernetes cluster, a BlueField-3 node, a pod, its containers, Linux namespaces, SubFunctions and OVS all tie together · server <b>${SERVER_NAME}</b> · ${NOW}</div>

<div class="card">
<b>Read this top-to-bottom.</b> Each layer below is a box <i>inside</i> the one above it. Left = the concept (what it is &amp; why); right/below = the <b>live values on ${SERVER_NAME}</b> proving it. Colors are consistent throughout.
<div class="legend" style="margin-top:8px">
<span><span class="chip" style="background:var(--cluster)">Cluster</span></span>
<span><span class="chip" style="background:var(--node)">Node</span></span>
<span><span class="chip" style="background:var(--pod)">Pod</span></span>
<span><span class="chip" style="background:var(--cont)">Container</span></span>
<span><span class="chip" style="background:var(--ns)">Namespace</span></span>
<span><span class="chip" style="background:var(--if)">Interface</span></span>
<span><span class="chip" style="background:var(--dp)">Data plane</span></span>
</div></div>

<h2>The big picture — nested layers</h2>
<div class="map">
  <div class="box" style="border-color:var(--cluster)">
    <span class="lbl" style="color:var(--cluster)">DPU CLUSTER</span> — a virtual Kubernetes control plane (Kamaji) living as pods on the DPF Operator VM
    <div class="meta">${SERVER_NAME}-dpu-cluster · API: https://${SERVER_NAME}-dpu-cluster.${DPF_NAMESPACE}.svc:6443</div>
    <div class="box inset" style="border-color:var(--node)">
      <span class="lbl" style="color:var(--node)">NODE</span> — the BlueField-3 Arm, a Kubernetes worker that joined the cluster
      <div class="meta">${SERVER_NAME}-dpu · ${BF3_OOB_IP} · kubelet + containerd</div>
      <div class="box inset" style="border-color:var(--pod)">
        <span class="lbl" style="color:var(--pod)">POD</span> — doca-hbn (a "sandbox": shared net/ipc/uts for its containers)
        <div class="meta">${HBN_POD}</div>
        <div class="box inset" style="border-color:var(--cont)">
          <span class="lbl" style="color:var(--cont)">CONTAINERS</span> — <span class="pill">init-sfs</span> (runs once, moves SFs in) + <span class="pill">doca-hbn</span> (FRR/zebra/NVUE)
          <div class="box inset" style="border-color:var(--ns)">
            <span class="lbl" style="color:var(--ns)">LINUX NAMESPACES</span> — the kernel isolation that <i>is</i> the container (own net/pid/mnt/uts/ipc)
            <div class="box inset" style="border-color:var(--if)">
              <span class="lbl" style="color:var(--if)">INTERFACES (in the pod netns)</span> — SubFunction <i>function</i> netdevs FRR owns
              <div class="meta">p0_if · p1_if · pf0hpf_if · pf1hpf_if · pf0vf0-3_if · pf1vf0-3_if &nbsp;(+ eth0 = flannel)</div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
  <div class="box" style="border-color:var(--dp)">
    <span class="lbl" style="color:var(--dp)">DATA PLANE (BF3 host netns, not in the pod)</span> — each SubFunction's <i>representor</i> sits on OVS <b>br-hbn</b>; the BF3 eswitch hardware-offloads packets between ToR uplinks, the x86 host PFs/VFs, and these representors. FRR (control plane) decides routes; the eswitch (data plane) moves the packets at line rate.
  </div>
</div>

<h2><span class="chip" style="background:var(--cluster)">1 · Cluster</span> &nbsp;the virtual control plane</h2>
<div class="what">A Kubernetes <b>cluster</b> is an API server + scheduler + etcd that schedule and track workloads. Here it's a <b>Kamaji TenantControlPlane</b> — a lightweight per-DPU control plane that runs as ordinary pods on the DPF Operator VM, so the BF3 doesn't run its own control plane. The DPU CR is DPF's record of the physical BF3 being provisioned into this cluster.</div>
<div class="grid2">
<div class="card"><b>DPUCluster</b> (DPF's intent)<pre>$(echo "$DPUCLUSTER" | esc)</pre></div>
<div class="card"><b>TenantControlPlane</b> (the actual k8s API)<pre>$(echo "$TCP" | esc)</pre></div>
</div>
<div class="card"><b>DPU</b> (the provisioned BlueField-3)<pre>$(echo "$DPU_CR" | esc)</pre></div>

<h2><span class="chip" style="background:var(--node)">2 · Node</span> &nbsp;the BlueField-3 as a worker</h2>
<div class="what">A <b>node</b> is a machine running <b>kubelet</b> that the cluster schedules pods onto. The BF3 Arm joined as a worker (kubeadm-join over the tunnel). Note the <b>arm64</b> arch and the DOCA OS — this node <i>is</i> the DPU.</div>
<div class="grid2">
<div class="card"><b>Node</b><pre>$(echo "$NODE" | esc)</pre></div>
<div class="card"><b>Node info</b><pre>$(echo "$NODE_DETAIL" | esc)
kubelet (on BF3): $(echo "$KUBELET" | esc)</pre></div>
</div>

<h2><span class="chip" style="background:var(--pod)">3 · Pod</span> &nbsp;the unit Kubernetes schedules</h2>
<div class="what">A <b>pod</b> is one-or-more containers that share a network namespace (one IP), IPC and UTS — created as a "sandbox" first, then the containers join it. These are the pods k8s placed on the BF3:</div>
<div class="card"><pre>$(echo "$PODS_ON_NODE" | esc)</pre></div>
<div class="card">The HBN pod's containers:<pre>$(echo "$HBN_CONTAINERS" | esc)</pre></div>

<h2><span class="chip" style="background:var(--cont)">4 · Container</span> &nbsp;a process the runtime isolates</h2>
<div class="what">On the node, <b>containerd</b> (the CRI runtime) actually runs the containers. <b>crictl</b> is the CLI to inspect them. A pod shows up as a <b>sandbox</b>; each container is a process inside it.</div>
<div class="grid2">
<div class="card"><b>crictl pods</b> (sandboxes)<pre>$(echo "$CRI_PODS" | esc)</pre></div>
<div class="card"><b>crictl ps</b> (containers)<pre>$(echo "$CRI_PS" | esc)</pre></div>
</div>
<div class="card"><pre>$(echo "$CONTAINER" | esc)</pre></div>

<h2><span class="chip" style="background:var(--ns)">5 · Namespace</span> &nbsp;what a container actually is</h2>
<div class="what">A container is just a Linux <b>process placed in its own namespaces</b> — kernel-level isolation of what it can see. Same kernel as the host (no VM). <b>ISOLATED</b> = the container has its own; <b>shared</b> = it sees the host's. <code>cgroups</code> (separate) cap how much CPU/mem it can use.</div>
<div class="card"><pre>$(echo "$NAMESPACES" | esc)</pre></div>

<h2><span class="chip" style="background:var(--if)">6 · Interfaces</span> &nbsp;and the SubFunction "move"</h2>
<div class="what">This is the DPU trick. Each <b>SubFunction (SF)</b> has two halves: a <b>function</b> netdev (<code>p0_if</code>) and a <b>representor</b> (<code>p0_if_r</code>). At startup <code>init-sfs</code> <b>moves the function netdevs into the pod's network namespace</b> so FRR owns them, while the representors stay on the BF3 host plugged into OVS. That's why the function netdevs appear inside the pod (left) but show empty on the host SF driver (right).</div>
<div class="grid2">
<div class="card"><b>Inside the pod netns</b> — FRR's interfaces (function netdevs)<pre>$(echo "$PODNETNS" | esc)</pre></div>
<div class="card"><b>On the BF3 host</b> — representors (function side moved away)<pre>$(echo "$HOSTREPS" | esc)

$(echo "$SFMAP" | esc)</pre></div>
</div>

<h2><span class="chip" style="background:var(--dp)">7 · Data plane</span> &nbsp;OVS br-hbn + eswitch offload</h2>
<div class="what">The representors are ports on OVS <b>br-hbn</b> on the BF3 host. The BF3 eswitch (switchdev mode) <b>hardware-offloads</b> flows between the physical uplinks (<code>p0/p1</code> → ToR), the x86 host PFs/VFs, and the representors — so steady-state traffic never touches the Arm CPU. FRR only programs the control plane; the silicon moves the packets.</div>
<div class="card"><b>br-hbn ports</b><pre>$(echo "$OVS" | esc)</pre></div>
<div class="card"><b>End-to-end path for one VF</b>
<pre>x86 host vfN  ⇄  [BF3 eswitch / switchdev]  ⇄  pfXvfN_if_r (representor, OVS br-hbn)
                                              │  hardware offload
                                       pfXvfN_if (function netdev, in the pod)  ⇄  FRR</pre></div>

<h2>Command cheat-sheet</h2>
<table>
<tr><th>Layer</th><th>Command (run where)</th></tr>
<tr><td><span class="chip" style="background:var(--cluster)">Cluster</span></td><td><code>kubectl --kubeconfig ~/dpu-tc-kubeconfig get dpucluster,tenantcontrolplane,nodes -A</code> &nbsp;(DPF VM)</td></tr>
<tr><td><span class="chip" style="background:var(--node)">Node</span></td><td><code>D="kubectl --kubeconfig ~/dpu-tc-kubeconfig"; \$D get pods -A -o wide --field-selector spec.nodeName=${SERVER_NAME}-dpu</code></td></tr>
<tr><td><span class="chip" style="background:var(--cont)">Container</span></td><td><code>sudo crictl pods; sudo crictl ps; sudo crictl inspect &lt;id&gt;</code> &nbsp;(on BF3)</td></tr>
<tr><td><span class="chip" style="background:var(--ns)">Namespace</span></td><td><code>PID=\$(sudo crictl inspect \$(sudo crictl ps --name doca-hbn -q) | python3 -c 'import sys,json;print(json.load(sys.stdin)["info"]["pid"])'); sudo lsns -p \$PID</code> &nbsp;(on BF3)</td></tr>
<tr><td><span class="chip" style="background:var(--if)">Interface</span></td><td><code>sudo nsenter -t \$PID -n ip -br link</code> &nbsp;· &nbsp;<code>\$D exec -it -n doca-hbn ${HBN_POD} -- vtysh -c "show interface brief"</code></td></tr>
<tr><td><span class="chip" style="background:var(--dp)">Data plane</span></td><td><code>sudo ovs-vsctl show; sudo ovs-appctl dpctl/dump-flows type=offloaded</code> &nbsp;(on BF3)</td></tr>
</table>

<div class="sub" style="margin-top:24px">Generated by <code>dpf/scripts/explain_stack.sh</code> · re-run any time for a fresh snapshot.</div>
</div></body></html>
HTML

echo "Done: ${OUTPUT}" >&2
echo "${OUTPUT}"
