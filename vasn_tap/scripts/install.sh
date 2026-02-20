#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must be run as root. Use sudo ./install.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_SRC="${SCRIPT_DIR}/vasn_tap"
BPF_SRC="${SCRIPT_DIR}/tc_clone.bpf.o"
CFG_EXAMPLE_SRC="${SCRIPT_DIR}/config.example.yaml"
CTL_SRC="${SCRIPT_DIR}/vasn_tapctl.sh"
UNIT_SRC="${SCRIPT_DIR}/vasn_tap.service"

BIN_DST="/usr/local/bin/vasn_tap"
BPF_DST="/usr/local/share/vasn_tap/tc_clone.bpf.o"
CTL_DST="/usr/local/bin/vasn_tapctl"
UNIT_DST="/etc/systemd/system/vasn_tap.service"
CFG_DIR="/etc/vasn_tap"
CFG_DST="${CFG_DIR}/config.yaml"
CFG_EXAMPLE_DST="${CFG_DIR}/config.example.yaml"

for f in "${BIN_SRC}" "${BPF_SRC}" "${CTL_SRC}" "${UNIT_SRC}"; do
  if [[ ! -f "${f}" ]]; then
    echo "Required file not found: ${f}" >&2
    exit 1
  fi
done

echo "[1/6] Creating directories"
install -d -m 755 /usr/local/bin
install -d -m 755 /usr/local/share/vasn_tap
install -d -m 755 "${CFG_DIR}"

echo "[2/6] Installing binary and BPF object"
install -m 755 "${BIN_SRC}" "${BIN_DST}"
install -m 644 "${BPF_SRC}" "${BPF_DST}"

echo "[3/6] Installing control script"
install -m 755 "${CTL_SRC}" "${CTL_DST}"

echo "[4/6] Installing configuration templates"
if [[ -f "${CFG_EXAMPLE_SRC}" ]]; then
  install -m 644 "${CFG_EXAMPLE_SRC}" "${CFG_EXAMPLE_DST}"
  if [[ ! -f "${CFG_DST}" ]]; then
    install -m 644 "${CFG_EXAMPLE_SRC}" "${CFG_DST}"
    echo "Created ${CFG_DST} from config.example.yaml"
  else
    echo "Existing ${CFG_DST} kept (not overwritten)"
  fi
else
  echo "Warning: config.example.yaml not found in package; skipping config template install"
fi

echo "[5/6] Installing systemd unit"
install -m 644 "${UNIT_SRC}" "${UNIT_DST}"
systemctl daemon-reload

echo "[6/6] Dependency check (informational)"
if command -v ldd >/dev/null 2>&1; then
  if ! ldd "${BIN_DST}" >/dev/null 2>&1; then
    echo "Warning: ldd could not inspect ${BIN_DST}; verify runtime libraries are installed."
  fi
fi

cat <<'EOF'
Installation complete.

Next steps:
1) Edit /etc/vasn_tap/config.yaml (including required runtime fields).
2) Validate config: vasn_tapctl validate
3) Start service:   vasn_tapctl start
4) Check status:    vasn_tapctl status

Requirements:
- Host must provide required shared libraries (libbpf, libyaml, libelf, zlib, etc).
EOF
