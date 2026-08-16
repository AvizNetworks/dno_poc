#!/usr/bin/env bash
# bringup_hbn_bf3.sh — Idempotent HBN bringup for BlueField-3 DPU (DOCA 3.3.0)
# Run on BF3 with sudo: sudo ./bringup_hbn_bf3.sh [options]
#
# PREFLIGHT-FIRST: every prerequisite is validated READ-ONLY before any mutation.
#   --check     preflight only, exit 0 = ready / 1 = blockers. Nothing is changed.
#   --dry-run   preflight + print what every step WOULD do. Nothing is changed.
# A normal run refuses to mutate anything until preflight passes.
set -euo pipefail

# ─── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MLX_REF_DIR="${REPO_DIR}/mellanox"
DOCA_SCRIPTS_DIR="${REPO_DIR}/doca_hbn_v3.3.0/scripts/3.3.0"
DOCA_CONFIGS_DIR="${REPO_DIR}/doca_hbn_v3.3.0/configs/3.3.0"
BF3_PCI0="0000:03:00.0"
BF3_PCI1="0000:03:00.1"
HBN_POD_SPEC="/etc/kubelet.d/doca_hbn.yaml"
MLX_SF_CONF="/etc/mellanox/mlnx-sf.conf"
MLNX_BF_CONF="/etc/mellanox/mlnx-bf.conf"
HBN_CONF="/etc/mellanox/hbn.conf"
SFC_CONF="/etc/mellanox/sfc.conf"
SFC_OPT="/opt/mellanox/sfc-hbn"
SFC_LINK="/opt/mellanox/sfc"
AUXDEV=/lib/udev/auxdev-sf-netdev-rename
SFREP=/lib/udev/sf-rep-netdev-rename
CNI_CONFLIST="/etc/cni/net.d/10-containerd-net-br-mgmt.conflist"
HBN_LOCAL_REPO="/var/hbn-repo-aarch64-ubuntu2404-local"
LOG_DIR="/var/log/doca/hbn"
WAIT_TIMEOUT=300
ENABLE_BGP=false
REST_USER="nvidia"
REST_PASS="nvidia"
SKIP_DNS_FIX=false
CHECK_ONLY=false
DRY_RUN=false
P0_VFS=0
P1_VFS=0
# VF SubFunction numbering — AUTHORITATIVE scheme from /opt/mellanox/sfc-hbn/install.sh:
# ECPF0 VFs (pf0vfN) use sfnum 1001+N; ECPF1 VFs (pf1vfN) use sfnum 1257+N.
# The patched udev namers map ONLY these ranges → pf0vfN_if / pf1vfN_if (+ _if_r reps).
# Any other scheme (e.g. the old hand-rolled 4-11) silently breaks VF naming.
ECPF0_VF_SF_BASE=1001
ECPF1_VF_SF_BASE=1257

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  --check              PREFLIGHT ONLY: validate every prerequisite read-only and
                       print an exact fix for each failure. Exit 0 = ready to run.
                       Nothing on the system is changed.
  --dry-run            Run preflight, then print what every step would do
                       without applying anything.
  --enable-bgp         Enable bgpd in FRR daemons (default: off)
  --rest-user <user>   REST API username (default: nvidia)
  --rest-pass <pass>   REST API password (default: nvidia)
  --skip-dns-fix       Skip adding nameserver 8.8.8.8 to resolv.conf
  --vfs <n>            Total VFs split equally across both PFs (even number;
                       e.g. --vfs 8 -> 4 per PF). Requires host SR-IOV VFs FIRST.
  --p0-vfs <n>         VFs on PF0 only
  --p1-vfs <n>         VFs on PF1 only
  -h, --help           Show this help

Examples:
  sudo $0 --check                # validate everything, change nothing
  sudo $0                        # core bringup (p0/p1/pf0hpf/pf1hpf)
  sudo $0 --enable-bgp --rest-user nvidia --rest-pass MyPass123
  sudo $0 --vfs 8                # AFTER setup_host_vfs_standalone.sh on the x86 host
EOF
  exit 0
}

# ─── Arg parsing ─────────────────────────────────────────────────────────────
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
while [[ $# -gt 0 ]]; do
  case $1 in
    --check|--preflight) CHECK_ONLY=true ;;
    --dry-run)          DRY_RUN=true ;;
    --enable-bgp)       ENABLE_BGP=true ;;
    --rest-user)        REST_USER="${2:?--rest-user needs a value}"; shift ;;
    --rest-pass)        REST_PASS="${2:?--rest-pass needs a value}"; shift ;;
    --skip-dns-fix)     SKIP_DNS_FIX=true ;;
    --vfs)              is_uint "${2:-}" || fail "--vfs needs a number"
                        [[ $(( $2 % 2 )) -eq 0 ]] || fail "--vfs must be even (split across 2 PFs); got $2"
                        P0_VFS=$(( $2 / 2 )); P1_VFS=$(( $2 / 2 )); shift ;;
    --p0-vfs)           is_uint "${2:-}" || fail "--p0-vfs needs a number"; P0_VFS="$2"; shift ;;
    --p1-vfs)           is_uint "${2:-}" || fail "--p1-vfs needs a number"; P1_VFS="$2"; shift ;;
    -h|--help)          usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done
TOTAL_VFS=$((P0_VFS + P1_VFS))

[[ $EUID -ne 0 ]] && fail "This script must be run as root (sudo)"

# ─── Shared read-only probes (used by preflight AND apply) ───────────────────

# Runtime units are VRF-templated on BFB (kubelet@mgmt) or plain (kubelet).
detect_unit() {  # $1 = base name -> echoes the unit that is active or enabled
  local base="$1" u
  for u in "${base}@mgmt.service" "${base}.service"; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then echo "$u"; return 0; fi
  done
  for u in "${base}@mgmt.service" "${base}.service"; do
    case "$(systemctl is-enabled "$u" 2>/dev/null || true)" in
      enabled|indirect|static) echo "$u"; return 0 ;;
    esac
  done
  return 1
}

vf_rep_present() {  # $1=pfX  $2=index  -> 0 if the VF eswitch rep netdev exists
  local want="$1vf$2" n ppn
  for n in /sys/class/net/*; do
    ppn=$(cat "$n/phys_port_name" 2>/dev/null) || continue
    # kernel names VF reps c1pf0vf0 / pf0vf0 depending on version — match the tail
    [[ "$ppn" == "$want" || "$ppn" == *"$want" ]] && return 0
  done
  return 1
}

missing_vf_reps() {  # echoes space-separated list of missing pfXvfN eswitch reps
  local i out=()
  for ((i=0; i<P0_VFS; i++)); do vf_rep_present pf0 "$i" || out+=("pf0vf${i}"); done
  for ((i=0; i<P1_VFS; i++)); do vf_rep_present pf1 "$i" || out+=("pf1vf${i}"); done
  echo "${out[*]:-}"
}

stale_legacy_vf_sfs() {  # old hand-rolled sfnum 4-11 scheme — namers can't map it
  devlink port show 2>/dev/null | grep -oE "sfnum (4|5|6|7|8|9|10|11)( |$)" \
    | awk '{print $2}' | sort -un | tr '\n' ' ' || true
}

sfc_ofport_stale() {  # 0 if sfc.service failed with the stale-ofport_request signature
  systemctl is-failed --quiet sfc.service 2>/dev/null || return 1
  journalctl -u sfc.service -n 80 --no-pager 2>/dev/null \
    | grep -q "does not have ofport" || return 1
  return 0
}

detect_port_macs() {  # sets P0_MAC / P1_MAC from phys_port_name (read-only)
  P0_MAC=""; P1_MAC=""
  local NDEV PNAME ADDR
  for NDEV in /sys/class/net/*/; do
    PNAME=$(cat "${NDEV}phys_port_name" 2>/dev/null || echo "")
    ADDR=$(cat "${NDEV}address" 2>/dev/null || echo "")
    if [[ "$PNAME" == "p0" ]]; then P0_MAC="$ADDR"; fi
    if [[ "$PNAME" == "p1" ]]; then P1_MAC="$ADDR"; fi
  done
  return 0
}

# Reason string if mlnx-sf.conf must be regenerated; empty = OK as-is.
sf_conf_regen_reason() {
  [[ -f "${MLX_SF_CONF}" ]] || { echo "missing"; return; }
  local _SFNUM i
  for _SFNUM in 2 3 1514 1515; do
    grep -q -- "--sfnum ${_SFNUM} " "${MLX_SF_CONF}" 2>/dev/null \
      || { echo "core sfnums (2,3,1514,1515) incomplete"; return; }
  done
  if [[ $TOTAL_VFS -gt 0 ]]; then
    for ((i=0; i<P0_VFS; i++)); do
      grep -q -- "--sfnum $((ECPF0_VF_SF_BASE+i)) " "${MLX_SF_CONF}" 2>/dev/null \
        || { echo "VF sfnums (${ECPF0_VF_SF_BASE}+/${ECPF1_VF_SF_BASE}+) missing"; return; }
    done
    for ((i=0; i<P1_VFS; i++)); do
      grep -q -- "--sfnum $((ECPF1_VF_SF_BASE+i)) " "${MLX_SF_CONF}" 2>/dev/null \
        || { echo "VF sfnums (${ECPF0_VF_SF_BASE}+/${ECPF1_VF_SF_BASE}+) missing"; return; }
    done
  fi
  if { [[ -n "${P0_MAC}" ]] && grep -qi "${P0_MAC}" "${MLX_SF_CONF}"; } || \
     { [[ -n "${P1_MAC}" ]] && grep -qi "${P1_MAC}" "${MLX_SF_CONF}"; }; then
    echo "contains a physical port MAC (mlx5 then skips SF netdevs)"; return
  fi
  echo ""
}

# ═══ PREFLIGHT — read-only validation of EVERY prerequisite ═══════════════════
# Runs before ANY mutation. Each failure states WHAT is wrong and the EXACT fix.
# [ OK ] ready (or the apply phase fixes it automatically — "will ...")
# [WARN] non-blocking, degraded feature
# [FAIL] blocker — nothing will be changed until it is fixed
PF_FAIL=0; PF_WARN=0
pf_ok()   { echo -e "  ${GREEN}[ OK ]${NC} $*"; }
pf_warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; PF_WARN=$((PF_WARN+1)); }
pf_fail() { echo -e "  ${RED}[FAIL]${NC} $*"; PF_FAIL=$((PF_FAIL+1)); }
pf_fix()  { echo -e "         ${CYAN}fix:${NC} $*"; }

