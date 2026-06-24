#!/usr/bin/env bash
# setup_host_vfs.sh — Enable SR-IOV VFs on the x86 HOST and rename them to vf0..vfN.
#
# Run this on the x86 HOST (NOT the BF3), with sudo, AFTER HBN is up on the BF3.
# It is independent of the BF3 side and safe to run any time / re-run (idempotent).
#
#   sudo ./setup_host_vfs.sh                 # auto-detect BF3 PFs, 4 VFs/PF -> vf0..vf7
#   sudo ./setup_host_vfs.sh --vfs-per-pf 4
#   sudo ./setup_host_vfs.sh --pf enp65s0f0np0 --pf enp65s0f1np1   # explicit PFs (skip autodetect)
#   sudo ./setup_host_vfs.sh --persist       # also survive reboot (systemd oneshot)
#   sudo ./setup_host_vfs.sh --dry-run       # show what it WOULD do
#
# Auto-detection: finds Mellanox BlueField-3 PFs by PCI device id 0xa2dc
# (a standalone ConnectX-7 like 0x101d is ignored), ordered by phys_port_name (p0,p1,...).
# VFs are numbered sequentially across PFs: PF(p0)->vf0..vf(N-1), PF(p1)->vfN..vf(2N-1).
#
# NOTE: BF3 side is left untouched — doca_hbn.yaml / sfc.conf / pfXvfN_if names stay as-is.
set -euo pipefail

# ─── Config (override via flags) ────────────────────────────────────────────────
BF3_DEVID="0xa2dc"     # PCI device id of BlueField-3 integrated NIC (auto-detect filter)
VFS_PER_PF=4           # per PF; with 2 PFs -> 8 VFs total -> vf0..vf7
PERSIST=false
DRY_RUN=false
PFS=()                 # explicit PF list (via --pf); empty => auto-detect

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pf)          PFS+=("$2"); shift 2 ;;
    --vfs-per-pf)  VFS_PER_PF="$2"; shift 2 ;;
    --devid)       BF3_DEVID="$2"; shift 2 ;;
    --persist)     PERSIST=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

[[ $EUID -ne 0 ]] && fail "Run as root (sudo)"

