"""Windowed-traffic re-arm: the poller must re-enable an exhausted stream.

Continuous Send is `rate pps` + `limit pps*WINDOW` re-armed each fast tick —
the only pg pattern that stays near the requested rate on VPP 26.06, whose
rate limiter can escalate an unlimited stream to line rate. Field-verified:
re-enabling a finished limited stream resets its count and re-runs it.
"""

from __future__ import annotations

from aviz_gw_top.data.vpp_source import VppDataSource

_SHOW_FMT = (
    "Name               Enabled        Count     Parameters\n"
    "gwtop-traffic        {enabled}          {count}     "
    "limit 10000, rate 1.00e3 pps, size 128-128, buffer-size 2048, worker 0,\n"
)


class _CliSpy:
    def __init__(self, show_reply: str) -> None:
        self.show_reply = show_reply
        self.commands: list[str] = []

    def __call__(self, command: str) -> str:
        self.commands.append(command)
        if command.startswith("show packet-generator"):
            return self.show_reply
        return ""


def _source(active: bool, show_reply: str,
            oneshot: bool = False) -> tuple[VppDataSource, _CliSpy]:
    src = VppDataSource.__new__(VppDataSource)
    src._traffic_active = active
    src._traffic_oneshot = oneshot
    spy = _CliSpy(show_reply)
    src._cli = spy  # type: ignore[method-assign]
    return src, spy


def test_exhausted_window_is_reenabled() -> None:
    src, spy = _source(True, _SHOW_FMT.format(enabled="No", count=10000))
    src._maybe_rearm_traffic()
    assert "packet-generator enable-stream gwtop-traffic" in spy.commands
    assert src.traffic_active


def test_timed_run_finishes_instead_of_rearming() -> None:
    # duration > 0: the exhausted stream means "done" — never re-enable.
    src, spy = _source(True, _SHOW_FMT.format(enabled="No", count=10000),
                       oneshot=True)
    src._maybe_rearm_traffic()
    assert not any("enable-stream" in c for c in spy.commands)
    assert not src.traffic_active


def test_running_window_is_left_alone() -> None:
    src, spy = _source(True, _SHOW_FMT.format(enabled="Yes", count=1215))
    src._maybe_rearm_traffic()
    assert not any("enable-stream" in c for c in spy.commands)
    assert src._traffic_active


def test_vanished_stream_deactivates() -> None:
    src, spy = _source(True, "Name               Enabled        Count\n")
    src._maybe_rearm_traffic()
    assert not any("enable-stream" in c for c in spy.commands)
    assert not src._traffic_active


def test_inactive_makes_no_cli_calls() -> None:
    src, spy = _source(False, "")
    src._maybe_rearm_traffic()
    assert spy.commands == []


def test_cli_failure_deactivates_instead_of_raising() -> None:
    src, _ = _source(True, "")
    def boom(command: str) -> str:
        raise RuntimeError("api gone")
    src._cli = boom  # type: ignore[method-assign]
    src._maybe_rearm_traffic()
    assert not src._traffic_active
