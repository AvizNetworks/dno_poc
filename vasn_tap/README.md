# vasn_tap - High Performance Packet Tap

A lightweight, high-performance packet tap application that captures traffic from customer interfaces, processes it in userspace, and forwards it to the Aviz Service Node (ASN). Supports two capture backends: **eBPF** (TC BPF + perf buffer) and **AF_PACKET** (TPACKET_V3 mmap RX + TPACKET_V2 mmap TX + FANOUT_HASH).

## Overview

vasn_tap is designed to run on customer operating systems with minimal dependencies. It taps network traffic transparently (without affecting the original flow), performs optional filtering/processing in userspace, and forwards a copy of all packets to an output interface (typically connected to an Aviz Service Node on-prem).

### Two Capture Modes

| Feature | eBPF Mode (`-m ebpf`) | AF_PACKET Mode (`-m afpacket`) |
|---------|----------------------|-------------------------------|
| **RX Mechanism** | TC BPF hook + perf buffer | TPACKET_V3 mmap ring buffer |
| **TX Mechanism** | Per-packet `send()` via `output.c` | TPACKET_V2 mmap TX ring (zero-copy, batch flush) |
| **Multi-worker** | Single thread only (perf buffer limitation) | Yes, via PACKET_FANOUT_HASH |
| **Kernel requirement** | >= 5.10 with BTF | >= 3.2 |
| **Dependencies** | libbpf, clang, bpftool | None (standard sockets) |
| **Best for** | Filtering at kernel level | Portability, multi-core scaling, high throughput |

**When to use which:**
- Use **afpacket** if you need multi-worker scaling, portability across kernel versions, or simpler deployment (no BPF toolchain).
- Use **ebpf** if you need kernel-level filtering before packets reach userspace, or want to leverage eBPF programmability.

## Prerequisites

### Required Packages

**Ubuntu/Debian:**

```bash
sudo apt-get update
sudo apt-get install -y gcc make \
    clang llvm libelf-dev zlib1g-dev \
    libbpf-dev linux-tools-common linux-tools-$(uname -r) \
    libcmocka-dev    # for unit tests
```

**RHEL/CentOS/Fedora:**

```bash
sudo dnf install -y gcc make \
    clang llvm elfutils-libelf-devel zlib-devel \
    libbpf-devel bpftool \
    libcmocka-devel  # for unit tests
```

### Kernel Requirements

- **eBPF mode**: Linux kernel >= 5.10 with BTF support (`/sys/kernel/btf/vmlinux` must exist)
- **AF_PACKET mode**: Linux kernel >= 3.2 (TPACKET_V3 support)

## Building

```bash
# Build everything (eBPF program + userspace binary)
make

# Clean all build artifacts
make clean

# Show all available targets
make help
```

The build produces:
- `vasn_tap` -- the main binary
- `tc_clone.bpf.o` -- the compiled eBPF program (used by ebpf mode)

## Usage

vasn_tap requires **root privileges** (for raw socket access and eBPF).

```bash
# AF_PACKET mode: 4 workers, capture from eth0, forward to eth1, show stats
sudo ./vasn_tap -m afpacket -i eth0 -o eth1 -w 4 -s

# eBPF mode (default): capture from eth0, forward to eth1
sudo ./vasn_tap -i eth0 -o eth1 -s

# AF_PACKET benchmark mode (capture only, no forwarding)
sudo ./vasn_tap -m afpacket -i eth0 -w 4 -s

# Verbose output for debugging
sudo ./vasn_tap -m afpacket -i eth0 -o eth1 -w 2 -v -s
```

### Command Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `-i, --input <iface>` | Input interface for packet capture | **Required** |
| `-o, --output <iface>` | Output interface for forwarding | None (drop mode) |
| `-m, --mode <mode>` | Capture mode: `ebpf` or `afpacket` | `ebpf` |
| `-w, --workers <n>` | Number of worker threads (1-128) | Auto (num CPUs) |
| `-v, --verbose` | Enable verbose logging | Off |
| `-s, --stats` | Print periodic statistics (every 1s) | Off |
| `-h, --help` | Show help message and exit | -- |

**Notes:**
- In **ebpf** mode, worker count is forced to 1 regardless of `-w` (perf buffer limitation).
- In **afpacket** mode, workers are distributed via PACKET_FANOUT_HASH for per-flow affinity.
- If `-o` is omitted, packets are captured and counted but not forwarded (useful for benchmarking).

## Testing

### Unit Tests (no root required)

```bash
make test
```

Runs 4 test suites (41 tests total) using CMocka: CLI parsing, config validation, stats accumulation, and output error paths.

### Integration Tests (requires root)

```bash
sudo bash tests/integration/run_all.sh
```

Creates network namespaces with veth pairs, runs tests in both eBPF and AF_PACKET modes, and generates an **HTML report** at `test_report.html` in the project root.

See [TESTING.md](TESTING.md) for full details on the test suites, how to add tests, and the test matrix.

## Project Structure

