# DPF — DPU Provisioning Framework

NVIDIA DPF Operator v25.10.1 — Kubernetes-native lifecycle management for BlueField-3 DPUs.

---

## What DPF Does

DPF treats each BF3 DPU as a Kubernetes resource. You declare the desired state (which OS image, which cluster, which workloads), and DPF makes it happen — flashing the BFB, rebooting the BF3, joining it to a virtual k8s cluster, and deploying services onto it.

**Key design principle:** the x86 host server does NOT join any Kubernetes cluster. Only the BF3 ARM cores join the DPU cluster.

---

## Lab Topology

```
DPF Operator VM (10.4.5.136)
  ├── k3s cluster (single node)
  ├── DPF Operator v25.10.1
  ├── Kamaji (virtual k8s for DPUs)
  ├── ArgoCD (GitOps for DPU workloads)
  └── bfb-registry (nginx, port 8080 — serves BFB to BMC)

S4 Server
  ├── x86 host   10.20.13.226  (aviz / aviz@123)      — NOT in k8s (BF3 rshim + SR-IOV VFs)
  ├── BF3 OOB    10.20.13.249  (ubuntu / Aviz@AIF12345) — joins DPU cluster
  └── BF3 BMC    10.20.13.250  (root / Aviz@AIF12345)   — Redfish endpoint

SUBNET NOTE: 10.4.5.x and 10.20.13.x are on different subnets.
  ICMP works both ways. TCP is one-way: DPF VM → x86 host (OK), BF3 → DPF VM (BLOCKED).
  See tunnel_dpf.sh for the workaround.
```

---

## Scripts

All scripts run from the **DPF Operator VM** (`10.4.5.136`). No sudo required.

| Script | Purpose |
|---|---|
| `scripts/bringup_dpf.sh` | End-to-end idempotent provisioning |
| `scripts/status_dpf.sh` | Health check — all DPF components |
| `scripts/tunnel_dpf.sh` | SSH tunnel for cross-subnet kubeadm join (per-server presets, Kamaji IP auto-discovery) |
| `scripts/setup_host_vfs.sh` | Run on the **x86 host**: enable SR-IOV VFs + rename to `vf0..vfN` (auto-detects the BF3 PFs; errors if >1 BF3) |
| `scripts/explain_stack.sh` | Generate an educational HTML map of the stack (cluster→node→pod→container→namespace→interface→data plane) with live values |

---

## OS Flash: rshim is Required (not optional)

The BMC on these BF3s has ~200MB of staging storage. The BFB file is ~1.5GB.
**DPF's Redfish OS install path cannot work** — the BMC physically cannot stage the BFB.

DPF still handles everything else:
- Generating the bfcfg (kubeadm join config + systemd services)
- Managing the Kamaji TenantControlPlane
- Deploying DPUServices onto the BF3 after it joins

The OS flash itself must go through the x86 host's PCIe rshim connection using `bfb-install`.

```
DPF role:   bfcfg generation → TenantControlPlane → DPUService deployment
rshim role: OS flash (bfb-install on x86 host via PCIe rshim to BF3)
```

## Upgrading DPF Operator

Use `--upgrade` mode — handles the Helm upgrade plus all post-upgrade manual fixes automatically:

```bash
./dpf/scripts/bringup_dpf.sh --upgrade                    # upgrade to default version
./dpf/scripts/bringup_dpf.sh --upgrade --version v25.10.2 # upgrade to specific version
```

