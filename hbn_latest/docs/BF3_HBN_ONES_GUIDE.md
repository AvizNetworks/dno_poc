# BlueField-3 + HBN bring-up for ONES

This guide takes a BlueField-3 (BF3) card from "just installed in a server" to
"HBN running and ready for ONES to provision". At the end you will have:

- the BF3 in **DPU mode**, running the validated OS (`bf-bundle-3.3.0`)
- **HBN** (NVIDIA Host-Based Networking: FRR routing + NVUE API) running on the BF3
- **SR-IOV VFs** on the x86 host, each wired to its own HBN interface — these are the
  interfaces ONES assigns IP addresses to
- a short list of facts to hand to ONES (Step 9)

Everything runs **offline** — the BF3 does not need internet access.
Plan about 1–2 hours for a card you have never seen before; most of it is waiting
for flashes and reboots.

---

## Fast path — one command on the x86 host

`scripts/hbn_quickstart.sh` runs Steps 1–9 for you from the x86 host. It reaches the
BF3 over the PCIe management link (rshim), so the BF3 needs no network, console or
password beforehand, and it calls the same scripts described below.

```bash
# on the x86 host, in the extracted package (put the .bfb and the doca_hbn image tar
# next to the hbn-standalone folder, or let the script download the .bfb)
cp scripts/hbn_quickstart.env.sample hbn_quickstart.env     # optional: edit VFs, OOB IP, ...
sudo ./scripts/hbn_quickstart.sh --check                    # read-only: what would it do?
sudo ./scripts/hbn_quickstart.sh                            # run it — repeat until it says DONE
```

- It asks before anything destructive (flashing the BF3, switching to DPU mode,
  re-creating VFs); `--yes` answers for you.
- When a **cold power cycle** is needed it stops with exit code 3 and says so:
  power-cycle the server (`sudo ipmitool chassis power cycle`, or `--power-cycle` to let
  the script do it), then run the same command again.
- A BF3 that already runs bf-bundle 3.3.0 is **not** re-flashed if you set its `ubuntu`
  password as `BF3_PASSWORD` in `hbn_quickstart.env` (needs `sshpass` on the host).
- At the end it writes the hand-over for ONES (Step 9) to
  `/var/lib/hbn-quickstart/ones-handover.txt` and `.json`.

If anything stops it, the steps below are the same procedure by hand — continue there.

---

## What you need

| Item | Notes |
|---|---|
| x86 host with the BF3 installed | Ubuntu, root access, `rshim` package (`sudo apt install rshim`) |
| Host BMC access, or someone who can power-cycle the server | Needed for a **cold** power cycle (Steps 1–2) |
| BF3 BMC IP + `root` password | The BF3's own BMC (OpenBMC), on the card's RJ45 management port |
| An IP address for the BF3 management port (OOB) | Same subnet as the BF3 BMC — there is usually no DHCP on that network |
| `bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb` | BF3 OS image, ~1.5 GB (download link in Step 2) |
| `hbn-standalone-<date>.tar.gz` | The scripts (this package) |
| `doca_hbn_3.3.0-doca3.3.0.tar` | The HBN container image (arm64), delivered alongside this package. Not needed if the BF3 has internet access. |

### What is in the package

| Script | Runs on | Purpose |
|---|---|---|
| `scripts/inventory_bf3.sh` | BF3 | Read-only report: can HBN run here, single- or dual-port, what a bring-up would replace |
| `scripts/setup_host_vfs_standalone.sh` | x86 host | Creates the SR-IOV VFs (persists across reboots) |
| `scripts/bringup_hbn_bf3.sh` | BF3 | HBN bring-up for **dual-port** cards (p0 + p1) |
| `scripts/bringup_hbn_bf3_single_port.sh` | BF3 | HBN bring-up for **single-port** cards (e.g. B3140H SuperNIC) |
| `scripts/status_hbn.sh` | BF3 | Health check after bring-up |
| `scripts/topology_hbn.sh` | BF3 | Interface reference card (HBN interface ↔ host VF) |

