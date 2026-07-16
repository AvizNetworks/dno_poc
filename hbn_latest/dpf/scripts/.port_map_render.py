#!/usr/bin/env python3
# Renders the BF3 HBN port-mapping diagram from live facts. Called by port_map.sh.
import sys, html, json, datetime

server, wname, oob, bmc, xip, frr_f, host_f, out = sys.argv[1:9]

# ── parse live FRR interface brief → {ifname: (status, addr)} ────────────────────
frr = {}
for ln in open(frr_f):
    p = ln.split()
    if len(p) >= 2 and (p[0].endswith("_if") or p[0].startswith("vlan")):
        frr[p[0]] = (p[1], p[3] if len(p) >= 4 else "")

# ── parse host facts ────────────────────────────────────────────────────────────
pf0nic, pf1nic, numvfs, vfs = "enp?s0f0np0", "enp?s0f1np1", "", []
for ln in open(host_f):
    p = ln.split()
    if not p: continue
    if p[0] == "PF0" and len(p) >= 2: pf0nic = p[1]; numvfs = p[2] if len(p) > 2 else ""
    elif p[0] == "PF1" and len(p) >= 2: pf1nic = p[1]
    elif p[0] == "VFS": vfs = p[1:]
has_vfs = len(vfs) > 0

# ── fixed structure (our DPUFlavor sfnum mapping) ───────────────────────────────
# (name, sfnum, host_vf_name)
UPLINKS = [("p0", 2, None), ("p1", 3, None)]
HOSTPF  = [("pf0hpf", 1514, None), ("pf1hpf", 1515, None)]
VFS     = [(f"pf0vf{i}", 4+i, f"vf{i}") for i in range(4)] + \
          [(f"pf1vf{i}", 8+i, f"vf{4+i}") for i in range(4)]

def st(ifn):  # live status/addr for an *_if
    s, a = frr.get(ifn, ("?", ""))
    return s, a

def dot(cls): return f'<div class="port-dot {cls}"></div>'
def esc(x): return html.escape(str(x))

# ── build the three BF3 columns + host column as port lists ─────────────────────
def port(pid, name, desc):
    return (f'<div class="port" data-id="{pid}" onclick="showInfo(this)">{dot(_dotmap[pid[:3]] if False else "")}'
            f'<div><div class="port-name">{esc(name)}</div><div class="port-desc">{esc(desc)}</div></div></div>')

def p(pid, name, desc, dcls):
    return (f'<div class="port" data-id="{esc(pid)}" onclick="showInfo(this)">{dot(dcls)}'
            f'<div><div class="port-name">{esc(name)}</div><div class="port-desc">{esc(desc)}</div></div></div>')

# eswitch column
esw = [p("eswitch", "switchdev", "TC flower rules", "")]
esw += [p(f"esw-{n}", f"{n} rep", f"→ {n}_if_r", "dot-rep") for n,_,_ in UPLINKS]
esw += ['<div class="section-div"></div>']
esw += [p(f"esw-{n}", f"{n} rep", f"→ {n}_if_r", "dot-sf") for n,_,_ in HOSTPF]
esw += ['<div class="section-div"></div>']
esw += [p("esw-vf", "pf0vf0..3 / pf1vf0..3", "→ pfNvfM_if_r", "dot-vf")]

# OVS br-hbn column
ovs = [p(f"ovs-{n}", n, "physical uplink (DPDK)", "dot-uplink") for n,_,_ in UPLINKS]
ovs += ['<div class="section-div"></div>']
ovs += [p(f"ovs-{n}r", f"{n}_if_r", f"{n} SF representor", "dot-rep") for n,_,_ in UPLINKS]
ovs += ['<div class="section-div"></div>']
for n,sf,_ in HOSTPF:
    ovs.append(p(f"ovs-{n}", n, "host PF proxy", "dot-sf"))
    ovs.append(p(f"ovs-{n}r", f"{n}_if_r", f"SF rep · sfnum {sf}", "dot-sf"))
ovs += ['<div class="section-div"></div>']
ovs += [p(f"ovs-{n}r", f"{n}_if_r", f"VF rep · sfnum {sf}", "dot-vf") for n,sf,_ in VFS]
ovs += ['<div class="section-div"></div>']
ovs += [p("ovs-aviz", "aviz0", "mirror → ASN DPI (planned)", "")]

