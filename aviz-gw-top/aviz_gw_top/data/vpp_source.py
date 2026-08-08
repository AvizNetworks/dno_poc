"""Real data source: stats segment (fast) + binary API (slow) + cli_inband.

Two distinct channels, used deliberately:

* Stats segment — shared-memory read via vpp_papi.VPPStats. Everything at
  1 Hz comes from here: interface counters, per-node counters, per-worker
  counters, named error counters. Counters are stored per worker thread; we
  keep the per-worker vectors and sum for totals (see _sum_simple).
* Binary API — vpp_papi.VPPApiClient over the local socket. Structural,
  slower-moving state: interface table, FIB, neighbors, ACLs, NAT.

cli_inband is used only where no typed message exists (packet trace, pg,
`show nat44 summary`, `show threads`); every such text format is parsed by a
named function in parsers.py, never here and never in the UI.

We never shell out to vppctl.

VERIFY(26.06): message names, field names, and stats paths marked below were
written for VPP v26.06-release and vpp-papi 2.4. Each lives in a single named
constant / accessor so a rename in a future VPP is a one-line fix. Where a
name can vary across releases, _find_msg() introspects the connected VPP at
runtime instead of hard-coding one candidate.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from struct import Struct
from typing import Any, TypeVar

from ..config import (
    PG_PACKET_SIZE,
    TARGET_VPP_VERSION,
    TRACE_INPUT_NODES,
    TRAFFIC_WINDOW_SECONDS,
)
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
)
from . import parsers
from .base import DataSource, DataSourceError, FastSample, RawWorkerSample, SlowSample

log = logging.getLogger(__name__)

T = TypeVar("T")

# -- stats segment paths (VERIFY(26.06): stable for many releases) -----------
STATS_IF_NAMES = "/if/names"
STATS_IF_RX = "/if/rx"            # combined (packets, bytes) [thread][sw_if_index]
STATS_IF_TX = "/if/tx"
STATS_IF_DROPS = "/if/drops"      # simple [thread][sw_if_index]
STATS_IF_RX_ERROR = "/if/rx-error"
STATS_IF_TX_ERROR = "/if/tx-error"
STATS_NODE_NAMES = "/sys/node/names"
STATS_NODE_CALLS = "/sys/node/calls"    # simple [thread][node_index]
STATS_NODE_VECTORS = "/sys/node/vectors"
STATS_NODE_CLOCKS = "/sys/node/clocks"
STATS_NODE_SUSPENDS = "/sys/node/suspends"
STATS_ERR_PATTERN = "^/err/"      # /err/<node>/<reason>
# VERIFY(26.06): per-rule ACL hit counters in the stats segment. If the
# pattern below matches nothing on the target build, hit counts fall back to 0.
STATS_ACL_PATTERN = "^/acl/"
# VERIFY(26.06): NAT44-ED gauges (e.g. /nat44-ed/total-sessions).
STATS_NAT_PATTERN = "^/nat44-ed/"

# -- binary API message-name candidates, newest first -------------------------
# VERIFY(26.06): _find_msg picks the first name the connected VPP actually
# exposes, so older/newer variants keep working.
MSG_NAT_SESSION_DUMP = ("nat44_user_session_v3_dump", "nat44_user_session_v2_dump",
                        "nat44_user_session_dump")
MSG_NAT_USER_DUMP = ("nat44_user_dump",)
MSG_NAT_STATIC_DUMP = ("nat44_static_mapping_dump",)
MSG_NEIGHBOR_DUMP = ("ip_neighbor_dump",)
MSG_ROUTE_DUMP = ("ip_route_dump",)
MSG_TABLE_DUMP = ("ip_table_dump",)
MSG_ACL_DUMP = ("acl_dump",)
MSG_ACL_INTERFACE_DUMP = ("acl_interface_list_dump",)

_CLIENT_NAME = "aviz-gw-top"

# VERIFY(26.06): FIB_API_PATH_TYPE_* enum values. Non-NORMAL paths terminate
# in the router (no adjacency), so they never count as "unresolved".
_PATH_TYPE_LABELS: dict[int, str] = {
    1: "(local)",       # FIB_API_PATH_TYPE_LOCAL / receive
    2: "(drop)",        # FIB_API_PATH_TYPE_DROP
    5: "(unreachable)",  # FIB_API_PATH_TYPE_ICMP_UNREACH
    6: "(prohibit)",    # FIB_API_PATH_TYPE_ICMP_PROHIBIT
}


def _sum_simple(value: Any, index: int) -> int:
    """Sum a simple per-worker counter across worker slots for one index."""
    total = 0
    for per_thread in value:
        if index < len(per_thread):
            total += per_thread[index]
    return total


def _sum_combined_packets(value: Any, index: int) -> int:
    """Sum the packets field of a combined (packets+bytes) per-worker counter.

    Falls back to plain ints so a simple-counter layout still sums correctly.
    """
    total = 0
    for per_thread in value:
        if index >= len(per_thread):
            continue
        entry = per_thread[index]
        packets = getattr(entry, "packets", None)
        if packets is None and isinstance(entry, dict):
            packets = entry.get("packets", 0)
        if packets is None and isinstance(entry, (tuple, list)):
            packets = entry[0]
        if packets is None:
            packets = entry
        total += int(packets)
    return total


def _per_worker_simple(value: Any, index: int) -> tuple[int, ...]:
    return tuple(
        per_thread[index] if index < len(per_thread) else 0 for per_thread in value
    )


def _sum_combined(value: Any, index: int) -> tuple[int, int]:
    """Sum a combined (packets, bytes) counter across worker slots."""
    packets = 0
    octets = 0
    for per_thread in value:
        if index < len(per_thread):
            entry = per_thread[index]
            packets += entry[0]
            octets += entry[1]
    return packets, octets


class VppDataSource(DataSource):
    def __init__(self, stats_socket: str, api_socket: str) -> None:
        self._stats_socket = stats_socket
        self._api_socket = api_socket
        self._stats: Any = None
        self._client: Any = None
        self._api: Any = None
        self._system = SystemInfo()
        self._start_time = 0.0
        # Caches refreshed on the slow path, consumed by the fast path.
        self._if_meta: dict[int, dict[str, Any]] = {}  # sw_if_index -> flags/mtu/addrs
        self._threads: tuple[tuple[int, str, int], ...] = ()
        self._msg_cache: dict[tuple[str, ...], str | None] = {}
        # Traffic stream state: when active, the fast path watches the pg
        # stream each tick — re-arming it (continuous mode) or marking it
        # finished (timed mode). See start_traffic.
        self._traffic_active = False
        self._traffic_oneshot = False

    @property
    def name(self) -> str:
        return "live"

    # -- connection ------------------------------------------------------------

    def connect(self) -> SystemInfo:
        try:
            from vpp_papi import VPPApiClient
            from vpp_papi.vpp_stats import VPPStats
        except ImportError as exc:  # pragma: no cover - environment dependent
            raise DataSourceError(f"vpp_papi not importable: {exc}") from exc

        try:
            self._stats = VPPStats(socketname=self._stats_socket)
            self._stats.connect()
        except Exception as exc:
            raise DataSourceError(
                f"stats segment unavailable at {self._stats_socket}: {exc}"
            ) from exc

        try:
            try:
                client = VPPApiClient(server_address=self._api_socket)
            except Exception:
                # No local .api.json files: bootstrap definitions from VPP itself.
                client = VPPApiClient(server_address=self._api_socket, bootstrapapi=True)
            client.connect(_CLIENT_NAME)
        except Exception as exc:
            self._stats.disconnect()
            self._stats = None
            raise DataSourceError(
                f"binary API unavailable at {self._api_socket}: {exc}"
            ) from exc
        self._client = client
        self._api = client.api
        self._msg_cache.clear()
        self._traffic_active = False  # any previous stream died with old VPP

        version_reply = self._api.show_version()
        version = _to_str(version_reply.version)
        self._start_time = time.time()
        self._refresh_threads()
        self._refresh_interface_meta()
        self._system = SystemInfo(
            version=version,
            version_mismatch=TARGET_VPP_VERSION not in version,
            uptime_seconds=0.0,
            worker_count=max(0, len(self._threads) - 1),
            connected=True,
            mock=False,
        )
        return self._system

    def disconnect(self) -> None:
        # Never leave a demo traffic stream running after the tool exits.
        if self._api is not None:
            try:
                self.stop_traffic()
            except Exception:  # noqa: BLE001 - teardown must not raise
                pass
        for closer in (self._client, self._stats):
            if closer is not None:
                try:
                    closer.disconnect()
                except Exception:  # noqa: BLE001 - teardown must not raise
                    pass
        self._client = None
        self._api = None
        self._stats = None

    def _find_msg(self, candidates: tuple[str, ...]) -> str | None:
        """First binary API message name the connected VPP exposes."""
        if candidates in self._msg_cache:
            return self._msg_cache[candidates]
        found = None
        for name in candidates:
            if hasattr(self._api, name):
                found = name
                break
        self._msg_cache[candidates] = found
        if found is None:
            log.warning("none of the API messages %s exist on this VPP", candidates)
        return found

    def _cli(self, command: str) -> str:
        """Run a CLI command over the binary API (cli_inband). Fallback only —
        used exclusively for commands with no typed message."""
        reply = self._api.cli_inband(cmd=command)
        if getattr(reply, "retval", 0) != 0:
            raise DataSourceError(f"cli_inband {command!r} failed: rv {reply.retval}")
        return _to_str(reply.reply)

    def _refresh_threads(self) -> None:
        try:
            self._threads = parsers.parse_show_threads(self._cli("show threads"))
        except Exception as exc:
            log.warning("show threads failed: %s", exc)
            self._threads = ()

    # -- fast path: stats segment ------------------------------------------------

    def sample_fast(self) -> FastSample:
        stats = self._stats
        if stats is None:
            raise DataSourceError("not connected")
        try:
            return self._sample_fast(stats)
        except DataSourceError:
            raise
        except Exception as exc:
            raise DataSourceError(f"stats segment read failed: {exc}") from exc

    def _sample_fast(self, stats: Any) -> FastSample:
        self._maybe_rearm_traffic()
        now = time.time()
        if_names = stats[STATS_IF_NAMES]
        rx = stats[STATS_IF_RX]
        tx = stats[STATS_IF_TX]
        drops = stats[STATS_IF_DROPS]
        rx_err = _try_get(stats, STATS_IF_RX_ERROR)
        tx_err = _try_get(stats, STATS_IF_TX_ERROR)

        interfaces = []
        for idx, if_name in enumerate(if_names):
            if not if_name:
                continue
            meta = self._if_meta.get(idx, {})
            rx_p, rx_b = _sum_combined(rx, idx)
            tx_p, tx_b = _sum_combined(tx, idx)
            interfaces.append(
                InterfaceStats(
                    name=str(if_name),
                    sw_if_index=idx,
                    admin_up=bool(meta.get("admin_up", True)),
                    link_up=bool(meta.get("link_up", True)),
                    mtu=int(meta.get("mtu", 0)),
                    addresses=tuple(meta.get("addresses", ())),
                    vrf=str(meta.get("vrf", "default")),
                    rx_packets=rx_p,
                    rx_bytes=rx_b,
                    tx_packets=tx_p,
                    tx_bytes=tx_b,
                    rx_drops=_sum_simple(drops, idx),
                    tx_drops=0,  # /if/drops is not split by direction
                    rx_errors=_sum_simple(rx_err, idx) if rx_err else 0,
                    tx_errors=_sum_simple(tx_err, idx) if tx_err else 0,
                    rx_packets_per_worker=tuple(
                        per_thread[idx][0] if idx < len(per_thread) else 0
                        for per_thread in rx
                    ),
                )
            )

        nodes: list[NodeStats] = []
        workers: list[RawWorkerSample] = []
        thread_meta = {tid: (tname, core) for tid, tname, core in self._threads}
        node_names = _try_get(stats, STATS_NODE_NAMES)
        if node_names is None:
            # Per-node counters are a statseg STARTUP option, OFF in the
            # stock config (seen live after a metasrv01 VPP restart): a
            # gateway without them must degrade — interfaces, drops and
            # error counters still work — never spin in a disconnect
            # loop. Workers keep their name/core from `show threads`;
            # rates read zero and the UI states why the panel is empty.
            for tid, tname, core in self._threads:
                workers.append(RawWorkerSample(index=tid, name=tname,
                                               core_id=core, calls=0,
                                               vectors=0, clocks=0))
        else:
            calls = stats[STATS_NODE_CALLS]
            vectors = stats[STATS_NODE_VECTORS]
            clocks = stats[STATS_NODE_CLOCKS]
            suspends = _try_get(stats, STATS_NODE_SUSPENDS)

            n_threads = len(calls)
            worker_calls = [0] * n_threads
            worker_vectors = [0] * n_threads
            worker_clocks = [0] * n_threads
            for idx, node_name in enumerate(node_names):
                if not node_name:
                    continue
                per_worker_vec = _per_worker_simple(vectors, idx)
                per_worker_calls = _per_worker_simple(calls, idx)
                per_worker_clocks = _per_worker_simple(clocks, idx)
                total_vectors = sum(per_worker_vec)
                total_calls = sum(per_worker_calls)
                total_clocks = sum(per_worker_clocks)
                for t in range(n_threads):
                    worker_calls[t] += per_worker_calls[t] if t < len(per_worker_calls) else 0
                    worker_vectors[t] += per_worker_vec[t] if t < len(per_worker_vec) else 0
                    worker_clocks[t] += per_worker_clocks[t] if t < len(per_worker_clocks) else 0
                # Keep the model small: skip nodes that have never run at all.
                if total_calls == 0 and total_vectors == 0:
                    continue
                nodes.append(
                    NodeStats(
                        name=str(node_name),
                        calls=total_calls,
                        vectors=total_vectors,
                        suspends=_sum_simple(suspends, idx) if suspends else 0,
                        clocks=total_clocks,
                        vectors_per_worker=per_worker_vec,
                        calls_per_worker=per_worker_calls,
                        clocks_per_worker=per_worker_clocks,
                    )
                )

            for t in range(n_threads):
                # The stats segment can carry more per-thread slots than vlib
                # threads exist (observed on 26.06: 4 slots, `show threads` lists
                # 3). A slot that is both unknown to `show threads` and has never
                # done any work is a phantom — skip it. If it ever shows activity
                # it still appears, under a fallback name.
                known = t in thread_meta
                busy = worker_calls[t] or worker_vectors[t] or worker_clocks[t]
                if not known and not busy:
                    continue
                name, core = thread_meta.get(t, (f"thread-{t}", -1))
                workers.append(
                    RawWorkerSample(
                        index=t,
                        name=name,
                        core_id=core,
                        calls=worker_calls[t],
                        vectors=worker_vectors[t],
                        clocks=worker_clocks[t],
                    )
                )

        errors = self._read_error_counters(stats)
        uptime = now - self._start_time
        # Prefer the vlib thread listing for the worker count; the stats
        # segment may carry extra phantom slots (see above).
        worker_count = (
            max(0, len(self._threads) - 1) if self._threads else max(0, n_threads - 1)
        )
        system = SystemInfo(
            version=self._system.version,
            version_mismatch=self._system.version_mismatch,
            uptime_seconds=uptime,
            worker_count=worker_count,
            connected=True,
            mock=False,
        )
        return FastSample(
            timestamp=now,
            system=system,
            interfaces=tuple(interfaces),
            nodes=tuple(nodes),
            workers=tuple(workers),
            errors=errors,
        )

    def _read_error_counters(self, stats: Any) -> tuple[ErrorCounter, ...]:
        errors = []
        paths = stats.ls([STATS_ERR_PATTERN])
        for path, count in _dump_error_counts(stats, paths).items():
            # /err/<node>/<reason>
            parts = path.split("/", 3)
            if len(parts) < 4:
                continue
            if count == 0:
                continue  # thousands of zero counters; only surface nonzero
            errors.append(ErrorCounter(node=parts[2], reason=parts[3], count=count))
        errors.sort(key=lambda e: e.count, reverse=True)
        return tuple(errors[:64])

    # -- slow path: binary API dumps ---------------------------------------------

    def sample_slow(self) -> SlowSample:
        if self._api is None:
            raise DataSourceError("not connected")
        # The interface dump is a core message: if it fails, the API session
        # is genuinely broken and the poller should reconnect.
        try:
            self._refresh_interface_meta()
        except Exception as exc:
            raise DataSourceError(f"binary API dump failed: {exc}") from exc
        # Everything below degrades per-feature: a gateway without the ACL or
        # NAT plugin loaded (their messages exist in the local .api.json files
        # but not in the running VPP) must show an empty screen, not a
        # disconnect loop.
        no_neighbors: tuple[Neighbor, ...] = ()
        no_routes: tuple[tuple[Route, ...], bool] = ((), False)
        no_acls: tuple[AclSet, ...] = ()
        neighbors = self._optional(self._dump_neighbors, no_neighbors, "neighbors")
        routes, counters_enabled = self._optional(
            lambda: self._dump_routes(neighbors), no_routes, "routes"
        )
        acls = self._optional(self._dump_acls, no_acls, "acls")
        nat = self._optional(self._dump_nat, NatState(), "nat")
        no_placement: tuple[RxQueuePlacement, ...] = ()
        placement = self._optional(
            self._dump_rx_placement, no_placement, "rx-placement"
        )
        return SlowSample(
            timestamp=time.time(),
            routes=routes,
            per_route_counters_enabled=counters_enabled,
            neighbors=neighbors,
            acls=acls,
            nat=nat,
            rx_placement=placement,
        )

    def _dump_rx_placement(self) -> tuple[RxQueuePlacement, ...]:
        # Tiny cli_inband read serviced by the main thread; workers never
        # see it (same posture as every other slow-path read).
        return parsers.parse_rx_placement(
            self._cli(parsers.cmd_show_rx_placement())
        )

    def _optional(self, fn: Callable[[], T], default: T, what: str) -> T:
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001 - feature absent on this gateway
            log.debug("%s dump unavailable: %s", what, exc)
            return default

    def _if_name(self, sw_if_index: int) -> str:
        meta = self._if_meta.get(sw_if_index)
        return str(meta["name"]) if meta and "name" in meta else f"if-{sw_if_index}"

    def _refresh_interface_meta(self) -> None:
        meta: dict[int, dict[str, Any]] = {}
        for detail in self._api.sw_interface_dump():
            idx = int(detail.sw_if_index)
            flags = int(getattr(detail, "flags", 0))
            # VERIFY(26.06): IF_STATUS_API_FLAG_ADMIN_UP=1, _LINK_UP=2
            meta[idx] = {
                "name": _to_str(detail.interface_name),
                "admin_up": bool(flags & 1),
                "link_up": bool(flags & 2),
                "mtu": int(detail.mtu[0]) if getattr(detail, "mtu", None) else 0,
                "addresses": [],
            }
        for idx in meta:
            try:
                for addr in self._api.ip_address_dump(sw_if_index=idx, is_ipv6=False):
                    meta[idx]["addresses"].append(str(addr.prefix))
            except Exception:  # noqa: BLE001 - address dump is best-effort
                pass
        self._if_meta = meta
        # VRF tags ride on the meta cache so the fast path (InterfaceStats),
        # neighbors and ACL attachments all read one consistent mapping.
        try:
            if_vrf = self._if_vrf_map()
        except Exception:  # noqa: BLE001 - vrf tagging is best-effort
            if_vrf = {}
        for idx in meta:
            meta[idx]["vrf"] = if_vrf.get(idx, "default")

    def _if_vrf(self, sw_if_index: int) -> str:
        meta = self._if_meta.get(sw_if_index)
        return str(meta.get("vrf", "default")) if meta else "default"

    def _if_vrf_map(self) -> dict[int, str]:
        """Map sw_if_index -> IPv4 VRF name for all known interfaces.

        VERIFY(26.06): sw_interface_get_table(sw_if_index, is_ipv6) replies
        with vrf_id = the interface's FIB table id.
        """
        names = dict(self._dump_ip4_tables())
        mapping: dict[int, str] = {}
        for idx in self._if_meta:
            try:
                reply = self._api.sw_interface_get_table(
                    sw_if_index=idx, is_ipv6=False
                )
                vrf_id = int(reply.vrf_id)
            except Exception:  # noqa: BLE001 - keep the neighbor, lose the vrf
                vrf_id = 0
            mapping[idx] = names.get(vrf_id, f"vrf-{vrf_id}")
        return mapping

    def _dump_neighbors(self) -> tuple[Neighbor, ...]:
        msg = self._find_msg(MSG_NEIGHBOR_DUMP)
        if msg is None:
            return ()
        neighbors = []
        # VERIFY(26.06): ip_neighbor_dump(sw_if_index=0xffffffff, af=ADDRESS_IP4)
        # dumps all IPv4 neighbors.
        for detail in getattr(self._api, msg)(sw_if_index=0xFFFFFFFF, af=0):
            entry = detail.neighbor
            flags = int(getattr(entry, "flags", 0))
            # VERIFY(26.06): IP_API_NEIGHBOR_FLAG_STATIC=1
            state = "static" if flags & 1 else "dynamic"
            sw_if_index = int(entry.sw_if_index)
            neighbors.append(
                Neighbor(
                    ip=str(entry.ip_address),
                    mac=str(entry.mac_address),
                    interface=self._if_name(sw_if_index),
                    state=state,
                    age_seconds=0.0,  # not exposed via the dump message
                    vrf=self._if_vrf(sw_if_index),
                )
            )
        return tuple(neighbors)

    def _dump_ip4_tables(self) -> list[tuple[int, str]]:
        """All IPv4 FIB tables (VRFs) as (table_id, display name), id order.

        VERIFY(26.06): ip_table_dump returns both address families; each
        detail.table carries table_id, is_ip6 and the (possibly VPP
        auto-generated, e.g. "ipv4-VRF:0") name.
        """
        tables: dict[int, str] = {}
        msg = self._find_msg(MSG_TABLE_DUMP)
        if msg is not None:
            for detail in getattr(self._api, msg)():
                table = detail.table
                if bool(getattr(table, "is_ip6", False)):
                    continue
                table_id = int(table.table_id)
                name = _to_str(getattr(table, "name", ""))
                # Unnamed tables get the VPP auto-name "ipv4-VRF:<id>" —
                # compact it; user-assigned names pass through untouched.
                if not name or name == f"ipv4-VRF:{table_id}":
                    name = f"vrf-{table_id}"
                tables[table_id] = name
        # Table 0 always exists; if the dump is unavailable this also keeps
        # the old single-table behaviour.
        tables[0] = "default"
        return sorted(tables.items())

    def _dump_routes(self, neighbors: tuple[Neighbor, ...]) -> tuple[tuple[Route, ...], bool]:
        msg = self._find_msg(MSG_ROUTE_DUMP)
        if msg is None:
            return (), False
        # Adjacency resolution is per-VRF: 10.0.0.1 resolved in one table
        # says nothing about the same address in another table.
        resolved_ips = {(n.vrf, n.ip) for n in neighbors if n.mac}
        counters = self._route_counters()
        routes = []
        for table_id, vrf in self._dump_ip4_tables():
            # VERIFY(26.06): ip_route_dump(table={'table_id': N, 'is_ip6': False})
            for detail in getattr(self._api, msg)(
                table={"table_id": table_id, "is_ip6": False}
            ):
                routes.append(self._parse_route(detail.route, vrf, resolved_ips, counters))
        return tuple(routes), counters is not None

    def _parse_route(
        self,
        route: Any,
        vrf: str,
        resolved_ips: set[tuple[str, str]],
        counters: list[tuple[int, int]] | None,
    ) -> Route:
        prefix = str(route.prefix)
        hops = []
        for path in route.paths[: int(route.n_paths)]:
            nh_addr = _path_nh_address(path)
            sw_if_index = int(getattr(path, "sw_if_index", 0xFFFFFFFF))
            interface = (
                self._if_name(sw_if_index) if sw_if_index != 0xFFFFFFFF else ""
            )
            # Special paths (local/receive, drop, unreach, ...) terminate
            # in the router itself: there is no adjacency to resolve.
            ptype = int(getattr(path, "type", 0))
            label = _PATH_TYPE_LABELS.get(ptype)
            if ptype != 0 and label is None:
                label = f"(special:{ptype})"
            if label is not None:
                display = f"{nh_addr} {label}".strip() if nh_addr else label
                resolved = True
            else:
                # Normal path: a via-address is usable once ARP resolved
                # its MAC; attached (no address) counts as resolved.
                display = nh_addr
                resolved = nh_addr == "" or (vrf, nh_addr) in resolved_ips
            hops.append(
                RouteNextHop(
                    address=display,
                    interface=interface,
                    weight=int(getattr(path, "weight", 1)) or 1,
                    resolved=resolved,
                    special=label is not None,
                )
            )
        stats_index = int(getattr(route, "stats_index", 0))
        packets = octets = None
        if counters is not None and stats_index < len(counters):
            packets, octets = counters[stats_index]
        # Best-effort provenance: the dump doesn't say who installed the
        # route (BGP vs static), but structural kinds are derivable.
        if hops and all(h.special for h in hops):
            source = hops[0].address.split("(")[-1].rstrip(")")
        elif hops and all(not h.address for h in hops):
            source = "connected"
        else:
            source = ""
        return Route(
            prefix=prefix,
            next_hops=tuple(hops),
            packets=packets,
            bytes=octets,
            source=source,
            vrf=vrf,
        )

    def _route_counters(self) -> list[tuple[int, int]] | None:
        """Per-route counters, when enabled in the deployment.

        VERIFY(26.06): optional (off by default at scale); when enabled the
        combined counter lives at /net/route/to indexed by stats_index.
        """
        if self._stats is None:
            return None
        try:
            paths = self._stats.ls(["^/net/route/to$"])
            if not paths:
                return None
            value = self._stats[paths[0]]
            n = max(len(per_thread) for per_thread in value)
            return [_sum_combined(value, i) for i in range(n)]
        except Exception:  # noqa: BLE001
            return None

    def _dump_acls(self) -> tuple[AclSet, ...]:
        msg = self._find_msg(MSG_ACL_DUMP)
        if msg is None:
            return ()
        hits = self._acl_hit_counters()
        attachments: dict[int, list[AclAttachment]] = {}
        attach_msg = self._find_msg(MSG_ACL_INTERFACE_DUMP)
        if attach_msg is not None:
            # VERIFY(26.06): acl_interface_list_dump: n_input of `acls` are
            # input-direction, the rest output.
            for detail in getattr(self._api, attach_msg)(sw_if_index=0xFFFFFFFF):
                if_index = int(detail.sw_if_index)
                iface = self._if_name(if_index)
                n_input = int(detail.n_input)
                for pos, acl_index in enumerate(detail.acls[: int(detail.count)]):
                    attachments.setdefault(int(acl_index), []).append(
                        AclAttachment(
                            interface=iface,
                            direction="input" if pos < n_input else "output",
                            vrf=self._if_vrf(if_index),
                        )
                    )
        acl_sets = []
        for detail in getattr(self._api, msg)(acl_index=0xFFFFFFFF):
            acl_index = int(detail.acl_index)
            # Stats rows are rules+1 on 26.06 (row 0 unused, rule r at row
            # r+1). Detect per ACL: a row at index n_rules can only exist in
            # the offset layout. Falls back to 1:1 if upstream ever fixes it.
            n_rules = int(detail.count)
            row_offset = 1 if (acl_index, n_rules) in hits else 0
            rules = []
            for i, r in enumerate(detail.r[: int(detail.count)]):
                action = int(r.is_permit)
                # VERIFY(26.06): acl_action 0=deny 1=permit 2=permit+reflect
                action_name = {0: "deny", 1: "permit", 2: "permit+reflect"}.get(
                    action, str(action)
                )
                rules.append(
                    AclRule(
                        rule_index=i,
                        action=action_name,
                        src_prefix=str(r.src_prefix),
                        dst_prefix=str(r.dst_prefix),
                        proto=_proto_name(int(r.proto)),
                        src_port_first=int(r.srcport_or_icmptype_first),
                        src_port_last=int(r.srcport_or_icmptype_last),
                        dst_port_first=int(r.dstport_or_icmpcode_first),
                        dst_port_last=int(r.dstport_or_icmpcode_last),
                        hits=hits.get((acl_index, i + row_offset), 0),
                    )
                )
            acl_sets.append(
                AclSet(
                    acl_index=acl_index,
                    tag=_to_str(detail.tag),
                    rules=tuple(rules),
                    attachments=tuple(attachments.get(acl_index, ())),
                )
            )
        return tuple(acl_sets)

    def _acl_hit_counters(self) -> dict[tuple[int, int], int]:
        """Per-rule hit counters from the stats segment, when exposed."""
        hits: dict[tuple[int, int], int] = {}
        if self._stats is None:
            return hits
        try:
            for path in self._stats.ls([STATS_ACL_PATTERN]):
                # VERIFIED live on 26.06 (2026-08-04, frr-vpp-poc): the layout
                # is /acl/<acl_index>/matches, a COMBINED counter (packets +
                # bytes — NOT simple ints) with n_rules+1 rows: row 0 is
                # always zero/unused and rule r lives at row r+1. Counters
                # stay absent-or-zero until acl_stats_intf_counters_enable is
                # called (off by default in VPP). Rows are stored raw here;
                # _dump_acls detects the +1 offset per ACL from its rule count.
                parts = path.strip("/").split("/")
                if len(parts) < 2:
                    continue
                try:
                    acl_index = int(parts[1])
                except ValueError:
                    continue
                value = self._stats[path]
                n = max((len(per_thread) for per_thread in value), default=0)
                for row in range(n):
                    hits[(acl_index, row)] = _sum_combined_packets(value, row)
        except Exception:  # noqa: BLE001 - hit counters are best-effort
            return hits
        return hits

    def _dump_nat(self) -> NatState:
        # Session count + configured limit: no typed message covers the
        # configured maximum, so parse `show nat44 summary` (quarantined).
        session_count = 0
        max_sessions = 0
        try:
            session_count, max_sessions = parsers.parse_nat44_summary(
                self._cli("show nat44 summary")
            )
        except Exception as exc:  # NAT plugin may simply not be loaded
            log.debug("nat44 summary unavailable: %s", exc)
            return NatState()

        sessions = self._dump_nat_sessions()
        no_mappings: tuple[NatStaticMapping, ...] = ()
        mappings = self._optional(
            self._dump_nat_static, no_mappings, "nat static mappings"
        )
        counters: dict[str, int] = {}
        if self._stats is not None:
            try:
                for path in self._stats.ls([STATS_NAT_PATTERN]):
                    name = path.rsplit("/", 1)[-1]
                    counters[name] = int(_flatten_sum(self._stats[path]))
            except Exception:  # noqa: BLE001
                pass
        return NatState(
            sessions=sessions,
            static_mappings=mappings,
            session_count=session_count,
            max_sessions=max_sessions,
            counters=counters,
        )

    def _dump_nat_static(self) -> tuple[NatStaticMapping, ...]:
        """Configured DNAT: static mappings (port-forwards and 1:1).

        VERIFY(26.06): nat44_static_mapping_details carries flags,
        local/external addresses+ports, protocol (IP proto number), vrf_id,
        tag. NAT_IS_ADDR_ONLY flag = 0x08: address-only 1:1 mapping, ports
        are meaningless.
        """
        msg = self._find_msg(MSG_NAT_STATIC_DUMP)
        if msg is None:
            return ()
        table_names = dict(self._dump_ip4_tables())
        mappings = []
        for d in getattr(self._api, msg)():
            addr_only = bool(int(getattr(d, "flags", 0)) & 0x08)
            vrf_id = int(getattr(d, "vrf_id", 0))
            mappings.append(
                NatStaticMapping(
                    external_addr=str(d.external_ip_address),
                    external_port=0 if addr_only else int(d.external_port),
                    local_addr=str(d.local_ip_address),
                    local_port=0 if addr_only else int(d.local_port),
                    protocol="any" if addr_only else _proto_name(int(d.protocol)),
                    vrf=table_names.get(vrf_id, f"vrf-{vrf_id}"),
                    tag=_to_str(getattr(d, "tag", "")),
                )
            )
        return tuple(mappings)

    def _dump_nat_sessions(self, limit: int = 500) -> tuple[NatSession, ...]:
        """Sample of NAT sessions via the typed dump (NAT44-ED variant).

        VERIFY(26.06): assumes the NAT44-ED plugin; the session dump message
        differs between NAT variants, hence the candidate list.
        """
        user_msg = self._find_msg(MSG_NAT_USER_DUMP)
        sess_msg = self._find_msg(MSG_NAT_SESSION_DUMP)
        if user_msg is None or sess_msg is None:
            return ()
        table_names = dict(self._dump_ip4_tables())
        sessions: list[NatSession] = []
        try:
            for user in getattr(self._api, user_msg)():
                if len(sessions) >= limit:
                    break
                user_vrf_id = int(user.vrf_id)
                user_vrf = table_names.get(user_vrf_id, f"vrf-{user_vrf_id}")
                details = getattr(self._api, sess_msg)(
                    ip_address=user.ip_address, vrf_id=user.vrf_id
                )
                for s in details:
                    if len(sessions) >= limit:
                        break
                    sessions.append(
                        NatSession(
                            inside_addr=str(s.inside_ip_address),
                            inside_port=int(s.inside_port),
                            outside_addr=str(s.outside_ip_address),
                            outside_port=int(s.outside_port),
                            protocol=_proto_name(int(s.protocol)),
                            direction="in2out",
                            age_seconds=float(getattr(s, "last_heard", 0)),
                            expire_seconds=float(getattr(s, "time_since_last_heard", 0)),
                            vrf=user_vrf,
                        )
                    )
        except Exception as exc:  # noqa: BLE001
            log.debug("nat session dump failed: %s", exc)
        return tuple(sessions)

    # -- traces (Validation screen) ------------------------------------------------

    def capture_trace(self, count: int) -> tuple[PacketTrace, ...]:
        """Passive: enable tracing on the first working input node, wait for
        real traffic to fill the buffer, then parse the accumulated traces."""
        self._cli(parsers.cmd_clear_trace())
        enabled = False
        for input_node in TRACE_INPUT_NODES:
            try:
                self._cli(parsers.cmd_trace_add(input_node, count))
                enabled = True
            except DataSourceError:
                continue  # node not present on this build (e.g. no DPDK)
        if not enabled:
            raise DataSourceError(
                f"could not enable tracing on any of {TRACE_INPUT_NODES}"
            )
        time.sleep(1.0)  # let real traffic hit the trace buffer
        text = self._cli(parsers.cmd_show_trace(count))
        return self._resolve_hw_rx(parsers.parse_show_trace(text))

    def _resolve_hw_rx(
        self, traces: tuple[PacketTrace, ...]
    ) -> tuple[PacketTrace, ...]:
        """Turn "hw:<n>" rx markers into interface names.

        af-packet/virtio/tap input trace records carry only hw_if_index; the
        name lives in `show hardware-interfaces brief`. Resolved lazily and
        only when a marker is present (dpdk traces name the port directly).
        If the lookup fails the marker stays visible — "hw:1" beats "?".
        """
        if not any(t.input_interface.startswith("hw:") for t in traces):
            return traces
        try:
            hw_names = parsers.parse_hardware_brief(
                self._cli(parsers.cmd_show_hardware_brief())
            )
        except Exception:  # noqa: BLE001 - resolution is best-effort
            return traces
        from dataclasses import replace as dc_replace

        resolved = []
        for t in traces:
            if t.input_interface.startswith("hw:"):
                name = hw_names.get(int(t.input_interface[3:]))
                if name:
                    t = dc_replace(t, input_interface=name)
            resolved.append(t)
        return tuple(resolved)

    def inject_and_trace(self, request: TraceRequest, burst: int) -> tuple[PacketTrace, ...]:
        """Active (--allow-inject only): pg stream matching the request, small
        burst, capture via pg-input tracing. Cleans the stream up afterwards."""
        if not request.ingress_interface:
            # Without an rx interface the packets arrive on the auto-created
            # pg interface, which has no IP configured — ip4 processing is
            # not enabled there and everything dies in ip4-not-enabled.
            from dataclasses import replace as dc_replace

            default = self._default_ingress()
            if default:
                request = dc_replace(request, ingress_interface=default)
        self._cli(parsers.cmd_clear_trace())
        self._cli(parsers.cmd_trace_add("pg-input", burst))
        self._cli(parsers.build_pg_stream(request, burst))
        try:
            self._cli(parsers.cmd_pg_enable())
            time.sleep(0.5)
            text = self._cli(parsers.cmd_show_trace(burst))
        finally:
            try:
                self._cli(parsers.cmd_pg_delete())
            except DataSourceError:
                pass
        traces = self._resolve_hw_rx(parsers.parse_show_trace(text))
        return tuple(
            PacketTrace(
                packet_index=t.packet_index,
                input_interface=t.input_interface,
                steps=t.steps,
                injected=True,
                worker=t.worker,
            )
            for t in traces
        )

    def start_traffic(self, request: TraceRequest, pps: int,
                      duration_seconds: int = 0,
                      packet_size: int = PG_PACKET_SIZE) -> None:
        """Traffic as limited bursts (--allow-inject only).

        Every stream carries BOTH `rate pps` and a `limit`: when VPP's rate
        limiter behaves this is a smooth pps stream; when its trapdoor fires
        (26.06 escalates unlimited rated streams to line rate) the limit
        caps the burst and the average still lands near the requested rate.

        Timed run (duration > 0): limit = pps * duration — the stream stops
        by itself and traffic_active flips False (one-shot).
        Continuous (duration = 0): limit = pps * TRAFFIC_WINDOW_SECONDS and
        the fast path re-enables the stream when a window runs out —
        field-verified on 26.06: re-enable resets the count.
        """
        if not request.ingress_interface:
            from dataclasses import replace as dc_replace

            default = self._default_ingress()
            if default:
                request = dc_replace(request, ingress_interface=default)
        self.stop_traffic()  # replace any previous stream
        window = duration_seconds if duration_seconds > 0 else TRAFFIC_WINDOW_SECONDS
        self._cli(parsers.build_pg_stream(request, burst=pps * window,
                                          pps=pps, name=parsers.PG_TRAFFIC_NAME,
                                          size=packet_size))
        # Keep the stream single-threaded before enabling it (see
        # pin_pg_placement for why: the rate limiter breaks otherwise).
        self.pin_pg_placement()
        self._cli(parsers.cmd_pg_enable(parsers.PG_TRAFFIC_NAME))
        # Safety: verify the stream actually carries the requested rate. An
        # unrated pg stream generates a full frame every poll — line rate —
        # which must never happen by accident (observed in the field when a
        # rate failed to apply). If verification itself fails, assume the
        # worst and kill the stream.
        try:
            streams = parsers.parse_pg_streams(self._cli(parsers.cmd_show_pg()))
            ours = next(
                (s for s in streams if s[0] == parsers.PG_TRAFFIC_NAME), None
            )
        except Exception as exc:
            self.stop_traffic()
            raise DataSourceError(
                f"could not verify traffic stream rate ({exc}); stream stopped"
            ) from exc
        if ours is None or not ours[1] or ours[2] <= 0:
            self.stop_traffic()
            found = "missing" if ours is None else f"enabled={ours[1]} rate={ours[2]}"
            raise DataSourceError(
                f"traffic stream did not come up rate-limited ({found}); "
                "stopped it rather than run at line rate"
            )
        self._traffic_active = True
        self._traffic_oneshot = duration_seconds > 0

    def stop_traffic(self) -> None:
        self._traffic_active = False
        self._traffic_oneshot = False
        for command in (parsers.cmd_pg_disable(parsers.PG_TRAFFIC_NAME),
                        parsers.cmd_pg_delete(parsers.PG_TRAFFIC_NAME)):
            try:
                self._cli(command)
            except Exception:  # noqa: BLE001 - stream may simply not exist
                pass

    @property
    def traffic_active(self) -> bool:
        return self._traffic_active

    def _maybe_rearm_traffic(self) -> None:
        """Watch the traffic stream once per fast tick while active.

        Continuous mode re-enables the stream when its window's limit ran
        out; a timed run instead flips traffic_active off (done). A stream
        that vanished (VPP restart, manual delete) deactivates traffic
        instead of failing the sample.
        """
        if not self._traffic_active:
            return
        try:
            streams = parsers.parse_pg_streams(self._cli(parsers.cmd_show_pg()))
            ours = next(
                (s for s in streams if s[0] == parsers.PG_TRAFFIC_NAME), None
            )
            if ours is None:
                self._traffic_active = False
                return
            if not ours[1]:  # stream stopped: limit reached
                if self._traffic_oneshot:
                    self._traffic_active = False  # timed run finished
                else:
                    self._cli(parsers.cmd_pg_enable(parsers.PG_TRAFFIC_NAME))
        except Exception:
            log.exception("traffic re-arm failed; leaving stream stopped")
            self._traffic_active = False

    def pin_pg_placement(self, worker: int = 0) -> None:
        """Pin the pg interface's rx queues to a single worker.

        Works around a VPP rate-limiter trapdoor: pg_input_stream computes
        `dt = vlib_time_now(vm) - s->time_last_generate` where the clock is
        per-thread but time_last_generate is per-stream. If two threads poll
        one stream, dt can go negative; `n_packets = s->packet_accumulator`
        then casts a negative f64 to uword (~1.8e19), gets clamped to
        n_max_frame (256), and the accumulator is driven permanently
        negative — so every later call emits a full frame, i.e. line rate,
        regardless of the configured rate. Keeping the stream on one thread
        keeps dt monotonic. VERIFY(26.06): pg interface naming (pg-N).
        """
        for meta in self._if_meta.values():
            name = str(meta.get("name", ""))
            if name.startswith("pg-"):
                for queue in (0, 1):
                    try:
                        self._cli(
                            f"set interface rx-placement {name} queue {queue} "
                            f"worker {worker}"
                        )
                    except Exception:  # noqa: BLE001 - queue may not exist
                        pass

    def _default_ingress(self) -> str:
        """A sensible rx interface for injection: admin-up, has an IP, and is
        a real port (not local/loopback/pg/tap)."""
        for idx in sorted(self._if_meta):
            meta = self._if_meta[idx]
            name = str(meta.get("name", ""))
            if (
                meta.get("admin_up")
                and meta.get("addresses")
                and not name.startswith(("local", "loop", "pg", "tap"))
            ):
                return name
        return ""


# -- small helpers --------------------------------------------------------------


def _to_str(value: Any) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace").rstrip("\x00")
    return str(value).rstrip("\x00")


_STAT_TYPE_SYMLINK = 6  # vpp_papi StatsEntry stattype for symlinked counters
_SYMLINK_TARGET = Struct("II")  # (target directory index, column index)
_SYMLINK_RAW = Struct("Q")


def _dump_error_counts(stats: Any, paths: list[str]) -> dict[str, int]:
    """Total each /err/ counter, resolving symlinks via one shared read.

    On VPP 26.06 every /err/<node>/<reason> entry is a symlink into the
    shared /node/errors vector, and vpp_papi resolves EACH symlink by
    reading that entire vector: O(N^2) over ~3000 counters costs more than
    the whole fast-poll interval (1.18 s measured live vs the 1.0 s
    cadence), so the poller loop never slept and pegged a core. Instead,
    read each distinct target vector once, total it per column, and index
    the symlinks into those totals. Entries that are not symlinks (older
    VPP, tests) or that race a directory refresh take vpp_papi's normal
    per-counter read.
    """
    counts: dict[str, int] = {}
    fallback: list[str] = []
    column_sums: dict[int, list[int]] = {}
    for path in paths:
        try:
            entry = stats.directory[path]
            if entry.type != _STAT_TYPE_SYMLINK:
                fallback.append(path)
                continue
            target, column = _SYMLINK_TARGET.unpack(_SYMLINK_RAW.pack(entry.value))
            sums = column_sums.get(target)
            if sums is None:
                vector = stats[stats.directory_by_idx[target]]
                sums = [sum(per_thread) for per_thread in zip(*vector, strict=True)]
                column_sums[target] = sums
            counts[path] = int(sums[column]) if column < len(sums) else 0
        except Exception:  # noqa: BLE001 - stale directory entry mid-refresh
            fallback.append(path)
    for path, value in stats.dump(fallback).items():
        try:
            counts[path] = int(_flatten_sum(value))
        except (TypeError, ValueError):
            continue
    return counts


def _try_get(stats: Any, path: str) -> Any | None:
    try:
        return stats[path]
    except Exception:  # noqa: BLE001 - path may not exist
        return None


def _flatten_sum(value: Any) -> int:
    """Sum arbitrarily nested per-worker counter lists."""
    if isinstance(value, (int, float)):
        return int(value)
    total = 0
    try:
        for item in value:
            total += _flatten_sum(item)
    except TypeError:
        return 0
    return total


def _proto_name(proto: int) -> str:
    return {0: "any", 1: "icmp", 6: "tcp", 17: "udp", 58: "icmp6"}.get(proto, str(proto))


def _path_nh_address(path: Any) -> str:
    """Extract the next-hop address from a fib_path, tolerating layout drift.

    VERIFY(26.06): fib_path.nh.address is a union (ip4/ip6); vpp_papi decodes
    it into an object whose str() is the printable address on this release.
    """
    nh = getattr(path, "nh", None)
    if nh is None:
        return ""
    address = getattr(nh, "address", None)
    if address is None:
        return ""
    for field in ("ip4", "ip6"):
        value = getattr(address, field, None)
        if value is not None and str(value) not in ("0.0.0.0", "::", ""):
            return str(value)
    # All-zero union: the path has no gateway address (attached/special).
    # Never fall back to str(address) — that is a Python repr, not an IP.
    return ""
