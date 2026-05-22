#!/usr/bin/env bash
# mirror_to_dpu.sh — Mirror internet-facing interface traffic to BF3 DPU for DPI
#
# Uses tc mirred MIRROR (copy) — original traffic is completely unaffected.
# Run on the x86 host (10.20.13.13) with sudo.
#
# Usage:
#   sudo ./mirror_to_dpu.sh start
#   sudo ./mirror_to_dpu.sh stop
#   sudo ./mirror_to_dpu.sh status
set -uo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
SRC_IFACE="eno2"           # Internet-facing interface (10.20.13.13)
DST_IFACE="enp65s0f0np0"  # BF3 PCIe link → OVS mirror → aviz0 → DPI

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

ok()   { printf "${GREEN}[OK]${NC}   %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$*"; }
info() { printf "${CYAN}[INFO]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }

# ─── Helpers ─────────────────────────────────────────────────────────────────
require_root() {
  [[ $EUID -eq 0 ]] || { echo -e "${RED}ERROR:${NC} Run with sudo."; exit 1; }
}

ingress_active() {
  tc filter show dev "$SRC_IFACE" parent ffff: 2>/dev/null | grep -q "mirred"
}

egress_active() {
  tc qdisc show dev "$SRC_IFACE" 2>/dev/null | grep -q "prio" && \
  tc filter show dev "$SRC_IFACE" parent 1: 2>/dev/null | grep -q "mirred"
}

# ─── Start ───────────────────────────────────────────────────────────────────
start_mirror() {
  require_root
  echo ""
  echo -e "  ${BOLD}Mirror ON: ${SRC_IFACE} → ${DST_IFACE}${NC}"
  echo -e "  ${CYAN}(copy only — existing internet connectivity is unaffected)${NC}"
  echo ""

  # Ingress: traffic arriving on SRC_IFACE (inbound internet)
  if ingress_active; then
    warn "Ingress mirror already active"
  else
    info "Setting up ingress mirror (inbound traffic on ${SRC_IFACE})..."
    tc qdisc add dev "$SRC_IFACE" handle ffff: ingress 2>/dev/null || true
    if tc filter add dev "$SRC_IFACE" parent ffff: protocol all \
        u32 match u32 0 0 \
        action mirred egress mirror dev "$DST_IFACE" 2>/dev/null; then
      ok "Ingress mirror active"
    else
      fail "Failed to add ingress mirror filter"
    fi
  fi

  # Egress: traffic leaving via SRC_IFACE (outbound internet)
  if egress_active; then
    warn "Egress mirror already active"
  else
    info "Setting up egress mirror (outbound traffic on ${SRC_IFACE})..."
    # Replace root qdisc with prio so we can attach a filter
    # prio passes all traffic normally — no impact on throughput or latency
    tc qdisc replace dev "$SRC_IFACE" handle 1: root prio 2>/dev/null || \
    tc qdisc add    dev "$SRC_IFACE" handle 1: root prio 2>/dev/null || true
    if tc filter add dev "$SRC_IFACE" parent 1: protocol all \
        u32 match u32 0 0 \
        action mirred egress mirror dev "$DST_IFACE" 2>/dev/null; then
      ok "Egress mirror active"
    else
      fail "Failed to add egress mirror filter"
    fi
  fi

  echo ""
  echo -e "  Traffic path:"
  echo -e "    ${SRC_IFACE} (internet) ──tc mirred──▶ ${DST_IFACE} ──▶ BF3 OVS ──▶ aviz0 ──▶ DPI"
  echo ""
}

# ─── Stop ────────────────────────────────────────────────────────────────────
stop_mirror() {
  require_root
  echo ""
  echo -e "  ${BOLD}Mirror OFF: removing ${SRC_IFACE} → ${DST_IFACE}${NC}"
  echo ""

  # Remove ingress qdisc (takes all ingress filters with it)
  if tc qdisc show dev "$SRC_IFACE" 2>/dev/null | grep -q "ffff:"; then
    info "Removing ingress mirror..."
    tc qdisc del dev "$SRC_IFACE" ingress 2>/dev/null \
      && ok "Ingress mirror removed" \
      || warn "Could not remove ingress qdisc"
  else
    warn "No ingress mirror found"
  fi

  # Remove root prio qdisc (kernel restores default pfifo_fast automatically)
  if tc qdisc show dev "$SRC_IFACE" 2>/dev/null | grep -q "prio"; then
    info "Removing egress mirror..."
    tc qdisc del dev "$SRC_IFACE" root 2>/dev/null \
      && ok "Egress mirror removed — default qdisc restored" \
      || warn "Could not remove root qdisc"
  else
    warn "No egress mirror found"
  fi

  echo ""
}

# ─── Status ──────────────────────────────────────────────────────────────────
show_status() {
  echo ""
  echo -e "  ${BOLD}Mirror Status: ${SRC_IFACE} → ${DST_IFACE}${NC}"
  echo ""

  if ingress_active; then
    echo -e "  Ingress (inbound  → ${SRC_IFACE}): ${GREEN}ACTIVE${NC}"
  else
    echo -e "  Ingress (inbound  → ${SRC_IFACE}): ${RED}INACTIVE${NC}"
  fi

  if egress_active; then
    echo -e "  Egress  (outbound ← ${SRC_IFACE}): ${GREEN}ACTIVE${NC}"
  else
    echo -e "  Egress  (outbound ← ${SRC_IFACE}): ${RED}INACTIVE${NC}"
  fi

  echo ""
  echo "  qdiscs on ${SRC_IFACE}:"
  tc qdisc show dev "$SRC_IFACE" 2>/dev/null | sed 's/^/    /' || true
  echo ""
  echo "  filters (ingress):"
  tc filter show dev "$SRC_IFACE" parent ffff: 2>/dev/null | grep -v "^$" | sed 's/^/    /' || true
  echo "  filters (egress):"
  tc filter show dev "$SRC_IFACE" parent 1: 2>/dev/null | grep -v "^$" | sed 's/^/    /' || true
  echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────
case "${1:-help}" in
  start)  start_mirror ;;
  stop)   stop_mirror  ;;
  status) show_status  ;;
  *)
    echo ""
    echo -e "  ${BOLD}Usage:${NC} sudo $0 {start|stop|status}"
    echo ""
    echo "  start   mirror all ${SRC_IFACE} traffic to ${DST_IFACE} (non-destructive copy)"
    echo "  stop    remove mirror, restore default qdisc"
    echo "  status  show current mirror state and tc filters"
    echo ""
    echo "  Source : ${SRC_IFACE}  — internet-facing NIC (10.20.13.13)"
    echo "  Dest   : ${DST_IFACE}  — BF3 PCIe link → OVS br-hbn → aviz0 → Aviz DPI"
    echo ""
    exit 1
    ;;
esac
