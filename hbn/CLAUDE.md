# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## What This Repo Is

Bash scripts for bringing up NVIDIA HBN (Host-Based Networking) on a BlueField-3 DPU running DOCA 3.3.0. All scripts run **on the BF3** (or from an x86 host via SSH), not locally. Validated on `bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb`.

---

## Deployment Targets

- **BF3 OOB IP:** `10.20.13.228` (ubuntu / Aviz@AIF12345)
- **x86 Host IP:** `10.20.13.12` (admin / Aviz@AIF123)
- **ToR Switch IP:** `10.20.13.214` (admin / Aviz@123)

VSCode tasks (`.vscode/tasks.json`) auto-open SSH sessions to the BF3 and host on folder open.

---

## Common Commands

All scripts require `sudo` and run on the BF3 unless noted.

**Bringup (idempotent, safe to re-run):**
```bash
sudo ./bringup_hbn_bf3.sh
sudo ./bringup_hbn_bf3.sh --enable-bgp --hbn-scripts-dir ~/hbn-scripts
```

**Health check:**
```bash
sudo ./status_hbn.sh
```

**Interface reference (live state + MACs):**
```bash
sudo ./topology_hbn.sh
```

**Access methods cheatsheet (run from any machine):**
```bash
./access_hbn.sh --bf3-ip 10.20.13.228
```

**End-to-end routing validation (SSH-based, run from x86 host or locally):**
```bash
# requires: sudo apt install sshpass
./validate_routing.sh
./validate_routing.sh --setup   # also configures IPs before testing
```

**Static routing test via NVUE REST API (run from any machine):**
```bash
# requires: sudo apt install sshpass
./test_static_routing_rest.sh
./test_static_routing_rest.sh --setup   # also configures ToR and Host IPs + routes
```

**Get a shell inside doca-hbn container:**
```bash
CONT=$(sudo crictl ps | grep doca-hbn | grep -v init | awk '{print $1}')
sudo crictl exec -it $CONT vtysh   # FRR CLI
sudo crictl exec -it $CONT nv      # NVUE CLI
```

---

## Architecture

### Data Plane

```
ToR Switch ←── p0 / p1 (physical ports)
               │
          [BF3 eswitch — switchdev mode]
               │
          OVS-DPDK (br-hbn) ← hardware offload
               │
          doca-hbn container (CRI-O / kubelet)
               │  netns
          FRR (zebra, staticd, bfdd, bgpd)
          NVUE REST API (:8765)
               │
          pf0hpf / pf1hpf (PCIe SubFunctions)
               │
x86 Host ←── enp193s0f0np0 / enp193s0f0np1
```

### Key Concepts

- **SubFunctions (SFs):** sfnum 2, 3, 1514, 1515 — provisioned via `/etc/mellanox/mlnx-sf.conf`. Must exist before the doca-hbn pod starts.
- **SF Representors:** `p0_if_r`, `p1_if_r`, `pf0hpf_if_r`, `pf1hpf_if_r` — kernel netdevs on the BF3 host, ports on `br-hbn`.
- **Container interfaces:** `p0_if`, `p1_if`, `pf0hpf_if`, `pf1hpf_if` — inside the doca-hbn container's netns. These are what FRR/NVUE configure. They start DOWN after pod restart and must be set UP.
- **OVS bridge `br-hbn`:** Connects representors; hardware-offloads matched flows to the eswitch. Check health with `ovs-vsctl show` and `ovs-appctl dpctl/dump-flows type=offloaded`.
- **FRR config:** Persisted to `/var/lib/hbn/etc/frr/` (a hostPath volume). `bgpd` is disabled by default; enable via `--enable-bgp` or edit `daemons` directly.
- **NVUE REST API:** Runs on port 8765 inside the container, proxied to OOB. Credentials set by `hbn-dpu-setup.sh`. Uses a revision/apply workflow for config changes.

### Config Files (mellanox/)

| File | Purpose |
|---|---|
| `mlnx-sf.conf` | Creates the 4 SubFunctions with specific MACs and CPU affinity |
| `hbn.conf` | OVS bridge topology: which ports are uplinks vs. host-facing |
| `mlnx-bf.conf` / `mlnx-ovs.conf` | BF3 system-level OVS/DPDK config |
| `sfc.conf` / `sfc-ovs.conf` | SFC bridge config (currently unused) |
| `hbn_profiles/` | DPDK resource/CPU profiles for doca-hbn |

### Script Internals

`bringup_hbn_bf3.sh` runs 11 idempotent steps. Each step checks current state before acting — safe to re-run mid-bringup. It uses `crictl` (not `docker`) because the BF3 uses CRI-O under kubelet.

`status_hbn.sh` accesses the container's network namespace via `nsenter -t <PID> -n` to check interface states and FRR daemons without `crictl exec`, which avoids TTY issues.

`validate_routing.sh` SSHes to all three devices (ToR, BF3, Host) using `sshpass`. Credentials are hardcoded at the top of the file — update them there if they change.

`test_static_routing_rest.sh` stages interface IPs and static routes via NVUE REST API (revision workflow), then verifies via `?rev=applied` and FRR. **NVUE REST apply is broken on DOCA 3.3.0** — `PATCH /revision/$REV {"state":"apply"}` leaves revisions `pending` indefinitely. Apply must be triggered from inside the container: `crictl exec $CONT nv config apply --assume-yes`. The script falls back to `vtysh` if the apply doesn't commit. **Static route nexthops must not be within the same subnet as the destination prefix** — FRR marks such routes `S inactive` (recursive loop). Use a non-connected prefix (e.g., `10.10.1.0/24 via 5.5.5.1` is valid; `5.5.5.0/24 via 5.5.5.1` is not).

---

## Troubleshooting Quick Reference

| Symptom | Fix |
|---|---|
| SFs missing | `sudo bash /etc/mellanox/mlnx-sf.conf` |
| Interfaces DOWN after pod start | `ip link set p0_if up` inside container |
| `crictl pull` fails | `echo "nameserver 8.8.8.8" >> /etc/resolv.conf` |
| REST API 401 | Run `hbn-dpu-setup.sh -u nvidia -p nvidia -e` from its source dir |
| NVUE revision stuck `pending` | REST apply is broken on DOCA 3.3.0 — use `crictl exec $CONT nv config apply --assume-yes` inside the container |
| FRR static route shows `S inactive` | Nexthop is in the same subnet as the destination — use a non-connected prefix (e.g., `10.10.1.0/24 via 5.5.5.1`, not `5.5.5.0/24 via 5.5.5.1`) |
| bgpd not running | `--enable-bgp` flag or `sed -i 's/bgpd=no/bgpd=yes/' /var/lib/hbn/etc/frr/daemons` |
| kubelet pod not starting | Check `journalctl -u kubelet | grep hbn`; ensure `/var/lib/hbn/` dirs exist |
