"""Screen 1 — Status: workers, interface throughput, hot nodes, drops."""

from __future__ import annotations

from collections import deque
from typing import ClassVar

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import DataTable, Sparkline, Static
from textual.widgets.data_table import RowDoesNotExist

from ...config import TRACE_INPUT_NODES
from ...model import GatewayState
from ...theme import (
    Sem,
    sem_for_drops,
    sem_for_vectors_per_call,
    sem_for_worker_utilization,
    style_for,
)
from ..format import bar, clk_per_pkt, human_bps, human_count, human_pps
from ..widgets.tables import refill
from .base import BaseScreen


def _rate_cell(value: float, text: str, cutoff: float = 0.0) -> Text:
    """Rate column: dim zero, normal flowing, bold in the screen's top decile."""
    if value <= 0:
        return Text(text, style_for(Sem.IDLE))
    style = style_for(Sem.PLAIN)
    if cutoff > 0 and value >= cutoff:
        style = "bold"
    return Text(text, style)


def _peer_status(admin_up: bool, link_up: bool, nbr_count: int,
                 unresolved: bool) -> tuple[str, Sem]:
    """Peer-liveness cell: carrier up says nothing about the device behind it.

    Field incident: both routers died while their links kept carrier, so the
    link column showed 'up' throughout. The tell was one level higher — zero
    resolved neighbors while routes kept gleaning out the interface.
    """
    if not (admin_up and link_up):
        return "—", Sem.IDLE
    if nbr_count:
        return f"{nbr_count} nbr", Sem.OK
    if unresolved:
        return "SILENT", Sem.CRIT
    return "—", Sem.IDLE


def _top_decile(values: list[float]) -> float:
    flowing = sorted(v for v in values if v > 0)
    if not flowing:
        return 0.0
    return flowing[max(0, int(len(flowing) * 0.9) - 1)]