**What `--upgrade` does (post-upgrade fixes required for v25.10.x):**
1. `helm upgrade dpf-operator` to the target version
2. Updates sub-controller deployment images (dpf-provisioning, dpuservice, kamaji-cm, servicechainset) — Helm only updates the main controller; others need manual image update
3. Fixes `servicechainset-controller-manager-credentials` secret — `KUBERNETES_SERVICE_HOST` must be the DPU cluster DNS name (`s4-dpu-cluster.dpf-operator-system.svc`) not the NodePort IP, otherwise the DPU cluster token is rejected by k3s
4. Bootstraps `svc.dpu.nvidia.com` CRDs onto the DPU cluster — needed for servicechainset-controller to start (CRDs normally deployed by a DPUService, but that requires the controller to be running first — chicken-and-egg)
5. Creates ClusterRole + ClusterRoleBinding on DPU cluster for the servicechainset-controller service account

## Quick Start

```bash
# Place BFB file on DPF VM
scp bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb dpu-vm@10.4.5.136:/opt/bfb/

# Place BFB file on x86 host (for rshim flash) — S4 host is 10.20.13.226
scp bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb aviz@10.20.13.226:~/

# Step 0 — confirm the operator is healthy BEFORE provisioning (v25.10.1)
kubectl get dpfoperatorconfig -n dpf-operator-system   # must be Ready=True

# Step 1 — provision (creates the DPUCluster so the tunnel can find the Kamaji IP)
./dpf/scripts/bringup_dpf.sh --server s4 \
  --bmc-ip 10.20.13.250 --oob-ip 10.20.13.249 --serial MT2437600HGY \
  --x86-host 10.20.13.226 --x86-user aviz --x86-pass aviz@123 --rshim-install --hbn

# Step 2 — once s4-dpu-cluster exists, open the cross-subnet tunnel (auto-discovers Kamaji IP)
./dpf/scripts/tunnel_dpf.sh --server s4 start
./dpf/scripts/tunnel_dpf.sh --server s4 bf3    # prints BF3 iptables rules (auto-applied by sfc.service too)

# Step 3 — check
./dpf/scripts/status_dpf.sh

# Step 4 — host SR-IOV VFs (on the x86 host 10.20.13.226)
sudo ./dpf/scripts/setup_host_vfs.sh           # vf0..vf7
```

> See **"v25.10.1 provisioning changes"** and **"BF3 first-boot operational gotchas"** below — a fresh
> BF3 may need a one-time console password, `dhclient oob_net0`, and `systemctl enable --now sfc.service`.

---

## bringup_dpf.sh — Step by Step

```
Step 1   Preflight: kubectl, BMC Redfish, cert-manager, Kamaji, ArgoCD
Step 2   Start python3 HTTP server to serve BFB file (port 9090 → PVC)
Step 3   Clean up stale Kamaji etcd-defrag jobs
Step 4   Create BFB PVC (30Gi local-path storage for BFB + bfcfg)
Step 5   Create DPFOperatorConfig (bootstraps bfb-registry, provisioning controller)
Step 6   Wait for Kamaji + DPF controller + bfb-registry (5 min timeout)
Step 7   Create BFB CR → wait for BFB download into PVC (10 min timeout)
Step 8   Create DPUFlavor (hugepages, OVS raw mode for BF3)
Step 9   Create DPUCluster (Kamaji TenantControlPlane)
Step 10  Create DPUNode + DPUDevice + DPU → triggers Redfish OS flash
Step 10b [--rshim-install only] flash via x86 rshim, wait for BF3 to join
Step 11  Wait for DPU phase: Ready (30 min timeout)
```

Each step checks current state first — safe to re-run at any point.

**Config variables** (top of script — change per environment):

```bash
BF3_BMC_IP="10.20.13.250"    # BMC Redfish endpoint
BF3_OOB_IP="10.20.13.249"    # BF3 OOB management IP
BF3_SERIAL="MT2437600HGY"    # from: dmidecode -t system | grep Serial (on x86 host)
BFB_FILE="/opt/bfb/bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb"
BFB_REGISTRY_IP="10.4.5.136" # this DPF VM
X86_HOST_IP="10.20.13.226"   # S4 x86 host with PCIe rshim to BF3 (pass --x86-host per server)
```

---

## Provisioning Flow

