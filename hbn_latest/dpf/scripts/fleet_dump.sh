#!/usr/bin/env bash
# fleet_dump.sh — the WHOLE fleet in one HTML: operator view + a tab per worker.
# Workers come from dpf/config.yaml (add worker3 → it appears automatically).
#
# Usage (on the DPF Operator VM):
#   ./dpf/scripts/fleet_dump.sh                 # → ~/dpf_summary/fleet-dump.html
#
# kubectl-only (no BF3 SSH, no credentials needed beyond kubeconfigs).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.yaml"
DPF_NAMESPACE="dpf-operator-system"
OUTPUT="${HOME}/dpf_summary/fleet-dump.html"
mkdir -p "${HOME}/dpf_summary"

if [[ -n "${KUBECONFIG:-}" ]]; then :;
elif [[ -r /etc/rancher/k3s/k3s.yaml ]]; then export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
else export KUBECONFIG="${HOME}/.kube/config"; fi

[[ -f "${CONFIG_FILE}" ]] || { echo "config.yaml not found"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "needs python3-yaml"; exit 1; }

TMP="$(mktemp -d "${HOME}/.fleet-dump.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

kube() { kubectl "$@" 2>/dev/null || echo "(unavailable)"; }

echo "Collecting operator cluster..." >&2
kube get dpu -n "${DPF_NAMESPACE}" -o wide               > "${TMP}/op_dpu.txt"
kube get dpucluster,tcp -n "${DPF_NAMESPACE}"            > "${TMP}/op_cluster.txt"
kube get bfb -n "${DPF_NAMESPACE}"                       > "${TMP}/op_bfb.txt"
kube get dpuservice -n "${DPF_NAMESPACE}"                > "${TMP}/op_dpusvc.txt"
kube get applications -n "${DPF_NAMESPACE}" 2>/dev/null  > "${TMP}/op_apps.txt" || true
kube get pods -n "${DPF_NAMESPACE}" -o wide              > "${TMP}/op_pods.txt"
kube get nodes -o wide                                   > "${TMP}/op_nodes.txt"

# name<TAB>server<TAB>oob<TAB>port
python3 - "${CONFIG_FILE}" <<'PY' > "${TMP}/workers.tsv"
import sys, yaml
c = yaml.safe_load(open(sys.argv[1])) or {}
for w in c.get("workers") or []:
    print(f'{w.get("name","?")}\t{w.get("server","?")}\t{w.get("oob_ip","?")}\t{w.get("apiserver_port",6443)}')
PY

while IFS=$'\t' read -r NAME SERVER OOB PORT; do
  echo "Collecting ${NAME} (${SERVER})..." >&2
  KC="${TMP}/kc-${SERVER}"
  kubectl get secret "${SERVER}-dpu-cluster-admin-kubeconfig" -n "${DPF_NAMESPACE}" \
    -o jsonpath='{.data.admin\.conf}' 2>/dev/null | base64 -d > "${KC}" || true
  W="${TMP}/w_${SERVER}"
  echo "${NAME}|${SERVER}|${OOB}|${PORT}" > "${W}_meta.txt"
  if [[ -s "${KC}" ]]; then
    dk() { kubectl --kubeconfig "${KC}" "$@" 2>/dev/null || echo "(unavailable)"; }
    dk get nodes -o wide                          > "${W}_nodes.txt"
    dk get pods -A -o wide                        > "${W}_pods.txt"
    dk get svc -A                                 > "${W}_svc.txt"
    POD=$(kubectl --kubeconfig "${KC}" get pod -n doca-hbn \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "${POD}" ]]; then
      dk exec -n doca-hbn "${POD}" -- vtysh -c "show interface brief" > "${W}_frr.txt"
      dk exec -n doca-hbn "${POD}" -- vtysh -c "show ip route"        > "${W}_routes.txt"
    else
      echo "(no doca-hbn pod)" > "${W}_frr.txt"; echo "" > "${W}_routes.txt"
    fi
    # health flags for the summary card
    NODE_READY=$(grep -c ' Ready' "${W}_nodes.txt" || true)
    NOT_RUN=$(tail -n +2 "${W}_pods.txt" | grep -vcE 'Running|Completed|unavailable' || true)
    HBN_RUN=$(grep -cE 'doca-hbn.*Running' "${W}_pods.txt" || true)
    FRR_UP=$(grep -cE '_if\s+up' "${W}_frr.txt" || true)
    VF_UP=$(grep -cE 'pf[0-9]vf[0-9]+_if\s+up' "${W}_frr.txt" || true)
    echo "${NODE_READY}|${NOT_RUN}|${HBN_RUN}|${FRR_UP}|${VF_UP}" > "${W}_health.txt"
  else
    echo "(kubeconfig not available — cluster not created yet?)" | tee \
      "${W}_nodes.txt" "${W}_pods.txt" "${W}_svc.txt" "${W}_frr.txt" "${W}_routes.txt" >/dev/null
    echo "0|0|0|0|0" > "${W}_health.txt"
  fi
done < "${TMP}/workers.tsv"

echo "Writing ${OUTPUT}..." >&2
python3 - "${TMP}" "${OUTPUT}" <<'PY'
import html, sys, os, glob, datetime
tmp, out = sys.argv[1], sys.argv[2]
def rd(p):
    try: return open(p).read().rstrip()
    except Exception: return "(missing)"
def esc(s): return html.escape(s)

