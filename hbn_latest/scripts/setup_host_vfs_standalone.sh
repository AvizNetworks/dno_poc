#!/usr/bin/env bash
# Create + persist SR-IOV VFs on the BF3 host PFs (x86 host, standalone HBN).
# Run on the x86 host BEFORE 'bringup_hbn_bf3.sh --vfs' on the BF3.
# Auto-detects the BF3 PFs by PCI id 15b3:a2dc. Default 4 VFs per PF (--vfs-per-pf N to change).
set -euo pipefail
VFS_PER_PF=4
[[ "${1:-}" == "--vfs-per-pf" ]] && VFS_PER_PF="$2"
[[ $EUID -ne 0 ]] && { echo "run as root (sudo)"; exit 1; }
mapfile -t PFS < <(for d in /sys/class/net/*/device; do
  [[ "$(cat "$d/vendor" 2>/dev/null)" == "0x15b3" && "$(cat "$d/device" 2>/dev/null)" == "0xa2dc" ]] \
    && [[ -e "$d/sriov_totalvfs" ]] && basename "$(dirname "$d")"; done | sort -u)
[[ ${#PFS[@]} -eq 0 ]] && { echo "No BF3 PFs (15b3:a2dc) with SR-IOV found. If the PF netdev is missing after a BF3 reflash, REBOOT this host first."; exit 1; }
echo "BF3 PFs: ${PFS[*]}  (VFs per PF: ${VFS_PER_PF})"
for pf in "${PFS[@]}"; do
  echo 0 > "/sys/class/net/$pf/device/sriov_numvfs"
  echo "$VFS_PER_PF" > "/sys/class/net/$pf/device/sriov_numvfs"
  for v in /sys/class/net/${pf%np*}v*; do [[ -e "$v" ]] && ip link set dev "$(basename "$v")" up 2>/dev/null || true; done
  echo "  $pf -> $(cat /sys/class/net/$pf/device/sriov_numvfs) VFs"
done
# Persist across reboot (sriov_numvfs resets to 0 otherwise). The boot helper finds the PFs by
# PCI id, not by interface name — the name changes when the card moves to another slot.
cat > /usr/local/sbin/bf3-host-vfs.sh <<'HELPER'
#!/bin/bash
# bf3-host-vfs.sh N — create N SR-IOV VFs on every BF3 PF (15b3:a2dc). Written by setup_host_vfs_standalone.sh.
N="${1:-4}"; rc=0; found=0
for d in /sys/bus/pci/devices/*; do
  [[ "$(cat "$d/vendor" 2>/dev/null)" == "0x15b3" && "$(cat "$d/device" 2>/dev/null)" == "0xa2dc" && -e "$d/sriov_numvfs" ]] || continue
  found=1
  [[ "$(cat "$d/sriov_numvfs")" == "$N" ]] || { echo 0 > "$d/sriov_numvfs"; echo "$N" > "$d/sriov_numvfs" || rc=1; }
  echo "$(basename "$d") $(ls "$d/net" 2>/dev/null): $(cat "$d/sriov_numvfs") VFs"
done
[[ $found -eq 1 ]] || { echo "no BF3 PF (15b3:a2dc) with SR-IOV found"; exit 1; }
exit $rc
HELPER
chmod 755 /usr/local/sbin/bf3-host-vfs.sh
cat > /etc/systemd/system/bf3-host-vfs.service <<UNIT
[Unit]
Description=Create SR-IOV VFs on BF3 host PFs
After=network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/bf3-host-vfs.sh ${VFS_PER_PF}
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable bf3-host-vfs.service
if [[ ${#PFS[@]} -eq 1 ]]; then   # single-port BF3 (one PF)
  echo "Persisted via bf3-host-vfs.service. Now run 'bringup_hbn_bf3_single_port.sh --vfs ${VFS_PER_PF}' on the BF3."
else
  echo "Persisted via bf3-host-vfs.service. Now run 'bringup_hbn_bf3.sh --vfs $((VFS_PER_PF*2))' on the BF3."
fi
