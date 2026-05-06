# BF3 HBN Bring-Up Runbook

Validated on: BlueField-3, DOCA 3.3.0 / doca_hbn:3.3.0-doca3.3.0

---

## Current Topology

This system has a single BF3 DPU with 2 physical ports. The BF3 ARM runs
OVS-DPDK (DOCA mode) as the HBN dataplane, with the doca-hbn container
running FRR for routing and BFD.

```
                        ┌─────────────────────────────────────────────────┐
    NETWORK / TOR       │              BF3 DPU (ARM OS)                  │
                        │                                                 │
   Port 0 ─────────────►│ p0  (dpdk)   MAC: 5c:25:73:79:c8:8a            │
                        │   ↕ p0_if_r  MAC: 5c:25:73:79:c8:9c (sfnum 2) │
   Port 1 ─────────────►│ p1  (dpdk)   MAC: 5c:25:73:79:c8:8b            │
                        │   ↕ p1_if_r  MAC: 5c:25:73:79:c8:9d (sfnum 3) │
                        │                                                 │
                        │  ┌──────────────────────────────────────────┐  │
                        │  │           br-hbn  (OVS-DPDK)             │  │
                        │  │   fail_mode=secure  datapath=netdev       │  │
                        │  │                                           │  │
                        │  │   vxlan0  (remote_ip=flow, tos=inherit)  │  │
                        │  └──────────────────────────────────────────┘  │
                        │                                                 │
                        │ pf0hpf (dpdk)  MAC: 5c:25:73:79:c8:8c c1pf0   │
                        │   ↕ pf0hpf_if_r MAC: 00:04:4b:44:cb:f0 (1514) │
                        │ pf1hpf (dpdk)  MAC: 5c:25:73:79:c8:8d c1pf1   │
                        │   ↕ pf1hpf_if_r MAC: 00:04:4b:9f:5f:f1 (1515) │
                        │                                                 │
                        │  ┌──────────────────────────────────────────┐  │
                        │  │        doca-hbn container (k8s pod)       │  │
                        │  │                                           │  │
                        │  │  p0_if     ─ SF data netdev for p0       │  │
                        │  │  p1_if     ─ SF data netdev for p1       │  │
                        │  │  pf0hpf_if ─ SF data netdev for pf0hpf  │  │
                        │  │  pf1hpf_if ─ SF data netdev for pf1hpf  │  │
                        │  │                                           │  │
                        │  │  FRR: zebra  staticd  bfdd  (bgpd off)  │  │
                        │  └──────────────────────────────────────────┘  │
                        │                          │                      │
                        └──────────────────────────┼──────────────────────┘
                                                   │ PCIe
                                          ┌────────┴────────┐
                                          │   HOST (x86)    │
                                          │  NIC 0   NIC 1  │
                                          └─────────────────┘
```

### Port → SF → Representor Mapping

| OVS DPDK Port | Role | SF netdev (container) | Representor (host) | sfnum | MAC |
|---------------|------|-----------------------|-------------------|-------|-----|
| `p0` | Physical uplink 0 | `p0_if` | `p0_if_r` | 2 | `5c:25:73:79:c8:9c` |
| `p1` | Physical uplink 1 | `p1_if` | `p1_if_r` | 3 | `5c:25:73:79:c8:9d` |
| `pf0hpf` | Host PF0 proxy | `pf0hpf_if` | `pf0hpf_if_r` | 1514 | `00:04:4b:44:cb:f0` |
| `pf1hpf` | Host PF1 proxy | `pf1hpf_if` | `pf1hpf_if_r` | 1515 | `00:04:4b:9f:5f:f1` |

### Link Propagation
Link state is propagated between DPDK port and its representor:
```
p0      ↔  p0_if_r
p1      ↔  p1_if_r
pf0hpf  ↔  pf0hpf_if_r
pf1hpf  ↔  pf1hpf_if_r
```

---

## Configuration Files Reference

### `/etc/mellanox/hbn.conf`
Primary HBN configuration. Defines which ports belong to which bridge,
which profile to use, and link propagation pairs.