workers = []
for line in rd(os.path.join(tmp, "workers.tsv")).splitlines():
    name, server, oob, port = line.split("\t")
    w = os.path.join(tmp, f"w_{server}")
    h = rd(w + "_health.txt").split("|")
    workers.append(dict(name=name, server=server, oob=oob, port=port,
        nodes=rd(w+"_nodes.txt"), pods=rd(w+"_pods.txt"), svc=rd(w+"_svc.txt"),
        frr=rd(w+"_frr.txt"), routes=rd(w+"_routes.txt"),
        ready=int(h[0] or 0), notrun=int(h[1] or 0), hbn=int(h[2] or 0),
        frr_up=int(h[3] or 0), vf_up=int(h[4] or 0)))

def card(w):
    ok = w["ready"] > 0 and w["notrun"] == 0 and w["hbn"] > 0
    cls, badge = ("ok", "HEALTHY") if ok else ("bad", "ATTENTION")
    return f'''<div class="card {cls}">
      <div class="card-h">{esc(w["name"])} <span class="srv">({esc(w["server"])})</span>
        <span class="badge {cls}">{badge}</span></div>
      <div class="card-b">OOB {esc(w["oob"])} · apiserver :{esc(w["port"])}<br>
        node Ready: {w["ready"]} · pods not Running: {w["notrun"]} · HBN: {"Running" if w["hbn"] else "DOWN"}<br>
        FRR: {w["frr_up"]} interfaces up · {w["vf_up"]} VF up</div></div>'''

def pre(title, body):
    return f'<h3>{esc(title)}</h3><pre>{esc(body)}</pre>'

tabs_btn = '<button class="tab on" onclick="show(\'op\',this)">Operator (S5)</button>' + "".join(
    f'<button class="tab" onclick="show(\'{w["server"]}\',this)">{esc(w["name"])} ({esc(w["server"])})</button>'
    for w in workers)

op = "".join([
    pre("Fleet nodes (operator k3s)", rd(os.path.join(tmp,"op_nodes.txt"))),
    pre("DPUs", rd(os.path.join(tmp,"op_dpu.txt"))),
    pre("DPUClusters / TenantControlPlanes", rd(os.path.join(tmp,"op_cluster.txt"))),
    pre("BFB", rd(os.path.join(tmp,"op_bfb.txt"))),
    pre("DPUServices", rd(os.path.join(tmp,"op_dpusvc.txt"))),
    pre("ArgoCD applications", rd(os.path.join(tmp,"op_apps.txt"))),
    pre("Pods (dpf-operator-system)", rd(os.path.join(tmp,"op_pods.txt"))),
])

panes = f'<div id="pane-op" class="pane on">{op}</div>'
for w in workers:
    panes += f'''<div id="pane-{w["server"]}" class="pane">{
        pre("Node", w["nodes"]) + pre("Pods (all namespaces)", w["pods"]) +
        pre("FRR interfaces", w["frr"]) + pre("FRR routes", w["routes"]) +
        pre("Services", w["svc"])}</div>'''

cards = "".join(card(w) for w in workers)
now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")

page = f'''<!doctype html><meta charset="utf-8"><title>DPF Fleet Dump</title><style>
:root{{--bg:#0b0f17;--panel:#141b27;--bd:#27313f;--fg:#e9eef5;--mut:#93a1b3;--nv:#76b900;--red:#e5534b}}
body{{margin:0;background:var(--bg);color:var(--fg);font:14px -apple-system,Segoe UI,Roboto,sans-serif;padding:24px}}
h1{{font-size:22px;margin:0 0 4px}} .sub{{color:var(--mut);font-size:12px;margin-bottom:18px}}
.cards{{display:flex;gap:14px;flex-wrap:wrap;margin-bottom:18px}}
.card{{background:var(--panel);border:1px solid var(--bd);border-radius:10px;padding:12px 16px;min-width:280px}}
.card.ok{{border-left:4px solid var(--nv)}} .card.bad{{border-left:4px solid var(--red)}}
.card-h{{font-weight:700;margin-bottom:6px}} .srv{{color:var(--mut);font-weight:400}}
.card-b{{color:var(--mut);font-size:12.5px;line-height:1.6}}
.badge{{float:right;font-size:10px;font-weight:800;border-radius:10px;padding:2px 8px}}
.badge.ok{{background:#12351f;color:var(--nv)}} .badge.bad{{background:#3d1512;color:var(--red)}}
.tabs{{display:flex;gap:6px;margin-bottom:0;flex-wrap:wrap}}
.tab{{background:var(--panel);border:1px solid var(--bd);border-bottom:none;color:var(--mut);
  padding:8px 16px;border-radius:8px 8px 0 0;cursor:pointer;font-weight:600}}
.tab.on{{color:var(--fg);background:#1a2230}}
.pane{{display:none;background:#0d1420;border:1px solid var(--bd);border-radius:0 8px 8px 8px;padding:6px 18px 18px}}
.pane.on{{display:block}}
h3{{font-size:13px;letter-spacing:.05em;text-transform:uppercase;color:var(--nv);margin:18px 0 6px}}
pre{{background:#070a10;border:1px solid var(--bd);border-radius:6px;padding:10px 12px;overflow-x:auto;
  font:12px ui-monospace,Consolas,monospace;line-height:1.5;color:#cdd9e5;margin:0}}
</style>
<h1>DPF Fleet Dump</h1><div class="sub">generated {now} · one page, whole fleet · regenerate: ./dpf/scripts/fleet_dump.sh</div>
<div class="cards">{cards}</div>
<div class="tabs">{tabs_btn}</div>
{panes}
<script>
function show(id, btn) {{
  document.querySelectorAll('.pane').forEach(p => p.classList.remove('on'));
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('on'));
  document.getElementById('pane-' + id).classList.add('on');
  btn.classList.add('on');
}}
</script>'''
open(out, "w").write(page)
print(f"wrote {out}")
PY
echo "Done → ${OUTPUT}" >&2