# FRR container column (live status/addr)
def frow(n, sf, kind):
    s, a = st(f"{n}_if")
    tag = f"sfnum {sf}" + (f" · {a}" if a else "") + (f" · {s}" if s not in ("up","?") else "")
    return p(f"frr-{n}", f"{n}_if", tag, kind)
frr_col  = [frow(n,sf,"dot-frr") for n,sf,_ in UPLINKS]
frr_col += ['<div class="section-div"></div>']
frr_col += [frow(n,sf,"dot-frr") for n,sf,_ in HOSTPF]
frr_col += ['<div class="section-div"></div>']
frr_col += [frow(n,sf,"dot-vf") for n,sf,_ in VFS]

# Host column
if has_vfs:
    host_col  = [p("host-pf0", pf0nic, "BF3 PF0", "dot-host"),
                 p("host-pf1", pf1nic, "BF3 PF1", "dot-host"),
                 '<div class="section-div"></div>']
    host_col += [p(f"host-{hv}", hv, f"SR-IOV VF ↔ {n}_if", "dot-vf") for n,_,hv in VFS]
else:
    host_col  = [p("host-pf0", pf0nic, "BF3 PF0", "dot-host"),
                 p("host-pf1", pf1nic, "BF3 PF1", "dot-host"),
                 '<div class="section-div"></div>',
                 '<div class="hw-box" style="border-color:#c05621;color:#f6ad55">'
                 '<strong>⚠ No host VFs</strong>This x86 host is a VMware VM — PCIe '
                 'passthrough does not expose SR-IOV, so vf0..vf7 cannot exist here. '
                 'The BF3 still has all 8 VF SFs internally.</div>']

# ── portInfo tooltips (live where known) ────────────────────────────────────────
info = {}
info["eswitch"] = {"title":"eswitch (hardware)","rows":[["Mode","switchdev"],
    ["TC rules","programmed by nl2doca from FRR routes"],["Offload","matched flows bypass the ARM"]],
    "flow":"first packet → ARM (FRR) → nl2doca installs eswitch rule → later packets forwarded in hardware"}
info["ovs-aviz"] = {"title":"aviz0 — ASN mirror (planned)","rows":[["Type","OVS internal / AF_PACKET"],
    ["Purpose","copy of host↔FRR traffic for DPI"],["Consumer","Aviz Service Node (ASN)"]],
    "flow":"br-hbn ports → OVS mirror → aviz0 → ASN deep packet inspection"}
for n,sf,hv in UPLINKS+HOSTPF+VFS:
    s,a = st(f"{n}_if")
    rows=[["sfnum",sf],["FRR iface",f"{n}_if"],["OVS rep",f"{n}_if_r"],["status",s]]
    if a: rows.append(["address",a])
    if hv: rows.append(["host VF",hv])
    info[f"frr-{n}"]={"title":f"FRR: {n}_if","rows":rows,
        "flow":(f"host {hv} → PCIe → eswitch → {n}_if_r (OVS) → {n}_if (FRR routes)" if hv
                else (f"host {pf0nic if n=='pf0hpf' else pf1nic} → PCIe → {n}_if_r (OVS) → {n}_if (FRR)"
                      if n.endswith('hpf') else f"ToR → {n} physical → eswitch → {n}_if_r (OVS) → {n}_if (FRR)"))}
    info[f"ovs-{n}r"]={"title":f"OVS: {n}_if_r","rows":[["Type","SF representor (br-hbn port)"],
        ["sfnum",sf],["pairs with",f"{n}_if in the HBN pod"],
        ["pair flow",f"priority=500 in_port={n} ↔ {n}_if_r"]],
        "flow":f"eswitch port {n} ↔ [pair flow] ↔ {n}_if_r ↔ SF ↔ {n}_if (FRR)"}

data = {
  "server": server.upper(), "wname": wname, "oob": oob, "bmc": bmc, "xip": xip,
  "pf0nic": pf0nic, "pf1nic": pf1nic, "has_vfs": has_vfs,
  "esw":"".join(esw), "ovs":"".join(ovs), "frr":"".join(frr_col), "host":"".join(host_col),
  "info": json.dumps(info),
  "ts": datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC"),
}

