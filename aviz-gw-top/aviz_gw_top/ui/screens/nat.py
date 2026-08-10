"""Screen 4 — NAT: session-table utilization, churn rates, sessions, counters."""

from __future__ import annotations

from typing import ClassVar

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import DataTable, Static

from ...model import GatewayState
from ...theme import Sem, sem_for_nat_utilization, style_for
from ..format import bar, human_count, human_duration
from ..widgets.tables import refill
from .base import BaseScreen


class NatScreen(BaseScreen):
    SCREEN_NAME: ClassVar[str] = "nat"
    FILTERABLE: ClassVar[bool] = True

    BINDINGS = [
        ("v", "cycle_vrf", "VRF"),
    ]

    DEFAULT_CSS = """
    NatScreen #nat-top { height: 8; }
    NatScreen #util-panel { width: 3fr; }
    NatScreen #counters-panel { width: 2fr; }
    NatScreen #mappings-panel { height: auto; max-height: 8; }
    NatScreen #sessions-panel { height: 1fr; }
    """

    def compose_body(self) -> ComposeResult:
        with Horizontal(id="nat-top"):
            with Vertical(id="util-panel", classes="panel"):
                yield Static("SESSION TABLE — NAT is the dominant memory consumer; "
                             "watch this live", classes="panel-title sem-fg-accent")
                yield Static(id="util-bar")
                yield Static(id="churn")
            with Vertical(id="counters-panel", classes="panel"):
                yield Static("NAT COUNTERS", classes="panel-title sem-fg-accent")
                yield DataTable(id="nat-counters", cursor_type="none")
        with Vertical(id="mappings-panel", classes="panel"):
            yield Static(id="mappings-title", classes="panel-title sem-fg-accent")
            yield DataTable(id="mappings-table", cursor_type="none")
        with Vertical(id="sessions-panel", classes="panel"):
            yield Static(id="sessions-title", classes="panel-title sem-fg-accent")
            yield DataTable(id="sessions-table", cursor_type="row", zebra_stripes=True)

    def on_mount(self) -> None:
        self.query_one("#nat-counters", DataTable).add_columns("counter", "total", "/s")
        self.query_one("#mappings-table", DataTable).add_columns(
            "proto", "external", "local", "vrf", "tag"
        )
        self.query_one("#sessions-table", DataTable).add_columns(
            "proto", "vrf", "inside", "outside", "direction", "type",
            "idle", "expires in"
        )
        super().on_mount()

    def update_state(self, state: GatewayState) -> None:
        nat = state.nat
        util_widget = self.query_one("#util-bar", Static)
        if nat.max_sessions > 0:
            frac = nat.utilization
            sem = sem_for_nat_utilization(frac)
            t = Text()
            t.append(bar(frac, 40), style_for(sem))
            t.append(f"  {frac * 100:5.1f}%  ", style_for(sem))
            t.append(f"{human_count(nat.session_count)} / {human_count(nat.max_sessions)} "
                     "sessions")
            util_widget.update(t)
        else:
            util_widget.update(
                Text(f"{human_count(nat.session_count)} sessions "
                     "(configured maximum unknown)", style_for(Sem.WARN))
            )

        churn = Text("created ")
        churn.append(f"{nat.created_per_sec:7.1f}/s", style_for(Sem.OK))
        churn.append("   expired ")
        churn.append(f"{nat.expired_per_sec:7.1f}/s", style_for(Sem.IDLE))
        self.query_one("#churn", Static).update(churn)

        c_rows = []
        for name in sorted(nat.counters):
            value = nat.counters[name]
            rate = nat.counter_rates.get(name, 0.0)
            bad = name in ("no translation entry", "out of ports")
            sem = Sem.CRIT if bad and rate > 0 else (Sem.IDLE if value == 0 else Sem.PLAIN)
            c_rows.append((
                Text(name, style_for(Sem.CRIT if bad and rate > 0 else Sem.INFO)),
                Text(human_count(value), style_for(sem)),
                Text(f"{rate:9.1f}", style_for(sem)),
            ))
        refill(self.query_one("#nat-counters", DataTable), c_rows)

        # DNAT visibility: the configured port-forwards / 1:1 mappings.
        # Mappings and sessions both follow the app-global VRF view ("v"):
        # the vrf on both is the INSIDE/tenant table.
        mappings = [m for m in nat.static_mappings if self.in_vrf(m.vrf)]
        m_title = Text("STATIC MAPPINGS (DNAT) — ")
        if mappings:
            m_title.append(f"{len(mappings)} configured", style_for(Sem.INFO))
        elif nat.static_mappings:
            m_title.append("none in this VRF", style_for(Sem.IDLE))
        else:
            m_title.append("none configured — all traffic is dynamic SNAT",
                           style_for(Sem.IDLE))
        m_title.append_text(self.vrf_suffix())
        self.query_one("#mappings-title", Static).update(m_title)
        m_rows = []
        for m in mappings:
            if m.external_port:
                ext = f"{m.external_addr}:{m.external_port}"
                loc = f"{m.local_addr}:{m.local_port}"
            else:
                ext = f"{m.external_addr} (1:1)"
                loc = m.local_addr
            m_rows.append((
                Text(m.protocol),
                Text(ext, style_for(Sem.WARN)),
                Text(loc, style_for(Sem.INFO)),
                Text(m.vrf,
                     style_for(Sem.IDLE if m.vrf == "default" else Sem.ACCENT)),
                Text(m.tag or "—", style_for(Sem.IDLE)),
            ))
        refill(self.query_one("#mappings-table", DataTable), m_rows)

        # Session type: a session terminating on a static mapping's external
        # endpoint (or created out2in) is DNAT; everything else is dynamic
        # SNAT.
        dnat_exact = {(m.protocol, m.external_addr, m.external_port)
                      for m in nat.static_mappings if m.external_port}
        dnat_addrs = {m.external_addr
                      for m in nat.static_mappings if not m.external_port}

        def session_type(s: object) -> str:
            from ...model import NatSession
            assert isinstance(s, NatSession)
            # s.static (NAT_IS_STATIC session flag) is authoritative; the
            # endpoint matching below covers older dump messages without it.
            if (s.static
                    or s.direction == "out2in"
                    or (s.protocol, s.outside_addr, s.outside_port) in dnat_exact
                    or s.outside_addr in dnat_addrs):
                return "static"
            return "SNAT"

        sessions = [
            s for s in nat.sessions
            if self.in_vrf(s.vrf)
            and self.matches_filter(s.inside_addr, s.outside_addr, s.protocol,
                                    session_type(s), s.vrf)
        ]
        title = Text(f"SESSIONS (showing {len(sessions)} of "
                     f"{human_count(nat.session_count)})")
        title.append_text(self.vrf_suffix())
        if self.filter_text:
            title.append(f"  filter: {self.filter_text}", style_for(Sem.WARN))
        self.query_one("#sessions-title", Static).update(title)

        s_rows = []
        for s in sessions[:200]:
            kind = session_type(s)
            s_rows.append((
                Text(s.protocol),
                Text(s.vrf,
                     style_for(Sem.IDLE if s.vrf == "default" else Sem.ACCENT)),
                Text(f"{s.inside_addr}:{s.inside_port}", style_for(Sem.INFO)),
                Text(f"{s.outside_addr}:{s.outside_port}", style_for(Sem.WARN)),
                Text(s.direction, style_for(Sem.IDLE)),
                Text(kind,
                     style_for(Sem.ACCENT if kind == "static" else Sem.IDLE)),
                Text(human_duration(s.idle_seconds)),
                Text("stale", style_for(Sem.WARN)) if s.stale
                else Text(human_duration(s.expire_seconds), style_for(Sem.IDLE)),
            ))
        refill(self.query_one("#sessions-table", DataTable), s_rows)
