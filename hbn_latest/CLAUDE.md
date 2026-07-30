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
| S8 | `10.20.13.156` ubuntu/Aviz@AIF12345 | `10.20.13.234` root/Aviz@AIF12345 | `10.20.13.11` admin/Aviz@AIF123 |

S8 = ASUS ESC4000A-E10, BF3 900-9D3B6 (400GbE/NDR, 32GB, SN MT2416XZ03VT). BF3 ARM OOB is DHCP and flips `10.20.13.156`↔`10.20.13.242` across reboots — rediscover via BMC ARP if unreachable (BMC MAC = ARM MAC +1). S8 provisioned via DPF (`worker3`, apiserver_port `6445`) + HBN with 8 VFs.
S7 = sister ASUS `10.20.13.10` admin/Aviz@AIF123 — BF3 still in InfiniBand mode, not yet provisioned (no MFT installed there).

**ToR Switch:** `10.20.13.214` (admin / Aviz@123) — shared across S1 and S2.

**DPF Operator VM:** `10.4.5.136` dpu-vm/admin — k3s cluster, DPF Operator v25.10.1 installed; manages S4's and S8's BF3s via DPF provisioning (workers in `dpf/config.yaml`).

VSCode tasks (`.vscode/tasks.json`) auto-open SSH sessions to all servers on folder open.

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

**VF bringup — ORDER MATTERS. Host VFs FIRST, then BF3 `--vfs`.**
The BF3 `sfc.conf` maps the VF eswitch representors (`pf0vfN`), which only exist once
the x86 host has created the SR-IOV VFs. So always create host VFs before running
`--vfs` on the BF3, or `sfc.service` will fail (missing `pf0vfN` port).

Step 1 — **on the x86 host** — auto-detects the BF3 PFs (`15b3:a2dc`), creates 4 VFs/PF,
brings them up, and installs `bf3-host-vfs.service` so they persist across reboot
(`sriov_numvfs` resets to 0 otherwise):
```bash
sudo ./scripts/setup_host_vfs_standalone.sh          # 4 VFs/PF (default)
# manual equivalent (names per-server, e.g. S7=enp195s0f0np0, S1=enp65s0f0np0):
#   echo 4 > /sys/class/net/enp195s0f0np0/device/sriov_numvfs
```
Step 2 — **on the BF3**: `sudo ./scripts/bringup_hbn_bf3.sh --vfs 8`

**VF SubFunction numbering — AUTHORITATIVE (per NVIDIA `install.sh`), NOT 4-11.**
ECPF0 VFs (`pf0vfN`) use **sfnum 1001+N**; ECPF1 VFs (`pf1vfN`) use **sfnum 1257+N**.
The patched udev namers map these ranges → `pf0vfN_if`/`pf1vfN_if` (+ `_if_r` reps).
Using sfnum 4-11 (an old hand-rolled scheme) is why earlier VF bringups needed manual
workarounds — the namers don't map that range. The bringup script now generates the
correct sfnums, and the whole VF path is config-driven (mlnx-sf.conf + sfc.conf +
hbn.conf) so it is **reboot-persistent** (validated on S7: all 8 VFs come up in FRR
from a cold boot, no manual steps).
```
BF3 container   SF rep (br-hbn)   eswitch rep (br-hbn)   sfnum      Host NIC (S7)
pf0vf0_if       pf0vf0_if_r       pf0vf0                 1001       enp195s0f0v0
pf0vf1_if       pf0vf1_if_r       pf0vf1                 1002       enp195s0f0v1
pf0vf2_if       pf0vf2_if_r       pf0vf2                 1003       enp195s0f0v2
pf0vf3_if       pf0vf3_if_r       pf0vf3                 1004       enp195s0f0v3
pf1vf0_if       pf1vf0_if_r       pf1vf0                 1257       enp195s0f1v0
pf1vf1_if       pf1vf1_if_r       pf1vf1                 1258       enp195s0f1v1
pf1vf2_if       pf1vf2_if_r       pf1vf2                 1259       enp195s0f1v2
pf1vf3_if       pf1vf3_if_r       pf1vf3                 1260       enp195s0f1v3
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

**Provision BF3 + deploy HBN (idempotent, safe to re-run). MULTI-DPU validated:**
Workers are defined in `dpf/config.yaml` (topology + unique `apiserver_port` per worker:
s4=6443, s2=6444) and `dpf/config.local.yaml` (per-worker passwords, gitignored — copy
`config.local.sample.yaml`). CLI flags override config. NO NGC key needed anywhere
(operator chart from /opt/dpf/*.tgz, HBN image cached/public).
```bash
# provision + HBN for a worker from config.yaml (the normal path)
./dpf/scripts/bringup_dpf.sh --worker worker1 --rshim-install --hbn   # S4
./dpf/scripts/bringup_dpf.sh --worker worker2 --rshim-install --hbn   # S2 (Lenovo — see CRD note)