Both bring-up scripts are **preflight-first** (`--check` changes nothing and prints
the exact fix for every problem) and **safe to re-run**.

---

## Steps at a glance

| # | Where | What |
|---|---|---|
| 1 | BF3 BMC + host | Make sure the BF3 is in DPU mode (SuperNIC cards ship in NIC mode) |
| 2 | x86 host | Flash the BF3 OS (`bf-bundle-3.3.0`) |
| 3 | BF3 console | First login, set the clock, give the management port an IP |
| 4 | BF3 | Copy the package + HBN image, import the image |
| 5 | BF3 | Run the inventory (read-only) |
| 6 | x86 host | Create the host VFs |
| 7 | BF3 | Bring up HBN |
| 8 | BF3 | Verify |
| 9 | — | Hand over to ONES |

Placeholders used below: `<BMC>` = BF3 BMC IP, `<BMCPW>` = its root password,
`<OOB-IP>` = the address you give the BF3 management port.

---

## Step 1 — Put the BF3 in DPU mode

HBN runs on the BF3's Arm cores, which only happens in **DPU mode**. SuperNIC models
(for example the single-port B3140H) are shipped in **NIC mode**: the Arm stops in
UEFI and never boots Linux.

**Check** (from any machine that reaches the BF3 BMC):

```bash
C="curl -sk --max-time 30 -u root:<BMCPW>"     # quote the password if it has special characters
$C https://<BMC>/redfish/v1/Systems/Bluefield/Bios | grep '"NicMode"'
$C https://<BMC>/redfish/v1/Systems/Bluefield      | grep -A3 BootProgress
```

- `"NicMode": "DpuMode"` and `OemLastState: "OsIsRunning"` → already in DPU mode, go to Step 2.
- `"NicMode": "NicMode"`, or `OemLastState: "UEFI"` → switch it:

**Switch to DPU mode** — the order matters:

```bash
# 1. stage the change
$C -X PATCH -H 'Content-Type: application/json' \
   https://<BMC>/redfish/v1/Systems/Bluefield/Bios/Settings \
   -d '{"Attributes":{"NicMode":"DpuMode"}}'

# 2. reboot the BF3 Arm so its UEFI applies the staged setting — via rshim, from
#    whichever side owns it (only one side can):
#    x86 host (if `systemctl is-active rshim` says active):
echo "SW_RESET 1" | sudo tee /dev/rshim0/misc
#    …or the BF3 BMC (when the host does not run rshim):
#    ssh root@<BMC> 'systemctl start rshim; echo "SW_RESET 1" > /dev/rshim0/misc; systemctl stop rshim'
#    wait ~2 min, then confirm the pending setting was consumed:
$C https://<BMC>/redfish/v1/Systems/Bluefield/Bios/Settings | grep -A2 '"Attributes"'   # expect {}

# 3. COLD power cycle the x86 server (cuts power to the PCIe slot):
sudo ipmitool chassis power cycle    # on the x86 host, or via the host BMC
```

A warm reboot, `reboot` on the Arm, or a BMC "chassis reset" does **not** apply the
mode change — it must be a real power cycle of the server.

**Confirm** after the server is back: `BootProgress` → `OemLastState: "OsIsRunning"`,
and on the x86 host `sudo devlink dev eswitch show pci/<BF3-PCI>` → `Operation not supported`
(the Arm now owns the eswitch). The `NicMode` value under `/Bios` may keep showing the
old value until the next Arm boot — trust `BootProgress`, not that field.

---

## Step 2 — Flash the BF3 OS (bf-bundle 3.3.0)

This erases the BF3's storage and installs Ubuntu 24.04 + DOCA 3.3.0 + matching
NIC firmware. The DPU-mode setting from Step 1 is kept.

On the **x86 host**:

