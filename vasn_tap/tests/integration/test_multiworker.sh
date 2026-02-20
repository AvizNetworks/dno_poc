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
TIMEOUT=15

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
    CAPTURED=0

    STATS_FILE=$(mktemp /tmp/vasn_tap_stats_XXXXXX.txt)
    CAPTURE_FILE=$(mktemp /tmp/vasn_tap_multiworker_XXXXXX.pcap)
    CONFIG_FILE=$(mktemp /tmp/vasn_tap_multiworker_XXXXXX.yaml)
    cat > "$CONFIG_FILE" <<EOF
runtime:
  input_iface: veth_src_host
  output_iface: veth_dst_host
  mode: afpacket
  workers: $workers
  stats: true
filter:
  default_action: allow
  rules: []
EOF

    # Start packet capture in ns_dst (verify packets actually reach destination)
    ip netns exec ns_dst timeout $TIMEOUT tcpdump -i veth_dst_ns -c $((NUM_PINGS * 2)) -w "$CAPTURE_FILE" 2>/dev/null &
    TCPDUMP_PID=$!
    sleep 0.5

    # Start vasn_tap
    $VASN_TAP -c "$CONFIG_FILE" > "$STATS_FILE" 2>&1 &
    VASN_PID=$!
    sleep 1

    if ! kill -0 $VASN_PID 2>/dev/null; then
        kill $TCPDUMP_PID 2>/dev/null || true
        SUB_ERROR="vasn_tap failed to start with $workers workers"
        echo "  FAIL: $SUB_ERROR"
        cat "$STATS_FILE"
        rm -f "$STATS_FILE" "$CAPTURE_FILE" "$CONFIG_FILE"
        FAIL=$((FAIL + 1))
        SUB_DURATION=$(($(date +%s) - SUB_START))
        JSON=$(build_result_json \
            "test_name"         "Multi-Worker ($workers workers)" \
            "description"       "AF_PACKET mode with $workers worker thread(s): send $NUM_PINGS ICMP pings and verify RX/TX and packets at ns_dst" \
            "result"            "$SUB_RESULT" \
            "mode"              "afpacket" \
            "workers"           "$workers" \
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
            "duration_sec"      "$SUB_DURATION" \
            "error_msg"         "$SUB_ERROR")
        write_result "$JSON" "multiworker_w${workers}"
        continue
    fi

    # Send traffic
    ip netns exec ns_src ping -c $NUM_PINGS -i 0.05 -W 1 192.168.200.2 > /dev/null 2>&1 || true
    sleep 1

    # Stop vasn_tap
    kill -INT $VASN_PID 2>/dev/null || true
    wait $VASN_PID 2>/dev/null || true

    # Wait for tcpdump to finish
    wait $TCPDUMP_PID 2>/dev/null || true

    # Check stats
    RX_COUNT=$(grep -oP 'RX: \K[0-9]+' "$STATS_FILE" | tail -1)
    TX_COUNT=$(grep -oP 'TX: \K[0-9]+' "$STATS_FILE" | tail -1)
    DROP_COUNT=$(grep -oP 'Dropped: \K[0-9]+' "$STATS_FILE" | tail -1)
    CAPTURED=$(tcpdump -r "$CAPTURE_FILE" 2>/dev/null | wc -l)

    echo "  Workers=$workers: RX=${RX_COUNT:-0}, TX=${TX_COUNT:-0}, captured_at_dst=$CAPTURED"

    rm -f "$STATS_FILE" "$CAPTURE_FILE" "$CONFIG_FILE"

    SUB_DURATION=$(($(date +%s) - SUB_START))

    if [ "${RX_COUNT:-0}" -gt 0 ] && [ "${TX_COUNT:-0}" -gt 0 ] && [ "${CAPTURED:-0}" -gt 0 ]; then
        SUB_RESULT="PASS"
        echo "  PASS"
        PASS=$((PASS + 1))
    else
        SUB_ERROR="Expected RX>0, TX>0 and captured_at_dst>0; got RX=${RX_COUNT:-0}, TX=${TX_COUNT:-0}, captured_at_dst=${CAPTURED:-0}"
        echo "  FAIL: $SUB_ERROR"
        FAIL=$((FAIL + 1))
    fi

    # Write JSON result for this sub-test
    JSON=$(build_result_json \
        "test_name"         "Multi-Worker ($workers workers)" \
        "description"       "AF_PACKET mode with $workers worker thread(s): send $NUM_PINGS ICMP pings and verify RX/TX and packets at ns_dst" \
        "result"            "$SUB_RESULT" \
        "mode"              "afpacket" \
        "workers"           "$workers" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
        "traffic_type"      "ICMP ping" \
        "traffic_count"     "$NUM_PINGS" \
        "traffic_src"       "ns_src (192.168.200.1)" \
        "traffic_dst"       "host (192.168.200.2)" \
        "rx_packets"        "${RX_COUNT:-0}" \
        "tx_packets"        "${TX_COUNT:-0}" \
        "dropped_packets"   "${DROP_COUNT:-0}" \
        "captured_at_dst"   "${CAPTURED:-0}" \
        "duration_sec"      "$SUB_DURATION" \
        "error_msg"         "$SUB_ERROR" \
        "note"              "RX counts raw frames on input (requests+replies+ARP). Pass requires packets captured in ns_dst (tcpdump on veth_dst_ns).")
    write_result "$JSON" "multiworker_w${workers}"

    sleep 0.5
done

echo ""
echo "=== Multiworker test: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ]
