#!/usr/bin/env bash
# nvidia_debug_commands.sh — Quick reference for NVIDIA support call
# Run from DPF Operator VM (10.4.5.136)
# Usage: ./nvidia_debug_commands.sh [section]
# Sections: all, cluster, dpu, redfish, bmc, servicechainset, bf3, argocd

set -uo pipefail
KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
DPF_NS="dpf-operator-system"
DPU_KC="/tmp/dpu-tc-kubeconfig"
BMC_IP="10.20.13.250"
BMC_USER="root"
BMC_PASS="Aviz@AIF12345"
BF3_OOB="10.20.13.249"
BF3_PASS="Aviz@AIF12345"
KC="kubectl --kubeconfig ${KUBECONFIG}"
DKC="kubectl --kubeconfig ${DPU_KC}"

kube()  { kubectl --kubeconfig "${KUBECONFIG}" "$@"; }
dkube() { kubectl --kubeconfig "${DPU_KC}" "$@"; }
bmc()   { curl -sk -u "${BMC_USER}:${BMC_PASS}" "$@"; }

SECTION="${1:-all}"

# run TITLE CMD [ARGS...]  — prints title, the actual command, then the output
run() {
  local title="$1"; shift
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "  $title"
  echo "────────────────────────────────────────────────────────"
  # Print the actual command
  echo "  CMD: $*"
  echo "════════════════════════════════════════════════════════"
  eval "$@" 2>&1 || echo "(error or no output)"
  echo ""
}

# cmd TITLE "full command string" — for complex commands, shows and runs the string
cmd() {
  local title="$1"
  local command="$2"
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "  $title"
  echo "────────────────────────────────────────────────────────"
  echo "  CMD: $command"
  echo "════════════════════════════════════════════════════════"
  eval "$command" 2>&1 || echo "(error or no output)"
  echo ""
}

# ── SECTION: Cluster Overview ─────────────────────────────────────────────────
cluster() {
  run "k3s Management Cluster — Version" \
    kube version

  run "k3s Nodes" \
    kube get nodes -o wide

  run "DPF Operator Version (pod image)" \
    kube get pods -n "${DPF_NS}" dpf-operator-controller-manager-$(
      kube get pods -n "${DPF_NS}" --no-headers | grep dpf-operator-controller-manager | awk '{print $1}' | sed 's/dpf-operator-controller-manager-//'
    ) -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || \
    kube get pods -n "${DPF_NS}" --no-headers | grep dpf-operator-controller-manager | awk '{print $1}' | \
    xargs -I{} kube get pod {} -n "${DPF_NS}" -o jsonpath='{.spec.containers[0].image}'

  run "All DPF Pods Status" \
    kube get pods -n "${DPF_NS}" -o wide

  run "Kamaji Pods" \
    kube get pods -n kamaji-system -o wide
}

# ── SECTION: DPU Provisioning ─────────────────────────────────────────────────
dpu() {
  run "DPU CR Status" \
    kube get dpu -n "${DPF_NS}" -o wide

  cmd "DPU Conditions (full)" \
    "${KC} get dpu s4-dpu -n ${DPF_NS} -o jsonpath='{.status.conditions}' | python3 -m json.tool"

  cmd "DPU Full Status JSON" \
    "${KC} get dpu s4-dpu -n ${DPF_NS} -o jsonpath='{.status}' | python3 -m json.tool"

  run "DPU Describe" \
    kube describe dpu s4-dpu -n "${DPF_NS}"

  run "DPUDevice" \
    kube get dpudevice s4-bf3 -n "${DPF_NS}" -o yaml

  run "DPUNode" \
    kube get dpunode s4-node -n "${DPF_NS}" -o yaml

  run "DPUFlavor" \
    kube get dpuflavor bf3-base -n "${DPF_NS}" -o yaml

  run "DPFOperatorConfig" \
    kube get dpfoperatorconfig -n "${DPF_NS}" -o yaml

  run "BFB CR Status" \
    kube get bfb -n "${DPF_NS}" -o wide

  run "BFB PVC" \
    kube get pvc bfb-pvc -n "${DPF_NS}"

  cmd "DPF Provisioning Controller Logs (last 50 lines)" \
    "${KC} logs -n ${DPF_NS} \$(${KC} get pods -n ${DPF_NS} --no-headers | grep dpf-provisioning-controller | awk '{print \$1}') --tail=50"

  cmd "DPF Operator Controller Logs (last 50 lines)" \
    "${KC} logs -n ${DPF_NS} \$(${KC} get pods -n ${DPF_NS} --no-headers | grep dpf-operator-controller-manager | awk '{print \$1}') --tail=50"
}

