# vasn_tap - High Performance Packet Tap

A lightweight, high-performance packet tap application that captures traffic from customer interfaces, processes it in userspace, and forwards it to the Aviz Service Node (ASN). Supports two capture backends: **eBPF** (TC BPF + perf buffer) and **AF_PACKET** (TPACKET_V3 mmap RX + TPACKET_V2 mmap TX + FANOUT_HASH).

## Overview

vasn_tap is designed to run on customer operating systems with minimal dependencies. It taps network traffic transparently (without affecting the original flow), performs optional filtering/processing in userspace, and forwards a copy of all packets to an output interface (typically connected to an Aviz Service Node on-prem).

### Two Capture Modes

| Feature | eBPF Mode (`runtime.mode: ebpf`) | AF_PACKET Mode (`runtime.mode: afpacket`) |
|---------|----------------------|-------------------------------|
| **RX Mechanism** | TC BPF hook + perf buffer | TPACKET_V3 mmap ring buffer |
| **TX Mechanism** | TX ring or userspace tunnel (VXLAN/GRE) when configured | TX ring or userspace tunnel (VXLAN/GRE) when configured |
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
    libyaml-dev \
    libcmocka-dev    # for unit tests
```

**RHEL/CentOS/Fedora:**

```bash
sudo dnf install -y gcc make \
    clang llvm elfutils-libelf-devel zlib-devel \
    libbpf-devel bpftool \
    libyaml-devel \
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

## Packaging and Systemd Deployment

The repository includes first-release packaging and service-control scripts under `scripts/`:

- `scripts/build-package.sh` -- builds and creates `vasn_tap-v<version>-<date>-<sha>.tar.gz`
- `scripts/install.sh` -- installs binary, BPF object, config template, control script, and systemd unit
- `scripts/uninstall.sh` -- uninstall helper (`--purge-config` optional)
- `scripts/vasn_tapctl.sh` -- control helper: `start|stop|restart|status|counters|logs|validate|apply`
- `scripts/vasn_tap.service` -- systemd unit (`ExecStart=/usr/local/bin/vasn_tap -c /etc/vasn_tap/config.yaml`)
- `scripts/INSTALL.txt` -- quick install/run instructions for QA

Typical flow:

```bash
# Build package tarball
./scripts/build-package.sh

# On target host (after untar)
sudo ./install.sh
sudo vasn_tapctl validate
sudo vasn_tapctl start
sudo vasn_tapctl status
```

## Usage

vasn_tap requires **root privileges** (for raw socket access and eBPF).
Runtime startup settings are loaded from the YAML `runtime:` section.

```bash
# Run with a YAML config (runtime + filter + optional tunnel)
sudo ./vasn_tap -c /etc/vasn_tap/config.yaml

# Validate config only (load and exit)
sudo ./vasn_tap -V -c /etc/vasn_tap/config.yaml
```

### Command Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `-c, --config <path>` | YAML config path (runtime + filter + optional tunnel) | **Required** |
| `-V, --validate-config` | Load and validate config only, then exit (use with `-c`) | Off |
| `--version` | Show version, git commit, and build timestamp (UTC) then exit | -- |
| `-h, --help` | Show help message and exit | -- |

**Notes:**
- Runtime keys (input/output/mode/workers/stats/etc.) are defined in YAML under `runtime:`.
- Optional post-filter truncation is configured under `runtime.truncate` (`enabled` + `length`).
- In **ebpf** mode, worker count is forced to 1 regardless of `runtime.workers` (perf buffer limitation).
- In **afpacket** mode, workers are distributed via PACKET_FANOUT_HASH for per-flow affinity.
- If `runtime.output_iface` is omitted, packets are captured and counted but not forwarded (drop mode).
- If tunnel is disabled and input/output are the same interface (especially `lo`), self-forwarding loops are possible. Use different interfaces or drop mode.
- TX packet length is clamped to the output interface MTU (avoids kernel "packet size is too long" and stuck ring). Oversize packets are truncated; use UDP or jumbo MTU on the path to avoid truncation.
- When `runtime.truncate.enabled: true`, packets that pass filter are truncated to `runtime.truncate.length` before output/tunnel send. For ETH+IPv4 and ETH+VLAN+IPv4 frames, IPv4 total length and header checksum are updated.
- If mandatory config fields are missing/invalid (e.g. `runtime.input_iface` or `runtime.mode`), vasn_tap **does not start**.
- Use **`-V -c <path>`** to validate config before restart/apply. Config is read once at startup; **restart is required** for config changes.

