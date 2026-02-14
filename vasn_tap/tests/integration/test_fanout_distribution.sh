#!/bin/bash
#
# vasn_tap integration test - AF_PACKET fanout distribution verification
#
# Verifies that PACKET_FANOUT_HASH actually distributes packets across
# multiple worker sockets by:
#   1. Running iperf3 with multiple parallel TCP streams (distinct 5-tuples)
#   2. Parsing vasn_tap's per-worker stats output to check each worker's RX count
#
# This test is AF_PACKET-only (fanout is an AF_PACKET kernel feature).
#
# Requirements:
#   - iperf3 must be installed
#   - Test namespaces must be set up (setup_namespaces.sh)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VASN_TAP="$PROJECT_DIR/vasn_tap"
NUM_WORKERS="${NUM_WORKERS:-4}"
NUM_FLOWS="${NUM_FLOWS:-8}"
IPERF_DURATION=5
IPERF_RATE="${IPERF_RATE:-10M}"   # Per-stream bandwidth limit (e.g. 10M = 10 Mbps per stream)
START_TIME=$(date +%s)

# Source helpers for JSON result writing
source "$SCRIPT_DIR/test_helpers.sh"

echo "=== Test: fanout_distribution ==="
echo "  Workers: $NUM_WORKERS, Flows: $NUM_FLOWS, Rate: ${IPERF_RATE}/stream, Duration: ${IPERF_DURATION}s"

RESULT="FAIL"
ERROR_MSG=""
WORKERS_WITH_TRAFFIC=0
TOTAL_RX=0
PER_WORKER_DETAIL=""

# --- Pre-flight: check iperf3 ---
if ! command -v iperf3 &>/dev/null; then
    echo "  SKIP: iperf3 not found (install with: apt-get install iperf3)"
    RESULT="SKIP"
    ERROR_MSG="iperf3 not installed"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Fanout Distribution" \
        "description"       "Verify PACKET_FANOUT_HASH distributes traffic across $NUM_WORKERS worker sockets using $NUM_FLOWS parallel TCP flows" \
        "result"            "$RESULT" \
        "mode"              "afpacket" \
        "workers"           "$NUM_WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
        "traffic_type"      "iperf3 TCP ($NUM_FLOWS streams x ${IPERF_RATE}/stream)" \
        "traffic_count"     "$NUM_FLOWS" \
        "traffic_src"       "ns_src (192.168.200.1)" \
        "traffic_dst"       "host (192.168.200.2)" \
        "rx_packets"        "0" \
        "tx_packets"        "0" \
        "dropped_packets"   "0" \
        "captured_at_dst"   "0" \
        "duration_sec"      "$DURATION" \
        "error_msg"         "$ERROR_MSG" \
        "note"              "Test skipped: iperf3 is required but not installed.")
    write_result "$JSON" "fanout_distribution"
    # Exit 0 so the suite doesn't count a skip as a failure
    exit 0
fi

# --- Cleanup function ---
cleanup() {
    # Kill vasn_tap if still running
    if [ -n "$VASN_PID" ] && kill -0 "$VASN_PID" 2>/dev/null; then
        kill -INT "$VASN_PID" 2>/dev/null || true
        wait "$VASN_PID" 2>/dev/null || true
    fi
    # Kill iperf3 server if still running
    if [ -n "$IPERF_SERVER_PID" ] && kill -0 "$IPERF_SERVER_PID" 2>/dev/null; then
        kill "$IPERF_SERVER_PID" 2>/dev/null || true
        wait "$IPERF_SERVER_PID" 2>/dev/null || true
    fi
    # Also kill any stray iperf3 on our bind address
    pkill -f "iperf3 -s -B 192.168.200.2" 2>/dev/null || true
    # Clean up temp files
    rm -f "$STATS_FILE" "$IPERF_LOG"
}
trap cleanup EXIT

# --- Connectivity pre-check ---
echo "  Checking connectivity ns_src -> host (192.168.200.2)..."
if ! ip netns exec ns_src ping -c 1 -W 2 192.168.200.2 > /dev/null 2>&1; then
    echo "  FAIL: ns_src cannot reach 192.168.200.2 (namespaces not set up?)"
    ERROR_MSG="Connectivity check failed: ns_src cannot ping 192.168.200.2"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Fanout Distribution" \
        "description"       "Verify PACKET_FANOUT_HASH distributes traffic across $NUM_WORKERS worker sockets using $NUM_FLOWS parallel TCP flows" \
        "result"            "FAIL" \
        "mode"              "afpacket" \
        "workers"           "$NUM_WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
        "traffic_type"      "iperf3 TCP ($NUM_FLOWS streams x ${IPERF_RATE}/stream)" \
        "traffic_count"     "$NUM_FLOWS" \
        "traffic_src"       "ns_src (192.168.200.1)" \
        "traffic_dst"       "host (192.168.200.2)" \
        "rx_packets"        "0" \
        "tx_packets"        "0" \
        "dropped_packets"   "0" \
        "captured_at_dst"   "0" \
        "duration_sec"      "$DURATION" \
        "error_msg"         "$ERROR_MSG" \
        "note"              "Connectivity pre-check failed. Run setup_namespaces.sh first.")
    write_result "$JSON" "fanout_distribution"
    exit 1