# NOTE: BF3 must be re-flashed for DPUFlavor changes (hugepages, VFs, configFiles) to apply
./dpf/scripts/bringup_dpf.sh --worker worker1 --hbn      # HBN only (already provisioned)
./dpf/scripts/bringup_dpf.sh --dry-run                   # preview (first worker)

# legacy explicit-flags form still works:
./dpf/scripts/bringup_dpf.sh --server s2 --bmc-ip 10.20.13.212 --oob-ip 10.20.13.228 \
  --serial 53FV46T002X --rshim-install --hbn
```
First boot after a flash = 2 console commands (password + `sudo systemctl start
dpf-firstboot-kick`); every later boot is hands-off (flavor bakes oob-net0-dhcp + kicker).

**DPF health check:**
```bash
./dpf/scripts/fleet_status.sh [--frr]    # ALL workers: DPU/cluster/node/HBN (+FRR counts)
./dpf/scripts/status_dpf.sh              # single-cluster deep check
```
Per-DPU cluster access — use PER-SERVER kubeconfigs (shared ~/dpu-tc-kubeconfig gets
overwritten by the last bringup): `kubectl --kubeconfig ~/s4-tc-kubeconfig ...` / `~/s2-tc-kubeconfig`.

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
| DPU stuck `Initialize Interface`, logs `status.psid: Invalid value ... '^MT_?[A-Z0-9]+$'` | **Lenovo/OEM card** — DPUDevice CRD only accepts NVIDIA PSIDs. Relax the CRD `status.psid.pattern` to `^[A-Za-z0-9_-]+$` (re-apply after operator upgrades). Prefer NVIDIA-branded cards |
| 2nd DPUCluster's TCP pods `Pending` (`Insufficient cpu`) | Two 3-replica TCPs don't fit S5 — patch the new TCP: `{"spec":{"controlPlane":{"deployment":{"replicas":1}}}}` |
| 2nd DPU's pods stuck `ContainerCreating` (`loopback: missing network name`), apps `Sync: Unknown` | Rebuild the ArgoCD cluster secret from the CURRENT tenant kubeconfig + `kubectl rollout restart statefulset/argocd-application-controller -n argocd` |
| doca-hbn pod deleted → new pod stuck `Init:0/1` forever | init-sfs deadlock: SF netdevs back in host netns unnamed — on the BF3: `sudo systemctl restart sfc.service`, **then** `systemctl is-active kubelet \|\| sudo systemctl start kubelet` (kubelet coupled to sfc — stays down if the restart fails; stranded S4 NotReady 8 days) |
| First boot ignores baked systemd units (kicker/oob) | DPF writes flavor configFiles via **cloud-init mid-first-boot** — units can't self-start on boot #1. Console: `sudo systemctl start dpf-firstboot-kick`. Boot #2+ is hands-off |
| Host VFs impossible on S4's x86 host | `.226` is a **VMware VM** — PCI passthrough doesn't expose SR-IOV (`sriov_totalvfs` empty). Use S2 (bare metal, `/opt/dpf/setup_host_vfs.sh`, rshim0=BF3 rshim1=BF2) for host-VF work |
| Host↔FRR traffic dead (ARP leaves `pfXvfN_if`, nothing at host VF) | br-hbn drops unchained traffic; `sfc.sh` now installs priority-500 port-pair flows (validated S2, all 12 ports). Check `ovs-ofctl dump-flows br-hbn \| grep -c priority=500`; `systemctl restart sfc.service` re-applies (also needed once if host VFs created after boot) |
| Throughput low / ARM cores busy under load | DPF HBN data plane is **CPU-routed** (software datapath) — by design of the raw-DaemonSet deployment. Eswitch offload = DPUService/chains migration (README design note). Do NOT flip br-hbn to netdev — tested, doesn't offload, sfc-controller reverts it |
| **Standalone** (S1-class) `--vfs` box: VF ports pass no traffic | Stock pair-rule machinery only manages the original 4 ports; the 8 VF pairs are missing. Fix via `/etc/mellanox/hbn.conf` `LINK_PROPAGATION` + stock sfc adoption in a maintenance window — NOT static flows (its refresher deletes foreign rules) |
| Fresh BF3: `ib0`/`ib1` present (no `p0`/`p1`), `devlink dev eswitch show` → "Operation not supported", `mlnx-sf create` → "SF ports are not supported", init-sfs loops `Device "p0_if" does not exist` | BF3 shipped in **InfiniBand mode**; `LINK_TYPE=ETH` is only staged as **Next Boot** (`mlxconfig -e q` shows `Current=IB`). It commits ONLY on a **true cold power cycle** that cuts the PCIe slot power: `sudo ipmitool chassis power cycle` on the x86 host. Does NOT work: ARM `reboot`, `chassis power reset`, BF3-BMC `obmcutil chassisoff/chassison` (warm), or `mlxfwreset -l3` (hung the ARM ~15 min, needed BMC recovery). Root cause we hit it: BMC 404 → patched DPU→Ready → rshim OS-only flash never applied the flavor nvconfig |
| S8-class BMC: DPU `Error`, condition `BFBTransferred` reason `FailToInstall` "get status: 404" (NOT `OSInstalled`) | Same 404-skip family as S4 but different condition type — `bringup_dpf.sh` now checks both `OSInstalled` and `BFBTransferred` and auto-patches DPU→Ready. Then BF3 still needs the cold power cycle above to apply nvconfig |
| `--hbn` re-run loops forever (recreates DPUFlavor → deletes DPU → reflash → BF3 leaves cluster → repeat) | Step 8 used to delete/recreate the immutable flavor unconditionally. `bringup_dpf.sh` now `kube diff`s first and **skips** the destructive recreate when the flavor is unchanged (no DPU delete, no reflash) |
| Deleting a DPUCluster's TenantControlPlane (e.g. to free CPU) breaks CNI for **every** DPU | Kamaji stops regenerating that cluster's `admin-kubeconfig` secret; the DPUService Application generator iterates ALL DPUClusters and one missing secret blocks Application creation for the whole fleet (new DPU never gets CNI). Keep every TCP healthy. On recreate, re-patch `networkProfile.port` (unique per worker) AND `networkProfile.address=<DPF_VM_IP>` — the DPUCluster controller resets them |
| s8/2nd-DPU apps `Sync: Unknown`, `dial tcp <clusterIP>:6443 i/o timeout` | ArgoCD cluster secret's `server` URL hardcodes `:6443` but this cluster's TCP listens on its unique `apiserver_port` (e.g. 6445). Patch the secret's base64 `server` to `https://<server>-dpu-cluster.dpf-operator-system.svc:<apiserver_port>`, then hard-refresh the apps |
| BF3 node `Ready` but doca-hbn `Pending`; kubelet logs `node "<n>" not found` (only *updating*, never *creating*) | After a DPU delete/recreate the Node object was GC'd; kubelet has a valid cert so it doesn't re-bootstrap. `sudo systemctl restart kubelet` forces node re-registration. Note `kubeadm reset` wipes the BF3 iptables DNAT rules — reapply after |
| BF3 containerd can't pull `k8s.gcr.io/pause:3.9` (DNS refused/timeout) | resolv.conf nameservers dead (`192.168.100.1`, subnet `.243`). `sudo resolvectl dns oob_net0 8.8.8.8` (resolv.conf is a systemd-resolved-managed file — editing it directly gets regenerated) |
| **Deleting/recreating a DPUCluster's TenantControlPlane takes HBN down** (e.g. to free CPU) | **DON'T.** It rotates the cluster CA → node cert, CNI, SA tokens, ArgoCD creds all break; multi-hour recovery (see runbook below). Data plane keeps forwarding while it's down, but the node can't recover from any reboot/crash until the CP is restored. Free CPU by lowering replicas, not deleting TCPs. |
| DPU shows `phase: Error` / `ready=Error` in fleet_status but HBN pod is `1/1 Running` | **Cosmetic** — leftover DPU-CR provisioning phase from the Redfish-404 auto-patch. Does NOT affect HBN. Clear it: `kubectl patch dpu <server>-dpu -n dpf-operator-system --subresource=status --type=merge -p '{"status":{"phase":"Ready"}}'` |
| rshim `bfb-install` → `cat: write error: Connection timed out` / `Failed to push BFB` | Two causes, check both: (1) **BF3 BMC runs its own rshim** competing with host PCIe rshim — on the BMC `systemctl stop rshim`; (2) host rshim fell back to slow **"direct io"** (journal: `Fall-back to direct io`) and stalls at `BOOT_TIMEOUT`. Fix throughput with **vfio**: `echo vfio-pci > /sys/bus/pci/devices/<rshim_bdf>/driver_override; echo <rshim_bdf> > /sys/bus/pci/drivers_probe; systemctl restart rshim` (viable only if the rshim function `xx:00.2` is alone in its IOMMU group). Also bump `echo "BOOT_TIMEOUT 1200" > /dev/rshim0/misc`. NOTE: rshim function `c3:00.2` is only exposed while the ARM is booted — a bricked BF3 (bad eMMC) stops presenting it, so recover via the **BF3 BMC rshim**, not host PCIe |

