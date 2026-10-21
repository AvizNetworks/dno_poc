#!/usr/bin/env bash
# make_packages.sh — build the TWO customer packets from this repo (single source).
#
#   ./make_packages.sh [--with-image] [output-dir]   # default: <repo>/packages/<YYYYMMDD>
#
#   --with-image  ALSO export the doca_hbn container image (linux/arm64, ~750MB) as
#                 doca_hbn_<tag>.tar for OFFLINE BF3s (no nvcr.io reach). Needs docker +
#                 internet on the build machine. Git-ignored — ship it out-of-band. On the BF3:
#                   sudo ctr -n k8s.io images import doca_hbn_<tag>.tar
#
# Stages in a temp dir, then writes ONLY the deliverables into the output dir
# (commit that dir to give the team the packets):
#   hbn-standalone-<date>.tar.gz  — run ON the BF3 (scripts/, mellanox/, doca_hbn_v3.3.0/, docs/)
#   hbn-dpf-<date>.tar.gz         — run from the DPF Operator VM (dpf/)
#   dpu-netboot-<date>.tar.gz     — run ON the BF3: netboot.sh (= scripts/dpu_netboot_server.sh) + README
#                                   (docs/NETBOOT.md); x86 host PXE/install from its own DPU, no controller
#   SHA256SUMS
#
# The packet README is GENERATED from the repo README.md by stripping every
# <!-- lab-internal:start --> ... <!-- lab-internal:end --> block (DPF cross-refs,
# lab server tables, lab-only test scripts). Maintain ONLY the repo README —
# never hand-edit the packet copy.
#
# Excluded from packets by design:
#   - scripts/test/            (lab test scripts with embedded lab credentials)
#   - dpf/config.local.yaml    (real secrets — customers copy the .sample)
#   - dpf/docs/                (internal slide deck)
#   - dpf/scripts/nvidia_debug_commands.sh, *.bak
#   - CLAUDE.md, .vscode/      (internal)
# A credential scan runs at the end and ABORTS the build on any hit.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATE=$(date +%Y%m%d)
WITH_IMAGE=false
[[ "${1:-}" == "--with-image" ]] && { WITH_IMAGE=true; shift; }
OUT="${1:-${REPO}/packages/${DATE}}"
STAGE=$(mktemp -d)
trap 'rm -rf "${STAGE}"' EXIT

echo "== staging in ${STAGE} (deliverables -> ${OUT})"
mkdir -p "${OUT}" "${STAGE}/hbn-standalone/scripts" "${STAGE}/hbn-dpf/dpf" "${STAGE}/dpu-netboot"

# ── Standalone packet ─────────────────────────────────────────────────────────
cp -r "${REPO}/mellanox" "${REPO}/doca_hbn_v3.3.0" "${REPO}/docs" "${STAGE}/hbn-standalone/"
rm -f "${STAGE}/hbn-standalone/docs/NETBOOT.md"     # belongs to the dpu-netboot packet
for f in hbn_quickstart.sh hbn_quickstart.env.sample inventory_bf3.sh bringup_hbn_bf3.sh bringup_hbn_bf3_single_port.sh \
         status_hbn.sh topology_hbn.sh access_hbn.sh \
         setup_host_vfs_standalone.sh setup_host_vfs.sh mirror_to_dpu.sh; do
  cp "${REPO}/scripts/${f}" "${STAGE}/hbn-standalone/scripts/"
done

# Generate the customer README: strip lab-internal blocks
python3 - "${REPO}/README.md" "${STAGE}/hbn-standalone/README.md" <<'PY'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
s = re.sub(r'<!-- lab-internal:start -->\n.*?<!-- lab-internal:end -->\n',
           '', s, flags=re.S)
assert 'lab-internal' not in s, 'unbalanced lab-internal markers in README.md'
assert 'dpf' not in s.lower(), 'DPF still mentioned in packet README — wrap it in lab-internal markers'
assert '10.20.13.' not in s and '10.4.5.' not in s, 'lab IP leaked into packet README'
open(dst, 'w').write(s)
print("  packet README generated (%d lines)" % len(s.splitlines()))
PY

# ── DPF packet ────────────────────────────────────────────────────────────────
for f in README.md QUICKSTART.md CHEATSHEET.md MULTI-DPU-DESIGN.md \
         config.yaml config.local.sample.yaml; do
  cp "${REPO}/dpf/${f}" "${STAGE}/hbn-dpf/dpf/"
