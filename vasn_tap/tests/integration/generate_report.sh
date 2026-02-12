#!/bin/bash
#
# vasn_tap integration test - HTML Report Generator
#
# Usage: ./generate_report.sh <result_dir> <output_html> [total_duration_sec]
#
# Reads JSON result files from <result_dir>, produces a self-contained
# HTML report at <output_html>.
#

set -e

RESULT_DIR="$1"
OUTPUT_HTML="$2"
TOTAL_DURATION="${3:-0}"

if [ -z "$RESULT_DIR" ] || [ -z "$OUTPUT_HTML" ]; then
    echo "Usage: $0 <result_dir> <output_html> [total_duration_sec]"
    exit 1
fi

# Count pass/fail
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TESTS=0

for f in "$RESULT_DIR"/*.json; do
    [ -f "$f" ] || continue
    result=$(grep -oP '"result"\s*:\s*"\K[^"]+' "$f")
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [ "$result" = "PASS" ]; then
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
done

# System info
REPORT_DATE=$(date '+%Y-%m-%d %H:%M:%S %Z')
KERNEL_VER=$(uname -r)
HOSTNAME_STR=$(hostname)
ARCH=$(uname -m)

# Helper: extract JSON field (simple grep-based, works for our flat JSON)
jval() {
    local file="$1" key="$2"
    grep -oP "\"${key}\"\s*:\s*\"\K[^\"]*" "$file" 2>/dev/null | head -1
}
jnum() {
    local file="$1" key="$2"
    grep -oP "\"${key}\"\s*:\s*\K[0-9]+" "$file" 2>/dev/null | head -1
}

# Determine overall status
if [ $TOTAL_FAIL -eq 0 ] && [ $TOTAL_TESTS -gt 0 ]; then
    OVERALL_STATUS="ALL PASSED"
    OVERALL_CLASS="pass"
else
    OVERALL_STATUS="$TOTAL_FAIL FAILED"
    OVERALL_CLASS="fail"
fi

# Start building HTML
cat > "$OUTPUT_HTML" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>vasn_tap Integration Test Report</title>
<style>
  :root {
    --bg: #f5f7fa;
    --card-bg: #ffffff;
    --text: #1a1a2e;
    --text-muted: #6b7280;
    --border: #e5e7eb;
    --pass-bg: #ecfdf5;
    --pass-text: #065f46;
    --pass-border: #6ee7b7;
    --pass-badge: #059669;
    --fail-bg: #fef2f2;
    --fail-text: #991b1b;
    --fail-border: #fca5a5;
    --fail-badge: #dc2626;
    --header-bg: #1e293b;
    --header-text: #f1f5f9;
    --accent: #3b82f6;
    --table-header: #f9fafb;
    --topology-bg: #1e293b;
    --topology-text: #a5f3fc;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.6;
  }
  .header {
    background: var(--header-bg);
    color: var(--header-text);
    padding: 24px 32px;
  }
  .header h1 { font-size: 24px; font-weight: 700; margin-bottom: 4px; }
  .header .subtitle { font-size: 14px; opacity: 0.7; }
  .header .meta {
    display: flex; flex-wrap: wrap; gap: 20px;
    margin-top: 12px; font-size: 13px; opacity: 0.85;
  }
  .header .meta span { display: flex; align-items: center; gap: 4px; }
  .container { max-width: 1100px; margin: 0 auto; padding: 24px 16px; }

  /* Summary bar */
  .summary {
    display: flex; gap: 16px; margin-bottom: 24px; flex-wrap: wrap;
  }
  .summary-card {
    flex: 1; min-width: 140px;
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 16px 20px;
    text-align: center;
  }
  .summary-card .label { font-size: 12px; text-transform: uppercase; color: var(--text-muted); letter-spacing: 0.5px; }
  .summary-card .value { font-size: 28px; font-weight: 700; margin-top: 4px; }
  .summary-card.total .value { color: var(--accent); }
  .summary-card.passed .value { color: var(--pass-badge); }
  .summary-card.failed .value { color: var(--fail-badge); }
  .summary-card.overall { border-width: 2px; }
  .summary-card.overall.pass { border-color: var(--pass-border); background: var(--pass-bg); }
  .summary-card.overall.fail { border-color: var(--fail-border); background: var(--fail-bg); }
  .summary-card.overall .value.pass { color: var(--pass-badge); }
  .summary-card.overall .value.fail { color: var(--fail-badge); }

  /* Topology */
  .topology {
    background: var(--topology-bg);
    border-radius: 10px;
    padding: 20px 24px;
    margin-bottom: 24px;
    overflow-x: auto;
  }
  .topology h3 { color: #94a3b8; font-size: 13px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 12px; }
  .topology pre {
    color: var(--topology-text);
    font-family: 'SF Mono', 'Fira Code', 'Cascadia Code', monospace;
    font-size: 13px;
    line-height: 1.5;
    white-space: pre;
  }

  /* Test cards */
  .test-card {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 10px;
    margin-bottom: 16px;
    overflow: hidden;
    transition: box-shadow 0.15s;
  }
  .test-card:hover { box-shadow: 0 4px 12px rgba(0,0,0,0.08); }
  .test-card.pass { border-left: 4px solid var(--pass-badge); }
  .test-card.fail { border-left: 4px solid var(--fail-badge); }

  .test-header {
    display: flex; justify-content: space-between; align-items: center;
    padding: 16px 20px;
    cursor: pointer;
  }
  .test-header h3 { font-size: 16px; font-weight: 600; }
  .test-header .desc { font-size: 13px; color: var(--text-muted); margin-top: 2px; }

  .badge {
    display: inline-block;
    padding: 4px 12px;
    border-radius: 20px;
    font-size: 12px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    white-space: nowrap;
  }
  .badge.pass { background: var(--pass-bg); color: var(--pass-badge); border: 1px solid var(--pass-border); }
  .badge.fail { background: var(--fail-bg); color: var(--fail-badge); border: 1px solid var(--fail-border); }

  .test-body { padding: 0 20px 20px; }
  .test-body .section-title {
    font-size: 11px; text-transform: uppercase; color: var(--text-muted);
    letter-spacing: 0.8px; margin: 16px 0 8px; font-weight: 600;
  }

  .detail-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 12px;
  }
  .detail-item {
    background: var(--table-header);
    border-radius: 8px;
    padding: 12px 16px;
  }
  .detail-item .label { font-size: 11px; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.5px; }
  .detail-item .val { font-size: 18px; font-weight: 600; margin-top: 2px; }
  .detail-item .val.highlight { color: var(--accent); }

  table.info-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 14px;
    margin-top: 4px;
  }
  table.info-table th {
    text-align: left;
    padding: 8px 12px;
    background: var(--table-header);
    color: var(--text-muted);
    font-weight: 600;
    font-size: 12px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    border-bottom: 1px solid var(--border);
  }
  table.info-table td {
    padding: 8px 12px;
    border-bottom: 1px solid var(--border);
  }

  .error-box {
    background: var(--fail-bg);
    border: 1px solid var(--fail-border);
    border-radius: 8px;
    padding: 12px 16px;
    margin-top: 12px;
    font-size: 13px;
    color: var(--fail-text);
  }
  .error-box .error-label { font-weight: 700; margin-bottom: 4px; }

  .note-box {
    background: #eff6ff;
    border: 1px solid #93c5fd;
    border-radius: 8px;
    padding: 12px 16px;
    margin-top: 12px;
    font-size: 13px;
    color: #1e40af;
    line-height: 1.5;
  }
  .note-box .note-label { font-weight: 700; margin-bottom: 4px; }

  .detail-item .sublabel {
    font-size: 10px;
    color: var(--text-muted);
    margin-top: 2px;
    font-weight: 400;
    line-height: 1.3;
  }

  .footer {
    text-align: center;
    padding: 20px;
    font-size: 12px;
    color: var(--text-muted);
  }

  /* Collapsible */
  .test-body { display: none; }
  .test-card.open .test-body { display: block; }
  .toggle-icon { transition: transform 0.2s; font-size: 14px; color: var(--text-muted); }
  .test-card.open .toggle-icon { transform: rotate(90deg); }
