#!/usr/bin/env bash
set -euo pipefail

PURGE_CONFIG=false

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--purge-config]

Options:
  --purge-config   Also remove /etc/vasn_tap directory and config files
EOF
}

for arg in "$@"; do
  case "${arg}" in
    --purge-config)
      PURGE_CONFIG=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must be run as root. Use sudo ./uninstall.sh" >&2
  exit 1
fi

SERVICE_NAME="vasn_tap"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

BIN_PATH="/usr/local/bin/vasn_tap"
CTL_PATH="/usr/local/bin/vasn_tapctl"
BPF_PATH="/usr/local/share/vasn_tap/tc_clone.bpf.o"
SHARE_DIR="/usr/local/share/vasn_tap"
CFG_DIR="/etc/vasn_tap"

echo "[1/5] Stopping and disabling service (if present)"
if command -v systemctl >/dev/null 2>&1; then
  # Best-effort cleanup; ignore errors when service/unit is not present.
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
else
  echo "Warning: systemctl not found; skipping service stop/disable"
fi

echo "[2/5] Removing systemd unit"
if [[ -f "${UNIT_PATH}" ]]; then
  rm -f "${UNIT_PATH}"
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi

echo "[3/5] Removing installed binaries and scripts"
rm -f "${BIN_PATH}" "${CTL_PATH}"

echo "[4/5] Removing BPF artifact"
rm -f "${BPF_PATH}"
rmdir "${SHARE_DIR}" 2>/dev/null || true

echo "[5/5] Configuration"
if [[ "${PURGE_CONFIG}" == "true" ]]; then
  rm -rf "${CFG_DIR}"
  echo "Removed ${CFG_DIR}"
else
  echo "Kept ${CFG_DIR} (use --purge-config to remove it)"
fi

echo "Uninstall complete."