### Filter (ACL) config

When `-c <path>` is given, the YAML defines **runtime** startup options and ACL policy. Filter ACL is under `filter:`: **default_action** (`allow` or `drop`) and a list of **rules**. Packets are evaluated **first-match**: the first rule whose match criteria fit the packet determines allow/drop; if no rule matches, **default_action** applies. No rule match fields => match-all rule.

Example (see `config.example.yaml`):

```yaml
runtime:
  input_iface: eth0
  output_iface: eth1
  mode: afpacket
  truncate:
    enabled: true
    length: 128
filter:
  default_action: drop
  rules:
    - action: allow
      match:
        protocol: tcp
        port_dst: 443
    - action: allow
      match:
        ip_src: 192.168.200.0/24
```

Match fields: **protocol** (tcp, udp, icmp, icmpv6 or number), **port_src**, **port_dst**, **ip_src**, **ip_dst** (IPv4 or CIDR), **eth_type**. All match fields in a rule are ANDed; only specified fields are checked.

### Tunnel (optional)

When the YAML config includes a top-level **tunnel** section, allowed packets are encapsulated in userspace (VXLAN or GRE) and sent to a remote IP instead of being L2-forwarded. No kernel tunnel device is created. **`runtime.output_iface` is required** when tunnel is enabled; **`runtime.output_iface: lo` is rejected**.

Example (see `config.example.yaml`):

```yaml
runtime:
  input_iface: eth0
  output_iface: eth1
  mode: afpacket
filter:
  default_action: allow
  rules: []
tunnel:
  type: gre
  remote_ip: 10.4.5.187
  key: 1000
#  local_ip: optional; else derived from runtime.output_iface
```

For VXLAN: **type: vxlan**, **remote_ip** (required), **vni** (e.g. 1000), **dstport** (default 4789), optional **local_ip**. For GRE: **type: gre**, **remote_ip** (required), optional **key** and **local_ip**. With `runtime.stats: true`, stats show a line: `Tunnel (VXLAN): N packets sent, M bytes` or `Tunnel (GRE): ...`.

## Testing

### Unit Tests (no root required)

```bash
make test
```

Runs 7 unit test suites using CMocka: CLI parsing, config validation, stats accumulation, output error paths, filter logic, YAML config load, and truncation helper behavior.

### Integration Tests (requires root)

```bash
make test-basic    # 8 cases → tests/integration/reports/test_report_basic.html
make test-filter   # 10 cases → tests/integration/reports/test_report_filter.html
make test-tunnel   # 2 cases (GRE, VXLAN) → tests/integration/reports/test_report_tunnel.html
make test-truncate # 3 cases (truncate afpacket, ebpf, no_truncate) → tests/integration/reports/test_report_truncate.html
make test-all      # 23 cases (basic + filter + tunnel + truncate) → tests/integration/reports/test_report.html
```

