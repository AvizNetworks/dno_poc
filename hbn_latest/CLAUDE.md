# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## What This Repo Is

Two independent toolsets in this repo — keep them separate:

- **`scripts/`** — HBN (Host-Based Networking): standalone bringup of doca-hbn on a BF3. Runs on the BF3 directly. No Kubernetes required.
- **`dpf/`** — DPF (DPU Provisioning Framework): Kubernetes-native lifecycle management for BF3 DPUs. Runs from the DPF Operator VM. HBN will be deployed as a DPUService on top of DPF in a future step.

HBN scripts validated on `bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb`.

---

## Deployment Targets

| Server | BF3 ARM (OOB) | BF3 BMC | x86 Host |
|---|---|---|---|
| S1 | `10.20.13.247` ubuntu/Aviz@AIF12345 | `10.20.13.216` root/Aviz@AIF12345 | `10.20.13.13` admin/Aviz@AIF123 |
| S2 | `10.20.13.228` ubuntu/Aviz@AIF12345 | `10.20.13.212` root/Aviz@AIF12345 | `10.20.13.12` admin/Aviz@AIF123 |
| S3 | `10.4.5.165` ubuntu/H3lLoW0rLd12! | `10.4.5.166` root/MaiBF3@94538 | — |
| S4 | `10.20.13.249` ubuntu/Aviz@AIF12345 | `10.20.13.250` root/Aviz@AIF12345 | `10.20.13.207` aviz/aviz@123 |

**ToR Switch:** `10.20.13.214` (admin / Aviz@123) — shared across S1 and S2.

**DPF Operator VM:** `10.4.5.136` dpu-vm/admin — k3s cluster, DPF Operator v25.7.0 installed; manages S4's BF3 via DPF provisioning.

VSCode tasks (`.vscode/tasks.json`) auto-open SSH sessions to all 4 servers on folder open.

---

## Common Commands

All scripts require `sudo` and run on the BF3 unless noted.

**Bringup (idempotent, safe to re-run):**
```bash
sudo ./scripts/bringup_hbn_bf3.sh
sudo ./scripts/bringup_hbn_bf3.sh --enable-bgp --rest-pass <password>

# With SR-IOV VFs (enable on host first — see VF section below)
sudo ./scripts/bringup_hbn_bf3.sh --vfs 8            # 4 VFs per PF
sudo ./scripts/bringup_hbn_bf3.sh --p0-vfs 4 --p1-vfs 4
```

**Health check:**
```bash
sudo ./scripts/status_hbn.sh   # shows all interfaces including VFs if enabled
```

**Interface reference (live state + MACs + host NIC mapping):**
```bash
sudo ./scripts/topology_hbn.sh
sudo ./scripts/topology_hbn.sh --host-ip <HOST-IP>   # auto-discovers host NIC names
```

**Access methods cheatsheet (run from any machine):**
```bash
./scripts/access_hbn.sh --bf3-ip <BF3-OOB-IP>
```

**Enable SR-IOV VFs on x86 host (required before --vfs bringup):**
```bash
# On x86 host — adjust interface names per server
echo 4 > /sys/class/net/enp65s0f0np0/device/sriov_numvfs   # S1
echo 4 > /sys/class/net/enp65s0f1np1/device/sriov_numvfs
# Verify: ip link show enp65s0f0np0 | grep "vf "
```

**VF interface mapping (after --vfs bringup):**
```
BF3 container   ↔  Host NIC
pf0vf0_if       ↔  enp65s0f0v0   (sfnum 4)
pf0vf1_if       ↔  enp65s0f0v1   (sfnum 5)
pf0vf2_if       ↔  enp65s0f0v2   (sfnum 6)
pf0vf3_if       ↔  enp65s0f0v3   (sfnum 7)
pf1vf0_if       ↔  enp65s0f1v0   (sfnum 8)
pf1vf1_if       ↔  enp65s0f1v1   (sfnum 9)
pf1vf2_if       ↔  enp65s0f1v2   (sfnum 10)
pf1vf3_if       ↔  enp65s0f1v3   (sfnum 11)
```

**End-to-end routing validation (SSH-based, run from x86 host or locally):**
```bash
# requires: sudo apt install sshpass
./scripts/validate_routing.sh
./scripts/validate_routing.sh --setup   # also configures IPs before testing
```

**Static routing test via NVUE REST API (run from any machine):**
```bash
# requires: sudo apt install sshpass
./scripts/test_static_routing_rest.sh          # targets S2 (10.20.13.228) — 5.5.5.x on Ethernet76
./scripts/test_static_routing_rest.sh --setup  # also configures ToR and Host IPs + routes

./scripts/test/test_static_routing_rest1.sh          # targets S1 (10.20.13.247) — 6.6.6.x on Ethernet72
./scripts/test/test_static_routing_rest1.sh --setup
```