```bash
wget https://content.mellanox.com/BlueField/BFBs/Ubuntu24.04/bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb

sudo systemctl enable --now rshim
ls /dev/rshim0/                                    # must exist (see Troubleshooting if not)
echo "BOOT_TIMEOUT 1200" | sudo tee /dev/rshim0/misc
sudo bfb-install --bfb bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb --rshim rshim0
```

Takes 10–20 minutes and ends with `Installation finished`; the Arm reboots by itself.
Only one side may own rshim: if the BF3 BMC's rshim is running, stop it first
(`ssh root@<BMC> systemctl stop rshim`).

**NIC firmware:** compare `ethtool -i <host-PF-netdev> | grep firmware` with the version
printed by the installer (`NIC firmware update done: …`). If they differ, cold power
cycle the server once more. If the host PF netdev disappeared after the flash, reboot
the x86 host.

---

## Step 3 — First login, clock, management IP

Open the BF3 console through its BMC (works even with no network on the BF3):

```bash
ssh -p 2200 root@<BMC>           # serial console of the BF3 Arm; exit with ~.  (~~. inside ssh)
```

Log in as `ubuntu` / `ubuntu`; you are forced to choose a new password.
**Type it carefully and write it down** — a mistyped password here means a re-flash.
Then, right away, consider adding your SSH public key to `~/.ssh/authorized_keys`.

**Set the clock** — a freshly flashed BF3 has a wrong date, which breaks TLS and
certificates:

```bash
sudo date -u -s "2026-10-21 09:30:00"      # current UTC time
```

**Give the management port (`oob_net0`) a static IP.** It shares the RJ45 port with
the BF3 BMC, so use the BMC's subnet and gateway:

```bash
ping -c2 -W1 <OOB-IP> && echo "IN USE — pick another" || echo free

sudo tee /etc/netplan/60-oob.yaml >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    oob_net0:
      dhcp4: false
      addresses: [<OOB-IP>/<prefix>]
      routes: [{to: default, via: <gateway>}]
      nameservers: {addresses: [<dns-server>]}
EOF
sudo chmod 600 /etc/netplan/60-oob.yaml && sudo netplan apply
ping -c2 <gateway>
```

From now on you can use `ssh ubuntu@<OOB-IP>` instead of the console.

---

## Step 4 — Copy the package and the HBN image to the BF3

From any machine that reaches `<OOB-IP>`:

```bash
scp hbn-standalone-<date>.tar.gz doca_hbn_3.3.0-doca3.3.0.tar ubuntu@<OOB-IP>:~/
```

(The image is ~740 MB; `gzip` it first on slow links and `gunzip` it on the BF3.)

On the **BF3**:

```bash
tar xzf hbn-standalone-<date>.tar.gz
sudo ctr -n k8s.io images import ~/doca_hbn_3.3.0-doca3.3.0.tar
sudo crictl images | grep doca_hbn                  # nvcr.io/nvidia/doca/doca_hbn  3.3.0-doca3.3.0
```

If the BF3 has internet access you can pull instead of importing:
`sudo crictl pull nvcr.io/nvidia/doca/doca_hbn:3.3.0-doca3.3.0`.

**Check one firmware setting** (HBN needs SubFunctions; some flashes stage this to 0):

```bash
sudo mst start
sudo mlxconfig -d 03:00.0 -e q PF_TOTAL_SF
# if "Next Boot" shows 0:   sudo mlxconfig -d 03:00.0 -y s PF_TOTAL_SF=32
```

---

## Step 5 — Inventory (read-only)

```bash
cd ~/hbn-standalone
sudo ./scripts/inventory_bf3.sh --quick
```

Read the **Port layout** line and the **VERDICT** at the end:

- `Port layout: SINGLE-PORT …` → use `bringup_hbn_bf3_single_port.sh` in Step 7
- `Port layout: dual-port …` → use `bringup_hbn_bf3.sh` in Step 7
- `1. HBN CANNOT RUN YET` → fix the listed blockers first (each one says how)
- `3. TAKEOVER` lists what a bring-up will replace (on a freshly flashed BF3 this is
  only the factory OVS bridge `ovsbr1` and SubFunction 0 — expected)

