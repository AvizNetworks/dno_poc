"""MockDataSource: plausible, animated fake gateway data. No VPP required.

Counters are cumulative and monotonic, advanced by time-varying rates each
sample, so the poller's rate/reset logic runs the exact same code path as
against a live gateway. The whole UI is developable and demoable on this.
"""

from __future__ import annotations

import math
import random
import time
from dataclasses import dataclass, field

from ..config import TARGET_VPP_VERSION
from ..model import (
    AclAttachment,
    AclRule,
    AclSet,
    ErrorCounter,
    InterfaceStats,
    NatSession,
    NatState,
    NatStaticMapping,
    Neighbor,
    NodeStats,
    PacketTrace,
    Route,
    RouteNextHop,
    RxQueuePlacement,
    SystemInfo,
    TraceRequest,
    TraceStep,
)
from .base import (
    NAT_COUNTER_CREATED,
    NAT_COUNTER_EXPIRED,
    DataSource,
    FastSample,
    RawWorkerSample,
    SlowSample,
)

_WORKERS = 2  # worker threads (not counting main)


@dataclass
class _NodeCtr:
    """Per-worker cumulative counters (slot 0 = main)."""

    calls: list[float] = field(default_factory=lambda: [0.0] * (_WORKERS + 1))
    clocks: list[float] = field(default_factory=lambda: [0.0] * (_WORKERS + 1))
    vectors: list[float] = field(default_factory=lambda: [0.0] * (_WORKERS + 1))

# (name, base pps, avg packet bytes)
_IFACES = (
    ("TenGigabitEthernet0/0/0", 380_000.0, 780),   # uplink
    ("TenGigabitEthernet0/0/1", 355_000.0, 640),   # downlink
    ("TenGigabitEthernet0/0/1.101", 12_000.0, 500),  # tenant-a sub-interface
    ("tap0", 40.0, 120),                            # linux-cp punt to FRR/BGP
    ("loop0", 0.0, 0),
)

# An interface is bound to exactly one IPv4 table; unlisted = default.
_IFACE_VRFS = {"TenGigabitEthernet0/0/1.101": "tenant-a"}

# (node name, vectors per input packet share, clocks per packet)
_NODES = (
    ("dpdk-input", 1.00, 68.0),
    ("ethernet-input", 1.00, 24.0),
    ("ip4-input", 0.99, 30.0),
    ("acl-plugin-in-ip4-fa", 0.99, 95.0),
    ("nat44-ed-in2out", 0.55, 160.0),
    ("nat44-ed-out2in", 0.43, 150.0),
    ("ip4-lookup", 0.98, 55.0),
    ("ip4-rewrite", 0.97, 40.0),
    ("interface-output", 0.97, 18.0),
    ("TenGigabitEthernet0/0/0-tx", 0.52, 45.0),
    ("TenGigabitEthernet0/0/1-tx", 0.45, 45.0),
    ("linux-cp-punt", 0.0001, 210.0),
    ("error-drop", 0.006, 12.0),
    ("ip4-icmp-error", 0.0, 0.0),      # registered but idle — must not show up
    ("ip6-input", 0.0, 0.0),           # in "top nodes"
)

_ERRORS = (
    ("acl-plugin-in-ip4-fa", "deny packets", 210.0),
    ("ip4-input", "ip4 ttl <= 1", 2.0),
    ("nat44-ed-out2in", "no translation entry", 14.0),
    ("nat44-ed-in2out", "out of ports", 0.15),
    ("ethernet-input", "unknown ethernet type", 0.4),
    ("ip4-lookup", "ip4 no route", 1.2),
    ("ip4-icmp-input", "echo replies sent", 0.3),
)

# Advanced at EXACTLY rate*dt (no load/jitter): demos the steady-rate (▲)
# detection — modeled on the field incident where 1/s ICMP port-unreachables
# (peers answering unanswered BFD probes) ticked the NAT drop counter for a
# day before anyone looked.
_STEADY_ERRORS = (
    ("nat44-ed-out2in-slowpath", "unsupported ICMP type", 1.0),
)


