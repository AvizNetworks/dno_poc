#!/usr/bin/env bash
# inventory_bf3.sh — READ-ONLY capability inventory of a BlueField-3 (run on the BF3 ARM)
# Run with sudo: sudo ./inventory_bf3.sh [--quick] [--no-check] [--out FILE]
#
# Answers, for a BF3 we have never seen before:
#   1. Can standalone HBN run here?            (blockers + version gap)
#   2. What can it do?                         (p0 only vs p0+p1, VF capacity, uplink state)
#   3. What would a bringup take over/break?   (existing OVS, IPs, netplan, k8s, pods)
# and finishes by running `bringup_hbn_bf3.sh --check` (also read-only) if present.
#
# NOTHING is changed: no service restarts, no mlxconfig set, no promisc (tcpdump -p).
# The full report is saved (colour-stripped) so the customer can send it back to us.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRINGUP="${SCRIPT_DIR}/bringup_hbn_bf3.sh"
VALIDATED_BUNDLE="3.3.0"        # bf-bundle / DOCA version bringup_hbn_bf3.sh is validated on
HBN_SFNUMS="2 3 1514 1515"      # core SFs the bringup owns
LLDP_WAIT=35                    # seconds to listen for LLDP per uplink (switches send every 30s)
QUICK=false
RUN_CHECK=true
OUT=""
ARGS=("$@")

usage() {
  cat <<EOF
Usage: sudo $0 [OPTIONS]

READ-ONLY capability inventory of a BlueField-3. Changes nothing.

Options:
  --quick       skip the ${LLDP_WAIT}s passive LLDP listen on p0/p1 (no switch/port names)
  --no-check    do not run bringup_hbn_bf3.sh --check at the end
  --out FILE    report path (default: /tmp/bf3-inventory-<hostname>-<timestamp>.txt)
  -h, --help    this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)    QUICK=true; shift ;;
    --no-check) RUN_CHECK=false; shift ;;
    --out)      OUT="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run with sudo (mlxconfig/flint/dmidecode need root). Nothing was changed."; exit 1; }

HOST="$(hostname 2>/dev/null || echo bf3)"
OUT="${OUT:-/tmp/bf3-inventory-${HOST}-$(date +%Y%m%d-%H%M%S).txt}"

# ─── Colors / output ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
section() { echo; echo -e "${CYAN}══ $* ══${NC}"; }
kv()      { printf "  %-28s %s\n" "$1" "$2"; }
good()    { echo -e "  ${GREEN}[ OK ]${NC} $*"; }
note()    { echo -e "  ${YELLOW}[NOTE]${NC} $*"; }
bad()     { echo -e "  ${RED}[BLOCK]${NC} $*"; }

BLOCKERS=(); CAVEATS=(); TAKEOVER=()
block()    { BLOCKERS+=("$*"); bad "$*"; }
caveat()   { CAVEATS+=("$*"); note "$*"; }
takeover() { TAKEOVER+=("$*"); note "$*"; }
have()     { command -v "$1" >/dev/null 2>&1; }

# Re-run ourselves through tee so the whole report (minus colour codes) lands in ${OUT}
if [[ -z "${INV_INNER:-}" ]]; then
  INV_INNER=1 bash "$0" "${ARGS[@]}" --out "${OUT}" 2>&1 | tee "${OUT}.raw"
  rc=${PIPESTATUS[0]}
  sed 's/\x1b\[[0-9;]*m//g' "${OUT}.raw" > "${OUT}" && rm -f "${OUT}.raw"
  exit "$rc"
fi

# PF PCI addresses: from the uplink netdevs, fall back to the usual BF3 slots
pci_of() { basename "$(readlink -f "/sys/class/net/$1/device" 2>/dev/null)" 2>/dev/null; }
PCI0="$(pci_of p0)"; PCI0="${PCI0:-0000:03:00.0}"
PCI1="$(pci_of p1)"; PCI1="${PCI1:-0000:03:00.1}"

