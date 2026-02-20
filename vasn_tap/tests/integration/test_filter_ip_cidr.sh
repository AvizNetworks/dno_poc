#!/bin/bash
#
# vasn_tap integration test - Filter: default drop, one rule allow ip_src 192.168.200.0/24
# Traffic from ns_src (192.168.200.1) matches CIDR; expect RX>0, TX>0, Dropped=0.
# Usage: test_filter_ip_cidr.sh [afpacket|ebpf]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VASN_TAP="$PROJECT_DIR/vasn_tap"
MODE="${1:-afpacket}"
NUM_PINGS=20
TIMEOUT=10
START_TIME=$(date +%s)

if [ "$MODE" = "ebpf" ]; then
    WORKERS=1
else
    WORKERS=2
fi

source "$SCRIPT_DIR/test_helpers.sh"

echo "=== Test: filter_ip_cidr (mode=$MODE) ==="

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
  mode: $MODE
  workers: $WORKERS
  stats: true
filter:
  default_action: drop
  rules:
    - action: allow
      match:
        ip_src: 192.168.200.0/24
EOF

if ! $VASN_TAP -V -c "$CONFIG_FILE" > /dev/null 2>&1; then
    ERROR_MSG="Config file failed to load (validate-config)"
    echo "FAIL: $ERROR_MSG"
    $VASN_TAP -V -c "$CONFIG_FILE" 2>&1 || true
    rm -f "$CONFIG_FILE"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json "test_name" "Filter (IP CIDR) - $MODE" "description" "ACL default_action=drop, one rule allow ip_src 192.168.200.0/24. Expect RX>0, TX>0, Dropped=0." "result" "$RESULT" "mode" "$MODE" "workers" "$WORKERS" "input_iface" "veth_src_host" "output_iface" "veth_dst_host" "traffic_type" "ICMP ping" "traffic_count" "$NUM_PINGS" "rx_packets" "0" "tx_packets" "0" "dropped_packets" "0" "captured_at_dst" "0" "duration_sec" "$DURATION" "error_msg" "$ERROR_MSG")
    write_result "$JSON" "filter_ip_cidr_${MODE}"
    exit 1
fi

STATS_FILE=$(mktemp /tmp/vasn_tap_stats_XXXXXX.txt)

$VASN_TAP -c "$CONFIG_FILE" > "$STATS_FILE" 2>&1 &
VASN_PID=$!
sleep 1

if ! kill -0 $VASN_PID 2>/dev/null; then
    ERROR_MSG="vasn_tap failed to start with ip_src CIDR filter config"
    echo "FAIL: $ERROR_MSG"
    cat "$STATS_FILE"
    rm -f "$CONFIG_FILE" "$STATS_FILE"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json "test_name" "Filter (IP CIDR) - $MODE" "description" "ACL default_action=drop, one rule allow ip_src 192.168.200.0/24. Expect RX>0, TX>0, Dropped=0." "result" "$RESULT" "mode" "$MODE" "workers" "$WORKERS" "input_iface" "veth_src_host" "output_iface" "veth_dst_host" "traffic_type" "ICMP ping" "traffic_count" "$NUM_PINGS" "rx_packets" "0" "tx_packets" "0" "dropped_packets" "0" "captured_at_dst" "0" "duration_sec" "$DURATION" "error_msg" "$ERROR_MSG")
    write_result "$JSON" "filter_ip_cidr_${MODE}"
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

if [ "${RX_COUNT:-0}" -gt 0 ] && [ "${TX_COUNT:-0}" -gt 0 ] && [ "${DROP_COUNT:-0}" -eq 0 ]; then
    RESULT="PASS"
    echo "PASS: filter_ip_cidr ($MODE)"
else
    ERROR_MSG="With ip_src 192.168.200.0/24 rule expected RX>0, TX>0, Dropped=0; got RX=${RX_COUNT:-0}, TX=${TX_COUNT:-0}, Dropped=${DROP_COUNT:-0}"
    echo "FAIL: filter_ip_cidr ($MODE) - $ERROR_MSG"
fi

JSON=$(build_result_json "test_name" "Filter (IP CIDR) - $MODE" "description" "ACL default_action=drop, one rule allow ip_src 192.168.200.0/24. Expect RX>0, TX>0, Dropped=0." "result" "$RESULT" "mode" "$MODE" "workers" "$WORKERS" "input_iface" "veth_src_host" "output_iface" "veth_dst_host" "traffic_type" "ICMP ping" "traffic_count" "$NUM_PINGS" "rx_packets" "${RX_COUNT:-0}" "tx_packets" "${TX_COUNT:-0}" "dropped_packets" "${DROP_COUNT:-0}" "captured_at_dst" "0" "duration_sec" "$DURATION" "error_msg" "$ERROR_MSG")
write_result "$JSON" "filter_ip_cidr_${MODE}"

[ "$RESULT" = "PASS" ]
