"""Background poller: owns the DataSource, computes rates, publishes snapshots.

One thread owns all gateway I/O — both the stats-segment reads and the binary
API — on two cadences (fast/slow). It publishes immutable GatewayState
snapshots via an atomic attribute swap; the UI reads `poller.state` and never
blocks on gateway I/O. Trace runs are funneled through the same thread with
submit(), because the underlying API client is not thread-safe.

Counter mechanics honored here:
- All source counters are cumulative and monotonic; every per-second rate in
  the published models is computed here from consecutive samples.
- A decrease means the gateway restarted: RateTracker re-baselines and emits
  0.0 for that window instead of a negative rate.
"""

from __future__ import annotations

import queue
import threading
import time
from collections import deque
from collections.abc import Callable
from concurrent.futures import Future
from dataclasses import dataclass, replace
from typing import Any, TypeVar

from ..config import (
    DEFAULT_FAST_INTERVAL,
    DEFAULT_SLOW_INTERVAL,
    RECONNECT_INTERVAL,
    TARGET_VPP_VERSION,
    VPP_MAX_VECTOR_SIZE,
)
from ..model import (
    GatewayState,
    NatState,
    NodeStats,
    SystemInfo,
    WorkerStats,
)
from .base import (
    NAT_COUNTER_CREATED,
    NAT_COUNTER_EXPIRED,
    DataSource,
    FastSample,
    SlowSample,
)

T = TypeVar("T")


@dataclass
class _RateState:
    value: float          # last observed counter value
    changed_ts: float     # when the value last changed
    interval: float | None  # observed time between the last two changes
    rate: float           # rate computed at the last change


class RateTracker:
    """Per-key rate computation over consecutive cumulative samples.

    Two stats-segment quirks are handled here:

    * Counter reset (VPP restart): a decrease re-baselines and emits 0.0,
      never a negative rate.
    * Slow-updating counters: VPP's stats collector refreshes some segments
      (notably /sys/node/*) only every ~10 s — much slower than our sampling.
      A naive delta/sample-dt yields 0, 0, ..., 0, then one sample at ~10x
      the true rate. Instead, rates are computed over the counter's *own*
      change interval, held steady between changes, and decayed to zero once
      the counter has stayed quiet for about two of its update intervals
      (i.e. traffic genuinely stopped).
    """

    def __init__(self) -> None:
        self._prev: dict[str, _RateState] = {}

    def rate(self, key: str, value: float, timestamp: float) -> float:
        st = self._prev.get(key)
        if st is None or value < st.value:
            # First sample, or counter went backwards (restart): re-baseline.
            self._prev[key] = _RateState(value, timestamp, None, 0.0)
            return 0.0
        if value > st.value:
            dt = timestamp - st.changed_ts
            if dt <= 0:
                self._prev[key] = _RateState(value, timestamp, st.interval, 0.0)
                return 0.0
            rate = (value - st.value) / dt
            self._prev[key] = _RateState(value, timestamp, dt, rate)
            return rate
        # Unchanged: hold the last rate while within the counter's observed
        # update cadence; after ~2 intervals of silence, report zero.
        if st.interval is None:
            return 0.0
        if timestamp - st.changed_ts <= 2.0 * st.interval + 0.5:
            return st.rate
        st.rate = 0.0
        return 0.0

    def reset(self) -> None:
        self._prev.clear()


class SteadyRateDetector:
    """Flags counters ticking at a near-constant nonzero rate.

    A drop rate that holds steady across many measurement windows is a
    periodicity fingerprint — probes, retries, keepalives — which almost
    always means a config mismatch rather than load (this is how the
    dead-BFD-vs-NAT incident was found in the field, 2026-08-10).

    Judged over DISTINCT rate values, not poll ticks: /err counters refresh
    only every ~10 s and RateTracker holds the rate between refreshes, so
    consecutive identical readings are one measurement, not evidence of
    steadiness. With ~10 s windows, flagging takes about a minute — fine,
    since the anomalies this catches persist for hours.
    """

    WINDOW = 6          # distinct measurements required before judging
    TOLERANCE = 0.25    # allowed (max-min)/mean spread within the window
    MIN_RATE = 0.01     # ignore near-zero drift

    def __init__(self) -> None:
        self._history: dict[str, deque[float]] = {}

    def update(self, key: str, rate: float) -> bool:
        h = self._history.setdefault(key, deque(maxlen=self.WINDOW))
        if rate <= 0.0:
            # Counter went quiet: whatever was periodic has stopped.
            h.clear()
            return False
        if not h or rate != h[-1]:
            h.append(rate)
        if len(h) < self.WINDOW:
            return False
        mean = sum(h) / len(h)
        if mean < self.MIN_RATE:
            return False
        return (max(h) - min(h)) <= self.TOLERANCE * mean

    def reset(self) -> None:
        self._history.clear()