done
cp -r "${REPO}/dpf/manifests" "${REPO}/dpf/scripts" "${STAGE}/hbn-dpf/dpf/"
rm -f "${STAGE}/hbn-dpf/dpf/scripts/"*.bak \
      "${STAGE}/hbn-dpf/dpf/scripts/nvidia_debug_commands.sh" 2>/dev/null || true

# ── DPU netboot packet ────────────────────────────────────────────────────────
cp "${REPO}/scripts/dpu_netboot_server.sh" "${STAGE}/dpu-netboot/netboot.sh"
chmod +x "${STAGE}/dpu-netboot/netboot.sh"
cp "${REPO}/docs/NETBOOT.md" "${STAGE}/dpu-netboot/README.md"
bash -n "${STAGE}/dpu-netboot/netboot.sh"
if grep -nE '10\.20\.13\.|10\.4\.5\.|d4:5d:64|9c:63:c0|s8-host' "${STAGE}/dpu-netboot/"*; then
  echo "!! lab-specific value leaked into dpu-netboot packet — build aborted"; exit 1
fi

# ── Credential scan (ABORTS on any hit) ───────────────────────────────────────
echo "== credential scan"
PATTERNS='Aviz@|aviz@123|Dno@123|YourPaSsWoRd|H3lLoW0rLd|MaiBF3|AIF123|Con@dmin|\$6\$[A-Za-z0-9./]{8,}\$'
if grep -rnE "${PATTERNS}" "${STAGE}"; then
  echo "!! CREDENTIALS FOUND — build aborted"; exit 1
fi
echo "  clean"

# ── Tarballs + checksums (only these land in ${OUT}) ─────────────────────────
tar -C "${STAGE}" -czf "${OUT}/hbn-standalone-${DATE}.tar.gz" hbn-standalone
tar -C "${STAGE}" -czf "${OUT}/hbn-dpf-${DATE}.tar.gz" hbn-dpf
tar -C "${STAGE}" -czf "${OUT}/dpu-netboot-${DATE}.tar.gz" dpu-netboot

# ── Optional: doca_hbn image for OFFLINE BF3s (--with-image) ─────────────────
# Image ref comes from the pod spec (single source of truth). The BF3 is ARM: the
# build machine is usually x86, so force linux/arm64 and verify it TWICE (docker's
# view + the config blob inside the saved tar) — an amd64 tar imports fine but the
# pod then dies with "exec format error".
IMAGE_TAR=""
if $WITH_IMAGE; then
  IMAGE=$(awk '/image:/{print $2; exit}' "${REPO}/doca_hbn_v3.3.0/configs/3.3.0/doca_hbn.yaml")
  IMAGE_TAR="doca_hbn_${IMAGE##*:}.tar"
  echo "== exporting ${IMAGE} (linux/arm64) -> ${IMAGE_TAR}"
  command -v docker >/dev/null || { echo "!! --with-image needs docker"; exit 1; }
  docker pull -q --platform linux/arm64 "${IMAGE}"
  ARCH=$(docker image inspect "${IMAGE}" --format '{{.Os}}/{{.Architecture}}')
  [[ "${ARCH}" == "linux/arm64" ]] || { echo "!! ${IMAGE} is ${ARCH}, not linux/arm64 — aborted"; exit 1; }
  docker save -o "${OUT}/${IMAGE_TAR}" "${IMAGE}"
  chmod 0644 "${OUT}/${IMAGE_TAR}"   # docker save -o writes 0600
  python3 - "${OUT}/${IMAGE_TAR}" <<'PY'
import sys, json, tarfile
t = tarfile.open(sys.argv[1])
m = json.load(t.extractfile("manifest.json"))[0]
cfg = json.load(t.extractfile(m["Config"]))
arch = "%s/%s" % (cfg.get("os"), cfg.get("architecture"))
assert arch == "linux/arm64", "saved image is %s, not linux/arm64" % arch
print("  verified in tar: %s, tag %s, %d layers" % (arch, m["RepoTags"][0], len(m["Layers"])))
PY
fi

cd "${OUT}"
sha256sum ./*.tar.gz ${IMAGE_TAR:+"./${IMAGE_TAR}"} > SHA256SUMS
echo "== done"
cat SHA256SUMS