preflight() {
  local esw0 esw1 reason legacy missing ssp_deb ib_devs
  echo ""
  echo -e "${CYAN}══ PREFLIGHT (read-only — nothing is changed) ═══════════════════${NC}"

  # 1. Platform: really a BF3 running arm64
  if [[ "$(uname -m)" == "aarch64" && -e "/sys/bus/pci/devices/${BF3_PCI0}" ]]; then
    pf_ok "platform: aarch64 BlueField, PF0 at ${BF3_PCI0}"
  else
    pf_fail "not a BlueField-3 ARM environment (arch=$(uname -m), ${BF3_PCI0} $( [[ -e /sys/bus/pci/devices/${BF3_PCI0} ]] && echo present || echo absent ))"
    pf_fix "run this script ON the BF3 (SSH to its OOB IP), not on the x86 host"
  fi

  # 2. Repo layout (script deploys reference configs from the repo)
  if [[ -f "${MLX_REF_DIR}/hbn.conf" && -f "${MLX_REF_DIR}/sfc.conf" ]]; then
    pf_ok "repo reference configs present: ${MLX_REF_DIR}"
  else
    pf_fail "reference configs missing under ${MLX_REF_DIR}"
    pf_fix "copy the FULL repo to the BF3 (mellanox/ + doca_hbn_v3.3.0/ + scripts/), then re-run"
  fi
  if [[ -f "${HBN_POD_SPEC}" || -f "${DOCA_CONFIGS_DIR}/doca_hbn.yaml" || -f "${MLX_REF_DIR}/doca_hbn.yaml" ]]; then
    pf_ok "doca_hbn.yaml pod spec available"
  else
    pf_fail "doca_hbn.yaml not found (neither installed at ${HBN_POD_SPEC} nor in repo)"
    pf_fix "restore ${DOCA_CONFIGS_DIR}/doca_hbn.yaml from the repo"
  fi
  if [[ -d "${DOCA_SCRIPTS_DIR}" ]]; then
    pf_ok "DOCA REST scripts present (encrypt_password.py / enable-rest-api.py)"
  else
    pf_warn "DOCA scripts missing at ${DOCA_SCRIPTS_DIR} — REST API setup (step 13) will be skipped"
  fi

  # 3. Link type: IB mode cannot be fixed from the ARM — needs a true cold power cycle
  esw0=$(devlink dev eswitch show "pci/${BF3_PCI0}" 2>&1 || true)
  esw1=$(devlink dev eswitch show "pci/${BF3_PCI1}" 2>&1 || true)
  ib_devs=""
  for _ib in /sys/class/net/ib*; do [[ -e "$_ib" ]] && ib_devs+="$(basename "$_ib") "; done
  if echo "${esw0}" | grep -qi "not supported" && [[ -n "${ib_devs}" ]]; then
    pf_fail "BF3 is in INFINIBAND mode (${ib_devs}found, eswitch 'Operation not supported')"
    pf_fix "LINK_TYPE=ETH only commits on a TRUE COLD power cycle (PCIe slot power must drop):"
    pf_fix "  1) verify staged: mlxconfig -d ${BF3_PCI0} -e q LINK_TYPE_P1 LINK_TYPE_P2  (Next Boot must be ETH(2))"
    pf_fix "     if not staged: mlxconfig -d ${BF3_PCI0} set LINK_TYPE_P1=2 LINK_TYPE_P2=2"
    pf_fix "  2) on the X86 HOST: sudo ipmitool chassis power cycle"
    pf_fix "  NOTE: ARM 'reboot', 'chassis power reset', BMC obmcutil chassisoff/on and mlxfwreset do NOT commit it"
  else
    for _pci_out in "0:${esw0}" "1:${esw1}"; do
      if echo "${_pci_out#*:}" | grep -q "mode switchdev"; then
        pf_ok "eswitch PF${_pci_out%%:*}: switchdev mode"
      else
        pf_fail "eswitch PF${_pci_out%%:*} NOT in switchdev mode"
        pf_fix "devlink dev eswitch set pci/$( [[ ${_pci_out%%:*} == 0 ]] && echo "${BF3_PCI0}" || echo "${BF3_PCI1}" ) mode switchdev"
      fi
    done
  fi

  # 3b. Eswitch MULTIPORT readiness. ALL HBN SFs are hosted on PF0, so any traffic
  #     on the p1 uplink must cross eswitches (PF1 wire -> PF0 SF). That requires
  #     esw_multiport=true, which the firmware only supports when nvconfig
  #     LAG_RESOURCE_ALLOCATION=PRE_ALLOCATION(1) — and that value ONLY truly
  #     applies at a TRUE COLD power cycle (PCIe slot power drop). Without it,
  #     p1 blackholes unicast while everything config-plane looks healthy.
  local lag_out lag_cur lag_next mp_pci mp_val lag_fail=0 lag_staged=0
  if command -v mlxconfig >/dev/null 2>&1; then
    for mp_pci in "${BF3_PCI0}" "${BF3_PCI1}"; do
      # -e prints Default/Current/Next-Boot; plain 'q' prints ONLY Next Boot,
      # which is exactly the cosmetic value we must not trust.
      lag_out=$(mlxconfig -d "${mp_pci}" -e q LAG_RESOURCE_ALLOCATION 2>/dev/null \
        | awk '/LAG_RESOURCE_ALLOCATION/{print $(NF-1), $NF}' || true)
      lag_cur="${lag_out% *}"; lag_next="${lag_out##* }"
      if [[ -z "${lag_out}" ]]; then
        pf_warn "could not query LAG_RESOURCE_ALLOCATION on ${mp_pci} — verify manually: mlxconfig -d ${mp_pci} -e q LAG_RESOURCE_ALLOCATION"
      elif [[ "${lag_cur}" == *"(1)"* ]]; then
        pf_ok "LAG_RESOURCE_ALLOCATION current=PRE_ALLOCATION(1) (${mp_pci})"
      elif [[ "${lag_next}" == *"(1)"* ]]; then
        pf_fail "LAG_RESOURCE_ALLOCATION staged for next boot but NOT applied (${mp_pci}: current=${lag_cur})"
        lag_staged=1; lag_fail=1
      else
        pf_fail "LAG_RESOURCE_ALLOCATION is ${lag_cur} (${mp_pci}) — p1 uplink CANNOT reach the PF0-hosted HBN SFs"
        lag_fail=1
      fi
    done
    if [[ ${lag_fail} -eq 1 ]]; then
      [[ ${lag_staged} -eq 0 ]] && \
        pf_fix "stage it now (safe, takes effect only at power cycle): mlxconfig -d ${BF3_PCI0} set LAG_RESOURCE_ALLOCATION=1 && mlxconfig -d ${BF3_PCI1} set LAG_RESOURCE_ALLOCATION=1"
      pf_fix "then COLD power cycle from the X86 HOST: sudo ipmitool chassis power cycle"
      pf_fix "ARM 'reboot' does NOT commit it. Do NOT trust a live 'Current=1' after a"
      pf_fix "runtime set — the LAG pool only allocates at firmware cold init (half-applied"
      pf_fix "state passes multicast but blackholes unicast BOTH directions on p1)."
    fi
  else
    pf_warn "mlxconfig not found — cannot verify LAG_RESOURCE_ALLOCATION; p1 uplink may blackhole (install mstflint or verify from the x86 host)"
  fi
  mp_val=$(devlink dev param show "pci/${BF3_PCI0}" name esw_multiport 2>/dev/null \
    | awk '/cmode/{print $NF}' || true)
  if [[ "${mp_val}" == "true" ]]; then
    pf_ok "eswitch multiport active (esw_multiport=true)"
  elif [[ ${lag_fail} -eq 0 ]]; then
    pf_ok "esw_multiport currently '${mp_val:-unsupported}' — will enable (devlink runtime param + mlnx-bf.conf)"
  fi
  if grep -q '^ENABLE_ESWITCH_MULTIPORT="yes"' "${MLNX_BF_CONF}" 2>/dev/null; then
    pf_ok "mlnx-bf.conf: ENABLE_ESWITCH_MULTIPORT=\"yes\" (re-enabled every boot)"
  else
    pf_ok "mlnx-bf.conf missing ENABLE_ESWITCH_MULTIPORT=\"yes\" — will set it (else multiport is lost on reboot)"
  fi

  # 4. sfc-hbn payload + service + /opt/mellanox/sfc path (sfc.service runs sfc/sfc.sh)
  if [[ -x "${SFC_OPT}/sfc.sh" || -x "${SFC_LINK}/sfc.sh" ]]; then
    pf_ok "sfc-hbn payload present (sfc.sh)"
  else
    pf_fail "sfc-hbn payload missing (no ${SFC_OPT}/sfc.sh)"
    pf_fix "install OFFLINE from the on-DPU repo: sudo apt-get install -y sfc-hbn  (sources ${HBN_LOCAL_REPO})"
    pf_fix "do NOT run ${SFC_OPT}/install.sh — it reconfigures mgmt-VRF/SSH and can drop your OOB session"
  fi
  if systemctl cat sfc.service &>/dev/null; then
    pf_ok "sfc.service registered with systemd"
  elif [[ -f "${SFC_OPT}/sfc.service" ]]; then
    pf_ok "sfc.service not registered — will install it OFFLINE from ${SFC_OPT} (no install.sh)"
  else
    pf_fail "sfc.service neither registered nor available at ${SFC_OPT}/sfc.service"
    pf_fix "install sfc-hbn first (see above), then re-run"
  fi
  if [[ -x "${SFC_LINK}/sfc.sh" ]]; then
    pf_ok "${SFC_LINK}/sfc.sh present (sfc.service ExecStartPre path)"
  elif [[ -x "${SFC_OPT}/sfc.sh" ]]; then
    pf_ok "${SFC_LINK} missing — will symlink it to ${SFC_OPT}"
  fi

  # 5. sfc-state-propagation (SF link-state daemon; install.sh normally installs it)
  if dpkg -s sfc-state-propagation &>/dev/null; then
    pf_ok "sfc-state-propagation installed"
  else
    ssp_deb=$(find "${HBN_LOCAL_REPO}" -maxdepth 1 -name 'sfc-state-propagation_*_arm64.deb' 2>/dev/null | head -1 || true)
    if [[ -n "${ssp_deb}" ]]; then
      pf_ok "sfc-state-propagation not installed — will install OFFLINE from ${ssp_deb##*/}"
    else
      pf_warn "sfc-state-propagation not installed and no .deb in ${HBN_LOCAL_REPO} — SF link state won't propagate"
    fi
  fi

  # 6. udev SF namers (stock versions emit enp3s0f0sN names -> init-sfs waits forever)
  local namer
  for namer in "${AUXDEV}" "${SFREP}"; do
    if [[ ! -f "${namer}" ]]; then
      pf_fail "udev namer missing: ${namer}"
      pf_fix "reinstall the mlnx-ofed/sfc udev package, or restore from a working BF3"
    elif grep -q 'source /etc/mellanox/sfc.conf' "${namer}"; then
      pf_ok "udev namer patched (HBN sfnum map): ${namer##*/}"
    else
      pf_ok "udev namer is stock — will patch ${namer##*/} (sfnum -> p0_if/pf0vfN_if map, backup kept)"
    fi
  done

  # 7. Container runtime + kubelet (static pod host)
  if CONTAINERD_UNIT=$(detect_unit containerd); then
    if systemctl is-active --quiet "${CONTAINERD_UNIT}"; then
      pf_ok "container runtime active: ${CONTAINERD_UNIT}"
    else
      pf_ok "container runtime ${CONTAINERD_UNIT} inactive — will start it"
    fi
  else
    pf_fail "no containerd unit found (containerd@mgmt/containerd)"
    pf_fix "this BFB image is missing the container runtime — reflash with the validated bundle"
  fi
  if KUBELET_UNIT=$(detect_unit kubelet); then
    if systemctl is-active --quiet "${KUBELET_UNIT}"; then
      pf_ok "kubelet active: ${KUBELET_UNIT}"
    else
      pf_ok "kubelet ${KUBELET_UNIT} inactive — will start it"
    fi
  else
    pf_fail "no kubelet unit found (kubelet@mgmt/kubelet)"
    pf_fix "this BFB image is missing kubelet — reflash with the validated bundle"
  fi

  # 8. doca_hbn container image — the customer environment is OFFLINE
  if crictl images 2>/dev/null | grep -qE "doca_hbn|doca-hbn"; then
    pf_ok "doca_hbn image present in containerd"
  elif ! systemctl is-active --quiet "${CONTAINERD_UNIT:-containerd.service}" 2>/dev/null; then
    pf_warn "image check deferred (runtime not running) — if missing, import OFFLINE:"
    pf_fix "sudo ctr -n k8s.io images import /path/to/doca_hbn_3.3.0-doca3.3.0.tar"
  else
    pf_fail "doca_hbn image NOT in containerd (offline environment — a pull would fail)"
    pf_fix "import it OFFLINE: sudo ctr -n k8s.io images import /path/to/doca_hbn_3.3.0-doca3.3.0.tar"
    pf_fix "(create the tar on a connected machine: docker save nvcr.io/nvidia/doca/doca_hbn:3.3.0-doca3.3.0 -o doca_hbn_3.3.0-doca3.3.0.tar)"
  fi

  # 9. Hugepages (OVS-DPDK needs 1600 x 2MB)
  local hp_now mem_avail_kb
  hp_now=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || echo 0)
  if [[ ${hp_now} -ge 1600 ]]; then
    pf_ok "hugepages: ${hp_now} x 2MB already allocated"
  else
    mem_avail_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    if [[ ${mem_avail_kb} -ge 3500000 ]]; then
      pf_ok "hugepages: ${hp_now} allocated — will allocate 1600 x 2MB (persisted via systemd unit)"
    else
      pf_fail "not enough free memory for 1600 x 2MB hugepages (MemAvailable=$((mem_avail_kb/1024))MB, need ~3500MB)"
      pf_fix "free memory (stop large processes) or reboot the BF3, then re-run"
    fi
  fi

  # 10. CNI conflist (init-sfs reads it to set up the container mgmt VRF)
  if [[ -f "${CNI_CONFLIST}" ]]; then
    pf_ok "CNI conflist present: ${CNI_CONFLIST##*/}"
  else
    pf_ok "CNI conflist missing — will install the validated br-mgmt template"
  fi

  # 11. VF mode gating: host SR-IOV VFs MUST exist first (they create the pf0vfN
  #     eswitch reps that sfc.conf/br-hbn map). Without them sfc.service fails.
  if [[ ${TOTAL_VFS} -gt 0 ]]; then
    missing=$(missing_vf_reps)
    if [[ -z "${missing}" ]]; then
      pf_ok "VF eswitch reps present for all ${TOTAL_VFS} VFs (host SR-IOV VFs are up)"
    else
      pf_fail "VF eswitch reps missing on the BF3: ${missing}"
      pf_fix "host VFs must be created FIRST — on the X86 HOST run:"
      pf_fix "  sudo ./scripts/setup_host_vfs_standalone.sh   # 4 VFs/PF + reboot persistence"
      pf_fix "then re-run: sudo $0 --vfs ${TOTAL_VFS}"
      pf_fix "(if the host PF netdev is missing after a BF3 reflash, REBOOT the x86 host first)"
    fi
    legacy=$(stale_legacy_vf_sfs)
    if [[ -n "${legacy}" ]]; then
      pf_ok "stale legacy VF SFs found (sfnum ${legacy}— old 4-11 scheme) — will delete and recreate as ${ECPF0_VF_SF_BASE}+/${ECPF1_VF_SF_BASE}+"
    fi
  else
    legacy=$(stale_legacy_vf_sfs)
    [[ -n "${legacy}" ]] && pf_warn "legacy-scheme SFs present (sfnum ${legacy}) — harmless without --vfs, but run --vfs to clean them up"
  fi

  # 12. Stale br-hbn OVS DB (survives reboot; classic cause: hand-run ovs-vsctl add-port)
  if sfc_ofport_stale; then
    pf_ok "sfc.service failed with stale ofport_request — will rebuild br-hbn cleanly (del-br + restart sfc; NEVER per-port edits)"
  fi

  # 13. mlnx-sf.conf sanity
  detect_port_macs
  reason=$(sf_conf_regen_reason)
  if [[ -z "${reason}" ]]; then
    pf_ok "mlnx-sf.conf: sfnums and MACs OK"
  else
    pf_ok "mlnx-sf.conf ${reason} — will regenerate (core 2,3,1514,1515 + ${TOTAL_VFS} VF SFs)"
  fi
  [[ -z "${P0_MAC}" ]] && pf_warn "could not detect p0 physical MAC — generated SF MACs fall back to fixed LA range"

  # 14. Python deps for REST persistence (step 13)
  if python3 -c "import cryptography, yaml" 2>/dev/null; then
    pf_ok "python3 cryptography/yaml available (REST password persistence)"
  else
    pf_warn "python3-cryptography/python3-yaml missing — will try offline apt; REST password may not persist across container restarts"
  fi

  # 15. DNS (informational only — bringup itself needs NO internet)
  if grep -qE "^nameserver " /etc/resolv.conf 2>/dev/null; then
    pf_ok "resolv.conf has a nameserver (not required for offline bringup)"
  else
    pf_warn "no nameserver configured — fine for offline bringup; --skip-dns-fix to keep it that way"
  fi

  echo ""
  if [[ ${PF_FAIL} -gt 0 ]]; then
    echo -e "  ${RED}NOT ready${NC} — ${PF_FAIL} blocker(s), ${PF_WARN} warning(s). Fix the [FAIL] items above and re-run: $0 --check"
  else
    echo -e "  ${GREEN}READY${NC} — 0 blockers, ${PF_WARN} warning(s)."
  fi
  echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
  echo ""
}

