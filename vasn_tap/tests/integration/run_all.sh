#!/bin/bash
#
# vasn_tap integration test - Run all integration tests
# Usage: sudo ./tests/integration/run_all.sh
#
# Runs each test in BOTH afpacket and ebpf modes, except multiworker
# which is afpacket-only (ebpf mode is single-threaded).
#
# Produces an HTML report at <project_dir>/test_report.html
#

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUITE_START=$(date +%s)

# Check for root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Integration tests require root privileges"
    echo "Usage: sudo $0"
    exit 1
fi

# Check binary exists
if [ ! -x "$PROJECT_DIR/vasn_tap" ]; then
    echo "Error: vasn_tap binary not found. Run 'make' first."
    exit 1
fi

# Create result directory for JSON output (exported so test scripts see it)
export RESULT_DIR
RESULT_DIR=$(mktemp -d /tmp/vasn_tap_results_XXXXXX)

echo "============================================"
echo "  vasn_tap Integration Test Suite"
echo "  Testing modes: afpacket + ebpf"
echo "============================================"
echo "  Results dir: $RESULT_DIR"
echo ""

# Setup
echo ">>> Setting up test environment..."
bash "$SCRIPT_DIR/setup_namespaces.sh"
echo ""

# Run tests
PASS=0
FAIL=0

# Tests that run in both modes
for mode in afpacket ebpf; do
    echo "========== Mode: $mode =========="
    echo ""

    for test in test_basic_forward test_drop_mode test_graceful_shutdown; do
        echo ">>> Running: $test ($mode)"
        if bash "$SCRIPT_DIR/${test}.sh" "$mode"; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
        fi
        echo ""
        sleep 1
    done
done

# Multi-worker is afpacket-only (ebpf is single-threaded by design)
echo "========== AF_PACKET-only tests =========="
echo ""
echo ">>> Running: test_multiworker (afpacket only)"
if bash "$SCRIPT_DIR/test_multiworker.sh"; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi
echo ""

echo ">>> Running: test_fanout_distribution (afpacket only)"
if bash "$SCRIPT_DIR/test_fanout_distribution.sh"; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi
echo ""

# Teardown
echo ">>> Tearing down test environment..."
bash "$SCRIPT_DIR/teardown_namespaces.sh"
echo ""

# Calculate total duration
SUITE_END=$(date +%s)
TOTAL_DURATION=$((SUITE_END - SUITE_START))

# Generate HTML report
REPORT_PATH="$PROJECT_DIR/test_report.html"
echo ">>> Generating HTML report..."
bash "$SCRIPT_DIR/generate_report.sh" "$RESULT_DIR" "$REPORT_PATH" "$TOTAL_DURATION"
echo ""

# Clean up result dir
rm -rf "$RESULT_DIR"

# Console report
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