---

## Runbook: recover HBN after a TenantControlPlane was deleted/recreated

Recreating a DPUCluster's TCP gives it a **fresh CA + etcd**, which strands the BF3 node and wipes its workloads. Recovering **without a reflash** (validated on s2, 2026-07-23), in order:

1. **Rejoin the node** (its old kubelet cert is signed by the dead CA). Kamaji TCPs here lack `--enable-bootstrap-token-auth`, so bootstrap-token join fails (`Unauthorized`) — instead **hand-sign a kubelet cert** from the TCP CA secret:
   ```bash
   # on DPF VM: extract CA, sign kubelet client cert (CN=system:node:<server>-dpu, O=system:nodes)
   kubectl get secret <server>-dpu-cluster-ca -n dpf-operator-system -o jsonpath='{.data.ca\.crt}'|base64 -d>ca.crt
   kubectl get secret <server>-dpu-cluster-ca -n dpf-operator-system -o jsonpath='{.data.ca\.key}'|base64 -d>ca.key
   openssl genrsa -out kubelet.key 2048
   openssl req -new -key kubelet.key -subj "/O=system:nodes/CN=system:node:<server>-dpu" -out k.csr
   openssl x509 -req -in k.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 \
     -extfile <(printf 'extendedKeyUsage=clientAuth\n') -out kubelet.crt
   # build /etc/kubernetes/kubelet.conf (embed ca.crt + kubelet.crt/key, server https://<DPF_VM>:<apiserver_port>)
   # on BF3: also place /etc/kubernetes/pki/ca.crt and /var/lib/kubelet/config.yaml
   #   (config.yaml from: kubectl --kubeconfig <tenant> get cm kubelet-config -n kube-system -o jsonpath='{.data.kubelet}')
   #   rm /etc/kubernetes/bootstrap-kubelet.conf ; reapply iptables DNAT ; systemctl restart kubelet
   ```
   Node goes `Ready`. (`kubeadm reset` wipes the iptables DNAT rules — reapply after.)