```ini
[hbn_profile]
profile_name = default          # maps to resources_profiles.yaml → default

[BR_HBN_UPLINKS]
p0                              # physical uplink ports added to br-hbn (DPDK)
p1

[BR_HBN_REPS]
pf0hpf                          # host-facing proxy ports added to br-hbn (DPDK)
pf1hpf

[BR_HBN_SFS]
                                # empty — SFs provisioned separately via mlnx-sf.conf

[BR_SFC_UPLINKS]
                                # empty — no SFC bridge
[BR_SFC_REPS]
[BR_SFC_SFS]
[BR_HBN_SFC_PATCH_PORTS]

[LINK_PROPAGATION]              # OVS link-state propagation pairs
p0:p0_if_r
p1:p1_if_r
pf0hpf:pf0hpf_if_r
pf1hpf:pf1hpf_if_r

[ENABLE_BR_SFC]                 # empty — br-sfc disabled
[ENABLE_BR_SFC_DEFAULT_FLOWS]
[ENABLE_VETH]                   # empty — using SF path, not veth path
```

---

### `/etc/mellanox/sfc.conf`
Runtime configuration sourced by `sfc.sh` and the `init-sfs` init container.
Defines OVS port mappings used to wire up the bridge.

```bash
BR_HBN_NAME=br-hbn

# Format: bridge~dpdk_port~ovs_rep_port~sf_netdev~of_port
MAPPINGS=(
"br-hbn~p0~p0_if_r~p0_if~p0_if_r"
"br-hbn~p1~p1_if_r~p1_if~p1_if_r"
"br-hbn~pf0hpf~pf0hpf_if_r~pf0hpf_if~pf0hpf_if_r"
"br-hbn~pf1hpf~pf1hpf_if_r~pf1hpf_if~pf1hpf_if_r"
)
```

Fields per entry:
1. Bridge name (`br-hbn`)
2. DPDK port in OVS (`p0`)
3. Representor port in OVS (`p0_if_r`) — also used for TC offload
4. SF data netdev moved into doca-hbn container (`p0_if`)
5. OpenFlow port identifier (`p0_if_r`)

---