fi
echo "  Connectivity OK"

# --- Start iperf3 server on the host (192.168.200.2) ---
IPERF_LOG=$(mktemp /tmp/iperf3_server_XXXXXX.log)
iperf3 -s -B 192.168.200.2 -D --logfile "$IPERF_LOG" 2>/dev/null
# iperf3 -D daemonizes; find its PID
sleep 0.5
IPERF_SERVER_PID=$(pgrep -f "iperf3 -s -B 192.168.200.2" | head -1)
if [ -z "$IPERF_SERVER_PID" ]; then
    echo "  FAIL: Could not start iperf3 server"
    ERROR_MSG="iperf3 server failed to start on 192.168.200.2"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Fanout Distribution" \
        "description"       "Verify PACKET_FANOUT_HASH distributes traffic across $NUM_WORKERS worker sockets using $NUM_FLOWS parallel TCP flows" \
        "result"            "FAIL" \
        "mode"              "afpacket" \
        "workers"           "$NUM_WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
        "traffic_type"      "iperf3 TCP ($NUM_FLOWS streams x ${IPERF_RATE}/stream)" \
        "traffic_count"     "$NUM_FLOWS" \
        "traffic_src"       "ns_src (192.168.200.1)" \
        "traffic_dst"       "host (192.168.200.2)" \
        "rx_packets"        "0" \
        "tx_packets"        "0" \
        "dropped_packets"   "0" \
        "captured_at_dst"   "0" \
        "duration_sec"      "$DURATION" \
        "error_msg"         "$ERROR_MSG" \
        "note"              "iperf3 server could not bind to 192.168.200.2:5201.")
    write_result "$JSON" "fanout_distribution"
    exit 1
fi
echo "  iperf3 server started (PID $IPERF_SERVER_PID) on 192.168.200.2:5201"

# --- Start vasn_tap ---
STATS_FILE=$(mktemp /tmp/vasn_tap_fanout_XXXXXX.txt)
$VASN_TAP -m afpacket -i veth_src_host -o veth_dst_host -w "$NUM_WORKERS" -v -s > "$STATS_FILE" 2>&1 &
VASN_PID=$!
sleep 1

if ! kill -0 "$VASN_PID" 2>/dev/null; then
    echo "  FAIL: vasn_tap failed to start"
    ERROR_MSG="vasn_tap exited immediately"
    cat "$STATS_FILE"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Fanout Distribution" \
        "description"       "Verify PACKET_FANOUT_HASH distributes traffic across $NUM_WORKERS worker sockets using $NUM_FLOWS parallel TCP flows" \
        "result"            "FAIL" \
        "mode"              "afpacket" \
        "workers"           "$NUM_WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
        "traffic_type"      "iperf3 TCP ($NUM_FLOWS streams x ${IPERF_RATE}/stream)" \
        "traffic_count"     "$NUM_FLOWS" \
        "traffic_src"       "ns_src (192.168.200.1)" \
        "traffic_dst"       "host (192.168.200.2)" \
        "rx_packets"        "0" \
        "tx_packets"        "0" \
        "dropped_packets"   "0" \
        "captured_at_dst"   "0" \
        "duration_sec"      "$DURATION" \
        "error_msg"         "$ERROR_MSG" \
        "note"              "vasn_tap could not start in afpacket mode with $NUM_WORKERS workers.")
    write_result "$JSON" "fanout_distribution"
    exit 1
fi
echo "  vasn_tap started (PID $VASN_PID) with $NUM_WORKERS workers"

# --- Generate multi-flow traffic with iperf3 ---
echo "  Running iperf3 client: $NUM_FLOWS parallel TCP streams at ${IPERF_RATE}/stream for ${IPERF_DURATION}s..."
IPERF_CLIENT_LOG=$(mktemp /tmp/iperf3_client_XXXXXX.log)
ip netns exec ns_src iperf3 -c 192.168.200.2 -P "$NUM_FLOWS" -b "$IPERF_RATE" -t "$IPERF_DURATION" --connect-timeout 3000 > "$IPERF_CLIENT_LOG" 2>&1
IPERF_EXIT=$?
if [ $IPERF_EXIT -ne 0 ]; then
    echo "  WARNING: iperf3 client exited with code $IPERF_EXIT"
    echo "  iperf3 client output:"
    head -20 "$IPERF_CLIENT_LOG" | sed 's/^/    /'
else
    echo "  iperf3 client completed successfully"
fi
rm -f "$IPERF_CLIENT_LOG"
sleep 1

# --- Stop vasn_tap and collect per-worker stats ---
kill -INT "$VASN_PID" 2>/dev/null || true
wait "$VASN_PID" 2>/dev/null || true
VASN_PID=""

