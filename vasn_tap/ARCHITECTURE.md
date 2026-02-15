# vasn_tap Architecture

This document describes the internal architecture of vasn_tap, its modules, data flows, and key design decisions. It is intended for developers working on or extending the codebase.

## High-Level Overview

vasn_tap is a lightweight packet tap that runs on customer operating systems. It transparently captures a copy of all network traffic from a specified interface, performs optional processing in userspace, and forwards the packets to an output interface (typically connected to an Aviz Service Node on-prem).

```
  Customer Network                    vasn_tap                    Aviz Service Node
  ================               ==================              ===================

  +-----------+                  +------------------+            +------------------+
  | Customer  |   raw traffic    |  capture         |  forwarded |                  |
  | Interface |  ------------->  |  optional filter |  --------> |  ASN (on-prem)   |
  | (eth0)    |  (not modified)  |  (YAML -c)       |  (eth1)   |                  |
  +-----------+                  |  stats / -F dump |            +------------------+
       |                         +------------------+
       |  original traffic              |
       |  continues normally            | L2/L3/L4 ACL (filter.c), then tx_ring
       v                                |
   [Normal stack]                  [Stats, logging]
```

The application supports **two capture backends** selected at startup via the `-m` flag:

1. **eBPF mode** (`-m ebpf`): Uses TC BPF hooks in the kernel to clone packets into a perf buffer, consumed by a single worker thread.
2. **AF_PACKET mode** (`-m afpacket`): Uses TPACKET_V3 mmap'd ring buffers with PACKET_FANOUT_HASH for multi-worker distribution.

## Module Map

```
                          +------------------+
                          |  main.c          |  Entry point, signal handling
                          |  cli.c           |  Argument parsing
                          |  config.c       |  YAML filter config load
                          |  filter.c       |  ACL filter_packet (L2/L3/L4)
                          +--------+---------+
                                   |
                      mode selection (g_capture_mode)
                       /                    \
                      /                      \
            +--------+--------+      +--------+---------+
            | eBPF Backend    |      | AF_PACKET Backend |
            |                 |      |                   |
            |  tap.c          |      |  afpacket.c       |
            |  worker.c       |      |  (self-contained) |
            |  ebpf/tc_clone  |      |                   |
            +--------+--------+      +--------+----------+
                     |                         |
                     +------------+------------+
                     |                         |
                     v                         v
               +------------------------------------------+
               |  tx_ring.c / tx_ring.h                   |
               |  Shared TPACKET_V2 mmap TX ring          |
               |  (both modes use same zero-copy output)  |
               +------------------------------------------+
```