# Single-port SKU (e.g. B3140H SuperNIC): no p1 netdev AND no second PCI function.
# (p1 missing but 03:00.1 present = dual-port card in IB mode — still a blocker.)
SINGLE_PORT=false
if [[ ! -e /sys/class/net/p1 && ! -e "/sys/bus/pci/devices/${PCI1}" ]]; then
  SINGLE_PORT=true
  BRINGUP="${SCRIPT_DIR}/bringup_hbn_bf3_single_port.sh"
  HBN_SFNUMS="2 1514"
fi
UPLINKS="p0 p1"; HOST_PFS="pf0hpf pf1hpf"; PFS=("${PCI0}" "${PCI1}")
$SINGLE_PORT && { UPLINKS="p0"; HOST_PFS="pf0hpf"; PFS=("${PCI0}"); }

echo "============================================================"
echo "  BF3 capability inventory (READ-ONLY — nothing is changed)"
echo "  host: ${HOST}   date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "  report: ${OUT}"
echo "============================================================"

# ═══ 1. Identity & software ══════════════════════════════════════════════════
section "1. Identity & software"
BUNDLE="$(head -1 /etc/mlnx-release 2>/dev/null || echo unknown)"
BUNDLE_VER="$(grep -oE 'bf-bundle-[0-9]+\.[0-9]+\.[0-9]+' <<<"${BUNDLE}" | sed 's/bf-bundle-//')"
kv "BFB bundle" "${BUNDLE}"
kv "OS / kernel" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}") / $(uname -r)"
kv "Uptime" "$(uptime -p 2>/dev/null)"
kv "Board serial" "$(dmidecode -s system-serial-number 2>/dev/null || echo ?)"
VPD="$(lspci -s "${PCI0}" -vv 2>/dev/null)"
kv "Product" "$(grep -m1 'Product Name:' <<<"${VPD}" | sed 's/.*Product Name: //')"
kv "Part number" "$(grep -m1 '\[PN\]' <<<"${VPD}" | sed 's/.*: //')"
kv "Port layout" "$($SINGLE_PORT && echo "SINGLE-PORT (p0 only, one PCI function ${PCI0}) → ${BRINGUP##*/}" || echo "dual-port (p0 + p1)")"
if have flint; then
  FQ="$(flint -d "${PCI0}" q 2>/dev/null)"
  kv "Firmware" "$(awk -F': *' '/^FW Version/{print $2}' <<<"${FQ}")"
  kv "PSID" "$(awk -F': *' '/^PSID/{print $2}' <<<"${FQ}")"
fi
kv "CPU cores / RAM" "$(nproc) cores / $(free -g | awk '/^Mem:/{print $2" GB total, "$7" GB available"}')"
kv "Root disk" "$(df -h / | awk 'NR==2{print $2" total, "$4" free"}')"
for p in doca-runtime doca-sdk-common mlnx-ofed-kernel-utils sfc-hbn hbn-runtime doca-openvswitch openvswitch-switch; do
  v="$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || true)"
  [[ -n "$v" ]] && kv "pkg ${p}" "$v"
done

if [[ -z "${BUNDLE_VER}" ]]; then
  caveat "bundle version unknown — cannot confirm compatibility with the ${VALIDATED_BUNDLE}-validated bringup"
elif [[ "${BUNDLE_VER}" == "${VALIDATED_BUNDLE}" ]]; then
  good "bundle ${BUNDLE_VER} = version the standalone bringup is validated on"
else
  caveat "bundle ${BUNDLE_VER} ≠ validated ${VALIDATED_BUNDLE} — bringup (doca_hbn ${VALIDATED_BUNDLE} image + configs) is untested here"
fi

# ═══ 2. Firmware configuration (nvconfig) ════════════════════════════════════
section "2. Firmware config (mlxconfig — Current vs Next Boot)"
NV_KEYS="INTERNAL_CPU_OFFLOAD_ENGINE LINK_TYPE_P1 LINK_TYPE_P2 SRIOV_EN NUM_OF_VFS LAG_RESOURCE_ALLOCATION PF_TOTAL_SF PER_PF_NUM_SF"
declare -A NV_CUR=() NV_NEXT=()
if have mlxconfig; then
  # -e q columns: Default Current NextBoot (plain `q` shows ONLY Next Boot — never trust it)
  nv_query() {  # $@ = keys -> "KEY CURRENT NEXT" lines
    mlxconfig -d "${PCI0}" -e q "$@" 2>/dev/null \
      | awk '{sub(/^[[:space:]]*\*?[[:space:]]*/, "")} NF>=4 && $1 ~ /^[A-Z_0-9]+$/ {print $1, $(NF-1), $NF}'
  }
  # One unknown key (e.g. LINK_TYPE_P2 on a single-port card) fails the WHOLE query,
  # so fall back to one key at a time when the batch comes back empty.
  # shellcheck disable=SC2086
  NV_OUT="$(nv_query ${NV_KEYS})"
  if [[ -z "${NV_OUT}" ]]; then
    for k in ${NV_KEYS}; do NV_OUT+="$(nv_query "$k")"$'\n'; done
  fi
  while read -r key cur nxt; do
    [[ -n "$key" ]] && { NV_CUR[$key]="$cur"; NV_NEXT[$key]="$nxt"; }
  done <<<"${NV_OUT}"
  printf "  %-28s %-26s %s\n" "PARAMETER" "CURRENT (running)" "NEXT BOOT"
  for k in ${NV_KEYS}; do
    [[ -n "${NV_CUR[$k]:-}" ]] || continue
    flag=""; [[ "${NV_CUR[$k]}" != "${NV_NEXT[$k]}" ]] && flag="  <- staged, needs COLD power cycle"
    printf "  %-28s %-26s %s%s\n" "$k" "${NV_CUR[$k]}" "${NV_NEXT[$k]}" "$flag"
  done
  [[ ${#NV_CUR[@]} -eq 0 ]] && caveat "mlxconfig returned nothing for ${PCI0} — firmware settings unknown"
else
  caveat "mlxconfig not installed — firmware settings unknown (install mstflint or query from the x86 host)"
fi

case "${NV_CUR[INTERNAL_CPU_OFFLOAD_ENGINE]:-}" in
  *"(1)"*) block "NIC mode (INTERNAL_CPU_OFFLOAD_ENGINE=DISABLED) — ARM has no datapath role; HBN impossible until DPU mode + cold power cycle" ;;
  *"(0)"*) good "DPU mode (INTERNAL_CPU_OFFLOAD_ENGINE=ENABLED)" ;;
esac
for k in LINK_TYPE_P1 LINK_TYPE_P2; do
  case "${NV_CUR[$k]:-}" in
    *IB*)  block "${k}=${NV_CUR[$k]} — InfiniBand; HBN needs ETH (set LINK_TYPE=2 + TRUE cold power cycle from the x86 host)" ;;
    *ETH*) good "${k}=ETH" ;;
  esac
