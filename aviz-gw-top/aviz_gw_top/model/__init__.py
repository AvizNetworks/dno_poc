"""Plain dataclasses shared between the data layer and the UI.

This is the only vocabulary the UI understands. No vpp_papi types, no raw CLI
text, no stats-segment paths cross this boundary. Everything is frozen: the
poller publishes immutable snapshots and the UI reads them without locking.
"""

from .entities import (
    AclAttachment,
    AclRule,
    AclSet,
    ErrorCounter,
    GatewayState,
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
    WorkerStats,
)

__all__ = [
    "AclAttachment",
    "AclRule",
    "AclSet",
    "ErrorCounter",
    "GatewayState",
    "InterfaceStats",
    "NatSession",
    "NatState",
    "NatStaticMapping",
    "Neighbor",
    "RxQueuePlacement",
    "NodeStats",
    "PacketTrace",
    "Route",
    "RouteNextHop",
    "SystemInfo",
    "TraceRequest",
    "TraceStep",
    "WorkerStats",
]