**Get a shell inside doca-hbn container:**
```bash
CONT=$(sudo crictl ps | grep doca-hbn | grep -v init | awk '{print $1}')
sudo crictl exec -it $CONT vtysh   # FRR CLI
sudo crictl exec -it $CONT nv      # NVUE CLI
```

---

## DPF Commands

All DPF scripts run from the **DPF Operator VM** (`10.4.5.136`). No sudo required.
The DPF stack is completely separate from the HBN scripts above.

**Prerequisites:**
- `KUBECONFIG=~/.kube/config` (k3s kubeconfig on DPF Operator VM)
- BFB file placed at `/opt/bfb/bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb`
- BMC reachable: `10.20.13.250` (S4)

**Provision BF3 via DPF (idempotent, safe to re-run):**
```bash
./dpf/scripts/bringup_dpf.sh
./dpf/scripts/bringup_dpf.sh --dry-run          # preview steps without applying
./dpf/scripts/bringup_dpf.sh --rshim-install    # flash via x86 rshim (bypasses Redfish)
```

**DPF health check:**
```bash
./dpf/scripts/status_dpf.sh
```

**Cross-subnet tunnel (required when DPF VM and BF3 are on different subnets):**
```bash
./dpf/scripts/tunnel_dpf.sh start   # open reverse SSH tunnel DPF VM → x86 host
./dpf/scripts/tunnel_dpf.sh bf3     # print iptables DNAT commands to run on BF3
./dpf/scripts/tunnel_dpf.sh status  # check tunnel health
./dpf/scripts/tunnel_dpf.sh stop    # tear down
```

**Get DPU cluster kubeconfig:**
```bash
kubectl get secret s4-dpu-cluster-admin-kubeconfig -n dpf-operator-system \
  -o jsonpath='{.data.admin\.conf}' | base64 -d > /tmp/dpu-kubeconfig
kubectl get nodes --kubeconfig /tmp/dpu-kubeconfig
```

**Architecture (OOB-only — x86 host NOT in k8s cluster):**
```
DPF Operator VM (10.4.5.136)
  └── DPF Operator → Redfish API → BMC (10.20.13.250) → flash BFB on BF3
  └── Kamaji (virtual k8s control plane) ← BF3 kubelet joins via OOB (10.20.13.249)

S4 Host (10.20.13.207): NOT involved in k8s

SUBNET NOTE: TCP from 10.20.13.x → 10.4.5.x is blocked in this lab.
Use tunnel_dpf.sh before running --rshim-install. See dpf/README.md.
```

**Key config variables** (top of `bringup_dpf.sh` — update per environment):
```
BF3_BMC_IP      BMC/Redfish endpoint        (default: 10.20.13.250)
BF3_OOB_IP      BF3 OOB management IP       (default: 10.20.13.249)
BF3_SERIAL      BF3 serial number           (default: MT2437600HGY)
BFB_FILE        local path to .bfb          (default: /opt/bfb/bf-bundle-*.bfb)
BFB_REGISTRY_IP IP serving BFB over HTTP    (default: 10.4.5.136)
X86_HOST_IP     x86 host for rshim install  (default: 10.20.13.207)
```

**Get BF3 serial number:**
```bash
ssh ubuntu@<BF3-OOB> 'sudo dmidecode -t system | grep Serial'
# or from x86 host:
ssh aviz@<x86-host> 'sudo dmidecode -t system | grep -A2 "System Information" | grep Serial'
```

**Troubleshooting DPF:**

| Symptom | Fix |
|---|---|
| `DPFOperatorConfig` missing | Run `bringup_dpf.sh` — step 5 creates it |
| Kamaji pods not starting | Check PVC bound: `kubectl get pvc -n dpf-operator-system` |
| BFB stuck downloading | Check registry reachable: `curl http://BFB_REGISTRY_IP:8080/` |
| DPU phase stuck `OSInstalling` | BMC reboot in progress — wait up to 30 min |
| DPU phase `Error` / `FailToInstall` / `404` | BMC skipped flash (same version) — run `bringup_dpf.sh --rshim-install` or patch: `kubectl patch dpu s4-dpu -n dpf-operator-system --subresource=status --type=merge -p '{"status":{"phase":"Ready"}}'` |
| `kubeadm join: no route to host` | TCP blocked between subnets — run `tunnel_dpf.sh start` then `tunnel_dpf.sh bf3` |
| etcd-defrag jobs accumulating | Run `bringup_dpf.sh` — step 3 cleans them up |
| `sudo` slow on BF3 | `echo "127.0.0.1 s4-dpu" \| sudo tee -a /etc/hosts` |

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
- **NVUE REST API:** Runs on port 8765 inside the container, proxied to OOB. Credentials set via `doca_hbn_v3.3.0/scripts/3.3.0/encrypt_password.py` (run by bringup script). Uses a revision/apply workflow for config changes.

