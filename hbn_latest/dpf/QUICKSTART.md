# DPF Bringup — Quick Start

Provision a BlueField-3 via DPF + deploy HBN. **The script installs all prerequisites itself**
(NFD, cert-manager, Kamaji, ArgoCD, DPF Operator) on a fresh DPF VM — you only stage the BFB image.

Run everything from the **DPF Operator VM**. Workers are defined in
[`config.yaml`](config.yaml) (topology) + [`config.local.yaml`](config.local.sample.yaml)
(passwords, gitignored) — the lab's `worker1` (S4) and `worker2` (S2) are already filled in.

---

### 0. One-time: create the secrets file
```bash
cd ~/hbn/dpf
cp config.local.sample.yaml config.local.yaml   # then fill in the real passwords
```

### 1. Get the BFB image and place it on the DPF VM (and the worker's x86 host for rshim)

> **The BFB is NOT included in this package** — it is NVIDIA software, downloaded under
> your own DOCA license from NVIDIA's DOCA downloads (BlueField BFB bundles).
> This release is validated against exactly this build — verify the checksum:
> ```
> file:   bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb   (~1.5 GB)
> sha256: f74e8a5cf8a1628094b5e77a6d9a7eae47fe15b11e5a9e64e125c7369906d8af
> ```

```bash
sha256sum bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb   # must match the value above
scp bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb dpu-vm@<DPF_VM>:/opt/bfb/
scp bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb <x86_user>@<X86_HOST>:~/
```

### 2. Preflight first (read-only), then run the bringup
```bash
cd ~/hbn
# validate EVERYTHING read-only — tools, config, cluster, ports, BFB, BMC creds,
# firmware gates. Exit 0 = ready; every failure prints its exact fix.
./dpf/scripts/bringup_dpf.sh --check --worker worker1

# optional: preview every step against live state without changing anything
./dpf/scripts/bringup_dpf.sh --dry-run --worker worker1 --rshim-install --hbn

# the real run (re-runs preflight itself and refuses to start on blockers)
./dpf/scripts/bringup_dpf.sh --worker worker1 --rshim-install --hbn
```
Everything else (BMC/OOB IPs, serial, x86 host + creds, apiserver port) comes from the
config files. CLI flags still override if needed. The BF3's **first boot does a firmware
update (25–40 min)** and may time out the wait — that's expected; continue to step 3.

> **Guardrails you get for free:**
> - A **changed DPUFlavor fails fast** instead of silently deleting the DPU and
>   reflashing the BF3 — that destructive path now requires an explicit
>   `--allow-reflash` (use only in a maintenance window).
> - After provisioning, **step 11b reads the firmware back** (`LAG_RESOURCE_ALLOCATION`)
>   — if the flash path skipped nvconfig you get an ACTION-REQUIRED block with the
>   exact fix (stage via mlxconfig + TRUE cold power cycle of the x86 host).
> - `--hbn` ends with **BF3-side hardening + a passive datapath validation**:
>   eswitch multiport enabled, br-hbn pair flows re-derived + a boot-time guard
>   installed, NVUE REST kept on 0.0.0.0 across config cleanups, then 35s of
>   wire-vs-container RX counters per uplink to prove delivery actually works.

> **Cross-subnet only** (DPF VM on `10.4.5.x`, BF3 on `10.20.13.x`): once the script prints
> `DPUCluster ... created`, run in another terminal:
> `./dpf/scripts/tunnel_dpf.sh --server <SERVER> start`
> (it auto-discovers the cluster's Kamaji IP **and port**).

### 3. On the BF3 — first boot, exactly TWO commands (via BMC ARM console)
The BF3 will look "hung" (OOB unreachable, console quiet) — it isn't; it's at the login prompt.
```bash
# log in: ubuntu / ubuntu → set the new password when prompted, then:
sudo systemctl start dpf-firstboot-kick
```
That one service brings up OOB DHCP, sfc, and the cluster join. (It can't self-start on the
very first boot because DPF delivers its files via cloud-init mid-boot — every later boot is
fully hands-off.)

### 4. Re-run the exact same command from step 2
```bash
./dpf/scripts/bringup_dpf.sh --worker worker1 --rshim-install --hbn
```
It sees the BF3 already joined, skips the flash, marks the DPU **Ready**, and deploys **HBN**.

### 5. Verify + host VFs
```bash
./dpf/scripts/fleet_status.sh --frr             # all workers: DPU/node/HBN/FRR
# on the worker's x86 host (bare metal only — VM hosts can't do SR-IOV passthrough):
sudo ./dpf/scripts/setup_host_vfs.sh --persist  # → vf0..vf7 + reboot persistence
```

### Adding another DPU (multi-DPU)
Add a `workerN` block to `config.yaml` with a **unique `apiserver_port`** (6443, 6444, 6445…)
and its passwords to `config.local.yaml`, then repeat steps 1–5 with `--worker workerN`.
s4 (:6443) + s2 (:6444) coexisting is validated. Caveats: a small operator VM needs the 2nd
TenantControlPlane scaled to 1 replica, and **Lenovo/OEM cards need a CRD patch** — see
README Known Issues #12–13.

---

**Done** when `fleet_status.sh` shows the DPU `Ready`, node `Ready`, HBN `Running`.

Stuck somewhere? → [`README.md`](README.md) (Known Issues + v25.10.1 notes). Common ones:
- DPU stuck `Initialize Interface` → OEM card PSID rejected by CRD (README #12), or BMC has
  no `/redfish/v1/Chassis/Card1`.
- `DPUCluster` stuck `Pending` → operator not `Ready`; 2nd cluster → TCP replicas (README #13).
- HBN pod re-stuck `Init:0/1` after a pod delete → `sudo systemctl restart sfc.service` on the BF3.
- SSH `host key changed` after reflash → `ssh-keygen -R <BF3_OOB_IP>`.
