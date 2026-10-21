#!/usr/bin/env bash
# hbn_quickstart.sh — ONE command on the x86 HOST: BF3 → DPU mode → bf-bundle 3.3.0 →
# HBN with host VFs → hand-over facts for ONES.   Run it until it prints DONE.
#
#   sudo ./scripts/hbn_quickstart.sh [--config FILE] [--check] [--yes] [--power-cycle]
#
# Runs on the x86 host that holds the BF3. Reaches the BF3 over rshim/tmfifo, so the BF3
# needs no network, console or password beforehand. Each phase checks state first and
# skips what is already done. When a cold power cycle is needed it stops (exit 3):
# power-cycle the server, then run the SAME command again.
#
# It only ORCHESTRATES — the per-step scripts are used unchanged and still work by hand:
#   host: setup_host_vfs_standalone.sh
#   BF3 : inventory_bf3.sh, bringup_hbn_bf3.sh / bringup_hbn_bf3_single_port.sh, status_hbn.sh
#
# Exit codes: 0 = DONE (or --check found nothing blocking), 1 = error/blocked,
#             3 = power cycle (or host reboot) needed — then re-run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="/var/lib/hbn-quickstart"
SSH_KEY="${STATE_DIR}/id_ed25519"
SECRETS="${STATE_DIR}/secrets.env"
VALIDATED_BUNDLE="3.3.0"
BFB_NAME="bf-bundle-3.3.0-202_26.01_ubuntu-24.04_64k_prod.bfb"
BFB_URL="https://content.mellanox.com/BlueField/BFBs/Ubuntu24.04/${BFB_NAME}"
HBN_IMAGE=$(awk '/image:/{print $2; exit}' "${REPO_DIR}/doca_hbn_v3.3.0/configs/3.3.0/doca_hbn.yaml" 2>/dev/null)
HBN_IMAGE="${HBN_IMAGE:-nvcr.io/nvidia/doca/doca_hbn:3.3.0-doca3.3.0}"
IMAGE_TAR_NAME="doca_hbn_${HBN_IMAGE##*:}.tar"
HOST_TMFIFO_IP="192.168.100.1"
BF3_TMFIFO_IP="192.168.100.2"        # BFB default on the BF3 side of tmfifo
BF3_PKG_DIR="hbn-standalone"         # under /home/ubuntu on the BF3

# ─── Site settings (override in --config FILE; see hbn_quickstart.env.sample) ─
VFS_PER_PF=4             # host VFs per BF3 PF (0 = no VFs)
HOST_PF_IN_HBN=yes       # no = --no-pf (single-port only): host PF stays outside HBN
ENABLE_BGP=yes
REST_PASSWORD=""         # NVUE REST user 'nvidia'; generated + saved if empty
BF3_PASSWORD=""          # BF3 'ubuntu' password; generated if empty (flash) — set it to adopt an existing install
OOB_ADDRESS=""           # BF3 management port, CIDR (e.g. 10.0.1.105/24); empty = leave as is
OOB_GATEWAY=""
OOB_DNS="8.8.8.8"
BFB_FILE=""              # local .bfb; empty = look next to the package, then download
HBN_IMAGE_TAR=""         # local doca_hbn image tar; empty = look next to the package, else pull on the BF3
BF3_BMC=""               # optional: BF3 BMC IP + password → Redfish for the NIC→DPU mode switch
BF3_BMC_USER="root"
BF3_BMC_PASSWORD=""
BF3_PCI=""               # host PCI address of BF3 PF0 (only if the host has several BF3s)

CONFIG=""; CHECK=false; YES=false; AUTO_POWER=false; REFLASH=false; FORCE=false
LOG=""; BF3_AUTH=key     # key = quickstart SSH key; pass = BF3_PASSWORD via sshpass

usage() {
  cat <<EOF
Usage: sudo $0 [OPTIONS]

One command to get a BlueField-3 from "installed" to "HBN running, ready for ONES".
Re-run the same command until it prints DONE (it stops when a power cycle is needed).

Options:
  --config FILE   site settings (default: hbn_quickstart.env next to scripts/, if present)
  --check         read-only: detect state and print the plan; change nothing
  --yes           do not ask before destructive steps (BF3 flash, VF re-create, mode switch)
  --power-cycle   run 'ipmitool chassis power cycle' itself when one is needed
  --reflash       flash the BF3 even if it already runs bf-bundle ${VALIDATED_BUNDLE}
  --force         proceed although the BF3 looks managed by something else
  -h, --help      this help

Files: state, keys, generated passwords and the ONES hand-over go to ${STATE_DIR}/
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)      CONFIG="${2:?--config needs a file}"; shift ;;
    --check)       CHECK=true ;;
    --yes|-y)      YES=true ;;
    --power-cycle) AUTO_POWER=true ;;
    --reflash)     REFLASH=true ;;
    --force)       FORCE=true ;;
    -h|--help)     usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

# ─── Output ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
PHASE_N=0
phase() { PHASE_N=$((PHASE_N+1)); echo; echo -e "${CYAN}${BOLD}[${PHASE_N}/8] $*${NC}"; }
ok()    { echo -e "  ${GREEN}[ OK ]${NC} $*"; }
info()  { echo -e "  ${CYAN}[INFO]${NC} $*"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
plan()  { echo -e "  ${YELLOW}[PLAN]${NC} $*"; }
die()   { echo -e "  ${RED}[FAIL]${NC} $*"; echo; exit 1; }

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }

# Config precedence: defaults < generated secrets from earlier runs < config file
[[ -f "${SECRETS}" ]] && source "${SECRETS}"
[[ -z "${CONFIG}" && -f "${REPO_DIR}/hbn_quickstart.env" ]] && CONFIG="${REPO_DIR}/hbn_quickstart.env"
if [[ -n "${CONFIG}" ]]; then
  [[ -f "${CONFIG}" ]] || die "config file not found: ${CONFIG}"
  # shellcheck disable=SC1090
  source "${CONFIG}"
