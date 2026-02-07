# vasn_tap - High Performance eBPF Packet Tap

A high-performance packet tap using eBPF TC hooks for packet cloning and pthread workers for userspace processing. Designed for VMs, containers, and cloud environments.

## Features

- **eBPF-based packet cloning** at TC ingress/egress hooks
- **Zero-copy transfer** to userspace via per-CPU perf ring buffers
- **CPU-pinned pthread workers** for maximum performance
- **Optional packet forwarding** to output interface
- **Minimal overhead** - clone packets without affecting original traffic

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Kernel Space                              │
│  ┌──────────┐    ┌─────────────┐    ┌──────────────────┐   │
│  │   eth0   │───▶│ TC Ingress  │───▶│  Perf Ring       │   │
│  │          │    │ TC Egress   │    │  Buffer (per-CPU)│   │
│  └──────────┘    └─────────────┘    └────────┬─────────┘   │
└──────────────────────────────────────────────┼─────────────┘
                                               │
┌──────────────────────────────────────────────▼─────────────┐
│                    User Space                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Pthread Workers (CPU-pinned)             │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐    │  │
│  │  │Worker 0 │ │Worker 1 │ │Worker 2 │ │Worker N │    │  │
│  │  │ (CPU 0) │ │ (CPU 1) │ │ (CPU 2) │ │ (CPU N) │    │  │
│  │  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘    │  │
│  └───────┼───────────┼───────────┼───────────┼──────────┘  │
│          │           │           │           │              │
│          ▼           ▼           ▼           ▼              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │     Output: Raw Socket (eth1) or Drop (benchmark)     │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Requirements

- Linux kernel >= 5.10 with BTF support
- clang/llvm >= 11
- libbpf >= 0.8
- libelf
- zlib
- bpftool

### Ubuntu/Debian

```bash
sudo apt-get update
sudo apt-get install -y clang llvm libelf-dev zlib1g-dev \
    libbpf-dev linux-tools-common linux-tools-$(uname -r)
```

### RHEL/CentOS/Fedora

```bash
sudo dnf install -y clang llvm elfutils-libelf-devel zlib-devel \
    libbpf-devel bpftool
```

## Building

```bash
# Build everything
make

# Clean build artifacts
make clean

# Generate vmlinux.h only
make vmlinux
```

## Usage

```bash
# Basic usage - clone packets from eth0, drop in userspace (benchmark mode)
sudo ./vasn_tap -i eth0

# Clone packets from eth0, forward to eth1
sudo ./vasn_tap -i eth0 -o eth1

# With specific worker count and verbose output
sudo ./vasn_tap -i eth0 -o eth1 -w 4 -v

# With periodic statistics
sudo ./vasn_tap -i eth0 -o eth1 -s
```

### Command Line Options

| Option | Description |
|--------|-------------|
| `-i, --input <iface>` | Input interface for packet capture (required) |
| `-o, --output <iface>` | Output interface for forwarding (optional) |
| `-w, --workers <n>` | Number of worker threads (default: num CPUs) |
| `-v, --verbose` | Enable verbose logging |
| `-s, --stats` | Print periodic statistics |
| `-h, --help` | Show help message |

## Performance Tuning

### CPU Affinity

Workers are automatically pinned to CPUs. For best performance:

```bash
# Isolate CPUs for packet processing
# Add to kernel cmdline: isolcpus=2,3,4,5

# Run with isolated CPUs
sudo ./vasn_tap -i eth0 -o eth1 -w 4
```

### Ring Buffer Size

The default ring buffer size (64 pages per CPU) can be tuned by modifying `PERF_BUFFER_PAGES` in `src/worker.c`.

### Network Tuning

```bash
# Increase socket buffer sizes
sudo sysctl -w net.core.rmem_max=26214400
sudo sysctl -w net.core.wmem_max=26214400

# Enable busy polling
sudo sysctl -w net.core.busy_poll=50
sudo sysctl -w net.core.busy_read=50
```

## License

GPL-2.0 (eBPF programs require GPL license)
