"""Parser tests driven by checked-in sample CLI output (tests/fixtures/).

These fixtures are the contract for the most fragile part of the codebase:
when bumping TARGET_VPP_VERSION, capture fresh output from the new release,
update the fixtures, and make these tests pass again.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from aviz_gw_top.data import parsers
from aviz_gw_top.model import TraceRequest

FIXTURES = Path(__file__).parent / "fixtures"


def fixture(name: str) -> str:
    return (FIXTURES / name).read_text()


# -- show trace -----------------------------------------------------------------


@pytest.fixture(scope="module")
def traces() -> tuple:
    return parsers.parse_show_trace(fixture("show_trace.txt"))


def test_trace_packet_count(traces: tuple) -> None:
    assert len(traces) == 3


def test_trace_forward_path(traces: tuple) -> None:
    t = traces[0]
    assert t.packet_index == 1
    assert t.input_interface == "TenGigabitEthernet0/0/1"
    nodes = [s.node for s in t.steps]
    assert nodes == [
        "dpdk-input", "ethernet-input", "ip4-input", "acl-plugin-in-ip4-fa",
        "nat44-ed-in2out", "nat44-ed-in2out-slowpath", "ip4-lookup",
        "ip4-rewrite", "TenGigabitEthernet0/0/0-output",
        "TenGigabitEthernet0/0/0-tx",
    ]


def test_trace_acl_permit(traces: tuple) -> None:
    acl = next(s for s in traces[0].steps if s.node == "acl-plugin-in-ip4-fa")
    assert acl.outcome == "permit"
    assert "acl 0 rule 1" in acl.summary


def test_trace_nat_translation_extracted(traces: tuple) -> None:
    nat = next(s for s in traces[0].steps if s.node == "nat44-ed-in2out-slowpath")
    assert nat.outcome == "translate"
    assert "192.168.10.42:33000 -> 203.0.113.10:17001" in nat.summary


def test_trace_fib_lookup(traces: tuple) -> None:
    lookup = next(s for s in traces[0].steps if s.node == "ip4-lookup")
    assert lookup.outcome == "forward"
    assert lookup.summary.startswith("fib 0")


def test_trace_rewrite_and_tx(traces: tuple) -> None:
    rewrite = next(s for s in traces[0].steps if s.node == "ip4-rewrite")
    assert rewrite.outcome == "rewrite"
    tx = traces[0].steps[-1]
    assert tx.outcome == "forward"


def test_trace_acl_deny_packet(traces: tuple) -> None:
    t = traces[1]
    assert t.input_interface == "TenGigabitEthernet0/0/0"
    acl = next(s for s in t.steps if s.node == "acl-plugin-in-ip4-fa")
    assert acl.outcome == "deny"
    assert "acl 0 rule 3" in acl.summary
    drops = [s for s in t.steps if s.terminal]
    assert drops, "deny packet must contain a terminal drop step"


def test_trace_unknown_node_keeps_raw(traces: tuple) -> None:
    t = traces[2]
    unknown = t.steps[0]
    assert unknown.node == "some-future-plugin-node"
    assert unknown.recognized is False
    assert "must survive verbatim" in unknown.raw


# -- show trace: captured from a live v26.06 gateway (linux-cp punt + ARP) -------


@pytest.fixture(scope="module")
def live_traces() -> tuple:
    return parsers.parse_show_trace(fixture("show_trace_live_2606.txt"))


def test_live_trace_packet_count(live_traces: tuple) -> None:
    assert len(live_traces) == 2


def test_live_trace_punt_path_fully_recognized(live_traces: tuple) -> None:
    """BGP packet punted to FRR via linux-cp DVR/tap: every step classified."""
    t = live_traces[0]
    assert t.input_interface == "tenant0"
    assert [s.node for s in t.steps] == [
        "dpdk-input", "ethernet-input", "ip4-input-no-checksum", "ip4-lookup",
        "ip4-receive", "ip4-punt", "ip4-punt-redirect", "ip4-dvr-dpo",
        "ip4-dvr-reinject", "tap4098-output", "tap4098-tx",
    ]
    unrecognized = [s.node for s in t.steps if not s.recognized]
    assert unrecognized == [], f"raw-rendered steps: {unrecognized}"
    punt = next(s for s in t.steps if s.node == "ip4-punt")
    assert "control plane" in punt.summary
    assert t.steps[-1].outcome == "forward"  # leaves via the tap toward FRR


def test_live_trace_noise_lines_filtered(live_traces: tuple) -> None:
    last_step = live_traces[-1].steps[-1]
    assert "Limiting display" not in last_step.raw
    assert all("Limiting display" not in d for d in last_step.details)


def test_live_trace_arp_drop(live_traces: tuple) -> None:
    t = live_traces[1]
    assert t.input_interface == "tenant0"
    for node in ("arp-input", "linux-cp-arp-phy", "arp-reply"):
        step = next(s for s in t.steps if s.node == node)
        assert step.recognized and step.outcome == "info"
    drop = t.steps[-1]
    assert drop.terminal
    assert "not local to subnet" in drop.summary


def test_trace_empty_input() -> None:
    assert parsers.parse_show_trace("") == ()
    assert parsers.parse_show_trace("No packets in trace buffer") == ()


# -- show threads -----------------------------------------------------------------


def test_parse_show_threads() -> None:
    rows = parsers.parse_show_threads(fixture("show_threads.txt"))
    assert rows == ((0, "vpp_main", 1), (1, "vpp_wk_0", 2), (2, "vpp_wk_1", 3))


# -- show nat44 summary -------------------------------------------------------------


def test_parse_nat44_summary() -> None:
    sessions, max_sessions = parsers.parse_nat44_summary(
        fixture("show_nat44_summary.txt")
    )
    assert sessions == 51244
    assert max_sessions == 63000 * 2


def test_parse_nat44_summary_empty() -> None:
    assert parsers.parse_nat44_summary("") == (0, 0)


# -- show packet-generator (captured from a live 26.06 gateway) --------------------


def test_parse_pg_streams() -> None:
    streams = parsers.parse_pg_streams(fixture("show_packet_generator.txt"))
    assert streams == (
        ("demo-pps", False, 500.0),
        ("gwtop-traffic", True, 100000.0),
        ("unrated-stream", True, 0.0),  # no rate = line-rate: must read as 0
    )


def test_parse_pg_streams_empty() -> None:
    assert parsers.parse_pg_streams("") == ()
    assert parsers.parse_pg_streams("Name  Enabled  Count  Parameters\n") == ()


# -- pg stream construction ----------------------------------------------------------


def test_build_pg_stream_udp() -> None:
    req = TraceRequest(src_ip="10.0.0.1", dst_ip="10.0.0.2",
                       protocol="udp", src_port=1234, dst_port=53)
    text = parsers.build_pg_stream(req, burst=4)
    assert "name gwtop-validate" in text
    assert "limit 4" in text
    assert "UDP: 10.0.0.1 -> 10.0.0.2" in text
    assert "UDP: 1234 -> 53" in text


def test_build_pg_traffic_stream_windowed() -> None:
    # Continuous traffic is rate + a window limit: VPP 26.06's rate limiter
    # can escalate an unlimited stream to line rate (float->uword trapdoor),
    # so a bare `rate` with no `limit` must never be generated.
    req = TraceRequest(src_ip="120.60.0.5", dst_ip="10.60.0.10",
                       protocol="udp", src_port=5000, dst_port=5001,
                       ingress_interface="uplink0")
    text = parsers.build_pg_stream(req, burst=5000, pps=500,
                                   name=parsers.PG_TRAFFIC_NAME, size=1500)
    assert "name gwtop-traffic" in text
    assert "rate 500" in text
    assert "limit 5000" in text
    assert "size 1500-1500" in text
    assert "interface uplink0" in text


def test_build_pg_stream_icmp() -> None:
    req = TraceRequest(src_ip="10.0.0.1", dst_ip="10.0.0.2", protocol="icmp")
    text = parsers.build_pg_stream(req, burst=2)
    assert "ICMP: 10.0.0.1 -> 10.0.0.2" in text
    assert "echo_request" in text
    assert "1234" not in text


# -- af-packet rx fallback + hardware brief ---------------------------------

_AF_PACKET_TRACE = """\
------------------- Start of thread 0 vpp_main -------------------
Packet 1

