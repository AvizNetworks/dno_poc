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
| S4 | `10.20.13.249` ubuntu/Aviz@AIF12345 | `10.20.13.250` root/Aviz@AIF12345 | `10.20.13.226` aviz/aviz@123 |

**ToR Switch:** `10.20.13.214` (admin / Aviz@123) — shared across S1 and S2.

**DPF Operator VM:** `10.4.5.136` dpu-vm/admin — k3s cluster, DPF Operator v25.10.1 installed; manages S4's BF3 via DPF provisioning.

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

**Upgrade DPF Operator (handles all post-upgrade fixes automatically):**
```bash
./dpf/scripts/bringup_dpf.sh --upgrade                    # upgrade to v25.10.1
./dpf/scripts/bringup_dpf.sh --upgrade --version v25.10.2 # upgrade to specific version
```

**Provision BF3 + deploy HBN (idempotent, safe to re-run):**
```bash
# Step 1: Provision BF3 OS via rshim (first time)
./dpf/scripts/bringup_dpf.sh --rshim-install

# Step 2: Deploy HBN — NO NGC key needed, uses image already on BF3
# NOTE: BF3 must be re-flashed first for DPUFlavor changes (hugepages, VFs) to apply
./dpf/scripts/bringup_dpf.sh --hbn

# Combined: provision + deploy HBN in one run
./dpf/scripts/bringup_dpf.sh --rshim-install --hbn

# For a different server (S1, S2 etc):
./dpf/scripts/bringup_dpf.sh --server s1 \
  --bmc-ip 10.20.13.216 --oob-ip 10.20.13.247 --serial <SN> \
  --rshim-install --hbn

./dpf/scripts/bringup_dpf.sh --dry-run          # preview steps without applying
```

**DPF health check:**
```bash
./dpf/scripts/status_dpf.sh
```