```
1. Apply DPU CR
        │
        ▼
2. DPF downloads BFB → stores in PVC
   bfb-registry (nginx port 8080) serves it to the BMC
        │
        ▼
3. DPF generates bfcfg
   Cloud-init user-data containing:
     - kubeadm join <TenantControlPlane>:6443
     - kubeadm-join.service (runs on first boot)
     - Netplan config for oob_net0
   Stored in PVC at: bfcfg/<namespace>_<dpu>_<uid>
        │
        ▼
4. DPF calls BMC Redfish API → flashes BFB
   POST /redfish/v1/UpdateService/update-multipart
   BMC stages BFB, then InitiateFirmwareUpdate
   BF3 reboots; BMC firmware + NIC firmware + Ubuntu OS all updated
        │
        ▼
5. BF3 boots into new Ubuntu
   cloud-init processes bfcfg
   kubeadm-join.service runs on first boot
        │
        ▼
6. BF3 kubelet joins TenantControlPlane
   kubeadm join 10.4.5.136:6443 --token ...
   DPF sees node → marks DPU phase: Ready
        │
        ▼
7. ArgoCD deploys DPUServices onto BF3
   (HBN, OVS, servicechainset, etc.)
```

---

## Kubernetes Resources (Manifests)

| File | Resource | Purpose |
|---|---|---|
| `01-bfb-pvc.yaml` | PersistentVolumeClaim | 30Gi storage for BFB + bfcfg |
| `02-dpfoperatorconfig.yaml` | DPFOperatorConfig | Bootstrap: bfb-registry, Redfish mode |
| `03-bfb.yaml` | BFB | OS image reference (URL → download into PVC) |
| `04-dpuflavor.yaml` | DPUFlavor | BF3 hardware config (hugepages, OVS) |
| `05-dpunode.yaml` | DPUNode | Represents the x86 host server |
| `06-dpudevice.yaml` | DPUDevice | Physical BF3 (serial + BMC IP) |
| `07-dpu.yaml` | DPU | Ties everything together, triggers flash |
| `08-dpucluster.yaml` | DPUCluster | Kamaji TenantControlPlane definition |

---

## Kamaji — Virtual k8s Control Planes

Without Kamaji, each BF3 would need a dedicated k8s control plane VM. Kamaji runs multiple
virtual control planes as pods inside the single k3s cluster — each BF3 gets its own
TenantControlPlane (etcd + apiserver + controller-manager) without extra VMs.

```
k3s cluster on DPF VM
  ├── s4-dpu-cluster pods  (etcd ×3, apiserver, controller-manager)
  └── s5-dpu-cluster pods  (etcd ×3, apiserver, controller-manager) ← future
```

Get the DPU cluster kubeconfig:
```bash
kubectl get secret s4-dpu-cluster-admin-kubeconfig -n dpf-operator-system \
  -o jsonpath='{.data.admin\.conf}' | base64 -d > /tmp/dpu-kubeconfig
kubectl get nodes --kubeconfig /tmp/dpu-kubeconfig
```

---

## Known Issues and Workarounds

### 1. DPU phase Error / FailToInstall / 404

**Symptom:** `DPU phase: Error`, condition `OSInstalled: False`, reason `FailToInstall`, message `404 Not Found`

**Cause:** The BMC storage (~200MB) cannot stage the BFB (~1.5GB). Redfish OS install
cannot work on this hardware. DPF reports Error when it polls the Redfish task and gets 404.
This is expected — always use `--rshim-install`.

**Fix — use rshim path:**
```bash
./dpf/scripts/bringup_dpf.sh --rshim-install
```

**Fix — if BF3 already joined and only DPU CR needs updating:**
```bash
kubectl patch dpu s4-dpu -n dpf-operator-system --subresource=status --type=merge \
  -p '{"status":{"phase":"Ready"}}'
```

### 2. Cross-subnet TCP block (BF3 → DPF VM)

