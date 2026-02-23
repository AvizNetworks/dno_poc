# vasn_tap Customer Guide

This guide explains how to obtain, install, configure, and operate vasn_tap on your system. vasn_tap captures traffic from a network interface, optionally filters and truncates it, and forwards it to another interface or encapsulates it (VXLAN or GRE) to a remote node such as an Aviz Service Node (ASN).

---

## 1. Introduction

vasn_tap is a lightweight packet tap that runs on your Linux host. It copies traffic from an input interface (e.g. a customer-facing port), applies optional filtering and truncation, and either forwards packets to an output interface or encapsulates them in VXLAN or GRE and sends them to a remote IP. The original traffic is not modified; only a copy is processed and sent. Typical use is to feed an Aviz Service Node or similar appliance with a subset of traffic for monitoring or analysis.

---

## 2. Prerequisites

- **Operating system:** Linux.
- **Privileges:** vasn_tap must run as root (for raw socket and, in eBPF mode, BPF access).
- **Kernel:** 
  - **AF_PACKET mode** (recommended for most deployments): Linux kernel 3.2 or newer.
  - **eBPF mode:** Linux kernel 5.10 or newer with BTF support.
- **Optional:** systemd for running vasn_tap as a service; systemd journal for viewing counters and logs.

If you received a **prebuilt package** (tarball), you do not need compilers or build tools. If you are building from source, see the main [README.md](../README.md) for required packages (e.g. gcc, make, libyaml-dev; for eBPF: libbpf, clang, bpftool).

---

## 3. Obtaining vasn_tap

You typically receive vasn_tap as a tarball (e.g. `vasn_tap-v1.0.0-<date>-<sha>.tar.gz`). Extract it:

```bash
tar -xzf vasn_tap-<version>.tar.gz
cd vasn_tap-<version>
```

If you are building from source, run `make` in the project root and use `./scripts/build-package.sh` to create a tarball. See [README.md](../README.md) for build instructions.

---

## 4. Installation

From the extracted package directory, run the install script as root:

```bash
sudo ./install.sh
```

This installs:

- The `vasn_tap` binary to `/usr/local/bin/`
- The eBPF object (if present) to `/usr/local/share/vasn_tap/`
- A default config file at `/etc/vasn_tap/config.yaml` (if it does not already exist)
- The `vasn_tapctl` control script (available in your PATH)
- A systemd unit so you can run vasn_tap as a service

**Interactive interface selection:** To have the installer prompt you for the input and output interfaces (and write them into the config), run:

```bash
sudo ./install.sh -i
```

---

## 5. Configuration

Edit the main config file:

```bash
sudo nano /etc/vasn_tap/config.yaml
```

**Required settings:**

- **runtime.input_iface** — The interface from which to capture traffic (e.g. `eth0`, `ens34`).
- **runtime.mode** — Either `afpacket` or `ebpf`. Use `afpacket` unless you have a specific need for eBPF and a supported kernel.
- **runtime.output_iface** — Required if you want to forward traffic or use a tunnel. Omit (or leave unset) for drop-only mode (capture and count, no forward).

**When using a tunnel** (VXLAN or GRE), you must set `runtime.output_iface` to the interface used to reach the tunnel remote IP. The tunnel section specifies `type` (vxlan or gre), `remote_ip`, and for VXLAN: `vni`, `dstport` (default 4789).

**Filter:** The `filter` section is mandatory. Set `default_action` to `allow` or `drop`, and list `rules`. Rules are evaluated first-match; each rule has an `action` (allow or drop) and a `match` (protocol, port_src, port_dst, ip_src, ip_dst, etc.). If no rule matches, `default_action` applies.

**Example — allow all, no tunnel:**

```yaml
runtime:
  input_iface: eth0
  output_iface: eth1
  mode: afpacket
  workers: 4
  stats: true
filter:
  default_action: allow
  rules: []
```

**Example — drop by default, allow specific traffic:**

```yaml
runtime:
  input_iface: eth0
  output_iface: eth1
  mode: afpacket
  stats: true
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

**Example — VXLAN tunnel:**

```yaml
runtime:
  input_iface: eth0
  output_iface: eth1
  mode: afpacket
  stats: true