done
if $SINGLE_PORT; then
  good "single-port card — LAG_RESOURCE_ALLOCATION / multiport not applicable"
else
  case "${NV_CUR[LAG_RESOURCE_ALLOCATION]:-}" in
    *"(1)"*) good "LAG_RESOURCE_ALLOCATION=1 — eswitch multiport possible → BOTH uplinks usable by HBN" ;;
    "")      ;;
    *)       caveat "LAG_RESOURCE_ALLOCATION=${NV_CUR[LAG_RESOURCE_ALLOCATION]} — only p0 usable by HBN (p1 blackholes) until set to 1 + TRUE cold power cycle"
             [[ "${NV_NEXT[LAG_RESOURCE_ALLOCATION]:-}" == *"(1)"* ]] && note "  (already staged for next boot — only the cold power cycle is missing)" ;;
  esac
fi
VF_CAP=0
if [[ "${NV_CUR[SRIOV_EN]:-}" == *"(1)"* ]]; then
  VF_CAP="${NV_CUR[NUM_OF_VFS]:-0}"
  good "SR-IOV enabled — up to ${VF_CAP} VFs per host PF (firmware ceiling)"
elif [[ -n "${NV_CUR[SRIOV_EN]:-}" ]]; then
  caveat "SR-IOV disabled in firmware — no host VFs possible (--vfs unusable)"
