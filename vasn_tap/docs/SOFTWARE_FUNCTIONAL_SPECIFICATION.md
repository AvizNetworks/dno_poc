# vasn_tap Software Functional Specification (SFS)

**Audience:** Development, QA, and customer-facing teams.  
**Purpose:** Define what the product does, what it does not do, behavior guarantees, and limitations.

---

## 1. Document control

| Field | Value |
|-------|--------|
| Product | vasn_tap |
| Document | Software Functional Specification |
| Status | v1.0 (first release) |
| See also | [README.md](../README.md), [ARCHITECTURE.md](../ARCHITECTURE.md) |

---

## 2. Product summary

vasn_tap is a packet tap application that captures traffic from a configured input interface, optionally filters and truncates packets in userspace, and forwards them to an output interface or encapsulates them (VXLAN or GRE) to a remote IP. It supports two capture backends: **AF_PACKET** (kernel TPACKET_V3 RX with FANOUT, TPACKET_V2 TX) and **eBPF** (TC BPF hook + perf buffer). No kernel tunnel device is created; encapsulation is done in userspace. All runtime behavior is configured via a single YAML file; the CLI accepts only config path, validate-only flag, version, and help.

---

## 3. Functional capabilities

- **Capture**
  - Two modes: `afpacket` and `ebpf` (YAML `runtime.mode`).
  - Configurable worker count for AF_PACKET only; eBPF is single-worker.
  - Input interface (required) and output interface (optional unless tunnel is enabled). When output is omitted and tunnel is not configured, vasn_tap runs in drop mode (capture and count only, no forward).

- **Filter (ACL)**
  - First-match rule list with `default_action` (allow or drop) when no rule matches.
  - Match fields: protocol (tcp, udp, icmp, icmpv6 or number), port_src, port_dst, ip_src, ip_dst (IPv4 or CIDR), eth_type. All fields in a rule are ANDed; only specified fields are checked.
  - Supports IPv4 and single 802.1Q/802.1AD VLAN (IP at fixed offsets). No packet copy; first matching rule wins.

- **Truncation**
  - Optional post-filter truncation to a configured length (64–9000 bytes). When enabled, packets that pass the filter are truncated before output or tunnel send. For ETH+IPv4 and ETH+VLAN+IPv4 frames, IPv4 total length and header checksum are updated in place (or in a copy in eBPF mode).

- **Tunnel**
  - Optional VXLAN or GRE encapsulation to a remote IP. No kernel tunnel device; encapsulation is done in userspace. `runtime.output_iface` is required when tunnel is enabled; loopback (`lo`) as output is rejected. VXLAN: remote_ip, vni, dstport (default 4789), optional local_ip. GRE: remote_ip, optional key and local_ip.

- **CLI**
  - `-c, --config <path>` (required): YAML config path.
  - `-V, --validate-config`: Load and validate config only, then exit.
  - `--version`: Print version, git commit, build timestamp and exit.
  - `-h, --help`: Print help and exit. No runtime options on CLI; all runtime behavior is in YAML.

- **Config**
  - Single YAML file with mandatory `runtime` and `filter` sections and optional `tunnel` section. Validation is performed at load; invalid config causes startup failure. Config is read once at startup; **restart is required** for any config change.

- **Stats and observability**
  - Periodic stats (interval in code): RX/TX/dropped/truncated counts and rates; when tunnel is enabled, tunnel packet/byte counts. Optional filter rule hit counts and resource usage (RSS, per-thread CPU%). vasn_tapctl provides `counters` (from journal) and `logs` (journalctl tail). Stats are printed to stdout and (when run as systemd service) to the journal.

---

## 4. Behavior and guarantees

- Config is read once at process start. No reload or in-band config push.
- Graceful shutdown on SIGINT/SIGTERM: workers are stopped, resources released, process exits.
- When tunnel is enabled, `runtime.output_iface` is required and must not be `lo`; otherwise tunnel init fails.
- When `runtime.output_iface` is omitted and tunnel is not configured, vasn_tap runs in drop mode (no forwarding).
- If mandatory config fields are missing or invalid (e.g. `runtime.input_iface`, `runtime.mode`), vasn_tap does not start.
- TX packet length is clamped to the output interface MTU to avoid kernel errors; oversize packets may be truncated on send.
- Filter evaluation is first-match; no rule match implies `default_action`.