**Cross-subnet tunnel (required when DPF VM and BF3 are on different subnets):**
```bash
# Per-server presets + Kamaji ClusterIP auto-discovery (start AFTER the DPUCluster exists)
./dpf/scripts/tunnel_dpf.sh --server s4 start   # reverse SSH tunnel DPF VM → x86 host (.226)
./dpf/scripts/tunnel_dpf.sh --server s4 bf3     # print ALL 3 iptables rules to run on BF3:
                                                #   Rule 1 (before bringup): kubeadm join routing
                                                #   Rule 2 (after boot): host processes → API server
                                                #   Rule 3 (after boot): pod traffic → API server
./dpf/scripts/tunnel_dpf.sh --server s4 status  # check tunnel health
./dpf/scripts/tunnel_dpf.sh --server s4 stop    # tear down
```
Note: All 3 BF3 iptables rules are lost on reboot, but `sfc.service` re-applies them at boot
(flavor's `X86_HOST_IP` substituted to the x86 host). Not needed on same-network deployments.
Tunnels are matched per Kamaji ClusterIP, so multiple DPUs' tunnels coexist on one DPF VM.

**Host SR-IOV VFs (run on the x86 host, AFTER the BF3 is flashed with VFs):**
```bash
# auto-detects the BF3 PFs by PCI id 0xa2dc; renames to vf0..vf7; --persist survives reboot
sudo ./dpf/scripts/setup_host_vfs.sh            # vf0..vf3 (PF0), vf4..vf7 (PF1)
sudo ./dpf/scripts/setup_host_vfs.sh --persist  # + systemd oneshot for reboot persistence
```

**Explain the stack (educational HTML map) — run from the DPF VM:**
```bash
./dpf/scripts/explain_stack.sh --server s4   # → ~/dpf_summary/dpf-stack-explained.html
# maps cluster→node→pod→container→namespace→interface→data plane with live values
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

S4 Host (10.20.13.226): NOT involved in k8s (BF3 PCIe rshim + SR-IOV VFs live here)

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
X86_HOST_IP     x86 host for rshim install  (S4: 10.20.13.226 — pass --x86-host)
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
| `servicechainset-controller` CrashLoopBackOff | Run `bringup_dpf.sh --upgrade` — fixes credentials secret, bootstraps CRDs on DPU cluster, creates RBAC |
| After upgrade, DPUServices still Pending | Sub-controller images not updated — `bringup_dpf.sh --upgrade` handles this |
| DPUCluster stuck `phase: Pending`, cluster-manager logs `skip Pending cluster`, no TenantControlPlane | Operator not Ready (half-finished upgrade). Confirm `kubectl get dpfoperatorconfig -n dpf-operator-system` is `Ready=True`; if wedged, clean reinstall the operator then re-run `bringup_dpf.sh` (v25.10.1) |
| DPU stuck `Initializing`, reason `DPUInstallInterfaceNotProvided`, provisioning-controller **panics** in `HandleRebootSync` | DPUNode needs `nodeRebootMethod: external` (v25.10.1; default `hostAgent` panics on OOB). Already set in `05-dpunode.yaml` |
| DPU stuck `Initialize Interface`, reason `DPUDeviceNotReady`; DPUDevice `NodeAttached=False` ("No DPUNode found") | DPUNode needs `spec.dpus: [{name: <server>-bf3}]` (v25.10.1). Already in `05-dpunode.yaml` |
| `DPUFlavor is being referred to by DPU(s)` on re-run | Flavor is per-server now (`<server>-bf3-hbn`) so DPUs don't collide — `bringup_dpf.sh` handles it |
| `Failed to deploy bfcfg — .../bfb//bfb/bfcfg/...` (404) | v25.10.1 `bfCFGFile` is absolute; `bringup_dpf.sh` normalizes the path (no double `/bfb/`) |
| DPUServices `Sync: Unknown`, CNI never deploys, pods `ContainerCreating` with `loopback: missing network name` | Stale ArgoCD cluster secret after a DPUCluster recreate — `bringup_dpf.sh` Step 9b now always refreshes it; manual: delete `<server>-dpu-cluster` secret in `argocd` and re-run |
| Fresh BF3 looks "hung" after flash (OOB down, console quiet, BMC `BootProgress=OEM`) | NOT hung — it's at the **first-login password prompt** on the BMC ARM console. Set password (`ubuntu`/`Aviz@AIF12345`), then `sudo dhclient oob_net0`, `sudo systemctl enable --now sfc.service`, `sudo systemctl restart kubeadm-join.service` |
| Re-flashed BF3: SSH `REMOTE HOST IDENTIFICATION HAS CHANGED` | New host key after flash — `ssh-keygen -R 10.20.13.249` |

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

**`aviz0` is an OVS internal port** already present in `br-hbn` on S1 BF3 (type:internal, MTU 9000, PROMISC). It is not a physical or SF interface — OVS creates it automatically. Traffic mirrored from `mirror_to_dpu.sh` flows through `br-hbn` and exits via `aviz0` into whatever process is listening on it (ASN).

---

## Aviz Service Node (ASN) — DPI on BF3 ARM

ASN is Aviz's Deep Packet Inspection engine. On the BF3 it runs as an ARM64 binary using AF_PACKET (raw sockets on `aviz0`) — no DPDK hugepages required.

**Run ASN directly (S1 BF3):**
```bash
ssh ubuntu@10.20.13.247
cd /home/ubuntu/asn-app
sudo ./build.py        # reads config.json; build disabled, run enabled
# starts: aviz-dc-virtual-mode> prompt = ASN CLI
```

**Key config (`/home/ubuntu/asn-app/config.json`):**
```json
"data_path": "af_packet",
"selected_interfaces": ["aviz0"],
"asn_instance": "virtual",
"config-hugepage": { "enabled": false }
```

**Paths on S1 BF3:**
```
/home/ubuntu/asn-app/                        source repo + config.json
/home/ubuntu/asn-app/build-native/asn-app    compiled ARM64 binary (native)
/home/ubuntu/asn-app/build-generic/asn-app   compiled ARM64 binary (generic/docker)
/home/ubuntu/GA/v2_5/20260610/               GA release build (same structure)

# Docker packaging infrastructure:
/home/aviz/Images/asn-packages/offline_packages/asn-dpu-docker-offline/
  Dockerfile         UBI9 ARM64 base, offline RPMs
  docker.yaml        docker-compose: privileged, network_mode:host, mounts /dev/net/tun
  entrypoint.sh      starts Redis + REST + monitor + asn-core
  run-asn-dpu-docker.sh  builds image from offline kit + runs via docker-compose

# Packaging scripts (create the offline kit tarball):
/home/ubuntu/asn-app/scripts/package-files/prep-asn-dpu-docker.sh
/home/ubuntu/asn-app/scripts/package-files/package-asn.yaml   # build orchestrator config
```

**Installed libs on S1 BF3 host** (available for container bind-mount or COPY):
```
/usr/local/lib/libipoque_pace2.so.7   PACE2 DPI engine (ipoque/Rohde&Schwarz)
/usr/lib/libasn_dpi.so                Aviz proprietary DPI library
```

**Docker containerization:** The full offline kit flow is: `package-asn.py` (run from 10.4.4.40 build server) → creates `asn-image-bluefield-YYYYMMDD.tar.gz` → `prep-asn-dpu-docker.sh` bundles it with base images from 10.4.4.40 → `run-asn-dpu-docker.sh` loads + runs. No pre-built tarball exists on the BF3 yet; the binary runs directly via `build.py`. To containerize without the full pipeline, build a simple Ubuntu-based Dockerfile copying `build-native/asn-app` + the installed libs directly.

**Prerequisite for traffic to reach ASN:** Run `scripts/mirror_to_dpu.sh start` on the x86 host to copy traffic into `br-hbn`; ASN receives it via `aviz0`.

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
