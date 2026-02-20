#!/bin/bash
#
# vasn_tap integration test - Filter (ACL) with AF_PACKET mode
# Uses -c config with default_action: drop and no rules (drop all).
# Verifies TX=0, Dropped>0.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VASN_TAP="$PROJECT_DIR/vasn_tap"
NUM_PINGS=20
WORKERS=2
TIMEOUT=10
START_TIME=$(date +%s)

source "$SCRIPT_DIR/test_helpers.sh"

echo "=== Test: filter_afpacket (ACL drop all) ==="

RESULT="FAIL"
ERROR_MSG=""
RX_COUNT=0
TX_COUNT=0
DROP_COUNT=0

CONFIG_FILE=$(mktemp /tmp/vasn_tap_filter_XXXXXX.yaml)
cat > "$CONFIG_FILE" <<EOF
runtime:
  input_iface: veth_src_host
  output_iface: veth_dst_host
  mode: afpacket
  workers: $WORKERS
  stats: true
filter:
  default_action: drop
  rules: []
EOF

STATS_FILE=$(mktemp /tmp/vasn_tap_stats_XXXXXX.txt)

$VASN_TAP -c "$CONFIG_FILE" > "$STATS_FILE" 2>&1 &
VASN_PID=$!
sleep 1

if ! kill -0 $VASN_PID 2>/dev/null; then
    ERROR_MSG="vasn_tap failed to start with filter config"
    echo "FAIL: $ERROR_MSG"
    cat "$STATS_FILE"
    rm -f "$CONFIG_FILE" "$STATS_FILE"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json "test_name" "Filter (drop all) - AF_PACKET" "description" "ACL default_action=drop, rules=[]. Expect TX=0, Dropped>0." "result" "$RESULT" "mode" "afpacket" "workers" "$WORKERS" "input_iface" "veth_src_host" "output_iface" "veth_dst_host" "traffic_type" "ICMP ping" "traffic_count" "$NUM_PINGS" "rx_packets" "0" "tx_packets" "0" "dropped_packets" "0" "captured_at_dst" "0" "duration_sec" "$DURATION" "error_msg" "$ERROR_MSG")
    write_result "$JSON" "filter_afpacket"
    exit 1
fi

ip netns exec ns_src ping -c $NUM_PINGS -i 0.1 -W 1 192.168.200.2 > /dev/null 2>&1 || true
sleep 1

kill -INT $VASN_PID 2>/dev/null || true
wait $VASN_PID 2>/dev/null || true

RX_COUNT=$(grep -oP 'RX: \K[0-9]+' "$STATS_FILE" | tail -1)
TX_COUNT=$(grep -oP 'TX: \K[0-9]+' "$STATS_FILE" | tail -1)
DROP_COUNT=$(grep -oP 'Dropped: \K[0-9]+' "$STATS_FILE" | tail -1)

echo "  RX=${RX_COUNT:-0}, TX=${TX_COUNT:-0}, Dropped=${DROP_COUNT:-0}"

rm -f "$CONFIG_FILE" "$STATS_FILE"
DURATION=$(($(date +%s) - START_TIME))

if [ "${RX_COUNT:-0}" -gt 0 ] && [ "${TX_COUNT:-0}" -eq 0 ] && [ "${DROP_COUNT:-0}" -gt 0 ]; then
    RESULT="PASS"
    echo "PASS: filter_afpacket"
else
    ERROR_MSG="With drop-all filter expected RX>0, TX=0, Dropped>0; got RX=${RX_COUNT:-0}, TX=${TX_COUNT:-0}, Dropped=${DROP_COUNT:-0}"
    echo "FAIL: filter_afpacket - $ERROR_MSG"
fi

JSON=$(build_result_json "test_name" "Filter (drop all) - AF_PACKET" "description" "ACL default_action=drop, rules=[]. Expect TX=0, Dropped>0." "result" "$RESULT" "mode" "afpacket" "workers" "$WORKERS" "input_iface" "veth_src_host" "output_iface" "veth_dst_host" "traffic_type" "ICMP ping" "traffic_count" "$NUM_PINGS" "rx_packets" "${RX_COUNT:-0}" "tx_packets" "${TX_COUNT:-0}" "dropped_packets" "${DROP_COUNT:-0}" "captured_at_dst" "0" "duration_sec" "$DURATION" "error_msg" "$ERROR_MSG")
write_result "$JSON" "filter_afpacket"

[ "$RESULT" = "PASS" ]
