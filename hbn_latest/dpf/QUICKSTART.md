# DPF Bringup — Quick Start

Provision a BlueField-3 via DPF + deploy HBN. **The script installs all prerequisites itself**
(NFD, cert-manager, Kamaji, ArgoCD, DPF Operator) on a fresh DPF VM — you only stage the BFB image.

Run everything from the **DPF Operator VM**. (Worked example = **S4**.)

| | S4 value |
|---|---|
| `<SERVER>` | `s4` |
| `<BMC_IP>` | `10.20.13.250` |
| `<BF3_OOB_IP>` | `10.20.13.249` |
| `<BF3_SERIAL>` | `MT2437600HGY` |
| `<X86_HOST>` | `10.20.13.226` (user `aviz` / `aviz@123`) |

---

### 1. Put the BFB image on the DPF VM (and the x86 host for rshim)
```bash
scp bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb dpu-vm@<DPF_VM>:/opt/bfb/
scp bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb aviz@<X86_HOST>:~/
```

### 2. Run the bringup (installs prereqs + flashes the BF3)
```bash
cd ~/hbn
./dpf/scripts/bringup_dpf.sh --server <SERVER> \
  --bmc-ip <BMC_IP> --oob-ip <BF3_OOB_IP> --serial <BF3_SERIAL> \
  --x86-host <X86_HOST> --x86-user aviz --x86-pass aviz@123 \
  --rshim-install --hbn
```
It sets up everything and flashes the BF3, then waits for it to join. The BF3's **first boot does a
firmware update (25–40 min)** and may time out the wait — that's expected; continue to step 3.

> **Cross-subnet only** (DPF VM on `10.4.5.x`, BF3 on `10.20.13.x`): once the script prints
> `DPUCluster ... created`, run in another terminal:
> `./dpf/scripts/tunnel_dpf.sh --server <SERVER> start`

### 3. On the BF3 — one-time first-boot setup (via BMC ARM console)
The BF3 will look "hung" (OOB unreachable, console quiet) — it isn't; it's at the login prompt.
```bash
# log in on the BMC console: ubuntu / Aviz@AIF12345  (set the new password when prompted)
sudo dhclient oob_net0
sudo systemctl enable --now sfc.service
sudo systemctl restart kubeadm-join.service
```

### 4. Re-run the exact same command from step 2
```bash
./dpf/scripts/bringup_dpf.sh --server <SERVER> \
  --bmc-ip <BMC_IP> --oob-ip <BF3_OOB_IP> --serial <BF3_SERIAL> \
  --x86-host <X86_HOST> --x86-user aviz --x86-pass aviz@123 \
  --rshim-install --hbn
```
It sees the BF3 already joined, skips the flash, marks the DPU **Ready**, and deploys **HBN**.

### 5. Verify + host VFs
```bash
./dpf/scripts/status_dpf.sh                     # DPU <SERVER>-dpu: Ready
sudo ./dpf/scripts/setup_host_vfs.sh            # on the x86 host → vf0..vf7
```

---

**Done** when `status_dpf.sh` shows the DPU `Ready`, the BF3 node `Ready`, and the `doca-hbn` pod `Running`.

Stuck somewhere? → [`README.md`](README.md) (Known Issues + v25.10.1 notes). Common ones:
- BF3 never leaves `Initialize Interface` → BMC may be incompatible (no `/redfish/v1/Chassis/Card1`).
- `DPUCluster` stuck `Pending` → operator not `Ready` (`kubectl get dpfoperatorconfig -n dpf-operator-system`).
- SSH `host key changed` after reflash → `ssh-keygen -R <BF3_OOB_IP>`.