fi
[[ "${VFS_PER_PF}" =~ ^[0-9]+$ ]] || die "VFS_PER_PF must be a number (got '${VFS_PER_PF}')"

if ! $CHECK; then
  mkdir -p "${STATE_DIR}" && chmod 700 "${STATE_DIR}"
  LOG="${STATE_DIR}/quickstart-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "${LOG}") 2>&1
fi

echo "============================================================"
echo "  HBN quickstart — $(hostname) — $(date -u '+%Y-%m-%d %H:%M UTC')"
$CHECK && echo "  MODE: --check (read-only — nothing is changed)"
[[ -n "${CONFIG}" ]] && echo "  config: ${CONFIG}"
echo "============================================================"

# ─── Helpers ─────────────────────────────────────────────────────────────────
confirm() {  # $1 = question
  $YES && return 0
  [[ -t 0 ]] || die "$1 — re-run with --yes to allow this non-interactively"
  local a; read -r -p "  $1 [y/N] " a
  [[ "$a" == [yY]* ]]
}

gen_password() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16; }

save_secret() {  # $1=VAR  $2=value — persist generated secrets so re-runs reuse them
  touch "${SECRETS}" && chmod 600 "${SECRETS}"
  sed -i "/^$1=/d" "${SECRETS}"
  printf '%s=%q\n' "$1" "$2" >> "${SECRETS}"
}

boot_id() { cat /proc/sys/kernel/random/boot_id; }

need_power_cycle() {  # $1 = why
  echo
  echo -e "  ${YELLOW}${BOLD}► COLD POWER CYCLE NEEDED:${NC} $1"
  echo "    A warm reboot is NOT enough — power must drop to the PCIe slot."
  if $AUTO_POWER && command -v ipmitool >/dev/null && [[ -e /dev/ipmi0 || -e /dev/ipmi/0 || -e /dev/ipmidev/0 ]]; then
    echo "    --power-cycle: running 'ipmitool chassis power cycle' in 10s (Ctrl-C to abort)..."
    sleep 10; sync; ipmitool chassis power cycle
  else
    echo "    Run:  sudo ipmitool chassis power cycle     (or power-cycle via the host BMC)"
  fi
  echo "    Then run the same command again:  sudo $0${CONFIG:+ --config ${CONFIG}}"
  exit 3
}

# SSH to the BF3 over tmfifo. Host keys change on every flash → never pinned.
bf3_ssh() {
  local o=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8)
  if [[ "${BF3_AUTH}" == pass ]]; then
    SSHPASS="${BF3_PASSWORD}" sshpass -e ssh "${o[@]}" -o PubkeyAuthentication=no "ubuntu@${BF3_TMFIFO_IP}" "$@"
  else
    ssh -i "${SSH_KEY}" -o BatchMode=yes "${o[@]}" "ubuntu@${BF3_TMFIFO_IP}" "$@"
  fi
}

# Run a bash snippet as root on the BF3. The snippet travels base64-encoded and runs from a
# file; sudo -k forces the password prompt every time. The snippet starts with
# 'exec </dev/null' because with NOPASSWD sudo (what bf.cfg's ubuntu_PASSWORD sets up)
# sudo does not consume the password line — nothing inside may read it.
bf3_sudo() {
  local b64; b64=$(printf 'exec </dev/null\n%s\n' "$1" | base64 -w0)
  printf '%s\n' "${BF3_PASSWORD}" | bf3_ssh \
    "f=\$(mktemp); echo ${b64} | base64 -d > \$f; sudo -k -S -p '' bash \$f; rc=\$?; rm -f \$f; exit \$rc"
}

redfish() {  # $1=method $2=path [$3=json]
  curl -sk --max-time 30 -u "${BF3_BMC_USER}:${BF3_BMC_PASSWORD}" -X "$1" \
       ${3:+-H 'Content-Type: application/json' -d "$3"} "https://${BF3_BMC}$2"
}