**Symptom:** `kubeadm join` fails with `dial tcp 10.4.5.136:6443: connect: no route to host`

**Cause:** Lab firewall blocks TCP from 10.20.13.x to 10.4.5.x. ICMP works, TCP doesn't.

**Fix:** SSH reverse tunnel + BF3 iptables DNAT. See `tunnel_dpf.sh` for full details.

```bash
# On DPF VM
./dpf/scripts/tunnel_dpf.sh start
./dpf/scripts/tunnel_dpf.sh bf3   # prints commands to run on BF3
```

### 3. NodePort 6443 conflicts with k3s API server

**Symptom:** Kamaji TenantControlPlane NodePort 6443 has no iptables PREROUTING DNAT rule.
External traffic hitting 10.4.5.136:6443 goes to k3s, not Kamaji.

**Cause:** k3s-server occupies port 6443, preventing kube-proxy from creating the NodePort
DNAT rule. This is why the SSH tunnel is required — it bypasses the NodePort entirely
by routing directly to the Kamaji ClusterIP (10.43.62.50:6443) from inside the cluster.

### 4. Bootstrap token expiry

The bfcfg generated by DPF contains a kubeadm bootstrap token with a 24h TTL.
`bringup_dpf.sh --rshim-install` automatically creates a fresh token before each flash.
If running kubeadm join manually after 24h, create a new token:

```bash
# Get DPU cluster kubeconfig
kubectl get secret s4-dpu-cluster-admin-kubeconfig -n dpf-operator-system \
  -o jsonpath='{.data.admin\.conf}' | base64 -d > /tmp/dpu-tc-kubeconfig

# Create fresh token
TOKEN_ID=$(openssl rand -hex 3); TOKEN_SECRET=$(openssl rand -hex 8)
kubectl --kubeconfig /tmp/dpu-tc-kubeconfig create secret generic \
  "bootstrap-token-${TOKEN_ID}" -n kube-system \
  --type bootstrap.kubernetes.io/token \
  --from-literal="token-id=${TOKEN_ID}" \
  --from-literal="token-secret=${TOKEN_SECRET}" \
  --from-literal=usage-bootstrap-authentication=true \
  --from-literal=usage-bootstrap-signing=true \
  --from-literal='auth-extra-groups=system:bootstrappers:kubeadm:default-node-token'

echo "New token: ${TOKEN_ID}.${TOKEN_SECRET}"
# Update /opt/dpf/join_k8s_cluster.sh on BF3 with new token
```

---

## v25.10.1 provisioning changes (validated on S4, 2026-06)

The v25.7.0 → v25.10.1 upgrade changed the provisioning flow in several breaking ways.
`bringup_dpf.sh` and the manifests now handle all of these automatically — documented here so
the behavior is understood and recognizable.

### 5. Operator must be fully Ready, or clusters stall at `Pending`
**Symptom:** new `DPUCluster` stuck `phase: Pending`; cluster-manager logs `skip Pending cluster`;
no TenantControlPlane is ever created.
**Cause:** a half-finished operator upgrade (e.g. `servicechainset` CrashLoopBackOff, sub-controllers
still tagged v25.7.0) leaves `DPFOperatorConfig` `Ready=False` (`PreUpgradeValidationReady`/
`SystemComponentsReady` failing). While not Ready, the cluster-manager defers all new clusters.
**Fix:** finish the upgrade (`bringup_dpf.sh --upgrade`) or, if wedged, do a **clean operator reinstall**
(`helm uninstall dpf-operator` + delete `DPFOperatorConfig` and DPF CRs with finalizers stripped, then
re-run `bringup_dpf.sh` — Step 1 reinstalls a fresh v25.10.1 operator). Always confirm
`kubectl get dpfoperatorconfig -n dpf-operator-system` shows `Ready=True` before provisioning.

