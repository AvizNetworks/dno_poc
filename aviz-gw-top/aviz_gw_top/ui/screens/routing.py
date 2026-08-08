"""Screen 2 — Routing: FIB, adjacency state, neighbors, next-hop summary."""

from __future__ import annotations

import ipaddress
from collections import Counter
from typing import ClassVar

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import DataTable, Static

from ...model import GatewayState, Route
from ...theme import Sem, style_for
from ..format import human_count, human_duration
from ..widgets.tables import refill
from .base import BaseScreen


class RoutingScreen(BaseScreen):
    SCREEN_NAME: ClassVar[str] = "routing"
    FILTERABLE: ClassVar[bool] = True

    BINDINGS = [
        ("v", "cycle_vrf", "VRF"),
    ]

    DEFAULT_CSS = """
    RoutingScreen #routes-panel { height: 3fr; }
    RoutingScreen .row-bottom { height: 2fr; min-height: 9; }
    RoutingScreen #neighbors-panel { width: 3fr; }
    RoutingScreen #summary-panel { width: 2fr; }
    """

    def compose_body(self) -> ComposeResult:
        with Vertical(id="routes-panel", classes="panel"):
            yield Static(id="routes-title", classes="panel-title sem-fg-accent")
            yield DataTable(id="routes-table", cursor_type="row", zebra_stripes=True)
        with Horizontal(classes="row-bottom"):
            with Vertical(id="neighbors-panel", classes="panel"):
                yield Static("NEIGHBORS / ARP — incomplete means the route above it "
                             "is not usable yet", classes="panel-title sem-fg-accent")
                yield DataTable(id="neighbors-table", cursor_type="row", zebra_stripes=True)
            with Vertical(id="summary-panel", classes="panel"):
                yield Static("PREFIXES PER NEXT-HOP", classes="panel-title sem-fg-accent")
                yield DataTable(id="nexthop-table", cursor_type="none")

    def on_mount(self) -> None:
        self.query_one("#routes-table", DataTable).add_columns(
            "vrf", "prefix", "next-hop", "interface", "adjacency", "source",
            "packets", "bytes", "pps",
        )
        self.query_one("#neighbors-table", DataTable).add_columns(
            "vrf", "ip", "mac", "interface", "state", "age"
        )
        self.query_one("#nexthop-table", DataTable).add_columns("next-hop", "prefixes")
        super().on_mount()

    @staticmethod
    def _prefix_sort_key(route: Route) -> tuple[int, int, int]:
        """Sort like `show ip fib`: by network address, wider prefixes first.

        The dump order from VPP is internal hash order and means nothing;
        there is no stored "LPM order" — lookups use the mtrie directly.
        """
        try:
            net = ipaddress.ip_network(route.prefix, strict=False)
            return (int(net.network_address), net.prefixlen, 0)
        except ValueError:
            return (0, 0, 1)  # unparseable prefixes sink to the top, flagged

    def update_state(self, state: GatewayState) -> None:
        visible = [r for r in state.routes if self.in_vrf(r.vrf)]
        routes = sorted(
            (r for r in visible if self._route_matches(r)),
            key=lambda r: (r.vrf != "default", r.vrf, self._prefix_sort_key(r)),
        )
        title = Text("FIB — ")
        title.append(f"{len(visible)} routes", style_for(Sem.INFO))
        if self._vrf_selected is not None:
            title.append(f" (of {len(state.routes)} total)", style_for(Sem.IDLE))
        elif len(self._vrfs) > 1:
            title.append(f" in {len(self._vrfs)} VRFs", style_for(Sem.INFO))
        title.append_text(self.vrf_suffix())
        incomplete = sum(1 for r in visible if not r.resolved)
        if incomplete:
            title.append(f"  {incomplete} with unresolved adjacency", style_for(Sem.CRIT))
        if not state.per_route_counters_enabled:
            title.append("  (per-route counters not enabled)", style_for(Sem.IDLE))
        if self.filter_text:
            title.append(f"  filter: {self.filter_text} → {len(routes)}",
                         style_for(Sem.WARN))
        self.query_one("#routes-title", Static).update(title)

        rows = []
        for r in routes:
            hops = r.next_hops or ()
            nh_text = Text(", ".join(h.address or "(directly attached)" for h in hops)
                           or "—")
            if_text = Text(", ".join(dict.fromkeys(h.interface for h in hops if h.interface)),
                           style_for(Sem.INFO))
            if r.special:
                # Drop/local routes terminate here; no adjacency to resolve.
                adj = Text("—", style_for(Sem.IDLE))
            elif r.resolved:
                adj = Text("complete", style_for(Sem.OK))
            else:
                adj = Text("INCOMPLETE (ARP unresolved)", style_for(Sem.CRIT))
            if state.per_route_counters_enabled and r.packets is not None:
                pkts = Text(human_count(r.packets))
                byts = Text(human_count(r.bytes or 0))
                pps = Text(f"{r.pps:9.1f}",
                           style_for(Sem.IDLE if r.pps == 0 else Sem.PLAIN))
            else:
                pkts = Text("n/a", style_for(Sem.IDLE))
                byts = Text("n/a", style_for(Sem.IDLE))
                pps = Text("n/a", style_for(Sem.IDLE))
            rows.append((
                Text(r.vrf,
                     style_for(Sem.IDLE if r.vrf == "default" else Sem.ACCENT)),
                Text(r.prefix, style_for(Sem.INFO)),
                nh_text, if_text, adj,
                Text(r.source, style_for(Sem.IDLE)),
                pkts, byts, pps,
            ))
        refill(self.query_one("#routes-table", DataTable), rows)

        n_rows = []
        for n in state.neighbors:
            if not self.in_vrf(n.vrf):
                continue
            if not self.matches_filter(n.ip, n.mac, n.interface, n.state, n.vrf):
                continue
            if n.state == "incomplete":
                st = Text("INCOMPLETE", style_for(Sem.CRIT))
                mac = Text("(unresolved)", style_for(Sem.CRIT))
            else:
                st = Text(n.state, style_for(Sem.OK if n.state else Sem.IDLE))
                mac = Text(n.mac)
            n_rows.append((
                Text(n.vrf,
                     style_for(Sem.IDLE if n.vrf == "default" else Sem.ACCENT)),
                Text(n.ip, style_for(Sem.INFO)), mac,
                Text(n.interface, style_for(Sem.INFO)), st,
                Text(human_duration(n.age_seconds) if n.age_seconds else "—",
                     style_for(Sem.IDLE)),
            ))
        refill(self.query_one("#neighbors-table", DataTable), n_rows)

        # Counted per (vrf, address): the same next-hop IP in two tables is
        # two different adjacencies, not one.
        counts: Counter[tuple[str, str]] = Counter()
        for r in visible:
            for h in r.next_hops:
                # Real gateways only. Special paths carry no gateway even
                # when they show an address: "10.0.0.1 (local)" is the
                # interface's OWN address on a receive route, not a next-hop.
                if h.address and not h.special and not h.address.startswith("("):
                    counts[(r.vrf, h.address.split(" ")[0])] += 1
        nh_rows = []
        for (vrf, nh), c in counts.most_common(12):
            label = Text(nh, style_for(Sem.INFO))
            if self._vrf_selected is None and len(self._vrfs) > 1:
                label.append(f"  {vrf}",
                             style_for(Sem.IDLE if vrf == "default" else Sem.ACCENT))
            nh_rows.append((label, Text(str(c))))
        refill(self.query_one("#nexthop-table", DataTable), nh_rows)

    def _route_matches(self, r: Route) -> bool:
        return self.matches_filter(
            r.prefix,
            r.vrf,
            *(h.address for h in r.next_hops),
            *(h.interface for h in r.next_hops),
        )