### `/etc/mellanox/mlnx-sf.conf`
Commands to create the 4 internal SFs required by HBN. These are run at
boot by `mlnx_interface_mgr` (or manually if that service doesn't fire).

```bash
# sfnum 2  → p0_if_r (representor), p0_if (data netdev)
/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum 2    --hwaddr 5c:25:73:79:c8:9c -t --cpu-list 0-2

# sfnum 1514 → pf0hpf_if_r (representor), pf0hpf_if (data netdev)
/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum 1514 --hwaddr 00:04:4b:44:cb:f0 -t --cpu-list 0-2

# sfnum 3  → p1_if_r (representor), p1_if (data netdev)
/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum 3    --hwaddr 5c:25:73:79:c8:9d -t --cpu-list 0-2

# sfnum 1515 → pf1hpf_if_r (representor), pf1hpf_if (data netdev)
/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum 1515 --hwaddr 00:04:4b:9f:5f:f1 -t --cpu-list 0-2
```

All SFs are on PCI device `0000:03:00.0` (PF0). The `-t` flag sets trusted
mode. `--cpu-list 0-2` pins the SF to ARM cores 0-2.

After creation, udev fires `/opt/mellanox/sfc-hbn/sf-rep-netdev-rename`
which maps sfnum → name:
```
sfnum 2    → p0_if_r
sfnum 3    → p1_if_r
sfnum 1514 → pf0hpf_if_r
sfnum 1515 → pf1hpf_if_r
```
The SF data netdevs (`p0_if`, etc.) are renamed by `systemd-networkd`.

---

### `/etc/mellanox/mlnx-ovs.conf`
OVS global settings applied by `mlnx_bf_configure`.

```bash
CREATE_OVS_BRIDGES="no"        # bridges managed by sfc.sh, not auto-created
OVS_HW_OFFLOAD="yes"           # enable TC flower hardware offload
OVS_START_TIMEOUT=30
OVS_TIMEOUT=300
OVS_BR_PORTS_TIMEOUT=30
OVS_DOCA="yes"                 # use OVS-DOCA (DPDK-based) instead of kernel OVS
OVS_DEFAULT_HUGEPAGE_SIZE=2048
OVS_DEFAULT_HUGEPAGE_NUM=512
```

---

### `/etc/mellanox/mlnx-bf.conf`
BlueField-specific hardware settings.

```bash
IPSEC_FULL_OFFLOAD="no"        # IPsec full offload disabled
ENABLE_ESWITCH_MULTIPORT="yes" # allow e-switch to span both PF0 and PF1
```

---

### `/etc/mellanox/sfc-ovs.conf`
Optional OVS tuning applied by `sfc.sh`. Currently all defaults (commented out).

```bash
# hw_offload=true
# hw_offload_ct_size=64000
# max_idle=60000
# flow_limit=500000
```

---

### `/etc/mellanox/hugepages.d/hbn (ovs-doca).json`
Hugepage allocation for the OVS-DOCA dataplane. Managed by `hbn_profile_apply.py`.

```json
{
  "2048": {
    "num": 1600,
    "is_active": "active"
  }
}
```
1600 × 2MB hugepages = 3.2GB reserved for OVS-DOCA.

---

### `/etc/mellanox/hbn_profiles/resources_profiles.yaml`
Available resource profiles selectable in `hbn.conf → profile_name`.

```yaml
profiles:
  default:
    hbn_cpu: "2"          # ARM cores for HBN container
    hbn_memory: "3Gi"
    ovs_cpu: "1"          # ARM cores for OVS PMD
    huge_pages_size: "2048"
    huge_pages_count: "1600"

  rp_4k_16k:             # small scale: 4k MACs, 16k routes
    hbn_cpu: "2"
    hbn_memory: "3Gi"
    ovs_cpu: "1"
    huge_pages_size: "2048"
    huge_pages_count: "1600"

  rp_8k_80k:             # medium scale: 8k MACs, 80k routes
    hbn_cpu: "2"
    hbn_memory: "5Gi"
    ovs_cpu: "1"
    huge_pages_size: "2048"
    huge_pages_count: "2000"

  rp_16k_128k:           # large scale: 16k MACs, 128k routes
    hbn_cpu: "4"
    hbn_memory: "7Gi"
    ovs_cpu: "1"
    huge_pages_size: "2048"
    huge_pages_count: "3000"
```

---

### `/etc/mellanox/hbn_profiles/flexible_profile.yaml`
Custom profile used when `profile_name = flexible_profile` in `hbn.conf`.

```yaml
flexible:
  hbn_cpu: "1"
  hbn_memory: "3Gi"
  ovs_cpu: "1"
  huge_pages_size: "2048"
  huge_pages_count: "1600"
```

---

## Automated Bringup

The `bringup_hbn_bf3.sh` script handles everything below automatically and is
idempotent — safe to re-run at any step.

```bash
# Prerequisites: clone the repo to the BF3 so mellanox/ directory is present
sudo ./bringup_hbn_bf3.sh
sudo ./bringup_hbn_bf3.sh --enable-bgp --hbn-scripts-dir ~/hbn-scripts
```

Before running on a **brand-new BF3**, ensure `mellanox/doca_hbn.yaml` exists in
the repo (copy from a working BF3):
```bash
scp ubuntu@<working-bf3>:/etc/kubelet.d/doca_hbn.yaml mellanox/
```

The script deploys all config files from `mellanox/`, allocates hugepages,
validates SFs and OVS ports, then waits for the pod and brings up interfaces.
The manual steps below document what the script does and are useful for
debugging individual failures.

---

## Manual Bring-Up Steps

All commands run on the **BF3 ARM OS** unless stated otherwise.

---

### Step 1 — Verify E-Switch is in Switchdev Mode

```bash
sudo devlink dev eswitch show pci/0000:03:00.0
sudo devlink dev eswitch show pci/0000:03:00.1
```

Expected: `mode switchdev inline-mode none encap-mode basic`

If not:
```bash
sudo devlink dev eswitch set pci/0000:03:00.0 mode switchdev
sudo devlink dev eswitch set pci/0000:03:00.1 mode switchdev
```

---

### Step 2 — Fix DNS (if BF3 cannot resolve hostnames)

```bash
ping 8.8.8.8       # connectivity OK
nslookup nvcr.io   # may fail
```

Quick fix:
```bash
echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf
```

Permanent fix: configure in `/etc/systemd/resolved.conf` or netplan.

---

### Step 3 — Install Required Packages

```bash
sudo apt install apparmor-utils -y
```

Without this the `init-sfs` container fails:
```
nsenter: failed to execute aa-complain: No such file or directory
Error: HBN initial config for DPF/SFC failed.
```

---

### Step 4 — Create Required Host Directories

The `doca-hbn-service` pod declares all these as hostPath volumes. Kubelet
will not start the pod if any are missing.

```bash
sudo mkdir -p \
  /var/lib/hbn/etc/nvue.d \
  /var/lib/hbn/etc/frr \
  /var/lib/hbn/etc/network \
  /var/lib/hbn/etc/cumulus \
  /var/lib/hbn/etc/hbn-users \
  /var/lib/hbn/etc/supervisor/conf.d \
  /var/lib/hbn/var/lib/nvue \
  /var/lib/hbn/var/support \
  /var/log/doca/hbn
```

---

### Step 5 — Deploy Reference Config Files

On a fresh BF3, `install.sh` generates `hbn.conf` with 14 VF interfaces and
`sfc.conf` with 14 VF port mappings. `init-sfs` reads `hbn.conf` to know which
interfaces to wait for — with the VF version it loops forever. Replace both
from the repo's `mellanox/` directory.

```bash
# hbn.conf — detect VF entries (pf0vf0 etc.) and replace
grep "pf0vf0" /etc/mellanox/hbn.conf && \
  sudo cp mellanox/hbn.conf /etc/mellanox/hbn.conf

# sfc.conf — same check for VF MAPPINGS
grep "pf0vf" /etc/mellanox/sfc.conf && \
  sudo cp mellanox/sfc.conf /etc/mellanox/sfc.conf

# mlnx-sf.conf — check for physical port MAC assigned as SF MAC
# Physical port MAC conflict causes mlx5_core to skip function netdev creation
# (p0_if_r etc. never appear). Replace if install.sh used physical MACs.
P0_MAC=$(cat /sys/class/net/$(grep -rl "^p0$" /sys/class/net/*/phys_port_name 2>/dev/null | head -1 | cut -d/ -f5)/address)
grep -qi "$P0_MAC" /etc/mellanox/mlnx-sf.conf && \
  sudo cp mellanox/mlnx-sf.conf /etc/mellanox/mlnx-sf.conf

# doca_hbn.yaml — hbn-runtime package does NOT install this; kubelet needs it
# Copy from working BF3 if not already present:
#   scp ubuntu@<working-bf3>:/etc/kubelet.d/doca_hbn.yaml mellanox/
sudo cp mellanox/doca_hbn.yaml /etc/kubelet.d/doca_hbn.yaml
```

---

### Step 6 — Allocate Hugepages

OVS-DPDK needs 1600×2MB hugepages. A fresh BF3 has 0. Without this, OVS
creates `br-hbn` but immediately logs `creating tap device failed: Invalid
argument` and the DPDK ports never come up.

```bash
# Allocate (takes effect immediately, lost on reboot without the service below)
echo 1600 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
sudo mkdir -p /mnt/huge_2mb
sudo mount -t hugetlbfs -o pagesize=2M none /mnt/huge_2mb
sudo ovs-vsctl set Open_vSwitch . other_config:dpdk-hugepage-dir=/mnt/huge_2mb

# Verify
cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages   # expect 1600

# Persistent service (Before=openvswitch-switch.service)
sudo tee /etc/systemd/system/mlnx-hugepages-2mb.service > /dev/null <<'EOF'
[Unit]
Description=Allocate 2MB hugepages for OVS-DPDK
DefaultDependencies=no
Before=openvswitch-switch.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'echo 1600 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages && mkdir -p /mnt/huge_2mb && mountpoint -q /mnt/huge_2mb || mount -t hugetlbfs -o pagesize=2M none /mnt/huge_2mb'

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable mlnx-hugepages-2mb.service
```

If OVS already started with 0 hugepages (stale `br-hbn`):
```bash
sudo ovs-vsctl del-br br-hbn
sudo systemctl restart openvswitch-switch
sudo systemctl restart sfc.service
```

---

### Step 7 — Run HBN Profile Service

Configures hugepages and OVS PMD CPU settings based on `/etc/mellanox/hbn.conf`.

```bash
sudo systemctl restart hbn-profile.service
journalctl -u hbn-profile.service --no-pager | tail -5
```

Expected: `HBN profile 'default' applied successfully`

---

### Step 8 — Pull the doca_hbn Container Image

```bash
sudo grep image /etc/kubelet.d/doca_hbn.yaml
sudo crictl pull nvcr.io/nvidia/doca/doca_hbn:3.3.0-doca3.3.0
sudo crictl images | grep doca_hbn
```

---

### Step 9 — Create Internal SFs

This is the most critical step. After fixing `mlnx-sf.conf` in Step 5, run:

```bash
sudo bash /etc/mellanox/mlnx-sf.conf
sleep 8
```

Verify representors appeared with correct opstate and were renamed by udev:
```bash
devlink port show | grep sfnum    # expect opstate: attached for 2, 3, 1514, 1515
grep -r "" /sys/class/net/*/phys_port_name 2>/dev/null
```

Expected in `/sys/class/net/`:
```
p0_if_r      phys_port_name: pf0sf2
p1_if_r      phys_port_name: pf0sf3
pf0hpf_if_r  phys_port_name: pf0sf1514
pf1hpf_if_r  phys_port_name: pf0sf1515
```

If representors appear but `p0_if_r` etc. are missing, the SF MACs conflict with
physical port MACs (install.sh assigns `p0`'s MAC to sfnum 2). Fix: replace
`mlnx-sf.conf` from the repo, delete existing SFs, and reprovision:
```bash
sudo cp mellanox/mlnx-sf.conf /etc/mellanox/mlnx-sf.conf
# delete using full sfindex path from devlink (NOT just the integer)
devlink port show | grep "sfnum [2-9]\|sfnum 1[0-9]"
# e.g.:  pci/0000:03:00.0/163872: ... sfnum 2
sudo mlnx-sf --action delete --sfindex pci/0000:03:00.0/<sfindex>
# repeat for each HBN SF, then:
sudo bash /etc/mellanox/mlnx-sf.conf
```

After reprovisioning, restart sfc.service so it picks up the new representors:
```bash
sudo systemctl restart sfc.service
sleep 20
```

---

### Step 10 — Validate OVS Ports

After sfc.service runs, `br-hbn` should have exactly 8 ports:

```bash
sudo ovs-vsctl list-ports br-hbn
# expected: p0 p1 pf0hpf pf1hpf p0_if_r p1_if_r pf0hpf_if_r pf1hpf_if_r
```

If any are missing, restart sfc.service and check its logs:
```bash
sudo systemctl restart sfc.service
sleep 20
journalctl -u sfc -n 50
```

---

### Step 11 — Wait for Pod to Start

Kubelet retries every ~2 minutes automatically.

```bash
sudo crictl ps

# Watch init-sfs (moves SF netdevs into pod netns, waits for SFC completion)
sudo crictl logs -f $(sudo crictl ps -q --name init-sfs) 2>/dev/null

# Watch main container
sudo crictl logs -f $(sudo crictl ps -q --name doca-hbn) 2>/dev/null
```

Expected sequence:
1. `init-sfs`: initial config → waits for `p0_if` etc. → moves to pod netns → logs "HBN initial config for DPF/SFC completed"
2. `doca-hbn`: FRR starts (zebra, staticd, bfdd)

---

### Step 12 — Bring Up HBN Interfaces

Interfaces arrive DOWN inside the container after the netns move:

```bash
sudo crictl exec -it $(sudo crictl ps -q --name doca-hbn) bash
ip link set p0_if up
ip link set p1_if up
ip link set pf0hpf_if up
ip link set pf1hpf_if up
```

Or via vtysh:
```
configure terminal
interface p0_if
 no shutdown
interface p1_if
 no shutdown
interface pf0hpf_if
 no shutdown
interface pf1hpf_if
 no shutdown
end
```

---

### Step 13 — Enable BGP (if needed)

BGP is not in the default watchfrr command line. Enable it:

```bash
# For this session
sudo crictl exec -it $(sudo crictl ps -q --name doca-hbn) bash
sed -i 's/bgpd=no/bgpd=yes/' /etc/frr/daemons
/usr/lib/frr/watchfrr.sh start bgpd
```

For persistence across container restarts, edit the host-mounted copy:
```bash
sudo sed -i 's/bgpd=no/bgpd=yes/' /var/lib/hbn/etc/frr/daemons
```

---

### Step 14 — Verify Full Stack

```bash
# OVS — no "Invalid argument" or "could not set configuration" errors
sudo ovs-vsctl show

# SF representors
grep -r "" /sys/class/net/*/phys_port_name 2>/dev/null

# All SFs active (expect 5: 4 HBN + 1 management)
devlink port show | grep sfnum

# FRR processes
ps aux | grep frr

# Inside container
sudo crictl exec -it $(sudo crictl ps -q --name doca-hbn) vtysh -c "show interface brief"
```

---

### Step 15 — Check E-Switch / OVS Flow Rules

```bash
# TC flower rules on representors (hardware offloaded)
for intf in p0_if_r p1_if_r pf0hpf_if_r pf1hpf_if_r; do
  echo "=== $intf ==="
  tc filter show dev $intf ingress
done

# OVS OpenFlow rules
sudo ovs-ofctl dump-flows br-hbn

# Hardware-offloaded DPDK flows
sudo ovs-appctl dpctl/dump-flows type=offloaded

# Port stats
sudo ovs-ofctl dump-ports br-hbn
```

---

## Key Files

| File | Purpose |
|------|---------|
| `/etc/mellanox/hbn.conf` | HBN bridge membership and profile selection |
| `/etc/mellanox/sfc.conf` | MAPPINGS: wires OVS ports, SF netdevs, representors together |
| `/etc/mellanox/mlnx-sf.conf` | SF creation commands with sfnum and MAC |
| `/etc/mellanox/mlnx-ovs.conf` | OVS global settings (DOCA mode, HW offload) |
| `/etc/mellanox/mlnx-bf.conf` | BF3 hardware settings (eswitch multiport) |
| `/etc/mellanox/sfc-ovs.conf` | Optional OVS flow tuning for sfc.sh |
| `/etc/mellanox/hugepages.d/hbn (ovs-doca).json` | Active hugepage allocation |
| `/etc/mellanox/hbn_profiles/resources_profiles.yaml` | Named resource profiles |
| `/etc/kubelet.d/doca_hbn.yaml` | Static pod spec (hostPath volumes, image, resources) |
| `/opt/mellanox/sfc-hbn/sf-rep-netdev-rename` | Udev script: sfnum → representor name |
| `/opt/mellanox/sfc-hbn/sfc.sh` | OVS bridge/port/flow setup, logs "SFC Completed" |
| `/opt/mellanox/hbn-profile/hbn_profile_apply.py` | Profile service: hugepages + OVS PMD |
| `/var/lib/hbn/etc/frr/` | Persistent FRR config (host-mounted into container) |
| `/var/lib/hbn/etc/frr/daemons` | Controls which FRR daemons start (bgpd=no by default) |
| `/var/log/doca/hbn/` | HBN container logs |

---

## Common Failure Modes

| Symptom | Root Cause | Fix |
|---------|-----------|-----|
| `init-sfs` stuck forever waiting for interfaces | `hbn.conf` has 14 VF entries (install.sh generated) | Replace from `mellanox/hbn.conf` (Step 5) |
| OVS br-hbn `Invalid argument` / tap device failed | OVS started before hugepages allocated | `del-br br-hbn`, allocate hugepages, restart OVS + sfc.service (Step 6) |
| SFs provisioned but `p0_if_r` etc. missing | `mlnx-sf.conf` assigns physical port MAC to SF; mlx5_core skips function netdev | Replace `mlnx-sf.conf`, delete SFs (`mlnx-sf -a delete -i pci/…/<sfidx>`), reprovision (Step 9) |
| `mlnx-sf --action delete` reports "SF not found" | Using integer sfindex instead of full path | Use `pci/0000:03:00.0/<sfindex>` format (from `devlink port show`) |
| OVS ports missing after sfc.service | sfc.service ran before SFs were provisioned | `systemctl restart sfc.service` (Step 10) |
| Pod never starts; kubelet can't find pod spec | `doca_hbn.yaml` not in `/etc/kubelet.d/` | Copy from working BF3 into `mellanox/`, then deploy (Step 5) |
| OVS `_if_r: No such device` | SFs not created | Run `mlnx-sf.conf` (Step 9) |
| `init-sfs` stuck: `Device p0_if does not exist` | SFs not created | Same as above |
| `init-sfs` fails: `aa-complain not found` | `apparmor-utils` not installed | `apt install apparmor-utils` (Step 3) |
| Pod stuck, kubelet hostPath volume errors | `/var/lib/hbn/` dirs missing | Create dirs (Step 4) |
| `crictl pull` fails | DNS broken | Fix `/etc/resolv.conf` (Step 2) |
| `p0_if` etc. DOWN in vtysh | Not brought up after netns move | `ip link set <if> up` (Step 12) |
| `bgpd` not running | Not in watchfrr command / daemons file | Enable + start bgpd (Step 13) |
| `hbn-profile.service` fails first run | `/etc/kubelet.d/doca_hbn.yaml` not yet present | Re-run after YAML exists (Step 7) |
| REST API 401 after container restart | Credentials reset to nvidia/nvidia | Re-run `hbn-dpu-setup.sh -u nvidia -p nvidia -e` from its source dir |
| SFs opstate `detached` / stuck in `sf_cfg` | Used raw `devlink port function set state active` instead of `mlnx-sf` | Delete and recreate with `mlnx-sf --action create -t` (the `-t` flag is required) |
