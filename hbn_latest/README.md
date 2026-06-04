# HBN BF3 Bringup Scripts

Automated scripts to bring up NVIDIA HBN (Host-Based Networking) on a BlueField-3 DPU running DOCA 3.3.0.

**Validated on:** `bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb`

---

## What is HBN?

HBN turns the BF3 DPU into a virtual switch and router between:
- **Your x86 host** (connected via PCIe)
- **The Top-of-Rack switch** (connected via physical ports p0/p1)

The BF3 runs OVS-DPDK for hardware-offloaded switching and FRR for routing (BGP, OSPF, static routes, BFD). You configure routing on 4 interfaces inside the `doca-hbn` container — not on the host.

```
ToR Switch ←──── p0_if / p1_if          (configure routing here)
x86 Host   ←──── pf0hpf_if / pf1hpf_if  (configure routing here)
```

---

## Lab Servers

| Server | BF3 ARM (OOB) | x86 Host | Notes |
|---|---|---|---|
| S1 | `10.20.13.247` | `10.20.13.13` | test_static_routing_rest1.sh — 6.6.6.x |
| S2 | `10.20.13.228` | `10.20.13.12` | test_static_routing_rest.sh — 5.5.5.x |
| S3 | `10.4.5.165` | — | different credentials |
| S4 | `10.20.13.249` | — | |

**ToR Switch:** `10.20.13.214` — shared across S1 and S2.

VSCode tasks (`.vscode/tasks.json`) auto-open SSH terminals to all 4 servers on folder open.

---

## Quick Start

### Step 1 — Clone the repo to the BF3

```bash
scp -r /path/to/hbn/ ubuntu@<BF3-OOB-IP>:~/hbn/
ssh ubuntu@<BF3-OOB-IP>
cd ~/hbn
```

The repo must be present in full — `scripts/bringup_hbn_bf3.sh` deploys configs from `mellanox/` and `doca_hbn_v3.3.0/` at the repo root.

### Step 2 — Run bringup on BF3

```bash
sudo ./scripts/bringup_hbn_bf3.sh
```

With BGP enabled and a custom REST API password:
```bash
sudo ./scripts/bringup_hbn_bf3.sh --enable-bgp --rest-pass MyPass123
```

### Step 3 — Check status

```bash
sudo ./scripts/status_hbn.sh
```

### Step 4 — View interface reference

```bash
sudo ./scripts/topology_hbn.sh
```

### Step 5 — Start configuring FRR

```bash
CONT=$(sudo crictl ps | grep doca-hbn | grep -v init | awk '{print $1}')
sudo crictl exec -it $CONT vtysh
```

---

## Repository Layout

```
hbn/
├── scripts/          # runnable scripts (copy full repo to BF3)
├── docs/             # reference docs and runbooks
├── mellanox/         # reference config files deployed by bringup
└── doca_hbn_v3.3.0/  # official NVIDIA HBN package (scripts + pod spec)
```

---

## Scripts

### `scripts/bringup_hbn_bf3.sh`

**Run on BF3 with sudo. Idempotent — safe to re-run.**

Automates all bringup steps:
1. Verify eswitch switchdev mode
2. Fix DNS (adds 8.8.8.8 if needed for image pull)
3. Create required hostPath directories
4. Generate `hbn.conf`, `sfc.conf`, `mlnx-sf.conf` dynamically (VF-aware)
5. Allocate hugepages (1600×2MB) and create persistent service
6. Provision SubFunctions (sfnum 2, 3, 1514, 1515 + VF sfnums if `--vfs` set)
7. OVS health check — clean stale VF entries, rename VF representors
8. Validate OVS ports on `br-hbn`
9. Pull `doca_hbn` container image
10. Wait for `doca-hbn` pod to be Running
11. Move VF SF function netdevs into container, bring up all interfaces
12. Enable BGP in FRR (optional)
13. Configure REST API password and external access

**Options:**

| Flag | Default | Description |
|---|---|---|
| `--enable-bgp` | off | Enable bgpd in FRR daemons |
| `--rest-user <user>` | `nvidia` | REST API username |
| `--rest-pass <pass>` | `nvidia` | REST API password |
| `--skip-dns-fix` | off | Skip adding nameserver 8.8.8.8 |
| `--vfs <n>` | 0 | Total VFs split equally across both PFs (e.g. `--vfs 8` → 4 per PF) |
| `--p0-vfs <n>` | 0 | VFs on PF0 only |
| `--p1-vfs <n>` | 0 | VFs on PF1 only |

**VF prerequisite** — enable SR-IOV on the x86 host before running with `--vfs`:
```bash
# On x86 host (run once, make persistent via udev or systemd)
echo 4 > /sys/class/net/enp65s0f0np0/device/sriov_numvfs
echo 4 > /sys/class/net/enp65s0f1np1/device/sriov_numvfs
```

---

### `scripts/topology_hbn.sh`

**Run on BF3 with sudo.**

Prints the 4 configurable interfaces with their live state, MAC, and IP. Saves output to `/var/log/doca/hbn/topology-<timestamp>.txt`.