class StatusScreen(BaseScreen):
    SCREEN_NAME: ClassVar[str] = "status"

    BINDINGS = [
        ("v", "cycle_vrf", "VRF"),
        ("w", "toggle_worker_split", "Splits"),
    ]

    DEFAULT_CSS = """
    StatusScreen .row-top { height: 9; }
    StatusScreen #workers-panel { width: 3fr; }
    StatusScreen #drops-panel { width: 2fr; }
    StatusScreen #punt-panel { width: 2fr; }
    StatusScreen #ifaces-panel { height: 1fr; min-height: 7; }
    StatusScreen #nodes-panel { height: 1fr; min-height: 7; }
    StatusScreen #spark-row { height: 2; margin: 0 1; }
    StatusScreen #spark-label { width: 24; }
    StatusScreen Sparkline { width: 1fr; }
    """

    def __init__(self) -> None:
        super().__init__()
        self._pps_history: deque[float] = deque([0.0] * 60, maxlen=60)
        self._expanded_node = ""  # node whose per-worker split is shown
        self._split_all = False   # "w": per-worker split under every node

    def compose_body(self) -> ComposeResult:
        with Horizontal(classes="row-top"):
            with Vertical(id="workers-panel", classes="panel"):
                yield Static("WORKER THREADS — vectors/call is the saturation signal",
                             classes="panel-title sem-fg-accent")
                yield DataTable(id="workers-table", cursor_type="row", zebra_stripes=True)
            with Vertical(id="drops-panel", classes="panel"):
                yield Static("DROPS — ▲ = steady rate (periodic → check config)",
                             classes="panel-title sem-fg-accent")
                yield Static(id="drops-total")
                yield DataTable(id="drops-table", cursor_type="none")
            with Vertical(id="punt-panel", classes="panel"):
                yield Static("LOCAL / PUNT — to the gateway itself",
                             classes="panel-title sem-fg-accent")
                yield DataTable(id="punt-table", cursor_type="none")
        with Vertical(id="ifaces-panel", classes="panel"):
            yield Static("INTERFACES", id="ifaces-title",
                         classes="panel-title sem-fg-accent")
            yield DataTable(id="ifaces-table", cursor_type="row", zebra_stripes=True)
        with Vertical(id="nodes-panel", classes="panel"):
            yield Static(id="nodes-title", classes="panel-title sem-fg-accent")
            yield DataTable(id="nodes-table", cursor_type="row", zebra_stripes=True)
        with Horizontal(id="spark-row"):
            yield Static(id="spark-label")
            yield Sparkline(list(self._pps_history), id="pps-spark")

    def on_mount(self) -> None:
        self.query_one("#workers-table", DataTable).add_columns(
            "worker", "core", "vec/call", "clk/pkt", "calls/s", "utilization"
        )
        self.query_one("#drops-table", DataTable).add_columns("reason", "node", "/s", "total")
        self.query_one("#punt-table", DataTable).add_columns(
            "path", "→ kern pps", "← kern pps"
        )
        self.query_one("#ifaces-table", DataTable).add_columns(
            "interface", "vrf", "address", "link", "peer", "rx pps", "rx bps",
            "tx pps", "tx bps", "drop/s", "drops"
        )
        self.query_one("#nodes-table", DataTable).add_columns(
            "node", "calls/s", "vectors/s", "vec/call", "clk/pkt"
        )
        super().on_mount()

    def update_state(self, state: GatewayState) -> None:
        self._update_workers(state)
        self._update_drops(state)
        self._update_punt(state)
        self._update_interfaces(state)
        self._update_nodes(state)
        self._update_spark(state)

    def _update_punt(self, state: GatewayState) -> None:
        """Traffic addressed to the gateway itself and the exit it takes.

        Control-plane packets (BGP, BFD, ARP replies, ...) are dataplane
        traffic here: punts ride the linux-cp taps (VPP tx on a tap = toward
        kernel, rx = kernel-originated), echoes are answered by VPP's ping
        plugin, and local-path failures land in DROPS with a named reason.
        All read from counters VPP maintains anyway — zero datapath cost.
        """
        rows = []
        for i in state.interfaces:
            if not i.name.startswith("tap"):
                continue
            rows.append((
                Text(f"{i.name} ⇄ kernel", style_for(Sem.INFO)),
                Text(human_count(i.tx_pps)),
                Text(human_count(i.rx_pps)),
            ))
        echo_rate = sum(e.rate for e in state.errors if "echo repl" in e.reason)
        rows.append((
            Text("icmp echo (VPP answers)", style_for(Sem.IDLE)),
            Text(human_count(echo_rate)),
            Text("—", style_for(Sem.IDLE)),
        ))
        # Two families the operator should chase via the DROPS panel: drops
        # on the local/punt path itself, and steady-rate (periodic) drops
        # anywhere — counter granularity can't prove the latter were
        # gateway-destined, but periodicity alone earns attention.
        local_drop = sum(
            e.rate for e in state.errors
            if e.steady or e.node.startswith(("ip4-local", "ip4-punt", "punt"))
        )
        sem = Sem.WARN if local_drop > 0 else Sem.IDLE
        rows.append((
            Text("local-path/periodic drops → DROPS", style_for(sem)),
            Text(human_count(local_drop), style_for(sem)),
            Text("—", style_for(Sem.IDLE)),
        ))
        refill(self.query_one("#punt-table", DataTable), rows)

    def _update_workers(self, state: GatewayState) -> None:
        rows = []
        for w in state.workers:
            # Main (index 0) does control-plane housekeeping, not forwarding.
            # Show it anyway — dimmed when idle — so nobody wonders where it
            # went; if it ever starts seeing packets it renders like a worker.
            is_idle_main = w.worker_index == 0 and w.vectors_per_sec == 0
            dim = style_for(Sem.IDLE)
            vpc_sem = sem_for_vectors_per_call(w.vectors_per_call)
            util_sem = sem_for_worker_utilization(w.utilization)
            name = w.name or f"worker {w.worker_index}"
            if is_idle_main:
                name += " (control)"
            rows.append((
                Text(name, dim if is_idle_main else style_for(Sem.INFO)),
                Text(str(w.core_id) if w.core_id >= 0 else "?",
                     dim if is_idle_main else ""),
                Text("—" if is_idle_main else f"{w.vectors_per_call:6.1f}",
                     dim if is_idle_main else style_for(vpc_sem)),
                Text("—" if is_idle_main
                     else clk_per_pkt(w.clocks_per_packet, w.vectors_per_call),
                     dim if is_idle_main else ""),
                Text(human_count(w.calls_per_sec), dim if is_idle_main else ""),
                Text("no packet work" if is_idle_main
                     else f"{bar(w.utilization, 16)} {w.utilization * 100:4.1f}%",
                     dim if is_idle_main else style_for(util_sem)),
            ))
        refill(self.query_one("#workers-table", DataTable), rows)

    def _update_drops(self, state: GatewayState) -> None:
        total_sem = sem_for_drops(state.total_drops_rate)
        summary = Text()
        summary.append(f"{human_count(state.total_drops_rate)}/s ", style_for(total_sem))
        summary.append(f"(total {human_count(state.total_drops)})", style_for(Sem.IDLE))
        self.query_one("#drops-total", Static).update(summary)

        # Steady rows outrank raw rate: a constant-rate drop (▲) is a config
        # mismatch fingerprint and must not be pushed out by transient bursts
        # exactly when someone should see it (the dead-BFD lesson).
        errors = sorted(
            state.errors, key=lambda e: (e.steady, e.rate, e.count), reverse=True
        )[:6]
        rows = []
        for e in errors:
            sem = Sem.WARN if e.steady else sem_for_drops(e.rate)
            rows.append((
                Text(("▲ " if e.steady else "") + e.reason, style_for(sem)),
                Text(e.node, style_for(Sem.INFO)),
                Text(f"{e.rate:8.1f}", style_for(sem)),
                Text(human_count(e.count), style_for(Sem.IDLE)),
            ))
        refill(self.query_one("#drops-table", DataTable), rows)

    def _update_interfaces(self, state: GatewayState) -> None:
        pps_cut = _top_decile([i.rx_pps for i in state.interfaces]
                              + [i.tx_pps for i in state.interfaces])
        bps_cut = _top_decile([i.rx_bps for i in state.interfaces]
                              + [i.tx_bps for i in state.interfaces])
        # Peer liveness from the slow-poll snapshot: resolved neighbors per
        # interface, and interfaces some route is still gleaning out of.
        nbr_count: dict[str, int] = {}
        for nb in state.neighbors:
            nbr_count[nb.interface] = nbr_count.get(nb.interface, 0) + 1
        unresolved_ifs = {
            nh.interface
            for r in state.routes
            for nh in r.next_hops
            if nh.interface and not nh.special and not nh.resolved
        }
        title = Text("INTERFACES")
        title.append_text(self.vrf_suffix())
        self.query_one("#ifaces-title", Static).update(title)
        rows = []
        for i in state.interfaces:
            if not self.in_vrf(i.vrf):
                continue
            if i.link_up:
                link = Text("up", style_for(Sem.OK))
            elif not i.admin_up:
                link = Text("admin-down", style_for(Sem.IDLE))
            else:
                link = Text("DOWN", style_for(Sem.CRIT))
            peer_text, peer_sem = _peer_status(
                i.admin_up, i.link_up,
                nbr_count.get(i.name, 0), i.name in unresolved_ifs,
            )
            drop_rate = i.rx_drops_delta + i.tx_drops_delta
            drops_total = i.rx_drops + i.tx_drops
            rows.append((
                Text(i.name, style_for(Sem.INFO)),
                Text(i.vrf,
                     style_for(Sem.IDLE if i.vrf == "default" else Sem.ACCENT)),
                Text(", ".join(i.addresses) if i.addresses else "—",
                     style_for(Sem.PLAIN if i.addresses else Sem.IDLE)),
                link,
                Text(peer_text, style_for(peer_sem)),
                _rate_cell(i.rx_pps, human_pps(i.rx_pps), pps_cut),
                _rate_cell(i.rx_bps, human_bps(i.rx_bps), bps_cut),
                _rate_cell(i.tx_pps, human_pps(i.tx_pps), pps_cut),
                _rate_cell(i.tx_bps, human_bps(i.tx_bps), bps_cut),
                Text(f"{drop_rate:6.1f}", style_for(sem_for_drops(drop_rate))),
                Text(human_count(drops_total), style_for(sem_for_drops(drops_total))),
            ))
        refill(self.query_one("#ifaces-table", DataTable), rows)

    def _split_shown(self, name: str) -> bool:
        return self._split_all or name == self._expanded_node

    def _update_nodes(self, state: GatewayState) -> None:
        title = Text("TOP NODES BY CYCLES (active only) — ")
        if self._split_all:
            title.append("per-worker split: ALL", style_for(Sem.ACCENT))
            title.append("  (press w to collapse)", style_for(Sem.IDLE))
        else:
            title.append("Enter on a row: per-worker split, "
                         "w: split all nodes", style_for(Sem.IDLE))
        active = [n for n in state.nodes if n.active]
        if not state.nodes and state.system.connected:
            title.append(
                "  no per-node counters in the stats segment — enable with "
                "statseg { per-node-counters on } in startup.conf",
                style_for(Sem.WARN),
            )
        self.query_one("#nodes-title", Static).update(title)
        active.sort(key=lambda n: n.clocks_per_sec, reverse=True)
        worker_names = {w.worker_index: w.name for w in state.workers}
        rows: list[tuple[Text, ...]] = []
        for n in active[:12]:
            rows.append((
                Text(n.name, style_for(Sem.INFO)),
                Text(human_count(n.calls_per_sec)),
                Text(human_count(n.vectors_per_sec)),
                Text(f"{n.vectors_per_call:6.1f}",
                     style_for(sem_for_vectors_per_call(n.vectors_per_call))),
                Text(clk_per_pkt(n.clocks_per_packet, n.vectors_per_call)),
            ))
            if self._split_shown(n.name):
                rows.extend(self._worker_split_rows(n, worker_names))
        # Packet-input nodes that are polling but seeing no packets would
        # rank #1 here on pure idle-spin cycles, so they can't join the
        # ranking — but hiding dpdk-input entirely reads as a bug to
        # operators (same call as the dimmed vpp_main row). Pin them below.
        dim = style_for(Sem.IDLE)
        pollers = [
            n for n in state.nodes
            if n.name in TRACE_INPUT_NODES and not n.active and n.calls_per_sec > 0
        ]
        for n in sorted(pollers, key=lambda n: n.calls_per_sec, reverse=True):
            rows.append((
                Text(f"{n.name} (polling, no packets)", dim),
                Text(human_count(n.calls_per_sec), dim),
                Text("0", dim),
                Text("—", dim),
                Text("—", dim),
            ))
            if self._split_shown(n.name):
                rows.extend(self._worker_split_rows(n, worker_names))
        refill(self.query_one("#nodes-table", DataTable), rows)

    def _worker_split_rows(
        self, n: object, worker_names: dict[int, str]
    ) -> list[tuple[Text, ...]]:
        from ...model import NodeStats

        assert isinstance(n, NodeStats)
        rows: list[tuple[Text, ...]] = []
        dim = style_for(Sem.IDLE)
        for t, calls_ps in enumerate(n.calls_ps_per_worker):
            vectors_ps = (n.vectors_ps_per_worker[t]
                          if t < len(n.vectors_ps_per_worker) else 0.0)
            clocks_ps = (n.clocks_ps_per_worker[t]
                         if t < len(n.clocks_ps_per_worker) else 0.0)
            if calls_ps == 0 and vectors_ps == 0:
                continue  # this worker never runs the node (e.g. main)
            vpc = vectors_ps / calls_ps if calls_ps > 0 else 0.0
            cpp = clocks_ps / vectors_ps if vectors_ps > 0 else 0.0
            name = worker_names.get(t, f"thread-{t}")
            rows.append((
                Text(f"  └ {name}", dim),
                Text(human_count(calls_ps), dim),
                Text(human_count(vectors_ps), dim),
                Text(f"{vpc:6.1f}", style_for(sem_for_vectors_per_call(vpc))),
                Text(clk_per_pkt(cpp, vpc), dim),
            ))
        if not rows:
            rows.append((Text("  └ (no per-worker data yet)", dim),
                         Text("", dim), Text("", dim), Text("", dim), Text("", dim)))
        return rows

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id != "nodes-table":
            return
        table = event.data_table
        # The table is rebuilt on every refresh tick, so the clicked row's key
        # may already be stale by the time this handler runs. Fall back to the
        # cursor position (preserved across rebuilds); never crash on a click.
        try:
            cells = table.get_row(event.row_key)
        except RowDoesNotExist:
            try:
                cells = table.get_row_at(event.cursor_row)
            except RowDoesNotExist:
                return
        name = cells[0].plain.strip() if cells else ""
        if not name or name.startswith("└"):
            return
        # Pinned poller rows carry a " (polling, no packets)" suffix.
        name = name.split(" (")[0]
        self._expanded_node = "" if self._expanded_node == name else name
        self._update_nodes(self.gw_app.poller.state)

    def action_toggle_worker_split(self) -> None:
        self._split_all = not self._split_all
        self._update_nodes(self.gw_app.poller.state)

    def _update_spark(self, state: GatewayState) -> None:
        self._pps_history.append(state.total_rx_pps)
        label = Text("aggregate rx ", style_for(Sem.IDLE))
        label.append(human_pps(state.total_rx_pps), style_for(Sem.PLAIN))
        self.query_one("#spark-label", Static).update(label)
        self.query_one("#pps-spark", Sparkline).data = list(self._pps_history)