class Poller:
    def __init__(
        self,
        source: DataSource,
        fast_interval: float = DEFAULT_FAST_INTERVAL,
        slow_interval: float = DEFAULT_SLOW_INTERVAL,
    ) -> None:
        self._source = source
        self._fast_interval = fast_interval
        self._slow_interval = slow_interval
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._paused = threading.Event()
        self._jobs: queue.Queue[tuple[Callable[[], Any], Future[Any]]] = queue.Queue()
        self._rates = RateTracker()
        self._steady = SteadyRateDetector()
        self._last_slow: SlowSample | None = None
        self._last_slow_time = 0.0
        self._state = GatewayState(system=SystemInfo(last_error="starting up"))
        self.version = 0  # bumped on every publish; UI re-renders on change

    # -- lifecycle -------------------------------------------------------------

    @property
    def state(self) -> GatewayState:
        return self._state

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="gw-poller", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5.0)
        self._source.disconnect()

    def toggle_pause(self) -> bool:
        """Toggle refresh pause; returns True when now paused."""
        if self._paused.is_set():
            self._paused.clear()
        else:
            self._paused.set()
        return self._paused.is_set()

    @property
    def paused(self) -> bool:
        return self._paused.is_set()

    def submit(self, fn: Callable[[], T]) -> Future[T]:
        """Run `fn` on the poller thread (all gateway I/O stays on one thread).

        Used by the Validation screen for trace capture/injection. The caller
        waits on the returned Future from a UI worker thread, never the UI
        event loop.
        """
        fut: Future[T] = Future()
        self._jobs.put((fn, fut))
        return fut

    # -- main loop ---------------------------------------------------------------

    def _run(self) -> None:
        connected = False
        while not self._stop.is_set():
            if not connected:
                connected = self._try_connect()
                if not connected:
                    self._stop.wait(RECONNECT_INTERVAL)
                    continue
            self._drain_jobs()
            if self._paused.is_set():
                self._stop.wait(0.2)
                continue
            started = time.monotonic()
            try:
                fast = self._source.sample_fast()
                slow = self._maybe_sample_slow(fast.timestamp)
                self._publish(fast, slow)
            except Exception as exc:  # gateway went away mid-sample
                connected = False
                self._publish_disconnected(str(exc))
                self._source.disconnect()
                continue
            elapsed = time.monotonic() - started
            self._stop.wait(max(0.05, self._fast_interval - elapsed))

    def _try_connect(self) -> bool:
        try:
            self._source.connect()
        except Exception as exc:
            self._publish_disconnected(str(exc))
            return False
        # Fresh connection: previous baselines are meaningless.
        self._rates.reset()
        self._steady.reset()
        self._last_slow = None
        self._last_slow_time = 0.0
        return True

    def _drain_jobs(self) -> None:
        while True:
            try:
                fn, fut = self._jobs.get_nowait()
            except queue.Empty:
                return
            if not fut.set_running_or_notify_cancel():
                continue
            try:
                fut.set_result(fn())
            except Exception as exc:
                fut.set_exception(exc)

    def _maybe_sample_slow(self, now: float) -> SlowSample | None:
        if self._last_slow is not None and now - self._last_slow_time < self._slow_interval:
            return self._last_slow
        sample = self._source.sample_slow()
        self._last_slow_time = now
        self._last_slow = self._compute_slow_rates(sample)
        return self._last_slow

    def _publish_disconnected(self, error: str) -> None:
        old = self._state
        self._state = replace(
            old,
            system=replace(old.system, connected=False, last_error=error),
            timestamp=time.time(),
        )
        self.version += 1

    # -- rate computation ----------------------------------------------------------

    def _publish(self, fast: FastSample, slow: SlowSample | None) -> None:
        ts = fast.timestamp
        rate = self._rates.rate

        interfaces = tuple(
            replace(
                i,
                rx_pps=rate(f"if.{i.name}.rxp", i.rx_packets, ts),
                rx_bps=rate(f"if.{i.name}.rxb", i.rx_bytes, ts) * 8,
                tx_pps=rate(f"if.{i.name}.txp", i.tx_packets, ts),
                tx_bps=rate(f"if.{i.name}.txb", i.tx_bytes, ts) * 8,
                rx_drops_delta=rate(f"if.{i.name}.rxd", i.rx_drops, ts),
                tx_drops_delta=rate(f"if.{i.name}.txd", i.tx_drops, ts),
                rx_pps_per_worker=tuple(
                    rate(f"if.{i.name}.rxw{t}", pkts, ts)
                    for t, pkts in enumerate(i.rx_packets_per_worker)
                ),
            )
            for i in fast.interfaces
        )

        nodes = tuple(self._node_with_rates(n, ts) for n in fast.nodes)

        workers = []
        for w in fast.workers:
            calls_ps = rate(f"wk.{w.index}.calls", w.calls, ts)
            vectors_ps = rate(f"wk.{w.index}.vectors", w.vectors, ts)
            clocks_ps = rate(f"wk.{w.index}.clocks", w.clocks, ts)
            vpc = vectors_ps / calls_ps if calls_ps > 0 else 0.0
            workers.append(
                WorkerStats(
                    worker_index=w.index,
                    name=w.name,
                    core_id=w.core_id,
                    vectors_per_call=vpc,
                    clocks_per_packet=clocks_ps / vectors_ps if vectors_ps > 0 else 0.0,
                    calls_per_sec=calls_ps,
                    vectors_per_sec=vectors_ps,
                    # Vector fill as the saturation estimate. A clocks/CPU-Hz
                    # ratio is meaningless on DPDK poll-mode workers: they
                    # burn 100% of a core spinning even when idle.
                    utilization=min(1.0, vpc / VPP_MAX_VECTOR_SIZE),
                )
            )

        err_list = []
        for e in fast.errors:
            key = f"err.{e.node}.{e.reason}"
            r = rate(key, e.count, ts)
            err_list.append(replace(e, rate=r, steady=self._steady.update(key, r)))
        errors = tuple(err_list)
        total_drops = sum(e.count for e in errors) + sum(
            i.rx_drops + i.tx_drops for i in fast.interfaces
        )
        total_drops_rate = sum(e.rate for e in errors) + sum(
            i.rx_drops_delta + i.tx_drops_delta for i in interfaces
        )

        system = replace(
            fast.system,
            version_mismatch=bool(
                fast.system.version and TARGET_VPP_VERSION not in fast.system.version
            ),
        )
        prev = self._last_slow if slow is None else slow
        self._state = GatewayState(
            system=system,
            timestamp=ts,
            interfaces=interfaces,
            nodes=nodes,
            workers=tuple(workers),
            errors=errors,
            total_rx_pps=sum(i.rx_pps for i in interfaces),
            total_tx_pps=sum(i.tx_pps for i in interfaces),
            total_drops=total_drops,
            total_drops_rate=total_drops_rate,
            routes=prev.routes if prev else (),
            per_route_counters_enabled=prev.per_route_counters_enabled if prev else False,
            neighbors=prev.neighbors if prev else (),
            acls=prev.acls if prev else (),
            nat=prev.nat if prev else NatState(),
            rx_placement=prev.rx_placement if prev else (),
        )
        self.version += 1

    def _node_with_rates(self, n: NodeStats, ts: float) -> NodeStats:
        rate = self._rates.rate
        calls_ps = rate(f"nd.{n.name}.calls", n.calls, ts)
        vectors_ps = rate(f"nd.{n.name}.vectors", n.vectors, ts)
        clocks_ps = rate(f"nd.{n.name}.clocks", n.clocks, ts)
        return replace(
            n,
            vectors_per_call=vectors_ps / calls_ps if calls_ps > 0 else 0.0,
            clocks_per_packet=clocks_ps / vectors_ps if vectors_ps > 0 else 0.0,
            calls_per_sec=calls_ps,
            vectors_per_sec=vectors_ps,
            clocks_per_sec=clocks_ps,
            calls_ps_per_worker=tuple(
                rate(f"nd.{n.name}.c{t}", v, ts)
                for t, v in enumerate(n.calls_per_worker)
            ),
            vectors_ps_per_worker=tuple(
                rate(f"nd.{n.name}.v{t}", v, ts)
                for t, v in enumerate(n.vectors_per_worker)
            ),
            clocks_ps_per_worker=tuple(
                rate(f"nd.{n.name}.k{t}", v, ts)
                for t, v in enumerate(n.clocks_per_worker)
            ),
        )

    def _compute_slow_rates(self, sample: SlowSample) -> SlowSample:
        ts = sample.timestamp
        rate = self._rates.rate
        routes = tuple(
            replace(r, pps=rate(f"rt.{r.vrf}.{r.prefix}", r.packets, ts))
            if r.packets is not None
            else r
            for r in sample.routes
        )
        acls = tuple(
            replace(
                a,
                rules=tuple(
                    replace(r, hit_rate=rate(f"acl.{a.acl_index}.{r.rule_index}", r.hits, ts))
                    for r in a.rules
                ),
            )
            for a in sample.acls
        )
        nat = sample.nat
        counter_rates = {
            name: rate(f"nat.{name}", value, ts) for name, value in nat.counters.items()
        }
        nat = replace(
            nat,
            created_per_sec=counter_rates.get(NAT_COUNTER_CREATED, 0.0),
            expired_per_sec=counter_rates.get(NAT_COUNTER_EXPIRED, 0.0),
            counter_rates=counter_rates,
        )
        return replace(sample, routes=routes, acls=acls, nat=nat)