</style>
</head>
<body>
HTMLHEAD

# Write header section
cat >> "$OUTPUT_HTML" << HEADEREOF
<div class="header">
  <h1>vasn_tap Integration Test Report</h1>
  <div class="subtitle">Automated packet tap testing results</div>
  <div class="meta">
    <span>Date: $REPORT_DATE</span>
    <span>Host: $HOSTNAME_STR</span>
    <span>Kernel: $KERNEL_VER</span>
    <span>Arch: $ARCH</span>
  </div>
</div>
HEADEREOF

# Write summary bar
cat >> "$OUTPUT_HTML" << SUMMARYEOF
<div class="container">
  <div class="summary">
    <div class="summary-card total">
      <div class="label">Total Tests</div>
      <div class="value">$TOTAL_TESTS</div>
    </div>
    <div class="summary-card passed">
      <div class="label">Passed</div>
      <div class="value">$TOTAL_PASS</div>
    </div>
    <div class="summary-card failed">
      <div class="label">Failed</div>
      <div class="value">$TOTAL_FAIL</div>
    </div>
    <div class="summary-card">
      <div class="label">Duration</div>
      <div class="value">${TOTAL_DURATION}s</div>
    </div>
    <div class="summary-card overall $OVERALL_CLASS">
      <div class="label">Status</div>
      <div class="value $OVERALL_CLASS">$OVERALL_STATUS</div>
    </div>
  </div>
