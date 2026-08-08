# aviz-gw-top

An htop-style, full-screen terminal dashboard for the **Aviz Gateway** data
plane (`aviz-gw-dp`) — a VPP-based software gateway doing routing, firewall
(ACL) and NAT, with FRR/BGP wired in via Linux-CP.

It is a **read-only** observability tool, with one deliberate, clearly-gated
exception: the Validation screen can inject test packets, but only when
started with `--allow-inject` (see below).

```
aviz-gw-top --mock          # full demo, no gateway required
aviz-gw-top                 # against a live gateway (default sockets)
gwtop                       # short alias, same tool
```

**New here? Start with [QUICKSTART.md](QUICKSTART.md)** — exact install/run
commands, the key cheat-sheet, and first-run troubleshooting.

## Screens

| Key | Screen     | What it shows |
|-----|-----------|----------------|
| 1   | Status     | Worker threads (vectors/call — the leading saturation signal), interfaces (with VRF + addresses + peer liveness), hottest graph nodes (`w` expands the per-worker split under every node), drop summary, throughput sparkline |
| 2   | Routing    | FIB across **all VRFs** with adjacency state (incomplete = ARP unresolved, matched per-VRF), neighbor/ARP table tagged by VRF, prefixes-per-next-hop summary (real gateways only, per VRF) |
| 3   | Firewall   | ACL rules in evaluation order with live hit counters; dead (zero-hit) rules dimmed; attachments carry the interface's VRF; warns when one ACL spans VRFs (hit counters are per rule, not per attachment) |
| 4   | NAT        | Session-table utilization bar, created/expired rates, NAT counters, **static mappings (DNAT)** panel, session sample with per-session SNAT/DNAT type and inside-VRF |
| 5   | Validation | Send test traffic (gated), then a packet's node-by-node journey through the graph as a colored pipeline; shows rx interface, carrying worker, live node counters (`w` splits them per worker, ◆ marks the carrying worker) |
| 6   | Cores      | RX queue → worker placement (`show interface rx-placement`) with per-core traffic shares; flags queue/traffic skew and idle polled queues |

Navigation: `1`–`6` or `Tab`/`Shift-Tab`. `q` quits, `p` pauses refresh,
`/` filters the current screen's table (Esc clears). On the Validation
screen, `←`/`→` or `[`/`]` (or clicking ◀ prev / next ▶) switch packets.

### Per-VRF views (`v`)

Screens 1, 2, 3, 4 and 6 all bind `v`, cycling **all → default → each
VRF**. The selection is app-global — cycle to a tenant on Routing and
Status/Firewall/NAT/Cores follow. Everything VRF-related resolves through
real table names (`ip_table_dump`): route tables, neighbor interfaces,
ACL attachments, NAT sessions (inside/tenant table) and static mappings.
On a single-table gateway `v` is a no-op and no VRF chrome appears.

## Install

Requires Python 3.11+.

```sh
uv venv && uv pip install -e ".[dev]"      # development
uv pip install -e ".[vpp]"                 # add vpp_papi from PyPI, or…
```

Against a real gateway, prefer the `python3-vpp-api` package shipped with the
gateway's VPP build over PyPI, so the PAPI version matches the running VPP.
The tool is fully usable without `vpp_papi` in `--mock` mode.

## Running with --mock

`aviz-gw-top --mock` runs the complete UI against an animated fake data
source (`data/mock_source.py`): drifting counters, a small FIB with one
deliberately unresolved next-hop, ACL rules with live hit counts (one dead
rule), churning NAT sessions, and canned packet traces for the Validation
screen (including a deny/drop path — try protocol `tcp`, dport `22` with
Inject+Trace). Every feature is demoable this way; no VPP anywhere.

## Running against a live gateway

```sh
aviz-gw-top [--stats-socket /run/vpp/stats.sock] [--api-socket /run/vpp/api.sock] \
            [--interval 1.0] [--slow-interval 5.0] [--allow-inject] [--no-color]
```

Two independent channels are used, on two cadences:

* **Stats segment** (`--stats-socket`, default `/run/vpp/stats.sock`) —
  shared-memory reads via `vpp_papi.VPPStats` for everything at 1 Hz:
  interface/node/worker/error counters. Counters are per-worker-thread; the
  tool keeps the per-worker breakdown (asymmetry usually means uneven RSS)
  and sums for totals. Counters are cumulative; all rates are computed in
  `data/poller.py`, which also detects counter resets (VPP restart) and
  re-baselines instead of emitting negative rates.
