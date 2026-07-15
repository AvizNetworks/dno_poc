# DPF + HBN — Operating Cheat-Sheet

Day-2 commands for a DPF-provisioned BF3 running HBN. **Run everything from the DPF Operator VM.**
For bringup see [`QUICKSTART.md`](QUICKSTART.md); for deep issues see [`README.md`](README.md).

> Each DPU has its **own cluster** with its own kubeconfig. With multi-DPU use
> **per-server files** (`~/s4-tc-kubeconfig`, `~/s2-tc-kubeconfig`) — the old shared
> `~/dpu-tc-kubeconfig` is silently overwritten by whichever bringup ran last.
> `$D` below = the handle for whichever server you're working on.

---

## Setup — one `$D` handle per DPU cluster (do this first)
```bash
for S in s4 s2; do   # regenerate per-server kubeconfigs (idempotent)
  kubectl get secret ${S}-dpu-cluster-admin-kubeconfig -n dpf-operator-system \
    -o jsonpath='{.data.admin\.conf}' | base64 -d > /home/dpu-vm/${S}-tc-kubeconfig
done
D="kubectl --kubeconfig /home/dpu-vm/s4-tc-kubeconfig"   # or s2- — absolute path, ~ won't expand in a var
echo "$D"                                                 # sanity: should print the kubectl line
```

## 1 · Is the fleet up?
```bash
./dpf/scripts/fleet_status.sh                               # ALL workers: DPU/cluster/node/HBN
./dpf/scripts/fleet_status.sh --frr                         # + FRR interface/VF counts (slower)
kubectl get dpfoperatorconfig -n dpf-operator-system        # operator: Ready=True
kubectl get dpu,dpucluster,tenantcontrolplane -n dpf-operator-system
./dpf/scripts/status_dpf.sh                                  # all-in-one DPF health
$D get --raw='/readyz'                                       # this DPU cluster API: prints "ok"
```

## 2 · Nodes & pods (DPU cluster)
```bash
$D get nodes -o wide                                         # <SERVER>-dpu  Ready
$D get pods -A -o wide                                       # every pod + node + IP
$D get pods -A | grep -vE 'Running|Completed'                # anything unhealthy
$D get pods -A -o wide --field-selector spec.nodeName=<SERVER>-dpu
$D describe node <SERVER>-dpu | sed -n '/Conditions/,/Events/p'
```

## 3 · HBN pod
```bash
$D get pod -n doca-hbn -o wide
POD=$($D get pod -n doca-hbn -o jsonpath='{.items[0].metadata.name}'); echo "POD=$POD"
$D logs -n doca-hbn "$POD"                                   # FRR / HBN logs
$D logs -n doca-hbn "$POD" -c init-sfs                       # init container (SF setup)
$D exec -it -n doca-hbn "$POD" -- supervisorctl status       # FRR daemon processes (zebra, bgpd…)
```

## 4 · FRR / zebra CLI — `vtysh`
`vtysh` is FRR's unified shell; **zebra**, bgpd, staticd, bfdd all answer through it.
```bash
# interactive:
$D exec -it -n doca-hbn "$POD" -- vtysh

# one-shot:
$D exec -n doca-hbn "$POD" -- vtysh -c "show interface brief"
$D exec -n doca-hbn "$POD" -- vtysh -c "show ip route"
```
Useful inside `vtysh`:
| Command | Shows |
|---|---|
| `show interface brief` | all interfaces (p0_if, pf0vfN_if…) + state + IP |
| `show ip route` | zebra's routing table (RIB) |
| `show running-config` | full FRR config |
| `show daemons` | which FRR daemons are running |
| `show bgp summary` | BGP neighbors (if BGP enabled) |
| `configure terminal` | enter config mode |

Bring an interface up (config mode):
```
configure terminal
 interface p0_if
  no shutdown
 exit
end
write memory
```

## 5 · NVUE (the other HBN CLI, same pod)
```bash
$D exec -it -n doca-hbn "$POD" -- nv config show
$D exec -it -n doca-hbn "$POD" -- nv show interface
```

## 6 · Host SR-IOV VFs (on the x86 host, NOT the DPF VM)
```bash
ssh aviz@<X86_HOST> 'ip -br link | grep -E "^vf[0-9]"'       # vf0..vf7 present + state
sudo ./dpf/scripts/setup_host_vfs.sh                         # (re)create + rename if missing
```

## 7 · Cross-subnet tunnel (only if DPF VM and BF3 are on different subnets)
```bash
./dpf/scripts/tunnel_dpf.sh --server <SERVER> status
./dpf/scripts/tunnel_dpf.sh --server <SERVER> start          # if down
```

## 8 · Visual stack map
```bash
./dpf/scripts/explain_stack.sh --server <SERVER>             # → ~/dpf_summary/dpf-stack-explained.html
./dpf/scripts/dump_cluster.sh                                # → ~/dpf_summary/cluster-dump.html
```

---

## Gotchas
- **`error: pod … must be specified`** → `$POD` is empty; re-run the `POD=$(...)` line (new shell loses it).
- **`error loading config … ~/...`** → never put `~` inside `$D`; use the absolute path `/home/dpu-vm/<server>-tc-kubeconfig`.
- **Commands hit the WRONG DPU** → you used the shared `~/dpu-tc-kubeconfig`, which the last bringup overwrote. Always use the per-server files (Setup section).
- **HBN pod re-stuck `Init:0/1` after deleting it** → SF netdevs lost their names; on the BF3: `sudo systemctl restart sfc.service` — **then always** `systemctl is-active kubelet || sudo systemctl start kubelet` (kubelet is coupled to sfc and can stay down).
- **A port passes no traffic** → check the pair flows: `sudo ovs-ofctl dump-flows br-hbn | grep -c priority=500` (24 on a full 12-port box) → `sudo systemctl restart sfc.service`. If host VFs were created after boot, one sfc restart wires them.
- **Performance expectations** → the data plane is **CPU-routed** (software) in this deployment — fine for all config/feature work, don't run throughput benchmarks. Eswitch offload arrives with the DPUService migration (README design note).
- **`kubectl: command not found` on the BF3** → the BF3 is a *worker* (kubelet + `crictl`, no `kubectl`). Run kubectl from the DPF VM; use `crictl` on the BF3.
- **SSH `REMOTE HOST IDENTIFICATION HAS CHANGED`** (after a reflash) → `ssh-keygen -R <BF3_OOB_IP>`.
- **Interfaces show `down`** → expected after a pod (re)start; bring up via `vtysh` config or NVUE.
