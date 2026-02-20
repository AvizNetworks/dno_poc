#!/bin/bash
#
# vasn_tap integration test - Drop mode (no output interface)
# Verifies RX counts but zero TX when -o is not specified
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VASN_TAP="$PROJECT_DIR/vasn_tap"
MODE="${1:-afpacket}"
NUM_PINGS=20
WORKERS=2
START_TIME=$(date +%s)

# Source helpers for JSON result writing
source "$SCRIPT_DIR/test_helpers.sh"

echo "=== Test: drop_mode (mode=$MODE) ==="

RESULT="FAIL"
ERROR_MSG=""
RX_COUNT=0
TX_COUNT=0
DROP_COUNT=0

STATS_FILE=$(mktemp /tmp/vasn_tap_stats_XXXXXX.txt)
CONFIG_FILE=$(mktemp /tmp/vasn_tap_drop_XXXXXX.yaml)
cat > "$CONFIG_FILE" <<EOF
runtime:
  input_iface: veth_src_host
  mode: $MODE
  workers: $WORKERS
  stats: true
filter:
  default_action: allow
  rules: []
EOF

# Start vasn_tap WITHOUT -o (drop mode)
$VASN_TAP -c "$CONFIG_FILE" > "$STATS_FILE" 2>&1 &
VASN_PID=$!
sleep 1

if ! kill -0 $VASN_PID 2>/dev/null; then
    ERROR_MSG="vasn_tap failed to start in drop mode (mode=$MODE)"
    echo "FAIL: $ERROR_MSG"
    cat "$STATS_FILE"
    rm -f "$STATS_FILE" "$CONFIG_FILE"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Drop Mode - $MODE" \
        "description"       "Capture $NUM_PINGS ICMP pings in $MODE mode with no output interface. Verify RX counts packets, TX stays zero, and dropped counter increments." \
        "result"            "$RESULT" \
        "mode"              "$MODE" \
        "workers"           "$WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "(none - drop mode)" \
        "traffic_type"      "ICMP ping" \
        "traffic_count"     "$NUM_PINGS" \
        "traffic_src"       "ns_src (192.168.200.1)" \
        "traffic_dst"       "host (192.168.200.2)" \
        "rx_packets"        "0" \
        "tx_packets"        "0" \
        "dropped_packets"   "0" \
        "captured_at_dst"   "0" \
        "duration_sec"      "$DURATION" \
        "error_msg"         "$ERROR_MSG")
    write_result "$JSON" "drop_mode_${MODE}"
    exit 1
fi

# Send traffic
ip netns exec ns_src ping -c $NUM_PINGS -i 0.1 -W 1 192.168.200.2 > /dev/null 2>&1 || true
sleep 1

# Stop
kill -INT $VASN_PID 2>/dev/null || true
wait $VASN_PID 2>/dev/null || true

# Check stats
RX_COUNT=$(grep -oP 'RX: \K[0-9]+' "$STATS_FILE" | tail -1)
TX_COUNT=$(grep -oP 'TX: \K[0-9]+' "$STATS_FILE" | tail -1)
DROP_COUNT=$(grep -oP 'Dropped: \K[0-9]+' "$STATS_FILE" | tail -1)

echo "  RX=${RX_COUNT:-0}, TX=${TX_COUNT:-0}, Dropped=${DROP_COUNT:-0}"

rm -f "$STATS_FILE" "$CONFIG_FILE"

DURATION=$(($(date +%s) - START_TIME))

# Verify: RX > 0, TX = 0, Dropped > 0
if [ "${RX_COUNT:-0}" -gt 0 ] && [ "${TX_COUNT:-0}" -eq 0 ] && [ "${DROP_COUNT:-0}" -gt 0 ]; then
    RESULT="PASS"
    echo "PASS: drop_mode (mode=$MODE)"
else
    ERROR_MSG="Expected RX>0, TX=0, Dropped>0, got RX=${RX_COUNT:-0}, TX=${TX_COUNT:-0}, Dropped=${DROP_COUNT:-0}"
    echo "FAIL: drop_mode (mode=$MODE) - $ERROR_MSG"
fi

# Build mode-specific note
if [ "$MODE" = "afpacket" ]; then
    NOTE_TEXT="No output interface configured -- all captured frames are counted as dropped. AF_PACKET RX includes both directions (requests + replies) plus ARP overhead."
else
    NOTE_TEXT="No output interface configured -- all captured frames are counted as dropped. eBPF perf buffer delivers packets matching the TC hook."
fi

# Write JSON result
JSON=$(build_result_json \
    "test_name"         "Drop Mode - $MODE" \
    "description"       "Capture $NUM_PINGS ICMP pings in $MODE mode with no output interface. Verify RX counts packets, TX stays zero, and dropped counter increments." \
    "result"            "$RESULT" \
    "mode"              "$MODE" \
    "workers"           "$WORKERS" \
    "input_iface"       "veth_src_host" \
    "output_iface"      "(none - drop mode)" \
    "traffic_type"      "ICMP ping" \
    "traffic_count"     "$NUM_PINGS" \
    "traffic_src"       "ns_src (192.168.200.1)" \
    "traffic_dst"       "host (192.168.200.2)" \
    "rx_packets"        "${RX_COUNT:-0}" \
    "tx_packets"        "${TX_COUNT:-0}" \
    "dropped_packets"   "${DROP_COUNT:-0}" \
    "captured_at_dst"   "0" \
    "duration_sec"      "$DURATION" \
    "error_msg"         "$ERROR_MSG" \
    "note"              "$NOTE_TEXT")
write_result "$JSON" "drop_mode_${MODE}"

[ "$RESULT" = "PASS" ]
