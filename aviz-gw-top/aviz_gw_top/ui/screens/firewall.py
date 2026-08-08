"""Screen 3 — Firewall: ACL rules in evaluation order with live hit counters."""

from __future__ import annotations

from typing import ClassVar

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.widgets import DataTable, Static

from ...model import GatewayState
from ...theme import Sem, style_for
from ..format import human_count, port_range
from ..widgets.tables import refill
from .base import BaseScreen


class FirewallScreen(BaseScreen):
    SCREEN_NAME: ClassVar[str] = "firewall"
    FILTERABLE: ClassVar[bool] = True

    BINDINGS = [
        ("v", "cycle_vrf", "VRF"),
    ]

    DEFAULT_CSS = """
    FirewallScreen #acl-summary { height: auto; max-height: 6; }
    FirewallScreen #rules-panel { height: 1fr; }
    """

    def compose_body(self) -> ComposeResult:
        with Vertical(id="acl-summary", classes="panel"):
            yield Static("FIREWALL (ACL)", classes="panel-title sem-fg-accent")
            yield Static(id="acl-totals")
            yield Static(id="acl-attachments")
        with Vertical(id="rules-panel", classes="panel"):
            yield Static(id="rules-title", classes="panel-title sem-fg-accent")
            yield DataTable(id="rules-table", cursor_type="row", zebra_stripes=True)

    def on_mount(self) -> None:
        self.query_one("#rules-table", DataTable).add_columns(
            "acl", "rule", "action", "proto", "source", "sport",
            "destination", "dport", "hits", "hits/s",
        )
        super().on_mount()

    def update_state(self, state: GatewayState) -> None:
        # An ACL belongs to the VRF(s) of the interfaces it is attached to.
        # Unattached ACLs have no VRF and only appear in the all-view.
        acls = [
            a for a in state.acls
            if self._vrf_selected is None
            or any(at.vrf == self._vrf_selected for at in a.attachments)
        ]
        permit_hits = deny_hits = 0
        dead = 0
        rows = []
        for acl in acls:
            for r in acl.rules:
                if r.is_permit:
                    permit_hits += r.hits
                else:
                    deny_hits += r.hits
                if r.hits == 0:
                    dead += 1
                if not self.matches_filter(
                    r.action, r.proto, r.src_prefix, r.dst_prefix,
                    str(acl.acl_index), acl.tag,
                ):
                    continue
                rows.append(self._rule_row(acl.acl_index, r))

        totals = Text("permitted ")
        totals.append(human_count(permit_hits), style_for(Sem.OK))
        totals.append("   denied ")
        totals.append(human_count(deny_hits), style_for(Sem.CRIT))
        totals.append(f"   zero-hit rules: {dead}",
                      style_for(Sem.WARN if dead else Sem.IDLE))
        self.query_one("#acl-totals", Static).update(totals)

        attach = Text()
        for acl in acls:
            attach.append(f"acl {acl.acl_index}", style_for(Sem.INFO))
            if acl.tag:
                attach.append(f" ({acl.tag})", style_for(Sem.IDLE))
            attach.append(" → ")
            shown = [a for a in acl.attachments if self.in_vrf(a.vrf)]
            attach.append(
                ", ".join(
                    f"{a.interface} [{a.direction}]"
                    + (f" {a.vrf}" if len(self._vrfs) > 1 and a.vrf != "default"
                       else "")
                    for a in shown
                )
                or "not attached",
                style_for(Sem.PLAIN if shown else Sem.WARN),
            )
            attach.append("   ")
        self.query_one("#acl-attachments", Static).update(attach)

        title = Text("RULES in evaluation order — ")
        title.append("zero-hit rules are dimmed (possible dead rules)",
                      style_for(Sem.IDLE))
        title.append_text(self.vrf_suffix())
        if self._vrf_selected is not None and any(
            len({a.vrf for a in acl.attachments}) > 1 for acl in acls
        ):
            # VPP hit counters are per rule, not per attachment: an ACL
            # shared across VRFs shows combined hits in every VRF view.
            title.append("  (shared ACL: hits include other VRFs)",
                         style_for(Sem.WARN))
        if self.filter_text:
            title.append(f"  filter: {self.filter_text}", style_for(Sem.WARN))
        self.query_one("#rules-title", Static).update(title)
        refill(self.query_one("#rules-table", DataTable), rows)

    def _rule_row(self, acl_index: int, r: object) -> tuple[Text, ...]:
        from ...model import AclRule

        assert isinstance(r, AclRule)
        if r.hits == 0:
            # Dead rule: dim the whole row so it stands apart from active ones.
            dim = style_for(Sem.IDLE)
            action = Text(r.action, dim)
            row_style = dim
        else:
            action = Text(r.action, style_for(Sem.OK if r.is_permit else Sem.CRIT))
            row_style = ""
        return (
            Text(str(acl_index), style_for(Sem.INFO)),
            Text(str(r.rule_index), style_for(Sem.INFO)),
            action,
            Text(r.proto, row_style),
            Text(r.src_prefix, row_style),
            Text(port_range(r.src_port_first, r.src_port_last), row_style),
            Text(r.dst_prefix, row_style),
            Text(port_range(r.dst_port_first, r.dst_port_last), row_style),
            Text(human_count(r.hits), row_style or "bold"),
            Text(f"{r.hit_rate:8.1f}", row_style),
        )
