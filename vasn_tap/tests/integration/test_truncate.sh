#!/bin/bash
#
# vasn_tap integration test - Truncation (runtime.truncate)
# Verifies that when truncate is enabled, forwarded packets are truncated to
# runtime.truncate.length; when disabled, original lengths are preserved.
# Usage: test_truncate.sh [afpacket|ebpf|no_truncate]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VASN_TAP="$PROJECT_DIR/vasn_tap"
MODE="${1:-afpacket}"
TRUNCATE_LEN=128
NUM_PINGS=20
PING_PAYLOAD=200
WORKERS=2
TIMEOUT=15
START_TIME=$(date +%s)

source "$SCRIPT_DIR/test_helpers.sh"

echo "=== Test: truncate (mode=$MODE) ==="

RESULT="FAIL"
ERROR_MSG=""
RX_COUNT=0
TX_COUNT=0
CAPTURED=0
TRUNCATED_COUNT=0

if [ ! -x "$VASN_TAP" ]; then
    ERROR_MSG="vasn_tap binary not found at $VASN_TAP"
    echo "FAIL: $ERROR_MSG"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Truncation ($MODE)" \
        "description"       "Verify packet truncation to ${TRUNCATE_LEN}B when enabled" \
        "result"            "$RESULT" \
        "mode"              "$MODE" \
        "workers"           "$WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
        "traffic_type"      "ICMP ping -s $PING_PAYLOAD" \
        "traffic_count"     "$NUM_PINGS" \
        "rx_packets"        "0" \
        "tx_packets"        "0" \
        "dropped_packets"   "0" \
        "captured_at_dst"   "0" \
        "duration_sec"      "$DURATION" \
        "error_msg"         "$ERROR_MSG")
    write_result "$JSON" "truncate_${MODE}"
    exit 1
fi

if ! ip netns list | grep -q ns_src; then
    ERROR_MSG="ns_src namespace not found. Run setup_namespaces.sh first."
    echo "FAIL: $ERROR_MSG"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Truncation ($MODE)" \
        "description"       "Verify packet truncation to ${TRUNCATE_LEN}B when enabled" \
        "result"            "$RESULT" \
        "mode"              "$MODE" \
        "workers"           "$WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
        "traffic_type"      "ICMP ping -s $PING_PAYLOAD" \
        "traffic_count"     "$NUM_PINGS" \
        "rx_packets"        "0" \
        "tx_packets"        "0" \
        "dropped_packets"   "0" \
        "captured_at_dst"   "0" \
        "duration_sec"      "$DURATION" \
        "error_msg"         "$ERROR_MSG")
    write_result "$JSON" "truncate_${MODE}"
    exit 1
fi

CAPTURE_FILE=$(mktemp /tmp/vasn_tap_truncate_XXXXXX.pcap)
ip netns exec ns_dst timeout $TIMEOUT tcpdump -i veth_dst_ns -c $((NUM_PINGS * 2)) -w "$CAPTURE_FILE" 2>/dev/null &
TCPDUMP_PID=$!
sleep 0.5

if [ "$MODE" = "no_truncate" ]; then
    TRUNCATE_YAML=""
    MODE_FOR_CONFIG="afpacket"
else
    TRUNCATE_YAML="  truncate:
    enabled: true
    length: $TRUNCATE_LEN"
    MODE_FOR_CONFIG="$MODE"
fi

CONFIG_FILE=$(mktemp /tmp/vasn_tap_truncate_XXXXXX.yaml)
cat > "$CONFIG_FILE" <<EOF
runtime:
  input_iface: veth_src_host
  output_iface: veth_dst_host
  mode: $MODE_FOR_CONFIG
  workers: $WORKERS
  verbose: true
  stats: true
$TRUNCATE_YAML
filter:
  default_action: allow
  rules: []
EOF

STATS_FILE=$(mktemp /tmp/vasn_tap_truncate_stats_XXXXXX.txt)
$VASN_TAP -c "$CONFIG_FILE" > "$STATS_FILE" 2>&1 &
VASN_PID=$!
sleep 1

if ! kill -0 $VASN_PID 2>/dev/null; then
    ERROR_MSG="vasn_tap failed to start"
    echo "FAIL: $ERROR_MSG"
    cat "$STATS_FILE"
    rm -f "$CAPTURE_FILE" "$STATS_FILE" "$CONFIG_FILE"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Truncation ($MODE)" \
        "description"       "Verify packet truncation to ${TRUNCATE_LEN}B when enabled" \
        "result"            "$RESULT" \
        "mode"              "$MODE" \
        "workers"           "$WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
        "traffic_type"      "ICMP ping -s $PING_PAYLOAD" \
        "traffic_count"     "$NUM_PINGS" \
        "rx_packets"        "0" \
        "tx_packets"        "0" \
        "dropped_packets"   "0" \
        "captured_at_dst"   "0" \
        "duration_sec"      "$DURATION" \
        "error_msg"         "$ERROR_MSG")
    write_result "$JSON" "truncate_${MODE}"
    exit 1
fi

