#!/usr/bin/env bash
# bringup_hbn_bf3.sh — Idempotent HBN bringup for BlueField-3 DPU (DOCA 3.3.0)
# Run on BF3 with sudo: sudo ./bringup_hbn_bf3.sh [options]
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
HBN_CONF="/etc/mellanox/hbn.conf"
SFC_CONF="/etc/mellanox/sfc.conf"
LOG_DIR="/var/log/doca/hbn"
WAIT_TIMEOUT=300
ENABLE_BGP=false
REST_USER="nvidia"
REST_PASS="nvidia"
SKIP_DNS_FIX=false
P0_VFS=0
P1_VFS=0

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
  --enable-bgp               Enable bgpd in FRR daemons (default: off)
  --rest-user <user>         REST API username (default: nvidia)
  --rest-pass <pass>         REST API password (default: nvidia)
  --skip-dns-fix             Skip adding nameserver 8.8.8.8 to resolv.conf
  --vfs <n>                  Total VFs split equally across both PFs (e.g. --vfs 8 → 4 per PF)
  --p0-vfs <n>               VFs on PF0 only
  --p1-vfs <n>               VFs on PF1 only
  -h, --help                 Show this help

Examples:
  sudo $0
  sudo $0 --enable-bgp --rest-user nvidia --rest-pass MyPass123
  sudo $0 --vfs 8
  sudo $0 --p0-vfs 4 --p1-vfs 4
EOF
  exit 0
}

# ─── Arg parsing ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --enable-bgp)       ENABLE_BGP=true ;;
    --rest-user)        REST_USER="$2"; shift ;;
    --rest-pass)        REST_PASS="$2"; shift ;;
    --skip-dns-fix)     SKIP_DNS_FIX=true ;;
    --vfs)              P0_VFS=$(($2/2)); P1_VFS=$(($2/2)); shift ;;
    --p0-vfs)           P0_VFS="$2"; shift ;;
    --p1-vfs)           P1_VFS="$2"; shift ;;
    -h|--help)          usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

[[ $EUID -ne 0 ]] && fail "This script must be run as root (sudo)"

# If sfc.service isn't registered with systemd, install it directly from the sfc-hbn package.
# Do NOT run install.sh — it also does mgmt VRF + SSH reconfiguration that hangs and may
# change the OOB IP, breaking the current SSH session.
if ! systemctl cat sfc.service &>/dev/null; then
  SFC_OPT="/opt/mellanox/sfc-hbn"
  if [[ -f "${SFC_OPT}/sfc.service" ]]; then
    info "sfc.service not registered — installing directly from ${SFC_OPT}"
    cp "${SFC_OPT}/sfc.service" /etc/systemd/system/sfc.service
    systemctl daemon-reload
    systemctl enable sfc.service
    ok "sfc.service installed and enabled"
  else
    fail "sfc.service not found at ${SFC_OPT}/sfc.service — is sfc-hbn installed? (apt-get install sfc-hbn)"
  fi
fi

# Detect the sfc service name — varies across DOCA package versions
SFC_SERVICE=""
for _S in sfc mlnx-sfc hbn-sfc; do
  systemctl cat "${_S}.service" &>/dev/null \
    && { SFC_SERVICE="${_S}.service"; break; }
done
if [[ -z "$SFC_SERVICE" ]]; then
  echo -e "${RED}[FAIL]${NC}  sfc.service not found after running /opt/mellanox/sfc-hbn/install.sh"
  echo -e "${CYAN}[INFO]${NC}  Check: systemctl list-unit-files | grep -iE 'sfc|dpdk|mlnx'"
  echo -e "${CYAN}[INFO]${NC}  install.sh is at: /opt/mellanox/sfc-hbn/install.sh"
  exit 1
fi

