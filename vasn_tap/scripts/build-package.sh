#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

echo "[1/5] Building vasn_tap"
make clean && make

echo "[2/5] Computing package version"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  git_sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
else
  git_tag=""
  git_sha=""
fi

build_date="$(date +%Y%m%d)"
app_version="$(./vasn_tap --version 2>/dev/null | awk 'NR==1 {print $2}')"
version_token="${app_version:-${git_tag:-dev}}"
version_token="${version_token//\//-}"
version_token="${version_token// /-}"
if [[ "${version_token}" != v* ]]; then
  version_token="v${version_token}"
fi
build_id="${git_sha:-nogit}"
VERSION="${version_token}-${build_date}-${build_id}"

STAGE_DIR_NAME="vasn_tap-${VERSION}"
STAGE_DIR="${REPO_ROOT}/${STAGE_DIR_NAME}"
TARBALL="${REPO_ROOT}/${STAGE_DIR_NAME}.tar.gz"

echo "[3/5] Preparing staging directory: ${STAGE_DIR_NAME}"
rm -rf "${STAGE_DIR}" "${TARBALL}"
mkdir -p "${STAGE_DIR}"

required_files=(
  "${REPO_ROOT}/vasn_tap"
  "${REPO_ROOT}/tc_clone.bpf.o"
  "${REPO_ROOT}/config.example.yaml"
  "${REPO_ROOT}/scripts/install.sh"
  "${REPO_ROOT}/scripts/vasn_tapctl.sh"
  "${REPO_ROOT}/scripts/vasn_tap.service"
  "${REPO_ROOT}/scripts/INSTALL.txt"
)

for file_path in "${required_files[@]}"; do
  if [[ ! -f "${file_path}" ]]; then
    echo "Missing required file: ${file_path}" >&2
    exit 1
  fi
done

cp "${REPO_ROOT}/vasn_tap" "${STAGE_DIR}/vasn_tap"
cp "${REPO_ROOT}/tc_clone.bpf.o" "${STAGE_DIR}/tc_clone.bpf.o"
cp "${REPO_ROOT}/config.example.yaml" "${STAGE_DIR}/config.example.yaml"
cp "${REPO_ROOT}/scripts/install.sh" "${STAGE_DIR}/install.sh"
cp "${REPO_ROOT}/scripts/vasn_tapctl.sh" "${STAGE_DIR}/vasn_tapctl.sh"
cp "${REPO_ROOT}/scripts/vasn_tap.service" "${STAGE_DIR}/vasn_tap.service"
cp "${REPO_ROOT}/scripts/INSTALL.txt" "${STAGE_DIR}/INSTALL.txt"

chmod 755 "${STAGE_DIR}/install.sh" "${STAGE_DIR}/vasn_tapctl.sh"
chmod 644 "${STAGE_DIR}/vasn_tap.service" "${STAGE_DIR}/INSTALL.txt" "${STAGE_DIR}/config.example.yaml"
chmod 644 "${STAGE_DIR}/tc_clone.bpf.o"
chmod 755 "${STAGE_DIR}/vasn_tap"

echo "[4/5] Creating tarball: $(basename "${TARBALL}")"
tar -C "${REPO_ROOT}" -czf "${TARBALL}" "${STAGE_DIR_NAME}"

echo "[5/5] Done"
echo "Package created: ${TARBALL}"