# --- Parse aggregate stats ---
RX_COUNT=$(grep -oP 'RX: \K[0-9]+' "$STATS_FILE" | tail -1)
TX_COUNT=$(grep -oP 'TX: \K[0-9]+' "$STATS_FILE" | tail -1)
DROP_COUNT=$(grep -oP 'Dropped: \K[0-9]+' "$STATS_FILE" | tail -1)

echo ""
echo "  Aggregate stats: RX=${RX_COUNT:-0}, TX=${TX_COUNT:-0}, Dropped=${DROP_COUNT:-0}"

# --- Parse per-worker stats ---
# vasn_tap prints lines like: "  Worker 0: RX=1200 TX=1200 Dropped=0"
echo ""
echo "  Per-worker RX breakdown:"

WORKERS_WITH_TRAFFIC=0
TOTAL_RX=0
PER_WORKER_DETAIL=""

for wid in $(seq 0 $((NUM_WORKERS - 1))); do
    # Extract per-worker RX from the stats output
    WORKER_RX=$(grep -oP "Worker ${wid}: RX=\K[0-9]+" "$STATS_FILE" | tail -1)
    WORKER_RX=${WORKER_RX:-0}

    WORKER_TX=$(grep -oP "Worker ${wid}: .*TX=\K[0-9]+" "$STATS_FILE" | tail -1)
    WORKER_TX=${WORKER_TX:-0}

    echo "    Worker $wid: RX=$WORKER_RX TX=$WORKER_TX"

    TOTAL_RX=$((TOTAL_RX + WORKER_RX))
    if [ "$WORKER_RX" -gt 0 ]; then
        WORKERS_WITH_TRAFFIC=$((WORKERS_WITH_TRAFFIC + 1))
    fi

    if [ -n "$PER_WORKER_DETAIL" ]; then
        PER_WORKER_DETAIL="$PER_WORKER_DETAIL, "
    fi
    PER_WORKER_DETAIL="${PER_WORKER_DETAIL}W${wid}:RX=${WORKER_RX}"
done

echo ""
echo "  Total per-worker RX: $TOTAL_RX"
echo "  Workers with traffic: $WORKERS_WITH_TRAFFIC / $NUM_WORKERS"

# --- Evaluate pass/fail ---
# Pass criteria:
#   1. Total RX > 0 (packets were captured)
#   2. At least 2 workers have RX > 0 (proves fanout distribution)
if [ "$TOTAL_RX" -le 0 ]; then
    ERROR_MSG="No packets captured (total RX = $TOTAL_RX). Per-worker: [$PER_WORKER_DETAIL]"
    echo "  FAIL: $ERROR_MSG"
elif [ "$WORKERS_WITH_TRAFFIC" -lt 2 ]; then
    ERROR_MSG="Only $WORKERS_WITH_TRAFFIC worker(s) received traffic (need >=2 to prove distribution). Per-worker: [$PER_WORKER_DETAIL]"
    echo "  FAIL: $ERROR_MSG"
else
    RESULT="PASS"
    echo "  PASS: $WORKERS_WITH_TRAFFIC/$NUM_WORKERS workers received traffic (total RX: $TOTAL_RX)"
fi

# --- Write JSON result ---
DURATION=$(($(date +%s) - START_TIME))

NOTE="Fanout test sends $NUM_FLOWS parallel TCP streams at ${IPERF_RATE}/stream (iperf3 -P $NUM_FLOWS -b $IPERF_RATE) for ${IPERF_DURATION}s to create distinct 5-tuples."
NOTE="$NOTE PACKET_FANOUT_HASH distributes flows by hashing src/dst IP + ports + protocol."
NOTE="$NOTE Per-worker breakdown: [$PER_WORKER_DETAIL]."
NOTE="$NOTE $WORKERS_WITH_TRAFFIC of $NUM_WORKERS workers received packets."
NOTE="$NOTE A single flow (e.g. one ping) always goes to one worker -- multiple flows are needed to prove distribution."

JSON=$(build_result_json \
    "test_name"         "Fanout Distribution" \
    "description"       "Verify PACKET_FANOUT_HASH distributes $NUM_FLOWS TCP flows across $NUM_WORKERS AF_PACKET worker threads" \
    "result"            "$RESULT" \
    "mode"              "afpacket" \
    "workers"           "$NUM_WORKERS" \
    "input_iface"       "veth_src_host" \
    "output_iface"      "veth_dst_host" \
    "traffic_type"      "iperf3 TCP ($NUM_FLOWS streams x ${IPERF_RATE}/stream)" \
    "traffic_count"     "$NUM_FLOWS" \
    "traffic_src"       "ns_src (192.168.200.1)" \
    "traffic_dst"       "host (192.168.200.2)" \
    "rx_packets"        "${RX_COUNT:-0}" \
    "tx_packets"        "${TX_COUNT:-0}" \
    "dropped_packets"   "${DROP_COUNT:-0}" \
    "captured_at_dst"   "0" \
    "duration_sec"      "$DURATION" \
    "error_msg"         "$ERROR_MSG" \
    "note"              "$NOTE")
write_result "$JSON" "fanout_distribution"

echo ""
echo "=== Fanout distribution test: $RESULT ==="
[ "$RESULT" = "PASS" ]