fi

# ═══ 3. eswitch ═══════════════════════════════════════════════════════════════
section "3. eswitch"
for pci in "${PFS[@]}"; do
  mode="$(devlink dev eswitch show "pci/${pci}" 2>&1 | grep -oE ' mode [a-z]+' | head -1 | awk '{print $2}')"
  if [[ "${mode}" == "switchdev" ]]; then good "${pci}: switchdev"
  else block "${pci}: eswitch mode '${mode:-unsupported}' — HBN needs switchdev (InfiniBand or NIC mode shows 'unsupported')"; fi
done
if ! $SINGLE_PORT; then
  MP="$(devlink dev param show "pci/${PCI0}" name esw_multiport 2>/dev/null | grep -oE 'value (true|false)' | awk '{print $2}' | head -1)"
  kv "esw_multiport (runtime)" "${MP:-unsupported}"
  kv "mlnx-bf.conf multiport" "$(grep -E '^ENABLE_ESWITCH_MULTIPORT' /etc/mellanox/mlnx-bf.conf 2>/dev/null || echo 'not set')"
fi

# ═══ 4. Uplinks ══════════════════════════════════════════════════════════════
section "4. Uplinks (physical ports)"
declare -A LLDP_FILE=()
if ! $QUICK && have tcpdump; then
  echo "  listening ${LLDP_WAIT}s for LLDP on ${UPLINKS// /\/} (passive, non-promisc; --quick skips)..."
  for u in ${UPLINKS}; do
    [[ -e "/sys/class/net/$u" ]] || continue
    LLDP_FILE[$u]="$(mktemp)"
    timeout "${LLDP_WAIT}" tcpdump -p -i "$u" -nn -v -c1 'ether proto 0x88cc' >"${LLDP_FILE[$u]}" 2>/dev/null &
  done
  wait
fi
for u in ${UPLINKS}; do
  if [[ ! -e "/sys/class/net/$u" ]]; then block "$u netdev missing (InfiniBand mode? check section 2)"; continue; fi
  carrier="$(cat "/sys/class/net/$u/carrier" 2>/dev/null || echo 0)"
  speed="$(ethtool "$u" 2>/dev/null | awk -F': ' '/Speed:/{print $2}')"
  mtu="$(cat "/sys/class/net/$u/mtu")"
  addrs="$(ip -o addr show dev "$u" scope global 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
  [[ "$carrier" == "1" ]] && link="UP" || link="DOWN (no carrier/cable)"
  kv "$u" "link ${link}, speed ${speed:-?}, mtu ${mtu}, mac $(cat "/sys/class/net/$u/address")"
  [[ -n "$addrs" ]] && { kv "" "IPs: ${addrs}"; takeover "$u carries IP(s) ${addrs}— HBN moves the uplink into its container (p0_if/p1_if); these stop working"; }
  if [[ -n "${LLDP_FILE[$u]:-}" ]]; then
    # tcpdump -v: "System Name TLV (5), length 10: leaf-cn-00" (value on the same line);
    #             "Port ID TLV (2) ..." then next line "  Subtype Local (7): Eth51/1"
    sys="$(grep -m1 'System Name TLV' "${LLDP_FILE[$u]}" | sed 's/.*: //')"
    pid="$(grep -m1 -A1 'Port ID TLV' "${LLDP_FILE[$u]}" | tail -1 | sed 's/.*: //')"
    pdesc="$(grep -m1 'Port Description TLV' "${LLDP_FILE[$u]}" | sed 's/.*: //')"
    sdesc="$(grep -m1 -A1 'System Description TLV' "${LLDP_FILE[$u]}" | tail -1 | sed 's/^[[:space:]]*//' | cut -c1-70)"
    if [[ -n "$sys$pid" ]]; then
      kv "" "LLDP neighbor: ${sys:-?} port ${pid:-?}${pdesc:+ (${pdesc})}"
      [[ -n "$sdesc" ]] && kv "" "  switch OS: ${sdesc}"
    else kv "" "LLDP neighbor: none heard in ${LLDP_WAIT}s"; fi
    rm -f "${LLDP_FILE[$u]}"
  elif have lldpctl && lldpctl "$u" 2>/dev/null | grep -q SysName; then
    kv "" "LLDP neighbor: $(lldpctl "$u" | awk -F': *' '/SysName/{s=$2} /PortID/{p=$2} END{print s" port "p}')"
  fi
  [[ "$carrier" == "1" ]] || caveat "$u has no link — HBN can be brought up but this uplink will carry no traffic"
