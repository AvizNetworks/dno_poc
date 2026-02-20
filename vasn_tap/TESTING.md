# vasn_tap Testing Guide

This document covers the testing strategy, all test suites, and how to add new tests to vasn_tap.

## Testing Overview

vasn_tap uses a **two-tier testing strategy**:

| Tier | Framework | Root? | What it tests |
|------|-----------|-------|---------------|
| **Unit tests** | [CMocka](https://cmocka.org/) (C) | No | Individual functions in isolation: CLI parsing, config validation, stats logic, output error paths |
| **Integration tests** | Bash + network namespaces | Yes | End-to-end packet flow: capture, forward, drop, shutdown, multi-worker, both modes |

## Quick Start

```bash
# Run unit tests (no root required)
make test

# Run integration tests (requires root; reports in tests/integration/reports/)
make test-basic   # 8 cases
make test-filter  # 10 filter cases
make test-tunnel  # 2 tunnel cases (GRE, VXLAN)
make test-all     # 20 cases (basic + filter + tunnel)
# Or: sudo tests/integration/run_integ.sh [basic|filter|tunnel|all]
```

---

## Unit Tests

### Building and Running

```bash
# Build and run all unit tests
make test

# Build a specific test (without running)
make build/test_cli

# Run a specific test binary directly
./build/test_cli
```

### Test Suites

#### test_cli.c -- CLI-lite Argument Parsing

Tests the `parse_args()` function in `src/cli.c` after moving runtime options into YAML.
Only `-c/-V/-h/--version` are accepted; deprecated runtime flags (`-i/-o/-m/-w/-v/-d/-s/-F/-M`) return `-1` with a migration hint.

| Test | What it verifies |
|------|-----------------|
| `test_parse_config_required` | Missing `-c` returns `-1` |
| `test_parse_config_path` | `-c /path` parses config path |
| `test_parse_validate_config` | `-V -c /path` sets validate mode |
| `test_parse_help` | `-h` returns `1` and sets `help = true` |
| `test_parse_version` | `--version` returns `1` and sets `show_version = true` |
| `test_parse_deprecated_input_flag` | `-i ...` returns `-1` |
| `test_parse_deprecated_mode_flag` | `-m ...` returns `-1` |
| `test_parse_null_args` | `args == NULL` returns `-1` |

#### test_stats.c -- Stats Accumulation and Reset (10 tests)

Tests the stats aggregation functions for both the AF_PACKET and eBPF backends.

| Test | What it verifies |
|------|-----------------|
| `test_afpacket_get_stats_single_worker` | Sums stats from 1 worker correctly |
| `test_afpacket_get_stats_multi_worker` | Sums stats across 4 workers: 100+200+300+400 = 1000 |
| `test_afpacket_get_stats_null_ctx` | `NULL` context returns zero stats, no crash |
| `test_afpacket_get_stats_null_total` | `NULL` total pointer does not crash |
| `test_afpacket_get_stats_null_workers` | `NULL` workers array with num_workers=4 returns zero |
| `test_afpacket_reset_stats` | Reset clears all per-worker atomic counters to 0 |
| `test_afpacket_reset_stats_null` | `NULL` context does not crash |
| `test_workers_get_stats_multi` | eBPF `workers_get_stats()` sums 3 workers |
| `test_workers_get_stats_null` | `NULL` context returns zero stats |
| `test_workers_reset_stats` | eBPF `workers_reset_stats()` clears all counters |

#### test_config.c -- Config Validation (5 tests)

Tests parameter validation in init functions.

#### test_config_filter.c -- YAML Runtime/Filter/Tunnel Parsing

Tests `config_load()` with runtime + filter + optional tunnel validation.

| Test | What it verifies |
|------|-----------------|
| `test_config_load_tunnel_gre` | YAML with GRE tunnel and runtime output loads correctly |
| `test_config_load_tunnel_vxlan` | YAML with VXLAN tunnel and runtime output loads correctly |
| `test_config_load_missing_runtime_input` | Missing `runtime.input_iface` fails validation |
| `test_config_load_missing_runtime_mode` | Missing `runtime.mode` fails validation |
| `test_config_load_tunnel_requires_runtime_output` | Tunnel enabled without `runtime.output_iface` fails validation |

(Other tests in this file cover general config load/free; see file for full list.)

| Test | What it verifies |
|------|-----------------|
| `test_afpacket_init_null_ctx` | `afpacket_init(NULL, &config)` returns `-EINVAL` |
| `test_afpacket_init_null_config` | `afpacket_init(&ctx, NULL)` returns `-EINVAL` |
| `test_workers_init_null_ctx` | `workers_init(NULL, NULL, &config)` returns `-EINVAL` |
| `test_workers_init_null_config` | `workers_init(&ctx, NULL, NULL)` returns `-EINVAL` |
| `test_capture_mode_values` | `CAPTURE_MODE_EBPF == 0`, `CAPTURE_MODE_AFPACKET == 1` |

#### test_output.c -- Output Module Error Paths (8 tests)

Tests the `output_open()`, `output_send()`, and `output_close()` functions.

| Test | What it verifies |
|------|-----------------|
| `test_output_send_negative_fd` | `output_send(-1, data, len)` returns `-EINVAL` |
| `test_output_send_null_data` | `output_send(fd, NULL, len)` returns `-EINVAL` |
| `test_output_send_zero_len` | `output_send(fd, data, 0)` returns `-EINVAL` |
| `test_output_open_null` | `output_open(NULL)` returns negative FD |
| `test_output_open_empty` | `output_open("")` returns negative FD |
| `test_output_open_nonexistent` | Non-existent interface name returns negative FD |
| `test_output_close_negative_fd` | `output_close(-1)` does not crash |
| `test_output_close_invalid_fd` | `output_close(9999)` does not crash |

### How to Add a New Unit Test

**Step 1:** Create a new test file in `tests/unit/`:

```c
/* tests/unit/test_mymodule.c */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <setjmp.h>
#include <cmocka.h>
#include <string.h>

/* Include the module header you're testing */
#include "../../src/mymodule.h"

static void test_myfunction_basic(void **state)
{
    (void)state;
    /* Arrange */
    int input = 42;

    /* Act */
    int result = myfunction(input);

    /* Assert */
    assert_int_equal(result, 84);
}

static void test_myfunction_null(void **state)
{
    (void)state;
    assert_int_equal(myfunction_with_ptr(NULL), -EINVAL);
}

int main(void)
{
    const struct CMUnitTest tests[] = {
        cmocka_unit_test(test_myfunction_basic),
        cmocka_unit_test(test_myfunction_null),
    };

    return cmocka_run_group_tests(tests, NULL, NULL);
}
```

**Step 2:** Add a build target in the `Makefile`:

```makefile
$(BUILD_DIR)/test_mymodule: $(TEST_UNIT_DIR)/test_mymodule.c $(BUILD_DIR)/mymodule.o
	@echo "Building test_mymodule..."
	$(CC) $(CFLAGS) -o $@ $< $(BUILD_DIR)/mymodule.o $(TEST_LDFLAGS)
```

**Step 3:** Add it to the `test` target's dependency list and `for` loop:

```makefile
test: ... $(BUILD_DIR)/test_mymodule
	@PASS=0; FAIL=0; \
	for t in ... $(BUILD_DIR)/test_mymodule; do \
```

**Step 4:** Build and run:

```bash
make test
```

### Design Note: Why parse_args() Was Extracted

Originally, CLI parsing lived inside `main()` in `main.c`. This made it impossible to unit-test argument parsing without running the entire program. By extracting it into `src/cli.c`:

- Each test can call `parse_args()` directly with a synthetic `argv[]`
- `optind = 1` is reset before each call so `getopt_long()` works across multiple tests
- `opterr = 0` suppresses getopt's error output during tests
- The function returns structured data (`struct cli_args`) instead of setting globals

---

## Integration Tests

### How to Run

```bash
# Run full suite (sets up namespaces, runs all 20 tests: 8 basic + 10 filter + 2 tunnel, generates HTML report)
make test-all
# Or: sudo tests/integration/run_integ.sh all
```

HTML reports are generated under **tests/integration/reports/** (test_report_basic.html, test_report_filter.html, test_report_tunnel.html, test_report.html depending on which suite was run).

### Test Topology

The integration tests create an isolated network topology using Linux network namespaces and veth pairs:

```
  [ns_src]                      [default ns]                      [ns_dst]
  192.168.200.1/24                                                     192.168.201.1/24

  +--------------+         +------------------+          +--------------+
  | veth_src_ns  |--veth-->| veth_src_host    |          | veth_dst_ns  |
  +--------------+         |                  |          +--------------+
                           |    vasn_tap      |                ^
                           |  -i veth_src_host|                |
                           |  -o veth_dst_host|          +-----+--------+
                           |                  |--veth-->| veth_dst_host |
                           +------------------+          +--------------+

  Traffic flow: ns_src --ping--> veth_src_host --vasn_tap--> veth_dst_host --> ns_dst
```

- `setup_namespaces.sh` creates this topology before tests
- `teardown_namespaces.sh` destroys it after tests

### Test Matrix

All tests except multiworker run in **both** capture modes:

| Test | AF_PACKET | eBPF | Description |
|------|:---------:|:----:|-------------|
| `test_basic_forward.sh` | Yes | Yes | Send 20 ICMP pings, verify they are captured and forwarded to destination |
| `test_drop_mode.sh` | Yes | Yes | Capture packets with no output interface, verify RX > 0, TX = 0, Dropped > 0 |
| `test_graceful_shutdown.sh` | Yes | Yes | Send SIGINT during active traffic, verify clean "Cleaning up" and "Done" messages |
| `test_multiworker.sh` | Yes | No* | Test with 1, 2, and 4 workers, verify RX/TX for each |
| `test_fanout_distribution.sh` | Yes | No* | Use iperf3 with 8 parallel TCP flows to verify PACKET_FANOUT_HASH distributes packets across 4 worker sockets. Exercises the TPACKET_V2 TX ring output path under sustained load (requires iperf3; skips gracefully if not installed) |
| `test_tunnel_gre.sh` | Yes | No | GRE tunnel: allow-all filter, tunnel to 192.168.201.1; ARP prime, pings; assert "Tunnel (GRE): N > 0"; tcpdump in ns_dst (proto 47) for received-at-destination |
| `test_tunnel_vxlan.sh` | Yes | No | VXLAN tunnel: allow-all filter, tunnel to 192.168.201.1; ARP prime, pings; assert "Tunnel (VXLAN): N > 0"; tcpdump in ns_dst (udp port 4789) for received-at-destination |

*eBPF mode is forced to 1 worker, so multi-worker, fanout, and tunnel testing only apply to AF_PACKET.

This gives **8 basic + 10 filter + 2 tunnel = 20** test results in the HTML reports (test_report_basic.html, test_report_filter.html, test_report_tunnel.html, and test_report.html for full suite).

### TX Ring Performance Notes

The AF_PACKET backend uses a TPACKET_V2 mmap'd TX ring for output. Integration tests exercise this path:

- **`test_basic_forward.sh` (afpacket)**: Validates that ICMP packets are written into the TX ring and flushed to the destination namespace
- **`test_fanout_distribution.sh`**: Stress-tests the TX ring under sustained iperf3 traffic (configurable via `IPERF_RATE` environment variable, default 10 Mbps per stream)
- **`test_multiworker.sh`**: Verifies that multiple workers, each with their own independent TX ring, can forward packets concurrently without interference

To manually stress-test with higher rates:

```bash
# Setup namespaces first
sudo bash tests/integration/setup_namespaces.sh

# Start vasn_tap
sudo ./vasn_tap -m afpacket -i veth_src_host -o veth_dst_host -w 4 -v -s

# In another terminal — adjust -b rate to find drop threshold
sudo ip netns exec ns_src iperf3 -c 192.168.200.2 -P 8 -b 100M -t 10
```

### Understanding Packet Counts

A common question is: "I sent 20 pings, why does RX show ~49?"

AF_PACKET in promiscuous mode captures **every raw frame** on the interface in both directions:
- 20 ICMP echo requests (ns_src -> host)
- 20 ICMP echo replies (host -> ns_src)
- ~9 ARP packets (MAC address resolution)
- = ~49 total raw frames

The HTML report includes explanatory notes on each test card clarifying this. In eBPF mode, the count depends on the TC hook direction and kernel behavior.

### HTML Report

After running the integration tests, HTML reports are generated under **tests/integration/reports/**:

- **test_report_basic.html** (make test-basic, 8 cases)
- **test_report_filter.html** (make test-filter, 10 cases)
- **test_report_tunnel.html** (make test-tunnel, 2 cases)
- **test_report.html** (make test-all, 20 cases)

Each report includes:

- **Summary bar**: Total tests, passed, failed, duration
- **Topology diagram**: ASCII art showing the test network layout
- **Per-test cards** (click to expand): Configuration, traffic sent, results (raw frames captured, frames forwarded, frames dropped, received at destination), duration, and explanatory notes. For tunnel tests, **Tunnel Packets Sent** is shown when `tunnel_packets` is present; **Received at Destination** is the encapsulated packet count captured in ns_dst (tcpdump).
- **Error details**: Automatically expanded for failed tests

### How to Add a New Integration Test

**Step 1:** Create a new script in `tests/integration/`:

```bash
#!/bin/bash
# tests/integration/test_mytest.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VASN_TAP="$PROJECT_DIR/vasn_tap"
MODE="${1:-afpacket}"    # Accept mode as argument
START_TIME=$(date +%s)

# Source helpers for JSON result writing
source "$SCRIPT_DIR/test_helpers.sh"

echo "=== Test: mytest (mode=$MODE) ==="

RESULT="FAIL"
ERROR_MSG=""

# ... your test logic here ...
# Start vasn_tap, send traffic, check results

DURATION=$(($(date +%s) - START_TIME))

# Determine pass/fail
if [ "${RX_COUNT:-0}" -gt 0 ]; then
    RESULT="PASS"
else
    ERROR_MSG="Expected RX > 0, got ${RX_COUNT:-0}"
fi

# Write JSON result for HTML report
JSON=$(build_result_json \
    "test_name"         "My Test ($MODE)" \
    "description"       "Description of what this test verifies" \
    "result"            "$RESULT" \
    "mode"              "$MODE" \
    "workers"           "2" \
    "input_iface"       "veth_src_host" \
    "output_iface"      "veth_dst_host" \
    "traffic_type"      "ICMP ping" \
    "traffic_count"     "20" \
    "traffic_src"       "ns_src (192.168.200.1)" \
    "traffic_dst"       "host (192.168.200.2)" \
    "rx_packets"        "${RX_COUNT:-0}" \
    "tx_packets"        "${TX_COUNT:-0}" \
    "dropped_packets"   "${DROP_COUNT:-0}" \
    "captured_at_dst"   "0" \
    "duration_sec"      "$DURATION" \
    "error_msg"         "$ERROR_MSG" \
    "note"              "Explanation of expected packet counts")
write_result "$JSON" "mytest_${MODE}"

[ "$RESULT" = "PASS" ]
```

**Step 2:** Add it to the appropriate suite in `run_integ.sh`:

- For a test that runs in both modes (like basic_forward): add it to the loop in the `basic`/`all` section (e.g. `for test in test_basic_forward test_drop_mode test_graceful_shutdown test_mytest`).
- For afpacket-only: add it in the "AF_PACKET-only tests" block.
- For a filter-only test: add it in the `filter` suite block.

**Step 3:** Make it executable and run:

```bash
chmod +x tests/integration/test_mytest.sh
sudo tests/integration/run_integ.sh all   # or basic / filter
```

### JSON Result Schema

Each test writes a JSON result file (when `RESULT_DIR` is set by `run_integ.sh`). The `generate_report.sh` script reads these to build the HTML report.

| Field | Type | Description |
|-------|------|-------------|
| `test_name` | string | Display name (e.g., "Basic Packet Forwarding (afpacket)") |
| `description` | string | Human-readable description |
| `result` | string | `"PASS"` or `"FAIL"` |
| `mode` | string | `"afpacket"` or `"ebpf"` |
| `workers` | number | Worker thread count |
| `input_iface` | string | Input interface name |
| `output_iface` | string | Output interface name (or "(none - drop mode)") |
| `traffic_type` | string | e.g., "ICMP ping" |
| `traffic_count` | number | Number of packets/pings sent |
| `traffic_src` | string | Source description |
| `traffic_dst` | string | Destination description |
| `rx_packets` | number | Raw frames captured by vasn_tap |
| `tx_packets` | number | Frames forwarded by vasn_tap |
| `dropped_packets` | number | Frames dropped (no output or error) |
| `captured_at_dst` | number | Packets verified by tcpdump at destination |
| `duration_sec` | number | Test duration in seconds |
| `error_msg` | string | Error details (empty on PASS) |
| `note` | string | Explanatory note about packet counts |

### Test Helper Functions

Defined in `tests/integration/test_helpers.sh`:

| Function | Purpose |
|----------|---------|
| `write_result "$json" "$filename"` | Write JSON result file to `RESULT_DIR` (no-op if unset) |
| `build_result_json "key" "val" ...` | Build a JSON string from key-value pairs |
| `json_escape "$string"` | Escape a string for safe JSON inclusion |

---

## File Reference

| File | Purpose |
|------|---------|
| `tests/unit/test_cli.c` | 18 tests for `parse_args()` |
| `tests/unit/test_stats.c` | 10 tests for stats accumulation/reset |
| `tests/unit/test_config.c` | 5 tests for init validation |
| `tests/unit/test_config_filter.c` | 10 tests for YAML load and tunnel (GRE/VXLAN) parsing |
| `tests/unit/test_output.c` | 8 tests for output module error paths |
| `tests/unit/test_common.h` | Shared CMocka includes |
| `tests/integration/run_integ.sh` | Suite runner: basic (8) \| filter (10) \| tunnel (2) \| all (20) |
| `tests/integration/run_all.sh` | Wrapper for `run_integ.sh all` |
| `tests/integration/reports/` | HTML reports (test_report_basic.html, test_report_filter.html, test_report_tunnel.html, test_report.html) |
| `tests/integration/setup_namespaces.sh` | Create test topology |
| `tests/integration/teardown_namespaces.sh` | Destroy test topology |
| `tests/integration/test_helpers.sh` | JSON result writing helpers |
| `tests/integration/generate_report.sh` | HTML report generator |
| `tests/integration/test_basic_forward.sh` | Packet forwarding test |
| `tests/integration/test_drop_mode.sh` | Drop mode test |
| `tests/integration/test_filter_afpacket.sh` | Filter (ACL) drop-all, afpacket mode |
| `tests/integration/test_filter_ebpf.sh` | Filter (ACL) drop-all, eBPF mode |
| `tests/integration/test_filter_allow_all.sh` | Filter allow-all (default allow, no rules); takes mode |
| `tests/integration/test_filter_allow_icmp_rule.sh` | Filter allow ICMP by rule; takes mode |
| `tests/integration/test_filter_drop_icmp_rule.sh` | Filter drop ICMP by rule; takes mode |
| `tests/integration/test_filter_ip_cidr.sh` | Filter IP/CIDR match (ip_src 192.168.200.0/24); takes mode |
| `tests/integration/test_multiworker.sh` | Multi-worker test (afpacket only) |
| `tests/integration/test_fanout_distribution.sh` | Fanout distribution test with iperf3 (afpacket only) |
| `tests/integration/test_graceful_shutdown.sh` | Graceful shutdown test |
| `tests/integration/test_tunnel_gre.sh` | GRE tunnel encap test (afpacket) |
| `tests/integration/test_tunnel_vxlan.sh` | VXLAN tunnel encap test (afpacket) |
