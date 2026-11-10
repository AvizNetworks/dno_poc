"""NAT session idle/expiry derivation.

Live-verified on VPP 26.06 (.40 gateway, 2026-08-09): the v3 session dump's
`last_heard` is a timestamp in VPP monotonic time (seconds since VPP start)
and `time_since_last_heard` is the idle time. The original decode displayed
last_heard as "age" and idle as "expires in" — both rows on screen summed to
VPP uptime, and 3h-old ICMP sessions (60s timeout) showed hours of remaining
life. Remaining lifetime must be derived: timeout - idle, floor 0, with
is_timed_out authoritative when present.
"""

from aviz_gw_top.data.vpp_source import NAT_DEFAULT_TIMEOUTS, _nat_session_expiry


def test_icmp_stale_session_from_field_data():
    # Screenshot row: icmp session idle 7h41m (27660s) — with the 60s icmp
    # timeout it expired hours ago and lingers only via lazy deletion.
    expire, stale = _nat_session_expiry("icmp", 27660.0, NAT_DEFAULT_TIMEOUTS, None)
    assert expire == 0.0
    assert stale is True


def test_active_tcp_session():
    expire, stale = _nat_session_expiry("tcp", 40.0, NAT_DEFAULT_TIMEOUTS, False)
    assert expire == 7400.0
    assert stale is False


def test_is_timed_out_flag_wins_over_derivation():
    # VPP says timed out even though idle < timeout (e.g. TCP transitory
    # state has a shorter timeout than the established one we assume).
    expire, stale = _nat_session_expiry("tcp", 300.0, NAT_DEFAULT_TIMEOUTS, True)
    assert expire == 0.0
    assert stale is True


def test_unknown_protocol_falls_back_to_udp_timeout():
    expire, stale = _nat_session_expiry("gre", 100.0, NAT_DEFAULT_TIMEOUTS, None)
    assert expire == 200.0  # udp timeout 300 - 100
    assert stale is False


def test_configured_timeouts_override_defaults():
    expire, stale = _nat_session_expiry("icmp", 30.0, {"icmp": 120.0}, None)
    assert expire == 90.0
    assert stale is False
