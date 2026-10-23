# HBN BF3 — Script Quick Reference

Scripts that run on BF3 require `sudo`.
Scripts that SSH across devices run from any machine and need `sshpass` (`sudo apt install sshpass`).

---

## inventory_bf3.sh — run this FIRST on an unfamiliar BF3

Read-only capability report (changes nothing). Answers: can HBN run here, what can
it do (p0 only vs p0+p1, VF capacity, uplink link/LLDP neighbor), and what would a
bringup take over (existing OVS bridges, IPs, netplan, external k8s cluster, pods).
Ends by running `bringup_hbn_bf3.sh --check` and prints a 3-line verdict.

```bash
sudo ./scripts/inventory_bf3.sh            # full (~1 min, includes 35s LLDP listen)
sudo ./scripts/inventory_bf3.sh --quick    # skip LLDP listen
# report saved to /tmp/bf3-inventory-<host>-<ts>.txt — send it back to Aviz
# exit 0 = no blockers, 1 = blockers
```

Catches things `--check` does not: BFB/DOCA version vs the validated 3.3.0, NIC vs
DPU mode, kubelet `staticPodPath` ≠ `/etc/kubelet.d` (HBN pod would never start),
BF3 joined to an external DPF/NICo cluster, and anything a bringup would disrupt.

## bringup_hbn_bf3.sh

The main bringup — **preflight first**: `--check` validates every prerequisite
read-only (exit 0 = ready, exact fix printed per failure), `--dry-run` previews
the 15-step plan, and a normal run refuses to start while blockers exist.
Fully offline and idempotent. See the root `README.md` for the full flow.

```bash
sudo ./bringup_hbn_bf3.sh --check     # validate everything, change nothing
sudo ./bringup_hbn_bf3.sh             # core bringup (add --vfs 8 for SR-IOV VFs)
```

---

## bringup_hbn_bf3_single_port.sh — single-port BF3 (e.g. B3140H SuperNIC)

Same flow and preflight as `bringup_hbn_bf3.sh`, for cards with ONE uplink (no
`p1`, one PCI function). `inventory_bf3.sh` detects the layout and tells you which
script to use. Refuses to run on a dual-port card.

```bash
sudo ./bringup_hbn_bf3_single_port.sh --check            # validate, change nothing
sudo ./bringup_hbn_bf3_single_port.sh --vfs 4            # p0 + host PF + 4 host VFs
sudo ./bringup_hbn_bf3_single_port.sh --vfs 4 --no-pf    # p0 + 4 host VFs (host PF left out of HBN)
```

`--no-pf` keeps the host PF (`pf0hpf`) outside HBN — use it when the host only uses
VFs; the PF then has no network path at all (HBN's OVS-DOCA drops traffic of ports not
in `br-hbn`). Leave it off when the host must reach the network through its PF (e.g. PXE
boot via the uplink). DPU netboot (`dpu-netboot`) must run BEFORE HBN, in either mode. Create the host VFs FIRST (`setup_host_vfs_standalone.sh` on the x86 host).

---

## status_hbn.sh

Checks the full HBN stack health on the BF3: eswitch mode, SubFunctions,
doca-hbn container, OVS bridge, FRR daemons, container interfaces, and REST API.
Run this first after any reboot or bringup to confirm everything is healthy.

```bash
ssh ubuntu@10.20.13.228
sudo ./status_hbn.sh
```

---

## topology_hbn.sh

Prints a live reference card of every HBN interface (`p0_if`, `p1_if`, `pf0hpf_if`,
`pf1hpf_if`, `pfNvfM_if` — whatever this BF3's layout has, read from
`/etc/mellanox/sfc.conf`) with current IP, MAC, and link state. Use this before
configuring FRR or NVUE to get the correct interface names and addresses.

```bash
ssh ubuntu@10.20.13.228
sudo ./topology_hbn.sh
```

---

## validate_routing.sh

SSH-based end-to-end routing validator. Checks interface states on all three
devices and runs bidirectional pings (BF3↔ToR, BF3↔Host). Use `--setup` to
auto-configure interface IPs before testing. Output is saved to a timestamped log file.

```bash
./validate_routing.sh           # ping validation only
./validate_routing.sh --setup   # configure IPs, then validate
```

---

## test_static_routing_rest.sh

Configures static routes on the BF3 via the NVUE REST API and verifies them
end-to-end. Tests the full control plane path: REST → FRR → dataplane → ping.
Use `--setup` to also configure the ToR interface and Host routes.

```bash
./test_static_routing_rest.sh           # test only
./test_static_routing_rest.sh --setup   # configure everything, then test
```

---

## .vscode/tasks.json

Opens SSH terminals to the BF3 and Host automatically when you open this folder
in VSCode. No manual SSH needed — terminals appear in the panel on folder open.

| Terminal | Target |
|---|---|
| SSH: BF3 DPU | `ubuntu@10.20.13.228` |
| SSH: host switch | `admin@10.20.13.12` |
| Local shell | `bash` (for running validate / REST scripts) |

To trigger manually: `Ctrl+Shift+P` → **Tasks: Run Task**

---

## Interface Map (quick reference)

```
ToR Switch  ←──  p0_if / p1_if        BF3 uplinks (configure routes here)
x86 Host    ←──  pf0hpf_if / pf1hpf_if  PCIe host channels (configure routes here)
```

| Interface | Connects to | Default IP |
|---|---|---|
| `p0_if` | ToR `Ethernet76` | `5.5.5.6/24` |
| `pf0hpf_if` | Host `enp193s0f0np0` | `192.168.201.2/24` |

---

## Common one-liners

```bash
# Get a shell inside the HBN container (FRR CLI)
CONT=$(sudo crictl ps | grep doca-hbn | grep -v init | awk '{print $1}')
sudo crictl exec -it $CONT vtysh

# Check FRR routing table
sudo crictl exec -it $CONT vtysh -c "show ip route"

# REST API — get system info
curl -k -u nvidia:nvidia https://10.20.13.228:8765/nvue_v1/system
```