TPL = r'''<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>BF3 HBN Port Mapping — ⟦server⟧</title><style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#0f1117;color:#e2e8f0;font-size:13px}
h1{text-align:center;padding:20px;font-size:20px;color:#63b3ed;letter-spacing:1px}
h1 span{color:#a0aec0;font-size:13px;font-weight:normal;display:block;margin-top:4px}
.diagram{display:flex;gap:0;align-items:stretch;padding:10px 20px 20px}
.col{display:flex;flex-direction:column;gap:8px;justify-content:center}
.col-tor{width:120px}.col-phys{width:110px}.col-eswitch{width:180px}.col-ovs{width:220px}.col-frr{width:230px}.col-host{width:190px}
.col-arrow{width:30px;display:flex;align-items:center;justify-content:center}
.arr{font-size:18px;color:#63b3ed}.arr.pcie{color:#9f7aea}
.box{border-radius:8px;padding:10px 12px;border:1px solid}
.box-label{font-size:10px;font-weight:700;letter-spacing:1px;text-transform:uppercase;margin-bottom:6px;opacity:.7}
.theme-tor{background:#1a2744;border-color:#2b4299}.theme-phys{background:#1a2a1a;border-color:#2d5a2d}
.theme-eswitch{background:#1a1a2e;border-color:#553c9a}.theme-ovs{background:#1a2520;border-color:#276749}
.theme-frr{background:#1a2530;border-color:#2c7a7b}.theme-host{background:#1a1a2e;border-color:#553c9a}
.port-list{display:flex;flex-direction:column;gap:4px}
.port{display:flex;align-items:center;gap:6px;padding:4px 8px;border-radius:4px;cursor:pointer;border:1px solid transparent}
.port:hover{border-color:#63b3ed44;background:#ffffff0a}.port.highlighted{background:#2a4a6a;border-color:#63b3ed}
.port-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.port-name{font-family:Consolas,monospace;font-size:12px;font-weight:600}
.port-desc{font-size:10px;color:#718096;margin-top:1px}
.dot-tor{background:#4299e1}.dot-uplink{background:#48bb78}.dot-rep{background:#9f7aea}
.dot-sf{background:#f6ad55}.dot-frr{background:#63b3ed}.dot-vf{background:#fc8181}.dot-host{background:#b794f4}
.hw-box{background:#1a1005;border:1px dashed #744210;border-radius:6px;padding:8px 10px;font-size:11px;color:#d69e2e;margin-top:6px}
.hw-box strong{display:block;margin-bottom:3px;color:#f6ad55}
.section-div{width:100%;border-top:1px dashed #2d3748;margin:4px 0}
.bf3-wrapper{border:1px solid #4a5568;border-radius:12px;padding:12px;background:#111827;display:flex;flex:1}
.bf3-label{writing-mode:vertical-rl;font-size:11px;font-weight:700;color:#718096;letter-spacing:2px;text-transform:uppercase;padding:0 4px;margin-right:8px}
.legend{display:flex;flex-wrap:wrap;gap:12px;padding:10px 20px;border-top:1px solid #2d3748}
.legend-item{display:flex;align-items:center;gap:5px;font-size:11px;color:#a0aec0}
.info-panel{position:fixed;right:20px;top:80px;width:290px;background:#1a202c;border:1px solid #4a5568;border-radius:8px;padding:14px;display:none;font-size:12px;line-height:1.7}
.info-panel h3{color:#63b3ed;margin-bottom:8px;font-size:13px}
.info-panel .close{float:right;cursor:pointer;color:#718096;font-size:16px}
.info-row{display:flex;gap:6px;margin-bottom:3px}.info-key{color:#718096;min-width:80px}.info-val{color:#e2e8f0;font-family:monospace}
.flow-path{margin-top:10px;padding:8px;background:#0f1117;border-radius:4px;font-family:monospace;font-size:11px;color:#68d391;line-height:1.8;white-space:pre-line}
</style></head><body>
<h1>BF3 HBN — Port Mapping &amp; Data Plane · ⟦server⟧
  <span>DPF-managed (⟦wname⟧) · BF3 OOB ⟦oob⟧ · BMC ⟦bmc⟧ · x86 host ⟦xip⟧ · generated ⟦ts⟧</span></h1>
<div class="diagram">
  <div class="col col-tor"><div class="box theme-tor"><div class="box-label">ToR Switch</div><div class="port-list">
    <div class="port" data-id="tor" onclick="showInfo(this)"><div class="port-dot dot-tor"></div><div><div class="port-name">uplinks</div><div class="port-desc">→ BF3 p0 / p1</div></div></div>
  </div></div></div>
  <div class="col-arrow"><span class="arr">▶</span></div>
  <div class="col col-phys"><div class="box theme-phys"><div class="box-label">Physical</div><div class="port-list">
    <div class="port" data-id="frr-p0" onclick="showInfo(this)"><div class="port-dot dot-uplink"></div><div><div class="port-name">p0</div><div class="port-desc">SFP 0</div></div></div>
    <div class="port" data-id="frr-p1" onclick="showInfo(this)"><div class="port-dot dot-uplink"></div><div><div class="port-name">p1</div><div class="port-desc">SFP 1</div></div></div>
  </div></div></div>
  <div class="bf3-wrapper"><div class="bf3-label">BF3 DPU ARM</div>
    <div class="col-arrow"><span class="arr">▶</span></div>
    <div class="col col-eswitch"><div class="box theme-eswitch"><div class="box-label">eswitch (HW)</div><div class="port-list">⟦esw⟧</div>
      <div class="hw-box"><strong>⚡ Hardware offload</strong>nl2doca programs eswitch rules from FRR routes; matched flows forward in hardware.</div></div></div>
    <div class="col-arrow"><span class="arr">⇄</span></div>
    <div class="col col-ovs"><div class="box theme-ovs"><div class="box-label">OVS br-hbn</div><div class="port-list">⟦ovs⟧</div></div></div>
    <div class="col-arrow"><span class="arr">⇄</span></div>
    <div class="col col-frr"><div class="box theme-frr"><div class="box-label">doca-hbn container (FRR)</div><div class="port-list">⟦frr⟧</div></div></div>
  </div>
  <div class="col-arrow"><span class="arr pcie">⇄</span></div>
  <div class="col col-host"><div class="box theme-host"><div class="box-label">x86 Host (⟦xip⟧)</div><div class="port-list">⟦host⟧</div></div></div>
</div>
<div class="legend">
  <div class="legend-item"><span class="port-dot dot-uplink"></span> physical / ToR uplink</div>
  <div class="legend-item"><span class="port-dot dot-rep"></span> eswitch representor</div>
  <div class="legend-item"><span class="port-dot dot-sf"></span> host-PF SF</div>
  <div class="legend-item"><span class="port-dot dot-frr"></span> FRR interface</div>
  <div class="legend-item"><span class="port-dot dot-vf"></span> VF (SR-IOV)</div>
  <div class="legend-item"><span class="port-dot dot-host"></span> host NIC</div>
  <div class="legend-item" style="margin-left:auto;color:#718096">click any port for live details</div>
</div>
<div class="info-panel" id="info-panel"><span class="close" onclick="closeInfo()">✕</span><h3 id="info-title">-</h3><div id="info-content"></div></div>
<script>
const portInfo=⟦info⟧;
function showInfo(el){const id=el.getAttribute('data-id');const i=portInfo[id];if(!i)return;
 document.querySelectorAll('.port.highlighted').forEach(p=>p.classList.remove('highlighted'));el.classList.add('highlighted');
 document.getElementById('info-title').textContent=i.title;let h='';
 (i.rows||[]).forEach(r=>h+=`<div class="info-row"><span class="info-key">${r[0]}</span><span class="info-val">${r[1]}</span></div>`);
 if(i.flow)h+=`<div class="flow-path">${i.flow.replace(/→/g,'\n→')}</div>`;
 document.getElementById('info-content').innerHTML=h;document.getElementById('info-panel').style.display='block';}
function closeInfo(){document.getElementById('info-panel').style.display='none';
 document.querySelectorAll('.port.highlighted').forEach(p=>p.classList.remove('highlighted'));}
</script></body></html>'''

for _k,_v in data.items():
    TPL = TPL.replace("⟦"+_k+"⟧", str(_v))
open(out, "w").write(TPL)
print(f"rendered {out}")
