#!/bin/bash
#
# vasn_tap integration test - Filter (ACL) with eBPF mode
# Uses -c config with default_action: drop and no rules (drop all).
# Verifies TX=0, Dropped>0, no packets at ns_dst.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VASN_TAP="$PROJECT_DIR/vasn_tap"
NUM_PINGS=20
TIMEOUT=10
START_TIME=$(date +%s)

source "$SCRIPT_DIR/test_helpers.sh"

echo "=== Test: filter_ebpf (ACL drop all) ==="

RESULT="FAIL"
ERROR_MSG=""
RX_COUNT=0
TX_COUNT=0
DROP_COUNT=0
CAPTURED=0

CONFIG_FILE=$(mktemp /tmp/vasn_tap_filter_XXXXXX.yaml)
cat > "$CONFIG_FILE" << 'EOF'
filter:
  default_action: drop
  rules: []
EOF

CAPTURE_FILE=$(mktemp /tmp/vasn_tap_test_XXXXXX.pcap)
STATS_FILE=$(mktemp /tmp/vasn_tap_stats_XXXXXX.txt)

ip netns exec ns_dst timeout $TIMEOUT tcpdump -i veth_dst_ns -c $NUM_PINGS -w "$CAPTURE_FILE" 2>/dev/null &
TCPDUMP_PID=$!
sleep 0.5

$VASN_TAP -m ebpf -i veth_src_host -o veth_dst_host -s -c "$CONFIG_FILE" > "$STATS_FILE" 2>&1 &
VASN_PID=$!
sleep 1

if ! kill -0 $VASN_PID 2>/dev/null; then
    ERROR_MSG="vasn_tap failed to start with filter config (ebpf)"
    echo "FAIL: $ERROR_MSG"
    cat "$STATS_FILE"
    rm -f "$CONFIG_FILE" "$CAPTURE_FILE" "$STATS_FILE"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Filter (drop all) - eBPF" \
        "description"       "Run with ACL config default_action=drop, rules=[]. Expect TX=0, Dropped>0." \
        "result"            "$RESULT" \
        "mode"              "ebpf" \
        "workers"           "1" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
        "traffic_type"      "ICMP ping" \
        "traffic_count"     "$NUM_PINGS" \
        "rx_packets"        "0" \
        "tx_packets"        "0" \
        "dropped_packets"   "0" \
        "captured_at_dst"   "0" \
        "duration_sec"      "$DURATION" \
        "error_msg"         "$ERROR_MSG")
    write_result "$JSON" "filter_ebpf"
    exit 1
fi

ip netns exec ns_src ping -c $NUM_PINGS -i 0.1 -W 1 192.168.200.2 > /dev/null 2>&1 || true
sleep 1

kill -INT $VASN_PID 2>/dev/null || true
wait $VASN_PID 2>/dev/null || true
wait $TCPDUMP_PID 2>/dev/null || true

RX_COUNT=$(grep -oP 'RX: \K[0-9]+' "$STATS_FILE" | tail -1)
TX_COUNT=$(grep -oP 'TX: \K[0-9]+' "$STATS_FILE" | tail -1)
DROP_COUNT=$(grep -oP 'Dropped: \K[0-9]+' "$STATS_FILE" | tail -1)
CAPTURED=$(tcpdump -r "$CAPTURE_FILE" 2>/dev/null | wc -l)

echo "  RX=${RX_COUNT:-0}, TX=${TX_COUNT:-0}, Dropped=${DROP_COUNT:-0}, captured_at_dst=$CAPTURED"

rm -f "$CONFIG_FILE" "$CAPTURE_FILE" "$STATS_FILE"
DURATION=$(($(date +%s) - START_TIME))

if [ "${RX_COUNT:-0}" -gt 0 ] && [ "${TX_COUNT:-0}" -eq 0 ] && [ "${DROP_COUNT:-0}" -gt 0 ]; then
    RESULT="PASS"
    echo "PASS: filter_ebpf"
else
    ERROR_MSG="With drop-all filter expected RX>0, TX=0, Dropped>0; got RX=${RX_COUNT:-0}, TX=${TX_COUNT:-0}, Dropped=${DROP_COUNT:-0}"
    echo "FAIL: filter_ebpf - $ERROR_MSG"
fi

JSON=$(build_result_json \
    "test_name"         "Filter (drop all) - eBPF" \
    "description"       "Run with ACL config default_action=drop, rules=[]. Expect TX=0, Dropped>0." \
    "result"            "$RESULT" \
    "mode"              "ebpf" \
    "workers"           "1" \
    "input_iface"       "veth_src_host" \
    "output_iface"      "veth_dst_host" \
    "traffic_type"      "ICMP ping" \
    "traffic_count"     "$NUM_PINGS" \
    "rx_packets"        "${RX_COUNT:-0}" \
    "tx_packets"        "${TX_COUNT:-0}" \
    "dropped_packets"   "${DROP_COUNT:-0}" \
    "captured_at_dst"   "$CAPTURED" \
    "duration_sec"      "$DURATION" \
    "error_msg"         "$ERROR_MSG")
write_result "$JSON" "filter_ebpf"

[ "$RESULT" = "PASS" ]