# ═══ Phase 1: find the BF3 on this host ══════════════════════════════════════
phase "Find the BF3 on this host"
mapfile -t _CANDS < <(for d in /sys/bus/pci/devices/*; do
  [[ "$(cat "$d/vendor" 2>/dev/null)" == "0x15b3" && "$(cat "$d/device" 2>/dev/null)" == "0xa2dc" \
     && "$(basename "$d")" == *.0 ]] && basename "$d"; done)
if [[ -n "${BF3_PCI}" ]]; then
  [[ "${BF3_PCI}" == *:*:*.* ]] || BF3_PCI="0000:${BF3_PCI}"
  [[ -e "/sys/bus/pci/devices/${BF3_PCI}" ]] || die "BF3_PCI=${BF3_PCI} not found on this host"
  HOST_PF0="${BF3_PCI}"
elif [[ ${#_CANDS[@]} -eq 1 ]]; then
  HOST_PF0="${_CANDS[0]}"
elif [[ ${#_CANDS[@]} -eq 0 ]]; then
  die "no BlueField-3 (15b3:a2dc) found. If the BF3 was just re-flashed, reboot this host first"
else
  die "several BF3 cards (${_CANDS[*]}) — set BF3_PCI=<one of them> in the config"
fi
_SLOT="${HOST_PF0%.*}"
mapfile -t HOST_PFS < <(for d in /sys/bus/pci/devices/${_SLOT}.*; do
  [[ "$(cat "$d/device" 2>/dev/null)" == "0xa2dc" ]] && basename "$d"; done)
RSHIM_BDF=$(for d in /sys/bus/pci/devices/${_SLOT}.*; do
  [[ "$(cat "$d/device" 2>/dev/null)" == "0xc2d5" ]] && basename "$d"; done | head -1)
HOST_PF0_NETDEV=$(ls "/sys/bus/pci/devices/${HOST_PF0}/net" 2>/dev/null | head -1)
ok "BF3 at ${HOST_PF0} — host PF(s): ${HOST_PFS[*]}${HOST_PF0_NETDEV:+ (PF0 netdev ${HOST_PF0_NETDEV})}"
[[ -n "${RSHIM_BDF}" ]] && ok "BF3 management (rshim) function: ${RSHIM_BDF}" \
  || warn "rshim PCI function not visible (expected while the BF3 Arm is down)"
[[ -n "${HOST_PF0_NETDEV}" ]] || warn "PF0 has no netdev — if the BF3 was just flashed, reboot this host"

# ═══ Phase 2: DPU mode ═══════════════════════════════════════════════════════
# Host view: NIC mode = the host owns the eswitch (devlink shows 'mode legacy');
#            DPU mode = the BF3 Arm owns it (host devlink: 'Operation not supported').
phase "DPU mode"
ESW=$(devlink dev eswitch show "pci/${HOST_PF0}" 2>&1 || true)
MARKER="${STATE_DIR}/mode-switch-staged"
if echo "${ESW}" | grep -qi "not supported"; then
  ok "BF3 is in DPU mode"
  rm -f "${MARKER}" 2>/dev/null
elif echo "${ESW}" | grep -qE "mode (legacy|switchdev)"; then
  warn "BF3 is in NIC mode — the Arm cannot run HBN"
  if [[ -f "${MARKER}" && "$(cat "${MARKER}")" == "$(boot_id)" ]]; then
    $CHECK && { plan "DPU mode is staged — only the cold power cycle is missing"; exit 0; }
    need_power_cycle "DPU mode is staged and waits for it"
  fi
  [[ -f "${MARKER}" ]] && warn "DPU mode was staged before the last boot but did not apply — that boot was probably a WARM reboot"
  if [[ -n "${BF3_BMC}" && -n "${BF3_BMC_PASSWORD}" ]]; then METHOD=redfish
  elif command -v mstconfig >/dev/null; then METHOD=mstconfig
  else die "cannot switch the mode: set BF3_BMC + BF3_BMC_PASSWORD (Redfish, recommended) or install mstflint (apt install mstflint)"
  fi
  if $CHECK; then plan "switch to DPU mode via ${METHOD}, then a cold power cycle"; exit 0; fi
  confirm "Switch the BF3 to DPU mode (via ${METHOD}; needs a cold power cycle)?" || die "aborted"
  if [[ "${METHOD}" == redfish ]]; then
    # validated path: stage in UEFI settings → Arm reset so UEFI applies it → cold cycle
    redfish PATCH /redfish/v1/Systems/Bluefield/Bios/Settings '{"Attributes":{"NicMode":"DpuMode"}}' >/dev/null \
      || die "Redfish PATCH to ${BF3_BMC} failed (check BF3_BMC / BF3_BMC_PASSWORD)"
    ok "DpuMode staged in the BF3 UEFI settings"
    systemctl enable --now rshim >/dev/null 2>&1
    sleep 5
    RSH=$(grep -l "${RSHIM_BDF:-none}" /dev/rshim*/misc 2>/dev/null | head -1)
    [[ -n "${RSH}" ]] || die "no host rshim for the BF3 — on the BF3 BMC run 'systemctl stop rshim', then re-run"
    echo "SW_RESET 1" > "${RSH}"
    info "BF3 Arm reset so its UEFI applies the setting — waiting up to 5 min..."
    for _ in $(seq 1 30); do
      sleep 10
      redfish GET /redfish/v1/Systems/Bluefield/Bios/Settings | grep -q '"NicMode"' || break
    done
    redfish GET /redfish/v1/Systems/Bluefield/Bios/Settings | grep -q '"NicMode"' \
      && warn "setting still pending after 5 min — power-cycling anyway; re-run reports if it did not apply"
  else
    # NVIDIA-documented host-side path (NIC mode lets the host change nvconfig)
    mstconfig -d "${HOST_PF0}" -y set INTERNAL_CPU_OFFLOAD_ENGINE=0 \
      || die "mstconfig failed — use the Redfish path (BF3_BMC + BF3_BMC_PASSWORD)"
    ok "INTERNAL_CPU_OFFLOAD_ENGINE=0 (DPU mode) staged"
  fi
  boot_id > "${MARKER}"
  need_power_cycle "to switch the BF3 to DPU mode"
else
  die "cannot read the BF3 eswitch mode from the host: ${ESW}"
fi

# ═══ Phase 3: BF3 OS (bf-bundle 3.3.0) ═══════════════════════════════════════
phase "BF3 operating system (bf-bundle ${VALIDATED_BUNDLE})"
RSH=""
for _ in 1 2 3; do
  RSH=$(grep -l "${RSHIM_BDF:-none}" /dev/rshim*/misc 2>/dev/null | head -1)
  [[ -n "${RSH}" ]] && break
  if $CHECK; then break; fi
  systemctl enable --now rshim >/dev/null 2>&1; sleep 5
done
if [[ -z "${RSH}" ]]; then
  $CHECK && { plan "host rshim not running — would start it (systemctl enable --now rshim)"; } \
         || die "no host rshim for ${RSHIM_BDF:-the BF3}. The BF3 BMC may own it: on the BMC 'systemctl stop rshim' (or Redfish BmcRShimEnabled=false), then re-run"
