# vasn_tap Architecture

This document describes the internal architecture of vasn_tap, its modules, data flows, and key design decisions. It is intended for developers working on or extending the codebase.

## High-Level Overview

vasn_tap is a lightweight packet tap that runs on customer operating systems. It transparently captures a copy of all network traffic from a specified interface, performs optional processing in userspace, and forwards the packets to an output interface (typically connected to an Aviz Service Node on-prem).

```
  Customer Network                    vasn_tap                    Aviz Service Node
  ================               ==================              ===================

  +-----------+                  +------------------+            +------------------+
  | Customer  |   raw traffic    |                  |  forwarded |                  |
  | Interface |  ------------->  |  vasn_tap        |  --------> |  ASN (on-prem)   |
  | (eth0)    |  (not modified)  |  -i eth0 -o eth1 |  (eth1)   |                  |
  +-----------+                  +------------------+            +------------------+
       |                                |
       |  original traffic              | capture + process
       |  continues normally            | in userspace
       v                                |
   [Normal stack]                  [Stats, logging]
```

The application supports **two capture backends** selected at startup via the `-m` flag:

1. **eBPF mode** (`-m ebpf`): Uses TC BPF hooks in the kernel to clone packets into a perf buffer, consumed by a single worker thread.
2. **AF_PACKET mode** (`-m afpacket`): Uses TPACKET_V3 mmap'd ring buffers with PACKET_FANOUT_HASH for multi-worker distribution.

## Module Map

```
                          +-----------+
                          |  main.c   |  Entry point, signal handling
                          |  cli.c    |  Argument parsing
                          +-----+-----+
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
                     v                         v
               +-----------+            +-----------+
               | output.c  |            | output.c  |
               | (TX sock) |            | (TX sock) |
               +-----------+            +-----------+
```

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
    int output_fd;                // Raw socket FD for TX (-1 = drop mode)
    volatile bool running;
    pthread_t *threads;
    struct worker_stats *stats;
};
```

Design notes:
- **Forced single-threaded**: `num_workers` is always set to 1 because the perf buffer polls events from all CPUs in a single `perf_buffer__poll()` call.
- Worker thread is pinned to CPU 0 via `pthread_setaffinity_np`.
- Callback `handle_sample()` receives `struct pkt_meta` (defined in `common.h`) and forwards the packet data via `send()` on the output socket.

### afpacket.c -- AF_PACKET Backend

**File:** `src/afpacket.c`, `src/afpacket.h`

Self-contained multi-worker capture backend using TPACKET_V3.

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
    int                  rx_fd;          // AF_PACKET RX socket
    void                *rx_ring;        // mmap'd TPACKET_V3 ring
    unsigned int         ring_size;      // Total mmap size
    struct iovec        *rd;             // Block descriptor iovecs
    unsigned int         block_nr;       // Number of blocks
    unsigned int         current_block;  // Current block index
    int                  output_fd;      // TX socket (-1 = drop)
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
- `setup_rx_socket()` -- Creates AF_PACKET socket, sets TPACKET_V3, configures `PACKET_RX_RING`, binds to interface, `mmap()`s the ring
- `join_fanout()` -- Sets `PACKET_FANOUT` with `PACKET_FANOUT_HASH | PACKET_FANOUT_FLAG_DEFRAG | PACKET_FANOUT_FLAG_ROLLOVER`
- `process_block()` -- Iterates packets in a TPACKET_V3 block, updates stats, sends to output
- `afpacket_worker_thread()` -- Main worker loop: `poll()` -> `process_block()` -> release block

Ring buffer defaults (configurable in `afpacket.h`):
- Block size: 256 KB
- Block count: 64 (= 16 MB per worker)
- Frame size: 2048 bytes
- Block timeout: 100 ms

### output.c -- TX Output Module

**File:** `src/output.c`, `src/output.h`

Standalone module for sending raw packets out an interface.

```c
int  output_open(const char *ifname);            // Open AF_PACKET raw socket
int  output_send(int fd, const void *data, uint32_t len);  // Send packet
void output_close(int fd);                       // Close socket
```

Implementation details:
- Uses `AF_PACKET` + `SOCK_RAW` + `ETH_P_ALL`
- Enables `PACKET_QDISC_BYPASS` for lower latency (bypasses kernel qdisc layer)
- `output_send()` uses `MSG_DONTWAIT` for non-blocking sends

### ebpf/tc_clone.bpf.c -- Kernel-Side BPF Program

**File:** `src/ebpf/tc_clone.bpf.c`, `src/ebpf/tc_clone.h`

The eBPF program that runs in the kernel at the TC (Traffic Control) hook points.

- Attached to both **ingress** and **egress** of the target interface
- Clones each packet's metadata + data into a `PERF_EVENT_ARRAY` map (`events`)
- Uses `bpf_perf_event_output()` to deliver `struct pkt_meta` + raw packet bytes to userspace
- Returns `TC_ACT_OK` -- original packet is not modified or dropped

## Data Flow Diagrams

### eBPF Mode

```
  +---------+     +-------------+     +-----------------+     +--------+     +--------+
  |   NIC   | --> | TC Ingress/ | --> | Perf Buffer     | --> | Worker | --> | Output |
  | (eth0)  |     | Egress Hook |     | (per-CPU ring)  |     | Thread |     | Socket |
  +---------+     +-------------+     +-----------------+     +--------+     +--------+
                        |                                          |              |
                   BPF program                              handle_sample()   send() to
                  clones packet                             in worker.c       output iface
                  to perf buffer
                        |
                  original packet
                  continues normally