class MockDataSource(DataSource):
    def __init__(self, seed: int = 7) -> None:
        self._rng = random.Random(seed)
        self._start = time.time()
        self._connected = False
        # Cumulative counter state, advanced on each fast sample.
        self._last_advance = self._start
        self._if_counters = {
            name: {"rxp": 0.0, "rxb": 0.0, "txp": 0.0, "txb": 0.0, "rxd": 0.0, "txd": 0.0}
            for name, _, _ in _IFACES
        }
        self._node_counters = {name: _NodeCtr() for name, _, _ in _NODES}
        self._err_counters = {(n, r): 0.0 for n, r, _ in _ERRORS + _STEADY_ERRORS}
        self._nat_created = 0.0
        self._nat_expired = 0.0
        self._nat_sessions: list[NatSession] = []
        self._acl_hits = [1_500_000.0, 920_000.0, 0.0, 84_000.0, 460_000.0,
                          64_000.0, 1_200.0]
        self._traffic_pps = 0.0        # simulated Start/Stop traffic stream
        self._traffic_iface = ""
        self._traffic_until = 0.0      # 0 = continuous; else auto-stop time

    # -- DataSource ----------------------------------------------------------

    @property
    def name(self) -> str:
        return "mock"

    def connect(self) -> SystemInfo:
        self._connected = True
        return self._system_info()

    def disconnect(self) -> None:
        self._connected = False

    def _system_info(self) -> SystemInfo:
        return SystemInfo(
            version=f"{TARGET_VPP_VERSION}-release",
            version_mismatch=False,
            uptime_seconds=time.time() - self._start + 4 * 3600,
            worker_count=_WORKERS,
            connected=self._connected,
            mock=True,
        )

    # A slow sinusoid so throughput visibly breathes over ~2 minutes.
    def _load_factor(self, now: float) -> float:
        return 0.75 + 0.25 * math.sin((now - self._start) / 20.0)

    def _advance(self) -> None:
        now = time.time()
        dt = max(0.0, now - self._last_advance)
        self._last_advance = now
        if dt == 0:
            return
        load = self._load_factor(now)
        jitter = self._rng.uniform(0.97, 1.03)

        total_pps = 0.0
        for name, base_pps, pkt_bytes in _IFACES:
            pps = base_pps * load * jitter
            if self._traffic_pps and name == (self._traffic_iface or _IFACES[0][0]):
                pps += self._traffic_pps
                pkt_bytes = pkt_bytes or 128
            total_pps += pps
            c = self._if_counters[name]
            c["rxp"] += pps * dt
            c["rxb"] += pps * pkt_bytes * dt
            c["txp"] += pps * 0.96 * dt
            c["txb"] += pps * 0.96 * pkt_bytes * dt
            # Drops appear when load pushes past ~0.92 (simulated saturation).
            if load > 0.92 and base_pps > 0:
                c["rxd"] += pps * 0.002 * dt

        for name, share, cpp in _NODES:
            n = self._node_counters[name]
            node_pps = total_pps * share
            if node_pps <= 0:
                continue
            # Vector size grows with load: healthy ~8, saturated pushes higher.
            vpc = min(256.0, 6.0 + 120.0 * max(0.0, load - 0.72) ** 2 * 40)
            calls = node_pps / max(vpc, 1.0)
            # Split across workers with deliberate mild RSS asymmetry.
            splits = (0.0, 0.58, 0.42) if share > 0.001 else (1.0, 0.0, 0.0)
            for w, frac in enumerate(splits):
                n.calls[w] += calls * frac * dt
                n.clocks[w] += node_pps * cpp * frac * dt
                n.vectors[w] += node_pps * frac * dt

        for node, reason, rate in _ERRORS:
            burst = self._rng.uniform(0.5, 1.5)
            self._err_counters[(node, reason)] += rate * load * burst * dt
        for node, reason, rate in _STEADY_ERRORS:
            self._err_counters[(node, reason)] += rate * dt

        self._advance_nat(dt, load)

    def _advance_nat(self, dt: float, load: float) -> None:
        created = 90.0 * load * dt
        expired = 85.0 * load * dt
        self._nat_created += created
        self._nat_expired += expired
        target = int(38_000 + 18_000 * load)
        # Keep a small displayable sample list; session_count is synthetic.
        while len(self._nat_sessions) < 60:
            self._nat_sessions.append(self._random_session())
        if self._rng.random() < 0.3 and self._nat_sessions:
            self._nat_sessions.pop(self._rng.randrange(len(self._nat_sessions)))
            self._nat_sessions.append(self._random_session())
        self._nat_target = target

    def _random_session(self) -> NatSession:
        proto = self._rng.choice(("tcp", "tcp", "tcp", "udp", "icmp"))
        return NatSession(
            inside_addr=f"192.168.{self._rng.randint(10, 12)}.{self._rng.randint(2, 250)}",
            inside_port=self._rng.randint(1024, 65000),
            outside_addr="203.0.113.10",
            outside_port=self._rng.randint(1024, 65000),
            protocol=proto,
            direction="in2out",
            idle_seconds=self._rng.uniform(1, 600),
            expire_seconds=self._rng.uniform(5, 7200),
        )

    def sample_fast(self) -> FastSample:
        self._advance()
        now = time.time()
        interfaces = []
        for name, _base_pps, _ in _IFACES:
            c = self._if_counters[name]
            idx = [n for n, _, _ in _IFACES].index(name)
            rxp = int(c["rxp"])
            interfaces.append(
                InterfaceStats(
                    name=name,
                    sw_if_index=idx + 1,
                    admin_up=name != "loop0",
                    link_up=name not in ("loop0",),
                    mtu=9000 if name.startswith("TenGig") else 1500,
                    addresses=self._iface_addrs(name),
                    vrf=_IFACE_VRFS.get(name, "default"),
                    rx_packets=rxp,
                    rx_bytes=int(c["rxb"]),
                    tx_packets=int(c["txp"]),
                    tx_bytes=int(c["txb"]),
                    rx_drops=int(c["rxd"]),
                    tx_drops=int(c["txd"]),
                    rx_packets_per_worker=(0, int(rxp * 0.58), int(rxp * 0.42)),
                )
            )

        nodes = []
        for name, _, _ in _NODES:
            n = self._node_counters[name]
            nodes.append(
                NodeStats(
                    name=name,
                    calls=int(sum(n.calls)),
                    vectors=int(sum(n.vectors)),
                    clocks=int(sum(n.clocks)),
                    vectors_per_worker=tuple(int(v) for v in n.vectors),
                    calls_per_worker=tuple(int(v) for v in n.calls),
                    clocks_per_worker=tuple(int(v) for v in n.clocks),
                )
            )

        workers = []
        for w in range(_WORKERS + 1):
            calls = sum(n.calls[w] for n in self._node_counters.values())
            vectors = sum(n.vectors[w] for n in self._node_counters.values())
            clocks = sum(n.clocks[w] for n in self._node_counters.values())
            workers.append(
                RawWorkerSample(
                    index=w,
                    name="vpp_main" if w == 0 else f"vpp_wk_{w - 1}",
                    core_id=0 if w == 0 else w + 1,
                    calls=int(calls),
                    vectors=int(vectors),
                    clocks=int(clocks),
                )
            )

        errors = tuple(
            ErrorCounter(node=node, reason=reason, count=int(self._err_counters[(node, reason)]))
            for node, reason, _ in _ERRORS + _STEADY_ERRORS
        )
        return FastSample(
            timestamp=now,
            system=self._system_info(),
            interfaces=tuple(interfaces),
            nodes=tuple(nodes),
            workers=tuple(workers),
            errors=errors,
        )

    @staticmethod
    def _iface_addrs(name: str) -> tuple[str, ...]:
        return {
            "TenGigabitEthernet0/0/0": ("203.0.113.10/24",),
            "TenGigabitEthernet0/0/1": ("192.168.10.1/24",),
            "TenGigabitEthernet0/0/1.101": ("10.99.0.254/24",),
            "tap0": ("10.255.0.1/30",),
        }.get(name, ())

    def sample_slow(self) -> SlowSample:
        now = time.time()
        load = self._load_factor(now)
        routes = (
            Route("0.0.0.0/0",
                  (RouteNextHop("203.0.113.1", "TenGigabitEthernet0/0/0"),), source="BGP"),
            Route("203.0.113.0/24",
                  (RouteNextHop("", "TenGigabitEthernet0/0/0"),), source="connected"),
            Route("192.168.10.0/24",
                  (RouteNextHop("", "TenGigabitEthernet0/0/1"),), source="connected"),
            Route("10.20.0.0/16",
                  (RouteNextHop("192.168.10.254", "TenGigabitEthernet0/0/1"),), source="BGP"),
            Route("10.30.0.0/16",
                  (RouteNextHop("192.168.10.254", "TenGigabitEthernet0/0/1"),), source="BGP"),
            # Classic bring-up failure: next-hop ARP unresolved -> incomplete.
            Route("10.40.0.0/16",
                  (RouteNextHop("192.168.10.99", "TenGigabitEthernet0/0/1", resolved=False),),
                  source="BGP"),
            Route("172.16.0.0/12",
                  (RouteNextHop("192.168.10.254", "TenGigabitEthernet0/0/1", weight=1),
                   RouteNextHop("192.168.10.253", "TenGigabitEthernet0/0/1", weight=1)),
                  source="BGP"),
            Route("10.255.0.0/30", (RouteNextHop("", "tap0"),), source="connected"),
            # A second FIB table, as created for tenant/management separation.
            Route("0.0.0.0/0",
                  (RouteNextHop("10.99.0.1", "TenGigabitEthernet0/0/1.101"),),
                  source="BGP", vrf="tenant-a"),
            Route("10.99.0.0/24",
                  (RouteNextHop("", "TenGigabitEthernet0/0/1.101"),),
                  source="connected", vrf="tenant-a"),
            Route("10.99.50.0/24",
                  (RouteNextHop("10.99.0.7", "TenGigabitEthernet0/0/1.101"),),
                  source="BGP", vrf="tenant-a"),
        )
        neighbors = (
            Neighbor("203.0.113.1", "02:fe:a0:11:22:01", "TenGigabitEthernet0/0/0",
                     "dynamic", 12.0 + (now % 30)),
            Neighbor("192.168.10.254", "02:fe:b0:33:44:02", "TenGigabitEthernet0/0/1",
                     "dynamic", 44.0 + (now % 60)),
            Neighbor("192.168.10.253", "02:fe:b0:33:44:03", "TenGigabitEthernet0/0/1",
                     "static", 0.0),
            Neighbor("192.168.10.99", "", "TenGigabitEthernet0/0/1", "incomplete", 3.0),
            Neighbor("10.99.0.1", "02:fe:c0:55:66:04",
                     "TenGigabitEthernet0/0/1.101",
                     "dynamic", 8.0 + (now % 45), vrf="tenant-a"),
        )

        for i in range(len(self._acl_hits)):
            if i != 2:  # rule 2 stays a dead rule
                self._acl_hits[i] += self._rng.uniform(20, 400) * load
        rules = (
            AclRule(0, "permit", "0.0.0.0/0", "192.168.10.0/24", "tcp",
                    dst_port_first=443, dst_port_last=443, hits=int(self._acl_hits[0])),
            AclRule(1, "permit", "192.168.10.0/24", "0.0.0.0/0", "any",
                    hits=int(self._acl_hits[1])),
            AclRule(2, "permit", "10.99.0.0/16", "0.0.0.0/0", "udp",
                    dst_port_first=4789, dst_port_last=4789, hits=int(self._acl_hits[2])),
            AclRule(3, "deny", "0.0.0.0/0", "192.168.10.0/24", "tcp",
                    dst_port_first=22, dst_port_last=22, hits=int(self._acl_hits[3])),
            AclRule(4, "deny", "0.0.0.0/0", "0.0.0.0/0", "any",
                    hits=int(self._acl_hits[4])),
        )
        acls = (
            AclSet(
                acl_index=0,
                tag="edge-inbound",
                rules=rules,
                attachments=(
                    AclAttachment("TenGigabitEthernet0/0/0", "input"),
                    AclAttachment("TenGigabitEthernet0/0/1", "output"),
                ),
            ),
            AclSet(
                acl_index=1,
                tag="tenant-a-in",
                rules=(
                    AclRule(0, "permit", "0.0.0.0/0", "10.99.0.0/24", "tcp",
                            dst_port_first=443, dst_port_last=443,
                            hits=int(self._acl_hits[5])),
                    AclRule(1, "deny", "0.0.0.0/0", "0.0.0.0/0", "any",
                            hits=int(self._acl_hits[6])),
                ),
                attachments=(
                    AclAttachment("TenGigabitEthernet0/0/1.101", "input",
                                  vrf="tenant-a"),
                ),
            ),
        )

        session_count = getattr(self, "_nat_target", 40_000)
        static_mappings = (
            NatStaticMapping("203.0.113.10", 443, "192.168.10.50", 443,
                             "tcp", tag="web-frontend"),
            NatStaticMapping("203.0.113.11", 0, "192.168.10.60", 0,
                             "any", tag="dmz-1to1"),
            NatStaticMapping("203.0.113.10", 8443, "10.99.0.80", 443,
                             "tcp", vrf="tenant-a", tag="tenant-a-web"),
        )
        dnat_session = NatSession(
            inside_addr="192.168.10.50", inside_port=443,
            outside_addr="203.0.113.10", outside_port=443,
            protocol="tcp", direction="out2in",
            idle_seconds=920.0, expire_seconds=6400.0, static=True,
        )
        tenant_sessions = (
            NatSession("10.99.0.12", 51330, "203.0.113.10", 41002, "tcp",
                       "in2out", 75.0, 5200.0, vrf="tenant-a"),
            NatSession("10.99.0.80", 443, "203.0.113.10", 8443, "tcp",
                       "out2in", 480.0, 7000.0, vrf="tenant-a"),
            # Timed-out entry awaiting lazy deletion — exercises the "stale"
            # rendering on screen 4.
            NatSession("10.99.0.33", 40100, "203.0.113.10", 40100, "icmp",
                       "in2out", 4400.0, 0.0, stale=True, vrf="tenant-a"),
        )
        nat = NatState(
            sessions=(dnat_session, *tenant_sessions,
                      *sorted(self._nat_sessions, key=lambda s: s.idle_seconds)),
            static_mappings=static_mappings,
            session_count=session_count,
            max_sessions=63_000,
            counters={
                NAT_COUNTER_CREATED: int(self._nat_created),
                NAT_COUNTER_EXPIRED: int(self._nat_expired),
                "in2out translations": int(self._nat_created * 310),
                "out2in translations": int(self._nat_created * 295),
                "no translation entry": int(self._err_counters[
                    ("nat44-ed-out2in", "no translation entry")]),
                "out of ports": int(self._err_counters[("nat44-ed-in2out", "out of ports")]),
            },
        )
        # Deliberately skewed queue placement (wk_0 owns most queues) so the
        # Cores screen's imbalance hint is demoable on mock data.
        placement = (
            RxQueuePlacement("vpp_wk_0", 1, "dpdk-input",
                             "TenGigabitEthernet0/0/0", 0, "polling"),
            RxQueuePlacement("vpp_wk_0", 1, "dpdk-input",
                             "TenGigabitEthernet0/0/0", 1, "polling"),
            RxQueuePlacement("vpp_wk_0", 1, "dpdk-input",
                             "TenGigabitEthernet0/0/1", 0, "polling"),
            RxQueuePlacement("vpp_wk_0", 1, "dpdk-input",
                             "TenGigabitEthernet0/0/1", 1, "polling"),
            RxQueuePlacement("vpp_wk_1", 2, "dpdk-input",
                             "TenGigabitEthernet0/0/0", 2, "polling"),
            RxQueuePlacement("vpp_wk_1", 2, "tap-input", "tap0", 0, "polling"),
        )
        return SlowSample(
            timestamp=now,
            routes=routes,
            per_route_counters_enabled=False,
            neighbors=neighbors,
            acls=acls,
            nat=nat,
            rx_placement=placement,
        )

    # -- Traces ---------------------------------------------------------------

    def capture_trace(self, count: int) -> tuple[PacketTrace, ...]:
        time.sleep(0.4)  # simulate capture latency; callers must be off-thread
        req = TraceRequest(
            src_ip="192.168.10.42", dst_ip="8.8.8.8",
            protocol="udp", src_port=53124, dst_port=53,
            ingress_interface="TenGigabitEthernet0/0/1",
        )
        traces = [self._forward_trace(req, i, injected=False)
                  for i in range(min(count, 4))]
        traces.append(self._deny_trace(min(count, 4)))
        return tuple(traces)

    def start_traffic(self, request: TraceRequest, pps: int,
                      duration_seconds: int = 0, packet_size: int = 128) -> None:
        self._traffic_pps = float(pps)
        self._traffic_iface = request.ingress_interface
        self._traffic_until = (
            time.time() + duration_seconds if duration_seconds > 0 else 0.0
        )

    def stop_traffic(self) -> None:
        self._traffic_pps = 0.0
        self._traffic_iface = ""
        self._traffic_until = 0.0

    @property
    def traffic_active(self) -> bool:
        if self._traffic_pps <= 0:
            return False
        return not self._traffic_until or time.time() < self._traffic_until

    def inject_and_trace(self, request: TraceRequest, burst: int) -> tuple[PacketTrace, ...]:
        time.sleep(0.4)
        if request.protocol == "tcp" and request.dst_port == 22:
            return tuple(self._deny_trace(i, request=request, injected=True)
                         for i in range(burst))
        return tuple(self._forward_trace(request, i, injected=True) for i in range(burst))

    def _forward_trace(self, req: TraceRequest, idx: int, injected: bool) -> PacketTrace:
        ingress = req.ingress_interface or "TenGigabitEthernet0/0/1"
        nat_port = 17000 + idx
        steps = (
            TraceStep("dpdk-input", "info", f"rx on {ingress}",
                      (f"len 82  {req.protocol} {req.src_ip}:{req.src_port} -> "
                       f"{req.dst_ip}:{req.dst_port}",)),
            TraceStep("ethernet-input", "info", "IPv4 ethertype 0x0800",
                      ("dst 02:fe:b0:33:44:99 src 02:fe:c0:12:34:56",)),
            TraceStep("ip4-input", "forward", "header ok, ttl 64", ()),
            TraceStep("acl-plugin-in-ip4-fa", "permit",
                      "matched acl 0 rule 1: permit 192.168.10.0/24 -> any",
                      ("action permit, lc_index 0",)),
            TraceStep("nat44-ed-in2out", "translate",
                      f"{req.src_ip}:{req.src_port} -> 203.0.113.10:{nat_port}",
                      ("session slot new", "fib 0")),
            TraceStep("ip4-lookup", "forward",
                      "matched 0.0.0.0/0 via 203.0.113.1",
                      ("fib 0, dpo load-balance, next-hop 203.0.113.1",
                       "out TenGigabitEthernet0/0/0")),
            TraceStep("ip4-rewrite", "rewrite",
                      "ttl 64 -> 63, MAC rewrite to 02:fe:a0:11:22:01", ()),
            TraceStep("TenGigabitEthernet0/0/0-tx", "forward",
                      "tx on TenGigabitEthernet0/0/0", ()),
        )
        return PacketTrace(packet_index=idx, input_interface=ingress,
                           steps=steps, injected=injected,
                           worker=f"vpp_wk_{idx % _WORKERS}")

    def _deny_trace(self, idx: int, request: TraceRequest | None = None,
                    injected: bool = False) -> PacketTrace:
        src = request.src_ip if request else "198.51.100.66"
        dst = request.dst_ip if request else "192.168.10.42"
        sport = request.src_port if request else 40122
        dport = request.dst_port if request else 22
        ingress = (request.ingress_interface if request and request.ingress_interface
                   else "TenGigabitEthernet0/0/0")
        steps = (
            TraceStep("dpdk-input", "info", f"rx on {ingress}",
                      (f"len 74  tcp {src}:{sport} -> {dst}:{dport} SYN",)),
            TraceStep("ethernet-input", "info", "IPv4 ethertype 0x0800", ()),
            TraceStep("ip4-input", "forward", "header ok, ttl 57", ()),
            TraceStep("acl-plugin-in-ip4-fa", "deny",
                      f"matched acl 0 rule 3: deny tcp any -> 192.168.10.0/24 port {dport}",
                      ("action deny",)),
            TraceStep("error-drop", "drop", "acl-plugin-in-ip4-fa: deny packets", ()),
        )
        return PacketTrace(packet_index=idx, input_interface=ingress,
                           steps=steps, injected=injected,
                           worker=f"vpp_wk_{idx % _WORKERS}")