print_dry_run_plan() {
  echo -e "${CYAN}── DRY RUN — the steps a real run would execute ──────────────────${NC}"
  cat <<EOF
  Step  0/14  Host prep (offline, NO install.sh): register sfc.service, symlink
              ${SFC_LINK}, install sfc-state-propagation from ${HBN_LOCAL_REPO},
              patch both udev SF namers (+ rename existing SFs/reps), install CNI
              conflist if missing, start kubelet/containerd if inactive.
  Step  1/14  Verify eswitch switchdev mode (both PFs); enable eswitch MULTIPORT
              (ENABLE_ESWITCH_MULTIPORT="yes" in mlnx-bf.conf + devlink runtime
              param — required for the p1 uplink to reach the PF0-hosted SFs).
  Step  2/14  DNS fix ($( [[ "${SKIP_DNS_FIX}" == "true" ]] && echo "skipped by flag" || echo "append 8.8.8.8 if absent" )).
  Step  3/14  Create /var/lib/hbn hostPath directories.
  Step  4/14  Deploy configs: hbn.conf + sfc.conf $( [[ ${TOTAL_VFS} -gt 0 ]] && echo "GENERATED for ${P0_VFS}+${P1_VFS} VFs" || echo "from repo (core only)" );
              regenerate mlnx-sf.conf if needed; install doca_hbn.yaml pod spec.
  Step  5/14  Allocate 1600x2MB hugepages + mount + persist via systemd unit.
  Step  6/14  Provision SFs (sfnum 2,3,1514,1515$( [[ ${TOTAL_VFS} -gt 0 ]] && echo " + VFs ${ECPF0_VF_SF_BASE}+/${ECPF1_VF_SF_BASE}+" )); delete stale legacy SFs; wait attached.
  Step  7/14  OVS health check; restart sfc.service if SFs/hugepages changed.
              Stale-ofport recovery = del-br br-hbn + restart sfc (never per-port edits).
  Step  8/14  Validate all br-hbn ports (owned by sfc.sh, idempotent --may-exist).
  Step  9/14  Verify doca_hbn image present (offline — no pull attempted first).
  Step 10/14  Wait for doca-hbn pod Running (init-sfs deadlock guard: auto restart
              sfc.service + kubelet once if SF netdevs are stranded).
  Step 11/14  Bring UP all $((4 + TOTAL_VFS)) interfaces inside the container and verify.
  Step 12/14  BGP: $( [[ "${ENABLE_BGP}" == "true" ]] && echo "enable bgpd in FRR daemons" || echo "not requested (--enable-bgp)" ).
  Step 13/14  REST API: persist ${REST_USER} password, listen on 0.0.0.0, verify HTTPS :8765.
  Step 14/14  DATAPATH validation (passive, ~35s): per-uplink wire-RX vs
              container-RX counter deltas — catches the cross-PF/multiport
              unicast blackhole that config-plane checks cannot see.
EOF
  echo -e "${CYAN}── nothing was changed (dry run) ─────────────────────────────────${NC}"
}

# ═══ APPLY-PHASE HELPERS (each idempotent; only called after preflight passes) ═