```
vasn_tap/
├── include/
│   └── common.h              # Shared types (pkt_meta, pkt_direction, constants)
├── src/
│   ├── main.c                # Entry point, CLI dispatch, signal handling
│   ├── cli.c / cli.h         # Argument parsing (extracted for testability)
│   ├── tap.c / tap.h         # eBPF mode: load BPF, attach/detach TC hooks
│   ├── worker.c / worker.h   # eBPF mode: perf buffer consumer, stats
│   ├── afpacket.c / afpacket.h  # AF_PACKET mode: TPACKET_V3 RX, TPACKET_V2 TX, FANOUT
│   ├── output.c / output.h   # Raw socket TX for eBPF mode (AF_PACKET + QDISC_BYPASS)
│   └── ebpf/
│       ├── tc_clone.bpf.c    # Kernel-side TC BPF program
│       ├── tc_clone.h         # eBPF program constants
│       └── vmlinux.h          # Auto-generated kernel type definitions
├── tests/
│   ├── unit/                  # CMocka unit tests
│   │   ├── test_cli.c        # 18 tests: mode, interface, workers, flags
│   │   ├── test_config.c     # 5 tests: init validation, enum values
│   │   ├── test_stats.c      # 10 tests: stats accumulation, reset, NULL safety
│   │   ├── test_output.c     # 8 tests: send/open/close error paths
│   │   └── test_common.h     # Shared CMocka includes
│   └── integration/           # Bash-based integration tests
│       ├── run_all.sh         # Orchestrator (runs all tests, generates HTML)
│       ├── setup_namespaces.sh    # Create ns_src/ns_dst + veth pairs
│       ├── teardown_namespaces.sh # Cleanup
│       ├── test_helpers.sh    # JSON result writer helpers
│       ├── generate_report.sh # HTML report generator
│       ├── test_basic_forward.sh  # Packet forwarding (both modes)
│       ├── test_drop_mode.sh      # Drop mode verification (both modes)
│       ├── test_multiworker.sh    # Multi-worker scaling (afpacket only)
│       └── test_graceful_shutdown.sh  # SIGINT handling (both modes)
├── Makefile                   # Build system + test targets
├── README.md                  # This file
├── ARCHITECTURE.md            # Detailed architecture documentation
└── TESTING.md                 # Testing guide and reference
```

## Performance Tuning

### CPU Affinity

Workers are automatically pinned to CPUs. For best performance, isolate CPUs:

```bash
# Add to kernel cmdline: isolcpus=2,3,4,5
# Then run with those CPUs:
sudo ./vasn_tap -m afpacket -i eth0 -o eth1 -w 4
```

### Socket Buffer Sizes

```bash
sudo sysctl -w net.core.rmem_max=26214400
sudo sysctl -w net.core.wmem_max=26214400
```

> **Note:** In AF_PACKET mode, `SO_SNDBUFFORCE` is used to set a 4 MB send buffer
> on the TX socket, bypassing the `wmem_max` sysctl cap. This requires `CAP_NET_ADMIN`
> (which is already needed for AF_PACKET raw sockets).

### AF_PACKET Ring Tuning

Ring buffer sizes per worker are configured in `src/afpacket.h`:

**RX ring (TPACKET_V3):**
- `AFPACKET_BLOCK_SIZE` -- 256 KB per block (default)
- `AFPACKET_BLOCK_NR` -- 64 blocks = 16 MB per worker (default)

**TX ring (TPACKET_V2):**
- `AFPACKET_TX_BLOCK_SIZE` -- 256 KB per block (default)
- `AFPACKET_TX_BLOCK_NR` -- 16 blocks = 4 MB per worker (default)
- `AFPACKET_TX_FRAME_SIZE` -- 2048 bytes per frame (default)

The TX ring uses `PACKET_QDISC_BYPASS` to skip the kernel qdisc layer for lower-latency output.

### eBPF Perf Buffer Tuning

The perf buffer size is configured via `PERF_BUFFER_PAGES` in `src/worker.c`.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Error: This program requires root privileges` | Run with `sudo` |
| `Error: /sys/kernel/btf/vmlinux not found` | Your kernel lacks BTF support. Use `-m afpacket` instead, or upgrade to a kernel >= 5.10 with `CONFIG_DEBUG_INFO_BTF=y` |
| `Error: Input interface eth0 not found` | Check interface name with `ip link show` |
| `Failed to initialize AF_PACKET` | Check that the interface exists and is up: `ip link set eth0 up` |
| `make` fails with `clang not found` | Install clang: `sudo apt-get install clang llvm` |
| Unit tests fail to build | Install CMocka: `sudo apt-get install libcmocka-dev` |

## Further Reading

- [ARCHITECTURE.md](ARCHITECTURE.md) -- Detailed architecture, module breakdown, and design decisions
- [TESTING.md](TESTING.md) -- Complete testing guide, test matrix, and how to add new tests

## License

GPL-2.0 (eBPF programs require GPL license)
