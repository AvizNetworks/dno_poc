#!/bin/bash
#
# vasn_tap integration test - Run all 10 integration tests
# Usage: sudo ./tests/integration/run_all.sh
#
# Wrapper that runs run_integ.sh all (produces test_report.html)
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/run_integ.sh" all