# Host-side HBN prep that install.sh would normally do. We deliberately do NOT
# run ${SFC_OPT}/install.sh: it also reconfigures mgmt-VRF + SSH, which hangs
# and can change the OOB IP, breaking the session you are connected over.
step0_host_prep() {
  info "Step 0/14 — Host prep (offline; install.sh intentionally NOT run)"

  # sfc.service registration
  if ! systemctl cat sfc.service &>/dev/null; then
    [[ -f "${SFC_OPT}/sfc.service" ]] || fail "sfc.service not found at ${SFC_OPT}/sfc.service — install sfc-hbn first"
    info "registering sfc.service from ${SFC_OPT}"
    cp "${SFC_OPT}/sfc.service" /etc/systemd/system/sfc.service
    systemctl daemon-reload
    systemctl enable sfc.service
    ok "sfc.service installed and enabled"
  else
    ok "sfc.service already registered"
  fi

  # /opt/mellanox/sfc path used by sfc.service ExecStartPre
  if [[ ! -x "${SFC_LINK}/sfc.sh" && -x "${SFC_OPT}/sfc.sh" ]]; then
    ln -sfn "${SFC_OPT}" "${SFC_LINK}"
    ok "symlinked ${SFC_LINK} -> ${SFC_OPT}"
  fi

  # sfc-state-propagation — offline install from the on-DPU local repo
  if ! dpkg -s sfc-state-propagation &>/dev/null; then
    local ssp_deb
    ssp_deb=$(find "${HBN_LOCAL_REPO}" -maxdepth 1 -name 'sfc-state-propagation_*_arm64.deb' 2>/dev/null | head -1 || true)
    if [[ -n "${ssp_deb}" ]]; then
      info "installing sfc-state-propagation offline from ${ssp_deb##*/}"
      if dpkg -i "${ssp_deb}" >/dev/null 2>&1; then
        ok "sfc-state-propagation installed"
      else
        warn "sfc-state-propagation dpkg -i had issues (check deps: libmnl0, doca-openvswitch-switch)"
      fi
    else
      warn "sfc-state-propagation .deb not found in ${HBN_LOCAL_REPO} — SF state may not propagate"
    fi
  fi
  systemctl enable --now sfc-state-propagation &>/dev/null || true

  # CNI conflist for the container mgmt VRF (validated content from a working BF3)
  if [[ ! -f "${CNI_CONFLIST}" ]]; then
    mkdir -p /etc/cni/net.d
    cat > "${CNI_CONFLIST}" <<'EOF_CNI'
{
  "cniVersion": "0.3.1",
  "name": "containerd-net",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "br-mgmt",
      "isGateway": true,
      "isDefaultGateway": true,
      "ipMasq": true,
      "promiscMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [
          [{
            "subnet": "10.88.0.0/16",
            "gateway": "10.88.0.1"
          }],
          [{
            "subnet": "2001:4860:4860::/64",
            "gateway": "2001:4860:4860::1"
          }]
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    }
  ]
}
EOF_CNI
    ok "installed CNI conflist (br-mgmt) at ${CNI_CONFLIST}"
  fi

  # Container runtime + kubelet
  local u
  for u in "${CONTAINERD_UNIT:-}" "${KUBELET_UNIT:-}"; do
    [[ -n "$u" ]] || continue
    if ! systemctl is-active --quiet "$u"; then
      systemctl enable --now "$u" &>/dev/null || systemctl start "$u" || warn "could not start $u"
      ok "started $u"
    fi
  done

  patch_udev_namers
}

