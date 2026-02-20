#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="vasn_tap"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_PATH_DEFAULT="/etc/vasn_tap/config.yaml"
BIN_PATH="/usr/local/bin/vasn_tap"

usage() {
  cat <<'EOF'
Usage:
  vasn_tapctl start
  vasn_tapctl stop
  vasn_tapctl restart
  vasn_tapctl status
  vasn_tapctl counters
  vasn_tapctl logs [journalctl_args]
  vasn_tapctl validate [config_path]
  vasn_tapctl apply <config_path>
EOF
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found; this first release supports systemd only." >&2
    exit 1
  fi
  if [[ ! -f "${UNIT_PATH}" ]]; then
    echo "Service unit not installed at ${UNIT_PATH}. Run install.sh first." >&2
    exit 1
  fi
}

require_binary() {
  if [[ ! -x "${BIN_PATH}" ]]; then
    echo "Binary not found at ${BIN_PATH}. Run install.sh first." >&2
    exit 1
  fi
}

validate_config() {
  local cfg_path="$1"
  if [[ ! -f "${cfg_path}" ]]; then
    echo "Config file not found: ${cfg_path}" >&2
    return 1
  fi
  require_binary
  "${BIN_PATH}" --validate-config -c "${cfg_path}"
}

get_runtime_field() {
  local cfg_path="$1"
  local field_name="$2"
  awk -v field_name="${field_name}" '
    BEGIN { in_runtime = 0 }
    /^[[:space:]]*runtime:[[:space:]]*$/ { in_runtime = 1; next }
    in_runtime && /^[^[:space:]]/ { in_runtime = 0 }
    in_runtime && $0 ~ ("^[[:space:]]*" field_name ":[[:space:]]*") {
      val = $0
      sub(("^[[:space:]]*" field_name ":[[:space:]]*"), "", val)
      sub(/[[:space:]]*#.*/, "", val)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      print val
      exit
    }
  ' "${cfg_path}"
}

show_counters() {
  require_systemd
  if ! command -v journalctl >/dev/null 2>&1; then
    echo "journalctl not found; cannot read counters from systemd journal." >&2
    exit 1
  fi

  # Prefer unprivileged journal access; fallback to sudo if output is empty.
  # -q suppresses "not seeing messages from other users" hints.
  local jlog
  jlog="$(journalctl -q -o cat -u "${SERVICE_NAME}" --no-pager 2>/dev/null || true)"
  if [[ -z "${jlog}" ]] && command -v sudo >/dev/null 2>&1; then
    jlog="$(sudo journalctl -q -o cat -u "${SERVICE_NAME}" --no-pager 2>/dev/null || true)"
  fi
  if [[ -z "${jlog}" ]]; then
    echo "No journal lines available for ${SERVICE_NAME}." >&2
    echo "Try: sudo vasn_tapctl counters" >&2
    echo "Or grant journal read access (adm/systemd-journal group)." >&2
    exit 1
  fi

  local input_iface output_iface
  if [[ -f "${CONFIG_PATH_DEFAULT}" ]]; then
    input_iface="$(get_runtime_field "${CONFIG_PATH_DEFAULT}" "input_iface" || true)"
    output_iface="$(get_runtime_field "${CONFIG_PATH_DEFAULT}" "output_iface" || true)"
  else
    input_iface=""
    output_iface=""
  fi

  if [[ -n "${input_iface}" ]]; then
    echo "Input interface: ${input_iface}"
  fi
  if [[ -n "${output_iface}" ]]; then
    echo "Output interface: ${output_iface}"
  else
    echo "Output interface: (drop mode)"
  fi

  printf '%s\n' "${jlog}" | awk '
    function finalize_block() {
      if (cur_rx != "" && cur_tx != "" && cur_dr != "") {
        last_rx = cur_rx
        last_tx = cur_tx
        last_dr = cur_dr
        last_tn = cur_tn
        last_filter = cur_filter
        have_block = 1
      }
    }

    /^--- Statistics \(/ {
      finalize_block()
      in_stats = 1
      in_filter = 0
      cur_rx = cur_tx = cur_dr = cur_tn = ""
      cur_filter = ""
      next
    }

    in_stats && /(^|[[:space:]])RX:/      { cur_rx = $0; next }
    in_stats && /(^|[[:space:]])TX:/      { cur_tx = $0; next }
    in_stats && /(^|[[:space:]])Dropped:/ { cur_dr = $0; next }
    in_stats && /(^|[[:space:]])Tunnel \(/ { cur_tn = $0; next }

    in_stats && /^--- Filter rules \(hits\) ---$/ {
      in_filter = 1
      cur_filter = ""
      next
    }
    in_stats && /^----------------------------$/ {
      if (in_filter) {
        in_filter = 0
      }
      next
    }
    in_stats && in_filter {
      cur_filter = cur_filter $0 "\n"
      next
    }

    END {
      finalize_block()
      if (!have_block) {
        print "RX: not found in journal"
        print "TX: not found in journal"
        print "Dropped: not found in journal"
        exit
      }

      print last_rx
      print last_tx
      print last_dr
      if (last_tn != "") print last_tn

      if (last_filter != "") {
        print "--- Filter rules (hits) ---"
        printf "%s", last_filter
        print "----------------------------"
      }
    }
  '
}

show_logs() {
  require_systemd
  if ! command -v journalctl >/dev/null 2>&1; then
    echo "journalctl not found; cannot read service logs." >&2
    exit 1
  fi

  # Default behavior: follow logs if no explicit journalctl args were provided.
  local args=("$@")
  if [[ ${#args[@]} -eq 0 ]]; then
    args=(-f)
  fi

  # Follow mode: probe first; if unprivileged view is empty, fallback to sudo -f.
  local is_follow=false
  for a in "${args[@]}"; do
    if [[ "${a}" == "-f" || "${a}" == "--follow" ]]; then
      is_follow=true
      break
    fi
  done

  if [[ "${is_follow}" == "true" ]]; then
    local probe
    probe="$(journalctl -q -o cat -u "${SERVICE_NAME}" --no-pager -n 1 2>/dev/null || true)"
    if [[ -n "${probe}" ]]; then
      journalctl -q -o cat -u "${SERVICE_NAME}" --no-pager "${args[@]}"
      return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
      sudo journalctl -q -o cat -u "${SERVICE_NAME}" --no-pager "${args[@]}"
      return 0
    fi
    echo "Unable to read logs for ${SERVICE_NAME}. Try: sudo vasn_tapctl logs" >&2
    exit 1
  fi

  # Non-follow mode: capture output; fallback to sudo when empty.
  local out
  out="$(journalctl -q -o cat -u "${SERVICE_NAME}" --no-pager "${args[@]}" 2>/dev/null || true)"
  if [[ -n "${out}" ]]; then
    printf '%s\n' "${out}"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    out="$(sudo journalctl -q -o cat -u "${SERVICE_NAME}" --no-pager "${args[@]}" 2>/dev/null || true)"
    if [[ -n "${out}" ]]; then
      printf '%s\n' "${out}"
      return 0
    fi
  fi

  echo "No logs available for ${SERVICE_NAME} in current journal window." >&2
  echo "Try: sudo vasn_tapctl logs -n 200" >&2
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

cmd="$1"
shift || true

case "${cmd}" in
  start)
    require_systemd
    systemctl start "${SERVICE_NAME}"
    ;;
  stop)
    require_systemd
    systemctl stop "${SERVICE_NAME}"
    ;;
  restart)
    require_systemd
    systemctl restart "${SERVICE_NAME}"
    ;;
  status)
    require_systemd
    systemctl status "${SERVICE_NAME}" --no-pager
    ;;
  counters)
    show_counters
    ;;
  logs)
    show_logs "$@"
    ;;
  validate)
    cfg_path="${1:-${CONFIG_PATH_DEFAULT}}"
    validate_config "${cfg_path}"
    ;;
  apply)
    if [[ $# -ne 1 ]]; then
      echo "apply requires a config path." >&2
      usage
      exit 1
    fi
    require_systemd
    src_cfg="$1"
    validate_config "${src_cfg}"
    install -d -m 755 /etc/vasn_tap
    install -m 644 "${src_cfg}" "${CONFIG_PATH_DEFAULT}"
    systemctl restart "${SERVICE_NAME}"
    ;;
  *)
    echo "Unknown command: ${cmd}" >&2
    usage
    exit 1
    ;;
esac