> **Note:** Both eBPF and AF_PACKET use the **shared** `tx_ring` module for
> high-performance output (mmap'd TX ring, batch flush). The `output.c` module
> is no longer used by the main binary; it remains only for the `test_output` unit tests.

## Module Details

### main.c -- Entry Point

**File:** `src/main.c`

Responsibilities:
- Parses CLI arguments via `parse_args()` from `cli.c`
- Sets up signal handlers (SIGINT, SIGTERM) for graceful shutdown
- Selects capture mode and initializes the appropriate backend
- Runs the main loop: periodic stats printing, wait for signal
- On shutdown: stops workers, detaches hooks, cleans up resources

Key globals:
- `g_tap_ctx` -- eBPF tap context
- `g_worker_ctx` -- eBPF worker context
- `g_afpacket_ctx` -- AF_PACKET context
- `g_capture_mode` -- selected mode (from CLI)
- `g_running` -- volatile flag, set to false on SIGINT

### cli.c -- Argument Parsing

**File:** `src/cli.c`, `src/cli.h`

Extracted from `main.c` to make CLI parsing independently testable. Uses `getopt_long()` with re-entrant support (`optind = 1` reset).

Key struct:

```c
struct cli_args {
    char input_iface[64];    // -i / --input
    char output_iface[64];   // -o / --output
    enum capture_mode mode;  // -m / --mode (CAPTURE_MODE_EBPF or CAPTURE_MODE_AFPACKET)
    int num_workers;         // -w / --workers (0 = auto-detect)
    bool verbose;            // -v
    bool show_stats;         // -s
    bool help;               // -h
};
```

Return values: `0` = success, `1` = help requested, `-1` = error.

CLI also supports `-c, --config <path>` (filter config YAML), `--validate-config` (load/validate and exit), and `-F, --filter-stats` (periodically dump filter rules and per-rule hit counts when a filter config is loaded).

### config.c -- Filter Config (YAML)

**File:** `src/config.c`, `src/config.h`

Loads the filter (ACL) configuration from a YAML file. Used when `-c` is set. Parsing is a single-pass libyaml event stream: top-level key **filter**, then **default_action** (scalar) and **rules** (sequence of mappings); each rule has **action** and an optional **match** mapping (protocol, port_src, port_dst, ip_src, ip_dst, eth_type).

- **config_load(path)** — Opens file, parses YAML, fills `struct tap_config` (filter section). On error returns NULL and sets a static error message (retrievable via **config_get_error()**).
- **config_free(cfg)** — Frees the config. Safe to call with NULL.

Config layout: **filter.default_action** (`allow` | `drop`), **filter.rules[]** — each rule has **action** and optional **match** (protocol, port_src, port_dst, ip_src, ip_dst, eth_type). Validation is done at load; invalid files cause startup failure (no "allow all" fallback). Config is read once at startup; restart required for changes.

### filter.c -- Packet Filter (ACL)

**File:** `src/filter.c`, `src/filter.h`

Implements first-match ACL: for each packet, **filter_packet(cfg, pkt_data, pkt_len, matched_rule_index)** parses L2 (ethertype), L3 (IPv4 src/dst, protocol), L4 (TCP/UDP ports) and returns **FILTER_ACTION_ALLOW** or **FILTER_ACTION_DROP**. The optional **matched_rule_index** out-parameter is set to the rule index (0..num_rules-1) or -1 for default_action. No packet copy; first matching rule wins, else **default_action**. Main sets **g_filter_config** after load and calls **filter_stats_reset()**; AF_PACKET and eBPF workers call **filter_packet** before **tx_ring_write**, increment **filter_rule_hits[slot]** (per-rule or default slot), and on DROP skip TX. When **-F (--filter-stats)** is set, the stats loop aggregates these atomics and prints a rule dump (rule text plus hit counts); without **-F**, counters are still updated but no read/print is done.

### tap.c -- eBPF Tap Module

**File:** `src/tap.c`, `src/tap.h`

Manages the eBPF lifecycle for the TC-based capture mode.

Key struct:

```c
struct tap_ctx {
    struct bpf_object *obj;   // Loaded BPF object (tc_clone.bpf.o)
    int ingress_fd;           // Ingress program FD
    int egress_fd;            // Egress program FD
    int ifindex;              // Target interface index
    char ifname[64];          // Target interface name
    bool attached;            // Whether TC hooks are attached
};
```

Lifecycle:
1. `tap_init()` -- Opens and loads `tc_clone.bpf.o` via libbpf, resolves program FDs
2. `tap_attach()` -- Adds `clsact` qdisc, pins BPF programs under `/sys/fs/bpf/vasn_tap/`, attaches via `tc filter add`
3. `tap_detach()` -- Removes TC filters and qdisc
4. `tap_cleanup()` -- Closes the BPF object, frees resources

### worker.c -- Perf Buffer Consumer (eBPF mode)

**File:** `src/worker.c`, `src/worker.h`

Consumes packets from the eBPF perf buffer and optionally forwards them.

Key structs:

```c
struct worker_stats {
    _Atomic uint64_t packets_received;
    _Atomic uint64_t packets_sent;
    _Atomic uint64_t packets_dropped;
    _Atomic uint64_t bytes_received;
    _Atomic uint64_t bytes_sent;
};

struct worker_ctx {
    struct worker_config config;
    struct bpf_object *bpf_obj;   // Reference to BPF object from tap.c
    struct perf_buffer *pb;       // libbpf perf buffer handle
    struct tx_ring_ctx tx_ring;   // Shared TPACKET_V2 TX ring (tx_ring.fd == -1 if drop)
    unsigned int tx_pending;      // Packets written since last flush (batching)
    volatile bool running;
    pthread_t *threads;
    struct worker_stats *stats;
};
```

Design notes:
- **Forced single-threaded**: `num_workers` is always set to 1 because the perf buffer polls events from all CPUs in a single `perf_buffer__poll()` call.
- Worker thread is pinned to CPU 0 via `pthread_setaffinity_np`.
- Callback `handle_sample()` receives `struct pkt_meta` (defined in `common.h`) and forwards via the **shared TX ring** (`tx_ring_write()` + flush every 32 packets for batching).

### afpacket.c -- AF_PACKET Backend

**File:** `src/afpacket.c`, `src/afpacket.h`

Self-contained multi-worker capture backend using TPACKET_V3 for RX and TPACKET_V2 for TX.

Key structs:

```c
struct afpacket_config {
    char input_ifname[64];
    int  input_ifindex;
    char output_ifname[64];
    int  output_ifindex;       // 0 = drop mode
    int  num_workers;
    bool verbose;
};

struct afpacket_worker {
    /* RX: TPACKET_V3 mmap ring on input interface */
    int                  rx_fd;          // AF_PACKET RX socket
    void                *rx_ring;        // mmap'd TPACKET_V3 ring
    unsigned int         ring_size;      // Total RX mmap size
    struct iovec        *rd;             // Block descriptor iovecs
    unsigned int         block_nr;       // Number of RX blocks
    unsigned int         current_block;  // Current RX block index

    /* TX: shared TPACKET_V2 mmap ring (tx.fd == -1 means drop mode) */
    struct tx_ring_ctx   tx;

    struct worker_stats  stats;          // Per-worker statistics
};

struct afpacket_ctx {
    struct afpacket_config  config;
    struct afpacket_worker *workers;
    volatile bool           running;
    pthread_t              *threads;
};
```

Internal functions:
- `setup_rx_socket()` -- Creates AF_PACKET socket, sets TPACKET_V3, configures `PACKET_RX_RING`, binds to input interface, `mmap()`s the RX ring
- `join_fanout()` -- Sets `PACKET_FANOUT` with `PACKET_FANOUT_HASH | PACKET_FANOUT_FLAG_DEFRAG | PACKET_FANOUT_FLAG_ROLLOVER`
- `process_block()` -- Iterates packets in a TPACKET_V3 RX block; for each packet calls `tx_ring_write(&worker->tx, ...)` (shared module), then `tx_ring_flush(&worker->tx)` at end of block
- `afpacket_worker_thread()` -- Main worker loop: `poll()` -> `process_block()` -> release block

RX ring buffer defaults (configurable in `afpacket.h`):
- Block size: 256 KB
- Block count: 64 (= 16 MB per worker)
- Frame size: 2048 bytes
- Block timeout: 100 ms

TX is handled by the **shared** `tx_ring` module (see below).

### tx_ring.c -- Shared TX Output (both modes)

**File:** `src/tx_ring.c`, `src/tx_ring.h`

Shared TPACKET_V2 mmap'd TX ring used by **both** eBPF and AF_PACKET backends. Ensures a single, optimized output path and consistent throughput in either mode.

```c
struct tx_ring_ctx { ... };   // fd, ring, frame_nr, frame_size, current, max_tx_len, debug

int  tx_ring_setup(struct tx_ring_ctx *ctx, int ifindex, bool verbose, bool debug);
void tx_ring_teardown(struct tx_ring_ctx *ctx);
int  tx_ring_write(struct tx_ring_ctx *ctx, const void *data, uint32_t len);  // 0 = ok, -1 = dropped
void tx_ring_flush(struct tx_ring_ctx *ctx);
```

- **AF_PACKET**: Each worker has its own `struct tx_ring_ctx tx`; `tx_ring_setup()` is called per worker in `afpacket_init()`. In `process_block()`, if **g_filter_config** is set, **filter_packet()** is called first; on DROP the packet is counted as dropped and not written. Flush happens once per RX block.
- **eBPF**: Single `struct tx_ring_ctx tx_ring` in `worker_ctx`; `tx_ring_setup()` in `workers_init()`. In `handle_sample()`, if **g_filter_config** is set, **filter_packet()** is called first; on DROP the packet is counted as dropped and not written. Otherwise `tx_ring_write()` and flush every 32 packets to batch syscalls.

  +---------+     +------------------+     +-----------+     +-------------------+
  |   NIC   | --> | AF_PACKET Socket | --> | Worker 0  | --> | tx_ring (shared   |
  | (eth0)  |     | TPACKET_V3 RX    |     |           |     | module) ring 0    | --> eth1
  +---------+     | ring (mmap'd)    |     +-----------+     +-------------------+
                  |                  |
                  | PACKET_FANOUT    | --> | Worker 1  | --> | tx_ring ring 1    | --> eth1
                  | _HASH            |     +-----------+     +-------------------+
                  |                  |
                  |                  | --> | Worker 2  | --> | tx_ring ring 2    | --> eth1
                  +------------------+     +-----------+     +-------------------+
                          |                       |                    |
                    Kernel distributes       filter then          tx_ring_flush()
                    packets by 5-tuple       tx_ring_write()      per RX block
                    hash (flow affinity)
```

Characteristics:
- Each worker has its own mmap'd RX ring (TPACKET_V3) and its own **shared-module** TX ring (one `struct tx_ring_ctx` per worker)
- **RX path**: TPACKET_V3 variable-length blocks — kernel fills blocks, worker polls via `poll()`
- **TX path**: Shared `tx_ring` — worker calls `tx_ring_write()` then `tx_ring_flush()` once per RX block (one syscall per block)
- FANOUT_HASH ensures packets from the same flow always go to the same worker (preserves ordering)
- FANOUT_FLAG_DEFRAG reassembles IP fragments before distribution
- FANOUT_FLAG_ROLLOVER overflows to next worker if a ring is full

## Key Design Decisions

### Why Two Capture Modes?

| Decision | Rationale |
|----------|-----------|
| **eBPF for flexibility** | Allows kernel-level filtering and programmability. Can drop unwanted traffic before it reaches userspace. Requires newer kernels and BPF toolchain. |
| **AF_PACKET for portability** | Works on kernels as old as 3.2. No compile-time BPF dependencies. Multi-worker scaling via FANOUT. Ideal for customer environments where kernel version varies. |

### PACKET_FANOUT_HASH for Flow Affinity

AF_PACKET mode uses `PACKET_FANOUT_HASH` to distribute packets across workers based on a hash of the 5-tuple (src IP, dst IP, src port, dst port, protocol). This ensures:
- All packets from a single TCP/UDP flow go to the same worker
- No per-flow reordering across workers
- Good load distribution across diverse traffic

### PACKET_FANOUT_FLAG_DEFRAG for Fragments

IP fragments lack full 5-tuple information (only the first fragment has ports). Without special handling, fragments of the same packet could be distributed to different workers. `PACKET_FANOUT_FLAG_DEFRAG` tells the kernel to reassemble fragments before applying the fanout hash.

### Common TX Path (tx_ring) for Both Modes

Both eBPF and AF_PACKET use the **same** shared `tx_ring` module (TPACKET_V2 mmap'd TX ring) for output. This gives one code path, consistent behavior, and high throughput in either mode.

| Approach | Syscalls | Bottleneck |
|----------|----------|------------|
| **Per-packet `send()`** (old) | N per packet | Syscall overhead, `EAGAIN` drops when socket buffer fills |
| **Shared TPACKET_V2 TX ring** (current) | 1 per batch (AF_PACKET: per RX block; eBPF: every 32 packets) | Packets written into mmap memory; single `sendto(NULL, 0)` flushes |

Why TPACKET_V2 and not V3 for TX: TPACKET_V3 TX still uses fixed-size frames; V2 is stable since 2.6.31 and equally capable for this use. The shared module handles back-pressure (flush + brief spin; drop only if frame still unavailable after retries).

### Atomic Statistics

All `worker_stats` fields use `_Atomic uint64_t`. This allows:
- Lock-free updates from worker threads (each worker updates its own stats struct)
- Safe reads from the main thread for stats printing
- No mutex overhead on the hot path

### eBPF Forced to Single Worker

The eBPF perf buffer (`PERF_EVENT_ARRAY`) delivers events from all CPUs through a single `perf_buffer__poll()` call. Unlike AF_PACKET's FANOUT, there is no kernel-level mechanism to distribute perf buffer events across multiple userspace threads. Therefore, `num_workers` is forced to 1 in eBPF mode.

### Integration Tests

Integration tests are Bash-based and require root. The runner is `tests/integration/run_integ.sh [basic|filter|all]`: **basic** (8 cases), **filter** (2 ACL tests), **all** (10 cases). Make targets: `make test-basic`, `make test-filter`, `make test-all`. HTML reports are written to **tests/integration/reports/** (test_report_basic.html, test_report_filter.html, test_report.html). See [TESTING.md](TESTING.md) for details.

## Struct Quick Reference

| Struct | File | Purpose |
|--------|------|---------|
| `struct cli_args` | `src/cli.h` | Parsed command-line arguments |
| `struct tap_ctx` | `src/tap.h` | eBPF object and TC hook state |
| `struct worker_config` | `src/worker.h` | eBPF worker configuration |
| `struct worker_ctx` | `src/worker.h` | eBPF worker runtime state (includes `tx_ring`) |
| `struct worker_stats` | `src/worker.h` | Atomic packet/byte counters (shared by both modes) |
| `struct tx_ring_ctx` | `src/tx_ring.h` | Shared TPACKET_V2 TX ring state (used by both modes) |
| `struct afpacket_config` | `src/afpacket.h` | AF_PACKET backend configuration |
| `struct afpacket_worker` | `src/afpacket.h` | Per-worker RX ring + `struct tx_ring_ctx tx` |
| `struct afpacket_ctx` | `src/afpacket.h` | AF_PACKET backend runtime state |
| `struct tap_config` / `struct filter_config` | `src/config.h` | Filter (ACL) config from YAML |
| `struct pkt_meta` | `include/common.h` | Packet metadata passed from eBPF to userspace |

## Source File Summary

| File | Lines | Description |
|------|-------|-------------|
| `src/main.c` | ~330 | Entry point, config load, mode dispatch, signal handling, stats loop |
| `src/cli.c` | ~85 | `parse_args()` -- extracted for testability |
| `src/config.c` | ~350 | YAML filter config load (libyaml), validation |
| `src/filter.c` | ~120 | `filter_packet()` -- L2/L3/L4 ACL, first-match |
| `src/tap.c` | ~200 | eBPF: load, attach, detach, cleanup |
| `src/worker.c` | ~425 | eBPF: perf buffer polling, forwards via shared tx_ring |
| `src/tx_ring.c` | ~180 | Shared TPACKET_V2 mmap TX ring (both modes) |
| `src/afpacket.c` | ~660 | AF_PACKET: TPACKET_V3 RX, shared tx_ring per worker, FANOUT |
| `src/output.c` | ~107 | Legacy raw socket TX; used only by test_output unit tests |
| `src/ebpf/tc_clone.bpf.c` | ~80 | Kernel BPF program: clone to perf buffer |