fi
RSHIM_DEV=$(dirname "${RSH:-/dev/rshim0/misc}"); RSHIM_NAME=$(basename "${RSHIM_DEV}")
TMFIFO="tmfifo_net${RSHIM_NAME#rshim}"
TMFIFO_READY=false
if [[ -n "${RSH}" ]]; then
  ok "host owns rshim: ${RSHIM_DEV}"
  if ip -4 addr show "${TMFIFO}" 2>/dev/null | grep -q "${HOST_TMFIFO_IP}/"; then
    TMFIFO_READY=true
  elif $CHECK; then
    plan "would set ${HOST_TMFIFO_IP}/30 on ${TMFIFO} (host side of the rshim network link)"
  else
    ip addr add "${HOST_TMFIFO_IP}/30" dev "${TMFIFO}" 2>/dev/null; ip link set "${TMFIFO}" up 2>/dev/null
    ok "${TMFIFO} = ${HOST_TMFIFO_IP}/30 (host side of the rshim network link)"; TMFIFO_READY=true
  fi
fi

if ! $CHECK && [[ ! -f "${SSH_KEY}" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C "hbn-quickstart@$(hostname)" -f "${SSH_KEY}" && ok "SSH key created: ${SSH_KEY}"
fi

# Can we log in? Our key first; else BF3_PASSWORD (= adopt an existing install), and in a
# real run install our key with it so later steps need no sshpass.
BF3_LOGIN=false; BF3_BUNDLE=""
if $TMFIFO_READY; then
  if [[ -f "${SSH_KEY}" ]] && bf3_ssh true 2>/dev/null; then
    BF3_LOGIN=true
  elif [[ -n "${BF3_PASSWORD}" ]]; then
    if ! command -v sshpass >/dev/null; then
      warn "BF3_PASSWORD is set but sshpass is missing (apt install sshpass) — cannot use it"
    else
      BF3_AUTH=pass
      if bf3_ssh true 2>/dev/null; then
        BF3_LOGIN=true
        if ! $CHECK; then
          bf3_ssh 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' \
            < "${SSH_KEY}.pub" && BF3_AUTH=key && bf3_ssh true 2>/dev/null \
            && ok "logged in with BF3_PASSWORD and installed the quickstart SSH key"
          [[ "${BF3_AUTH}" == key ]] || warn "could not install the SSH key — continuing with the password"
        fi
      else
        BF3_AUTH=key; warn "BF3_PASSWORD did not work for 'ubuntu'"
      fi
    fi
  fi
fi
if $BF3_LOGIN; then
  BF3_BUNDLE=$(bf3_ssh "head -1 /etc/mlnx-release" 2>/dev/null)
  ok "BF3 reachable over rshim (${BF3_TMFIFO_IP}) — OS: ${BF3_BUNDLE:-unknown}"
elif $CHECK && ! $TMFIFO_READY; then
  plan "BF3 login not probed (rshim link not set up yet) — a real run probes it, and flashes"
  plan "the BF3 unless it is a reachable bf-bundle ${VALIDATED_BUNDLE} install (set BF3_PASSWORD to adopt one)"
  exit 0
fi

DO_FLASH=false
if $REFLASH; then DO_FLASH=true; REASON="--reflash given"
elif $BF3_LOGIN && [[ "${BF3_BUNDLE}" == *"bf-bundle-${VALIDATED_BUNDLE}-"* ]]; then
  ok "already on bf-bundle ${VALIDATED_BUNDLE} — no flash needed"
elif $BF3_LOGIN; then DO_FLASH=true; REASON="BF3 runs ${BF3_BUNDLE:-an unknown OS}, not ${VALIDATED_BUNDLE}"
else DO_FLASH=true; REASON="cannot log in to the BF3 (new or unknown install — set BF3_PASSWORD to adopt an existing ${VALIDATED_BUNDLE} install instead)"
fi

if $DO_FLASH; then
  warn "flash needed: ${REASON}"
  # locate the BFB: config, next to the package, state dir — else download
  BFB="${BFB_FILE}"
  for c in "${REPO_DIR}/${BFB_NAME}" "${REPO_DIR}/../${BFB_NAME}" "${STATE_DIR}/${BFB_NAME}"; do
    [[ -z "${BFB}" && -f "$c" ]] && BFB="$c"
  done
  if $CHECK; then
    plan "flash ${BFB_NAME} over ${RSHIM_DEV:-rshim} (ERASES the BF3 OS)${BFB:+ from ${BFB}}${BFB:- — would download it first}"
    plan "then: BF3 base config, package + image push, host VFs, HBN bring-up, hand-over"
    exit 0
  fi
  confirm "Flash ${BFB_NAME} onto the BF3? This ERASES the BF3's OS and data." || die "aborted"
  if [[ -z "${BFB}" ]]; then
    info "downloading ${BFB_NAME} (~1.5 GB)..."
    wget -q --show-progress -O "${STATE_DIR}/${BFB_NAME}.part" "${BFB_URL}" \
      && mv "${STATE_DIR}/${BFB_NAME}.part" "${STATE_DIR}/${BFB_NAME}" \
      || die "download failed — copy ${BFB_NAME} next to the package and re-run"
    BFB="${STATE_DIR}/${BFB_NAME}"
  fi
  [[ $(stat -c %s "${BFB}") -gt 500000000 ]] || die "${BFB} looks truncated"
  if [[ -z "${BF3_PASSWORD}" ]]; then BF3_PASSWORD=$(gen_password); save_secret BF3_PASSWORD "${BF3_PASSWORD}"; fi
  # bf.cfg (appended to the BFB by bfb-install): preset the ubuntu password (no forced
  # change, no console login) and authorize our key system-wide (the home dir only
  # appears at first boot, so the key goes to /etc/ssh/authorized_keys.d).
  CFG="${STATE_DIR}/bf.cfg"
  cat > "${CFG}" <<EOF
# generated by hbn_quickstart.sh
ubuntu_PASSWORD='$(openssl passwd -6 "${BF3_PASSWORD}")'
bfb_modify_os() {
  mkdir -p /mnt/etc/ssh/authorized_keys.d /mnt/etc/ssh/sshd_config.d
  echo '$(cat "${SSH_KEY}.pub")' > /mnt/etc/ssh/authorized_keys.d/ubuntu
  chmod 644 /mnt/etc/ssh/authorized_keys.d/ubuntu
  echo 'AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u' > /mnt/etc/ssh/sshd_config.d/60-hbn-quickstart.conf
}
EOF
  chmod 600 "${CFG}"
  echo "BOOT_TIMEOUT 1200" > "${RSHIM_DEV}/misc" 2>/dev/null
  echo "DISPLAY_LEVEL 1"   > "${RSHIM_DEV}/misc" 2>/dev/null
  info "flashing — 10-20 min; progress below"
  bfb-install --bfb "${BFB}" --config "${CFG}" --rshim "${RSHIM_NAME}" \
    || die "bfb-install failed. If it timed out: stop the BF3 BMC's rshim and re-run"
  ok "flash finished — waiting for the BF3 to boot (up to 25 min)"
  ip addr add "${HOST_TMFIFO_IP}/30" dev "${TMFIFO}" 2>/dev/null; ip link set "${TMFIFO}" up 2>/dev/null
  for i in $(seq 1 100); do bf3_ssh true 2>/dev/null && break; sleep 15; done
  bf3_ssh true 2>/dev/null || die "BF3 not reachable over rshim 25 min after the flash — check the console (BMC: ssh -p 2200 root@<BF3-BMC>)"
  BF3_BUNDLE=$(bf3_ssh "head -1 /etc/mlnx-release" 2>/dev/null)
  ok "BF3 is up: ${BF3_BUNDLE} — login: ubuntu / password in ${SECRETS}"
fi

# ─── --check: report the remaining phases read-only, then stop ──────────────
if $CHECK; then
  _have_sudo=false; [[ -n "${BF3_PASSWORD}" ]] && bf3_sudo true >/dev/null 2>&1 && _have_sudo=true
  SKEW=$(( $(date +%s) - $(bf3_ssh 'date +%s' 2>/dev/null || date +%s) ))
  [[ ${SKEW#-} -gt 30 ]] && plan "set the BF3 clock (${SKEW}s off)" || ok "BF3 clock in sync"
  if [[ -n "${OOB_ADDRESS}" ]]; then
    bf3_ssh "ip -4 addr show oob_net0" 2>/dev/null | grep -q "inet ${OOB_ADDRESS%/*}/" \
      && ok "oob_net0 = ${OOB_ADDRESS}" || plan "set oob_net0 to ${OOB_ADDRESS}"
  fi
  bf3_ssh "test -e /sys/bus/pci/devices/0000:03:00.1 || test -e /sys/class/net/p1" 2>/dev/null \
    && _lay=dual || _lay=single
  ok "layout: ${_lay}-port"
  [[ "${HOST_PF_IN_HBN}" == no && "${_lay}" == dual ]] && die "HOST_PF_IN_HBN=no is only supported on single-port cards"
  _vf=true; for pf in "${HOST_PFS[@]}"; do
    [[ "$(cat "/sys/bus/pci/devices/${pf}/sriov_numvfs" 2>/dev/null)" == "${VFS_PER_PF}" ]] || _vf=false; done
  $_vf && ok "host VFs: ${VFS_PER_PF} per PF" || plan "create ${VFS_PER_PF} host VFs per PF (setup_host_vfs_standalone.sh)"
  if $_have_sudo; then
    bf3_sudo "crictl images 2>/dev/null" | grep -q "doca_hbn.*${HBN_IMAGE##*:}" \
      && ok "image ${HBN_IMAGE} present" || plan "push + import the doca_hbn image"
    bf3_sudo "crictl ps --name doca-hbn -q" 2>/dev/null | grep -q . \
      && ok "doca-hbn running (a real run re-runs the bring-up only if the layout differs)" \
      || plan "run the HBN bring-up"
  else
    plan "image + HBN state not probed (needs BF3_PASSWORD for sudo) — a real run handles both"
  fi
  echo; echo "  --check done: nothing was changed."; exit 0
fi

# sudo must work with the password we hold
bf3_sudo "true" >/dev/null 2>&1 || die "BF3 sudo failed — set the BF3 'ubuntu' password as BF3_PASSWORD in the config"

# New NIC firmware from the bundle: running == stored, and the host still sees its PF?
FW=$(bf3_sudo "devlink dev info pci/0000:03:00.0" 2>/dev/null \
     | awk '/running:/{s="r"} /stored:/{s="s"} $1=="fw.version"{v[s]=$2} END{print v["r"], v["s"]}')
if [[ -n "${FW% *}" && "${FW% *}" != "${FW#* }" ]]; then
  need_power_cycle "to activate the new BF3 NIC firmware (running ${FW% *}, flashed ${FW#* })"
fi
[[ -n "$(ls "/sys/bus/pci/devices/${HOST_PF0}/net" 2>/dev/null)" ]] || {
  echo -e "  ${YELLOW}► HOST REBOOT NEEDED:${NC} the BF3 PF netdev vanished after the flash — run: sudo reboot ; then re-run"; exit 3; }
ok "NIC firmware ${FW% *} active; host PF netdev present"

# ═══ Phase 4: BF3 base config ════════════════════════════════════════════════
phase "BF3 base configuration (clock, management IP, SF capacity)"
SKEW=$(( $(date +%s) - $(bf3_ssh 'date +%s' 2>/dev/null || date +%s) ))
if [[ ${SKEW#-} -gt 30 ]]; then
  bf3_sudo "date -u -s @$(date +%s) >/dev/null; hwclock -w 2>/dev/null; true" && ok "BF3 clock set from the host (was ${SKEW}s off)"
else ok "BF3 clock in sync"; fi

if [[ -n "${OOB_ADDRESS}" ]]; then
  if bf3_ssh "ip -4 addr show oob_net0" 2>/dev/null | grep -q "inet ${OOB_ADDRESS%/*}/"; then
    ok "management port oob_net0 = ${OOB_ADDRESS}"
  else
    bf3_sudo "cat > /etc/netplan/60-oob.yaml <<'EOF'
network:
  version: 2
  ethernets:
    oob_net0:
      dhcp4: false
      addresses: [${OOB_ADDRESS}]
${OOB_GATEWAY:+      routes: [{to: default, via: ${OOB_GATEWAY}}]}
      nameservers: {addresses: [${OOB_DNS}]}
EOF
chmod 600 /etc/netplan/60-oob.yaml && netplan apply" && ok "management port oob_net0 set to ${OOB_ADDRESS}${OOB_GATEWAY:+ via ${OOB_GATEWAY}}"
  fi
else
  info "OOB_ADDRESS not set — management port left as is ($(bf3_ssh "ip -4 -br addr show oob_net0" 2>/dev/null | awk '{print $3}'))"
fi

# HBN needs SubFunctions: some flashes stage PF_TOTAL_SF=0 for the next boot
SF=$(bf3_sudo "mst start >/dev/null 2>&1; mlxconfig -d 03:00.0 -e q PF_TOTAL_SF 2>/dev/null" \
     | awk '/PF_TOTAL_SF/{print $(NF-1), $NF}')
if [[ "${SF##* }" == "0" ]]; then
  bf3_sudo "mlxconfig -d 03:00.0 -y s PF_TOTAL_SF=32 >/dev/null" && ok "PF_TOTAL_SF next-boot 0 → 32 (keeps SubFunctions available)"
  [[ "${SF% *}" == "0" ]] && need_power_cycle "to enable SubFunctions (PF_TOTAL_SF)"
else ok "SubFunction capacity: PF_TOTAL_SF current ${SF% *} / next boot ${SF##* }"; fi

# ═══ Phase 5: package + image onto the BF3 ═══════════════════════════════════
phase "HBN package + container image on the BF3"
tar czf - -C "${REPO_DIR}" scripts mellanox doca_hbn_v3.3.0 \
  | bf3_ssh "rm -rf ~/${BF3_PKG_DIR}.new && mkdir ~/${BF3_PKG_DIR}.new && tar xzf - -C ~/${BF3_PKG_DIR}.new \
             && rm -rf ~/${BF3_PKG_DIR} && mv ~/${BF3_PKG_DIR}.new ~/${BF3_PKG_DIR}" \
  || die "could not copy the package to the BF3"
ok "package copied to /home/ubuntu/${BF3_PKG_DIR}"

if bf3_sudo "crictl images 2>/dev/null" | grep -q "doca_hbn.*${HBN_IMAGE##*:}"; then
  ok "image ${HBN_IMAGE} present"
else
  TAR="${HBN_IMAGE_TAR}"
  for c in "${REPO_DIR}/${IMAGE_TAR_NAME}" "${REPO_DIR}/../${IMAGE_TAR_NAME}" "${REPO_DIR}/${IMAGE_TAR_NAME}.gz" "${REPO_DIR}/../${IMAGE_TAR_NAME}.gz"; do
    [[ -z "${TAR}" && -f "$c" ]] && TAR="$c"
  done
  if [[ -n "${TAR}" ]]; then
    info "pushing ${TAR##*/} over rshim (~300 MB compressed — several minutes)..."
    if [[ "${TAR}" == *.gz ]]; then cat "${TAR}"; else gzip -1 -c "${TAR}"; fi \
      | bf3_ssh "cat > ~/hbn-image.tar.gz" || die "image copy failed"
    bf3_sudo "gunzip -f /home/ubuntu/hbn-image.tar.gz && ctr -n k8s.io images import /home/ubuntu/hbn-image.tar >/dev/null; rc=\$?; rm -f /home/ubuntu/hbn-image.tar; exit \$rc" \
      || die "image import failed"
    ok "image imported from ${TAR##*/}"
  elif bf3_ssh "timeout 8 curl -s -o /dev/null https://nvcr.io/v2/" 2>/dev/null; then
    info "no local image tar — pulling ${HBN_IMAGE} on the BF3..."
    bf3_sudo "crictl pull ${HBN_IMAGE}" >/dev/null || die "pull failed"
    ok "image pulled"
  else
    die "no image: put ${IMAGE_TAR_NAME} next to the package (make_packages.sh --with-image) or give the BF3 internet (OOB_ADDRESS/OOB_GATEWAY)"
  fi
fi

# ═══ Phase 6: inventory + ownership guard ════════════════════════════════════
phase "Inventory (read-only)"
bf3_sudo "cd /home/ubuntu/${BF3_PKG_DIR} && ./scripts/inventory_bf3.sh --quick --no-check --out /tmp/hbn-quickstart-inventory.txt >/dev/null 2>&1; cat /tmp/hbn-quickstart-inventory.txt" \
  > "${STATE_DIR}/inventory-$(date +%Y%m%d-%H%M%S).txt" 2>/dev/null
INV=$(ls -t "${STATE_DIR}"/inventory-*.txt 2>/dev/null | head -1)
[[ -s "${INV}" ]] && ok "inventory saved: ${INV}" && grep -E 'Product|Port layout' "${INV}" | sed 's/^ */    /'
if bf3_ssh "test -f /etc/kubernetes/kubelet.conf" 2>/dev/null && ! $FORCE; then
  die "the BF3 kubelet is joined to an external cluster (DPF/NICo/other manages it) — refusing (--force to override)"
fi
if bf3_ssh "test -e /sys/bus/pci/devices/0000:03:00.1 || test -e /sys/class/net/p1" 2>/dev/null; then
  LAYOUT=dual; BF3_PF_COUNT=2; BRINGUP=bringup_hbn_bf3.sh
else
  LAYOUT=single; BF3_PF_COUNT=1; BRINGUP=bringup_hbn_bf3_single_port.sh
fi
ok "layout: ${LAYOUT}-port → ${BRINGUP}"
if [[ "${HOST_PF_IN_HBN}" == no && "${LAYOUT}" == dual ]]; then
  die "HOST_PF_IN_HBN=no is only supported on single-port cards — set it to yes"
fi

# ═══ Phase 7: host VFs ═══════════════════════════════════════════════════════
phase "Host SR-IOV VFs (${VFS_PER_PF} per PF)"
if [[ ${VFS_PER_PF} -eq 0 ]]; then
  info "VFS_PER_PF=0 — no VFs"
else
  VF_OK=true
  for pf in "${HOST_PFS[@]}"; do
    TOT=$(cat "/sys/bus/pci/devices/${pf}/sriov_totalvfs" 2>/dev/null || echo 0)
    [[ ${TOT:-0} -ge ${VFS_PER_PF} ]] || die "${pf}: SR-IOV allows ${TOT:-0} VFs, need ${VFS_PER_PF} (VM without SR-IOV passthrough, or SR-IOV disabled in BIOS?)"
    [[ "$(cat "/sys/bus/pci/devices/${pf}/sriov_numvfs" 2>/dev/null)" == "${VFS_PER_PF}" ]] || VF_OK=false
  done
  if $VF_OK && systemctl is-enabled --quiet bf3-host-vfs.service 2>/dev/null; then
    ok "${VFS_PER_PF} VFs per PF present and persistent (bf3-host-vfs.service)"
  else
    if [[ "$(cat "/sys/bus/pci/devices/${HOST_PF0}/sriov_numvfs" 2>/dev/null)" != 0 ]]; then
      confirm "Re-create the host VFs (existing VFs on the BF3 PFs drop briefly)?" || die "aborted"
    fi
    bash "${SCRIPT_DIR}/setup_host_vfs_standalone.sh" --vfs-per-pf "${VFS_PER_PF}" | sed 's/^/    /'
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "setup_host_vfs_standalone.sh failed"
    ok "host VFs created and persisted"
  fi
  # the BF3 can only wire VFs it sees: wait for the VF eswitch reps
  WANT=""; for ((p=0; p<BF3_PF_COUNT; p++)); do for ((i=0; i<VFS_PER_PF; i++)); do WANT+=" pf${p}vf${i}"; done; done
  for _ in $(seq 1 12); do
    MISSING=$(bf3_ssh "for r in ${WANT}; do test -e /sys/class/net/\$r || echo -n \"\$r \"; done" 2>/dev/null)
    [[ -z "${MISSING}" ]] && break; sleep 5
  done
  [[ -z "${MISSING}" ]] || die "BF3 does not see VF representors: ${MISSING}"
  ok "BF3 sees all $((VFS_PER_PF * BF3_PF_COUNT)) VF representors"
fi

# ═══ Phase 8: HBN bring-up + verification ════════════════════════════════════
phase "HBN bring-up"
TOTAL_VFS=$((VFS_PER_PF * BF3_PF_COUNT))
FLAGS="--vfs ${TOTAL_VFS}"
[[ "${HOST_PF_IN_HBN}" == no ]] && FLAGS+=" --no-pf"
[[ "${ENABLE_BGP}" == yes ]] && FLAGS+=" --enable-bgp"

# Skip when HBN already runs healthy with exactly this layout (a re-run restarts the pod)
LAYOUT_NOW=$(bf3_sudo "
  crictl ps --name doca-hbn -q 2>/dev/null | grep -q . || { echo none; exit; }
  vfs=\$(grep -cE '\"br-hbn~pf[01]vf[0-9]+~' /etc/mellanox/sfc.conf 2>/dev/null)
  pf=\$(grep -q '\"br-hbn~pf0hpf~' /etc/mellanox/sfc.conf 2>/dev/null && echo yes || echo no)
  ok=\$(/home/ubuntu/${BF3_PKG_DIR}/scripts/status_hbn.sh 2>&1 | grep -c 'All checks passed')
  echo \"\${vfs} \${pf} \${ok}\"")
if [[ "${LAYOUT_NOW}" == "${TOTAL_VFS} ${HOST_PF_IN_HBN} 1" ]]; then
  ok "HBN already running and healthy with this layout — not re-running the bring-up"
else
  [[ "${LAYOUT_NOW}" != none ]] && info "HBN present but differs (vfs/pf/healthy = ${LAYOUT_NOW}) — re-running the bring-up"
  # only now (the bring-up will apply it) may a REST password be generated
  if [[ -z "${REST_PASSWORD}" ]]; then REST_PASSWORD=$(gen_password); save_secret REST_PASSWORD "${REST_PASSWORD}"; fi
  info "preflight: ${BRINGUP} ${FLAGS} --check"
  bf3_sudo "cd /home/ubuntu/${BF3_PKG_DIR} && ./scripts/${BRINGUP} ${FLAGS} --check" | sed 's/^/    │ /'
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "bring-up preflight reported blockers (above)"
  info "running: ${BRINGUP} ${FLAGS} --rest-pass ****  (3-6 min)"
  bf3_sudo "cd /home/ubuntu/${BF3_PKG_DIR} && ./scripts/${BRINGUP} ${FLAGS} --rest-pass $(printf '%q' "${REST_PASSWORD}")" | sed 's/^/    │ /'
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "bring-up failed (output above; log: ${LOG})"
  ok "bring-up finished"
fi

STATUS=$(bf3_sudo "/home/ubuntu/${BF3_PKG_DIR}/scripts/status_hbn.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
if echo "${STATUS}" | grep -q 'All checks passed'; then ok "status_hbn.sh: all checks passed"
else warn "status_hbn.sh reports problems:"; echo "${STATUS}" | grep -E '^\[FAIL\]' | sed 's/^/    /'; fi

# Never hand ONES an untested credential: check the REST password against the live API
# (pod IP — the OOB portmap is not reachable from the BF3 itself)
REST_STATE="unknown"
if [[ -n "${REST_PASSWORD}" ]]; then
  CODE=$(bf3_sudo "pod=\$(crictl pods --name doca-hbn -q | head -1)
    ip=\$(crictl inspectp \$pod | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"status\"][\"network\"][\"ip\"])')
    curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -u nvidia:$(printf '%q' "${REST_PASSWORD}") https://\$ip:8765/nvue_v1/system" 2>/dev/null)
  if [[ "${CODE}" == 200 ]]; then REST_STATE="verified"; ok "REST API credentials verified (nvidia / password from config or ${SECRETS})"
  else REST_STATE="FAILED (HTTP ${CODE:-none})"; warn "REST_PASSWORD does not work against the live API (HTTP ${CODE:-none}) — set the real one in the config"; fi
else
  info "REST password unchanged from the earlier bring-up — set REST_PASSWORD in the config to record it in the hand-over"
fi

# ─── Hand-over for ONES ──────────────────────────────────────────────────────
OOB_NOW=$(bf3_ssh "ip -4 -br addr show oob_net0" 2>/dev/null | awk '{print $3}'); OOB_NOW="${OOB_NOW%/*}"
SERIAL=$(bf3_sudo "dmidecode -s system-serial-number" 2>/dev/null | tail -1)
VF_MAP=""
for ((p=0; p<${#HOST_PFS[@]} && p<BF3_PF_COUNT; p++)); do
  for ((i=0; i<VFS_PER_PF; i++)); do
    HV=$(ls "/sys/bus/pci/devices/${HOST_PFS[$p]}/virtfn${i}/net" 2>/dev/null | head -1)
    VF_MAP+="${HV:-?}=pf${p}vf${i}_if "
  done
done
HO_JSON="${STATE_DIR}/ones-handover.json"; HO_TXT="${STATE_DIR}/ones-handover.txt"
HOSTNAME_="$(hostname)" BUNDLE="${BF3_BUNDLE}" SERIAL="${SERIAL}" LAYOUT="${LAYOUT}" OOB="${OOB_NOW}" \
REST_PW="${REST_PASSWORD}" REST_STATE="${REST_STATE}" PFIN="${HOST_PF_IN_HBN}" PFDEV="${HOST_PF0_NETDEV}" VFMAP="${VF_MAP}" \
python3 - "${HO_JSON}" <<'PY'
import json, os, sys
e = os.environ
oob = e["OOB"] or None
vfs = [dict(zip(("host_vf", "hbn_interface"), x.split("="))) for x in e["VFMAP"].split()]
doc = {
  "host": {"hostname": e["HOSTNAME_"], "bf3_pf_netdev": e["PFDEV"], "vfs": vfs},
  "bf3": {"serial": e["SERIAL"], "os": e["BUNDLE"], "port_layout": e["LAYOUT"],
          "management_ip": oob, "ssh_user": "ubuntu"},
  "hbn": {"rest_api": f"https://{oob}:8765/nvue_v1/" if oob else None,
          "rest_user": "nvidia", "rest_password": e["REST_PW"] or None,
          "rest_credentials": e["REST_STATE"],
          "host_pf_in_hbn": e["PFIN"] == "yes",
          "uplinks": ["p0_if"] + (["p1_if"] if e["LAYOUT"] == "dual" else [])},
}
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
chmod 600 "${HO_JSON}"
{
  echo "ONES hand-over — $(hostname) — $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo "  BF3            : ${LAYOUT}-port, serial ${SERIAL:-?}, ${BF3_BUNDLE}"
  echo "  Management IP  : ${OOB_NOW:-not set (OOB_ADDRESS in the config)}"
  echo "  HBN REST API   : ${OOB_NOW:+https://${OOB_NOW}:8765/nvue_v1/}  user nvidia / ${REST_PASSWORD:-<unchanged — not known to this script>}  [${REST_STATE}]"
  echo "  Host PF in HBN : ${HOST_PF_IN_HBN}   (host PF netdev ${HOST_PF0_NETDEV:-?})"
  echo "  Host VF → HBN interface (ONES assigns IPs on the host VFs):"
  for m in ${VF_MAP}; do printf '    %-18s → %s\n' "${m%%=*}" "${m#*=}"; done
  echo "  Uplink(s)      : p0_if$([[ ${LAYOUT} == dual ]] && echo ' p1_if')"
  echo "  BF3 login      : ssh over rshim from this host: ubuntu@${BF3_TMFIFO_IP} (key ${SSH_KEY}); password = BF3_PASSWORD (your config, or ${SECRETS} if generated)"
  echo "  NOTE (DOCA 3.3.0): NVUE REST revisions stay 'pending' — apply inside the container:"
  echo "        sudo crictl exec \$(sudo crictl ps --name doca-hbn -q) nv config apply --assume-yes"
} > "${HO_TXT}"
chmod 600 "${HO_TXT}"
echo; cat "${HO_TXT}"
echo
echo -e "${GREEN}${BOLD}DONE${NC} — hand-over: ${HO_TXT} / ${HO_JSON}   log: ${LOG}"
exit 0
