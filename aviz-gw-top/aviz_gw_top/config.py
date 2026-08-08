"""Central configuration: version pin, socket paths, refresh cadences, thresholds.

Every tunable and every environment assumption lives here. Nothing else in the
codebase hard-codes a socket path, refresh interval, or color threshold.
"""

from __future__ import annotations

from dataclasses import dataclass

# The VPP release this tool is written and tested against. Checked (not enforced)
# at startup: a mismatch produces a warning banner, never a hard failure.
TARGET_VPP_VERSION = "26.06"

# Default socket paths for a stock VPP install. Overridable via CLI flags.
DEFAULT_STATS_SOCKET = "/run/vpp/stats.sock"
DEFAULT_API_SOCKET = "/run/vpp/api.sock"

# Polling cadences (seconds).
DEFAULT_FAST_INTERVAL = 1.0   # stats segment: interfaces, nodes, workers, errors
DEFAULT_SLOW_INTERVAL = 5.0   # binary API dumps: FIB, ACL, NAT, neighbors

# How long the poller waits before retrying after VPP disappears.
RECONNECT_INTERVAL = 2.0

# Maximum vector size in VPP's graph scheduler; vectors-per-call approaches this
# as a worker saturates.
VPP_MAX_VECTOR_SIZE = 256

# Continuous traffic (screen 5 Send) is driven as re-armed windowed bursts:
# each pg stream carries `limit pps * WINDOW` alongside `rate pps`, and the
# poller re-enables it when the window runs out. VPP 26.06's rate limiter has
# a float->uword trapdoor that escalates an unlimited stream to line rate;
# the limit caps the damage of one window even when that fires (verified in
# the field: re-enable resets the stream's count, so re-arming is cheap).
TRAFFIC_WINDOW_SECONDS = 10

# Default generated-packet size (bytes, IP header included). At 128 B a
# 10 Gb/s target needs ~9.7M pps — pg's single-worker ceiling — while at
# 1500 B it is only ~833K pps, so benchmarking runs should raise the size.
# Capped at 2048: pg's default buffer-size, above which packets would need
# chained buffers (unverified on 26.06).
PG_PACKET_SIZE = 128
PG_PACKET_SIZE_MAX = 2048

# Longest timed Send run selectable in the UI (duration 0 = until stopped).
TRAFFIC_DURATION_MAX = 3600


@dataclass(frozen=True)
class Thresholds:
    """Coloring thresholds. Values are starting heuristics — tune against real
    measurement of the target deployment."""

    # vectors-per-call: the leading saturation signal.
    vpc_warn: float = 32.0
    vpc_crit: float = 128.0

    # NAT session table utilization (fraction of configured max).
    nat_util_warn: float = 0.60
    nat_util_crit: float = 0.85

    # Estimated worker utilization (fraction of cycles doing packet work).
    worker_util_warn: float = 0.60
    worker_util_crit: float = 0.85


THRESHOLDS = Thresholds()

# Trace defaults for the Validation screen.
TRACE_PACKET_COUNT = 16          # packets to capture per passive trace run
INJECT_BURST_SIZE = 4            # packets injected per active-inject run
TRACE_INPUT_NODES = (            # input nodes tracing is enabled on, in order tried
    "dpdk-input",
    "tap-input",                 # tap/virtio devices (observed on 26.06)
    "af-packet-input",
    "virtio-input",
    "memif-input",
    "pg-input",
)
