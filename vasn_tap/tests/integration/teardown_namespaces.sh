#!/bin/bash
#
# vasn_tap integration test - Cleanup network namespaces
# Deleting the namespace also removes the veth pairs automatically
#

set -e

echo "=== Tearing down test namespaces ==="

# Kill any lingering vasn_tap processes from tests
pkill -f "vasn_tap.*veth_src_host" 2>/dev/null || true
sleep 0.5

# Remove host-side addresses (veths get deleted with namespace)
ip link del veth_src_host 2>/dev/null || true
ip link del veth_dst_host 2>/dev/null || true

# Delete namespaces
ip netns del ns_src 2>/dev/null || true
ip netns del ns_dst 2>/dev/null || true

echo "=== Cleanup complete ==="