00:00:41:648823: af-packet-input
  af_packet: hw_if_index 1 rx-queue 0 next-index 4
    tpacket3_hdr:
      status 0x20000001 len 98 snaplen 98 mac 66 net 80
00:00:41:648830: ethernet-input
  IP4: 02:fe:aa:bb:cc:01 -> 02:fe:aa:bb:cc:02
00:00:41:648834: ip4-input
  UDP: 192.168.100.2 -> 8.8.8.8
    tos 0x00, ttl 64, length 84, checksum 0x1234 dscp CS0 ecn NON_ECN
"""

_HW_BRIEF = """\
              Name                Idx   Link  Hardware
local0                             0    down  local0
host-lan-vpp                       1     up   host-lan-vpp
host-peer-vpp                      2     up   host-peer-vpp
loop1                              3     up   loop1
"""


def test_trace_af_packet_rx_falls_back_to_hw_marker() -> None:
    (trace,) = parsers.parse_show_trace(_AF_PACKET_TRACE)
    # af-packet-input names no interface; the parser must surface the
    # hardware index as a resolvable marker instead of losing it.
    assert trace.input_interface == "hw:1"


def test_parse_hardware_brief() -> None:
    mapping = parsers.parse_hardware_brief(_HW_BRIEF)
    assert mapping == {0: "local0", 1: "host-lan-vpp",
                       2: "host-peer-vpp", 3: "loop1"}


def test_dpdk_trace_rx_needs_no_hw_fallback(live_traces: tuple) -> None:
    # dpdk-style traces name the port directly; no marker may leak through.
    assert not any(t.input_interface.startswith("hw:") for t in live_traces)


def test_trace_worker_from_thread_sections(live_traces: tuple) -> None:
    # Every packet block sits under a "Start of thread N <name>" header;
    # the carrying worker must survive parsing.
    workers = {t.worker for t in live_traces}
    assert "" not in workers
    assert any(w.startswith("vpp_wk_") for w in workers)


# -- show interface rx-placement ---------------------------------------------


def test_parse_rx_placement_live() -> None:
    placements = parsers.parse_rx_placement(
        fixture("show_rx_placement_live_2606.txt"))
    assert len(placements) == 16
    by_worker: dict[str, int] = {}
    for p in placements:
        by_worker[p.worker_name] = by_worker.get(p.worker_name, 0) + 1
    # The real 2-vs-14 skew that motivated the Cores screen.
    assert by_worker == {"vpp_wk_0": 2, "vpp_wk_1": 14}
    first = placements[0]
    assert (first.thread_index, first.input_node, first.interface,
            first.queue_id, first.mode) == (1, "dpdk-input", "uplink0",
                                            0, "polling")
    tap = [p for p in placements if p.input_node == "tap-input"]
    assert len(tap) == 10 and all(p.worker_name == "vpp_wk_1" for p in tap)


def test_parse_rx_placement_empty() -> None:
    assert parsers.parse_rx_placement("") == ()
