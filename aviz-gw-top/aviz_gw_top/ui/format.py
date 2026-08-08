"""Human-readable formatting helpers shared by all screens."""

from __future__ import annotations

_UNITS = ("", "K", "M", "G", "T")


def human_count(value: float, precision: int = 1) -> str:
    """1234567 -> '1.2M'. Integers below 1000 render exactly."""
    v = float(value)
    for unit in _UNITS:
        if abs(v) < 1000.0:
            if unit == "" and v == int(v):
                return str(int(v))
            return f"{v:.{precision}f}{unit}"
        v /= 1000.0
    return f"{v:.{precision}f}P"


def human_pps(value: float) -> str:
    return f"{human_count(value)} pps" if value else "0 pps"


def human_bps(bits_per_sec: float) -> str:
    return f"{human_count(bits_per_sec)}b/s" if bits_per_sec else "0 b/s"


def human_duration(seconds: float) -> str:
    s = int(seconds)
    if s < 60:
        return f"{s}s"
    m, s = divmod(s, 60)
    if m < 60:
        return f"{m}m{s:02d}s"
    h, m = divmod(m, 60)
    if h < 24:
        return f"{h}h{m:02d}m"
    d, h = divmod(h, 24)
    return f"{d}d{h:02d}h"


def clk_per_pkt(clocks_per_packet: float, vectors_per_call: float) -> str:
    """clk/pkt cell text; '—' when the vector fill is poll noise.

    Poll-mode input nodes (and the workers running them) accrue clocks on
    every empty poll, so clocks÷vectors prints absurd 9-12 digit numbers
    when few packets flow. Below 1% vector fill the division measures the
    idle spin, not per-packet cost — render a dash instead.
    """
    if vectors_per_call < 0.01:
        return "—"
    return f"{clocks_per_packet:7.0f}"


def bar(fraction: float, width: int = 24) -> str:
    """Text utilization bar; readable with or without color."""
    fraction = max(0.0, min(1.0, fraction))
    filled = round(fraction * width)
    return "█" * filled + "░" * (width - filled)


def port_range(first: int, last: int) -> str:
    if first == 0 and last == 65535:
        return "any"
    if first == last:
        return str(first)
    return f"{first}-{last}"
