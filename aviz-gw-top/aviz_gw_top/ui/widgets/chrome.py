"""Global chrome shown on every screen: header line, tab strip, alert banner."""

from __future__ import annotations

from rich.text import Text
from textual.widgets import Static

from ...config import TARGET_VPP_VERSION
from ...model import GatewayState
from ...theme import Sem, style_for
from ..format import human_duration

SCREEN_TABS = (
    ("status", "1 Status"),
    ("routing", "2 Routing"),
    ("firewall", "3 Firewall"),
    ("nat", "4 NAT"),
    ("validation", "5 Validation"),
    ("cores", "6 Cores"),
)


class GwHeader(Static):
    """One-line system summary plus the screen tab strip."""

    def update_state(self, state: GatewayState, active_screen: str, paused: bool) -> None:
        sys = state.system
        line = Text()
        line.append(" Aviz Gateway ", style_for(Sem.ACCENT))
        line.append("aviz-gw-dp ", style_for(Sem.INFO))
        line.append(sys.version or "version unknown")
        line.append("  up ")
        line.append(human_duration(sys.uptime_seconds))
        line.append("  ")
        if sys.connected:
            line.append("● connected", style_for(Sem.OK))
        else:
            line.append("○ DISCONNECTED", style_for(Sem.CRIT))
        line.append(f"  workers {sys.worker_count}")
        if sys.mock:
            line.append("  [MOCK]", style_for(Sem.WARN))
        if paused:
            line.append("  ‖ PAUSED", style_for(Sem.WARN))

        tabs = Text("  ")
        for name, label in SCREEN_TABS:
            if name == active_screen:
                tabs.append(f" {label} ", style_for(Sem.ACCENT))
            else:
                tabs.append(f" {label} ", style_for(Sem.IDLE))
            tabs.append(" ")
        self.update(Text.assemble(line, "\n", tabs))


class AlertBanner(Static):
    """Disconnected / version-mismatch banner. Hidden when all is well."""

    def update_state(self, state: GatewayState) -> None:
        sys = state.system
        if not sys.connected:
            msg = " DISCONNECTED from aviz-gw-dp — retrying"
            if sys.last_error:
                msg += f"  ({sys.last_error})"
            self.update(Text(msg, style_for(Sem.CRIT)))
            self.display = True
        elif sys.version_mismatch:
            self.update(
                Text(
                    f" WARNING: running data plane reports '{sys.version}' but this tool "
                    f"targets VPP {TARGET_VPP_VERSION} — output formats may differ",
                    style_for(Sem.WARN),
                )
            )
            self.display = True
        else:
            self.display = False