For detailed data path and module roles, see [ARCHITECTURE.md](../ARCHITECTURE.md).

---

## 5. Out-of-scope / non-goals

- Config reload without process restart.
- IPv6 tunnel encapsulation (filter can match icmpv6 only).
- Multiple tunnel destinations or load balancing across VTEPs.
- TLS or other encryption of forwarded traffic.
- Built-in GUI or REST API.
- Creation or management of kernel tunnel devices (e.g. ip link add type vxlan). Tunnel is userspace-only.

---

## 6. Limitations and constraints

**eBPF mode**

- Single worker only (perf buffer limitation). `runtime.workers` is ignored.
- Linux kernel >= 5.10 with BTF (`/sys/kernel/btf/vmlinux`).
- Depends on libbpf and (for build) bpftool/clang. Prebuilt package may ship a compiled BPF object.
- Truncation runs on a writable copy of the packet (perf buffer is read-only); no additional memory leak from that buffer.

**AF_PACKET mode**

- Linux kernel >= 3.2 (TPACKET_V3 support).
- RX: kernel distributes packets across workers via PACKET_FANOUT_HASH. TX: each worker has its own TX socket and TPACKET_V2 ring bound to the same output interface; there is no shared TX ring.

**Tunnel**

- ARP for the tunnel remote IP is performed on the output interface. The implementation retries (e.g. 3 times) with a wait (e.g. 300 ms) after triggering ARP via a UDP connect. If the host routing table does not have a direct route for the remote IP on the output interface, ARP may fail until the cache is populated (e.g. by pinging the remote IP from the host).

**General**

- Config change requires process restart.
- Root (or equivalent capability) is required for raw sockets and eBPF.
- Using the same interface for input and output without tunnel can cause self-forwarding loops; use different interfaces or drop mode.
- Ring buffer sizes and timeouts are build-time or code constants; not all are exposed in config.

---

## 7. Configuration reference

| Section | Key | Required | Description |
|---------|-----|----------|-------------|
| runtime | input_iface | Yes | Input interface name |
| runtime | output_iface | When tunnel enabled | Output interface name |
| runtime | mode | Yes | `afpacket` or `ebpf` |
| runtime | workers | No | Worker count (AF_PACKET only; 0 = auto) |
| runtime | truncate.enabled | No | Enable post-filter truncation |
| runtime | truncate.length | When truncate enabled | Truncation length 64–9000 |
| runtime | stats, filter_stats, resource_usage, verbose, debug | No | Observability and logging |
| filter | default_action | Yes | `allow` or `drop` when no rule matches |
| filter | rules | Yes | List of rule objects (action + match) |
| tunnel | type | When tunnel present | `vxlan` or `gre` |
| tunnel | remote_ip | When tunnel present | Remote IP address |
| tunnel | vni, dstport | VXLAN | VNI and UDP port (default 4789) |
| tunnel | key, local_ip | GRE / optional | GRE key; local IP (optional) |

Full syntax and examples: [config.example.yaml](../config.example.yaml) and [README.md](../README.md).

---

## 8. Dependencies and requirements

- **OS:** Linux.
- **Kernel:** AF_PACKET >= 3.2; eBPF >= 5.10 with BTF.
- **Libraries:** libyaml; for eBPF build/runtime: libbpf, libelf, zlib. No extra deps for AF_PACKET-only run.
- **Privileges:** Root (or CAP_NET_RAW, CAP_NET_ADMIN as applicable).
- **Optional:** systemd for service management; journal for vasn_tapctl counters/logs.

See [README.md](../README.md) Prerequisites for distro-specific package lists.

---

## 9. References

| Document | Description |
|----------|-------------|
| [README.md](../README.md) | User-facing overview, build, usage, filter/tunnel/truncate |
| [ARCHITECTURE.md](../ARCHITECTURE.md) | Internal architecture and module design |
| [TESTING.md](../TESTING.md) | Test strategy and how to run tests |
| [scripts/INSTALL.txt](../scripts/INSTALL.txt) | Quick install and run steps |
| [config.example.yaml](../config.example.yaml) | Example YAML with comments |
