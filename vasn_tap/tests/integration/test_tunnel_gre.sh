#!/bin/bash
#
# vasn_tap integration test - Tunnel GRE
# Config: filter allow all + tunnel type GRE to 192.168.201.1 (ns_dst peer).
# Expect: vasn_tap starts, receives pings, reports "Tunnel (GRE): N packets sent" with N > 0.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VASN_TAP="$PROJECT_DIR/vasn_tap"
NUM_PINGS=20
WORKERS=2
TIMEOUT=15
START_TIME=$(date +%s)
CAPTURED=0

source "$SCRIPT_DIR/test_helpers.sh"

echo "=== Test: tunnel_gre ==="

RESULT="FAIL"
ERROR_MSG=""
RX_COUNT=0
TUNNEL_PACKETS=0

if [ ! -x "$VASN_TAP" ]; then
    ERROR_MSG="vasn_tap binary not found at $VASN_TAP"
    echo "FAIL: $ERROR_MSG"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Tunnel GRE" \
        "description"      "GRE tunnel encap to 192.168.201.1 (ns_dst); expect Tunnel (GRE) packets sent > 0" \
        "result"            "$RESULT" \
        "mode"              "afpacket" \
        "workers"           "$WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
        "traffic_type"      "ICMP ping" \
        "traffic_count"     "$NUM_PINGS" \
        "rx_packets"        "0" \
        "tx_packets"        "0" \
        "tunnel_packets"    "0" \
        "duration_sec"      "$DURATION" \
        "error_msg"         "$ERROR_MSG")
    write_result "$JSON" "tunnel_gre"
    exit 1
fi

if ! ip netns list | grep -q ns_src; then
    ERROR_MSG="ns_src namespace not found. Run setup_namespaces.sh first."
    echo "FAIL: $ERROR_MSG"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Tunnel GRE" \
        "description"      "GRE tunnel encap to 192.168.201.1 (ns_dst); expect Tunnel (GRE) packets sent > 0" \
        "result"            "$RESULT" \
        "mode"              "afpacket" \
        "workers"           "$WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
        "traffic_type"      "ICMP ping" \
        "traffic_count"     "$NUM_PINGS" \
        "rx_packets"        "0" \
        "tx_packets"        "0" \
        "tunnel_packets"    "0" \
        "duration_sec"      "$DURATION" \
        "error_msg"         "$ERROR_MSG")
    write_result "$JSON" "tunnel_gre"
    exit 1
fi

CONFIG_FILE=$(mktemp /tmp/vasn_tap_tunnel_XXXXXX.yaml)
cat > "$CONFIG_FILE" << 'YAML'
filter:
  default_action: allow
  rules: []
tunnel:
  type: gre
  remote_ip: 192.168.201.1
  key: 1000
YAML

# Prime ARP cache for tunnel remote (veth peer) so tunnel_init can resolve MAC
ping -c 1 -W 2 -I veth_dst_host 192.168.201.1 > /dev/null 2>&1 || true
sleep 0.5

# Capture GRE (proto 47) packets in ns_dst to verify encapsulated frames arrived
CAPTURE_FILE=$(mktemp /tmp/vasn_tap_tunnel_XXXXXX.pcap)
ip netns exec ns_dst timeout $TIMEOUT tcpdump -i veth_dst_ns -c 50 proto 47 -w "$CAPTURE_FILE" 2>/dev/null &
TCPDUMP_PID=$!
sleep 0.5

STATS_FILE=$(mktemp /tmp/vasn_tap_stats_XXXXXX.txt)
$VASN_TAP -m afpacket -i veth_src_host -o veth_dst_host -w $WORKERS -s -c "$CONFIG_FILE" > "$STATS_FILE" 2>&1 &
VASN_PID=$!
sleep 1

if ! kill -0 $VASN_PID 2>/dev/null; then
    ERROR_MSG="vasn_tap failed to start with GRE tunnel config"
    echo "FAIL: $ERROR_MSG"
    cat "$STATS_FILE"
    wait $TCPDUMP_PID 2>/dev/null || true
    rm -f "$CONFIG_FILE" "$STATS_FILE" "$CAPTURE_FILE"
    DURATION=$(($(date +%s) - START_TIME))
    JSON=$(build_result_json \
        "test_name"         "Tunnel GRE" \
        "description"      "GRE tunnel encap to 192.168.201.1 (ns_dst); expect Tunnel (GRE) packets sent > 0" \
        "result"            "$RESULT" \
        "mode"              "afpacket" \
        "workers"           "$WORKERS" \
        "input_iface"       "veth_src_host" \
        "output_iface"      "veth_dst_host" \
        "traffic_type"      "ICMP ping" \
        "traffic_count"     "$NUM_PINGS" \
        "rx_packets"        "0" \
        "tx_packets"        "0" \
        "tunnel_packets"    "0" \
        "captured_at_dst"   "0" \
        "duration_sec"      "$DURATION" \
        "error_msg"         "$ERROR_MSG")
    write_result "$JSON" "tunnel_gre"
    exit 1
fi

echo "  Sending $NUM_PINGS pings from ns_src..."
ip netns exec ns_src ping -c $NUM_PINGS -i 0.1 -W 1 192.168.200.2 > /dev/null 2>&1 || true
sleep 1

kill -INT $VASN_PID 2>/dev/null || true
wait $VASN_PID 2>/dev/null || true
wait $TCPDUMP_PID 2>/dev/null || true

RX_COUNT=$(grep -oP 'RX: \K[0-9]+' "$STATS_FILE" | tail -1)
TUNNEL_PACKETS=$(grep -oP 'Tunnel \(GRE\): \K[0-9]+' "$STATS_FILE" | tail -1)
CAPTURED=$(tcpdump -r "$CAPTURE_FILE" 2>/dev/null | wc -l)
echo "  RX=${RX_COUNT:-0}, Tunnel (GRE) packets sent=${TUNNEL_PACKETS:-0}, captured at ns_dst=${CAPTURED:-0}"

rm -f "$CONFIG_FILE" "$STATS_FILE" "$CAPTURE_FILE"
DURATION=$(($(date +%s) - START_TIME))

if [ "${RX_COUNT:-0}" -gt 0 ] && [ "${TUNNEL_PACKETS:-0}" -gt 0 ]; then
    RESULT="PASS"
    echo "PASS: tunnel_gre"
else
    ERROR_MSG="Expected RX>0 and Tunnel (GRE) packets>0; got RX=${RX_COUNT:-0}, tunnel_packets=${TUNNEL_PACKETS:-0}"
    echo "FAIL: tunnel_gre - $ERROR_MSG"
fi

JSON=$(build_result_json \
    "test_name"         "Tunnel GRE" \
    "description"      "GRE tunnel encap to 192.168.201.1 (ns_dst); expect Tunnel (GRE) packets sent > 0" \
    "result"            "$RESULT" \
    "mode"              "afpacket" \
    "workers"           "$WORKERS" \
    "input_iface"       "veth_src_host" \
    "output_iface"      "veth_dst_host" \
    "traffic_type"      "ICMP ping" \
    "traffic_count"     "$NUM_PINGS" \
    "rx_packets"        "${RX_COUNT:-0}" \
    "tx_packets"        "${TUNNEL_PACKETS:-0}" \
    "tunnel_packets"    "${TUNNEL_PACKETS:-0}" \
    "captured_at_dst"   "${CAPTURED:-0}" \
    "duration_sec"      "$DURATION" \
    "error_msg"         "$ERROR_MSG")
write_result "$JSON" "tunnel_gre"

[ "$RESULT" = "PASS" ]