SUMMARYEOF

# Write topology diagram
cat >> "$OUTPUT_HTML" << 'TOPOEOF'
  <div class="topology">
    <h3>Test Topology</h3>
    <pre>
    [ns_src]                      [default ns]                      [ns_dst]
    10.0.1.1/24                                                     10.0.2.1/24

    +--------------+         +------------------+          +--------------+
    | veth_src_ns  |--veth--&gt;| veth_src_host    |          | veth_dst_ns  |
    +--------------+         |                  |          +--------------+
                             |    vasn_tap      |                ^
                             |  -i veth_src_host|                |
                             |  -o veth_dst_host|          +-----+--------+
                             |                  |--veth--&gt;| veth_dst_host |
                             +------------------+          +--------------+

    Traffic flow: ns_src --ping--&gt; veth_src_host --vasn_tap--&gt; veth_dst_host --&gt; ns_dst
    </pre>
  </div>
TOPOEOF

# Write each test card
for f in $(ls "$RESULT_DIR"/*.json 2>/dev/null | sort); do
    [ -f "$f" ] || continue

    test_name=$(jval "$f" "test_name")
    description=$(jval "$f" "description")
    result=$(jval "$f" "result")
    mode=$(jval "$f" "mode")
    workers=$(jnum "$f" "workers")
    input_iface=$(jval "$f" "input_iface")
    output_iface=$(jval "$f" "output_iface")
    traffic_type=$(jval "$f" "traffic_type")
    traffic_count=$(jnum "$f" "traffic_count")
    traffic_src=$(jval "$f" "traffic_src")
    traffic_dst=$(jval "$f" "traffic_dst")
    rx_packets=$(jnum "$f" "rx_packets")
    tx_packets=$(jnum "$f" "tx_packets")
    dropped_packets=$(jnum "$f" "dropped_packets")
    captured_at_dst=$(jnum "$f" "captured_at_dst")
    duration_sec=$(jnum "$f" "duration_sec")
    error_msg=$(jval "$f" "error_msg")

    # Determine card class
    if [ "$result" = "PASS" ]; then
        card_class="pass"
        badge_text="PASS"
    else
        card_class="fail"
        badge_text="FAIL"
    fi

    cat >> "$OUTPUT_HTML" << CARDEOF

  <div class="test-card $card_class" onclick="this.classList.toggle('open')">
    <div class="test-header">
      <div>
        <h3>$test_name</h3>
        <div class="desc">$description</div>
      </div>
      <div style="display:flex;align-items:center;gap:12px;">
        <span class="badge $card_class">$badge_text</span>
        <span class="toggle-icon">&#9654;</span>
      </div>
    </div>
    <div class="test-body">
      <div class="section-title">Configuration</div>
      <table class="info-table">
        <tr><th>Capture Mode</th><th>Workers</th><th>Input Interface</th><th>Output Interface</th></tr>
        <tr><td>${mode:-n/a}</td><td>${workers:-0}</td><td>${input_iface:-n/a}</td><td>${output_iface:-n/a}</td></tr>
      </table>

      <div class="section-title">Traffic Injected by Test</div>
      <table class="info-table">
        <tr><th>Type</th><th>Pings Sent</th><th>Source</th><th>Destination</th><th>Expected Raw Frames</th></tr>
        <tr><td>${traffic_type:-n/a}</td><td>${traffic_count:-0}</td><td>${traffic_src:-n/a}</td><td>${traffic_dst:-n/a}</td><td>~$((${traffic_count:-0} * 2 + 10)) (requests + replies + ARP)</td></tr>
      </table>

      <div class="section-title">Results</div>
      <div class="detail-grid">
        <div class="detail-item">
          <div class="label">Raw Frames Captured</div>
          <div class="val highlight">${rx_packets:-0}</div>
          <div class="sublabel">All frames on input iface (both directions + ARP)</div>
        </div>
        <div class="detail-item">
          <div class="label">Frames Forwarded</div>
          <div class="val highlight">${tx_packets:-0}</div>
          <div class="sublabel">Frames sent to output interface by vasn_tap</div>
        </div>
        <div class="detail-item">
          <div class="label">Frames Dropped</div>
          <div class="val">${dropped_packets:-0}</div>
          <div class="sublabel">Captured but not forwarded (no output or error)</div>
        </div>
        <div class="detail-item">
          <div class="label">Received at Destination</div>
          <div class="val">${captured_at_dst:-0}</div>
          <div class="sublabel">Packets verified by tcpdump in ns_dst</div>
        </div>
        <div class="detail-item">
          <div class="label">Duration</div>
          <div class="val">${duration_sec:-0}s</div>
        </div>
      </div>
CARDEOF

    # Note box (explanatory text about packet counts)
    note=$(jval "$f" "note")
    if [ -n "$note" ]; then
        cat >> "$OUTPUT_HTML" << NOTEEOF
      <div class="note-box">
        <div class="note-label">Why do the numbers differ from pings sent?</div>
        <div>$note</div>
      </div>
NOTEEOF
    fi

    # Error box (only if failed)
    if [ "$result" != "PASS" ] && [ -n "$error_msg" ]; then
        cat >> "$OUTPUT_HTML" << ERREOF
      <div class="error-box">
        <div class="error-label">Error Details</div>
        <div>$error_msg</div>
      </div>
ERREOF
    fi

    # Extra details for graceful_shutdown test
    has_cleanup=$(jnum "$f" "has_cleanup")
    has_done=$(jnum "$f" "has_done")
    has_final_stats=$(jnum "$f" "has_final_stats")
    exit_code=$(jnum "$f" "exit_code")

    if [ -n "$has_cleanup" ]; then
        cat >> "$OUTPUT_HTML" << SHUTEOF
      <div class="section-title">Shutdown Verification</div>
      <table class="info-table">
        <tr><th>Check</th><th>Result</th></tr>
        <tr><td>Exit code</td><td>${exit_code:-n/a}</td></tr>
        <tr><td>"Cleaning up..." message</td><td>$([ "${has_cleanup:-0}" -gt 0 ] && echo "Yes" || echo "No")</td></tr>
        <tr><td>"Done." message</td><td>$([ "${has_done:-0}" -gt 0 ] && echo "Yes" || echo "No")</td></tr>
        <tr><td>Final statistics printed</td><td>$([ "${has_final_stats:-0}" -gt 0 ] && echo "Yes" || echo "No")</td></tr>
      </table>
SHUTEOF
    fi

    echo "    </div>" >> "$OUTPUT_HTML"
    echo "  </div>" >> "$OUTPUT_HTML"

done

# Footer and close
cat >> "$OUTPUT_HTML" << 'FOOTEREOF'
</div>

<div class="footer">
  Generated by vasn_tap integration test suite
</div>

<script>
// Auto-expand failed tests
document.querySelectorAll('.test-card.fail').forEach(function(card) {
  card.classList.add('open');
});
</script>
</body>
</html>
FOOTEREOF

echo "HTML report generated: $OUTPUT_HTML"