### 6. DPUNode needs `nodeRebootMethod: external` (else controller panics)
**Symptom:** DPU stuck `phase: Initializing`, reason `DPUInstallInterfaceNotProvided`; provisioning
controller logs a nil-pointer **panic** in `HandleRebootSync` for the DPUNode.
**Cause:** v25.10.1 defaults `nodeRebootMethod` to `hostAgent`, which assumes an in-cluster host agent.
OOB setups (x86 host NOT in k8s) have none → panic → DPU never initializes.
**Fix (in `05-dpunode.yaml`):**
```yaml
spec:
  nodeRebootMethod:
    external: {}
```

### 7. DPUNode must list its DPUDevice (`spec.dpus`)
**Symptom:** DPU stuck `Initialize Interface`, reason `DPUDeviceNotReady`; DPUDevice condition
`NodeAttached=False` ("No DPUNode found").
**Cause:** v25.10.1 requires the DPUNode to reference its attached device(s).
**Fix (in `05-dpunode.yaml`):**
```yaml
spec:
  dpus:
    - name: SERVER_NAME-bf3
```

### 8. Per-server DPUFlavor name (multi-DPU collision)
**Symptom:** `DPUFlavor is being referred to by DPU(s) [...], you must delete the DPU(s) first`.
**Cause:** an immutable `DPUFlavor` shared across DPUs can't be recreated without deleting the other DPU.
**Fix:** `bringup_dpf.sh` names the flavor per server (`<server>-bf3-hbn`) so each DPU is independent.

### 9. bfcfg URL double `/bfb/` (404 on rshim deploy)
**Symptom:** `Failed to deploy bfcfg — .../bfb//bfb/bfcfg/...` (404).
**Cause:** v25.10.1 reports `status.bfCFGFile` as an absolute path (`/bfb/bfcfg/...`); the old script
prepended `/bfb/` again. `bringup_dpf.sh` now normalizes the path.

### 10. Stale ArgoCD cluster secret after a DPUCluster recreate → no CNI
**Symptom:** DPUService Applications `Sync: Unknown`; flannel/multus never deploy to the DPU cluster;
pods stuck `ContainerCreating` with `plugin type="loopback" failed (add): missing network name`.
**Cause:** deleting+recreating a `DPUCluster` gives Kamaji a new CA/cert/key, but the ArgoCD cluster
secret (`<server>-dpu-cluster` in `argocd`) still holds the old creds → ArgoCD can't reach the cluster.
**Fix:** `bringup_dpf.sh` Step 9b now **always refreshes** that secret (was skip-if-exists). Manual:
delete the secret and re-run, or rebuild it from the fresh `*-dpu-cluster-admin-kubeconfig`.

### 11. BF3 first-boot operational gotchas (hands-on, not script bugs)
After a fresh flash the BF3 may need three one-time things on first boot:
1. **First-login password prompt** on the console — the BF3 sits at it and looks "hung" (OOB SSH
   refused, BMC `BootProgress=OEM`, console quiet). It isn't hung — set the password (default
   `ubuntu`/`Aviz@AIF12345`) on the BMC ARM console.
2. **`oob_net0` has no IP** — first boot can leave it down. On the BF3: `sudo dhclient oob_net0`.
3. **`sfc.service` ships disabled** — it must run to apply the tunnel iptables + wire `br-hbn`.
   On the BF3: `sudo systemctl enable --now sfc.service`, then `sudo systemctl restart kubeadm-join.service`.
   (Also: the reflash changes the BF3 SSH host key — clear it: `ssh-keygen -R 10.20.13.249`.)

---

## Host SR-IOV VFs (after HBN is up)

Run on the **x86 host** (not the BF3), after the BF3 is flashed with `NUM_OF_VFS` set:
```bash
sudo ./dpf/scripts/setup_host_vfs.sh            # auto-detect BF3 PFs → vf0..vf7
sudo ./dpf/scripts/setup_host_vfs.sh --persist  # survive reboot (systemd oneshot)
```
Auto-detects the BlueField-3 PFs by PCI device id `0xa2dc` (ignores standalone ConnectX-7), and
**refuses to run if more than one BF3 is present** (avoids ambiguous VF naming).

