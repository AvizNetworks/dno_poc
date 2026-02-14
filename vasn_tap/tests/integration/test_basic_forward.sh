#!/bin/bash
#
# vasn_tap integration test - Basic packet forwarding
# Sends pings from ns_src, verifies they are forwarded to ns_dst via vasn_tap
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VASN_TAP="$PROJECT_DIR/vasn_tap"
MODE="${1:-afpacket}"
NUM_PINGS=20
WORKERS=2
TIMEOUT=10
START_TIME=$(date +%s)

# Source helpers for JSON result writing
source "$SCRIPT_DIR/test_helpers.sh"

echo "=== Test: basic_forward (mode=$MODE) ==="

RESULT="FAIL"
ERROR_MSG=""
RX_COUNT=0
CAPTURED=0

# Verify binary exists
if [ ! -x "$VASN_TAP" ]; then
    ERROR_MSG="vasn_tap binary not found at $VASN_TAP"
    echo "FAIL: $ERROR_MSG"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Basic Packet Forwarding" \
        "description"       "Send $NUM_PINGS ICMP pings from ns_src through vasn_tap to ns_dst and verify packets are forwarded" \
        "result"            "$RESULT" \
        "mode"              "$MODE" \
        "workers"           "$WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
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
    write_result "$JSON" "basic_forward_${MODE}"
    exit 1
fi

# Verify namespaces exist
if ! ip netns list | grep -q ns_src; then
    ERROR_MSG="ns_src namespace not found. Run setup_namespaces.sh first."
    echo "FAIL: $ERROR_MSG"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Basic Packet Forwarding" \
        "description"       "Send $NUM_PINGS ICMP pings from ns_src through vasn_tap to ns_dst and verify packets are forwarded" \
        "result"            "$RESULT" \
        "mode"              "$MODE" \
        "workers"           "$WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
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
    write_result "$JSON" "basic_forward_${MODE}"
    exit 1
fi

# Start packet capture in ns_dst
CAPTURE_FILE=$(mktemp /tmp/vasn_tap_test_XXXXXX.pcap)
ip netns exec ns_dst timeout $TIMEOUT tcpdump -i veth_dst_ns -c $NUM_PINGS -w "$CAPTURE_FILE" 2>/dev/null &
TCPDUMP_PID=$!
sleep 0.5

# Start vasn_tap
STATS_FILE=$(mktemp /tmp/vasn_tap_stats_XXXXXX.txt)
$VASN_TAP -m "$MODE" -i veth_src_host -o veth_dst_host -w $WORKERS -s -v > "$STATS_FILE" 2>&1 &
VASN_PID=$!
sleep 1

# Verify vasn_tap is running
if ! kill -0 $VASN_PID 2>/dev/null; then
    ERROR_MSG="vasn_tap failed to start"
    echo "FAIL: $ERROR_MSG"
    cat "$STATS_FILE"
    rm -f "$CAPTURE_FILE" "$STATS_FILE"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Basic Packet Forwarding" \
        "description"       "Send $NUM_PINGS ICMP pings from ns_src through vasn_tap to ns_dst and verify packets are forwarded" \
        "result"            "$RESULT" \
        "mode"              "$MODE" \
        "workers"           "$WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
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
    write_result "$JSON" "basic_forward_${MODE}"
    exit 1
fi

# Send pings from ns_src to host (through veth_src)
echo "  Sending $NUM_PINGS pings from ns_src..."
ip netns exec ns_src ping -c $NUM_PINGS -i 0.1 -W 1 192.168.200.2 > /dev/null 2>&1 || true
sleep 1

# Stop vasn_tap gracefully
kill -INT $VASN_PID 2>/dev/null || true
wait $VASN_PID 2>/dev/null || true

# Wait for tcpdump to finish
wait $TCPDUMP_PID 2>/dev/null || true

# Check results
CAPTURED=$(tcpdump -r "$CAPTURE_FILE" 2>/dev/null | wc -l)

# Check vasn_tap stats - look for RX count
RX_COUNT=$(grep -oP 'RX: \K[0-9]+' "$STATS_FILE" | tail -1)
TX_COUNT=$(grep -oP 'TX: \K[0-9]+' "$STATS_FILE" | tail -1)
DROP_COUNT=$(grep -oP 'Dropped: \K[0-9]+' "$STATS_FILE" | tail -1)

echo "  vasn_tap RX: ${RX_COUNT:-0}"
echo "  vasn_tap TX: ${TX_COUNT:-0}"
echo "  Packets captured in ns_dst: $CAPTURED"

# Cleanup temp files
rm -f "$CAPTURE_FILE" "$STATS_FILE"

DURATION=$(($(date +%s) - START_TIME))

# Verify
if [ "${RX_COUNT:-0}" -gt 0 ] && [ "$CAPTURED" -gt 0 ]; then
    RESULT="PASS"
    echo "PASS: basic_forward (mode=$MODE)"
else
    ERROR_MSG="Expected RX>0 and captured>0, got RX=${RX_COUNT:-0}, captured=$CAPTURED"
    echo "FAIL: basic_forward (mode=$MODE) - $ERROR_MSG"
fi

# Build mode-specific note
if [ "$MODE" = "afpacket" ]; then
    NOTE_TEXT="AF_PACKET RX counts all raw frames on the input interface (both directions: echo requests + echo replies + ARP). Sent $NUM_PINGS pings, but AF_PACKET sees ~${NUM_PINGS}x2 ICMP frames plus ARP overhead."
else
    NOTE_TEXT="eBPF mode uses TC hook + perf buffer. RX count reflects packets delivered by the perf buffer to userspace. Count depends on TC hook direction and kernel behavior."
fi

# Write JSON result
JSON=$(build_result_json \
    "test_name"         "Basic Packet Forwarding ($MODE)" \
    "description"       "Send $NUM_PINGS ICMP pings from ns_src through vasn_tap to ns_dst and verify packets are forwarded" \
    "result"            "$RESULT" \
    "mode"              "$MODE" \
    "workers"           "$WORKERS" \
    "input_iface"       "veth_src_host" \
    "output_iface"      "veth_dst_host" \
    "traffic_type"      "ICMP ping" \
    "traffic_count"     "$NUM_PINGS" \
    "traffic_src"       "ns_src (192.168.200.1)" \
    "traffic_dst"       "host (192.168.200.2)" \
    "rx_packets"        "${RX_COUNT:-0}" \
    "tx_packets"        "${TX_COUNT:-0}" \
    "dropped_packets"   "${DROP_COUNT:-0}" \
    "captured_at_dst"   "$CAPTURED" \
    "duration_sec"      "$DURATION" \
    "error_msg"         "$ERROR_MSG" \
    "note"              "$NOTE_TEXT")
write_result "$JSON" "basic_forward_${MODE}"

[ "$RESULT" = "PASS" ]
