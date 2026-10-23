# HBN quickstart for BlueField-3

One command, run on the server that holds a BlueField-3 card, takes the card from
"fresh" to "HBN running and ready for Aviz ONES". At the end, the server has one main
network interface and a set of virtual interfaces through the card, and ONES can manage
the card through its API.

## What you need per server

- Ubuntu 22.04 or 24.04 with `sudo`.
- One **free IP address** for the card's management port, in the network that port is
  cabled to (there is usually no DHCP there), and that network's gateway.
- Someone who can **power-cycle the server once** (BMC, power button, or the script itself).
- Internet on the server for the first run, so the script can install a few packages
  (`rshim`, `sshpass`, `ipmitool`, `mstflint`). Offline server: install them first.

## 1. Put three files in one folder on the server

| File | From |
|---|---|
| `hbn-standalone-<date>.tar.gz` | Aviz (this package) |
| `bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb` | Card software (NVIDIA); Aviz can provide it |
| `doca_hbn_3.3.0-doca3.3.0.tar.gz` | HBN image; Aviz provides it |

The home folder is fine. For example, from a server that already has them:

```bash
scp ~/hbn-standalone-<date>.tar.gz ~/bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb \
    ~/doca_hbn_3.3.0-doca3.3.0.tar.gz  ubuntu@NEW-HOST:
```

The script finds the other two files next to the unpacked package.
If they are missing, it downloads the card software (needs internet on the server) and pulls
the HBN image (needs internet on the card's management network). Copying them is faster and
works offline.

## 2. Unpack and fill in the settings

```bash
cd ~ && tar xzf hbn-standalone-<date>.tar.gz && cd hbn-standalone
cp scripts/hbn_quickstart.env.sample hbn_quickstart.env
vi hbn_quickstart.env
```

Set at least these:

```bash
BF3_PASSWORD='...'          # password the card's 'ubuntu' user gets
OOB_ADDRESS=192.0.2.10/24   # a FREE address per card
OOB_GATEWAY=192.0.2.1
HOST_PF_IN_HBN=yes          # main interface through HBN too (needed for PXE boot through the card)
VFS_PER_PF=4                # number of virtual interfaces for tenants
REST_PASSWORD='...'         # password ONES uses for the card's API
```

## 3. Preview, then run

```bash
sudo ./scripts/hbn_quickstart.sh --check     # shows the plan, changes nothing — send us this output
sudo ./scripts/hbn_quickstart.sh             # run; about 20 to 25 minutes
```

- **"COLD POWER CYCLE NEEDED"**: a new card usually needs one. Power-cycle the server
  (`sudo ipmitool chassis power cycle`, or the BMC), log back in, and run the **same
  command** again. The script continues where it stopped. Re-running is always safe.
- **`--reflash`** wipes the card and installs it fresh. Not needed for a new card (it is
  installed automatically). Use it only on the **first** run, to reset a card that was used
  before; a re-run after a stop never installs twice.

## 4. Send Aviz two files

When the script prints **DONE**, its last line names both:

- `/var/lib/hbn-quickstart/ones-handover.json` — what ONES needs: the card's management
  IP, API address and login, and the list of the server's interfaces.
- `/var/lib/hbn-quickstart/quickstart-<date>.log` — everything the run did.

## What the server gets

| On the server | Used for |
|---|---|
| main interface (e.g. `enp59s0f0np0`) | the server's own traffic, PXE boot |
| virtual interfaces (e.g. `enp59s0f0v0` … `v3`) | tenants; ONES assigns them |

Exact names differ per server; `ones-handover.json` lists them. The script creates the
virtual interfaces itself and keeps them across reboots; there is no separate step for
them. To change how many, edit `VFS_PER_PF` and run the script again.

## If it stops

| Message | What to do |
|---|---|
| COLD POWER CYCLE NEEDED | Power-cycle the server, run the same command again |
| HOST REBOOT NEEDED | `sudo reboot`, run the same command again |
| NOT DONE — the server's traffic does not reach the card | The card's PCIe slot does not pass traffic. Power off, move the card to another slot (Intel S2600BP: Riser 1, Slot 1), power on, run the same command again. Send us the `.json` and the log |
| no BF3 rshim function | The card's management link to the server is disabled on the card's BMC. The message prints the fix; ask Aviz if unsure |
| Install missing host packages … | Answer `y` (needs internet), or install the listed packages first |

Anything else: send Aviz the log file from step 4.
