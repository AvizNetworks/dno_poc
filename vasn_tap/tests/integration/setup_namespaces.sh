#!/bin/bash
#
# vasn_tap integration test - Setup network namespaces and veth pairs
#
# Topology:
#   [ns_src]                    [default ns]                    [ns_dst]
#   192.168.200.1/24                                             192.168.201.1/24
#   veth_src_ns <--veth pair--> veth_src_host                   veth_dst_ns
#                                     |                              ^
#                                vasn_tap                        veth pair
#                             -i veth_src_host                       |
#                             -o veth_dst_host --> veth_dst_host
#

set -e

echo "=== Setting up test namespaces ==="

# Cleanup any previous run
bash "$(dirname "$0")/teardown_namespaces.sh" 2>/dev/null || true

# Create namespaces
ip netns add ns_src
ip netns add ns_dst

# Create veth pairs
ip link add veth_src_ns type veth peer name veth_src_host
ip link add veth_dst_ns type veth peer name veth_dst_host

# Move endpoints into namespaces
ip link set veth_src_ns netns ns_src
ip link set veth_dst_ns netns ns_dst

# Configure ns_src
ip netns exec ns_src ip addr add 192.168.200.1/24 dev veth_src_ns
ip netns exec ns_src ip link set veth_src_ns up
ip netns exec ns_src ip link set lo up

# Configure ns_dst
ip netns exec ns_dst ip addr add 192.168.201.1/24 dev veth_dst_ns
ip netns exec ns_dst ip link set veth_dst_ns up
ip netns exec ns_dst ip link set lo up

# Configure host-side endpoints
ip addr add 192.168.200.2/24 dev veth_src_host
ip link set veth_src_host up
ip addr add 192.168.201.2/24 dev veth_dst_host
ip link set veth_dst_host up

# Disable reverse path filtering on test interfaces only (required for forwarding to work)
# Note: do NOT touch net.ipv4.conf.all.rp_filter — it can break management connectivity
sysctl -q -w net.ipv4.conf.veth_src_host.rp_filter=0
sysctl -q -w net.ipv4.conf.veth_dst_host.rp_filter=0

# Set promiscuous mode on host-side interfaces (needed for AF_PACKET capture)
ip link set veth_src_host promisc on
ip link set veth_dst_host promisc on

echo "=== Test namespaces ready ==="
echo "  ns_src:  veth_src_ns  (192.168.200.1/24)"
echo "  host:    veth_src_host (192.168.200.2/24)"
echo "  host:    veth_dst_host (192.168.201.2/24)"
echo "  ns_dst:  veth_dst_ns  (192.168.201.1/24)"
