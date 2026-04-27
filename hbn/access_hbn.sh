#!/usr/bin/env bash
# access_hbn.sh — Quick reference for all HBN BF3 access methods
# Run from any machine: ./access_hbn.sh [--bf3-ip <IP>]
BF3_IP="10.20.13.228"
BF3_USER="ubuntu"

while [[ $# -gt 0 ]]; do
  case $1 in
    --bf3-ip)   BF3_IP="$2"; shift ;;
    --bf3-user) BF3_USER="$2"; shift ;;
    *) ;;
  esac
  shift
done

cat <<EOF

============================================================
  HBN BF3 Access Reference
  BF3 OOB IP : $BF3_IP
  Generated  : $(date)
============================================================

  [OOB SSH]
  ─────────
  ssh ${BF3_USER}@${BF3_IP}

  [RSHIM Console]  (run on x86 host, requires PCIe connection)
  ──────────────────────────────────────────────────────────
  sudo minicom -D /dev/rshim0/console
  # or:
  sudo screen /dev/rshim0/console 115200
  # Login: ubuntu / ubuntu (change on first login)

  [FRR CLI - vtysh]
  ─────────────────
  # SSH to BF3 first, then:
  CONT=\$(sudo crictl ps | grep doca-hbn | grep -v init | awk '{print \$1}')
  sudo crictl exec -it \$CONT vtysh

  Useful vtysh commands:
    show interface brief
    show ip route
    show bgp summary
    show daemons
    conf t

  [NVUE CLI]
  ──────────
  CONT=\$(sudo crictl ps | grep doca-hbn | grep -v init | awk '{print \$1}')
  sudo crictl exec -it \$CONT nv

  [NVUE REST API]
  ───────────────
  # System info
  curl -k -u nvidia:nvidia https://${BF3_IP}:8765/nvue_v1/system

  # All interfaces
  curl -k -u nvidia:nvidia https://${BF3_IP}:8765/nvue_v1/interface

  # VRF / routing
  curl -k -u nvidia:nvidia https://${BF3_IP}:8765/nvue_v1/vrf

  # BGP
  curl -k -u nvidia:nvidia https://${BF3_IP}:8765/nvue_v1/vrf/default/router/bgp

  # Apply config change (revision workflow):
  REV=\$(curl -sk -u nvidia:nvidia -X POST https://${BF3_IP}:8765/nvue_v1/revision \\
    | python3 -c "import sys,json; print(list(json.load(sys.stdin).keys())[0])")
  # ... PATCH config into revision using ?rev=\$REV ...
  curl -sk -u nvidia:nvidia -X PATCH "https://${BF3_IP}:8765/nvue_v1/revision/\$REV" \\
    -H "Content-Type: application/json" \\
    -d '{"state":"apply","auto-prompt":{"ays":"yes"}}'

  [OVS / eswitch (run on BF3)]
  ─────────────────────────────
  sudo ovs-vsctl show

  [Topology reference (run on BF3)]
  ───────────────────────────────────
  sudo ./topology_hbn.sh

  [Health check (run on BF3)]
  ────────────────────────────
  sudo ./status_hbn.sh

============================================================

EOF
