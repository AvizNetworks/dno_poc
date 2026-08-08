"""clk/pkt rendering: dash out poll-noise divisions.

Field finding: poll-mode input nodes (dpdk-input at ~9M empty polls/s) and
the workers running them accrue clocks with near-zero vectors, so a naive
clocks÷vectors prints 9-12 digit garbage that operators read as a problem.
"""

from __future__ import annotations

from aviz_gw_top.ui.format import clk_per_pkt


def test_poll_noise_renders_dash() -> None:
    # tap-input live: 0.9 vec/s over 9.1M calls/s -> vpc ~1e-7, cpp 761M.
    assert clk_per_pkt(761_481_186.0, 1e-7) == "—"


def test_idle_worker_renders_dash() -> None:
    assert clk_per_pkt(332_006_116.0, 0.0) == "—"


def test_real_packet_work_renders_number() -> None:
    assert clk_per_pkt(1206.0, 1.1).strip() == "1206"


def test_threshold_is_one_percent_fill() -> None:
    assert clk_per_pkt(5000.0, 0.009) == "—"
    assert clk_per_pkt(5000.0, 0.011).strip() == "5000"