# ─── VF config generators ────────────────────────────────────────────────────
generate_hbn_conf() {
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
  # VF SF function netdevs: ${_SF_PREFIX}s${sfnum} (e.g. enp3s0f0s4)
  # _SF_PREFIX is derived from BF3_PCI0 at the top of Step 4
  {
    cat <<'EOF'
BR_HBN_NAME=br-hbn
MAPPINGS=(
"br-hbn~p0~p0_if_r~p0_if~p0_if_r"
"br-hbn~p1~p1_if_r~p1_if~p1_if_r"
"br-hbn~pf0hpf~pf0hpf_if_r~pf0hpf_if~pf0hpf_if_r"
"br-hbn~pf1hpf~pf1hpf_if_r~pf1hpf_if~pf1hpf_if_r"
EOF
    # VF entries: field2=SF function netdev (→ container as pf0vfN_if)
    #             field3=VF representor renamed to pf0vfN_if_r (→ stays in OVS)
    local _SFNUM=4
    for ((i=0; i<P0_VFS; i++)); do
      echo "\"br-hbn~${_SF_PREFIX}s${_SFNUM}~pf0vf${i}_if_r~pf0vf${i}_if~pf0vf${i}_if_r\""
      _SFNUM=$((_SFNUM+1))
    done
    for ((i=0; i<P1_VFS; i++)); do
      echo "\"br-hbn~${_SF_PREFIX}s${_SFNUM}~pf1vf${i}_if_r~pf1vf${i}_if~pf1vf${i}_if_r\""
      _SFNUM=$((_SFNUM+1))
    done
    echo ")"
  } > "${SFC_CONF}"
}

echo ""
echo "============================================================"
echo "  HBN BF3 Bringup — DOCA 3.3.0"
echo "  $(date)"
echo "============================================================"
echo ""

# ─── Step 1: eswitch switchdev mode ──────────────────────────────────────────
info "Step 1/13 — Verifying eswitch switchdev mode"
for BF3_PCI in "$BF3_PCI0" "$BF3_PCI1"; do
  if devlink dev eswitch show "pci/$BF3_PCI" 2>/dev/null | grep "^pci/$BF3_PCI" | grep -q "mode switchdev"; then
    ok "pci/$BF3_PCI eswitch mode: switchdev"
  else
    fail "pci/$BF3_PCI eswitch NOT in switchdev mode. Run: devlink dev eswitch set pci/$BF3_PCI mode switchdev"
  fi
done

# ─── Step 2: DNS fix ─────────────────────────────────────────────────────────
info "Step 2/13 — Checking DNS"
if [[ "$SKIP_DNS_FIX" == "true" ]]; then
  warn "Skipping DNS fix (--skip-dns-fix)"
elif grep -q "8.8.8.8" /etc/resolv.conf 2>/dev/null; then
  ok "DNS already has 8.8.8.8"
else
  echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  ok "Added nameserver 8.8.8.8 to /etc/resolv.conf"
fi

# ─── Step 3: hostPath directories ────────────────────────────────────────────
info "Step 3/13 — Creating hostPath directories"
mkdir -p \
  /var/lib/hbn/etc/nvue.d \
  /var/lib/hbn/etc/frr \
  /var/lib/hbn/etc/network \
  /var/lib/hbn/etc/cumulus \
  /var/lib/hbn/etc/hbn-users \
  /var/lib/hbn/etc/supervisor/conf.d \
  /var/lib/hbn/var/lib/nvue \
  /var/lib/hbn/var/support \
  /var/log/doca/hbn
ok "hostPath directories ready"

# ─── Step 4: Deploy reference config files ───────────────────────────────────
info "Step 4/13 — Deploying reference config files from ${MLX_REF_DIR}"

[[ -d "$MLX_REF_DIR" ]] || fail "Reference config directory not found: $MLX_REF_DIR (clone the full repo)"

TOTAL_VFS=$((P0_VFS + P1_VFS))
# SF function netdev prefix derived from BF3 PCI address (e.g. 0000:03:00.0 → enp3s0f0)
_BUS_DEC=$(printf '%d' "0x${BF3_PCI0:5:2}" 2>/dev/null || echo 3)
_SF_PREFIX="enp${_BUS_DEC}s0f0"

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

# mlnx-sf.conf — install.sh may assign physical port MACs to SFs; mlx5_core then skips function netdevs
# Detect physical port MACs via phys_port_name (available in switchdev mode before any HBN config)
P0_MAC=""; P1_MAC=""
for NDEV in /sys/class/net/*/; do
  PNAME=$(cat "${NDEV}phys_port_name" 2>/dev/null || echo "")
  ADDR=$(cat "${NDEV}address" 2>/dev/null || echo "")
  [[ "$PNAME" == "p0" ]] && P0_MAC="$ADDR"
  [[ "$PNAME" == "p1" ]] && P1_MAC="$ADDR"
done

SF_CONF_OK=true
if [[ ! -f "${MLX_SF_CONF}" ]]; then
  SF_CONF_OK=false
  info "mlnx-sf.conf missing — will generate"
else
  # Verify all 4 base sfnums are present
  for _SFNUM in 2 3 1514 1515; do
    grep -q "\-\-sfnum ${_SFNUM}" "${MLX_SF_CONF}" 2>/dev/null || { SF_CONF_OK=false; break; }
  done
  [[ "$SF_CONF_OK" == "false" ]] && warn "mlnx-sf.conf missing required sfnums (2, 3, 1514, 1515) — will regenerate"
  # Verify VF sfnums present when --vfs was requested
  if [[ "$SF_CONF_OK" == "true" && $TOTAL_VFS -gt 0 ]]; then
    _CHK_SFNUM=4
    for ((i=0; i<P0_VFS; i++)); do
      grep -q "\-\-sfnum ${_CHK_SFNUM}" "${MLX_SF_CONF}" 2>/dev/null || { SF_CONF_OK=false; break; }
      _CHK_SFNUM=$((_CHK_SFNUM+1))
    done
    for ((i=0; i<P1_VFS; i++)); do
      grep -q "\-\-sfnum ${_CHK_SFNUM}" "${MLX_SF_CONF}" 2>/dev/null || { SF_CONF_OK=false; break; }
      _CHK_SFNUM=$((_CHK_SFNUM+1))
    done
    [[ "$SF_CONF_OK" == "false" ]] && warn "mlnx-sf.conf missing VF sfnums — will regenerate"
  fi
  # Check for physical MAC conflict
  if [[ "$SF_CONF_OK" == "true" ]]; then
    if { [[ -n "$P0_MAC" ]] && grep -qi "$P0_MAC" "${MLX_SF_CONF}"; } || \
       { [[ -n "$P1_MAC" ]] && grep -qi "$P1_MAC" "${MLX_SF_CONF}"; }; then
      warn "mlnx-sf.conf contains a physical port MAC — will regenerate"
      SF_CONF_OK=false
    fi
  fi
fi

if [[ "$SF_CONF_OK" == "false" ]]; then
  # Derive BF3-unique locally-administered MACs from p0 physical MAC.
  # Using bytes 3-5 of p0 MAC ensures per-BF3 uniqueness without OUI collision.
  if [[ -n "$P0_MAC" ]]; then
    IFS=':' read -ra _M <<< "$P0_MAC"
    _B3="${_M[3]}"; _B4="${_M[4]}"; _B5="${_M[5]}"
    _SF2_MAC="02:${_B3}:${_B4}:${_B5}:00:02"
    _SF3_MAC="02:${_B3}:${_B4}:${_B5}:00:03"
    _SF1514_MAC="02:${_B3}:${_B4}:${_B5}:05:ea"
    _SF1515_MAC="02:${_B3}:${_B4}:${_B5}:05:eb"
  else
    warn "Could not detect p0 MAC — using fixed LA MACs (may conflict if multiple BF3s on same L2)"
    _SF2_MAC="02:00:00:00:00:02"; _SF3_MAC="02:00:00:00:00:03"
    _SF1514_MAC="02:00:00:05:ea:00"; _SF1515_MAC="02:00:00:05:eb:00"
  fi
  {
    cat <<EOF
/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum 2 --hwaddr ${_SF2_MAC} -t --cpu-list 0-2
/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum 1514 --hwaddr ${_SF1514_MAC} -t --cpu-list 0-2
/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum 3 --hwaddr ${_SF3_MAC} -t --cpu-list 0-2
/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum 1515 --hwaddr ${_SF1515_MAC} -t --cpu-list 0-2
EOF
    # VF SFs: sfnums 4..4+P0_VFS-1 for pf0vfN, then 4+P0_VFS..4+P0_VFS+P1_VFS-1 for pf1vfN
    _SFNUM=4
    for ((i=0; i<P0_VFS; i++)); do
      _MAC="02:${_B3}:${_B4}:${_B5}:$(printf '%02x' 0):$(printf '%02x' $_SFNUM)"
      echo "/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum ${_SFNUM} --hwaddr ${_MAC} -t --cpu-list 0-2"
      _SFNUM=$((_SFNUM+1))
    done
    for ((i=0; i<P1_VFS; i++)); do
      _MAC="02:${_B3}:${_B4}:${_B5}:$(printf '%02x' 1):$(printf '%02x' $_SFNUM)"
      echo "/sbin/mlnx-sf --action create --device 0000:03:00.0 --sfnum ${_SFNUM} --hwaddr ${_MAC} -t --cpu-list 0-2"
      _SFNUM=$((_SFNUM+1))
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
info "Step 5/13 — Hugepage allocation (OVS-DPDK requires 1600×2MB)"

HP_FILE="/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
HP_NOW=$(cat "$HP_FILE" 2>/dev/null || echo 0)

if [[ $HP_NOW -ge 1600 ]]; then
  ok "Hugepages already allocated: ${HP_NOW}×2MB"
else
  info "Allocating 1600×2MB hugepages (currently: ${HP_NOW})"
  echo 1600 > "$HP_FILE"
  HP_NOW=$(cat "$HP_FILE")
  [[ $HP_NOW -ge 1600 ]] || fail "Could not allocate hugepages (got ${HP_NOW}) — system may be low on memory"
  ok "Hugepages allocated: ${HP_NOW}×2MB"
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
info "Step 6/13 — Checking SF provisioning (sfnum 2, 3, 1514, 1515)"

# SFS_PROVISIONED tracks whether sfc.service needs to be (re)started in step 7
SFS_PROVISIONED=true

# Primary check: all 4 SF opstate=attached in devlink
sfs_all_attached() {
  local s _SFNUM=4
  for s in 2 3 1514 1515; do
    local op
    op=$(devlink port show 2>/dev/null | grep "sfnum ${s} " | grep -o "opstate [a-z]*" | awk '{print $2}' || echo "")
    [[ "$op" == "attached" ]] || return 1
  done
  for ((i=0; i<P0_VFS; i++)); do
    local op
    op=$(devlink port show 2>/dev/null | grep "sfnum ${_SFNUM} " | grep -o "opstate [a-z]*" | awk '{print $2}' || echo "")
    [[ "$op" == "attached" ]] || return 1
    _SFNUM=$((_SFNUM+1))
  done
  for ((i=0; i<P1_VFS; i++)); do
    local op
    op=$(devlink port show 2>/dev/null | grep "sfnum ${_SFNUM} " | grep -o "opstate [a-z]*" | awk '{print $2}' || echo "")
    [[ "$op" == "attached" ]] || return 1
    _SFNUM=$((_SFNUM+1))
  done
}

if sfs_all_attached; then
  ok "SFs already provisioned and attached"
else
  SFS_PROVISIONED=false

  # SFs appear attached in devlink but netdevs missing → MAC conflict; delete and reprovision
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
          mlnx-sf --action delete --sfindex "$SFIDX" 2>/dev/null \
            && info "  Deleted sfnum $SFNUM" \
            || warn "  Could not delete sfnum $SFNUM — may already be gone"
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
    if ! $CMD >/tmp/sf_create_err 2>&1; then
      if grep -q "already exist" /tmp/sf_create_err 2>/dev/null; then
        SFNUM=$(echo "$CMD" | grep -o "\-\-sfnum [0-9]*" | awk '{print $2}')
        info "  sfnum ${SFNUM} already exists — skipping"
      else
        cat /tmp/sf_create_err >&2
        fail "mlnx-sf create failed: $CMD"
      fi
    fi
  done < "$MLX_SF_CONF"

  # Explicitly activate any SFs that are in devlink but not yet active.
  # mlnx-sf should do this internally, but some driver versions require it explicitly.
  _ALL_SFNUMS=(2 3 1514 1515)
  _VS=4; for ((i=0; i<P0_VFS; i++)); do _ALL_SFNUMS+=($_VS); _VS=$((_VS+1)); done
         for ((i=0; i<P1_VFS; i++)); do _ALL_SFNUMS+=($_VS); _VS=$((_VS+1)); done
  for _S in "${_ALL_SFNUMS[@]}"; do
    _PORT=$(devlink port show 2>/dev/null | grep "sfnum ${_S} " | awk '{print $1}' | sed 's/:$//')
    if [[ -n "$_PORT" ]]; then
      devlink port function set "$_PORT" state active 2>/dev/null \
        && info "  Activated sfnum ${_S} (${_PORT})" || true
    fi
  done

  # Poll for SF activation — kernel attaches SFs asynchronously (can take 20-60s on fresh BF3)
  info "Waiting for SFs to reach opstate=attached (up to 60s)..."
  SF_WAIT=0
  until sfs_all_attached || [[ $SF_WAIT -ge 60 ]]; do
    sleep 3; SF_WAIT=$((SF_WAIT + 3))
  done

  if sfs_all_attached; then
    ok "All 4 SFs attached (waited ${SF_WAIT}s)"
  else
    warn "SFs not fully attached after 60s — ${SFC_SERVICE} will retry; check 'mlnx-sf -a show' if pod fails"
  fi
fi

# ─── Step 7: OVS health check ────────────────────────────────────────────────
info "Step 7/13 — OVS bridge health check"

OVS_RESTARTED=false

# p0/p1 "Invalid argument" is benign on BF3 switchdev — exclude them from the check
OVS_REAL_ERRORS=$(ovs-vsctl show 2>/dev/null \
  | grep "Invalid argument" \
  | grep -v "could not add network device p[01] to ofproto" \
  | wc -l | tr -d ' ' || true)
OVS_REAL_ERRORS=${OVS_REAL_ERRORS:-0}
if [[ "$OVS_REAL_ERRORS" -gt 0 ]]; then
  warn "br-hbn has 'Invalid argument' — OVS started before hugepages were allocated; fixing"
  ovs-vsctl del-br br-hbn 2>/dev/null && info "Deleted stale br-hbn" || true
  systemctl restart openvswitch-switch
  sleep 5
  OVS_RESTARTED=true
fi

# Clean stale VF OVS entries and rename VF representors before sfc restart.
# Stale entries from previous runs cause "already in use" conflicts when sfc re-adds them.
if [[ $TOTAL_VFS -gt 0 ]]; then
  info "Cleaning stale VF OVS entries..."
  _VS=4
  for ((i=0; i<P0_VFS; i++)); do
    ovs-vsctl del-port br-hbn "pf0vf${i}"       2>/dev/null || true
    ovs-vsctl del-port br-hbn "pf0vf${i}_if_r"  2>/dev/null || true
    ovs-vsctl del-port br-hbn "${_SF_PREFIX}s${_VS}" 2>/dev/null || true
    _VS=$((_VS+1))
  done
  for ((i=0; i<P1_VFS; i++)); do
    ovs-vsctl del-port br-hbn "pf1vf${i}"           2>/dev/null || true
    ovs-vsctl del-port br-hbn "pf1vf${i}_if_r"      2>/dev/null || true
    ovs-vsctl del-port br-hbn "${_SF_PREFIX}s${_VS}" 2>/dev/null || true
    _VS=$((_VS+1))
  done

  info "Renaming VF representors for OVS..."
  for ((i=0; i<P0_VFS; i++)); do
    ip link show "pf0vf${i}" &>/dev/null 2>&1 && \
      ip link set "pf0vf${i}" name "pf0vf${i}_if_r" 2>/dev/null && \
      info "  pf0vf${i} → pf0vf${i}_if_r" || true
  done
  for ((i=0; i<P1_VFS; i++)); do
    ip link show "pf1vf${i}" &>/dev/null 2>&1 && \
      ip link set "pf1vf${i}" name "pf1vf${i}_if_r" 2>/dev/null && \
      info "  pf1vf${i} → pf1vf${i}_if_r" || true
  done
fi

# Restart sfc.service when OVS was fixed or SFs were just provisioned
if [[ "$OVS_RESTARTED" == "true" ]] || [[ "$SFS_PROVISIONED" == "false" ]]; then
  info "Restarting ${SFC_SERVICE} to wire up SFs and hugepages..."
  systemctl restart "$SFC_SERVICE"
  sleep 20
fi

# When VFs are configured, force restart the doca-hbn container so init-sfs
# runs again with the new VF OVS metadata (hbn_netdev) — this moves the VF SF
# function netdevs (enp3s0f0sN) into the container as pf0vfN_if / pf1vfN_if.
if [[ $TOTAL_VFS -gt 0 ]]; then
  _OLD_CONT=$(crictl ps -q --name doca-hbn 2>/dev/null | head -1 || true)
  if [[ -n "$_OLD_CONT" ]]; then
    info "Restarting doca-hbn container so init-sfs picks up VF interfaces..."
    crictl stop "$_OLD_CONT" 2>/dev/null || true
    sleep 5
  fi
fi

# ─── Step 8: Validate OVS ports ──────────────────────────────────────────────
info "Step 8/13 — Validating OVS ports on br-hbn"

check_ovs_ports() {
  local missing=()
  for port in p0 p1 pf0hpf pf1hpf p0_if_r p1_if_r pf0hpf_if_r pf1hpf_if_r; do
    ovs-vsctl list-ports br-hbn 2>/dev/null | grep -qx "$port" || missing+=("$port")
  done
  echo "${missing[*]}"
}

OVS_MISSING=$(check_ovs_ports)
if [[ -n "$OVS_MISSING" ]]; then
  warn "Missing OVS ports: ${OVS_MISSING} — restarting ${SFC_SERVICE}"
  systemctl restart "$SFC_SERVICE"
  sleep 20
  OVS_MISSING=$(check_ovs_ports)
  if [[ -n "$OVS_MISSING" ]]; then
    warn "Still missing OVS ports: ${OVS_MISSING} — check: journalctl -u ${SFC_SERVICE%.service} -n 50"
  else
    ok "All OVS ports present after ${SFC_SERVICE} restart"
  fi
else
  ok "All 8 OVS ports present on br-hbn"
fi

# ─── Step 9: Pull container image ───────────────────────────────────────────
info "Step 9/13 — Checking doca_hbn container image"
if crictl images 2>/dev/null | grep -q "doca_hbn\|doca-hbn"; then
  ok "doca_hbn image already present"
else
  IMAGE=$(grep -i "image:" "$HBN_POD_SPEC" | head -1 | awk '{print $2}')
  info "Pulling $IMAGE ..."
  crictl pull "$IMAGE"
  ok "Image pulled"
fi

# ─── Step 10: Wait for doca-hbn pod ──────────────────────────────────────────
info "Step 10/13 — Waiting for doca-hbn container to be Running (timeout: ${WAIT_TIMEOUT}s)"
ELAPSED=0
while true; do
  if crictl ps 2>/dev/null | grep "doca-hbn" | grep -v init | grep -q "Running"; then
    ok "doca-hbn container is Running"
    break
  fi
  if [[ $ELAPSED -ge $WAIT_TIMEOUT ]]; then
    fail "Timed out waiting for doca-hbn pod. Check: journalctl -u kubelet -f | grep hbn"
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
info "Step 11/13 — Bringing up HBN interfaces inside container"
HBN_IFACES=(p0_if p1_if pf0hpf_if pf1hpf_if)
for ((i=0; i<P0_VFS; i++)); do HBN_IFACES+=("pf0vf${i}_if"); done
for ((i=0; i<P1_VFS; i++)); do HBN_IFACES+=("pf1vf${i}_if"); done
# Move VF SF function netdevs from host into container (init-sfs doesn't handle these).
# The SF function netdev (enp3s0f0sN) is moved to the container and renamed pf0vfN_if.
if [[ $TOTAL_VFS -gt 0 ]]; then
  info "Moving VF SF function netdevs into container..."
  _SFNUM=4
  for ((i=0; i<P0_VFS; i++)); do
    _NETDEV="${_SF_PREFIX}s${_SFNUM}"
    if ip link show "$_NETDEV" &>/dev/null 2>&1; then
      ip link set "$_NETDEV" netns "$CONT_PID" name "pf0vf${i}_if" 2>/dev/null && \
        info "  ${_NETDEV} → pf0vf${i}_if (in container)" || \
        warn "  ${_NETDEV}: could not move to container"
    else
      warn "  ${_NETDEV}: not found in host namespace"
    fi
    _SFNUM=$((_SFNUM+1))
  done
  for ((i=0; i<P1_VFS; i++)); do
    _NETDEV="${_SF_PREFIX}s${_SFNUM}"
    if ip link show "$_NETDEV" &>/dev/null 2>&1; then
      ip link set "$_NETDEV" netns "$CONT_PID" name "pf1vf${i}_if" 2>/dev/null && \
        info "  ${_NETDEV} → pf1vf${i}_if (in container)" || \
        warn "  ${_NETDEV}: could not move to container"
    else
      warn "  ${_NETDEV}: not found in host namespace"
    fi
    _SFNUM=$((_SFNUM+1))
  done
fi

for iface in "${HBN_IFACES[@]}"; do
  STATE=$(crictl exec "$CONT" ip link show "$iface" 2>/dev/null | grep -o "state [A-Z]*" | awk '{print $2}' || true)
  if [[ "$STATE" == "UP" ]]; then
    ok "$iface already UP"
  elif [[ -z "$STATE" ]]; then
    warn "$iface: not found in container — VF SF may not be provisioned yet"
  else
    crictl exec "$CONT" ip link set "$iface" up 2>/dev/null && ok "$iface brought UP" || warn "$iface: could not set UP"
  fi
done

# ─── Step 12: Enable BGP ─────────────────────────────────────────────────────
info "Step 12/13 — BGP configuration"
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
info "Step 13/13 — REST API setup"

if [[ -d "$DOCA_SCRIPTS_DIR" ]]; then
  # Ensure Python deps available on BF3 host
  python3 -c "import cryptography, yaml" 2>/dev/null || \
    apt-get install -y python3-cryptography python3-yaml -qq

  # Persist password: encrypt_password.py runs on host, writes to hostPath volume
  # decrypt_user_add reads this on every container start and sets the user password
  mkdir -p /var/lib/hbn/etc/hbn-users
  python3 "$DOCA_SCRIPTS_DIR/encrypt_password.py" -u "$REST_USER" -p "$REST_PASS" \
    && ok "Password persisted for $REST_USER (survives container restart)" \
    || warn "encrypt_password.py failed — password will reset on container restart"

  # Update startup.yaml to listen on 0.0.0.0 — must run from script dir (relative paths)
  (cd "$DOCA_SCRIPTS_DIR" && python3 enable-rest-api.py) \
    && ok "NVUE startup.yaml updated for external REST access" \
    || warn "enable-rest-api.py failed"

  # Copy REST access marker read by container init
  mkdir -p /var/lib/hbn/etc/cumulus
  cp "$DOCA_SCRIPTS_DIR/etc/cumulus/hbn-dpu-setup.conf" /var/lib/hbn/etc/cumulus/

  # Apply password immediately without waiting for container restart
  crictl exec "$CONT" bash -c "echo '${REST_USER}:${REST_PASS}' | chpasswd" 2>/dev/null || true
else
  warn "DOCA scripts not found at $DOCA_SCRIPTS_DIR — skipping REST API setup"
  warn "Place the HBN scripts package at: $DOCA_SCRIPTS_DIR"
fi

# Verify
if curl -sk -u "${REST_USER}:${REST_PASS}" "https://localhost:8765/nvue_v1/system" 2>/dev/null | grep -q "build"; then
  ok "REST API accessible (user: $REST_USER)"
else
  warn "REST API check failed — nginx may need restart inside container"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Bringup Complete — Summary"
echo "============================================================"

OOB_IP=$(ip addr show oob_net0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || echo "unknown")
SF_COUNT=$(devlink port show 2>/dev/null | grep -c "sfnum [0-9]" || true); SF_COUNT=${SF_COUNT:-0}
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