* **Binary API** (`--api-socket`, default `/run/vpp/api.sock`) — structural
  dumps every ~5 s: interfaces, FIB, neighbors, ACLs, NAT. The tool connects
  directly over the socket; it never shells out to `vppctl`.

If the gateway goes away, a red DISCONNECTED banner appears and the tool
retries until it returns; it never crashes or hangs on gateway I/O.

### Required permissions

The user running the tool needs **read/write access to both sockets** (they
are Unix sockets; even the stats segment is bootstrapped via its socket).
Stock VPP creates them `root:vpp`, so either run as root or add your user to
the `vpp` group:

```sh
sudo usermod -aG vpp $USER   # then re-login
```

### Pinned VPP version

The tool targets **VPP v26.06-release**, pinned in a single constant:
`aviz_gw_top/config.py: TARGET_VPP_VERSION = "26.06"`. At startup the running
version is compared against the pin; a mismatch shows a yellow warning banner
(API and CLI output formats can shift between releases) but is never fatal.
No other code makes version assumptions.

## The Validation screen and --allow-inject

Screen 5 is the one exception to read-only, and it is explicitly gated:

* **Passive mode (default)** — "Trace" enables packet tracing on the input
  node for a bounded number of packets and renders traces of real traffic
  already flowing. Enabling trace is a control-plane action, but nothing is
  generated.