done

# ═══ 5. Host-facing interfaces ═══════════════════════════════════════════════
section "5. Host-facing (x86 side, seen from the BF3)"
for h in ${HOST_PFS}; do
  [[ -e "/sys/class/net/$h" ]] && kv "$h" "present (host PF representor)" || kv "$h" "MISSING"
done
VF_REPS=0
for n in /sys/class/net/*; do
  ppn="$(cat "$n/phys_port_name" 2>/dev/null)" || continue
  [[ "$ppn" =~ pf[01]vf[0-9]+$ ]] && VF_REPS=$((VF_REPS+1))
done
kv "host VFs currently created" "${VF_REPS} (VF representors on the BF3)"
[[ "${VF_REPS}" -eq 0 ]] && note "no host VFs yet — for --vfs, create them on the x86 host FIRST (setup_host_vfs_standalone.sh)"

# ═══ 6. Existing networking a bringup would take over ═══════════════════════
section "6. Existing networking (what an HBN bringup would take over)"
SF_LIST="$(devlink port show 2>/dev/null | grep -oE 'sfnum [0-9]+' | awk '{print $2}' | sort -n | tr '\n' ' ')"
kv "SubFunctions (sfnum)" "${SF_LIST:-none}"
OTHER_SF=()
for s in ${SF_LIST}; do
  [[ " ${HBN_SFNUMS} " == *" $s "* ]] && continue
  [[ "$s" -ge 1001 ]] && continue
  OTHER_SF+=("$s")
done
[[ ${#OTHER_SF[@]} -gt 0 ]] && takeover "non-HBN SFs present (sfnum ${OTHER_SF[*]}) — something else (stock BFB / DPF / other tool) created them; bringup regenerates mlnx-sf.conf"
if have ovs-vsctl && ovs-vsctl show >/dev/null 2>&1; then
  for br in $(ovs-vsctl list-br 2>/dev/null); do
    ports="$(ovs-vsctl list-ports "$br" 2>/dev/null | tr '\n' ' ')"
    kv "OVS bridge ${br}" "${ports:-<no ports>}"
    case "$br" in
      br-hbn) [[ -n "$ports" ]] && note "br-hbn already exists — bringup (sfc.sh) owns and rebuilds it" ;;
      ovsbr1|ovsbr2) takeover "stock BFB bridge ${br} (uplink+host PF switching) — sfc.service replaces it with br-hbn; host traffic path changes" ;;
      *) takeover "OVS bridge ${br} (ports: ${ports:-none}) — not ours; check what it does before bringup" ;;
    esac
  done
else
  kv "OVS" "not running"
fi
for t in bridge vxlan vlan bond; do
  l="$(ip -o -d link show type "$t" 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -vE '^(br-hbn|br-sfc|ovs-system|ovs-doca|ovsbr[12])$' | tr '\n' ' ')"
  [[ -n "$l" ]] && { kv "kernel ${t}s" "$l"; takeover "kernel ${t}(s) ${l}— may depend on uplinks/SFs HBN takes over"; }
done
SF_IPS="$(ip -o addr show scope global 2>/dev/null | awk '$2 ~ /^(en[0-9]+f[0-9]+.*s[0-9]+|enp[0-9]+s0f[0-9]+s[0-9]+|pf[01]hpf)/ {print $2"="$4}' | tr '\n' ' ')"
[[ -n "$SF_IPS" ]] && takeover "IPs on SF/host-PF netdevs: ${SF_IPS}— the stock 'sf0/sf1' mgmt path; check nothing (DHCP mgmt, overlay) relies on it"
kv "netplan files" "$(ls /etc/netplan 2>/dev/null | tr '\n' ' ')"
for f in /etc/netplan/*.yaml; do
  [[ -f "$f" ]] || continue
  refs="$(grep -oE '\b(p0|p1|pf0hpf|pf1hpf|en[0-9a-z]*s[0-9]+|enp[0-9]+s0f[0-9]+s[0-9]+)\b' "$f" 2>/dev/null | sort -u | tr '\n' ' ')"
  [[ -n "$refs" ]] && kv "  ${f##*/}" "references: ${refs}"
