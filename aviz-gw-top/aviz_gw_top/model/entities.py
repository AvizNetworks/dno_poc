"""All model dataclasses. Frozen, UI-facing, VPP-free."""

from __future__ import annotations

from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# System / connection
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class SystemInfo:
    version: str = ""              # e.g. "26.06-release"
    version_mismatch: bool = False  # True when version does not match the pin
    uptime_seconds: float = 0.0
    worker_count: int = 0
    connected: bool = False
    mock: bool = False
    last_error: str = ""           # last connection error, for the banner


# ---------------------------------------------------------------------------
# Fast-path telemetry (stats segment, 1 Hz)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class InterfaceStats:
    name: str
    sw_if_index: int
    admin_up: bool
    link_up: bool
    mtu: int = 0
    addresses: tuple[str, ...] = ()
    # An interface is bound to exactly one IPv4 FIB table.
    vrf: str = "default"
    # Cumulative counters (summed across workers).
    rx_packets: int = 0
    rx_bytes: int = 0
    tx_packets: int = 0
    tx_bytes: int = 0
    rx_drops: int = 0
    tx_drops: int = 0
    rx_errors: int = 0
    tx_errors: int = 0
    # Per-second rates computed by the poller from consecutive samples.
    rx_pps: float = 0.0
    rx_bps: float = 0.0        # bits/sec
    tx_pps: float = 0.0
    tx_bps: float = 0.0
    rx_drops_delta: float = 0.0  # drops/sec since last sample
    tx_drops_delta: float = 0.0
    # Per-worker rx packet counters. Asymmetry here usually means uneven RSS.
    rx_packets_per_worker: tuple[int, ...] = ()
    # ...and the poller-computed pps per worker slot (0 = main).
    rx_pps_per_worker: tuple[float, ...] = ()


@dataclass(frozen=True)
class NodeStats:
    name: str
    calls: int = 0
    vectors: int = 0
    suspends: int = 0
    clocks: int = 0
    # Derived over the last sampling window.
    vectors_per_call: float = 0.0
    clocks_per_packet: float = 0.0
    calls_per_sec: float = 0.0
    vectors_per_sec: float = 0.0
    clocks_per_sec: float = 0.0
    # Per-worker breakdown (index = worker slot, 0 = main). Cumulative
    # counters plus per-second rates; asymmetry across workers usually means
    # uneven RSS distribution.
    vectors_per_worker: tuple[int, ...] = ()
    calls_per_worker: tuple[int, ...] = ()
    clocks_per_worker: tuple[int, ...] = ()
    calls_ps_per_worker: tuple[float, ...] = ()
    vectors_ps_per_worker: tuple[float, ...] = ()
    clocks_ps_per_worker: tuple[float, ...] = ()

    @property
    def active(self) -> bool:
        """True when the node actually saw packets in the last window."""
        return self.vectors_per_sec > 0


@dataclass(frozen=True)
class WorkerStats:
    worker_index: int          # 0 = main thread, 1.. = workers
    name: str = ""             # e.g. "vpp_wk_0"
    core_id: int = -1
    vectors_per_call: float = 0.0
    clocks_per_packet: float = 0.0
    calls_per_sec: float = 0.0
    vectors_per_sec: float = 0.0
    utilization: float = 0.0   # 0..1 saturation estimate (vector fill: vpc/256)


@dataclass(frozen=True)
class ErrorCounter:
    node: str                  # graph node the error belongs to
    reason: str                # named drop reason, e.g. "ip4 ttl <= 1"
    count: int = 0             # cumulative
    rate: float = 0.0          # per-second delta
    severity: str = "error"    # "error" | "info" as classified by VPP


# ---------------------------------------------------------------------------
# Structural state (binary API, ~5 s)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class RouteNextHop:
    address: str = ""          # empty for receive/drop/glean specials
    interface: str = ""
    weight: int = 1
    special: bool = False      # local/drop/unreach path: no adjacency exists
    # Adjacency resolution: incomplete means ARP/ND has not resolved the
    # next-hop MAC yet, so the rewrite string is unfilled and the route is
    # not actually usable — a common bring-up failure.
    resolved: bool = True


@dataclass(frozen=True)
class Route:
    prefix: str                # e.g. "10.1.0.0/24"
    next_hops: tuple[RouteNextHop, ...] = ()
    # Per-route counters are optional in VPP and off by default at scale.
    # None means "not enabled", which the UI must distinguish from zero.
    packets: int | None = None
    bytes: int | None = None
    pps: float = 0.0           # rate over per-route counters, when enabled
    source: str = ""           # e.g. "connected", "local", "drop"; "" = learned
    vrf: str = "default"       # FIB table name; "default" = table 0

    @property
    def resolved(self) -> bool:
        return all(nh.resolved for nh in self.next_hops) if self.next_hops else False

    @property
    def special(self) -> bool:
        """True when every path terminates in the router (drop/local/...)."""
        return bool(self.next_hops) and all(nh.special for nh in self.next_hops)


@dataclass(frozen=True)
class RxQueuePlacement:
    """One rx queue pinned to one worker (from `show interface rx-placement`).

    The queue -> worker mapping is the placement truth; per-QUEUE traffic is
    not exposed by VPP, so rates come per (interface, worker) instead.
    """

    worker_name: str           # e.g. "vpp_wk_0"
    thread_index: int          # vlib thread id (matches worker slot index)
    input_node: str            # dpdk-input / tap-input / af-packet-input
    interface: str
    queue_id: int
    mode: str = "polling"      # "polling" | "interrupt" | "adaptive"


