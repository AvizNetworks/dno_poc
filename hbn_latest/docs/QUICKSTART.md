# HBN BF3 — Script Quick Reference

**Setup:** ToR `10.20.13.214` · BF3 `10.20.13.228` · Host `10.20.13.12`

Scripts that run on BF3 require `sudo`.
Scripts that SSH across devices (`validate_routing.sh`, `test_static_routing_rest.sh`) run from any machine and need `sshpass` (`sudo apt install sshpass`).

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

Prints a live reference card of all HBN interfaces (`p0_if`, `p1_if`, `pf0hpf_if`,
`pf1hpf_if`) with current IP, MAC, and link state. Use this before configuring
FRR or NVUE to get the correct interface names and addresses.

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
