#!/bin/bash
#
# vasn_tap integration test runner - Suite: basic | filter | tunnel | all
# Usage: sudo ./tests/integration/run_integ.sh [basic|filter|tunnel|truncate|all]
#
# basic: 8 tests (basic_forward, drop_mode, graceful_shutdown x2 modes, multiworker, fanout)
# filter: 10 tests (drop_all x2, allow_all, allow_icmp_rule, drop_icmp_rule, ip_cidr x2 modes each)
# tunnel: 2 tests (tunnel_gre, tunnel_vxlan)
# truncate: 3 tests (truncate afpacket, ebpf, no_truncate)
# all: 23 tests (basic 8 + filter 10 + tunnel 2 + truncate 3)
#
# Reports: tests/integration/reports/test_report_*.html
#

set -o pipefail

SUITE="${1:-all}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT_DIR="$SCRIPT_DIR/reports"
SUITE_START=$(date +%s)

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Integration tests require root privileges"
    echo "Usage: sudo $0 [basic|filter|tunnel|truncate|all]"
    exit 1
fi

if [ ! -x "$PROJECT_DIR/vasn_tap" ]; then
    echo "Error: vasn_tap binary not found. Run 'make' first."
    exit 1
fi

case "$SUITE" in
    basic|filter|tunnel|truncate|all) ;;
    *)
        echo "Error: Invalid suite. Use: basic, filter, tunnel, truncate, or all"
        echo "Usage: sudo $0 [basic|filter|tunnel|truncate|all]"
        exit 1
        ;;
esac

export RESULT_DIR
RESULT_DIR=$(mktemp -d /tmp/vasn_tap_results_XXXXXX)

echo "============================================"
echo "  vasn_tap Integration Test Suite: $SUITE"
echo "============================================"
echo "  Results dir: $RESULT_DIR"
echo ""

echo ">>> Setting up test environment..."
bash "$SCRIPT_DIR/setup_namespaces.sh"
echo ""

PASS=0
FAIL=0

run_one() {
    if bash "$SCRIPT_DIR/$1" ${2:+"$2"}; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
    echo ""
    sleep 1
}

if [ "$SUITE" = "basic" ] || [ "$SUITE" = "all" ]; then
    for mode in afpacket ebpf; do
        echo "========== Mode: $mode =========="
        echo ""
        for test in test_basic_forward test_drop_mode test_graceful_shutdown; do
            echo ">>> Running: $test ($mode)"
            run_one "${test}.sh" "$mode"
        done
        if [ "$SUITE" = "all" ]; then
            ft="test_filter_${mode}.sh"
            if [ -f "$SCRIPT_DIR/$ft" ]; then
                echo ">>> Running: $ft"
                run_one "$ft"
            fi
            echo ">>> Running: test_filter_allow_all.sh $mode"
            run_one "test_filter_allow_all.sh" "$mode"
            echo ">>> Running: test_filter_allow_icmp_rule.sh $mode"
            run_one "test_filter_allow_icmp_rule.sh" "$mode"
            echo ">>> Running: test_filter_drop_icmp_rule.sh $mode"
            run_one "test_filter_drop_icmp_rule.sh" "$mode"
            echo ">>> Running: test_filter_ip_cidr.sh $mode"
            run_one "test_filter_ip_cidr.sh" "$mode"
        fi
    done
    echo "========== AF_PACKET-only tests =========="
    echo ""
    echo ">>> Running: test_multiworker (afpacket only)"
    run_one "test_multiworker.sh"
    echo ">>> Running: test_fanout_distribution (afpacket only)"
    run_one "test_fanout_distribution.sh"
fi

if [ "$SUITE" = "filter" ]; then
    echo "========== Filter tests =========="
    echo ""
    echo ">>> Running: test_filter_afpacket.sh"
    run_one "test_filter_afpacket.sh"
    echo ">>> Running: test_filter_ebpf.sh"
    run_one "test_filter_ebpf.sh"
    for mode in afpacket ebpf; do
        echo ">>> Running: test_filter_allow_all.sh $mode"
        run_one "test_filter_allow_all.sh" "$mode"
        echo ">>> Running: test_filter_allow_icmp_rule.sh $mode"
        run_one "test_filter_allow_icmp_rule.sh" "$mode"
        echo ">>> Running: test_filter_drop_icmp_rule.sh $mode"
        run_one "test_filter_drop_icmp_rule.sh" "$mode"
        echo ">>> Running: test_filter_ip_cidr.sh $mode"
        run_one "test_filter_ip_cidr.sh" "$mode"
    done
fi

if [ "$SUITE" = "tunnel" ] || [ "$SUITE" = "all" ]; then
    echo "========== Tunnel tests =========="
    echo ""
    echo ">>> Running: test_tunnel_gre.sh"
    run_one "test_tunnel_gre.sh"
    echo ">>> Running: test_tunnel_vxlan.sh"
    run_one "test_tunnel_vxlan.sh"
fi

if [ "$SUITE" = "truncate" ] || [ "$SUITE" = "all" ]; then
    echo "========== Truncation tests =========="
    echo ""
    echo ">>> Running: test_truncate.sh afpacket"
    run_one "test_truncate.sh" "afpacket"
    echo ">>> Running: test_truncate.sh ebpf"
    run_one "test_truncate.sh" "ebpf"
    echo ">>> Running: test_truncate.sh no_truncate"
    run_one "test_truncate.sh" "no_truncate"
fi

echo ">>> Tearing down test environment..."
bash "$SCRIPT_DIR/teardown_namespaces.sh"
echo ""

SUITE_END=$(date +%s)
TOTAL_DURATION=$((SUITE_END - SUITE_START))

case "$SUITE" in
    basic)    REPORT_PATH="$REPORT_DIR/test_report_basic.html" ;;
    filter)   REPORT_PATH="$REPORT_DIR/test_report_filter.html" ;;
    tunnel)   REPORT_PATH="$REPORT_DIR/test_report_tunnel.html" ;;
    truncate) REPORT_PATH="$REPORT_DIR/test_report_truncate.html" ;;
    all)      REPORT_PATH="$REPORT_DIR/test_report.html" ;;
esac

mkdir -p "$REPORT_DIR"
echo ">>> Generating HTML report..."
bash "$SCRIPT_DIR/generate_report.sh" "$RESULT_DIR" "$REPORT_PATH" "$TOTAL_DURATION"
echo ""

rm -rf "$RESULT_DIR"

TOTAL=$((PASS + FAIL))
echo "============================================"
echo "  Results: $PASS/$TOTAL passed, $FAIL failed"
echo "  Duration: ${TOTAL_DURATION}s"
echo "  HTML Report: $REPORT_PATH"
echo "============================================"

if [ $FAIL -eq 0 ]; then
    echo "  ALL TESTS PASSED"
    exit 0
else
    echo "  SOME TESTS FAILED"
    exit 1
fi