echo "  Sending $NUM_PINGS pings (payload ${PING_PAYLOAD}B) from ns_src..."
ip netns exec ns_src ping -c $NUM_PINGS -s $PING_PAYLOAD -i 0.1 -W 1 192.168.200.2 > /dev/null 2>&1 || true
sleep 1

kill -INT $VASN_PID 2>/dev/null || true
wait $VASN_PID 2>/dev/null || true
wait $TCPDUMP_PID 2>/dev/null || true

CAPTURED=$(tcpdump -r "$CAPTURE_FILE" 2>/dev/null | wc -l)
RX_COUNT=$(grep -oP 'RX: \K[0-9]+' "$STATS_FILE" | tail -1)
TX_COUNT=$(grep -oP 'TX: \K[0-9]+' "$STATS_FILE" | tail -1)
DROP_COUNT=$(grep -oP 'Dropped: \K[0-9]+' "$STATS_FILE" | tail -1)
TRUNCATED_COUNT=$(grep -oP 'Truncated: \K[0-9]+' "$STATS_FILE" | tail -1)

echo "  vasn_tap RX: ${RX_COUNT:-0} TX: ${TX_COUNT:-0} Truncated: ${TRUNCATED_COUNT:-0}"
echo "  Packets captured in ns_dst: $CAPTURED"

LENGTHS_FILE=$(mktemp /tmp/vasn_tap_lengths_XXXXXX.txt)
if command -v python3 >/dev/null 2>&1; then
    python3 "$SCRIPT_DIR/pcap_packet_lengths.py" "$CAPTURE_FILE" > "$LENGTHS_FILE" 2>/dev/null || true
else
    python "$SCRIPT_DIR/pcap_packet_lengths.py" "$CAPTURE_FILE" > "$LENGTHS_FILE" 2>/dev/null || true
fi

MAX_LEN=0
HAS_EXACT=0
while read -r L; do
    [ -z "$L" ] && continue
    [ "$L" -gt "${MAX_LEN:-0}" ] && MAX_LEN=$L
    [ "$L" -eq "$TRUNCATE_LEN" ] && HAS_EXACT=1
done < "$LENGTHS_FILE"

rm -f "$CAPTURE_FILE" "$STATS_FILE" "$CONFIG_FILE" "$LENGTHS_FILE"
DURATION=$(($(date +%s) - START_TIME))

if [ "$MODE" = "no_truncate" ]; then
    if [ "${RX_COUNT:-0}" -gt 0 ] && [ "$CAPTURED" -gt 0 ] && [ "${MAX_LEN:-0}" -gt "$TRUNCATE_LEN" ]; then
        RESULT="PASS"
        echo "PASS: truncate ($MODE) - frames not truncated (max_len=$MAX_LEN)"
    else
        ERROR_MSG="Expected RX>0, captured>0, and at least one frame >${TRUNCATE_LEN}B; got RX=${RX_COUNT:-0} captured=$CAPTURED max_len=${MAX_LEN:-0}"
        echo "FAIL: truncate ($MODE) - $ERROR_MSG"
    fi
else
    if [ "${RX_COUNT:-0}" -gt 0 ] && [ "${TX_COUNT:-0}" -gt 0 ] && [ "$CAPTURED" -gt 0 ] && \
       [ "${MAX_LEN:-0}" -le "$TRUNCATE_LEN" ] && [ "$HAS_EXACT" -eq 1 ]; then
        RESULT="PASS"
        echo "PASS: truncate ($MODE) - all frames <= ${TRUNCATE_LEN}B, at least one exactly ${TRUNCATE_LEN}B"
    else
        ERROR_MSG="Expected RX>0 TX>0 captured>0, all lengths <=${TRUNCATE_LEN} and one ==${TRUNCATE_LEN}; got RX=${RX_COUNT:-0} TX=${TX_COUNT:-0} captured=$CAPTURED max_len=${MAX_LEN:-0} has_exact_128=$HAS_EXACT"
        echo "FAIL: truncate ($MODE) - $ERROR_MSG"
    fi
fi

NOTE_TEXT="Truncation test: ping -s $PING_PAYLOAD (frames >${TRUNCATE_LEN}B). When enabled, captured lengths must be <=${TRUNCATE_LEN} with at least one eq ${TRUNCATE_LEN}."

JSON=$(build_result_json \
    "test_name"         "Truncation ($MODE)" \
    "description"       "Verify packet truncation to ${TRUNCATE_LEN}B when enabled" \
    "result"            "$RESULT" \
    "mode"              "$MODE" \
    "workers"           "$WORKERS" \
    "input_iface"       "veth_src_host" \
    "output_iface"      "veth_dst_host" \
    "traffic_type"      "ICMP ping -s $PING_PAYLOAD" \
    "traffic_count"     "$NUM_PINGS" \
    "rx_packets"        "${RX_COUNT:-0}" \
    "tx_packets"        "${TX_COUNT:-0}" \
    "dropped_packets"   "${DROP_COUNT:-0}" \
    "captured_at_dst"   "$CAPTURED" \
    "duration_sec"      "$DURATION" \
    "error_msg"         "$ERROR_MSG" \
    "note"              "$NOTE_TEXT")
write_result "$JSON" "truncate_${MODE}"

[ "$RESULT" = "PASS" ]
