"""Textual application shell: navigation, bindings, screen registry."""

from __future__ import annotations

from textual.app import App
from textual.binding import Binding

from .. import theme
from ..data.base import DataSource
from ..data.poller import Poller
from .screens.cores import CoresScreen
from .screens.firewall import FirewallScreen
from .screens.nat import NatScreen
from .screens.routing import RoutingScreen
from .screens.status import StatusScreen
from .screens.validation import ValidationScreen
from .widgets.chrome import SCREEN_TABS

_BASE_CSS = """
Screen { layout: vertical; }
#gw-header { height: 2; padding: 0; }
#gw-banner { height: 1; }
#filter-box { height: 3; margin: 0 1; }

.panel { border: round $secondary; padding: 0 1; }
.panel-title { text-style: bold; height: 1; }

DataTable { height: 1fr; }
"""


class GwTopApp(App[None]):
    TITLE = "aviz-gw-top"
    CSS = _BASE_CSS + theme.textual_css()

    BINDINGS = [
        Binding("1", "goto('status')", "Status"),
        Binding("2", "goto('routing')", "Routing"),
        Binding("3", "goto('firewall')", "Firewall"),
        Binding("4", "goto('nat')", "NAT"),
        Binding("5", "goto('validation')", "Validate"),
        Binding("6", "goto('cores')", "Cores"),
        Binding("tab", "cycle(1)", "Next", priority=True),
        Binding("shift+tab", "cycle(-1)", "Prev", priority=True, show=False),
        Binding("p", "toggle_pause", "Pause"),
        Binding("slash", "filter", "Filter"),
        Binding("q", "quit", "Quit"),
    ]

    def __init__(self, source: DataSource, poller: Poller, allow_inject: bool) -> None:
        super().__init__()
        self.source = source
        self.poller = poller
        self.allow_inject = allow_inject
        # VRF view selection, shared by all screens: switching to screen 3
        # while looking at tenant-a keeps showing tenant-a. None = all.
        self.vrf_selected: str | None = None
        self._screen_order = [name for name, _ in SCREEN_TABS]

    def on_mount(self) -> None:
        for name, cls in (
            ("status", StatusScreen),
            ("routing", RoutingScreen),
            ("firewall", FirewallScreen),
            ("nat", NatScreen),
            ("validation", ValidationScreen),
            ("cores", CoresScreen),
        ):
            self.install_screen(cls(), name)
        self.push_screen("status")

    # -- navigation ------------------------------------------------------------

    def action_goto(self, name: str) -> None:
        if self.screen is not self.get_screen(name):
            self.switch_screen(name)

    def action_cycle(self, step: int) -> None:
        current = getattr(self.screen, "SCREEN_NAME", "status")
        try:
            idx = self._screen_order.index(current)
        except ValueError:
            idx = 0
        self.action_goto(self._screen_order[(idx + step) % len(self._screen_order)])

    def action_toggle_pause(self) -> None:
        paused = self.poller.toggle_pause()
        self.notify("refresh paused" if paused else "refresh resumed", timeout=2)

    def action_filter(self) -> None:
        screen = self.screen
        if hasattr(screen, "action_show_filter"):
            screen.action_show_filter()
