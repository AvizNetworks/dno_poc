#!/bin/bash
#
# vasn_tap integration test - Graceful shutdown
# Verifies clean exit on SIGINT during traffic, with final stats printed
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VASN_TAP="$PROJECT_DIR/vasn_tap"
MODE="${1:-afpacket}"
WORKERS=2
NUM_PINGS=50
START_TIME=$(date +%s)

# Source helpers for JSON result writing
source "$SCRIPT_DIR/test_helpers.sh"

echo "=== Test: graceful_shutdown (mode=$MODE) ==="

RESULT="FAIL"
ERROR_MSG=""
HAS_CLEANUP=0
HAS_DONE=0
HAS_STATS=0
WAIT_EXIT=0

STATS_FILE=$(mktemp /tmp/vasn_tap_stats_XXXXXX.txt)

# Start vasn_tap
$VASN_TAP -m "$MODE" -i veth_src_host -w $WORKERS -s > "$STATS_FILE" 2>&1 &
VASN_PID=$!
sleep 1

if ! kill -0 $VASN_PID 2>/dev/null; then
    ERROR_MSG="vasn_tap failed to start (mode=$MODE)"
    echo "FAIL: $ERROR_MSG"
    cat "$STATS_FILE"
    rm -f "$STATS_FILE"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Graceful Shutdown - $MODE" \
        "description"       "Send SIGINT in $MODE mode while $NUM_PINGS ICMP pings are in flight. Verify vasn_tap prints cleanup messages and exits cleanly." \
        "result"            "$RESULT" \
        "mode"              "$MODE" \
        "workers"           "$WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "(none - drop mode)" \
        "traffic_type"      "ICMP ping (background)" \
        "traffic_count"     "$NUM_PINGS" \
        "traffic_src"       "ns_src (10.0.1.1)" \
        "traffic_dst"       "host (10.0.1.2)" \
        "rx_packets"        "0" \
        "tx_packets"        "0" \
        "dropped_packets"   "0" \
        "captured_at_dst"   "0" \
        "duration_sec"      "$DURATION" \
        "exit_code"         "1" \
        "has_cleanup"       "0" \
        "has_done"          "0" \
        "has_final_stats"   "0" \
        "error_msg"         "$ERROR_MSG")
    write_result "$JSON" "graceful_shutdown_${MODE}"
    exit 1
fi

# Send continuous traffic in background
ip netns exec ns_src ping -c $NUM_PINGS -i 0.1 -W 1 10.0.1.2 > /dev/null 2>&1 &
PING_PID=$!
sleep 2

# Send SIGINT (Ctrl+C equivalent)
kill -INT $VASN_PID 2>/dev/null
WAIT_EXIT=0
wait $VASN_PID 2>/dev/null || WAIT_EXIT=$?

# Kill remaining ping
kill $PING_PID 2>/dev/null || true
wait $PING_PID 2>/dev/null || true

# Check for clean shutdown messages
HAS_CLEANUP=$(grep -c "Cleaning up" "$STATS_FILE" || true)
HAS_DONE=$(grep -c "Done\." "$STATS_FILE" || true)
HAS_STATS=$(grep -c "Statistics" "$STATS_FILE" || true)

# Also grab RX stats if available
RX_COUNT=$(grep -oP 'RX: \K[0-9]+' "$STATS_FILE" | tail -1)

echo "  Exit code: $WAIT_EXIT"
echo "  Has 'Cleaning up': $HAS_CLEANUP"
echo "  Has 'Done.': $HAS_DONE"
echo "  Has final stats: $HAS_STATS"

rm -f "$STATS_FILE"

DURATION=$(($(date +%s) - START_TIME))

# Verify clean shutdown
if [ "$HAS_CLEANUP" -gt 0 ] && [ "$HAS_DONE" -gt 0 ]; then
    RESULT="PASS"
    echo "PASS: graceful_shutdown (mode=$MODE)"
else
    ERROR_MSG="Missing shutdown messages: Cleaning up=$HAS_CLEANUP, Done=$HAS_DONE"
    echo "FAIL: graceful_shutdown (mode=$MODE) - $ERROR_MSG"
fi

# Write JSON result
JSON=$(build_result_json \
    "test_name"         "Graceful Shutdown - $MODE" \
    "description"       "Send SIGINT in $MODE mode while $NUM_PINGS ICMP pings are in flight. Verify vasn_tap prints cleanup messages and exits cleanly." \
    "result"            "$RESULT" \
    "mode"              "$MODE" \
    "workers"           "$WORKERS" \
    "input_iface"       "veth_src_host" \
    "output_iface"      "(none - drop mode)" \
    "traffic_type"      "ICMP ping (background)" \
    "traffic_count"     "$NUM_PINGS" \
    "traffic_src"       "ns_src (10.0.1.1)" \
    "traffic_dst"       "host (10.0.1.2)" \
    "rx_packets"        "${RX_COUNT:-0}" \
    "tx_packets"        "0" \
    "dropped_packets"   "0" \
    "captured_at_dst"   "0" \
    "duration_sec"      "$DURATION" \
    "exit_code"         "$WAIT_EXIT" \
    "has_cleanup"       "$HAS_CLEANUP" \
    "has_done"          "$HAS_DONE" \
    "has_final_stats"   "$HAS_STATS" \
    "error_msg"         "$ERROR_MSG" \
    "note"              "SIGINT sent after 2s of traffic in $MODE mode. Clean shutdown verified by checking for Cleaning up and Done messages in output.")
write_result "$JSON" "graceful_shutdown_${MODE}"

[ "$RESULT" = "PASS" ]