done
OOB_IP="$(ip -o -4 addr show dev oob_net0 2>/dev/null | awk '{print $4}')"
kv "OOB (oob_net0)" "${OOB_IP:-none} $(grep -qs dhcp4:.*true /etc/netplan/*oob* 2>/dev/null && echo '(DHCP — may change on reboot)')"

# ═══ 7. Runtime, cluster & workloads ═════════════════════════════════════════
section "7. Runtime, Kubernetes & workloads"
for u in containerd kubelet sfc; do
  st=inactive
  for unit in "${u}@mgmt.service" "${u}.service"; do
    systemctl is-active --quiet "$unit" 2>/dev/null && { st="active (${unit})"; break; }
  done
  kv "${u}" "$st"
done
if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  api="$(awk '/server:/{print $2; exit}' /etc/kubernetes/kubelet.conf)"
  kv "kubelet joined to" "${api}"
  takeover "kubelet is joined to an EXTERNAL cluster (${api}) — BF3 is managed by DPF/NICo/other; standalone HBN would conflict with that controller"
else
  kv "kubelet mode" "standalone (static pods from /etc/kubelet.d)"
fi
# bringup_hbn_bf3.sh drops doca_hbn.yaml into /etc/kubelet.d — kubelet must actually read that dir
KCFG="$(ps -o args= -C kubelet 2>/dev/null | grep -oE -- '--config[= ][^ ]+' | head -1 | sed 's/--config[= ]//')"
KCFG="${KCFG:-/var/lib/kubelet/config.yaml}"
SPP="$(awk '/^staticPodPath:/{print $2}' "${KCFG}" 2>/dev/null)"
kv "kubelet staticPodPath" "${SPP:-<unset>} (from ${KCFG})"
kv "static pod specs" "$(ls "${SPP:-/etc/kubelet.d}" 2>/dev/null | tr '\n' ' ')"
if [[ -n "${SPP}" && "${SPP%/}" != "/etc/kubelet.d" ]]; then
  block "kubelet reads static pods from ${SPP}, but bringup installs doca_hbn.yaml into /etc/kubelet.d — HBN pod would never start (bringup --check does not catch this)"
fi
if journalctl -u kubelet -n 50 --no-pager 2>/dev/null | grep -q 'error getting node'; then
  note "kubelet cannot find its own Node object in that cluster — BF3 looks ORPHANED from its controller"
