#!/usr/bin/env bash
# dashboard.sh — regenerate ALL fleet dashboards + the index landing page.
#   ./dpf/scripts/dashboard.sh          # fleet-dump + per-worker cluster-dumps + index
#   ./dpf/scripts/dashboard.sh --full   # also regenerates explain-stack pages (SSHes to BF3s)
#
# Serve with:  python3 -m http.server 7777 --directory ~/dpf_summary
# Then everything lives at  http://<DPF_VM>:7777/

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.yaml"
SUMMARY="${HOME}/dpf_summary"
mkdir -p "${SUMMARY}"
FULL=false
[[ "${1:-}" == "--full" ]] && FULL=true

WORKERS=$(python3 - "${CONFIG_FILE}" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1])) or {}
for w in c.get("workers") or []:
    print(f'{w.get("name","?")}\t{w.get("server","?")}')
PY
)

echo "── fleet dump ──" >&2
"${SCRIPT_DIR}/fleet_dump.sh" >&2 || echo "(fleet_dump failed)" >&2

# Read all workers into an array FIRST, then iterate. A plain
# `while read … done <<< "$WORKERS"` breaks here because the sub-scripts run
# `ssh` (port_map.sh) which consumes the loop's stdin — the here-string — so
# the loop would exit after the first worker (only s4 ever got generated).
mapfile -t _WORKER_LINES <<< "${WORKERS}"
for _line in "${_WORKER_LINES[@]}"; do
  [[ -z "${_line}" ]] && continue
  IFS=$'\t' read -r NAME SERVER <<< "${_line}"
  echo "── cluster dump: ${SERVER} ──" >&2
  "${SCRIPT_DIR}/dump_cluster.sh" --server "${SERVER}" >/dev/null 2>&1 </dev/null \
    || echo "(dump_cluster ${SERVER} failed)" >&2
  echo "── port map: ${SERVER} ──" >&2
  "${SCRIPT_DIR}/port_map.sh" --server "${SERVER}" >/dev/null 2>&1 </dev/null \
    || echo "(port_map ${SERVER} failed)" >&2
  if [[ "${FULL}" == "true" ]]; then
    echo "── explain stack: ${SERVER} ──" >&2
    "${SCRIPT_DIR}/explain_stack.sh" --server "${SERVER}" >/dev/null 2>&1 </dev/null \
      || echo "(explain_stack ${SERVER} failed — needs BF3 SSH creds in config.local.yaml)" >&2
  fi
done

echo "── index ──" >&2
python3 - "${SUMMARY}" "${CONFIG_FILE}" <<'PY'
import sys, os, yaml, datetime, html
summary, cfg = sys.argv[1], sys.argv[2]
c = yaml.safe_load(open(cfg)) or {}
workers = [(w.get("name","?"), w.get("server","?")) for w in c.get("workers") or []]

def age(fn):
    p = os.path.join(summary, fn)
    if not os.path.exists(p): return None
    dt = datetime.datetime.utcfromtimestamp(os.path.getmtime(p))
    return dt.strftime("%Y-%m-%d %H:%M UTC")

def link(fn, title, desc):
    a = age(fn)
    if a is None:
        return (f'<div class="item off"><div class="t">{html.escape(title)}</div>'
                f'<div class="d">{html.escape(desc)}</div><div class="a">not generated yet</div></div>')
    return (f'<a class="item" href="{fn}"><div class="t">{html.escape(title)}</div>'
            f'<div class="d">{html.escape(desc)}</div><div class="a">generated {a}</div></a>')

items = [link("fleet-dump.html", "Fleet Dump — everything, one page",
              "health cards per worker + operator view + per-worker tabs (nodes, pods, FRR, routes)")]
for name, srv in workers:
    items.append(link(f"cluster-dump-{srv}.html", f"Cluster Deep-Dive — {name} ({srv})",
                      "full k8s state of this DPU cluster (detailed tabs)"))
    items.append(link(f"port-map-{srv}.html", f"Port Map — {name} ({srv})",
                      "interactive ToR→physical→eswitch→OVS→FRR→host diagram, click any port"))
items.append(link("dpf-stack-explained.html", "Stack Explained (educational)",
                  "cluster→node→pod→container→interface map with live values"))

now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")
page = f'''<!doctype html><meta charset="utf-8"><title>DPF Dashboards</title><style>
:root{{--bg:#0b0f17;--panel:#141b27;--bd:#27313f;--fg:#e9eef5;--mut:#93a1b3;--nv:#76b900}}
body{{margin:0;background:var(--bg);color:var(--fg);font:15px -apple-system,Segoe UI,Roboto,sans-serif;
  display:flex;flex-direction:column;align-items:center;padding:48px 24px}}
h1{{font-size:26px;margin:0 0 4px}} .sub{{color:var(--mut);font-size:13px;margin-bottom:28px}}
.grid{{display:flex;flex-direction:column;gap:12px;width:min(680px,100%)}}
.item{{display:block;background:var(--panel);border:1px solid var(--bd);border-left:4px solid var(--nv);
  border-radius:10px;padding:14px 18px;text-decoration:none;color:var(--fg)}}
.item:hover{{background:#1a2230}} .item.off{{border-left-color:var(--bd);opacity:.55}}
.t{{font-weight:700;margin-bottom:3px}} .d{{color:var(--mut);font-size:13px}}
.a{{color:var(--mut);font-size:11px;margin-top:6px}}
.foot{{color:var(--mut);font-size:12px;margin-top:26px}}
code{{background:#070a10;border:1px solid var(--bd);border-radius:4px;padding:1px 6px;font-size:12px}}
</style>
<h1>DPF Fleet Dashboards</h1>
<div class="sub">index generated {now} · refresh everything: <code>./dpf/scripts/dashboard.sh</code> (add <code>--full</code> for stack maps)</div>
<div class="grid">{''.join(items)}</div>
<div class="foot">Live commands on the DPF VM: <code>fleet_status.sh --frr</code> · <code>status_dpf.sh</code> · <code>tunnel_dpf.sh --server sX status</code></div>'''
open(os.path.join(summary, "index.html"), "w").write(page)
print("wrote index.html")
PY
echo "Done → http://$(hostname -I | awk '{print $1}'):7777/" >&2