2. **Fix the ArgoCD cluster secret** (`<server>-dpu-cluster` in ns `argocd`) — after a recreate it has the **wrong port** (`:6443` vs the worker's unique port) AND the **old CA/creds**. Rebuild BOTH from the current admin kubeconfig: patch `server` to `https://<server>-dpu-cluster.dpf-operator-system.svc:<port>` and `config` to `{"tlsClientConfig":{"caData":..,"certData":..,"keyData":..}}` (base64 PEM from the kubeconfig). Then `kubectl rollout restart statefulset/argocd-application-controller -n argocd`.

3. **Clean leftover apps** of any deleted server: `kubectl delete application <deadserver>-dpu-cluster-* -n dpf-operator-system`.

4. **Manually sync the CNI apps** — ArgoCD won't auto-retry a revision it already failed (`Skipping auto-sync: failed previous sync attempt`). Force each:
   ```bash
   for a in cni-installer flannel multus nvidia-k8s-ipam ovs-cni sriov-device-plugin; do
     kubectl patch application <server>-dpu-cluster-$a -n dpf-operator-system --type merge -p '{"operation":{"sync":{}}}'; done
   ```
   CNI DaemonSets deploy → multus regenerates its host kubeconfig with the new CA → `x509: unknown authority` errors stop → pod sandboxes succeed.

5. **init-sfs deadlock** (`Device "p0_if" does not exist` loop): on the BF3 `sudo systemctl restart sfc.service` then confirm `systemctl is-active kubelet`. doca-hbn main container then starts; bring interfaces up (`ip link set p0_if up` etc.).

FRR config survives the whole ordeal (persisted on the BF3 hostPath), so the server's VRF/VXLAN/VLAN setup comes back intact. **ArgoCD Applications live in ns `dpf-operator-system`, not `argocd`.** The tenant apiserver may return empty on cluster-wide `LIST` during churn — trust `crictl` on the BF3 as ground truth.

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
| **Fresh flash:** init-sfs loops `Device "p0_if" does not exist`, host still shows `enp3s0f0s2` (SFs never renamed to `p0_if`) | A clean bf-bundle flash has `sfc-hbn` but not the full `hbn-runtime` prep (we skip `install.sh` — it hangs on mgmt-VRF/SSH). init-sfs waits for `p0_if` **on the host** then moves it into the pod; stock `/lib/udev/auxdev-sf-netdev-rename` only emits `enp<b>s<d>f<f>s<sfnum>`. **`bringup_hbn_bf3.sh` now fixes this**: installs `sfc-state-propagation` offline from `/var/hbn-repo-*` + patches the udev helper (`source /etc/mellanox/sfc.conf` + `SFMAP[2]=p0_if…`) + renames existing core SFs. Manual: patch the helper, then `ip link set enp3s0f0s2 down; ip link set enp3s0f0s2 name p0_if; ip link set p0_if up` (sfnum 2→p0_if, 3→p1_if, 1514→pf0hpf_if, 1515→pf1hpf_if). Do NOT run `install.sh`. |
| **Fresh flash:** `status_hbn.sh` FAILs `p0_if_r not found` + OVS `p0_if_r: could not set configuration (No such device)`, host shows `en3f0pf0sf2` | Same gap on the **representor** namer `/lib/udev/sf-rep-netdev-rename` (stock emits `en<b>f<f>pf<x>sf<sfnum>`). Reps never get `p0_if_r` names → `br-hbn` ports can't bind → no dataplane offload. **`bringup_hbn_bf3.sh` now patches this too** (`SFRMAP[2]=p0_if_r…`) + renames existing reps (match `phys_port_name pf0sf<sfnum>`). Prefer re-running the bringup (lets `sfc.sh` own br-hbn); avoid hand `ovs-vsctl add-port` — see stale-br-hbn row below. `p0`/`p1` "Invalid argument" is a **separate benign** switchdev warning, not this. |
| VFs: `--vfs 8` created SFs but FRR shows no `pf*vf*_if`; host SFs named `enp3s0f0s4`… (sfnum 4-11) | **Wrong VF sfnum scheme.** Authoritative (per `install.sh`): ECPF0 VFs = **sfnum 1001+N**, ECPF1 = **1257+N** — the udev namers only map those ranges → `pf0vfN_if`. The script now generates 1001+/1257+ and the whole VF path is config-driven (mlnx-sf.conf + sfc.conf `"br-hbn~pf0vfN~pf0vfN_if_r~pf0vfN_if~pf0vfN_if_r"` + hbn.conf) → reboot-persistent. If a box still has stale sfnum 4-11 SFs, delete them (`mlnx-sf --action delete --sfindex …`) and re-run `--vfs`. |
| VFs: `sfc.service` fails, log `Port pf0vfN … ofport` / VF eswitch rep `pf0vfN` missing | `--vfs` requires the **host SR-IOV VFs created first** (they create the `pf0vfN` eswitch reps the BF3 bridges). `bringup_hbn_bf3.sh` now **preflights this**: with `--vfs` it checks the `pf0vfN`/`pf1vfN` reps exist on the BF3 and, if not, fails fast telling you to run `setup_host_vfs_standalone.sh` on the x86 host first (nothing is changed). |
| **`sfc.service` fails on boot**, log `Error: Port: p0_if_r does not have ofport:[] the same as ofport_request:N` → nothing comes up | **Stale `br-hbn` OVS DB** — usually from hand-run `ovs-vsctl add/del-port` whose `ofport_request` persisted across reboot. Fix: `ovs-vsctl --if-exists del-br br-hbn; systemctl reset-failed sfc.service; systemctl start sfc.service` (sfc rebuilds br-hbn clean). **Never manage br-hbn ports by hand** — let `sfc.sh` own them (it uses `--may-exist`). |
| **x86 host shows no BF3 PF netdev** after a BF3 reflash/reboot; `dmesg`: `mlx5_core … wait vital failed (-110) … health recovery failed … disconnect`; `sriov_numvfs` can't be set | The BF3 was reflashed/rebooted **under a running host**, staling the host's PCIe link to the DPU. **Reboot the x86 host** — it re-enumerates PCI, `mlx5_core` re-binds, the PF netdev (`enp195s0f0np0`) reappears, then host VFs work. Always reboot the host after reflashing its BF3. |