Or run the runner directly: `sudo tests/integration/run_integ.sh [basic|filter|tunnel|truncate|all]`. Creates network namespaces with veth pairs; **basic** runs forwarding, drop mode, graceful shutdown (both modes), multiworker, and fanout; **filter** runs the ACL filter tests (afpacket + ebpf); **tunnel** runs GRE and VXLAN tunnel encap tests (afpacket); **truncate** runs truncation tests (afpacket, ebpf, and no_truncate). HTML reports are written under **tests/integration/reports/**.

See [TESTING.md](TESTING.md) for full details on the test suites, how to add tests, and the test matrix.

## Project Structure

```
vasn_tap/
├── include/
│   └── common.h              # Shared types (pkt_meta, pkt_direction, constants)
├── src/
│   ├── main.c                # Entry point, CLI dispatch, tunnel init, signal handling
│   ├── cli.c / cli.h         # Argument parsing (extracted for testability)
│   ├── config.c / config.h   # YAML runtime + filter + tunnel config load
│   ├── filter.c / filter.h   # ACL filter_packet (L2/L3/L4)
│   ├── tunnel.c / tunnel.h   # Optional VXLAN/GRE encap (userspace raw socket)
│   ├── truncate.c / truncate.h # Post-filter truncate + IPv4 checksum fixup
│   ├── tap.c / tap.h         # eBPF mode: load BPF, attach/detach TC hooks
│   ├── worker.c / worker.h   # eBPF mode: perf buffer consumer, stats
│   ├── tx_ring.c / tx_ring.h     # Shared TPACKET_V2 mmap TX ring (when no tunnel)
│   ├── afpacket.c / afpacket.h   # AF_PACKET mode: TPACKET_V3 RX, FANOUT, tx_ring or tunnel
│   ├── output.c / output.h      # Legacy; used only by test_output unit tests
│   └── ebpf/
│       ├── tc_clone.bpf.c    # Kernel-side TC BPF program
│       ├── tc_clone.h         # eBPF program constants
│       └── vmlinux.h          # Auto-generated kernel type definitions
├── scripts/
│   ├── build-package.sh       # Build + stage + tarball for QA
│   ├── install.sh             # Install binary/BPF/config/systemd unit
│   ├── uninstall.sh           # Remove installed service/binary (optional config purge)
│   ├── vasn_tapctl.sh         # start|stop|restart|status|counters|logs|validate|apply
│   ├── vasn_tap.service       # systemd unit (YAML-driven startup)
│   └── INSTALL.txt            # Packaging install quick guide
├── tests/
│   ├── unit/                  # CMocka unit tests
│   │   ├── test_cli.c        # CLI-lite tests: config path, validate, help/version, deprecated flags
│   │   ├── test_config.c     # 5 tests: init validation, enum values
│   │   ├── test_config_filter.c  # YAML load tests including runtime validation
│   │   ├── test_stats.c      # 10 tests: stats accumulation, reset, NULL safety
│   │   ├── test_output.c     # 8 tests: send/open/close error paths
│   │   ├── test_truncate.c   # Truncation helper tests (IPv4/VLAN-IPv4 fixup)
│   │   └── test_common.h     # Shared CMocka includes
│   └── integration/           # Bash-based integration tests
│       ├── run_integ.sh       # Runner: basic (8) | filter (10) | tunnel (2) | all (20)
│       ├── run_all.sh         # Wrapper for run_integ.sh all
│       ├── reports/           # HTML reports (test_report*.html)
│       ├── setup_namespaces.sh    # Create ns_src/ns_dst + veth pairs
│       ├── teardown_namespaces.sh # Cleanup
│       ├── test_helpers.sh    # JSON result writer helpers
│       ├── generate_report.sh # HTML report generator
│       ├── test_basic_forward.sh  # Packet forwarding (both modes)
│       ├── test_drop_mode.sh      # Drop mode verification (both modes)
│       ├── test_multiworker.sh    # Multi-worker scaling (afpacket only)
│       ├── test_graceful_shutdown.sh  # SIGINT handling (both modes)
│       ├── test_tunnel_gre.sh     # GRE tunnel encap (afpacket)
│       └── test_tunnel_vxlan.sh   # VXLAN tunnel encap (afpacket)
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
# Then configure in YAML runtime:
#   mode: afpacket
#   workers: 4
# and run:
sudo ./vasn_tap -c /etc/vasn_tap/config.yaml
```

### Socket Buffer Sizes

```bash
sudo sysctl -w net.core.rmem_max=26214400
sudo sysctl -w net.core.wmem_max=26214400
```

> **Note:** In AF_PACKET mode, `SO_SNDBUFFORCE` is used to set a 4 MB send buffer
> on the TX socket, bypassing the `wmem_max` sysctl cap. This requires `CAP_NET_ADMIN`
> (which is already needed for AF_PACKET raw sockets).

### Ring Tuning

**RX ring (AF_PACKET only)** — in `src/afpacket.h`:
- `AFPACKET_BLOCK_SIZE` -- 256 KB per block (default)
- `AFPACKET_BLOCK_NR` -- 64 blocks = 16 MB per worker (default)

**TX ring (shared by both modes)** — in `src/tx_ring.c`:
- 256 KB blocks × 16 = 4 MB per ring, 2048-byte frames
- Uses `PACKET_QDISC_BYPASS` and 4 MB send buffer (`SO_SNDBUFFORCE`) for lower latency

### eBPF Perf Buffer Tuning

The perf buffer size is configured via `PERF_BUFFER_PAGES` in `src/worker.c`.

### Memory and CPU utilization

**Memory** is dominated by mmap’d ring buffers; the kernel does not report per-thread RSS, so usage is process-wide.

- **AF_PACKET:** Each worker has an RX ring (default 16 MB per worker) and, when not using tunnel, a TX ring (4 MB per worker). Total scales with `runtime.workers` (e.g. 4 workers ≈ 80 MB with TX).
- **eBPF:** One perf buffer (~256 KB) and one shared TX ring (4 MB) when forwarding.
- **Tunnel mode:** One small encap buffer (2 KB) shared by workers.

Set `runtime.resource_usage: true` together with `runtime.stats: true` to print **memory (RSS)** and **per-thread CPU%** every stats interval. `resource_usage` implies stats in code.

```bash
sudo ./vasn_tap -c /etc/vasn_tap/config.yaml
```

Output appears below the packet stats every second, for example:

```
Memory: RSS 82 MiB
CPU (1.0s): tid 1234 0.1% tid 1235 12.3% tid 1236 11.8% ...
```

When truncation is enabled, stats also include:

```
Truncated: 4895 total, 1457930 bytes removed
```

Resource data is gathered only in the **main thread** (reads from `/proc/self/status` and `/proc/self/task/*/stat`); the packet **hot path is not touched**, so there is no performance impact on capture or forwarding.

**CPU** scales with the number of workers and traffic rate. Workers are pinned to CPUs; the main thread only sleeps and, when `runtime.stats` is enabled, prints stats (plus resource usage when `runtime.resource_usage` is enabled). To inspect from outside: `top` or `htop` (per-process and per-thread), or `pidstat -p <pid> -t 1` for per-thread CPU.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Error: This program requires root privileges` | Run with `sudo` |
| `Error: /sys/kernel/btf/vmlinux not found` | Your kernel lacks BTF support. Set `runtime.mode: afpacket` in YAML, or upgrade to a kernel >= 5.10 with `CONFIG_DEBUG_INFO_BTF=y` |
| `Error: Input interface eth0 not found` | Check interface name with `ip link show` |
| `Failed to initialize AF_PACKET` | Check that the interface exists and is up: `ip link set eth0 up` |
| `make` fails with `clang not found` | Install clang: `sudo apt-get install clang llvm` |
| Unit tests fail to build | Install CMocka: `sudo apt-get install libcmocka-dev` |

## Further Reading

- [ARCHITECTURE.md](ARCHITECTURE.md) -- Detailed architecture, module breakdown, and design decisions
- [TESTING.md](TESTING.md) -- Complete testing guide, test matrix, and how to add new tests

## License

GPL-2.0 (eBPF programs require GPL license)