# ── SECTION: Redfish Issue ────────────────────────────────────────────────────
redfish() {
  run "Redfish Version" \
    bmc "https://${BMC_IP}/redfish/v1/" | python3 -m json.tool | grep -E "RedfishVersion|Name|Description"

  run "BMC Firmware Inventory" \
    bmc "https://${BMC_IP}/redfish/v1/UpdateService/FirmwareInventory" | python3 -m json.tool

  run "DPU OS Firmware Version (currently installed)" \
    bmc "https://${BMC_IP}/redfish/v1/UpdateService/FirmwareInventory/DPU_OS" | python3 -m json.tool

  run "BMC Firmware Version" \
    bmc "https://${BMC_IP}/redfish/v1/UpdateService/FirmwareInventory/BMC_Firmware" | python3 -m json.tool

  run "UpdateService Capabilities" \
    bmc "https://${BMC_IP}/redfish/v1/UpdateService" | python3 -m json.tool

  run "PersistentStorage (OEM staging area)" \
    bmc "https://${BMC_IP}/redfish/v1/Systems/Bluefield/Oem/Nvidia/PersistentStorage" | python3 -m json.tool

  run "FirmwarePackages in staging" \
    bmc "https://${BMC_IP}/redfish/v1/Systems/Bluefield/Oem/Nvidia/PersistentStorage/FirmwarePackages" | python3 -m json.tool

  run "Active Redfish Tasks" \
    bmc "https://${BMC_IP}/redfish/v1/TaskService/Tasks" | python3 -m json.tool

  run "Redfish Event Log (last entries)" \
    bmc "https://${BMC_IP}/redfish/v1/Systems/Bluefield/LogServices/EventLog/Entries" | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
for e in d.get('Members',[])[-10:]:
    print(f\"{e.get('Created','')} [{e.get('Severity','')}] {e.get('Message','')}\")" 2>/dev/null || echo "(no entries)"

  cmd "BMC Disk Space (proves storage limitation)" \
    "sshpass -p '${BMC_PASS}' ssh -o StrictHostKeyChecking=no ${BMC_USER}@${BMC_IP} 'df -h'"

  echo ""
  echo "  ── Reproduce the Redfish 404 error ──────────────────"
  echo "  To trigger the FailToInstall error live:"
  echo ""
  echo "    kubectl delete dpu s4-dpu -n ${DPF_NS}"
  echo "    sed -e 's|BF3_SERIAL|MT2437600HGY|g' -e 's|BF3_BMC_IP|${BMC_IP}|g' \\"
  echo "      ~/hbn/dpf/manifests/07-dpu.yaml | kubectl apply -f -"
  echo "    kubectl get dpu s4-dpu -n ${DPF_NS} -w"
  echo ""
  echo "  Then capture the error:"
  echo "    kubectl get dpu s4-dpu -n ${DPF_NS} -o jsonpath='{.status.conditions}' | python3 -m json.tool"
  echo ""
}

# ── SECTION: BMC Info ─────────────────────────────────────────────────────────
bmc_info() {
  run "BMC System Info" \
    bmc "https://${BMC_IP}/redfish/v1/Systems/Bluefield" | python3 -m json.tool | \
    grep -E "Model|SerialNumber|BiosVersion|Status|MemorySummary|ProcessorSummary" | head -20

  run "BMC Manager Info" \
    bmc "https://${BMC_IP}/redfish/v1/Managers/Bmc" | python3 -m json.tool | \
    grep -E "FirmwareVersion|Model|Status|DateTime" | head -10

  run "Network Interfaces on BMC" \
    bmc "https://${BMC_IP}/redfish/v1/Managers/Bmc/EthernetInterfaces" | python3 -m json.tool
}

# ── SECTION: servicechainset-controller Crash ─────────────────────────────────
servicechainset() {
  run "servicechainset-controller Status" \
    kube get pods -n "${DPF_NS}" | grep servicechainset

  cmd "servicechainset-controller Logs (crash reason)" \
    "${KC} logs -n ${DPF_NS} \$(${KC} get pods -n ${DPF_NS} --no-headers | grep servicechainset-controller | awk '{print \$1}') --tail=100"

  cmd "servicechainset-controller Previous Crash Logs" \
    "${KC} logs -n ${DPF_NS} \$(${KC} get pods -n ${DPF_NS} --no-headers | grep servicechainset-controller | awk '{print \$1}') --previous --tail=50 || echo '(no previous logs)'"

  run "API Group Discovery Check" \
    kube get --raw /apis/svc.dpu.nvidia.com/v1alpha1 | python3 -m json.tool | grep '"name"'

  run "k8s Server Version (compatibility check)" \
    kube version

  cmd "servicechainset-controller Image" \
    "${KC} get pods -n ${DPF_NS} --no-headers | grep servicechainset-controller | awk '{print \$1}' | xargs -I{} ${KC} get pod {} -n ${DPF_NS} -o jsonpath='{.spec.containers[0].image}'"

  run "DPUServices Status (all pending due to crash)" \
    kube get dpuservice -n "${DPF_NS}"

  run "ServiceChainSets" \
    kube get servicechainsets -n "${DPF_NS}" 2>/dev/null || echo "(none)"

  run "ServiceInterfaceSets" \
    kube get serviceinterfacesets -n "${DPF_NS}" 2>/dev/null || echo "(none)"
}

# ── SECTION: BF3 TenantControlPlane ──────────────────────────────────────────
bf3() {
  # Refresh kubeconfig
  kube get secret s4-dpu-cluster-admin-kubeconfig -n "${DPF_NS}" \
    -o jsonpath='{.data.admin\.conf}' | base64 -d > "${DPU_KC}" 2>/dev/null || true

  run "BF3 Node Status" \
    dkube get nodes -o wide

  run "BF3 Node Labels" \
    dkube get node s4-dpu --show-labels

  run "BF3 All Pods" \
    dkube get pods -A -o wide

  run "BF3 CoreDNS Status (stuck = no CNI)" \
    dkube describe pods -n kube-system -l k8s-app=kube-dns | grep -E "Status:|Events:|Warning|Error|ContainerCreating" | head -20

  cmd "BF3 kubelet Status (via SSH)" \
    "sshpass -p '${BF3_PASS}' ssh -o StrictHostKeyChecking=no ubuntu@${BF3_OOB} 'systemctl is-active kubelet && systemctl status kubelet --no-pager | head -10'"

  cmd "BF3 OS Version" \
    "sshpass -p '${BF3_PASS}' ssh -o StrictHostKeyChecking=no ubuntu@${BF3_OOB} 'cat /etc/os-release | grep -E NAME\|VERSION'"

  cmd "BF3 Network Interfaces" \
    "sshpass -p '${BF3_PASS}' ssh -o StrictHostKeyChecking=no ubuntu@${BF3_OOB} 'ip link show'"

  cmd "BF3 CNI Config (empty = not installed)" \
    "sshpass -p '${BF3_PASS}' ssh -o StrictHostKeyChecking=no ubuntu@${BF3_OOB} 'ls -la /etc/cni/net.d/ 2>/dev/null || echo /etc/cni/net.d/ does not exist'"

  cmd "BF3 OVS Status" \
    "sshpass -p '${BF3_PASS}' ssh -o StrictHostKeyChecking=no ubuntu@${BF3_OOB} 'sudo ovs-vsctl show 2>/dev/null || echo OVS not running'"

  run "DPUCluster Status" \
    kube get dpucluster s4-dpu-cluster -n "${DPF_NS}" -o yaml | grep -A10 "status:"
}

# ── SECTION: ArgoCD ───────────────────────────────────────────────────────────
argocd() {
  run "ArgoCD Applications" \
    kube get applications -A

  run "ArgoCD AppProjects" \
    kube get appproject -n argocd

  run "ArgoCD ConfigMap (namespace config)" \
    kube get configmap argocd-cmd-params-cm -n argocd -o jsonpath='{.data}' | python3 -m json.tool
}

# ── Run selected sections ─────────────────────────────────────────────────────
case "${SECTION}" in
  cluster)       cluster ;;
  dpu)           dpu ;;
  redfish)       redfish ;;
  bmc)           bmc_info ;;
  servicechainset) servicechainset ;;
  bf3)           bf3 ;;
  argocd)        argocd ;;
  all)
    cluster
    dpu
    redfish
    bmc_info
    servicechainset
    bf3
    argocd
    ;;
  *)
    echo "Usage: $0 [all|cluster|dpu|redfish|bmc|servicechainset|bf3|argocd]"
    echo ""
    echo "  all             — run everything (full dump)"
    echo "  cluster         — k3s version, nodes, pod status"
    echo "  dpu             — DPU CR, conditions, provisioning logs"
    echo "  redfish         — Redfish API, firmware inventory, storage, reproduce error"
    echo "  bmc             — BMC system info, firmware version"
    echo "  servicechainset — crash logs, API group check, k8s version"
    echo "  bf3             — BF3 node, pods, kubelet, CNI, OVS"
    echo "  argocd          — ArgoCD apps, projects, config"
    exit 1
    ;;
esac

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Done. Share this output with NVIDIA support."
echo "════════════════════════════════════════════════════════"
echo ""