fi
if have crictl; then
  pods="$(crictl pods -q --state ready 2>/dev/null | wc -l)"
  kv "running pods" "${pods}"
  crictl pods --state ready 2>/dev/null | awk 'NR>1{print "    - "$(NF-3)" (ns "$(NF-2)")"}' | head -20
  [[ "${pods}" -gt 0 ]] && note "running pods share the BF3 CPUs/memory — check none uses p0/p1/SFs"
  HBN_IMG="$(crictl images 2>/dev/null | awk '/doca_hbn/{print $1":"$2}' | tr '\n' ' ')"
  kv "doca_hbn image" "${HBN_IMG:-not present}"
  [[ -z "${HBN_IMG}" ]] && caveat "doca_hbn image missing — needs nvcr.io access or an offline tar import"
  crictl ps 2>/dev/null | grep -q doca-hbn && note "doca-hbn is ALREADY running here"
  OTHER_IMG="$(crictl images 2>/dev/null | awk 'NR>1 && $1 !~ /pause|doca_hbn/{print $1}' | sed 's#.*/##' | sort -u | tr '\n' ' ')"
  [[ -n "${OTHER_IMG}" ]] && kv "other images cached" "${OTHER_IMG}"
fi
HP="$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || echo 0)"
kv "hugepages (2MB)" "${HP} allocated ($((HP*2)) MB); HBN needs 1600"

# ═══ 8. Who else uses this box ═══════════════════════════════════════════════
section "8. Recent use"
kv "logged in now" "$(who | awk '{print $1"@"$NF}' | tr '\n' ' ')"
echo "  last logins:"
last -n 8 -w 2>/dev/null | grep -vE '^(reboot|wtmp|$)' | sed 's/^/    /'

# ═══ 9. Bringup preflight ════════════════════════════════════════════════════
CHECK_RC="skipped"
if $RUN_CHECK; then
  section "9. ${BRINGUP##*/} --check (read-only)"
  if [[ -x "${BRINGUP}" ]]; then
    "${BRINGUP}" --check 2>&1 | sed 's/^/  │ /'
    CHECK_RC="${PIPESTATUS[0]}"
    [[ "${CHECK_RC}" == "0" ]] || block "bringup preflight reported blockers (see section 9)"
  else
    CHECK_RC="n/a"; note "${BRINGUP##*/} not found next to this script — copy the full repo to run it"
  fi
fi

# ═══ Verdict ═════════════════════════════════════════════════════════════════
section "VERDICT"
if [[ ${#BLOCKERS[@]} -eq 0 ]]; then
  echo -e "  ${GREEN}1. HBN CAN RUN${NC}$( [[ ${#CAVEATS[@]} -gt 0 ]] && echo ' — with caveats below')"
else
  echo -e "  ${RED}1. HBN CANNOT RUN YET — ${#BLOCKERS[@]} blocker(s):${NC}"
  for b in "${BLOCKERS[@]}"; do echo "       - $b"; done
fi
if $SINGLE_PORT; then up="p0 only (single-port card — use ${BRINGUP##*/})"
elif [[ "${NV_CUR[LAG_RESOURCE_ALLOCATION]:-}" == *"(1)"* ]]; then up="p0 + p1 (both uplinks)"
else up="p0 only (p1 needs LAG_RESOURCE_ALLOCATION=1 + cold power cycle)"; fi
echo "  2. CAPABILITY: uplinks ${up}; host VFs up to ${VF_CAP}/PF (firmware), ${VF_REPS} created now; bringup --check rc=${CHECK_RC}"
if [[ ${#TAKEOVER[@]} -eq 0 ]]; then
  echo -e "  3. TAKEOVER: ${GREEN}nothing found that a bringup would disrupt${NC}"
else
  echo -e "  3. TAKEOVER: ${YELLOW}a bringup would affect ${#TAKEOVER[@]} existing thing(s) — get the owner's OK:${NC}"
  for t in "${TAKEOVER[@]}"; do echo "       - $t"; done
fi
if [[ ${#CAVEATS[@]} -gt 0 ]]; then
  echo "  CAVEATS:"
  for c in "${CAVEATS[@]}"; do echo "       - $c"; done
fi
echo
echo "  Report saved: ${OUT}   (nothing on this BF3 was changed)"
[[ ${#BLOCKERS[@]} -eq 0 ]]
