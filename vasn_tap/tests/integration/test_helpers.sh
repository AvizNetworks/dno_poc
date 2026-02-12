#!/bin/bash
#
# vasn_tap integration test - Shared helper functions
# Sourced by each test script to provide JSON result writing
#

# write_result - Write a JSON result file to RESULT_DIR (if set)
#
# Usage: write_result <json_string>
#   or build it field-by-field and call write_result at the end
#
# Environment:
#   RESULT_DIR  - Directory to write JSON files to (optional, skip if unset)
#   RESULT_SEQ  - Auto-incremented sequence number for ordering
#
write_result() {
    local json="$1"
    local filename="$2"

    if [ -z "$RESULT_DIR" ]; then
        return 0
    fi

    # Use sequence number for ordering if available
    RESULT_SEQ=${RESULT_SEQ:-0}
    RESULT_SEQ=$((RESULT_SEQ + 1))
    export RESULT_SEQ

    local outfile="$RESULT_DIR/$(printf '%03d' $RESULT_SEQ)_${filename}.json"
    echo "$json" > "$outfile"
}

# json_escape - Escape a string for safe inclusion in JSON
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    echo -n "$s"
}

# build_result_json - Build a JSON result string from named parameters
#
# Usage:
#   build_result_json \
#       "test_name"         "Basic Forward" \
#       "description"       "Forward ICMP pings..." \
#       "result"            "PASS" \
#       "mode"              "afpacket" \
#       "workers"           "2" \
#       "input_iface"       "veth_src_host" \
#       "output_iface"      "veth_dst_host" \
#       "traffic_type"      "ICMP ping" \
#       "traffic_count"     "20" \
#       "traffic_src"       "ns_src (10.0.1.1)" \
#       "traffic_dst"       "host (10.0.1.2)" \
#       "rx_packets"        "40" \
#       "tx_packets"        "40" \
#       "dropped_packets"   "0" \
#       "captured_at_dst"   "40" \
#       "duration_sec"      "5" \
#       "error_msg"         ""
#
build_result_json() {
    local json="{"
    local first=true

    while [ $# -ge 2 ]; do
        local key="$1"
        local val="$2"
        shift 2

        if [ "$first" = true ]; then
            first=false
        else
            json+=","
        fi

        # Numeric fields - output without quotes
        case "$key" in
            workers|traffic_count|rx_packets|tx_packets|dropped_packets|captured_at_dst|duration_sec|exit_code|has_cleanup|has_done|has_final_stats)
                json+="\"$key\":${val:-0}"
                ;;
            *)
                local escaped
                escaped=$(json_escape "$val")
                json+="\"$key\":\"$escaped\""
                ;;
        esac
    done

    json+="}"
    echo "$json"
}