@dataclass(frozen=True)
class Neighbor:
    ip: str
    mac: str
    interface: str
    state: str = ""            # e.g. "dynamic", "static", "incomplete"
    age_seconds: float = 0.0
    # ARP entries live on an interface; the interface's IPv4 table decides
    # which VRF the neighbor (and any adjacency using it) belongs to.
    vrf: str = "default"


@dataclass(frozen=True)
class AclRule:
    rule_index: int
    action: str                # "permit" | "deny" | "permit+reflect"
    src_prefix: str = "0.0.0.0/0"
    dst_prefix: str = "0.0.0.0/0"
    proto: str = "any"         # "tcp" | "udp" | "icmp" | "any" | number
    src_port_first: int = 0
    src_port_last: int = 65535
    dst_port_first: int = 0
    dst_port_last: int = 65535
    hits: int = 0              # cumulative packets matched
    hit_rate: float = 0.0      # matches/sec over the last window

    @property
    def is_permit(self) -> bool:
        return self.action.startswith("permit")


@dataclass(frozen=True)
class AclAttachment:
    interface: str
    direction: str             # "input" | "output"
    # ACLs are global objects in VPP; VRF membership is derived from the
    # interface each attachment points at (one v4 table per interface).
    vrf: str = "default"


@dataclass(frozen=True)
class AclSet:
    acl_index: int
    tag: str = ""
    rules: tuple[AclRule, ...] = ()
    attachments: tuple[AclAttachment, ...] = ()


@dataclass(frozen=True)
class NatSession:
    inside_addr: str
    inside_port: int
    outside_addr: str
    outside_port: int
    protocol: str              # "tcp" | "udp" | "icmp"
    direction: str = "in2out"
    age_seconds: float = 0.0
    expire_seconds: float = 0.0
    # Inside/tenant table the session belongs to (nat44 user vrf_id):
    # overlapping tenant prefixes produce distinct per-VRF sessions.
    vrf: str = "default"


@dataclass(frozen=True)
class NatStaticMapping:
    """A configured NAT44 static mapping (DNAT / port-forward / 1:1).

    external_port == 0 means an address-only (1:1) mapping.
    """

    external_addr: str
    external_port: int
    local_addr: str
    local_port: int
    protocol: str = "any"      # "tcp" | "udp" | "icmp" | "any"
    vrf: str = "default"
    tag: str = ""              # operator-assigned label, often empty


@dataclass(frozen=True)
class NatState:
    sessions: tuple[NatSession, ...] = ()
    static_mappings: tuple[NatStaticMapping, ...] = ()
    session_count: int = 0     # total, may exceed len(sessions) when truncated
    max_sessions: int = 0      # configured session-table limit; 0 = unknown
    created_per_sec: float = 0.0
    expired_per_sec: float = 0.0
    # NAT-specific counters (cumulative, name -> value): translations,
    # no-session-found, out-of-ports, ...
    counters: dict[str, int] = field(default_factory=dict)
    counter_rates: dict[str, float] = field(default_factory=dict)

    @property
    def utilization(self) -> float:
        if self.max_sessions <= 0:
            return 0.0
        return self.session_count / self.max_sessions


# ---------------------------------------------------------------------------
# Packet trace (Validation screen)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class TraceRequest:
    src_ip: str
    dst_ip: str
    protocol: str = "udp"      # "tcp" | "udp" | "icmp"
    src_port: int = 0
    dst_port: int = 0
    ingress_interface: str = ""


@dataclass(frozen=True)
class TraceStep:
    node: str                  # graph node name, e.g. "ip4-lookup"
    outcome: str = "info"      # forward|permit|drop|deny|translate|rewrite|info
    summary: str = ""          # one-line decision, e.g. "matched 10.0.0.0/8"
    details: tuple[str, ...] = ()  # extracted key facts for the block body
    raw: str = ""              # original trace text for this node (fallback)
    recognized: bool = True    # False -> render raw text, never drop the step

    @property
    def terminal(self) -> bool:
        """Drop/deny steps terminate the rendered pipeline."""
        return self.outcome in ("drop", "deny")


@dataclass(frozen=True)
class PacketTrace:
    packet_index: int = 0
    input_interface: str = ""
    steps: tuple[TraceStep, ...] = ()
    injected: bool = False     # True when produced by active inject (pg)
    # Which thread's trace section the packet appeared in ("vpp_wk_0", ...):
    # exactly one worker carries a packet through the graph.
    worker: str = ""


# ---------------------------------------------------------------------------
# Published snapshot
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class GatewayState:
    """One immutable snapshot of everything the UI renders.

    fast_* fields refresh at the fast cadence (stats segment), the structural
    fields at the slow cadence (binary API). The poller merges the latest of
    each into a fresh GatewayState on every publish.
    """

    system: SystemInfo = field(default_factory=SystemInfo)
    timestamp: float = 0.0

    # Fast (1 Hz)
    interfaces: tuple[InterfaceStats, ...] = ()
    nodes: tuple[NodeStats, ...] = ()
    workers: tuple[WorkerStats, ...] = ()
    errors: tuple[ErrorCounter, ...] = ()
    total_rx_pps: float = 0.0
    total_tx_pps: float = 0.0
    total_drops: int = 0
    total_drops_rate: float = 0.0

    # Slow (5 s)
    routes: tuple[Route, ...] = ()
    per_route_counters_enabled: bool = False
    neighbors: tuple[Neighbor, ...] = ()
    acls: tuple[AclSet, ...] = ()
    nat: NatState = field(default_factory=NatState)
    rx_placement: tuple[RxQueuePlacement, ...] = ()
