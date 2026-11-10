"""SteadyRateDetector — the ▲ periodic-drop fingerprint on screen 1.

Modeled on the 2026-08-10 field incident: unanswered BFD probes drew 1/s of
ICMP errors into a NAT drop counter for a day; the rate's *constancy* was
the diagnosable signal. The detector judges distinct rate values (not poll
ticks) because /err counters refresh ~10 s and RateTracker holds rates
between refreshes — repeats are one measurement, not steadiness evidence.
"""

from aviz_gw_top.data.poller import SteadyRateDetector


def _feed(det: SteadyRateDetector, key: str, rates: list[float]) -> bool:
    result = False
    for r in rates:
        result = det.update(key, r)
    return result


def test_constant_rate_flags_steady():
    det = SteadyRateDetector()
    # Six measurement windows of ~1/s with realistic float wobble.
    assert _feed(det, "k", [1.0, 0.98, 1.02, 0.99, 1.01, 1.0]) is True


def test_held_rate_repeats_do_not_count_as_windows():
    det = SteadyRateDetector()
    # RateTracker holds 1.0 across ticks: repeats collapse to ONE measurement.
    assert _feed(det, "k", [1.0] * 20) is False


def test_bursty_rate_not_steady():
    det = SteadyRateDetector()
    assert _feed(det, "k", [5.0, 0.4, 12.0, 2.2, 9.0, 0.7]) is False


def test_needs_full_window():
    det = SteadyRateDetector()
    assert _feed(det, "k", [1.0, 0.99, 1.01]) is False


def test_going_quiet_clears_history():
    det = SteadyRateDetector()
    assert _feed(det, "k", [1.0, 0.98, 1.02, 0.99, 1.01, 1.0]) is True
    assert det.update("k", 0.0) is False
    # Must re-earn the flag from scratch after silence.
    assert _feed(det, "k", [1.0, 0.98, 1.02]) is False


def test_keys_are_independent():
    det = SteadyRateDetector()
    _feed(det, "a", [1.0, 0.98, 1.02, 0.99, 1.01])
    assert det.update("b", 1.0) is False
    assert det.update("a", 1.0) is True


def test_near_zero_drift_ignored():
    det = SteadyRateDetector()
    assert _feed(det, "k", [0.001, 0.0011, 0.0009, 0.001, 0.0012, 0.001]) is False
