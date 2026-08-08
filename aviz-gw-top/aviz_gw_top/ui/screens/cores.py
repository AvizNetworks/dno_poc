"""Screen 6 — Cores: rx-queue placement and per-core traffic distribution.

Answers "which core polls which queues, and what traffic does each core
actually carry?" — the placement-skew view. Queue pinnings come from
`show interface rx-placement` (slow path); per-core traffic comes from the
per-thread /if/rx counters the fast path already reads.
"""

from __future__ import annotations

from typing import ClassVar

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.widgets import DataTable, Static

from ...model import GatewayState, RxQueuePlacement
from ...theme import Sem, style_for
from ..format import bar, human_count, human_pps
from ..widgets.tables import refill
from .base import BaseScreen

# One worker owning at least this share of queues or traffic (with >1
# worker present) is called out as a placement skew.
_SKEW_SHARE = 0.75


class CoresScreen(BaseScreen):
    SCREEN_NAME: ClassVar[str] = "cores"
    FILTERABLE: ClassVar[bool] = True

    BINDINGS = [
        ("v", "cycle_vrf", "VRF"),
    ]

    DEFAULT_CSS = """
    CoresScreen #placement-panel { height: 3fr; }
    CoresScreen #notes-panel { height: auto; max-height: 7; }
    """

    def compose_body(self) -> ComposeResult:
        with Vertical(id="placement-panel", classes="panel"):
            yield Static(id="placement-title", classes="panel-title sem-fg-accent")
            yield DataTable(id="placement-table", cursor_type="row",
                            zebra_stripes=True)
        with Vertical(id="notes-panel", classes="panel"):
            yield Static("PLACEMENT NOTES", classes="panel-title sem-fg-accent")
            yield Static(id="placement-notes")

    def on_mount(self) -> None:
        self.query_one("#placement-table", DataTable).add_columns(
            "worker / rx source", "core", "queues", "mode",
            "rx pps", "rx bps", "share of rx",
        )
        super().on_mount()

    def update_state(self, state: GatewayState) -> None:
        title = Text("RX QUEUE PLACEMENT — which core polls what, and what "
                     "it carries")
        title.append_text(self.vrf_suffix())
        if self.filter_text:
            title.append(f"  filter: {self.filter_text}", style_for(Sem.WARN))
        self.query_one("#placement-title", Static).update(title)

        by_worker: dict[str, list[RxQueuePlacement]] = {}
        for p in state.rx_placement:
            by_worker.setdefault(p.worker_name, []).append(p)
        workers_by_name = {w.name: w for w in state.workers}
        iface_by_name = {i.name: i for i in state.interfaces}
        total_rx = sum(i.rx_pps for i in state.interfaces) or 1.0

        rows: list[tuple[Text, ...]] = []
        worker_traffic: dict[str, float] = {}
        for wname in sorted(by_worker):
            placements = by_worker[wname]
            w = workers_by_name.get(wname)
            slot = w.worker_index if w else placements[0].thread_index
            # Traffic per (worker, interface): VPP publishes per-thread rx
            # counters per interface, never per queue.
            per_iface: dict[str, float] = {}
            for p in placements:
                i = iface_by_name.get(p.interface)
                if i and slot < len(i.rx_pps_per_worker):
                    per_iface[p.interface] = i.rx_pps_per_worker[slot]
            w_pps = sum(per_iface.values())
            worker_traffic[wname] = w_pps
            share = w_pps / total_rx
            rows.append((
                Text(wname, style_for(Sem.ACCENT)),
                Text(str(w.core_id) if w and w.core_id >= 0 else "?",
                     style_for(Sem.INFO)),
                Text(f"{len(placements)}"),
                Text(""),
                Text(human_count(w_pps)),
                Text(""),
                Text(f"{bar(share, 12)} {share * 100:4.1f}%",
                     style_for(Sem.WARN if share >= _SKEW_SHARE else Sem.PLAIN)),
            ))
            # Group the worker's queues per interface (rates exist only at
            # that granularity anyway).
            ifaces = dict.fromkeys(p.interface for p in placements)
            for iface in ifaces:
                ps = [p for p in placements if p.interface == iface]
                info = iface_by_name.get(iface)
                if not self._row_matches(wname, iface, ps):
                    continue
                if info is not None and not self.in_vrf(info.vrf):
                    continue
                pps = per_iface.get(iface, 0.0)
                bps = 0.0
                if info and info.rx_pps > 0:
                    # Apportion interface bytes by this worker's packet share.
                    bps = info.rx_bps * (pps / info.rx_pps)
                queues = " ".join(f"q{p.queue_id}" for p in ps)
                modes = ",".join(dict.fromkeys(p.mode for p in ps))
                dim_zero = style_for(Sem.IDLE) if pps == 0 else ""
                rows.append((
                    Text(f"  └ {iface}", style_for(Sem.INFO)),
                    Text(""),
                    Text(queues, dim_zero),
                    Text(modes, dim_zero),
                    Text(human_pps(pps), dim_zero),
                    Text(human_count(bps) if bps else "—", dim_zero),
                    Text(f"{pps / total_rx * 100:4.1f}%", dim_zero),
                ))
        if not state.rx_placement:
            rows.append((
                Text("rx-placement not available on this gateway",
                     style_for(Sem.IDLE)),
                Text(""), Text(""), Text(""), Text(""), Text(""), Text(""),
            ))
        refill(self.query_one("#placement-table", DataTable), rows)
        self._update_notes(state, by_worker, worker_traffic, total_rx)

    def _row_matches(self, wname: str, iface: str,
                     ps: list[RxQueuePlacement]) -> bool:
        return self.matches_filter(wname, iface, *(p.input_node for p in ps),
                                   *(p.mode for p in ps))

    def _update_notes(
        self,
        state: GatewayState,
        by_worker: dict[str, list[RxQueuePlacement]],
        worker_traffic: dict[str, float],
        total_rx: float,
    ) -> None:
        notes = Text()
        if len(by_worker) > 1:
            counts = {w: len(ps) for w, ps in by_worker.items()}
            total_q = sum(counts.values())
            top_w, top_n = max(counts.items(), key=lambda kv: kv[1])
            if top_n / total_q >= _SKEW_SHARE:
                notes.append("QUEUE SKEW: ", style_for(Sem.WARN))
                notes.append(
                    f"{top_w} polls {top_n} of {total_q} rx queues — consider "
                    f"`set interface rx-placement <if> queue <n> worker <w>`\n",
                    style_for(Sem.PLAIN),
                )
            top_w, top_pps = max(worker_traffic.items(),
                                 key=lambda kv: kv[1], default=("", 0.0))
            if top_pps / total_rx >= _SKEW_SHARE and top_pps > 0:
                notes.append("TRAFFIC SKEW: ", style_for(Sem.WARN))
                notes.append(
                    f"{top_w} carries {top_pps / total_rx * 100:.0f}% of rx "
                    "packets — the other cores are along for the ride\n",
                    style_for(Sem.PLAIN),
                )
        placed = {p.interface for p in state.rx_placement}
        silent = [
            i.name for i in state.interfaces
            if i.name in placed and i.link_up and i.rx_pps == 0
        ]
        if silent:
            notes.append("IDLE QUEUES: ", style_for(Sem.IDLE))
            notes.append(f"{', '.join(silent)} polled but receiving nothing\n",
                         style_for(Sem.IDLE))
        if not notes.plain:
            notes.append("placement looks balanced", style_for(Sem.OK))
        self.query_one("#placement-notes", Static).update(notes)
