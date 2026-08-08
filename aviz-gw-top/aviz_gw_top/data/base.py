"""DataSource contract implemented by both the real VPP source and the mock.

Sources return *cumulative* counters embedded in model dataclasses (rate
fields left at zero). The poller owns previous-sample state and computes all
per-second rates, including counter-reset detection. Sources never compute
rates themselves — that keeps the reset logic in exactly one place.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field

from ..model import (
    AclSet,
    ErrorCounter,
    InterfaceStats,
    NatState,
    Neighbor,
    NodeStats,
    PacketTrace,
    Route,
    RxQueuePlacement,
    SystemInfo,
    TraceRequest,
)

# NAT cumulative counter keys the poller derives rates from. Sources must use
# these names in NatState.counters when the underlying values are available.
NAT_COUNTER_CREATED = "sessions-created"
NAT_COUNTER_EXPIRED = "sessions-expired"


@dataclass(frozen=True)
class RawWorkerSample:
    """Cumulative per-thread aggregates (summed over all nodes on the thread)."""

    index: int                 # 0 = main, 1.. = workers
    name: str = ""
    core_id: int = -1
    calls: int = 0
    vectors: int = 0
    clocks: int = 0


@dataclass(frozen=True)
class FastSample:
    """One fast-cadence sample: cumulative counters from the stats segment."""

    timestamp: float
    system: SystemInfo
    interfaces: tuple[InterfaceStats, ...] = ()
    nodes: tuple[NodeStats, ...] = ()
    workers: tuple[RawWorkerSample, ...] = ()
    errors: tuple[ErrorCounter, ...] = ()


@dataclass(frozen=True)
class SlowSample:
    """One slow-cadence sample: structural dumps from the binary API."""

    timestamp: float
    routes: tuple[Route, ...] = ()
    per_route_counters_enabled: bool = False
    neighbors: tuple[Neighbor, ...] = ()
    acls: tuple[AclSet, ...] = ()
    nat: NatState = field(default_factory=NatState)
    rx_placement: tuple[RxQueuePlacement, ...] = ()


class DataSourceError(Exception):
    """Raised by sources when the gateway is unreachable or a call fails."""


class DataSource(ABC):
    """Everything the tool needs from the gateway data plane."""

    @abstractmethod
    def connect(self) -> SystemInfo:
        """Establish connections; return system info. Raises DataSourceError."""

    @abstractmethod
    def disconnect(self) -> None:
        """Tear down connections. Must be safe to call repeatedly."""

    @abstractmethod
    def sample_fast(self) -> FastSample:
        """Read the high-frequency counters (stats segment)."""

    @abstractmethod
    def sample_slow(self) -> SlowSample:
        """Read structural state (FIB, neighbors, ACLs, NAT)."""

    # -- Validation screen ---------------------------------------------------

    @abstractmethod
    def capture_trace(self, count: int) -> tuple[PacketTrace, ...]:
        """Passive mode: enable tracing for `count` packets of real traffic,
        wait briefly, and return the parsed traces. Blocking — callers run
        this off the UI thread."""

    @abstractmethod
    def inject_and_trace(self, request: TraceRequest, burst: int) -> tuple[PacketTrace, ...]:
        """Active mode: craft packets matching `request`, inject `burst` of
        them via the packet generator, and return their traces. Only invoked
        when the tool runs with --allow-inject."""

    @abstractmethod
    def start_traffic(self, request: TraceRequest, pps: int,
                      duration_seconds: int = 0, packet_size: int = 128) -> None:
        """Active mode: stream packets matching `request` at `pps`.

        `duration_seconds` > 0 sends pps * duration packets and then stops
        by itself (benchmark run); 0 streams until stop_traffic().
        `packet_size` is the generated packet length in bytes; with pps it
        sets the bandwidth (pps * size * 8). Only invoked with
        --allow-inject."""

    @property
    @abstractmethod
    def traffic_active(self) -> bool:
        """True while a traffic stream is (still) generating. A timed run
        flips this False by itself when its duration is exhausted; the UI
        polls it to reset the Send toggle."""

    @abstractmethod
    def stop_traffic(self) -> None:
        """Stop the continuous stream. Safe to call when none is running;
        also called on disconnect so no stream outlives the tool."""

    @property
    @abstractmethod
    def name(self) -> str:
        """Short human-readable source name for the header ("live"/"mock")."""