patch_udev_namers() {
  # Patch the SF-naming udev helper if it's the stock version (no sfc.conf mapping).
  # The STOCK script just re-emits enp<b>s<d>f<f>s<sfnum>, so init-sfs waits forever
  # for p0_if. The HBN version maps sfnum -> p0_if/p1_if/pf0hpf_if/pf1hpf_if and the
  # VF ranges 1001+/1257+ -> pf0vfN_if/pf1vfN_if.
  if [[ -f "$AUXDEV" ]] && ! grep -q 'source /etc/mellanox/sfc.conf' "$AUXDEV"; then
    info "patching ${AUXDEV} (stock -> HBN sfnum map)"
    cp "$AUXDEV" "${AUXDEV}.stock.bak"
    cat > "$AUXDEV" <<'EOF_AUX'
#!/bin/bash
#
# Udev script to rename SF netdevice
# SF netdevices that aren't used by HBN renamed to conventional name, eg. enp3s0f0s88

SFNUM=$1
IFINDEX=$2

source /etc/mellanox/sfc.conf  # Get mappings

# Names for special SFs on ECPF0 (function 0)
declare -A SFMAP=(
    [2]="p0_if"
    [3]="p1_if"
    [1514]="pf0hpf_if"
    [1515]="pf1hpf_if"
)

i=500
for SFS in "${DPU_SFS_SF[@]}"; do
	SFMAP[$i]="$SFS"
	((i+=1))
done

# SF numbers 1001 to 1001+126 on ECPF0 (function 0) are mapped to ECPF0 VFs and follow pattern pf0vfx_if
start=1001
end=$((start+126))
for i in $(seq ${start} ${end});  do
	vf_idx=$((i-${start}))
	SFMAP[$i]="pf0vf${vf_idx}_if"
done

# SF numbers 1257 to 1257+126 on ECPF0 (function 0) are mapped to ECPF1 VFs and follow pattern pf1vfx_if
start=1257
end=$((start+126))
for i in $(seq ${start} ${end});  do
	vf_idx=$((i-${start}))
	SFMAP[$i]="pf1vf${vf_idx}_if"
done


for sf_ndev in `ls /sys/class/net/`; do
	_ifindex=`cat /sys/class/net/$sf_ndev/ifindex | head -1 2>/dev/null`
	if [ "$_ifindex" != "$IFINDEX" ]; then continue; fi

	_ifnum=`cat /sys/class/net/$sf_ndev/device/sfnum | head -1 2>/dev/null`
	if [ "$_ifnum" != "$SFNUM" ];then continue; fi

	devpath=`udevadm info /sys/class/net/$sf_ndev | grep "DEVPATH="`
	pcipath=`echo $devpath | awk -F "/mlx5_core.sf" '{print $1}'`
	array=($(echo "$pcipath" | sed 's/\// /g'))
	len=${#array[@]}
	# last element in array is pci parent device
	parent_pdev=${array[$len-1]}
	#pdev is : 0000:03:00.0, so extract them by their index
	b=`echo ${parent_pdev:5:2} | sed 's/^0//'`
	d=`echo ${parent_pdev:8:2} | sed 's/^0//'`
	f=${parent_pdev: -1}

	if (( $f == 0 )); then
		sf_name="${SFMAP[${SFNUM}]}"
	elif (( $f != 1 )) ; then
		echo "Unexpected PCI function: got $f, expected 0 or 1" > /dev/kmsg
	fi

	# non-HBN SF netdevice, use conventional name
	[ -z "$sf_name" ] && sf_name="enp${b}s${d}f${f}s${SFNUM}"

	echo "${sf_name}" >> /tmp/sf_devices
	echo "SF_NETDEV_NAME=${sf_name}"
	exit
done
EOF_AUX
    chmod +x "$AUXDEV"
    udevadm control --reload 2>/dev/null || true
    ok "auxdev-sf-netdev-rename patched (backup: ${AUXDEV}.stock.bak)"
    # Rename any already-created core SFs now (udev only fires on 'add')
    local _sf _n _dev _target
    declare -A _CORE=( [2]=p0_if [3]=p1_if [1514]=pf0hpf_if [1515]=pf1hpf_if )
    for _sf in /sys/class/net/*/device/sfnum; do
      [[ -e "$_sf" ]] || continue
      _n=$(cat "$_sf" 2>/dev/null); _dev=$(basename "$(dirname "$(dirname "$_sf")")")
      _target="${_CORE[$_n]:-}"
      if [[ -n "$_target" && "$_dev" != "$_target" ]] && ! ip link show "$_target" &>/dev/null; then
        ip link set dev "$_dev" down 2>/dev/null || true
        ip link set dev "$_dev" name "$_target" 2>/dev/null && ip link set dev "$_target" up 2>/dev/null \
          && info "renamed $_dev -> $_target (sfnum $_n)"
      fi
    done
  fi

  # Same for the SF REPRESENTOR namer: stock emits en<b>f<f>pf<x>sf<sfnum>; without
  # the patch br-hbn's p0_if_r ports never bind ("could not set configuration").
  if [[ -f "$SFREP" ]] && ! grep -q 'source /etc/mellanox/sfc.conf' "$SFREP"; then
    info "patching ${SFREP} (stock -> HBN sfnum map)"
    cp "$SFREP" "${SFREP}.stock.bak"
    cat > "$SFREP" <<'EOF_SFREP'
#!/bin/bash
#
# Udev script to rename SF netdevice
# SF netdevices that aren't used by HBN renamed to conventional name, eg. en3f0pf0sf88

PORT_NAME=$1
IFINDEX=$2

source /etc/mellanox/sfc.conf  # Get mappings

# Names for special SF representors on ECPF0 (function 0)
declare -A SFRMAP=(
    [2]="p0_if_r"
    [3]="p1_if_r"
    [1514]="pf0hpf_if_r"
    [1515]="pf1hpf_if_r"
)

i=500
for SFRS in "${DPU_SFS_SF_R[@]}"; do
	SFRMAP[$i]="$SFRS"
	((i+=1))
done

# SF representor numbers 1001 to 1001+126 on ECPF0 (function 0) are mapped to ECPF0 VFs and follow pattern pf0vfx_if_r
start=1001
end=$((start+126))
for i in $(seq ${start} ${end});  do
	vf_idx=$((i-${start}))
	SFRMAP[$i]="pf0vf${vf_idx}_if_r"
done

# SF representor numbers 1257 to 1257+126 on ECPF0 (function 0) are mapped to ECPF1 VFs and follow pattern pf1vfx_if_r
start=1257
end=$((start+126))
for i in $(seq ${start} ${end});  do
	vf_idx=$((i-${start}))
	SFRMAP[$i]="pf1vf${vf_idx}_if_r"
done


for rep_ndev in `ls /sys/class/net/`; do
	_ifindex=`cat /sys/class/net/$rep_ndev/ifindex | head -1 2>/dev/null`
	if [ "$_ifindex" != "$IFINDEX" ]; then continue; fi

	_phys_port_name=$(cat /sys/class/net/$rep_ndev/phys_port_name | head -1 2>/dev/null)
	if [[ "$_phys_port_name" != "$PORT_NAME" ]]; then continue; fi

	devpath=`udevadm info /sys/class/net/$rep_ndev | grep "DEVPATH="`
	pcipath=`echo $devpath | awk -F "/net/$rep_ndev" '{print $1}'`
	array=($(echo "$pcipath" | sed 's/\// /g'))
	len=${#array[@]}
	# last element in array is pci parent device
	parent_pdev=${array[$len-1]}
	#pdev is : 0000:03:00.0, so extract them by their index
	b=`echo ${parent_pdev:5:2} | sed 's/^0//'`
	f=${parent_pdev: -1}
	SFNUM=$(($(echo "${PORT_NAME}" | grep -o -E '[0-9]+' | tail -1)))

	if (( $f == 0 )); then
		sfr_name="${SFRMAP[${SFNUM}]}"
	elif (( $f != 1 )) ; then
		echo "Unexpected PCI function: got $f, expected 0 or 1 " > /dev/kmsg
	fi

	# non-HBN SF representor, use conventional name
	[ x$sfr_name == x ] && sfr_name="en${b}f${f}${PORT_NAME}"

	echo "${sfr_name}" >> /tmp/sfr_devices
	echo "NAME=${sfr_name}"
	exit
done
EOF_SFREP
    chmod +x "$SFREP"
    udevadm control --reload 2>/dev/null || true
    ok "sf-rep-netdev-rename patched (backup: ${SFREP}.stock.bak)"
    # Rename any already-created core representors now (match phys_port_name pf0sf<sfnum>)
    local _n _target _rdev _rd
    declare -A _CORER=( [2]=p0_if_r [3]=p1_if_r [1514]=pf0hpf_if_r [1515]=pf1hpf_if_r )
    for _n in "${!_CORER[@]}"; do
      _target="${_CORER[$_n]}"
      ip link show "$_target" &>/dev/null && continue
      for _rdev in /sys/class/net/*; do
        [[ "$(cat "$_rdev/phys_port_name" 2>/dev/null)" == "pf0sf${_n}" ]] || continue
        _rd=$(basename "$_rdev")
        ip link set dev "$_rd" down 2>/dev/null || true
        ip link set dev "$_rd" name "$_target" 2>/dev/null && ip link set dev "$_target" up 2>/dev/null \
          && info "renamed representor $_rd -> $_target (pf0sf${_n})"
        break
      done
    done
  fi
  return 0
}

# Stale br-hbn OVS DB recovery — the ONLY sanctioned intervention on br-hbn.
# We never add/del individual ports (a hand-set ofport_request survives reboot and
# breaks sfc.service); we delete the whole bridge and let sfc.sh rebuild it.
recover_stale_brhbn() {
  warn "sfc.service failed with stale ofport_request — rebuilding br-hbn cleanly"
  ovs-vsctl --if-exists del-br br-hbn
  systemctl reset-failed sfc.service 2>/dev/null || true
  systemctl start sfc.service
  sleep 20
}

# ─── VF config generators ────────────────────────────────────────────────────
generate_hbn_conf() {
  local i
  {
    cat <<'EOF'
[hbn_profile]
profile_name = default

[BR_HBN_UPLINKS]
p0
p1

[BR_HBN_REPS]
pf0hpf
pf1hpf
EOF
    for ((i=0; i<P0_VFS; i++)); do echo "pf0vf${i}"; done
    for ((i=0; i<P1_VFS; i++)); do echo "pf1vf${i}"; done
    cat <<'EOF'

[BR_HBN_SFS]


[BR_SFC_UPLINKS]


[BR_SFC_REPS]

[BR_SFC_SFS]


[BR_HBN_SFC_PATCH_PORTS]


[LINK_PROPAGATION]
p0:p0_if_r
p1:p1_if_r
pf0hpf:pf0hpf_if_r
pf1hpf:pf1hpf_if_r
EOF
    for ((i=0; i<P0_VFS; i++)); do echo "pf0vf${i}:pf0vf${i}_if_r"; done
    for ((i=0; i<P1_VFS; i++)); do echo "pf1vf${i}:pf1vf${i}_if_r"; done
    printf '\n[ENABLE_BR_SFC]\n\n\n[ENABLE_BR_SFC_DEFAULT_FLOWS]\n\n\n[ENABLE_VETH]\n\n'
  } > "${HBN_CONF}"
}

generate_sfc_conf() {
  # br-hbn port mappings, consumed by sfc.sh (adds ports) and init-sfs (field4 =
  # container netdev to move into the pod). Core + VF entries in authoritative format.
  local i
  {
    cat <<'EOF'
BR_HBN_NAME=br-hbn
MAPPINGS=(
"br-hbn~p0~p0_if_r~p0_if~p0_if_r"
"br-hbn~p1~p1_if_r~p1_if~p1_if_r"
"br-hbn~pf0hpf~pf0hpf_if_r~pf0hpf_if~pf0hpf_if_r"
"br-hbn~pf1hpf~pf1hpf_if_r~pf1hpf_if~pf1hpf_if_r"
EOF
    # VF entries — AUTHORITATIVE format from install.sh (generate_ovs_sf_mapping):
    # field2 = VF ESWITCH rep (pf0vfN, exists once host SR-IOV VFs exist),
    # field3 = SF rep (pf0vfN_if_r), field4 = SF netdev moved into the pod by init-sfs.
    for ((i=0; i<P0_VFS; i++)); do
      echo "\"br-hbn~pf0vf${i}~pf0vf${i}_if_r~pf0vf${i}_if~pf0vf${i}_if_r\""
    done
    for ((i=0; i<P1_VFS; i++)); do
      echo "\"br-hbn~pf1vf${i}~pf1vf${i}_if_r~pf1vf${i}_if~pf1vf${i}_if_r\""
    done
    echo ")"
  } > "${SFC_CONF}"
}

# ═══ RUN ══════════════════════════════════════════════════════════════════════
echo ""
echo "============================================================"
echo "  HBN BF3 Bringup — DOCA 3.3.0"
echo "  $(date)"
[[ "${CHECK_ONLY}" == "true" ]] && echo "  MODE: --check (read-only preflight)"
[[ "${DRY_RUN}"   == "true" ]] && echo "  MODE: --dry-run (no changes)"
echo "============================================================"

CONTAINERD_UNIT=""; KUBELET_UNIT=""
preflight

if [[ "${CHECK_ONLY}" == "true" ]]; then
  [[ ${PF_FAIL} -eq 0 ]] && exit 0 || exit 1
fi
if [[ "${DRY_RUN}" == "true" ]]; then
  print_dry_run_plan
  [[ ${PF_FAIL} -eq 0 ]] && exit 0 || exit 1
fi
if [[ ${PF_FAIL} -gt 0 ]]; then
  fail "Preflight found ${PF_FAIL} blocker(s) — NOTHING was changed. Fix them and re-run (iterate with: $0 --check)"
fi

# ─── Step 0: host prep ───────────────────────────────────────────────────────
step0_host_prep

# Detect the sfc service name — varies across DOCA package versions
SFC_SERVICE=""
for _S in sfc mlnx-sfc hbn-sfc; do
  systemctl cat "${_S}.service" &>/dev/null \
    && { SFC_SERVICE="${_S}.service"; break; }
done
[[ -z "$SFC_SERVICE" ]] && fail "no sfc service registered even after host prep — check: systemctl list-unit-files | grep -i sfc"

# ─── Step 1: eswitch switchdev mode + multiport ──────────────────────────────
info "Step 1/14 — Verifying eswitch switchdev mode + enabling multiport"
for BF3_PCI in "$BF3_PCI0" "$BF3_PCI1"; do
  if devlink dev eswitch show "pci/$BF3_PCI" 2>/dev/null | grep "^pci/$BF3_PCI" | grep -q "mode switchdev"; then
    ok "pci/$BF3_PCI eswitch mode: switchdev"
  else
    fail "pci/$BF3_PCI eswitch NOT in switchdev mode. Run: devlink dev eswitch set pci/$BF3_PCI mode switchdev"
  fi
done

# Eswitch multiport — all HBN SFs live on PF0; without multiport the p1 uplink
# cannot deliver to them (unicast blackhole with healthy-looking config plane).
if grep -q '^ENABLE_ESWITCH_MULTIPORT="yes"' "$MLNX_BF_CONF" 2>/dev/null; then
  ok "mlnx-bf.conf: ENABLE_ESWITCH_MULTIPORT=\"yes\" already set"
else
  if grep -q '^ENABLE_ESWITCH_MULTIPORT=' "$MLNX_BF_CONF" 2>/dev/null; then
    sed -i 's/^ENABLE_ESWITCH_MULTIPORT=.*/ENABLE_ESWITCH_MULTIPORT="yes"/' "$MLNX_BF_CONF"
  else
    printf '\nENABLE_ESWITCH_MULTIPORT="yes"\n' >> "$MLNX_BF_CONF"
  fi
  ok "mlnx-bf.conf: set ENABLE_ESWITCH_MULTIPORT=\"yes\" (mlnx_bf_configure re-applies it every boot)"
fi
MP_VAL=$(devlink dev param show "pci/${BF3_PCI0}" name esw_multiport 2>/dev/null \
  | awk '/cmode/{print $NF}' || true)
if [[ "$MP_VAL" == "true" ]]; then
  ok "eswitch multiport active (esw_multiport=true)"
elif devlink dev param set "pci/${BF3_PCI0}" name esw_multiport value true cmode runtime 2>/dev/null; then
  ok "eswitch multiport enabled at runtime (esw_multiport=true)"
else
  fail "cannot enable esw_multiport (firmware rejects it) — LAG_RESOURCE_ALLOCATION=1 was not committed by a TRUE cold power cycle. See: $0 --check"
fi

# ─── Step 2: DNS fix ─────────────────────────────────────────────────────────
info "Step 2/14 — Checking DNS"
if [[ "$SKIP_DNS_FIX" == "true" ]]; then
  warn "Skipping DNS fix (--skip-dns-fix)"
elif grep -q "8.8.8.8" /etc/resolv.conf 2>/dev/null; then
  ok "DNS already has 8.8.8.8"
else
  echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  ok "Added nameserver 8.8.8.8 to /etc/resolv.conf"
fi

# ─── Step 3: hostPath directories ────────────────────────────────────────────
info "Step 3/14 — Creating hostPath directories"
mkdir -p \
  /var/lib/hbn/etc/nvue.d \
  /var/lib/hbn/etc/frr \
  /var/lib/hbn/etc/network \
  /var/lib/hbn/etc/cumulus \
  /var/lib/hbn/etc/hbn-users \
  /var/lib/hbn/etc/supervisor/conf.d \
  /var/lib/hbn/var/lib/nvue \
  /var/lib/hbn/var/support \
  "${LOG_DIR}"
ok "hostPath directories ready"

# ─── Step 4: Deploy reference config files ───────────────────────────────────
info "Step 4/14 — Deploying reference config files from ${MLX_REF_DIR}"

[[ -d "$MLX_REF_DIR" ]] || fail "Reference config directory not found: $MLX_REF_DIR (clone the full repo)"

# Safety re-check (preflight already gated this): VF eswitch reps must exist.
if [[ $TOTAL_VFS -gt 0 ]]; then
  _MISSING=$(missing_vf_reps)
  [[ -z "$_MISSING" ]] || fail "VF eswitch reps disappeared since preflight: ${_MISSING} — re-run $0 --check"
  ok "VF eswitch reps present for ${TOTAL_VFS} VFs — host SR-IOV VFs are up"
fi

# hbn.conf — generate dynamically when VFs requested; otherwise use repo reference
if [[ $TOTAL_VFS -gt 0 ]]; then
  generate_hbn_conf
  ok "hbn.conf generated (p0_vfs=${P0_VFS}, p1_vfs=${P1_VFS})"
elif grep -qE "pf0vf[0-9]" "${HBN_CONF}" 2>/dev/null; then
  info "hbn.conf has unexpected VF entries — replacing with PF-only version"
  cp "${MLX_REF_DIR}/hbn.conf" "${HBN_CONF}"
  ok "hbn.conf replaced"
elif [[ ! -f "${HBN_CONF}" ]]; then
  cp "${MLX_REF_DIR}/hbn.conf" "${HBN_CONF}"
  ok "hbn.conf installed"
else
  ok "hbn.conf already correct"
fi

# sfc.conf — generate dynamically when VFs requested; otherwise use repo reference
if [[ $TOTAL_VFS -gt 0 ]]; then
  generate_sfc_conf
  ok "sfc.conf generated (p0_vfs=${P0_VFS}, p1_vfs=${P1_VFS})"
elif grep -qE "pf0vf[0-9]|pf1vf[0-9]" "${SFC_CONF}" 2>/dev/null; then
  info "sfc.conf has unexpected VF entries — replacing with PF-only version"
  cp "${MLX_REF_DIR}/sfc.conf" "${SFC_CONF}"
  ok "sfc.conf replaced"
elif [[ ! -f "${SFC_CONF}" ]]; then
  cp "${MLX_REF_DIR}/sfc.conf" "${SFC_CONF}"
  ok "sfc.conf installed"
else
  ok "sfc.conf already correct"
fi

# mlnx-sf.conf — regenerate when incomplete or carrying a physical port MAC
detect_port_macs
_REGEN_REASON=$(sf_conf_regen_reason)
if [[ -n "${_REGEN_REASON}" ]]; then
  info "mlnx-sf.conf ${_REGEN_REASON} — regenerating"
  # Derive BF3-unique locally-administered MACs from p0 physical MAC.
  if [[ -n "$P0_MAC" ]]; then
    IFS=':' read -ra _M <<< "$P0_MAC"
    _B3="${_M[3]}"; _B4="${_M[4]}"; _B5="${_M[5]}"
  else
    warn "Could not detect p0 MAC — using fixed LA MACs (may conflict if multiple BF3s on same L2)"
    _B3="00"; _B4="00"; _B5="00"
  fi
  _SF2_MAC="02:${_B3}:${_B4}:${_B5}:00:02"
  _SF3_MAC="02:${_B3}:${_B4}:${_B5}:00:03"
  _SF1514_MAC="02:${_B3}:${_B4}:${_B5}:05:ea"
  _SF1515_MAC="02:${_B3}:${_B4}:${_B5}:05:eb"
  {
    cat <<EOF
/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum 2 --hwaddr ${_SF2_MAC} -t --cpu-list 0-2
/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum 1514 --hwaddr ${_SF1514_MAC} -t --cpu-list 0-2
/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum 3 --hwaddr ${_SF3_MAC} -t --cpu-list 0-2
/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum 1515 --hwaddr ${_SF1515_MAC} -t --cpu-list 0-2
EOF
    # VF SFs — AUTHORITATIVE sfnum scheme (see header): 1001+N / 1257+N ONLY.
    for ((i=0; i<P0_VFS; i++)); do
      _SFNUM=$((ECPF0_VF_SF_BASE + i))
      _MAC="02:${_B3}:${_B4}:${_B5}:0a:$(printf '%02x' "$i")"
      echo "/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum ${_SFNUM} --hwaddr ${_MAC} -t --cpu-list 0-2"
    done
    for ((i=0; i<P1_VFS; i++)); do
      _SFNUM=$((ECPF1_VF_SF_BASE + i))
      _MAC="02:${_B3}:${_B4}:${_B5}:0b:$(printf '%02x' "$i")"
      echo "/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum ${_SFNUM} --hwaddr ${_MAC} -t --cpu-list 0-2"
    done
  } > "${MLX_SF_CONF}"
  ok "mlnx-sf.conf generated: sfnums 2,3,1514,1515 + ${TOTAL_VFS} VF SFs (base: ${P0_MAC:-unknown})"
else
  ok "mlnx-sf.conf check passed (sfnums and MACs OK)"
fi

# doca_hbn.yaml — static pod spec; hbn-runtime package does NOT install it
if [[ -f "${HBN_POD_SPEC}" ]]; then
  ok "doca_hbn.yaml already at ${HBN_POD_SPEC}"
elif [[ -f "${DOCA_CONFIGS_DIR}/doca_hbn.yaml" ]]; then
  cp "${DOCA_CONFIGS_DIR}/doca_hbn.yaml" "${HBN_POD_SPEC}"
  ok "doca_hbn.yaml installed from ${DOCA_CONFIGS_DIR}"
elif [[ -f "${MLX_REF_DIR}/doca_hbn.yaml" ]]; then
  cp "${MLX_REF_DIR}/doca_hbn.yaml" "${HBN_POD_SPEC}"
  ok "doca_hbn.yaml installed from ${MLX_REF_DIR}"
else
  fail "doca_hbn.yaml not found — expected at ${DOCA_CONFIGS_DIR}/doca_hbn.yaml"
fi

# ─── Step 5: Hugepages ───────────────────────────────────────────────────────
info "Step 5/14 — Hugepage allocation (OVS-DPDK requires 1600x2MB)"

HP_FILE="/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
HP_NOW=$(cat "$HP_FILE" 2>/dev/null || echo 0)

if [[ $HP_NOW -ge 1600 ]]; then
  ok "Hugepages already allocated: ${HP_NOW}x2MB"
else
  info "Allocating 1600x2MB hugepages (currently: ${HP_NOW})"
  echo 1600 > "$HP_FILE"
  HP_NOW=$(cat "$HP_FILE")
  [[ $HP_NOW -ge 1600 ]] || fail "Could not allocate hugepages (got ${HP_NOW}) — system may be low on memory"
  ok "Hugepages allocated: ${HP_NOW}x2MB"
fi

HP_MOUNT="/mnt/huge_2mb"
if mountpoint -q "$HP_MOUNT" 2>/dev/null; then
  ok "${HP_MOUNT} already mounted"
else
  mkdir -p "$HP_MOUNT"
  mount -t hugetlbfs -o pagesize=2M none "$HP_MOUNT"
  ok "${HP_MOUNT} mounted"
fi

# Tell OVS where hugepages live (no-op if already set correctly)
ovs-vsctl set Open_vSwitch . other_config:dpdk-hugepage-dir="$HP_MOUNT" 2>/dev/null || true

# Persistent hugepage service so allocation survives reboot before OVS starts
HP_SVC="/etc/systemd/system/mlnx-hugepages-2mb.service"
if [[ ! -f "$HP_SVC" ]]; then
  cat > "$HP_SVC" <<'SVCEOF'
[Unit]
Description=Allocate 2MB hugepages for OVS-DPDK
DefaultDependencies=no
Before=openvswitch-switch.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'echo 1600 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages && mkdir -p /mnt/huge_2mb && mountpoint -q /mnt/huge_2mb || mount -t hugetlbfs -o pagesize=2M none /mnt/huge_2mb'

[Install]
WantedBy=multi-user.target
SVCEOF
  systemctl daemon-reload
  systemctl enable mlnx-hugepages-2mb.service
  ok "mlnx-hugepages-2mb.service created and enabled"
else
  ok "mlnx-hugepages-2mb.service already present"
fi

# ─── Step 6: Provision SFs ───────────────────────────────────────────────────
info "Step 6/14 — Checking SF provisioning (sfnum 2, 3, 1514, 1515$( [[ $TOTAL_VFS -gt 0 ]] && echo " + ${TOTAL_VFS} VFs" ))"

# Clean stale legacy-scheme VF SFs (sfnum 4-11) first — the namers can't map them,
# so they'd never become pf*vf*_if and would just leak.
if [[ $TOTAL_VFS -gt 0 ]]; then
  _LEGACY=$(stale_legacy_vf_sfs)
  if [[ -n "$_LEGACY" ]]; then
    warn "deleting stale legacy VF SFs (sfnum ${_LEGACY}) — wrong numbering scheme"
    while IFS= read -r LINE; do
      SFNUM=$(echo "$LINE" | grep -o "sfnum [0-9]*" | awk '{print $2}')
      if [[ "$SFNUM" =~ ^([4-9]|1[01])$ ]]; then
        SFIDX=$(echo "$LINE" | awk '{print $1}' | sed 's/:$//')
        if mlnx-sf --action delete --sfindex "$SFIDX" 2>/dev/null; then
          info "  deleted legacy sfnum $SFNUM"
        fi
      fi
    done < <(devlink port show 2>/dev/null | grep "sfnum " || true)
  fi
fi

# SFS_PROVISIONED tracks whether sfc.service needs to be (re)started in step 7
SFS_PROVISIONED=true

# Primary check: all expected SFs opstate=attached in devlink.
# NOTE: devlink prints the "function:" attrs (incl. opstate) on a CONTINUATION
# line — join each port's lines first, or the check false-negatives forever
# (which made every re-run needlessly restart sfc.service).
sfs_all_attached() {
  local s i txt
  txt=$(devlink port show 2>/dev/null \
    | awk '/^pci\//{printf "\n%s",$0; next}{printf " %s",$0} END{print ""}')
  local want=(2 3 1514 1515)
  for ((i=0; i<P0_VFS; i++)); do want+=( $((ECPF0_VF_SF_BASE+i)) ); done
  for ((i=0; i<P1_VFS; i++)); do want+=( $((ECPF1_VF_SF_BASE+i)) ); done
  for s in "${want[@]}"; do
    echo "$txt" | grep "sfnum ${s} " | grep -q "opstate attached" || return 1
  done
}

if sfs_all_attached; then
  ok "SFs already provisioned and attached"
else
  SFS_PROVISIONED=false

  # SFs appear attached in devlink but netdevs missing -> MAC conflict; delete and reprovision
  if devlink port show 2>/dev/null | grep -qE "sfnum (2|3|1514|1515)"; then
    MISSING_NETDEVS=()
    for NETDEV in p0_if_r p1_if_r pf0hpf_if_r pf1hpf_if_r; do
      [[ -d "/sys/class/net/${NETDEV}" ]] || MISSING_NETDEVS+=("$NETDEV")
    done
    if [[ ${#MISSING_NETDEVS[@]} -gt 0 ]]; then
      warn "SFs in devlink but function netdevs missing: ${MISSING_NETDEVS[*]}"
      warn "Possible MAC conflict — deleting SFs for reprovisioning"
      while IFS= read -r LINE; do
        SFNUM=$(echo "$LINE" | grep -o "sfnum [0-9]*" | awk '{print $2}')
        if [[ "$SFNUM" =~ ^(2|3|1514|1515)$ ]]; then
          # awk field 1 is "pci/0000:03:00.0/163872:" — strip trailing colon
          SFIDX=$(echo "$LINE" | awk '{print $1}' | sed 's/:$//')
          if mlnx-sf --action delete --sfindex "$SFIDX" 2>/dev/null; then
            info "  Deleted sfnum $SFNUM"
          else
            warn "  Could not delete sfnum $SFNUM — may already be gone"
          fi
        fi
      done < <(devlink port show 2>/dev/null | grep "sfnum ")
      sleep 2
    fi
  fi

  [[ -f "$MLX_SF_CONF" ]] || fail "$MLX_SF_CONF not found — cannot provision SFs"
  info "Provisioning SFs from ${MLX_SF_CONF}..."
  # Run each mlnx-sf create individually so "already exists" errors are non-fatal
  while IFS= read -r CMD; do
    [[ -z "$CMD" || "$CMD" == \#* ]] && continue
    # shellcheck disable=SC2086  # intentional word splitting of the config line
    if ! $CMD >/tmp/sf_create_err 2>&1; then
      if grep -q "already exist" /tmp/sf_create_err 2>/dev/null; then
        SFNUM=$(echo "$CMD" | grep -o -- "--sfnum [0-9]*" | awk '{print $2}')
        info "  sfnum ${SFNUM} already exists — skipping"
      else
        cat /tmp/sf_create_err >&2
        fail "mlnx-sf create failed: $CMD"
      fi
    fi
  done < "$MLX_SF_CONF"

  # Explicitly activate any SFs that are in devlink but not yet active.
  _ALL_SFNUMS=(2 3 1514 1515)
  for ((i=0; i<P0_VFS; i++)); do _ALL_SFNUMS+=( $((ECPF0_VF_SF_BASE+i)) ); done
  for ((i=0; i<P1_VFS; i++)); do _ALL_SFNUMS+=( $((ECPF1_VF_SF_BASE+i)) ); done
  for _S in "${_ALL_SFNUMS[@]}"; do
    _PORT=$(devlink port show 2>/dev/null | grep "sfnum ${_S} " | awk '{print $1}' | sed 's/:$//')
    if [[ -n "$_PORT" ]]; then
      if devlink port function set "$_PORT" state active 2>/dev/null; then
        info "  Activated sfnum ${_S} (${_PORT})"
      fi
    fi
  done

  # Poll for SF activation — kernel attaches SFs asynchronously (20-60s on fresh BF3)
  info "Waiting for SFs to reach opstate=attached (up to 60s)..."
  SF_WAIT=0
  until sfs_all_attached || [[ $SF_WAIT -ge 60 ]]; do
    sleep 3; SF_WAIT=$((SF_WAIT + 3))
  done

  if sfs_all_attached; then
    ok "All SFs attached (waited ${SF_WAIT}s)"
  else
    warn "SFs not fully attached after 60s — ${SFC_SERVICE} will retry; check 'mlnx-sf -a show' if pod fails"
  fi
fi

# ─── Step 7: OVS health check ────────────────────────────────────────────────
info "Step 7/14 — OVS bridge health check"

OVS_RESTARTED=false

# p0/p1 "Invalid argument" is BENIGN on BF3 switchdev (eswitch firmware owns the
# physical uplinks; OVS-DPDK can't bind them as netdev ports) — exclude from check.
OVS_REAL_ERRORS=$(ovs-vsctl show 2>/dev/null \
  | grep "Invalid argument" \
  | grep -cv "could not add network device p[01] to ofproto" || true)
OVS_REAL_ERRORS=${OVS_REAL_ERRORS:-0}
if [[ "$OVS_REAL_ERRORS" -gt 0 ]]; then
  warn "br-hbn has 'Invalid argument' — OVS started before hugepages were allocated; fixing"
  if ovs-vsctl del-br br-hbn 2>/dev/null; then info "Deleted stale br-hbn"; fi
  systemctl restart openvswitch-switch
  sleep 5
  OVS_RESTARTED=true
fi

# Stale ofport_request from a previous boot / hand-run ovs-vsctl -> rebuild cleanly
if sfc_ofport_stale; then
  recover_stale_brhbn
  OVS_RESTARTED=true
fi

# NOTE: br-hbn ports (including VF reps) are owned ENTIRELY by sfc.sh, which reads
# sfc.conf MAPPINGS and adds them idempotently (--may-exist). We never touch
# individual br-hbn ports — manual add/del leaves stale ofport_request state that
# survives reboot and breaks sfc.service on the next boot.

# Restart sfc.service when OVS was fixed or SFs were just provisioned
if [[ "$OVS_RESTARTED" == "true" ]] || [[ "$SFS_PROVISIONED" == "false" ]]; then
  info "Restarting ${SFC_SERVICE} to wire up SFs and hugepages..."
  if ! systemctl restart "$SFC_SERVICE"; then
    if sfc_ofport_stale; then
      recover_stale_brhbn
    else
      fail "${SFC_SERVICE} failed — journalctl -u ${SFC_SERVICE%.service} -n 50"
    fi
  fi
  sleep 20
fi

# When VFs are configured, force restart the doca-hbn container so init-sfs
# runs again with the new VF OVS metadata (hbn_netdev) — this moves the VF SF
# function netdevs into the container as pf0vfN_if / pf1vfN_if.
if [[ $TOTAL_VFS -gt 0 ]]; then
  _OLD_CONT=$(crictl ps -q --name doca-hbn 2>/dev/null | head -1 || true)
  if [[ -n "$_OLD_CONT" ]]; then
    info "Restarting doca-hbn container so init-sfs picks up VF interfaces..."
    crictl stop "$_OLD_CONT" 2>/dev/null || true
    sleep 5
  fi
fi

# ─── Step 8: Validate OVS ports ──────────────────────────────────────────────
info "Step 8/14 — Validating OVS ports on br-hbn"

check_ovs_ports() {
  local missing=() port
  for port in p0 p1 pf0hpf pf1hpf p0_if_r p1_if_r pf0hpf_if_r pf1hpf_if_r; do
    ovs-vsctl list-ports br-hbn 2>/dev/null | grep -qx "$port" || missing+=("$port")
  done
  echo "${missing[*]:-}"
}

OVS_MISSING=$(check_ovs_ports)
if [[ -n "$OVS_MISSING" ]]; then
  warn "Missing OVS ports: ${OVS_MISSING} — restarting ${SFC_SERVICE}"
  systemctl restart "$SFC_SERVICE" || { sfc_ofport_stale && recover_stale_brhbn; }
  sleep 20
  OVS_MISSING=$(check_ovs_ports)
  if [[ -n "$OVS_MISSING" ]]; then
    warn "Still missing OVS ports: ${OVS_MISSING} — check: journalctl -u ${SFC_SERVICE%.service} -n 50"
  else
    ok "All OVS ports present after ${SFC_SERVICE} restart"
  fi
else
  ok "All 8 core OVS ports present on br-hbn"
fi

# ─── Step 9: Container image (OFFLINE) ───────────────────────────────────────
info "Step 9/14 — Checking doca_hbn container image"
if crictl images 2>/dev/null | grep -qE "doca_hbn|doca-hbn"; then
  ok "doca_hbn image present"
else
  IMAGE=$(grep -i "image:" "$HBN_POD_SPEC" | head -1 | awk '{print $2}')
  warn "image missing — attempting pull of $IMAGE (offline sites: import instead)"
  if ! crictl pull "$IMAGE"; then
    fail "cannot pull $IMAGE. OFFLINE fix: sudo ctr -n k8s.io images import /path/to/doca_hbn_3.3.0-doca3.3.0.tar"
  fi
  ok "Image pulled"
fi

# ─── Step 10: Wait for doca-hbn pod (with init-sfs deadlock guard) ───────────
info "Step 10/14 — Waiting for doca-hbn container to be Running (timeout: ${WAIT_TIMEOUT}s)"
ELAPSED=0
DEADLOCK_KICKED=false
while true; do
  if crictl ps 2>/dev/null | grep "doca-hbn" | grep -v init | grep -q "Running"; then
    ok "doca-hbn container is Running"
    break
  fi
  # init-sfs deadlock guard: on pod restart, init-sfs waits for the SF netdevs to
  # return to the host netns; if sfc-state-propagation raced it they come back
  # UNNAMED and init-sfs loops on 'Device "p0_if" does not exist' forever.
  # Documented recovery: restart sfc.service, then make sure kubelet stayed up.
  if [[ $ELAPSED -ge 120 && "$DEADLOCK_KICKED" == "false" ]]; then
    if ! ip link show p0_if &>/dev/null && ! crictl ps 2>/dev/null | grep "doca-hbn" | grep -v init | grep -q "Running"; then
      warn "possible init-sfs deadlock (p0_if not on host after ${ELAPSED}s) — restarting ${SFC_SERVICE}"
      systemctl restart "$SFC_SERVICE" || true
      sleep 5
      # kubelet is coupled to sfc on some builds — never leave it down
      if [[ -n "${KUBELET_UNIT:-}" ]] && ! systemctl is-active --quiet "${KUBELET_UNIT}"; then
        systemctl start "${KUBELET_UNIT}" || true
        warn "kubelet was down after sfc restart — started ${KUBELET_UNIT}"
      fi
      DEADLOCK_KICKED=true
    fi
  fi
  if [[ $ELAPSED -ge $WAIT_TIMEOUT ]]; then
    fail "Timed out waiting for doca-hbn pod. Check: journalctl -u kubelet -f | grep hbn  (and: crictl ps -a)"
  fi
  echo -n "."
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done
echo ""

CONT=$(crictl ps -q --name doca-hbn 2>/dev/null | head -1 || true)
[[ -z "$CONT" ]] && fail "Could not get doca-hbn container ID"
info "Container ID: $CONT"
CONT_PID=$(crictl inspect "$CONT" 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('info',{}).get('pid',''))" 2>/dev/null || true)
[[ -z "$CONT_PID" ]] && fail "Could not get doca-hbn container PID"

# ─── Step 11: Bring up interfaces inside container ───────────────────────────
info "Step 11/14 — Bringing up HBN interfaces inside container"
HBN_IFACES=(p0_if p1_if pf0hpf_if pf1hpf_if)
for ((i=0; i<P0_VFS; i++)); do HBN_IFACES+=("pf0vf${i}_if"); done
for ((i=0; i<P1_VFS; i++)); do HBN_IFACES+=("pf1vf${i}_if"); done
# VF SF netdevs are moved into the pod by init-sfs itself (sfc.conf MAPPINGS field4).

IFACE_FAILS=0
for iface in "${HBN_IFACES[@]}"; do
  STATE=$(crictl exec "$CONT" ip link show "$iface" 2>/dev/null | grep -o "state [A-Z]*" | awk '{print $2}' || true)
  if [[ "$STATE" == "UP" ]]; then
    ok "$iface already UP"
  elif [[ -z "$STATE" ]]; then
    warn "$iface: not found in container — VF SF may not be provisioned yet"
    IFACE_FAILS=$((IFACE_FAILS+1))
  else
    if crictl exec "$CONT" ip link set "$iface" up 2>/dev/null; then
      ok "$iface brought UP"
    else
      warn "$iface: could not set UP"
      IFACE_FAILS=$((IFACE_FAILS+1))
    fi
  fi
done
if [[ $IFACE_FAILS -eq 0 ]]; then
  ok "all $((4 + TOTAL_VFS)) HBN interfaces UP in container"
else
  warn "${IFACE_FAILS} interface(s) not UP — run status_hbn.sh after a minute"
fi

# ─── Step 12: Enable BGP ─────────────────────────────────────────────────────
info "Step 12/14 — BGP configuration"
FRR_DAEMONS="/var/lib/hbn/etc/frr/daemons"
if [[ "$ENABLE_BGP" == "true" ]]; then
  if [[ -f "$FRR_DAEMONS" ]]; then
    if grep -q "bgpd=yes" "$FRR_DAEMONS"; then
      ok "bgpd already enabled"
    else
      sed -i 's/bgpd=no/bgpd=yes/' "$FRR_DAEMONS"
      crictl exec "$CONT" supervisorctl restart frr 2>/dev/null || \
        crictl exec "$CONT" bash -c "/usr/lib/frr/frrinit.sh restart" 2>/dev/null || \
        crictl exec "$CONT" bash -c "killall -HUP watchfrr" 2>/dev/null || true
      sleep 5
      if crictl exec "$CONT" vtysh -c "show daemons" 2>/dev/null | grep -q "bgpd"; then
        ok "bgpd enabled and running"
      else
        warn "bgpd enabled in $FRR_DAEMONS but not yet running — FRR may need more time to restart"
      fi
    fi
  else
    warn "$FRR_DAEMONS not found — skipping BGP enable"
  fi
else
  ok "BGP not requested (use --enable-bgp to enable)"
fi

# ─── Step 13: REST API — password + listening address ────────────────────────
info "Step 13/14 — REST API setup"

if [[ -d "$DOCA_SCRIPTS_DIR" ]]; then
  # Ensure Python deps available on BF3 host (offline apt from local repo if configured)
  python3 -c "import cryptography, yaml" 2>/dev/null || \
    apt-get install -y python3-cryptography python3-yaml -qq 2>/dev/null || \
    warn "python3-cryptography/yaml unavailable — REST password won't persist across container restarts"

  # Persist password: encrypt_password.py runs on host, writes to hostPath volume;
  # the container re-creates the user from it on EVERY start (survives restarts).
  mkdir -p /var/lib/hbn/etc/hbn-users
  if python3 "$DOCA_SCRIPTS_DIR/encrypt_password.py" -u "$REST_USER" -p "$REST_PASS"; then
    ok "Password persisted for $REST_USER (survives container restart)"
  else
    warn "encrypt_password.py failed — password will reset on container restart"
  fi

  # Update startup.yaml to listen on 0.0.0.0 — must run from script dir (relative paths)
  if (cd "$DOCA_SCRIPTS_DIR" && python3 enable-rest-api.py); then
    ok "NVUE startup.yaml updated for external REST access"
  else
    warn "enable-rest-api.py failed"
  fi

  # Copy REST access marker read by container init
  mkdir -p /var/lib/hbn/etc/cumulus
  cp "$DOCA_SCRIPTS_DIR/etc/cumulus/hbn-dpu-setup.conf" /var/lib/hbn/etc/cumulus/

  # Apply password immediately without waiting for container restart
  crictl exec "$CONT" bash -c "id ${REST_USER} &>/dev/null || useradd -m -s /bin/bash ${REST_USER}; usermod -aG sudo,nvshow,nvset,nvapply ${REST_USER} 2>/dev/null; echo '${REST_USER}:${REST_PASS}' | chpasswd" 2>/dev/null || true
else
  warn "DOCA scripts not found at $DOCA_SCRIPTS_DIR — skipping REST API setup"
  warn "Place the HBN scripts package at: $DOCA_SCRIPTS_DIR"
fi

# Verify — the CNI portmap DNAT for :8765 only hooks PREROUTING, so the REST
# port is NOT reachable from the BF3 itself (localhost/OOB both fail with
# connection refused — that is normal). Verify against the pod IP directly;
# external clients use https://<OOB-IP>:8765.
REST_POD_ID=$(crictl pods --name doca-hbn -q 2>/dev/null | head -1 || true)
REST_POD_IP=""
[[ -n "$REST_POD_ID" ]] && REST_POD_IP=$(crictl inspectp "$REST_POD_ID" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['network']['ip'])" 2>/dev/null || true)
if [[ -n "$REST_POD_IP" ]] && curl -sk -u "${REST_USER}:${REST_PASS}" --max-time 10 \
     "https://${REST_POD_IP}:8765/nvue_v1/system" 2>/dev/null | grep -q "build"; then
  ok "REST API up and credentials valid (pod ${REST_POD_IP}:8765; external: https://<OOB-IP>:8765)"
else
  warn "REST API check failed — verify from ANOTHER machine (not the BF3 itself):"
  warn "  curl -k -u ${REST_USER}:*** https://<BF3-OOB-IP>:8765/nvue_v1/system"
fi

# ─── Step 14: Passive datapath validation ────────────────────────────────────
# The Aug-2026 cross-PF defect passed every config-plane check (interfaces UP,
# SFs attached, BGP configured) while the eswitch silently dropped rep->SF
# delivery on p1. Peer-independent detection: if the WIRE receives frames (the
# ToR sends LLDP every ~30s) but the container-side uplink counter never moves,
# delivery into HBN is dead. Read-only; never fails the bringup — it warns.
info "Step 14/14 — Datapath validation (passive; samples RX counters for 35s)"

# Wire-side counters via ethtool phy stats. LLDP-class frames (01:80:c2:...)
# are multicast and are consumed by the OVS pipeline BY DESIGN — they never
# reach pX_if even on a healthy box. So only BROADCAST + UNICAST wire frames
# count as "should have been delivered" (ARP requests, ND floods, real traffic).
dp_wire_bu() {  # $1=port -> echoes "<bcast+ucast> <total>" from phy counters
  ethtool -S "$1" 2>/dev/null | awk '
    /rx_packets_phy:/{t=$2} /rx_multicast_phy:/{m=$2}
    END{print (t-m)+0, t+0}'
}
declare -A DP_BU0 DP_TOT0 DP_CIF0
DP_PORTS=()
for _P in p0 p1; do
  if [[ ! -e "/sys/class/net/${_P}/carrier" ]]; then
    warn "uplink ${_P}: netdev not found — skipping datapath check"
    continue
  fi
  if [[ "$(cat "/sys/class/net/${_P}/carrier" 2>/dev/null || echo 0)" != "1" ]]; then
    warn "uplink ${_P}: no carrier (cable unplugged or ToR port down) — skipping"
    continue
  fi
  DP_PORTS+=("${_P}")
  read -r "DP_BU0[$_P]" "DP_TOT0[$_P]" <<< "$(dp_wire_bu "${_P}")"
  DP_CIF0[$_P]=$(crictl exec "$CONT" cat "/sys/class/net/${_P}_if/statistics/rx_packets" 2>/dev/null || echo 0)
done
if [[ ${#DP_PORTS[@]} -eq 0 ]]; then
  warn "no uplink has carrier — datapath NOT validated (connect p0/p1, then re-run or use status_hbn.sh)"
else
  info "sampling ${DP_PORTS[*]} for 35s (covers one ToR LLDP interval)..."
  sleep 35
  DP_SUSPECT=""
  for _P in "${DP_PORTS[@]}"; do
    read -r DP_BU1 DP_TOT1 <<< "$(dp_wire_bu "${_P}")"
    DP_BUD=$(( DP_BU1 - DP_BU0[$_P] ))
    DP_TOTD=$(( DP_TOT1 - DP_TOT0[$_P] ))
    DP_CIFD=$(( $(crictl exec "$CONT" cat "/sys/class/net/${_P}_if/statistics/rx_packets" 2>/dev/null || echo 0) - DP_CIF0[$_P] ))
    if [[ ${DP_CIFD} -gt 0 ]]; then
      ok "uplink ${_P}: wire -> container delivery OK (${_P}_if +${DP_CIFD} pkts)"
    elif [[ ${DP_BUD} -ge 3 ]]; then
      # broadcast/unicast arrived on the wire and NONE of it reached the container
      warn "uplink ${_P}: wire received +${DP_BUD} bcast/ucast pkts but ${_P}_if inside HBN got NONE — eswitch is dropping delivery"
      DP_SUSPECT="${DP_SUSPECT} ${_P}"
    elif [[ ${DP_TOTD} -gt 0 ]]; then
      warn "uplink ${_P}: only multicast (LLDP-class) frames in the window — INCONCLUSIVE"
      warn "  (these are consumed by the bridge by design; datapath is proven by Day-0"
      warn "   BGP coming up. If BGP later sits in Active with links UP, run: $0 --check)"
    else
      warn "uplink ${_P}: wire silent for 35s (ToR sending nothing, not even LLDP?) — INCONCLUSIVE"
    fi
  done
  if [[ -n "${DP_SUSPECT}" ]]; then
    warn "DATAPATH SUSPECT on:${DP_SUSPECT} — likely causes, in order:"
    warn "  1) LAG_RESOURCE_ALLOCATION=1 never committed by a TRUE cold power cycle"
    warn "     (x86 host: sudo ipmitool chassis power cycle; ARM reboot is NOT enough,"
    warn "      and a live-set mlxconfig 'Current=1' can be cosmetic)"
    warn "  2) stale sfc state — systemctl restart sfc.service, then re-run this script"
    warn "  NOTE: multicast (LLDP) may still pass while unicast blackholes — a BGP"
    warn "  session stuck in Active/Connect with links UP is the same signature."
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Bringup Complete — Summary"
echo "============================================================"

OOB_IP=$(ip addr show oob_net0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || echo "unknown")
# Count only the sfnums THIS bringup owns (core + requested VFs) — a box may
# carry stray/legacy SFs that would otherwise inflate the number confusingly.
_EXPECT_SFNUMS=(2 3 1514 1515)
for ((i=0; i<P0_VFS; i++)); do _EXPECT_SFNUMS+=( $((ECPF0_VF_SF_BASE+i)) ); done
for ((i=0; i<P1_VFS; i++)); do _EXPECT_SFNUMS+=( $((ECPF1_VF_SF_BASE+i)) ); done
SF_COUNT=0
_SF_PORTS=$(devlink port show 2>/dev/null || true)
for _S in "${_EXPECT_SFNUMS[@]}"; do
  echo "${_SF_PORTS}" | grep -q "sfnum ${_S} " && SF_COUNT=$((SF_COUNT+1))
done
FLOW_COUNT=$(ovs-appctl dpctl/dump-flows type=offloaded 2>/dev/null | grep -c "actions:" || true); FLOW_COUNT=${FLOW_COUNT:-0}
EXPECTED_SFS=$((4 + TOTAL_VFS))

echo ""
printf "  %-25s %s\n" "doca-hbn container:" "Running ($CONT)"
printf "  %-25s %s\n" "SFs provisioned:" "$SF_COUNT (expect ${EXPECTED_SFS})"
printf "  %-25s %s\n" "OVS offloaded flows:" "$FLOW_COUNT"
printf "  %-25s %s\n" "OOB IP:" "$OOB_IP"
printf "  %-25s %s\n" "REST API:" "https://${OOB_IP}:8765/nvue_v1/"
printf "  %-25s %s\n" "REST credentials:" "${REST_USER}:${REST_PASS}"
echo ""
echo "  Next steps:"
echo "    sudo crictl exec -it $CONT vtysh          # FRR CLI"
echo "    sudo crictl exec -it $CONT nv              # NVUE CLI"
echo "    ./topology_hbn.sh                          # Interface reference"
echo "    ./status_hbn.sh                            # Full health check"
echo ""
echo "  NOTE (DOCA 3.3.0): applying NVUE config via REST is broken — after POSTing"
echo "  a revision, apply it with: sudo crictl exec $CONT nv config apply --assume-yes"
echo ""
