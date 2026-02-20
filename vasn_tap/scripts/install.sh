#!/usr/bin/env bash
set -euo pipefail

FORCE_IFACE_PROMPT=false

usage() {
  cat <<'EOF'
Usage: install.sh [-i]

Options:
  -i    Always prompt for runtime.input_iface and runtime.output_iface
EOF
}

while getopts ":ih" opt; do
  case "${opt}" in
    i)
      FORCE_IFACE_PROMPT=true
      ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "Unknown option: -${OPTARG}" >&2
      usage
      exit 1
      ;;
  esac
done
shift $((OPTIND - 1))
if [[ $# -gt 0 ]]; then
  echo "Unexpected argument(s): $*" >&2
  usage
  exit 1
fi

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

has_runtime_field() {
  local cfg_path="$1"
  local field_name="$2"
  awk '
    BEGIN { in_runtime = 0; found = 0 }
    /^[[:space:]]*runtime:[[:space:]]*$/ { in_runtime = 1; next }
    in_runtime && /^[^[:space:]]/ { in_runtime = 0 }
    in_runtime && $0 ~ ("^[[:space:]]*" field_name ":[[:space:]]*") {
      val = $0
      sub(("^[[:space:]]*" field_name ":[[:space:]]*"), "", val)
      sub(/[[:space:]]*#.*/, "", val)
      gsub(/[[:space:]]/, "", val)
      if (val != "") found = 1
      exit
    }
    END { exit(found ? 0 : 1) }
  ' field_name="${field_name}" "${cfg_path}"
}

set_runtime_field() {
  local cfg_path="$1"
  local field_name="$2"
  local field_value="$3"
  local tmp_file
  tmp_file="$(mktemp)"

  awk -v field_name="${field_name}" -v field_value="${field_value}" '
    BEGIN { in_runtime = 0; inserted = 0; saw_runtime = 0 }
    {
      if ($0 ~ /^[[:space:]]*runtime:[[:space:]]*$/) {
        saw_runtime = 1
        in_runtime = 1
        print
        next
      }
      if (in_runtime && $0 ~ /^[^[:space:]]/) {
        if (!inserted) {
          print "  " field_name ": " field_value
          inserted = 1
        }
        in_runtime = 0
      }
      if (in_runtime && $0 ~ ("^[[:space:]]*" field_name ":[[:space:]]*")) {
        print "  " field_name ": " field_value
        inserted = 1
        next
      }
      print
    }
    END {
      if (in_runtime && !inserted) {
        print "  " field_name ": " field_value
        inserted = 1
      }
      if (!saw_runtime) {
        exit 2
      }
    }
  ' "${cfg_path}" > "${tmp_file}" || {
    rm -f "${tmp_file}"
    return 1
  }

  install -m 644 "${tmp_file}" "${cfg_path}"
  rm -f "${tmp_file}"
}

list_system_ifaces() {
  mapfile -t SYSTEM_IFACES < <(ip -o link show | awk -F': ' '{print $2}' | awk -F'@' '{print $1}')
}

prompt_for_runtime_iface() {
  local cfg_path="$1"
  local field_name="$2"
  local prompt_text="$3"
  local iface choice

  list_system_ifaces

  if [[ ${#SYSTEM_IFACES[@]} -eq 0 ]]; then
    echo "No network interfaces found on this host." >&2
    return 1
  fi
  if [[ ! -t 0 ]]; then
    echo "runtime.${field_name} is missing in ${cfg_path}, but install.sh is not interactive." >&2
    echo "Set runtime.${field_name} manually in ${cfg_path} and re-run install.sh." >&2
    return 1
  fi

  echo "runtime.${field_name} is missing in ${cfg_path}."
  echo "${prompt_text}"
  for i in "${!SYSTEM_IFACES[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${SYSTEM_IFACES[$i]}"
  done

  while true; do
    printf "Enter choice [1-%d]: " "${#SYSTEM_IFACES[@]}"
    read -r choice
    if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SYSTEM_IFACES[@]} )); then
      iface="${SYSTEM_IFACES[$((choice - 1))]}"
      break
    fi
    echo "Invalid choice. Please enter a number between 1 and ${#SYSTEM_IFACES[@]}."
  done

  set_runtime_field "${cfg_path}" "${field_name}" "${iface}" || {
    echo "Failed to update runtime.${field_name} in ${cfg_path}" >&2
    return 1
  }
  echo "Set runtime.${field_name} to '${iface}' in ${cfg_path}"
}

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

echo "[4/6] Installing configuration"
if [[ -f "${CFG_EXAMPLE_SRC}" ]]; then
  if [[ ! -f "${CFG_DST}" ]]; then
    install -m 644 "${CFG_EXAMPLE_SRC}" "${CFG_DST}"
    echo "Created ${CFG_DST} from config.example.yaml"
  else
    echo "Existing ${CFG_DST} kept (not overwritten)"
  fi
else
  echo "Warning: config.example.yaml not found in package; cannot auto-seed ${CFG_DST}"
fi

if [[ -f "${CFG_DST}" ]]; then
  if [[ "${FORCE_IFACE_PROMPT}" == "true" ]]; then
    prompt_for_runtime_iface "${CFG_DST}" "input_iface" "Select the interface to tap (input):" || exit 1
    prompt_for_runtime_iface "${CFG_DST}" "output_iface" "Select the output interface for forwarded traffic:" || exit 1
  else
    if ! has_runtime_field "${CFG_DST}" "input_iface"; then
      prompt_for_runtime_iface "${CFG_DST}" "input_iface" "Select the interface to tap (input):" || exit 1
    fi
    if ! has_runtime_field "${CFG_DST}" "output_iface"; then
      prompt_for_runtime_iface "${CFG_DST}" "output_iface" "Select the output interface for forwarded traffic:" || exit 1
    fi
  fi
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
1) Check status:    vasn_tapctl status
2) Check counters:  vasn_tapctl counters

Requirements:
- Host must provide required shared libraries (libbpf, libyaml, libelf, zlib, etc).
EOF