---

## Team Handoff: Provisioning a New BF3

### Server Reference Table

| Server | BF3 OOB (ARM) | BF3 BMC | x86 Host | Notes |
|---|---|---|---|---|
| S1 | `10.20.13.247` ubuntu/Aviz@AIF12345 | `10.20.13.216` root/Aviz@AIF12345 | `10.20.13.13` admin/Aviz@AIF123 | — |
| S2 | `10.20.13.228` ubuntu/Aviz@AIF12345 | `10.20.13.212` root/Aviz@AIF12345 | `10.20.13.12` admin/Aviz@AIF123 | — |
| S4 | `10.20.13.249` ubuntu/Aviz@AIF12345 | `10.20.13.250` root/Aviz@AIF12345 | `10.20.13.226` aviz/aviz@123 | provisioned via DPF + HBN (DPU Ready) |

### Prerequisites (do once per session)

1. **SSH to the DPF Operator VM** — all scripts must run from there:
   ```bash
   ssh dpu-vm@10.4.5.136   # password: admin
   cd ~/hbn
   ```

2. **BFB on DPF VM:**
   ```bash
   ls /opt/bfb/bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb
   ```

3. **BFB on the x86 host** (needed for rshim flash):
   ```bash
   # From DPF VM
   scp /opt/bfb/bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb <x86-user>@<x86-ip>:~/
   ```