# ─── Auto-detect BF3 PFs by PCI device id, ordered by phys_port_name ─────────────
# Only a SINGLE BlueField-3 per server is supported. PFs are grouped by the card's
# PCI address (address without the .function, e.g. 0000:41:00); if more than one
# distinct card is present, the script refuses to run to avoid ambiguous VF naming.
discover_bf3_pfs() {
  local rows=() cards=() nd d devid ppn pci group
  for nd in /sys/class/net/*; do
    d=$(basename "$nd")
    [[ -r "$nd/device/device" ]] || continue                 # has a PCI device
    devid=$(cat "$nd/device/device" 2>/dev/null || echo "")
    [[ "$devid" == "$BF3_DEVID" ]] || continue               # is BlueField-3
    [[ -e "$nd/device/sriov_totalvfs" ]] || continue         # is a PF (VFs lack this)
    [[ "$(cat "$nd/device/sriov_totalvfs" 2>/dev/null || echo 0)" -gt 0 ]] || continue
    pci=$(basename "$(readlink -f "$nd/device" 2>/dev/null)" 2>/dev/null)  # 0000:41:00.0
    group="${pci%.*}"                                         # 0000:41:00 (one per card)
    ppn=$(cat "$nd/phys_port_name" 2>/dev/null || echo "zz")  # p0,p1,... for ordering
    rows+=("${ppn}|${d}")
    cards+=("${group}")
  done
  [[ ${#rows[@]} -gt 0 ]] || fail "No BlueField-3 PFs found (device id ${BF3_DEVID}). Pass --pf explicitly."

  # Enforce single-BF3: count distinct PCI card groups
  local ncards
  ncards=$(printf '%s\n' "${cards[@]}" | sort -u | wc -l | tr -d ' ')
  if [[ "$ncards" -gt 1 ]]; then
    warn "Detected ${ncards} BlueField-3 cards: $(printf '%s\n' "${cards[@]}" | sort -u | tr '\n' ' ')"
    fail "VF creation is only supported when there is exactly ONE BlueField-3 in the server. Aborting."
  fi

  # sort by phys_port_name (p0 before p1) and emit just the netdev names
  printf '%s\n' "${rows[@]}" | sort | cut -d'|' -f2
}

if [[ ${#PFS[@]} -eq 0 ]]; then
  mapfile -t PFS < <(discover_bf3_pfs)
  info "Auto-detected BF3 PFs: ${PFS[*]}"
else
  info "Using explicit PFs: ${PFS[*]}"
fi

# ─── Enable SR-IOV + rename one PF's VFs starting at a given vf index ────────────
setup_pf() {
  local pf="$1" base="$2"
  local sysfs="/sys/class/net/${pf}/device/sriov_numvfs"
  [[ -e "$sysfs" ]] || fail "PF '${pf}' not found or not SR-IOV capable ($sysfs missing)"

  # 1. Enable VFs (write only if different; must go through 0 first)
  local cur; cur=$(cat "$sysfs")
  if [[ "$cur" != "$VFS_PER_PF" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      info "  [dry-run] would set ${pf} sriov_numvfs=${VFS_PER_PF} (currently ${cur})"
    else
      [[ "$cur" != "0" ]] && { echo 0 > "$sysfs"; sleep 1; }
      echo "$VFS_PER_PF" > "$sysfs" || fail "Could not set sriov_numvfs on $pf"
      sleep 2
      ok "${pf}: sriov_numvfs=${VFS_PER_PF}"
    fi
  else
    ok "${pf}: already has ${VFS_PER_PF} VFs"
  fi

  # 2. Rename each VF netdev -> vf<base+i> (resolve real name via virtfn symlink)
  local i dst vfpci src
  for ((i=0; i<VFS_PER_PF; i++)); do
    dst="vf$((base + i))"
    if ip link show "$dst" &>/dev/null; then ok "  ${dst} already present"; continue; fi
    vfpci=$(basename "$(readlink -f "/sys/class/net/${pf}/device/virtfn${i}" 2>/dev/null)" 2>/dev/null || true)
    src=""; [[ -n "$vfpci" ]] && src=$(ls "/sys/bus/pci/devices/${vfpci}/net/" 2>/dev/null | head -1 || true)
    if [[ -z "$src" ]]; then warn "  could not resolve VF${i} of ${pf} -> ${dst}"; continue; fi
    if [[ "$DRY_RUN" == "true" ]]; then info "  [dry-run] would rename ${src} -> ${dst}"; continue; fi
    ip link set "$src" down 2>/dev/null || true
    if ip link set "$src" name "$dst" 2>/dev/null; then
      ip link set "$dst" up 2>/dev/null || true; ok "  ${src} -> ${dst}"
    else
      warn "  failed to rename ${src} -> ${dst}"
    fi
  done
}

echo ""
echo "============================================================"
echo "  Host SR-IOV VF setup — vf0..vf$(( VFS_PER_PF*${#PFS[@]} - 1 ))"
echo "  PFs: ${PFS[*]}   VFs/PF: ${VFS_PER_PF}$( [[ $DRY_RUN == true ]] && echo '   [DRY-RUN]')"
echo "============================================================"
echo ""

base=0
for pf in "${PFS[@]}"; do
  setup_pf "$pf" "$base"
  base=$((base + VFS_PER_PF))
done

echo ""
if [[ "$DRY_RUN" != "true" ]]; then
  ok "Done. Host VFs:"
  ip -o link show 2>/dev/null | awk '{print $2}' | tr -d : | grep -E '^vf[0-9]+$' | sort -V | sed 's/^/    /'
fi

# ─── Optional: survive reboot (systemd oneshot re-runs this script) ──────────────
if [[ "$PERSIST" == "true" && "$DRY_RUN" != "true" ]]; then
  SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  PF_ARGS=""; for pf in "${PFS[@]}"; do PF_ARGS+=" --pf ${pf}"; done
  cat > /etc/systemd/system/host-vfs.service <<EOF
[Unit]
Description=Enable + rename BF3 SR-IOV VFs (vf0..vfN)
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SELF}${PF_ARGS} --vfs-per-pf ${VFS_PER_PF}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable host-vfs.service >/dev/null 2>&1
  ok "Persistence enabled — host-vfs.service re-creates + renames VFs on boot (keep script at ${SELF})"
fi
echo ""
