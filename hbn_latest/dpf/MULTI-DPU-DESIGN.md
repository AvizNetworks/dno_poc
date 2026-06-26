# Multi-DPU Support — Design & TODO

> **Status: DESIGN ONLY — not implemented.** Goal: have one DPF Operator VM manage **2+ DPUs
> simultaneously**. Today the scripts provision **one** DPU cleanly (validated on S4); a second
> DPU collides on the Kamaji NodePort. Findings below are from a read-only investigation on S5
> (2026-06-25). Estimated effort to implement + validate: **~1 day**.

---

## Background — what already works
The bringup is per-server, so most of multi-DPU is done:
- Per-server resource names: `<server>-dpu`, `<server>-dpu-cluster`, `<server>-bf3-hbn` flavor, `<server>-node`, `<server>-bf3`.
- `tunnel_dpf.sh` matches tunnels by **Kamaji ClusterIP**, so two DPUs' tunnels coexist.
- HBN is a per-cluster DaemonSet; `setup_host_vfs.sh` has a single-BF3-per-host guard.

## The blocker — NodePort 6443 collision
Each DPU gets its own Kamaji **TenantControlPlane (TCP)**. Kamaji exposes the TCP API server as a
`NodePort` Service, and **`nodePort = spec.networkProfile.port`, which defaults to `6443` for every
cluster**. The first cluster takes host port 6443; the second fails:

```
Service "<2nd>-dpu-cluster" is invalid: spec.ports[0].nodePort:
  Invalid value: 6443: provided port is already allocated
```
(We only ever ran one cluster by deleting the other.)

## Investigation findings (read-only, S5 / DOCA v25.10.1)
1. **DPUCluster CRD has no port knob** — `spec` = `{type, maxNodes, kubeconfig, clusterEndpoint}`;
   `clusterEndpoint` only configures **keepalived** (VIP/interface), nothing about the NodePort.
2. **cluster-manager (`kamaji-cm-controller-manager`) has no NodePort-range config** — it creates each
   TCP with the **default** `networkProfile.port: 6443`.
3. **Kamaji: `nodePort == networkProfile.port`** — confirmed: s4 TCP `networkProfile.port: 6443` →
   Service `nodePort: 6443`. `networkProfile.port` is "Port where the API server will be exposed".
4. **`networkProfile.port` is patchable and the patch sticks** — we already patch the sibling field
   `networkProfile.address` in `bringup_dpf.sh` Step 9 and the cluster-manager does **not** revert it.
   Same mechanism should let us set a unique port per cluster.

⇒ There is **no built-in per-cluster NodePort setting**, but the **patch-after-create pattern is viable**.

## Proposed solution
Assign each DPU cluster a **unique `networkProfile.port`** (= its NodePort), patched right after the
DPUCluster is created (alongside the existing address patch, before the DPU/bfcfg is generated).

Suggested mapping (stable, readable):
```
s4 → 6443   s2 → 6444   s1 → 6445   ...   (or 6443 + per-server index)
```
The port must then be **threaded through 3 places**:

| # | File | Change |
|---|---|---|
| 1 | `dpf/scripts/bringup_dpf.sh` | In the Step-9 TC patch, also set `spec.networkProfile.port=<PORT>` (per-server). Trivial — mirrors the `networkProfile.address` patch already there. |
| 2 | `dpf/scripts/tunnel_dpf.sh` | `KAMAJI_PORT` is hardcoded `6443`; make it the cluster's actual port (discover from the TCP, or per-server preset). The reverse tunnel forwards `x86:<PORT> → ClusterIP:<PORT>`. |
| 3 | `dpf/manifests/04-dpuflavor.yaml` (`sfc.sh`) | The join iptables DNAT `<DPF_VM>:6443 → x86:6443`; the 2nd DPU joins on `:<PORT>`, so the rule (and the matching `kubeadm` endpoint) need that port. |

## TODO (implementation checklist)
- [ ] `bringup_dpf.sh`: add `--apiserver-port` (or derive per `--server`); patch `networkProfile.port` in Step 9.
- [ ] `tunnel_dpf.sh`: use the cluster's real port instead of fixed 6443 (auto-discover from the TCP service, like the ClusterIP discovery).
- [ ] `04-dpuflavor.yaml` `sfc.sh`: parametrize the join-endpoint port (substituted by the script, like `X86_HOST_IP`).
- [ ] Provision DPU #2 on a **`Card1`-compatible BMC** (pre-flight: `curl …/redfish/v1/Chassis/Card1` = 200).
- [ ] **Verify (the two real unknowns):**
  - [ ] cluster-manager does **not** revert a patched `networkProfile.port` (very likely OK — address patch proved the pattern).
  - [ ] the **bfcfg kubeadm-join endpoint picks up the patched port** (`<DPF_VM>:<PORT>`) — patch happens before bfcfg generation, so it should, but must be seen end-to-end.
- [ ] Validate **both DPUs coexist**: both `s*-dpu` Ready, both HBN pods Running, both tunnels up (`tunnel_dpf.sh --server … status`), no NodePort conflict.

## Per-DPU prerequisites (unchanged, still apply to DPU #2)
- BMC must expose `/redfish/v1/Chassis/Card1` (S1's does not → DPF-incompatible).
- First-boot manual steps (password, `dhclient oob_net0`, `enable sfc.service`) — see `QUICKSTART.md`.
- rshim available on the x86 host **or** Redfish-viable (different BFB version) — see README "Redfish vs rshim".

## Effort
**~1 day**: a few hours for the 3 code changes (all known patterns) + a 2-DPU validation run.
Worst case (cluster-manager reverts the port, or bfcfg ignores it) would push toward 2 days and a
different approach (e.g., a mutating step on the TCP Service, or a non-NodePort exposure) — but the
evidence points to the 1-day path.

## Resource note
Two TCPs (each with its own etcd) on one DPF VM's k3s is heavier but fine for 2. Size the DPF VM
accordingly as the count grows.