The full report is saved under `/tmp/bf3-inventory-*.txt` — send it to us if anything
is unclear.

---

## Step 6 — Create the host VFs (x86 host)

The VFs must exist **before** the HBN bring-up: the BF3 can only wire up VFs it can see.

Copy `scripts/setup_host_vfs_standalone.sh` to the x86 host and run:

```bash
sudo ./setup_host_vfs_standalone.sh                  # 4 VFs per BF3 PF (default)
sudo ./setup_host_vfs_standalone.sh --vfs-per-pf 8   # or choose the count
ip -br link | grep -E 'v[0-9]+ '                     # e.g. enp94s0f0v0 … enp94s0f0v3
```

The script finds the BF3 automatically and installs `bf3-host-vfs.service` so the VFs
come back after every host reboot. It prints the exact bring-up command for Step 7.

Check on the **BF3** that it sees them: `ls /sys/class/net | grep -E '^pf[01]vf'`
→ `pf0vf0 … pf0vf3`.

---

## Step 7 — Bring up HBN

Always run `--check` first; it changes nothing and must say **READY**.

**Single-port card:**

```bash
cd ~/hbn-standalone
sudo ./scripts/bringup_hbn_bf3_single_port.sh --vfs 4 --check
sudo ./scripts/bringup_hbn_bf3_single_port.sh --vfs 4 --enable-bgp --rest-pass '<api-password>'
```

**Dual-port card:** (`--vfs` is the total, split across both PFs)

```bash
sudo ./scripts/bringup_hbn_bf3.sh --vfs 8 --check
sudo ./scripts/bringup_hbn_bf3.sh --vfs 8 --enable-bgp --rest-pass '<api-password>'
```

| Option | Meaning |
|---|---|
| `--vfs N` | Wire N host VFs into HBN (must match Step 6) |
| `--enable-bgp` | Start the BGP daemon in FRR |
| `--rest-pass <pw>` | Password for the NVUE REST API user `nvidia` |
| `--no-pf` *(single-port script)* | Leave the host **PF** out of HBN — only the VFs are connected |

**Should I use `--no-pf`?**
- Use it when the host **only** uses VFs (the ONES case) and the host PF should stay
  outside HBN — for example to install the host OS over the PF from a boot server
  running on the BF3 itself.
- Do **not** use it when the host must reach the network **through its PF** — for
  example PXE-booting the host from a server that sits behind the BF3's uplink.
- You can switch later: re-run the same command with or without `--no-pf`.

The run takes 3–6 minutes. These messages are **expected**:

| Message | Meaning |
|---|---|
| `possible init-sfs deadlock … restarting sfc.service` | Built-in recovery on a fresh BF3; the next line shows the container Running |
| `enable-rest-api.py failed` (first run only) | Harmless on a brand-new install; the REST API is still verified a few lines later |
| `p0 has no carrier — datapath NOT validated` | The uplink cable is not connected yet |

The summary should show `SFs provisioned: N (expect N)` and the REST API URL.

---

## Step 8 — Verify

```bash
sudo ./scripts/status_hbn.sh          # must end with: All checks passed. HBN stack is healthy.
sudo ./scripts/topology_hbn.sh        # every HBN interface with MAC / IP / link state
```

To show which host VF belongs to which HBN interface, let `topology_hbn.sh` look at
the host (needs `sshpass` on the BF3):

```bash
sudo ./scripts/topology_hbn.sh --host-ip <host-ip> --host-user <user> --host-pass '<password>'
#   pf0vf0_if  → Host VF : enp94s0f0v0   (example)
```

From another machine, check the API: `curl -k -u nvidia:<api-password> https://<OOB-IP>:8765/nvue_v1/system`

