"""Base screen: global chrome, snapshot-driven refresh, table filtering."""

from __future__ import annotations

from typing import TYPE_CHECKING, ClassVar

from rich.text import Text
from textual.app import ComposeResult
from textual.screen import Screen
from textual.widgets import Footer, Input

from ...model import GatewayState
from ...theme import Sem, style_for
from ..widgets.chrome import AlertBanner, GwHeader

if TYPE_CHECKING:
    from ..app import GwTopApp


class BaseScreen(Screen[None]):
    """Chrome + refresh plumbing shared by all five screens.

    Subclasses implement compose_body() and update_state(). The screen polls
    the poller's snapshot version a few times a second and re-renders only
    when a new snapshot was published — the UI never touches gateway I/O.
    """

    SCREEN_NAME: ClassVar[str] = ""
    FILTERABLE: ClassVar[bool] = False
    # Don't auto-focus the first widget: a focused Input would swallow the
    # number-key navigation. Tables/inputs are focused explicitly (click, /).
    # "" disables auto-focus; None would inherit the App default instead.
    AUTO_FOCUS: ClassVar[str | None] = ""

    def __init__(self) -> None:
        super().__init__()
        self._seen_version = -1
        self.filter_text = ""
        # The VRF list is derived from the FIB each tick (routes are the
        # authority on which tables exist). The *selection* lives on the app
        # (see _vrf_selected) so it follows the user across screens.
        self._vrfs: list[str] = []

    # VRF view selection: None = all tables; else one table name. App-global
    # on purpose — cycle to tenant-a on Routing, and Status/Firewall show
    # tenant-a too.
    @property
    def _vrf_selected(self) -> str | None:
        return self.gw_app.vrf_selected

    @_vrf_selected.setter
    def _vrf_selected(self, value: str | None) -> None:
        self.gw_app.vrf_selected = value

    @property
    def gw_app(self) -> GwTopApp:
        from ..app import GwTopApp

        app = self.app
        assert isinstance(app, GwTopApp)
        return app

    def compose(self) -> ComposeResult:
        yield GwHeader(id="gw-header")
        yield AlertBanner(id="gw-banner")
        if self.FILTERABLE:
            yield Input(placeholder="filter… (Esc to clear)", id="filter-box")
        yield from self.compose_body()
        yield Footer()

    def compose_body(self) -> ComposeResult:
        raise NotImplementedError

    def update_state(self, state: GatewayState) -> None:
        raise NotImplementedError

    def on_mount(self) -> None:
        self.query_one("#gw-banner", AlertBanner).display = False
        if self.FILTERABLE:
            self.query_one("#filter-box", Input).display = False
        self.set_interval(0.4, self._tick)
        self._tick(force=True)

    def on_screen_resume(self) -> None:
        self._tick(force=True)

    def _tick(self, force: bool = False) -> None:
        poller = self.gw_app.poller
        if not force and poller.version == self._seen_version:
            return
        self._seen_version = poller.version
        state = poller.state
        # Default VRF first, then other tables alphabetically.
        self._vrfs = sorted({r.vrf for r in state.routes},
                            key=lambda v: (v != "default", v))
        if self._vrf_selected is not None and self._vrf_selected not in self._vrfs:
            self._vrf_selected = None  # selected table vanished: back to all
        self.query_one("#gw-header", GwHeader).update_state(
            state, self.SCREEN_NAME, poller.paused
        )
        self.query_one("#gw-banner", AlertBanner).update_state(state)
        self.update_state(state)

    # -- VRF view ("v" on screens that bind it) --------------------------------

    def action_cycle_vrf(self) -> None:
        if len(self._vrfs) <= 1:
            return  # single-table gateway: nothing to cycle through
        order: list[str | None] = [None, *self._vrfs]
        idx = order.index(self._vrf_selected) if self._vrf_selected in order else 0
        self._vrf_selected = order[(idx + 1) % len(order)]
        self._tick(force=True)

    def in_vrf(self, vrf: str) -> bool:
        """True when the row belongs in the current VRF view."""
        return self._vrf_selected is None or vrf == self._vrf_selected

    def vrf_suffix(self) -> Text:
        """Panel-title fragment naming the VRF view; empty on single-table."""
        t = Text()
        if len(self._vrfs) <= 1:
            return t
        if self._vrf_selected is None:
            t.append("  vrf: all", style_for(Sem.IDLE))
        else:
            t.append(f"  vrf: {self._vrf_selected}", style_for(Sem.ACCENT))
        t.append("  press v for next VRF", style_for(Sem.IDLE))
        return t

    # -- filtering ("/") -----------------------------------------------------

    def action_show_filter(self) -> None:
        if not self.FILTERABLE:
            return
        box = self.query_one("#filter-box", Input)
        box.display = True
        box.focus()

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "filter-box":
            self.filter_text = event.value.strip().lower()
            self._tick(force=True)

    def on_key(self, event: object) -> None:
        # Esc while filtering: clear and hide the filter box.
        from textual import events

        if isinstance(event, events.Key) and event.key == "escape" and self.FILTERABLE:
            box = self.query_one("#filter-box", Input)
            if box.display:
                box.value = ""
                box.display = False
                self.filter_text = ""
                self.set_focus(None)
                self._tick(force=True)

    def matches_filter(self, *fields: str) -> bool:
        if not self.filter_text:
            return True
        hay = " ".join(fields).lower()
        return self.filter_text in hay
