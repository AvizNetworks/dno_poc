"""Screen 5 — Validation: render a packet's node-by-node journey.

Two verbs only:
- Trace: enable packet trace briefly and render the journey of whatever is
  flowing through the gateway right now (always available, read-only-ish).
- Send (--allow-inject only): generate the packet defined in the form at a
  chosen rate via the packet generator, toggled on/off. The mode is always
  visible; nothing is ever sent silently.
"""

from __future__ import annotations

import ipaddress
from typing import ClassVar

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widgets import Button, DataTable, Input, Select, Static

from ...config import (
    PG_PACKET_SIZE,
    PG_PACKET_SIZE_MAX,
    TRACE_PACKET_COUNT,
    TRAFFIC_DURATION_MAX,
)
from ...model import GatewayState, PacketTrace, TraceRequest
from ...theme import Sem, sem_for_trace_outcome, style_for
from ..format import human_bps, human_count
from ..widgets.tables import refill
from .base import BaseScreen


class ValidationScreen(BaseScreen):
    SCREEN_NAME: ClassVar[str] = "validation"

    BINDINGS = [
        ("left_square_bracket", "prev_packet", "Prev packet"),
        ("right_square_bracket", "next_packet", "Next packet"),
        # Arrow keys as intuitive aliases. Not shown in the footer (the
        # bracket pair is), and form Inputs still get their cursor keys —
        # a focused widget always wins over a screen binding.
        Binding("left", "prev_packet", "Prev packet", show=False),
        Binding("right", "next_packet", "Next packet", show=False),
        ("w", "toggle_worker_split", "Splits"),
    ]

    DEFAULT_CSS = """
    ValidationScreen #v-mode { height: 1; margin: 0 1; }
    ValidationScreen #v-box { height: 11; border: round $secondary;
                              padding: 0 1; margin: 0 1; }
    ValidationScreen #v-labels-row { height: 1; }
    ValidationScreen #v-inject-row { height: 3; }
    ValidationScreen #v-buttons-row { height: 3; margin-top: 1; }
    ValidationScreen .v-col-ip { width: 20; }
    ValidationScreen .v-col-proto { width: 12; }
    ValidationScreen .v-col-port { width: 10; }
    ValidationScreen .v-col-iface { width: 24; }
    ValidationScreen .v-col-pps { width: 14; }
    ValidationScreen .v-col-size { width: 12; }
    ValidationScreen .v-col-win { width: 14; }
    ValidationScreen #v-buttons-row Button { margin-left: 1; }
    ValidationScreen #v-trace-sep { width: 3; margin-left: 2;
                                    content-align: center middle; height: 3; }
    ValidationScreen #v-traffic-label { margin-left: 2; width: 1fr;
                                        content-align: left middle; }
    ValidationScreen #v-body { height: 1fr; }
    ValidationScreen #v-pipeline { width: 3fr; border: round $secondary; padding: 0 1; }
    ValidationScreen #v-counters-panel { width: 2fr; border: round $secondary;
                                         padding: 0 1; }
    ValidationScreen .trace-step { height: auto; margin: 0 0 0 2; padding: 0 1;
                                   width: 60; }
    ValidationScreen .trace-arrow { height: 2; margin-left: 2; width: 60;
                                    text-align: center; }
    ValidationScreen #v-status { height: 1; margin: 0 1; }
    """

    def __init__(self) -> None:
        super().__init__()
        self._traces: tuple[PacketTrace, ...] = ()
        self._current = 0
        self._trace_running = False
        self._iface_options: tuple[tuple[str, str], ...] = ()  # (name, vrf)
        self._iface_vrfs: dict[str, str] = {}
        self._split_all = False  # "w": per-worker rows in LIVE NODE COUNTERS
        self._traffic_running = False
        self._traffic_pps = 0        # requested rate, for the runaway guard
        self._runaway_strikes = 0    # consecutive over-threshold windows

    def compose_body(self) -> ComposeResult:
        yield Static(id="v-mode")
        with Vertical(id="v-box"):
            yield Static("Send generates this packet on the gateway; Trace shows "
                         "the journey of whatever is flowing (sent or real).",
                         classes="sem-fg-idle")
            with Horizontal(id="v-labels-row"):
                yield Static("source ip", classes="v-col-ip sem-fg-info")
                yield Static("destination ip", classes="v-col-ip sem-fg-info")
                yield Static("protocol", classes="v-col-proto sem-fg-info")
                yield Static("src port", classes="v-col-port sem-fg-info")
                yield Static("dst port", classes="v-col-port sem-fg-info")
                yield Static("arrives on", classes="v-col-iface sem-fg-info")
                yield Static("rate (pps)", classes="v-col-pps sem-fg-info")
                yield Static("size (B)", classes="v-col-size sem-fg-info")
                yield Static("duration (s)", classes="v-col-win sem-fg-info")
            with Horizontal(id="v-inject-row"):
                yield Input(placeholder="src ip", value="192.168.10.42",
                            id="v-src", classes="v-col-ip")
                yield Input(placeholder="dst ip", value="8.8.8.8", id="v-dst",
                            classes="v-col-ip")
                yield Select(
                    [("udp", "udp"), ("tcp", "tcp"), ("icmp", "icmp")],
                    value="udp", allow_blank=False, id="v-proto",
                    classes="v-col-proto",
                )
                yield Input(placeholder="sport", value="33000", id="v-sport",
                            classes="v-col-port")
                yield Input(placeholder="dport", value="53", id="v-dport",
                            classes="v-col-port")
                yield Select([], allow_blank=True, prompt="auto",
                             id="v-iface", classes="v-col-iface")
                yield Input(placeholder="pps", value="500", id="v-pps",
                            classes="v-col-pps")
                yield Input(placeholder="bytes", value=str(PG_PACKET_SIZE),
                            id="v-size", classes="v-col-size")
                yield Input(placeholder="0 = manual", value="0",
                            id="v-window", classes="v-col-win",
                            tooltip="send for this many seconds, then stop "
                                    "by itself; 0 = until Stop is pressed")
            with Horizontal(id="v-buttons-row"):
                yield Button("▶ Send", id="v-send", variant="success")
                yield Static("│", id="v-trace-sep", classes="sem-fg-idle")
                yield Button("Trace", id="v-trace", variant="primary")
                yield Button("Clear", id="v-clear")
                yield Static(id="v-traffic-label")
        yield Static(id="v-status")
        with Horizontal(id="v-body"):
            yield VerticalScroll(id="v-pipeline")
            with Vertical(id="v-counters-panel"):
                yield Static(id="v-counters-title",
                             classes="panel-title sem-fg-accent")
                yield DataTable(id="v-counters", cursor_type="none")

    def on_mount(self) -> None:
        self.query_one("#v-counters", DataTable).add_columns(
            "node", "calls/s", "vectors/s", "vec/call"
        )
        allow = self.gw_app.allow_inject
        send = self.query_one("#v-send", Button)
        send.disabled = not allow
        if not allow:
            send.tooltip = "start with --allow-inject to enable Send"
        self._update_mode_banner()
        self._set_status("no trace yet — Trace shows live traffic; Send first to "
                         "generate the packet defined above", Sem.IDLE)
        self._update_traffic_preview()
        super().on_mount()

    def on_input_changed(self, event: Input.Changed) -> None:
        super().on_input_changed(event)
        if event.input.id in ("v-pps", "v-size", "v-window"):
            self._update_traffic_preview()

    def _update_traffic_preview(self) -> None:
        """Show what Send would generate, before it is pressed."""
        if self._traffic_running:
            return  # the live banner owns the label while sending
        label = self.query_one("#v-traffic-label", Static)
        try:
            pps = int(self.query_one("#v-pps", Input).value or "0")
            size = int(self.query_one("#v-size", Input).value or "0")
            duration = int(self.query_one("#v-window", Input).value or "0")
        except ValueError:
            pps = size = duration = 0
        if pps > 0 and size > 0:
            for_txt = f"for {duration} s" if duration > 0 else "until stopped"
            label.update(Text(
                f"Send would generate {human_count(pps)} pps × {size} B "
                f"≈ {human_bps(pps * size * 8)} {for_txt}",
                style_for(Sem.IDLE)))
        else:
            label.update(Text("not sending", style_for(Sem.IDLE)))

    def _update_mode_banner(self) -> None:
        if self.gw_app.allow_inject:
            self.query_one("#v-mode", Static).update(
                Text(" MODE: ACTIVE — Send is enabled (--allow-inject) and puts "
                     "real packets into the data plane.",
                     style_for(Sem.WARN))
            )
        else:
            self.query_one("#v-mode", Static).update(
                Text(" MODE: PASSIVE — observing real traffic only; Send is "
                     "disabled. Start with --allow-inject to enable it.",
                     style_for(Sem.OK))
            )

    # -- form / actions --------------------------------------------------------

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "v-send":
            if self._traffic_running:
                self._traffic_control(False, None, 0)
            else:
                self._start_traffic()
            return
        if self._trace_running:
            self.notify("a trace run is already in progress", severity="warning")
            return
        if event.button.id == "v-clear":
            self._clear_results()
        elif event.button.id == "v-trace":
            self._set_status("tracing the next packets through the gateway…",
                             Sem.WARN)
            self._run_trace()

    # -- continuous traffic (Start/Stop) ---------------------------------------

    def _form_int(self, widget_id: str, label: str, lo: int, hi: int) -> int | None:
        try:
            value = int(self.query_one(widget_id, Input).value or "0")
        except ValueError:
            value = 0
        if not lo <= value <= hi:
            self.notify(f"{label} must be {lo}..{hi}", severity="error")
            return None
        return value

    def _start_traffic(self) -> None:
        request = self._build_request()
        if request is None:
            return
        pps = self._form_int("#v-pps", "pps", 1, 100_000_000)
        size = self._form_int("#v-size", "size (B)", 64, PG_PACKET_SIZE_MAX)
        duration = self._form_int("#v-window", "duration (s)", 0,
                                  TRAFFIC_DURATION_MAX)
        if pps is None or size is None or duration is None:
            return
        self._traffic_control(True, request, pps, size, duration)

    @work(thread=True, exclusive=True, group="traffic")
    def _traffic_control(self, start: bool, request: TraceRequest | None,
                         pps: int, size: int = PG_PACKET_SIZE,
                         duration: int = 0) -> None:
        app = self.gw_app
        try:
            if start and request is not None:
                fut = app.poller.submit(
                    lambda: app.source.start_traffic(
                        request, pps, duration_seconds=duration, packet_size=size
                    )
                )
            else:
                fut = app.poller.submit(app.source.stop_traffic)
            fut.result(timeout=15)
            app.call_from_thread(self._traffic_done, start, request, pps, size,
                                 duration)
        except Exception as exc:
            app.call_from_thread(self._set_status, f"traffic control failed: {exc}",
                                 Sem.CRIT)

    def _traffic_done(self, started: bool, request: TraceRequest | None,
                      pps: int, size: int = PG_PACKET_SIZE,
                      duration: int = 0) -> None:
        self._traffic_running = started
        self._traffic_pps = pps if started else 0
        toggle = self.query_one("#v-send", Button)
        if started:
            toggle.label = "■ Stop sending"
            toggle.variant = "error"
        else:
            toggle.label = "▶ Send"
            toggle.variant = "success"
        label = self.query_one("#v-traffic-label", Static)
        if started and request is not None:
            iface = request.ingress_interface or "auto"
            vrf = self._iface_vrfs.get(iface, "")
            if vrf and vrf != "default":
                iface = f"{iface} ({vrf})"
            bandwidth = human_bps(pps * size * 8)
            for_txt = f"for {duration} s" if duration else "until stopped"
            label.update(Text(f"● sending {human_count(pps)} pps × {size} B "
                              f"≈ {bandwidth} {for_txt}  "
                              f"{request.src_ip} -> {request.dst_ip} on {iface}"
                              "  — press Trace to see its journey",
                              style_for(Sem.WARN)))
        else:
            self._update_traffic_preview()

    def _build_request(self) -> TraceRequest | None:
        src = self.query_one("#v-src", Input).value.strip()
        dst = self.query_one("#v-dst", Input).value.strip()
        try:
            ipaddress.ip_address(src)
            ipaddress.ip_address(dst)
        except ValueError:
            self.notify("source and destination must be valid IP addresses",
                        severity="error")
            return None
        proto = self.query_one("#v-proto", Select).value
        try:
            sport = int(self.query_one("#v-sport", Input).value or "0")
            dport = int(self.query_one("#v-dport", Input).value or "0")
        except ValueError:
            self.notify("ports must be integers", severity="error")
            return None
        iface_value = self.query_one("#v-iface", Select).value
        ingress = "" if iface_value in (None, Select.BLANK) else str(iface_value)
        return TraceRequest(
            src_ip=src, dst_ip=dst, protocol=str(proto),
            src_port=sport, dst_port=dport,
            ingress_interface=ingress,
        )

    @work(thread=True, exclusive=True)
    def _run_trace(self) -> None:
        """Runs on a worker thread; gateway I/O runs on the poller thread."""
        self._trace_running = True
        app = self.gw_app
        try:
            fut = app.poller.submit(
                lambda: app.source.capture_trace(TRACE_PACKET_COUNT)
            )
            traces = fut.result(timeout=30)
            app.call_from_thread(self._show_traces, traces)
        except Exception as exc:
            app.call_from_thread(self._set_status, f"trace failed: {exc}", Sem.CRIT)
        finally:
            self._trace_running = False

    def _set_status(self, message: str, sem: Sem) -> None:
        self.query_one("#v-status", Static).update(Text(f" {message}", style_for(sem)))

    def _clear_results(self) -> None:
        self._traces = ()
        self._current = 0
        self.query_one("#v-pipeline", VerticalScroll).remove_children()
        refill(self.query_one("#v-counters", DataTable), [])
        self._set_status("cleared — Trace shows live traffic; Send first to "
                         "generate the packet defined above", Sem.IDLE)

    # -- rendering ---------------------------------------------------------------

    def _show_traces(self, traces: tuple[PacketTrace, ...]) -> None:
        self._traces = traces
        self._current = 0
        if not traces:
            self._set_status("no packets captured — is traffic flowing?", Sem.WARN)
            return
        self._render_current()

    def action_prev_packet(self) -> None:
        if self._traces:
            self._current = (self._current - 1) % len(self._traces)
            self._render_current()

    def action_next_packet(self) -> None:
        if self._traces:
            self._current = (self._current + 1) % len(self._traces)
            self._render_current()

    def _render_current(self) -> None:
        trace = self._traces[self._current]
        origin = "injected" if trace.injected else "live capture"
        n = len(self._traces)
        on_worker = f", on {trace.worker}" if trace.worker else ""
        line = (
            f" [{style_for(Sem.INFO)}]packet {self._current + 1}/{n} "
            f"({origin}, rx {trace.input_interface or '?'}{on_worker})[/]"
        )
        if n > 1:
            # Clickable pager plus the key aliases, spelled out. "[ / ]"
            # alone confused users; keep it as a shortcut, not the only door.
            acc = style_for(Sem.ACCENT)
            line += (
                f"   [{acc} @click=screen.prev_packet]◀ prev[/]"
                f"  [{acc} @click=screen.next_packet]next ▶[/]"
                f"  [{style_for(Sem.IDLE)}](click, or keys ←/→ or \\[/])[/]"
            )
        self.query_one("#v-status", Static).update(line)
        pipeline = self.query_one("#v-pipeline", VerticalScroll)
        pipeline.remove_children()
        widgets: list[Static] = []
        for i, step in enumerate(trace.steps):
            if i > 0:
                widgets.append(Static("│\n▼", classes="trace-arrow sem-fg-idle"))
            sem = sem_for_trace_outcome(step.outcome) if step.recognized else Sem.IDLE
            widgets.append(
                Static(self._step_text(step), classes=f"trace-step sem-border-{sem.value}")
            )
            if step.terminal:
                # A drop is a real terminal node: end the rendered pipeline here.
                widgets.append(
                    Static(Text("✖ PACKET DROPPED — end of path", style_for(Sem.CRIT)),
                           classes="trace-arrow")
                )
                break
        else:
            widgets.append(
                Static(Text("● egress — packet left the gateway", style_for(Sem.OK)),
                       classes="trace-arrow")
            )
        pipeline.mount_all(widgets)
        self._update_counters(self.gw_app.poller.state)

    def _step_text(self, step: object) -> Text:
        from ...model import TraceStep

        assert isinstance(step, TraceStep)
        sem = sem_for_trace_outcome(step.outcome)
        out = Text()
        out.append(step.node, style_for(Sem.PLAIN) + " bold" if style_for(Sem.PLAIN)
                   else "bold")
        out.append(f"  [{step.outcome}]", style_for(sem))
        if not step.recognized:
            # Unrecognized node format: show the raw trace text, never drop it.
            out.append("  (unparsed)", style_for(Sem.WARN))
            raw_lines = step.raw.rstrip().splitlines()
            for line in raw_lines[:12]:
                out.append("\n" + line)
            if len(raw_lines) > 12:
                out.append(f"\n… +{len(raw_lines) - 12} more lines",
                           style_for(Sem.IDLE))
            return out
        if step.summary:
            out.append("\n" + step.summary, style_for(sem))
        # Real traces carry long detail blobs (dpdk mbuf flags etc.); keep the
        # block scannable and lead with the header-ish lines.
        details = self._select_details(step.details)
        for line in details[:6]:
            out.append("\n  " + line, style_for(Sem.INFO))
        if len(details) > 6:
            out.append(f"\n  … +{len(details) - 6} more lines", style_for(Sem.IDLE))
        return out

    @staticmethod
    def _select_details(details: tuple[str, ...]) -> list[str]:
        """Prefer protocol-header lines (IP4:/TCP:/ARP:...) over buffer noise."""
        headers = [
            d for d in details
            if (prefix := d.split(":", 1)[0]).isupper() and " " not in prefix
        ]
        return headers if headers else list(details)

    # -- live counters alongside the path -------------------------------------

    def update_state(self, state: GatewayState) -> None:
        self._update_iface_options(state)
        self._update_counters(state)
        self._check_timed_send_done()
        self._runaway_guard(state)

    def _check_timed_send_done(self) -> None:
        """Reset the Send toggle when a timed run finished on its own."""
        if not self._traffic_running or self.gw_app.source.traffic_active:
            return
        self._traffic_done(False, None, 0)
        self._set_status("timed send finished (duration reached)", Sem.OK)

    def _runaway_guard(self, state: GatewayState) -> None:
        """Auto-stop the stream if pg generates far more than requested.

        Observed in the field: a stream that should be rate-limited running
        at line rate (vec/call pinned at 256). Whatever the root cause, the
        tool must never keep an out-of-control generator alive.

        Also observed in the field: a FALSE alarm — the node counters can
        publish a one-window spike as pg-input wakes up (the pg stream's
        Count proved it was generating exactly the requested rate). So the
        guard requires (a) two consecutive over-threshold windows and (b) a
        second, independent signal: total interface rx (continuously updated
        counters) must also exceed the threshold. A real runaway floods rx;
        a counter artifact does not.
        """
        if not self._traffic_running or self._traffic_pps <= 0:
            self._runaway_strikes = 0
            return
        pg = next((n for n in state.nodes if n.name == "pg-input"), None)
        if pg is None:
            return
        # Generous ceiling: 10x requested plus headroom for burst catch-up.
        threshold = max(self._traffic_pps * 10, 50_000)
        if pg.vectors_per_sec > threshold and state.total_rx_pps > threshold:
            self._runaway_strikes += 1
        else:
            self._runaway_strikes = 0
            return
        if self._runaway_strikes < 2:
            return
        actual = pg.vectors_per_sec
        self._runaway_strikes = 0
        self._traffic_control(False, None, 0)
        self._set_status(
            f"RUNAWAY GUARD: pg generating ~{actual:,.0f} pps vs requested "
            f"{self._traffic_pps} — stream auto-stopped",
            Sem.CRIT,
        )

    def _update_iface_options(self, state: GatewayState) -> None:
        """Keep the injection-interface dropdown in sync with real ports."""
        ports = tuple(
            (i.name, i.vrf) for i in state.interfaces
            if i.admin_up and not i.name.startswith(("local", "loop", "pg", "tap"))
        )
        if ports == self._iface_options:
            return
        self._iface_options = ports
        self._iface_vrfs = dict(ports)
        select = self.query_one("#v-iface", Select)
        previous = select.value
        # The label names the VRF because "arrives on" is also the FIB the
        # test packet is looked up in; the value stays the bare interface
        # name that the pg stream needs.
        select.set_options(
            (name if vrf == "default" else f"{name} — {vrf}", name)
            for name, vrf in ports
        )
        names = tuple(n for n, _ in ports)
        if previous in names:
            select.value = previous

    def action_toggle_worker_split(self) -> None:
        self._split_all = not self._split_all
        self._update_counters(self.gw_app.poller.state)

    def _update_counters(self, state: GatewayState) -> None:
        title = Text("LIVE NODE COUNTERS (nodes on this path) — ")
        if self._split_all:
            title.append("per-worker: ON", style_for(Sem.ACCENT))
            title.append("  ◆ = carried this packet (w hides)",
                         style_for(Sem.IDLE))
        else:
            title.append("w: per-worker split", style_for(Sem.IDLE))
        self.query_one("#v-counters-title", Static).update(title)
        table = self.query_one("#v-counters", DataTable)
        if not self._traces:
            refill(table, [])
            return
        trace = self._traces[self._current]
        wanted = [s.node for s in trace.steps]
        by_name = {n.name: n for n in state.nodes}
        worker_names = {w.worker_index: w.name for w in state.workers}
        rows: list[tuple[Text, ...]] = []
        for name in wanted:
            n = by_name.get(name)
            if n is None:
                rows.append((Text(name, style_for(Sem.IDLE)),
                             Text("—"), Text("—"), Text("—")))
                continue
            rows.append((
                Text(name, style_for(Sem.INFO)),
                Text(human_count(n.calls_per_sec)),
                Text(human_count(n.vectors_per_sec)),
                Text(f"{n.vectors_per_call:5.1f}"),
            ))
            if self._split_all:
                rows.extend(self._counter_split_rows(n, worker_names, trace.worker))
        refill(table, rows)

    @staticmethod
    def _counter_split_rows(
        n: object, worker_names: dict[int, str], carrying: str
    ) -> list[tuple[Text, ...]]:
        """Per-worker sub-rows; the worker that carried the traced packet is
        highlighted — the point of the split is seeing whether that one is
        the loaded one."""
        from ...model import NodeStats

        assert isinstance(n, NodeStats)
        rows: list[tuple[Text, ...]] = []
        dim = style_for(Sem.IDLE)
        for t, calls_ps in enumerate(n.calls_ps_per_worker):
            vectors_ps = (n.vectors_ps_per_worker[t]
                          if t < len(n.vectors_ps_per_worker) else 0.0)
            if calls_ps == 0 and vectors_ps == 0:
                continue  # this worker never runs the node (e.g. main)
            vpc = vectors_ps / calls_ps if calls_ps > 0 else 0.0
            wname = worker_names.get(t, f"thread-{t}")
            style = style_for(Sem.ACCENT) if wname == carrying else dim
            marker = " ◆" if wname == carrying else ""
            rows.append((
                Text(f"  └ {wname}{marker}", style),
                Text(human_count(calls_ps), style),
                Text(human_count(vectors_ps), style),
                Text(f"{vpc:5.1f}", style),
            ))
        return rows
