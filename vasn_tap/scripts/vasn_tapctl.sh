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
