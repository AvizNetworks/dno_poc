"""Rate computation tests, including the counter-reset (VPP restart) case."""

from __future__ import annotations

import time

from aviz_gw_top.data.mock_source import MockDataSource
from aviz_gw_top.data.poller import Poller, RateTracker


def test_first_sample_has_no_rate() -> None:
    rt = RateTracker()
    assert rt.rate("k", 1000, 10.0) == 0.0


def test_steady_rate() -> None:
    rt = RateTracker()
    rt.rate("k", 1000, 10.0)
    assert rt.rate("k", 1500, 11.0) == 500.0
    assert rt.rate("k", 2500, 13.0) == 500.0


def test_counter_reset_rebaselines_instead_of_negative() -> None:
    rt = RateTracker()
    rt.rate("k", 1_000_000, 10.0)
    assert rt.rate("k", 1_000_500, 11.0) == 500.0
    # VPP restarted: counter falls back to near zero. Must not go negative.
    assert rt.rate("k", 200, 12.0) == 0.0
    # And the new baseline is the post-reset value.
    assert rt.rate("k", 700, 13.0) == 500.0


def test_zero_and_negative_dt_guarded() -> None:
    rt = RateTracker()
    rt.rate("k", 100, 10.0)
    assert rt.rate("k", 200, 10.0) == 0.0
    assert rt.rate("k", 300, 9.0) == 0.0


def test_independent_keys() -> None:
    rt = RateTracker()
    rt.rate("a", 0, 0.0)
    rt.rate("b", 0, 0.0)
    assert rt.rate("a", 10, 1.0) == 10.0
    assert rt.rate("b", 90, 1.0) == 90.0


def test_slow_updating_counter_holds_rate_between_updates() -> None:
    """VPP refreshes /sys/node/* only every ~10 s. Rates must average over
    the counter's own update interval — no 0/0/.../10x sawtooth — and hold
    steady between updates."""
    rt = RateTracker()
    rt.rate("k", 0, 0.0)
    # Nine 1 Hz samples with no counter movement yet: no rate known.
    for t in range(1, 10):
        assert rt.rate("k", 0, float(t)) == 0.0
    # Collector publishes 10 s worth: rate is delta over 10 s, not over 1 s.
    assert rt.rate("k", 600, 10.0) == 60.0
    # Held steady on the quiet samples that follow.
    for t in range(11, 20):
        assert rt.rate("k", 600, float(t)) == 60.0
    # Next publish keeps averaging over the true window.
    assert rt.rate("k", 1200, 20.0) == 60.0


def test_stalled_counter_decays_to_zero() -> None:
    """When traffic genuinely stops, the held rate must drop to zero after
    ~2 of the counter's observed update intervals."""
    rt = RateTracker()
    rt.rate("k", 0, 0.0)
    assert rt.rate("k", 100, 1.0) == 100.0  # updates every 1 s
    assert rt.rate("k", 200, 2.0) == 100.0
    assert rt.rate("k", 200, 3.0) == 100.0  # within hold window
    assert rt.rate("k", 200, 10.0) == 0.0   # quiet too long: decayed
    assert rt.rate("k", 200, 11.0) == 0.0


def test_reset_clears_baselines() -> None:
    rt = RateTracker()
    rt.rate("k", 100, 1.0)
    rt.reset()
    assert rt.rate("k", 200, 2.0) == 0.0  # first sample again after reconnect


def test_poller_end_to_end_on_mock() -> None:
    """Poller publishes snapshots with computed rates from the mock source."""
    poller = Poller(MockDataSource(), fast_interval=0.05, slow_interval=0.1)
    poller.start()
    try:
        deadline = time.time() + 5.0
        while time.time() < deadline:
            state = poller.state
            if (
                state.system.connected
                and state.total_rx_pps > 0
                and state.routes
                and state.nat.session_count > 0
            ):
                break
            time.sleep(0.05)
        state = poller.state
        assert state.system.connected
        assert state.total_rx_pps > 0, "rates must be computed after two samples"
        assert any(w.vectors_per_call > 0 for w in state.workers)
        assert any(n.active for n in state.nodes)
        assert len(state.routes) > 0
        assert state.nat.max_sessions > 0
        # per-worker breakdown must be preserved, not collapsed
        busiest = max(state.nodes, key=lambda n: n.vectors)
        assert len(busiest.vectors_per_worker) >= 2
    finally:
        poller.stop()


def test_poller_submit_runs_on_poller_thread() -> None:
    source = MockDataSource()
    poller = Poller(source, fast_interval=0.05, slow_interval=0.1)
    poller.start()
    try:
        fut = poller.submit(lambda: source.capture_trace(2))
        traces = fut.result(timeout=5)
        assert traces
        assert all(t.steps for t in traces)
    finally:
        poller.stop()