### Config Files (mellanox/)

| File | Purpose |
|---|---|
| `mlnx-sf.conf` | Creates the 4 SubFunctions with specific MACs and CPU affinity |
| `hbn.conf` | OVS bridge topology: which ports are uplinks vs. host-facing |
| `mlnx-bf.conf` / `mlnx-ovs.conf` | BF3 system-level OVS/DPDK config |
| `sfc.conf` / `sfc-ovs.conf` | SFC bridge config (currently unused) |
| `hbn_profiles/` | DPDK resource/CPU profiles for doca-hbn |

### Script Internals

`scripts/bringup_hbn_bf3.sh` runs 14 idempotent steps. Each step checks current state before acting — safe to re-run mid-bringup. It uses `crictl` (not `docker`) because the BF3 uses CRI-O under kubelet. Reference configs are deployed from `mellanox/` and `doca_hbn_v3.3.0/` at the repo root — the full repo must be present on the BF3.

`scripts/status_hbn.sh` accesses the container's network namespace via `nsenter -t <PID> -n` to check interface states and FRR daemons without `crictl exec`, which avoids TTY issues.

`scripts/validate_routing.sh` SSHes to all three devices (ToR, BF3, Host) using `sshpass`. Credentials are hardcoded at the top of the file — update them there if they change.

`scripts/mirror_to_dpu.sh` sets up a tc mirred copy (non-destructive) from an x86 host interface to the BF3 PCIe link, so all traffic flows through OVS br-hbn and can be mirrored to `aviz0` for Aviz Service Node DPI. Run on the x86 host with `sudo`. Usage: `start | stop | status`. Edit `SRC_IFACE` and `DST_IFACE` at the top for each server — defaults are for S1 (eno2 → enp65s0f0np0).

`scripts/test_static_routing_rest.sh` (S2 — 10.20.13.228, Ethernet76, 5.5.5.0/24) and `scripts/test/test_static_routing_rest1.sh` (S1 — 10.20.13.247, Ethernet72, 6.6.6.0/24) both stage interface IPs and static routes via NVUE REST API (revision workflow), then verify via `?rev=applied` and FRR. **NVUE REST apply is broken on DOCA 3.3.0** — `PATCH /revision/$REV {"state":"apply"}` leaves revisions `pending` indefinitely. Apply must be triggered from inside the container: `crictl exec $CONT nv config apply --assume-yes`. The script falls back to `vtysh` if the apply doesn't commit — the fallback also sets interface IPs directly via `ip addr` in case NVUE fails to apply them. **Static route nexthops must not be within the same subnet as the destination prefix** — FRR marks such routes `S inactive` (recursive loop). Use a non-connected prefix (e.g., `10.10.1.0/24 via 5.5.5.1` is valid; `5.5.5.0/24 via 5.5.5.1` is not). **`sudo` over SSH requires `-S` flag** — without it, sudo silently fails with no TTY. Always use `echo '$PASS' | sudo -S command`.

---

## Troubleshooting Quick Reference

| Symptom | Fix |
|---|---|
| SFs missing | `sudo bash /etc/mellanox/mlnx-sf.conf` |
| Interfaces DOWN after pod start | `ip link set p0_if up` inside container |
| `crictl pull` fails | `echo "nameserver 8.8.8.8" >> /etc/resolv.conf` |
| REST API 401 | Re-run `scripts/bringup_hbn_bf3.sh --rest-pass <pass>`; or manually: `crictl exec $CONT bash -c "echo 'nvidia:<pass>' | chpasswd"` |
| NVUE revision stuck `pending` | REST apply is broken on DOCA 3.3.0 — use `crictl exec $CONT nv config apply --assume-yes` inside the container |
| FRR static route shows `S inactive` | Nexthop is in the same subnet as the destination — use a non-connected prefix (e.g., `10.10.1.0/24 via 5.5.5.1`, not `5.5.5.0/24 via 5.5.5.1`) |
| bgpd not running after `--enable-bgp` | bringup edits `/var/lib/hbn/etc/frr/daemons` then runs `crictl exec $CONT supervisorctl restart frr` — if still not running, run that command manually |
| OVS `p0`/`p1` "Invalid argument" in `ovs-vsctl show` | **Benign on BF3 switchdev** — physical uplinks are owned by eswitch firmware; OVS-DPDK cannot bind them as netdev ports. `status_hbn.sh` correctly shows this as `[WARN]` not `[FAIL]`. Only non-p0/p1 "Invalid argument" errors indicate a real hugepage/OVS problem. |
| kubelet pod not starting | Check `journalctl -u kubelet | grep hbn`; ensure `/var/lib/hbn/` dirs exist |