Example output:
```
  [1] ToR Uplink 0       → connects to Top-of-Rack switch port 0
      FRR Interface : p0_if
      MAC           : 5c:25:73:79:c8:9c
      IP Address    : (not configured)
      Link State    : UP
```

---

### `scripts/status_hbn.sh`

**Run on BF3 with sudo.**

Runs a full health check across all HBN components and reports `[OK]` / `[WARN]` / `[FAIL]`:

- eswitch switchdev mode
- SubFunctions (sfnum 2, 3, 1514, 1515)
- `doca-hbn` container running
- SF representors (`p0_if_r`, `p1_if_r`, `pf0hpf_if_r`, `pf1hpf_if_r`)
- OVS bridge `br-hbn` — port errors, offloaded flow count
- FRR daemons (zebra, bgpd, bfdd)
- Interface states inside container
- NVUE REST API reachability

---

### `scripts/access_hbn.sh`

**Run from any machine.**

Prints all access methods for the BF3. Accepts `--bf3-ip <IP>` to override the default IP.

```bash
./access_hbn.sh --bf3-ip 10.20.13.228
```

---

### `scripts/test_static_routing_rest.sh` / `scripts/test/test_static_routing_rest1.sh`

**Run from any machine. Requires `sshpass`.**

Configures interface IPs and static routes via the NVUE REST API, then runs end-to-end ping tests across all three devices (ToR ↔ BF3 ↔ Host).

- `test_static_routing_rest.sh` — targets S2 (10.20.13.228), Ethernet76, 5.5.5.0/24
- `test/test_static_routing_rest1.sh` — targets S1 (10.20.13.247), Ethernet72, 6.6.6.0/24

```bash
./scripts/test_static_routing_rest.sh           # test only
./scripts/test_static_routing_rest.sh --setup   # configure IPs + routes, then test
```

> **Note:** NVUE REST apply is broken on DOCA 3.3.0. Both scripts fall back to `vtysh` automatically if the apply doesn't commit.

---

### `scripts/mirror_to_dpu.sh`

**Run on the x86 host with sudo.**

Sets up a tc mirred copy from the host's internet-facing interface to the BF3 PCIe link. Traffic is copied (not redirected) so existing connectivity is completely unaffected. The copy flows through OVS `br-hbn` and can be mirrored to `aviz0` for Aviz Service Node (ASN) DPI.

```bash
sudo ./scripts/mirror_to_dpu.sh start    # enable mirror
sudo ./scripts/mirror_to_dpu.sh stop     # remove mirror, restore default qdisc
sudo ./scripts/mirror_to_dpu.sh status   # show current state
```

Edit `SRC_IFACE` and `DST_IFACE` at the top of the script for your server. Defaults are for S1: `eno2 → enp65s0f0np0`.

---

## Configuring Routing (Post-Bringup)

All routing is configured inside the `doca-hbn` container. The BF3 hardware offloads the dataplane automatically.

### Get a shell

```bash
CONT=$(sudo crictl ps | grep doca-hbn | grep -v init | awk '{print $1}')
sudo crictl exec -it $CONT vtysh
```

### Assign IPs to interfaces

```
conf t
interface p0_if
 ip address 192.168.1.1/30
 no shutdown
!
interface pf0hpf_if
 ip address 10.10.0.1/24
 no shutdown
```

### Configure BGP

```
router bgp 65000
 neighbor 192.168.1.2 remote-as 65001
 address-family ipv4 unicast
  network 10.10.0.0/24
 exit-address-family
```

### Via REST API

```bash
# Get system info
curl -k -u nvidia:nvidia https://<BF3-OOB-IP>:8765/nvue_v1/system

# Get all interfaces
curl -k -u nvidia:nvidia https://<BF3-OOB-IP>:8765/nvue_v1/interface
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pod not starting, kubelet errors | Missing `/var/lib/hbn/` dirs | Run `bringup_hbn_bf3.sh` |
| `aa-complain: not found` in init-sfs logs | `apparmor-utils` missing | `sudo apt install apparmor-utils` |
| `p0_if` not found in container | SFs not provisioned | `sudo bash /etc/mellanox/mlnx-sf.conf` |
| OVS ports show "No such device" | SF representors not created | Provision SFs, then restart OVS |
| `crictl pull` fails / DNS error | `/etc/resolv.conf` missing public DNS | `echo "nameserver 8.8.8.8" >> /etc/resolv.conf` |
| REST API returns 401 | Default credentials not set up | Run `hbn-dpu-setup.sh -u nvidia -p nvidia -e` from its source dir |
| bgpd not running | Disabled by default | `--enable-bgp` flag or edit `/var/lib/hbn/etc/frr/daemons` |
| Interfaces DOWN after pod start | Netns move leaves them DOWN | `ip link set p0_if up` inside container |

---

## Architecture Reference

For deep-dive architecture, config file annotations, and the full manual procedure see:
[docs/bf3-hbn-bringup.md](docs/bf3-hbn-bringup.md)
