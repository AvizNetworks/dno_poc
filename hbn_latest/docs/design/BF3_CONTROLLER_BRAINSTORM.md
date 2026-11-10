# BF3 Controller Service + UI — Brainstorming Notes

Status: **exploration, nothing decided.** Input for a design/brainstorm session.
Date: 2026-10-22. Author context: Aviz HBN/ONES team (standalone HBN on BlueField-3).

How to use this doc: each section ends with **Questions to discuss**. Options are listed with
pros/cons, not ranked unless a lean is stated. Section 14 collects all open questions in one list.

---

## 1. Why we're talking about this

Today a BF3 + HBN bring-up is driven **from the x86 host** that holds the card
(`hbn_quickstart.sh`, over PCIe rshim). That works — Test A passed on the partner box bp5 —
but real life keeps breaking the assumption that the host is available:

- **bp5 (partner box), Oct 22:** the host dropped off the network ("Destination Host
  Unreachable" from the upstream router). Every tool we have needs that host's OS. Yet the BF3's
  own BMC and the host's BMC were still reachable from the jump box (ones-1).
- **S8 (NICo-managed):** host rshim is **disabled at the BMC** (`HostRshim: Disabled`) — the
  host path doesn't even exist by design in NICo/DPF layouts.
- **Fresh/wiped servers:** no host OS at all yet — the whole point of DPU netboot is to install
  the host *from* the BF3, so the BF3 must be set up without the host.
- **Mode switches need cold power cycles** — today the script stops with "exit 3, go power
  cycle the host". A controller with host-BMC access could do it itself.
- **Fleet scale:** one script per host, run by hand, with results in a text file, doesn't scale
  past a handful of servers. Partners will bring multiple DPUs in multiple servers.

The idea: a **controller service** that runs on a management box (jump host / ONES server),
reaches every server through whichever path is alive, and drives each BF3 through its lifecycle —
with a **UI** on top so a partner/operator can see and act on a fleet.

---

## 2. What exists today (building blocks we'd reuse)

All in `hbn_latest/scripts/` unless noted. Principle so far: **existing scripts keep working by
hand; automation wraps them, never changes their manual behaviour.**

| Building block | Runs on | What it does |
|---|---|---|
| `inventory_bf3.sh` | BF3 Arm | Read-only capability report + verdict (bundle, NIC/DPU mode, single vs dual port, VF capacity, kubelet/cluster membership, LLDP) |
| `bringup_hbn_bf3.sh` | BF3 Arm | Dual-port HBN bring-up, 15 idempotent steps, `--check` preflight |
| `bringup_hbn_bf3_single_port.sh` | BF3 Arm | Single-port (SuperNIC B3140H) variant, `--no-pf` option |
| `status_hbn.sh` / `topology_hbn.sh` | BF3 Arm | Health check / interface reference card (layout-aware) |
| `setup_host_vfs_standalone.sh` | x86 host | Creates host SR-IOV VFs + persistence unit |
| `hbn_quickstart.sh` | x86 host | One-command orchestration over rshim/tmfifo: find BF3 → DPU mode → flash/adopt → base config → package+image push → inventory/guards → host VFs → bring-up → ONES hand-over file |
| `dpu_netboot_server.sh` | BF3 Arm | DHCP/TFTP/HTTP on pf0hpf so the host can PXE/install (or live-boot) from its own BF3 |
| `make_packages.sh` | build box | Offline packages (scripts + configs + optional arm64 HBN image tar) |
| `dpf/scripts/bringup_dpf.sh` | DPF operator VM | Kubernetes-native provisioning via BMC Redfish (DPF) — a *different* model we already know |
| NVUE REST (:8765 on BF3 OOB) | BF3 | HBN config API that ONES uses for tenant provisioning |

Hand-over today = `/var/lib/hbn-quickstart/ones-handover.{txt,json}` on the host (BF3 OOB IP,
REST endpoint + creds, interface map, VF list).

---

## 3. Access paths to a server (the core idea)

Each server has up to **five** ways in. The controller picks the best one that's alive per
action, and falls back.

| # | Path | Needs alive | Good for | Not good for |
|---|---|---|---|---|
| A | **BF3 Arm OOB SSH** (oob_net0) | Arm OS + OOB IP | config, package/image push, bring-up, health, logs | flashing, recovery when OS is broken |
| B | **Host OS SSH** | host OS | host VFs, host rshim/tmfifo, host-side tests (ping through PF/VF), lspci/VPD | anything when host is down |
| C | **Host rshim** (via B) | host OS + rshim function exposed | fastest BFB flash (vfio), tmfifo to Arm when OOB is dead, Arm console | NICo/DPF boxes (HostRshim disabled) |
| D | **BF3 BMC** (Redfish, BMC-side rshim, Arm console on :2200) | standby power only | identity (PN/serial), NIC↔DPU mode, BFB flash without host, Arm reset, console, bricked-card recovery | bulk data transfer speed; some BMC firmware quirks |
| E | **Host BMC** (IPMI / Redfish / SOL / KVM) | standby power only | power on/off/cycle, SEL/health, host console, one-time boot device (PXE), "what happened?" | anything inside the OS |

Rules we already learned the hard way:
- **One rshim owner at a time.** BMC rshim and host rshim fight (bfb-install timeouts). The
  controller must explicitly take/release ownership.
- **Cold power cycle ≠ reboot.** nvconfig changes (LINK_TYPE, LAG_RESOURCE_ALLOCATION, NIC mode
  on some cards) only commit when slot power is cut: host BMC `chassis power cycle`.
- **NIC mode on SuperNICs:** Redfish `Bios/Settings NicMode=DpuMode` → Arm reset (UEFI applies)
  → cold cycle. The `/Bios` read-back can be stale; trust BootProgress + host devlink.
- **Partner networks often have no DHCP on the OOB** → static OOB IP must be baked in.
- **Clock can be months off** after flash → TLS/apt/cert failures; set NTP/clock early.
- **Host reboot after BF3 reflash** is needed or the host PF goes stale ("wait vital failed").

### Questions to discuss
- Which paths do we *require* vs *optional*? Minimum viable = D + E? Or A + E?
- Do we support servers where we only get path B (host SSH) — i.e. today's quickstart mode?
- How do we discover paths: operator enters them, or scan a subnet and match MACs/serials?

---

## 4. Where the controller runs (deployment options)

| Option | Description | Pros | Cons |
|---|---|---|---|
| 4a. **CLI on a jump box** | A script/binary on ones-1-like box; state in a folder | Fastest to build; no infra | No UI, no concurrency, state in files |
| 4b. **Service + REST API + web UI** on a mgmt VM | Daemon with DB, job runner, API; UI talks to API | Fleet view, audit, multi-user, UI-ready | More to build/secure/operate |
| 4c. **Inside ONES** | A module/microservice of the ONES product | One product, one login; provisioning flows straight into tenant config | Couples release cycles; ONES team ownership |
| 4d. **Kubernetes operator / reuse DPF** | CRDs per server/DPU, reconcile loops | Matches NVIDIA DPF/NICo model; declarative | Heavy for partners; DPF already does this (and we've seen its pain) |
| 4e. **Hybrid** | 4a engine (same code) + 4b wrapper later | Start small, no throwaway | Need clean engine/API boundary from day one |

Lean (to challenge): **4e** — build the engine as a library/CLI with machine-readable output, then
wrap it in a service + UI, and later embed in ONES.

### Questions to discuss
- Does the controller live at the customer site (needs reach to BMC/OOB nets), or ours (VPN)?
- One controller per site, or one central controller with site agents?
- Air-gapped sites: controller must carry BFBs, HBN image, packages offline — how big is OK?

---

## 5. Lifecycle model (state machine per BF3)

A per-DPU state machine the UI can show as a progress bar / swimlane:

```
Unknown
  → Discovered        (BMC reachable, identity read: PN, serial, card type, port layout)
  → Assessed          (mode, bundle version, firmware, cluster membership, HBN present?)
  → ModeReady         (DPU mode confirmed; may require: Redfish PATCH → Arm reset → cold cycle)
  → OSInstalled       (target bf-bundle running; password/key/OOB from bf.cfg)
  → BaseConfigured    (clock/NTP, OOB netplan, PF_TOTAL_SF, LAG staging if dual-port)
  → Staged            (scripts + HBN image on the Arm)
  → HostReady         (host OS up, VFs created)        ← may be "Pending host" for a long time
  → HBNUp             (bring-up done, status_hbn all green)
  → Validated         (datapath tests passed: host PF/VF ↔ HBN, uplink ↔ ToR, REST login)
  → HandedOver        (ONES has endpoint/creds/interface map; tenant provisioning allowed)
  → Degraded / Failed / NeedsAction (power cycle / human / partner approval)
```

Design points:
- Every transition is **idempotent and re-runnable** (as our scripts already are).
- Some transitions need **approval** (destructive: reflash, mode switch, power cycle,
  `mlxconfig` changes) — especially on partner-owned boxes.
- "Pending host" must be a first-class state: BF3 side can finish while the host is down.
- Drift detection: a Validated BF3 can fall back (host rebooted → tmfifo IP lost, VFs gone; BF3
  reflashed by someone; kubelet joined to another cluster).

### Questions to discuss
- Is "HandedOver" the end, or does the controller keep owning day-2 (upgrades, health)?
- Desired-state (declarative: "this server should be HBN 3.3.0, 4 VFs, BGP on") vs
  imperative (buttons: "flash", "bring up")? Or both?

---

## 6. Capabilities the service could offer (menu for brainstorming)

Grouped; mark each as MVP / later / never during the session.

### 6.1 Discovery & inventory
- Add server by BMC IPs + creds; or bulk import CSV; or subnet scan + MAC/serial matching.
- Read identity via Redfish: BF3 PN (e.g. 900-9D3D4 SuperNIC vs 900-9D3B6 DPU), serial, OEM (Dell
  OEM PN like 0KK4NR), firmware, BMC version; host model/serial (dmidecode/Redfish).
- Port layout (single/dual), link speeds, PCIe link (Gen3 vs Gen5 — bp5 trains Gen3), slot power.
- Compatibility verdict: "can run HBN", "SuperNIC — needs DPU mode", "NICo-managed — hands off".

### 6.2 Mode & firmware
- NIC ↔ DPU mode switch (Redfish), with automatic Arm reset + cold cycle.
- Firmware version check vs bundle; OEM PSID handling (bf-bundle won't update OEM firmware).
- nvconfig audit/diff vs a known-good profile (we keep finding drift: ECPF ownership,
  PF_TOTAL_SF, LAG_RESOURCE_ALLOCATION, HIDE_PORT2_PF, NUM_OF_PF).
- "Golden nvconfig profile" per card type; one-click remediate (with approval + cold cycle).

### 6.3 OS provisioning
- Flash BFB via BMC (no host) or host rshim (fast) — controller chooses.
- bf.cfg baked in: ubuntu password, SSH key, static OOB IP/gw/DNS, NTP, hostname.
- Adopt an already-flashed BF3 (password known) instead of reflashing.
- BFB library: versions, checksums, which card types validated.

### 6.4 HBN bring-up & config
- Push package + image offline; run the right bring-up script (single/dual port).
- Options: VFs per PF, host PF in HBN or not, BGP on/off, REST password.
- Day-1 network config templates via NVUE (L2 bridge for PXE VLAN, L3 gateway, BGP to ToR,
  DHCP relay).
- Show FRR state (BGP sessions, routes) in the UI.

### 6.5 Host side
- Create/persist host VFs (needs host OS).
- Host OS install via DPU netboot (BF3 serves PXE; host BMC sets one-time PXE boot).
- Live-boot (RAM) rescue OS for the host from the BF3.
- Host power control, SEL, console (SOL/KVM link).

### 6.6 Validation / tests
- Datapath test matrix: host PF ↔ pf0hpf, host VF ↔ pfXvfN_if, uplink ↔ ToR, REST login, BGP up.
  (bp5 taught us: "HBN status green" ≠ "host traffic flows" — must test the actual path.)
- Passive counters check (vport_rx vs rx on representors) to localize drops.
- Throughput smoke test (optional, flagged when slot is Gen3/low power).

### 6.7 Monitoring & day-2
- Periodic health (status_hbn equivalent), drift alerts, BGP flaps, link down.
- Upgrades: bf-bundle / HBN image rolling upgrade per fleet with canary.
- Backup/restore of HBN/FRR/NVUE config.
- Event timeline per server (power events from SEL, reflashes, mode changes, who did what).

### 6.8 Troubleshooting & recovery
- "What happened?" panel: host power state + SEL tail + BF3 BootProgress + reachability of each path.
- One-click diagnostic bundle: doca-sosreport, inventory, status, mlxconfig, dmesg, host lspci.
- Guided fixes for known issues (our troubleshooting tables become a rules engine:
  symptom → check → fix).
- Bricked-card recovery via BMC rshim.

### 6.9 ONES integration
- Hand-over as API, not a text file: ONES pulls endpoint/creds/interface map per DPU.
- Gate: ONES can only provision tenants on DPUs in "Validated/HandedOver".
- Map tenants → host VFs → HBN interfaces in one view.

### Questions to discuss
- Which 5 capabilities make the MVP demo for partners?
- Which are "Aviz value-add" vs "NVIDIA tools already do it" (DPF, NICo, BMC UI)?

---

## 7. UI ideas

### 7.1 Screens
1. **Fleet dashboard** — table/cards of servers: card type, mode, bundle, HBN state, lifecycle
   stage, health dot, last event. Filters: site, partner, card type, stage, "needs action".
2. **Add server wizard** — enter host BMC, BF3 BMC, (optional) host SSH, OOB plan → controller
   probes each path live and shows green/red per path before saving.
3. **Server detail** — tabs:
   - Overview: identity, paths status, lifecycle progress bar, next action button.
   - Hardware: BF3 PN/serial/firmware/nvconfig diff vs profile, PCIe link, ports, host model.
   - HBN: interfaces (topology card), FRR/BGP, REST status, VFs.
   - Host: power, SEL, console link, VFs, OS.
   - Jobs/logs: live streaming output of running steps, history.
   - Timeline: events (power, flash, config changes, who/when).
4. **Job runner view** — queue across fleet, progress, cancel/retry, approvals pending.
5. **Approvals inbox** — destructive actions awaiting OK (partner-owned boxes!).
6. **Topology view** — ToR ↔ p0/p1 ↔ br-hbn ↔ pf0hpf/VFs ↔ host NICs, live link/counters.
7. **Diagnostics view** — "what happened" panel + collect bundle + rule-based suggestions.
8. **Settings** — BFB/image library, credential vault, golden profiles per card type, sites.

### 7.2 UX principles
- Every action shows **which path** it will use and **what it will change**, with a dry-run
  preview (our `--check` / `--dry-run` culture).
- Read-only by default; destructive actions require explicit confirm (+ reason).
- Show raw command output on demand — operators trust it, and it helps support.
- Long operations (flash ~10–30 min, cold cycle) show stage + ETA + "safe to leave page".

### 7.3 Tech options (for the UI)
- Web app (React/Vue) over the service's REST + websocket for live logs.
- Lightweight: server-rendered pages (HTMX) — faster to build, fewer moving parts.
- Embed as a page inside ONES UI.

### Questions to discuss
- Who is the primary user: Aviz field engineer, partner ops, or end customer?
- Does the UI need multi-tenant separation (partner A can't see partner B)?
- Mobile/tablet need? (Probably not.)

---

## 8. Data model sketch

- **Site** (name, networks, controller, offline yes/no)
- **Server** (host BMC endpoint+cred ref, host SSH endpoint+cred ref, model, serial)
- **DPU** (server ref, BF3 BMC endpoint+cred ref, PN, serial, card type, port layout, mode,
  firmware, bundle, OOB IP, lifecycle state, desired config)
- **Profile** (card type → golden nvconfig, bundle version, HBN options)
- **Job** (type, target, path used, steps, logs, status, started/finished by)
- **Event** (timestamp, source: SEL/Redfish/script/user, message)
- **Credential** (vault ref; never stored in plain text; rotated passwords tracked)
- **Handover** (DPU → REST endpoint, creds ref, interface map, VF list)

---

## 9. Security & safety

- **Credentials:** host BMC, BF3 BMC, Arm ubuntu, REST — per server. Need a vault (or at least
  encrypted store), rotation, and never echoing them in logs/UI. (Lesson: credentials got
  pasted in chat during bp5 bring-up and needed rotation.)
- **Partner-owned hardware:** read-only mode per server; approval workflow for anything that
  reflashes, changes nvconfig, power-cycles, or changes BMC settings.
- **Blast radius:** a bad bf.cfg (wrong static OOB) can strand a card → BMC console fallback must
  always remain; never disable BMC paths.
- **Coexistence:** detect NICo/DPF-managed DPUs (kubelet joined elsewhere, HostRshim disabled,
  `/etc/kubernetes/manifests` static pods) and refuse by default.
- **Audit log** of every action with user and reason.
- Controller access to BMC networks = high privilege; harden the controller host.

---

## 10. Hard problems / known gotchas to design around

1. **Host-dependent steps** (VFs, host tests) — need "pending host" + resume when host returns.
2. **Cold power cycle orchestration** — host BMC required; cycle also resets the BF3; the HBN
   stack must come back before host PXE times out (boot race).
3. **BMC Redfish quirks** — flash skipped when version unchanged (404 / FailToInstall seen in
   DPF), stale `/Bios` reads, BootProgress=OEM is normal steady state, varying BMC firmware.
4. **OEM cards** (Dell/Lenovo PSIDs) — firmware updates, CRD patterns (DPF PSID regex), maybe
   different behaviour (bp5's unresolved PF0 host↔representor delivery issue is on a Dell OEM
   B3140H).
5. **Netboot vs HBN** — can't serve PXE on pf0hpf while OVS-DOCA owns the eswitch; needs an
   HBN-integrated netboot mode or strict ordering (netboot before HBN).
6. **NVUE REST apply broken on DOCA 3.3.0** — config apply must be done inside the container.
7. **Clock skew** after flash; **no DHCP** on partner OOB; **no internet** on the BF3.
8. **rshim ownership** (host vs BMC) and slow BMC-side transfers.
9. **Version matrix**: validated on bf-bundle 3.3.0 + HBN 3.3.0; NICo boxes run 3.4.1.

---

## 11. Relationship to NVIDIA DPF / NICo

- DPF/NICo already do BMC-driven provisioning (Redfish flash, bf.cfg, DPU objects) but are
  Kubernetes-heavy, force SuperNICs into NIC mode (NICo), and we've hit many sharp edges.
- Our angle could be: **lightweight, standalone-HBN-first, partner-friendly, fleet UI, ONES
  integrated, works without Kubernetes**, and plays nice (detects + leaves alone) with DPF/NICo
  boxes.
- Option: use DPF for provisioning where present, our controller for everything else.

### Questions to discuss
- Compete, complement, or wrap DPF/NICo?
- Will partners already run NICo? If so, is our value the HBN/ONES layer only?

---

## 12. Phased roadmap (straw man)

| Phase | Scope | Value |
|---|---|---|
| 0 | **Remote doctor (read-only)**: per server, probe all 5 paths; show host power/SEL/console state, BF3 identity/mode/BootProgress/version, Arm reachability, HBN health | Immediately useful (e.g. bp5 outage); zero risk |
| 1 | Engine CLI: mode switch + cold cycle via BMCs, BMC flash with baked bf.cfg, adopt existing | No-host provisioning |
| 2 | HBN bring-up over OOB + deferred host VFs + validation tests + hand-over API | End-to-end without touching host scripts |
| 3 | Service + REST + minimal UI (fleet table, server detail, jobs with live logs, approvals) | Partner-facing demo |
| 4 | ONES integration, monitoring/drift, upgrades, netboot orchestration, diagnostics rules | Product |

---

## 13. Success criteria ideas

- Add a brand-new server (only BMC IPs + creds) → HandedOver with zero console typing.
- Time from rack to ONES-ready < 60 min (flash dominates).
- Any failure shows a specific cause + next action, not a log dump.
- Works with host OS down for everything except host VFs.
- Never performs a destructive action on a partner box without recorded approval.

---

## 14. All open questions (for the session)

1. Who is the primary user — Aviz field engineer, partner ops, end customer?
2. Where does the controller run — customer site, central, inside ONES?
3. Minimum required access paths per server? Can we always get host BMC + BF3 BMC creds?
4. CLI-first then UI, or UI-first?
5. Declarative desired state vs imperative actions vs both?
6. Day-2 ownership: does the controller keep monitoring/upgrading after hand-over?
7. MVP capability list — which 5 things for the first partner demo?
8. How to handle partner-owned hardware approvals in the UI?
9. Credential storage — vault product, or encrypted file to start?
10. Multi-tenant UI (partners isolated) needed in v1?
11. Offline/air-gapped support from day one?
12. Relationship with DPF/NICo — compete, complement, wrap?
13. Should host OS install (netboot) be part of v1?
14. Which card types to support first (B3140H SuperNIC single-port, 900-9D3B6 dual-port DPU, OEM)?
15. How do we test it — which lab servers are free (S3/S4 idle; S1/S2/S7/S8 team-used)?
16. Naming: "BF3 Controller", "DPU Manager", "ONES DPU Provisioner"…?