* **Active mode (`--allow-inject`)** — "Send" runs a rate-limited pg stream
  matching the form (src/dst IP, ports, protocol, rate, size, duration; the
  "arrives on" dropdown names each port's VRF — the injected packet is
  looked up in that interface's FIB). Every stream carries both `rate` and
  a `limit` (a 26.06 rate-limiter bug otherwise escalates to line rate);
  continuous mode re-arms bounded windows, timed mode stops itself. Without
  the flag Send is disabled and the UI shows PASSIVE mode at all times; the
  tool never injects silently.

The rendered pipeline shows one block per graph node with the decision made
there (ACL rule matched and verdict, FIB prefix and next-hop, NAT translation
before/after, final rewrite), colored green/permit, red/drop (drops terminate
the pipeline), yellow/translate-rewrite, cyan/informational. Unrecognized
node formats are rendered as raw text — a stage is never silently dropped.

## Why Textual

The UI uses [Textual](https://textual.textualize.io/): declarative layout and
CSS-like styling make five dense table screens far cheaper to build and
maintain than hand-managed curses windows, it has first-class async +
worker-thread support (the UI thread never touches gateway I/O), and built-in
widgets (DataTable, Sparkline, Input) cover everything needed. Swappability
is preserved by architecture rather than a widget-shim: **all** VPP access is
behind `data/` returning plain dataclasses from `model/`, every color goes
through semantic names in `theme.py`, and all number formatting lives in
`ui/format.py` — so replacing Textual with curses means rewriting only the
`ui/` package against the same models.

Colors: `--no-color` and the `NO_COLOR` env var disable color entirely; the
layout carries all meaning in text as well (e.g. `INCOMPLETE (ARP
unresolved)`, `admin-down`, explicit `[deny]` tags), color is reinforcement.

## Architecture

```
aviz_gw_top/
  config.py        # ALL tunables: version pin, sockets, cadences, thresholds
  theme.py         # ALL colors, as semantic names (OK/WARN/CRIT/IDLE/INFO/ACCENT)
  model/           # frozen dataclasses; the only vocabulary the UI knows
  data/
    base.py        # DataSource ABC + sample types
    mock_source.py # animated fake data (no VPP)
    vpp_source.py  # real: stats segment + binary API + cli_inband fallback
    parsers.py     # ALL CLI text parsing/building, quarantined
    poller.py      # one background thread: sampling, rates, reset detection
  ui/
    app.py         # navigation, bindings
    screens/       # status, routing, firewall, nat, validation, cores
    widgets/       # header/banner chrome, table refresh helper
tests/             # parser fixtures + rate computation + poller end-to-end
```

Layering rules (enforced by review, worth keeping): `data/` never imports UI;
`ui/` never imports `vpp_papi` and never parses gateway text; everything the
UI renders is a frozen dataclass from `model/`. A single poller thread owns
both gateway connections and publishes immutable snapshots; the UI reads the
latest snapshot and never blocks. Trace runs from the Validation screen are
funneled onto the poller thread via `Poller.submit()` because the PAPI client
is not thread-safe.

## CLI text-format dependencies (upgrade checklist)

Everything that scrapes CLI text lives in `aviz_gw_top/data/parsers.py` and
is unit-tested against captured output in `tests/fixtures/`. When bumping
`TARGET_VPP_VERSION`, capture fresh output for each of these and re-verify:

| Function | Command | Fixture |
|----------|---------|---------|
| `parse_show_trace` | `show trace max N` | `show_trace.txt`, `show_trace_live_2606.txt` |
| `parse_show_threads` | `show threads` | `show_threads.txt` |
| `parse_nat44_summary` | `show nat44 summary` | `show_nat44_summary.txt` |
| `parse_pg_streams` | `show packet-generator verbose` | `show_packet_generator.txt` |
| `parse_rx_placement` | `show interface rx-placement` | `show_rx_placement_live_2606.txt` |
| `parse_hardware_brief` | `show hardware-interfaces brief` | inline in `test_parsers.py` |
| `build_pg_stream` | `packet-generator new {...}` (input, not output) | — |
| `cmd_*` helpers | `trace add`, `clear trace`, `show trace max`, `packet-generator enable-stream/delete` | — |

## Verified vs. assumed (read before trusting against a new build)

Grep for `VERIFY(26.06)` — every place that depends on a VPP name that could
drift is marked and isolated behind a constant or accessor:

* **Stats segment paths** (`data/vpp_source.py`, `STATS_*` constants):
  `/if/*`, `/sys/node/*`, `/err/*` are long-stable; the ACL per-rule hit
  counter pattern (`^/acl/`) and NAT gauge pattern (`^/nat44-ed/`) are
  best-effort — if absent on the target build, hits/counters degrade to 0
  rather than failing.
* **Binary API message names** (`MSG_*` candidate tuples): resolved at
  runtime against the connected VPP via introspection (`_find_msg`), e.g. the
  NAT44-ED session dump tries `nat44_user_session_v3_dump` → `v2` → `v1`.
  The NAT plugin variant is assumed to be **NAT44-ED**; other variants
  (deterministic, EI) expose different dump messages.
* **Per-route counters**: optional in VPP, off by default at scale. When the
  stats path is absent the Routing screen shows "per-route counters not
  enabled" instead of zeros.
* **Per-node counters** (`/sys/node/*`): a `statseg { per-node-counters on }`
  STARTUP option, off in stock configs and with no runtime toggle on 26.06.
  When absent the tool stays connected and degrades — interfaces, drops and
  error counters keep working; node/worker-rate panels are empty and the
  TOP NODES title states the cause and the config line that fixes it.
* **Trace rx interface**: af-packet/virtio/tap input records name no
  interface, only `hw_if_index`; the tool resolves it via
  `show hardware-interfaces brief` (hw index ≠ sw index once
  sub-interfaces exist — never shortcut this mapping).
* **NAT static mappings**: `nat44_static_mapping_dump`; the `ADDR_ONLY`
  flag (0x08) marks 1:1 mappings whose ports are meaningless. The mapping's
  `vrf_id` names the *local* (tenant) table; per-session VRF comes from the
  NAT user record.
* **`show trace` step formats**: the per-node classifiers in
  `parse_show_trace` were written for 26.06-style output; unknown nodes fall
  back to raw-text rendering, so a format change degrades visibly, not
  silently.
* **pg stream syntax** in `build_pg_stream`.
* `vpp_papi` surface was introspected against vpp-papi 2.4.0 (PyPI): the
  code was written against the real signatures of `VPPStats.ls/dump/__getitem__`
  and `VPPApiClient`, not from memory.

## Development

```sh
uv run pytest              # parser + rate tests
uv run mypy aviz_gw_top    # strict typing
uv run ruff check .        # lint
aviz-gw-top --mock         # live demo without a gateway
```

Thresholds (vectors/call warn/crit, NAT utilization bands, worker utilization
bands) live in `config.Thresholds` and are deliberate starting heuristics —
tune them against real measurement.