4. **Start the SSH tunnel** (required — BF3 can't reach DPF VM directly over TCP):
   ```bash
   ./dpf/scripts/tunnel_dpf.sh start
   ./dpf/scripts/tunnel_dpf.sh status   # verify it's up
   ```

5. **Get the BF3 serial number:**
   ```bash
   ssh ubuntu@<BF3-OOB-IP> 'sudo dmidecode -t system | grep Serial'
   # or from x86 host if BF3 not yet accessible:
   ssh <x86-user>@<x86-host> 'sudo dmidecode -t system | grep -A2 "System Information" | grep Serial'
   ```

### Run the Provisioning

```bash
# Generic form
./dpf/scripts/bringup_dpf.sh \
  --server <s1|s2|s3> \
  --bmc-ip <BF3-BMC-IP> \
  --oob-ip <BF3-OOB-IP> \
  --serial <BF3-SERIAL> \
  --x86-host <X86-HOST-IP> \
  --x86-user <X86-USER> \
  --x86-pass <X86-PASS> \
  --rshim-install --hbn
```

**S1 example:**
```bash
./dpf/scripts/bringup_dpf.sh \
  --server s1 \
  --bmc-ip 10.20.13.216 --oob-ip 10.20.13.247 \
  --serial <SN> \
  --x86-host 10.20.13.13 --x86-user admin --x86-pass 'Aviz@AIF123' \
  --rshim-install --hbn
```

**S2 example:**
```bash
./dpf/scripts/bringup_dpf.sh \
  --server s2 \
  --bmc-ip 10.20.13.212 --oob-ip 10.20.13.228 \
  --serial <SN> \
  --x86-host 10.20.13.12 --x86-user admin --x86-pass 'Aviz@AIF123' \
  --rshim-install --hbn
```

> **Note:** `--x86-pass` is for the x86 host SSH login. The script also needs to sudo on that host — if sudo requires a password, pass the same password. For passwordless-sudo hosts, omit `--x86-pass`.

### Expected Timeline

| Phase | Duration | What's happening |
|---|---|---|
| Steps 1–9 | ~2 min | DPF resources created, BFB already in PVC |
| BFB flash via rshim | 10–20 min | `bfb-install` writes ~1.5GB over PCIe rshim |
| BF3 first boot | ~5 min | cloud-init runs, sets hugepages, starts services |
| kubeadm join | ~2 min | BF3 joins TenantControlPlane via SSH tunnel |
| DPUServices deploy | ~5 min | HBN pod pulls and starts |
| **Total** | **~25–40 min** | |

### Success Verification

```bash
# 1. DPU phase should be Ready
./dpf/scripts/status_dpf.sh

# 2. BF3 node in TenantControlPlane
kubectl get secret s1-dpu-cluster-admin-kubeconfig -n dpf-operator-system \
  -o jsonpath='{.data.admin\.conf}' | base64 -d > /tmp/dpu-kc
kubectl get nodes --kubeconfig /tmp/dpu-kc

# 3. doca-hbn pod Running 1/1 on BF3
kubectl get pods --kubeconfig /tmp/dpu-kc -A | grep hbn

# 4. FRR interfaces inside doca-hbn
CONT=$(ssh ubuntu@<BF3-OOB> 'sudo crictl ps | grep doca-hbn | grep -v init | awk "{print \$1}"')
ssh ubuntu@<BF3-OOB> "sudo crictl exec $CONT vtysh -c 'show interface brief'"
# All 12 interfaces (p0_if, p1_if, pf0hpf_if, pf1hpf_if, pf0vf0-3_if, pf1vf0-3_if) must be UP.
```

### Known First-Boot Issue: Hugepages Not Allocated

On a **brand-new BF3** (first flash ever), hugepages may not be available immediately after boot because cloud-init writes the GRUB config on the first boot — the kernel doesn't see the hugepages parameter until the *second* boot. The script handles this automatically by pre-allocating via `/proc/sys/vm/compact_memory`, but if doca-hbn fails to start with `DPDK: Not enough memory`, do:

```bash
ssh ubuntu@<BF3-OOB>
echo 1 | sudo tee /proc/sys/vm/compact_memory
echo 3072 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
sudo systemctl restart ovs-vswitchd ovs-config
# wait ~60s, then check if the pod came up
sudo crictl ps | grep doca-hbn
```

### Known Issue: "sudo: unable to resolve host s4-dpu"

Cosmetic noise in logs — add hostname to `/etc/hosts`:
```bash
ssh ubuntu@<BF3-OOB> 'echo "127.0.0.1 $(hostname)" | sudo tee -a /etc/hosts'
```

---

## Replicating to Other Servers

The `--server` flag sets the prefix for all Kubernetes resource names (`s1-dpu`, `s1-node`, `s1-bf3`, `s1-dpu-cluster`). Multiple servers can coexist in the same DPF Operator instance — each gets its own TenantControlPlane (Kamaji virtual cluster).

Minimum info needed per server:

| Flag | How to get it |
|---|---|
| `--bmc-ip` | Server topology table above |
| `--oob-ip` | Server topology table above |
| `--serial` | `ssh ubuntu@<BF3-OOB> 'sudo dmidecode -t system \| grep Serial'` |
| `--x86-host` | x86 host with PCIe connection to that BF3 |
| `--x86-user` | SSH user on x86 host |
| `--x86-pass` | SSH password on x86 host |

The DPUFlavor sfc.sh automatically gets the correct `X86_HOST_IP` and DPF VM IP substituted from these flags — no manual YAML editing needed.

---

## S4 Current State

| Component | State |
|---|---|
| DPF Operator | Running (v25.10.1) |
| Kamaji etcd | Running (3 replicas) |
| BFB | Ready (doca-3.3.0, bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k) |
| DPUCluster | Ready (s4-dpu-cluster, Kamaji, 1 node) |
| DPU | Ready (s4-dpu, MT2437600HGY) |
| BF3 kubelet | Active (v1.34.4, joined TenantControlPlane) |
| Flash method | rshim (Redfish skipped — same version already installed) |
| Tunnel | Required for kubeadm join (cross-subnet TCP block) |
