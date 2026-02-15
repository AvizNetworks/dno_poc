#!/bin/bash
#
# vasn_tap integration test runner - Suite: basic | filter | all
# Usage: sudo ./tests/integration/run_integ.sh [basic|filter|all]
#
# basic: 8 tests (basic_forward, drop_mode, graceful_shutdown x2 modes, multiworker, fanout)
# filter: 2 tests (test_filter_afpacket, test_filter_ebpf)
# all: 10 tests (one setup/teardown cycle)
#
# Reports: tests/integration/reports/test_report_basic.html, test_report_filter.html, test_report.html
#

set -o pipefail

SUITE="${1:-all}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT_DIR="$SCRIPT_DIR/reports"
SUITE_START=$(date +%s)

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Integration tests require root privileges"
    echo "Usage: sudo $0 [basic|filter|all]"
    exit 1
fi

if [ ! -x "$PROJECT_DIR/vasn_tap" ]; then
    echo "Error: vasn_tap binary not found. Run 'make' first."
    exit 1
fi

case "$SUITE" in
    basic|filter|all) ;;
    *)
        echo "Error: Invalid suite. Use: basic, filter, or all"
        echo "Usage: sudo $0 [basic|filter|all]"
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
fi

echo ">>> Tearing down test environment..."
bash "$SCRIPT_DIR/teardown_namespaces.sh"
echo ""

SUITE_END=$(date +%s)
TOTAL_DURATION=$((SUITE_END - SUITE_START))

case "$SUITE" in
    basic)  REPORT_PATH="$REPORT_DIR/test_report_basic.html" ;;
    filter) REPORT_PATH="$REPORT_DIR/test_report_filter.html" ;;
    all)    REPORT_PATH="$REPORT_DIR/test_report.html" ;;
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