filter:
  default_action: allow
  rules: []
tunnel:
  type: vxlan
  remote_ip: 192.168.200.1
  vni: 1000
  dstport: 4789
```

**Optional truncation:** To truncate forwarded packets to a fixed length (e.g. 128 bytes), add under `runtime`:

```yaml
  truncate:
    enabled: true
    length: 128
```

Length must be between 64 and 9000 when enabled.

For a full example with comments, see `config.example.yaml` in the package or repository.

---

## 6. Validating configuration

Before starting the service or applying a new config, validate it:

```bash
sudo vasn_tapctl validate
```

To validate a different file without changing the installed config:

```bash
sudo vasn_tapctl validate /path/to/my_config.yaml
```

**Validate-before-apply:** To copy a new config file into place and restart the service only if it is valid, use:

```bash
sudo vasn_tapctl apply /path/to/new.yaml
```

This validates the file first; if validation fails, the existing config and service are unchanged.

---

## 7. Running the service

Start, stop, restart, and check status with vasn_tapctl:

```bash
sudo vasn_tapctl start
sudo vasn_tapctl status
sudo vasn_tapctl stop
sudo vasn_tapctl restart
```

The service runs under systemd. Configuration is read only at startup; **after any config change you must restart** the service for changes to take effect.

---

## 8. Monitoring and logs

**Counters (from journal):**

```bash
vasn_tapctl counters
```

This shows RX, TX, dropped, truncated, and tunnel packet/byte counts from the most recent stats in the journal, plus input/output interface names when available. You may need `sudo` for journal access.

**Live logs:**

```bash
vasn_tapctl logs
```

This tails the vasn_tap service logs (journal). You can pass extra arguments to the underlying journalctl, e.g. `vasn_tapctl logs -n 100`.

**Direct journal access:**

```bash
journalctl -u vasn_tap -f
```

When `runtime.stats` is true, vasn_tap prints periodic stats to stdout (and thus to the journal when run as a service): RX/TX/dropped/truncated counts and rates, tunnel stats if enabled, and optionally filter rule hits and resource usage.

---

## 9. Uninstall

To remove the installed binary, service, and control script:

```bash
sudo ./uninstall.sh
```

The config directory `/etc/vasn_tap` is left in place by default. To remove it as well:

```bash
sudo ./uninstall.sh --purge-config
```

Run `uninstall.sh` from the same package directory where you ran `install.sh`, or ensure the script can find the paths it uses.

---

## 10. Troubleshooting

| Issue | What to do |
|-------|------------|
| **Tunnel init fails / ARP failed** | Ensure the output interface can reach the tunnel remote IP. If the remote is on a directly connected link (e.g. other end of a veth), you may need to ping the remote IP once so the ARP cache is populated, then start vasn_tap. Ensure `runtime.output_iface` is not `lo`. |
| **No packets forwarded (TX always 0)** | Check that `runtime.output_iface` is set when not in drop mode. Check the filter: if `default_action` is `drop`, ensure you have allow rules that match the traffic you expect, and that rule order is correct (first-match wins). |
| **Permission denied / requires root** | Run vasn_tap and vasn_tapctl with `sudo`. vasn_tap needs root for raw sockets and (in eBPF mode) BPF. |
| **Config change not applied** | Restart the service after editing `/etc/vasn_tap/config.yaml`. Config is read only at startup. |
| **Input/Output interface not found** | Check interface names with `ip link show`. Use the exact name (e.g. `eth0`, `ens34`) in the config. |
| **eBPF: /sys/kernel/btf/vmlinux not found** | Your kernel does not support BTF. Use `runtime.mode: afpacket` instead, or upgrade to a kernel >= 5.10 with BTF enabled. |

---

## 11. Support and references

- For detailed functional behavior and limitations, see [Software Functional Specification](SOFTWARE_FUNCTIONAL_SPECIFICATION.md).
- For build, advanced usage, and tuning, see the main [README.md](../README.md).
- For internal architecture and design, see [ARCHITECTURE.md](../ARCHITECTURE.md).

Contact your Aviz representative for product support and updates.
