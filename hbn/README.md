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

## Quick Start

### Step 1 — Copy scripts to BF3

```bash
scp bringup_hbn_bf3.sh topology_hbn.sh status_hbn.sh ubuntu@<BF3-OOB-IP>:~/
```

If you have the `hbn-dpu-setup.sh` NGC scripts, copy those too:
```bash
scp -r /path/to/ngc-scripts/ ubuntu@<BF3-OOB-IP>:~/hbn-scripts/
```

### Step 2 — Run bringup on BF3

```bash
ssh ubuntu@<BF3-OOB-IP>
sudo ./bringup_hbn_bf3.sh
```

With REST API and BGP enabled:
```bash
sudo ./bringup_hbn_bf3.sh --enable-bgp --hbn-scripts-dir ~/hbn-scripts
```

### Step 3 — Check status

```bash
sudo ./status_hbn.sh
```

### Step 4 — View interface reference

```bash
sudo ./topology_hbn.sh
```

### Step 5 — Start configuring FRR

```bash
CONT=$(sudo crictl ps | grep doca-hbn | grep -v init | awk '{print $1}')
sudo crictl exec -it $CONT vtysh
```

---

## Scripts

### `bringup_hbn_bf3.sh`

**Run on BF3 with sudo. Idempotent — safe to re-run.**

Automates all bringup steps:
1. Verify eswitch switchdev mode
2. Fix DNS (adds 8.8.8.8 if needed for image pull)
3. Install `apparmor-utils`
4. Create required hostPath directories
5. Pull `doca_hbn` container image
6. Provision SubFunctions (sfnum 2, 3, 1514, 1515)
7. Wait for `doca-hbn` pod to be Running
8. Bring up HBN interfaces (`p0_if`, `p1_if`, `pf0hpf_if`, `pf1hpf_if`)
9. Enable BGP in FRR (optional)
10. Enable NVUE REST API (optional)

**Options:**

| Flag | Default | Description |
|---|---|---|
| `--enable-bgp` | off | Enable bgpd in FRR daemons |
| `--rest-user <user>` | `nvidia` | REST API username |
| `--rest-pass <pass>` | `nvidia` | REST API password |
| `--hbn-scripts-dir <path>` | — | Path to dir with `hbn-dpu-setup.sh` |
| `--skip-dns-fix` | off | Skip adding nameserver 8.8.8.8 |

---

### `topology_hbn.sh`

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

### `status_hbn.sh`

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

### `access_hbn.sh`

**Run from any machine.**

Prints all access methods for the BF3. Accepts `--bf3-ip <IP>` to override the default IP.

```bash
./access_hbn.sh --bf3-ip 10.20.13.228
```

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
curl -k -u nvidia:nvidia https://10.20.13.228:8765/nvue_v1/system

# Get all interfaces
curl -k -u nvidia:nvidia https://10.20.13.228:8765/nvue_v1/interface
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
[bf3-hbn-bringup.md](bf3-hbn-bringup.md)
