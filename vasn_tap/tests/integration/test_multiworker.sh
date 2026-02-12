#!/bin/bash
#
# vasn_tap integration test - Multi-worker verification
# Tests that AF_PACKET mode works correctly with different worker counts
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VASN_TAP="$PROJECT_DIR/vasn_tap"
NUM_PINGS=30

# Source helpers for JSON result writing
source "$SCRIPT_DIR/test_helpers.sh"

echo "=== Test: multiworker ==="

PASS=0
FAIL=0

for workers in 1 2 4; do
    echo "--- Testing with $workers worker(s) ---"
    SUB_START=$(date +%s)
    SUB_RESULT="FAIL"
    SUB_ERROR=""
    RX_COUNT=0
    TX_COUNT=0

    STATS_FILE=$(mktemp /tmp/vasn_tap_stats_XXXXXX.txt)

    # Start vasn_tap
    $VASN_TAP -m afpacket -i veth_src_host -o veth_dst_host -w $workers -s > "$STATS_FILE" 2>&1 &
    VASN_PID=$!
    sleep 1

    if ! kill -0 $VASN_PID 2>/dev/null; then
        SUB_ERROR="vasn_tap failed to start with $workers workers"
        echo "  FAIL: $SUB_ERROR"
        cat "$STATS_FILE"
        rm -f "$STATS_FILE"
        FAIL=$((FAIL + 1))
        SUB_DURATION=$(($(date +%s) - SUB_START))
        JSON=$(build_result_json \
            "test_name"         "Multi-Worker ($workers workers)" \
            "description"       "AF_PACKET mode with $workers worker thread(s): send $NUM_PINGS ICMP pings and verify RX/TX across workers" \
            "result"            "$SUB_RESULT" \
            "mode"              "afpacket" \
            "workers"           "$workers" \
            "input_iface"       "veth_src_host" \
            "output_iface"      "veth_dst_host" \
            "traffic_type"      "ICMP ping" \
            "traffic_count"     "$NUM_PINGS" \
            "traffic_src"       "ns_src (10.0.1.1)" \
            "traffic_dst"       "host (10.0.1.2)" \
            "rx_packets"        "0" \
            "tx_packets"        "0" \
            "dropped_packets"   "0" \
            "captured_at_dst"   "0" \
            "duration_sec"      "$SUB_DURATION" \
            "error_msg"         "$SUB_ERROR")
        write_result "$JSON" "multiworker_w${workers}"
        continue
    fi

    # Send traffic
    ip netns exec ns_src ping -c $NUM_PINGS -i 0.05 -W 1 10.0.1.2 > /dev/null 2>&1 || true
    sleep 1

    # Stop
    kill -INT $VASN_PID 2>/dev/null || true
    wait $VASN_PID 2>/dev/null || true

    # Check stats
    RX_COUNT=$(grep -oP 'RX: \K[0-9]+' "$STATS_FILE" | tail -1)
    TX_COUNT=$(grep -oP 'TX: \K[0-9]+' "$STATS_FILE" | tail -1)
    DROP_COUNT=$(grep -oP 'Dropped: \K[0-9]+' "$STATS_FILE" | tail -1)

    echo "  Workers=$workers: RX=${RX_COUNT:-0}, TX=${TX_COUNT:-0}"

    rm -f "$STATS_FILE"

    SUB_DURATION=$(($(date +%s) - SUB_START))

    if [ "${RX_COUNT:-0}" -gt 0 ] && [ "${TX_COUNT:-0}" -gt 0 ]; then
        SUB_RESULT="PASS"
        echo "  PASS"
        PASS=$((PASS + 1))
    else
        SUB_ERROR="Expected RX>0 and TX>0, got RX=${RX_COUNT:-0}, TX=${TX_COUNT:-0}"
        echo "  FAIL"
        FAIL=$((FAIL + 1))
    fi

    # Write JSON result for this sub-test
    JSON=$(build_result_json \
        "test_name"         "Multi-Worker ($workers workers)" \
        "description"       "AF_PACKET mode with $workers worker thread(s): send $NUM_PINGS ICMP pings and verify RX/TX across workers" \
        "result"            "$SUB_RESULT" \
        "mode"              "afpacket" \
        "workers"           "$workers" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
        "traffic_type"      "ICMP ping" \
        "traffic_count"     "$NUM_PINGS" \
        "traffic_src"       "ns_src (10.0.1.1)" \
        "traffic_dst"       "host (10.0.1.2)" \
        "rx_packets"        "${RX_COUNT:-0}" \
        "tx_packets"        "${TX_COUNT:-0}" \
        "dropped_packets"   "${DROP_COUNT:-0}" \
        "captured_at_dst"   "0" \
        "duration_sec"      "$SUB_DURATION" \
        "error_msg"         "$SUB_ERROR" \
        "note"              "RX counts all raw frames seen by $workers worker(s) on the input interface (requests + replies + ARP). Sent $NUM_PINGS pings.")
    write_result "$JSON" "multiworker_w${workers}"

    sleep 0.5
done

echo ""
echo "=== Multiworker test: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ]