```

Characteristics:
- Single worker thread polls all per-CPU perf buffers
- Kernel does the cloning; userspace only receives copies
- BPF program can be extended for in-kernel filtering

### AF_PACKET Mode

```
  +---------+     +------------------+     +-----------+     +-----------+
  |   NIC   | --> | AF_PACKET Socket | --> | Worker 0  | --> | Output 0  |
  | (eth0)  |     | TPACKET_V3 ring  |     +-----------+     +-----------+
  +---------+     | (mmap'd)         |
                  |                  | --> | Worker 1  | --> | Output 1  |
                  | PACKET_FANOUT    |     +-----------+     +-----------+
                  | _HASH            |
                  |                  | --> | Worker 2  | --> | Output 2  |
                  +------------------+     +-----------+     +-----------+
                          |
                    Kernel distributes
                    packets by 5-tuple
                    hash (flow affinity)
```

Characteristics:
- Each worker has its own mmap'd ring buffer and output socket
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

### Atomic Statistics

All `worker_stats` fields use `_Atomic uint64_t`. This allows:
- Lock-free updates from worker threads (each worker updates its own stats struct)
- Safe reads from the main thread for stats printing
- No mutex overhead on the hot path

### eBPF Forced to Single Worker

The eBPF perf buffer (`PERF_EVENT_ARRAY`) delivers events from all CPUs through a single `perf_buffer__poll()` call. Unlike AF_PACKET's FANOUT, there is no kernel-level mechanism to distribute perf buffer events across multiple userspace threads. Therefore, `num_workers` is forced to 1 in eBPF mode.

## Struct Quick Reference

| Struct | File | Purpose |
|--------|------|---------|
| `struct cli_args` | `src/cli.h` | Parsed command-line arguments |
| `struct tap_ctx` | `src/tap.h` | eBPF object and TC hook state |
| `struct worker_config` | `src/worker.h` | eBPF worker configuration |
| `struct worker_ctx` | `src/worker.h` | eBPF worker runtime state |
| `struct worker_stats` | `src/worker.h` | Atomic packet/byte counters (shared by both modes) |
| `struct afpacket_config` | `src/afpacket.h` | AF_PACKET backend configuration |
| `struct afpacket_worker` | `src/afpacket.h` | Per-worker ring buffer and socket state |
| `struct afpacket_ctx` | `src/afpacket.h` | AF_PACKET backend runtime state |
| `struct pkt_meta` | `include/common.h` | Packet metadata passed from eBPF to userspace |

## Source File Summary

| File | Lines | Description |
|------|-------|-------------|
| `src/main.c` | ~313 | Entry point, mode dispatch, signal handling, stats loop |
| `src/cli.c` | ~85 | `parse_args()` -- extracted for testability |
| `src/tap.c` | ~200 | eBPF: load, attach, detach, cleanup |
| `src/worker.c` | ~250 | eBPF: perf buffer polling, packet forwarding |
| `src/afpacket.c` | ~532 | AF_PACKET: TPACKET_V3 ring, FANOUT, multi-worker |
| `src/output.c` | ~100 | Raw socket TX with QDISC_BYPASS |
| `src/ebpf/tc_clone.bpf.c` | ~80 | Kernel BPF program: clone to perf buffer |