---

## Step 9 — Hand over to ONES

Give ONES (or the team running it):

| Item | Where to get it |
|---|---|
| BF3 management IP | `<OOB-IP>` (Step 3) |
| HBN REST API | `https://<OOB-IP>:8765/nvue_v1/`, user `nvidia`, password from `--rest-pass` |
| Host VF names | Step 6 output, e.g. `enp94s0f0v0 … enp94s0f0v3` |
| HBN interface for each VF | `topology_hbn.sh --host-ip …` (Step 8): `pf0vfN_if` ↔ host VF N |
| Uplink interface | `p0_if` (and `p1_if` on dual-port cards) |

ONES assigns IP addresses on the **host VFs**; the matching `pf0vfN_if` inside HBN is
the next hop / gateway side for that VF.

> **DOCA 3.3.0 known issue — NVUE REST "apply":** a configuration revision applied via
> the REST API stays `pending`. Apply it from inside the HBN container instead:
> ```bash
> CONT=$(sudo crictl ps --name doca-hbn -q | head -1)
> sudo crictl exec $CONT nv config apply --assume-yes
> ```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| BF3 console stops in UEFI; `BootProgress` = `UEFI` | NIC mode — Step 1 |
| Mode still NIC after the power cycle | The Arm did not boot after the Redfish PATCH. Do Step 1 in order: PATCH → Arm reset → confirm `Settings` is `{}` → cold power cycle |
| `/Bios` still shows `NicMode` but the OS boots | Stale field — trust `BootProgress: OsIsRunning` |
| Redfish returns 401 | Wrong password, or the account is locked after several failures (wait ~10 min) |
| `/dev/rshim0` missing on the host | `sudo systemctl restart rshim`; make sure the BF3 BMC's rshim is stopped |
| On the BMC: `microcom: can't open '/dev/rshim0/console'` | Use `ssh -p 2200 root@<BMC>` instead (does not need rshim) |
| `bfb-install` stalls / `Connection timed out` | Stop the BMC's rshim; `echo "BOOT_TIMEOUT 1200" \| sudo tee /dev/rshim0/misc`; retry |
| Host PF netdev gone after flashing | Reboot the x86 host |
| `Login incorrect` on the BF3 | Wait 10 min (lockout), retry slowly. Otherwise reset via GRUB (`init=/bin/bash`, `passwd ubuntu`) or re-flash (Step 2) |
| `time stamp … in the future`, TLS/certificate errors | Set the clock (Step 3) |
| `scp host:'a b' .` → `No such file` | Newer scp does not split quoted names — use `host:'*.tar.gz'` or one file per argument |
| `--check`: `doca_hbn image NOT in containerd` | Import the image (Step 4) |
| `--check`: `VF eswitch reps missing` | Create the host VFs first (Step 6) |
| `--check`: `dual-port BF3 detected` | Use `bringup_hbn_bf3.sh` |
| `--check` (dual-port): `LAG_RESOURCE_ALLOCATION` | Follow the printed fix: set it, then **cold** power cycle the server |
| `status_hbn.sh`: interface `state=DOWN` | `sudo crictl exec <cont> ip link set <iface> up` |
| Host dmesg: `insufficient power on the PCIe slot` | The slot cannot fully power the card — check whether the card needs its auxiliary power cable. Fine for functional tests, not for load |

---

## Notes and limits

- **Single-port cards** have one uplink (`p0`) — no uplink redundancy.
- **Host ↔ BF3 bandwidth** is limited by the host's PCIe generation
  (`sudo lspci -vvs <BF3-PCI> | grep LnkSta`): PCIe Gen3 x16 ≈ 126 Gb/s.
- **Re-running** any bring-up script is safe; it only changes what is not yet correct.
- **Re-flashing** (Step 2) erases the BF3 OS, the HBN configuration and the imported
  image — repeat Steps 3–8 afterwards. Firmware settings (DPU mode) are kept.
