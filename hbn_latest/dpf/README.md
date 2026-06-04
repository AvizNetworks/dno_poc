# DPF — DPU Provisioning Framework

NVIDIA DPF Operator v25.7.0 — Kubernetes-native lifecycle management for BlueField-3 DPUs.

---

## What DPF Does

DPF treats each BF3 DPU as a Kubernetes resource. You declare the desired state (which OS image, which cluster, which workloads), and DPF makes it happen — flashing the BFB, rebooting the BF3, joining it to a virtual k8s cluster, and deploying services onto it.

**Key design principle:** the x86 host server does NOT join any Kubernetes cluster. Only the BF3 ARM cores join the DPU cluster.

---

## Lab Topology

```
DPF Operator VM (10.4.5.136)
  ├── k3s cluster (single node)
  ├── DPF Operator v25.7.0
  ├── Kamaji (virtual k8s for DPUs)
  ├── ArgoCD (GitOps for DPU workloads)
  └── bfb-registry (nginx, port 8080 — serves BFB to BMC)

S4 Server
  ├── x86 host   10.20.13.207  (aviz / aviz@123)      — NOT in k8s
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
| `scripts/tunnel_dpf.sh` | SSH tunnel for cross-subnet kubeadm join |

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

## Quick Start

```bash
# Place BFB file on DPF VM
scp bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb dpu-vm@10.4.5.136:/opt/bfb/

# Place BFB file on x86 host (for rshim flash)
scp bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb aviz@10.20.13.207:~/

# Step 1 — set up SSH tunnel (needed: DPF VM on 10.4.5.x, BF3 on 10.20.13.x)
./dpf/scripts/tunnel_dpf.sh start

# Step 2 — run BF3-side iptables rule (print and paste into BF3 terminal)
./dpf/scripts/tunnel_dpf.sh bf3

# Step 3 — provision
./dpf/scripts/bringup_dpf.sh --rshim-install

# Step 4 — check
./dpf/scripts/status_dpf.sh
```

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
X86_HOST_IP="10.20.13.207"   # x86 host with PCIe rshim to BF3 (for --rshim-install)
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

## Replicating to Other Servers

To provision a new BF3 on S1, S2, etc.:

1. Update the config variables at the top of `bringup_dpf.sh`
2. Update manifest resource names (`s4-` prefix → `s1-` etc.) or add `--server` flag (future work)
3. If DPF VM is on a different subnet than the BF3, run `tunnel_dpf.sh start` first

Minimum info needed per server:

| Variable | How to get it |
|---|---|
| `BF3_BMC_IP` | From lab topology table in CLAUDE.md |
| `BF3_OOB_IP` | From lab topology table in CLAUDE.md |
| `BF3_SERIAL` | `ssh ubuntu@<BF3-OOB> 'sudo dmidecode -t system \| grep Serial'` |
| `X86_HOST_IP` | x86 host with PCIe connection to that BF3 |

---

## S4 Current State

| Component | State |
|---|---|
| DPF Operator | Running (v25.7.0) |
| Kamaji etcd | Running (3 replicas) |
| BFB | Ready (doca-3.3.0, bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k) |
| DPUCluster | Ready (s4-dpu-cluster, Kamaji, 1 node) |
| DPU | Ready (s4-dpu, MT2437600HGY) |
| BF3 kubelet | Active (v1.34.4, joined TenantControlPlane) |
| Flash method | rshim (Redfish skipped — same version already installed) |
| Tunnel | Required for kubeadm join (cross-subnet TCP block) |
