#!/usr/bin/env bash
# make_packages.sh — build the TWO customer packets from this repo (single source).
#
#   ./make_packages.sh [output-dir]        # default: <repo>/packages/<YYYYMMDD>
#
# Stages in a temp dir, then writes ONLY the deliverables into the output dir
# (commit that dir to give the team the packets):
#   hbn-standalone-<date>.tar.gz  — run ON the BF3 (scripts/, mellanox/, doca_hbn_v3.3.0/, docs/)
#   hbn-dpf-<date>.tar.gz         — run from the DPF Operator VM (dpf/)
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
OUT="${1:-${REPO}/packages/${DATE}}"
STAGE=$(mktemp -d)
trap 'rm -rf "${STAGE}"' EXIT

echo "== staging in ${STAGE} (deliverables -> ${OUT})"
mkdir -p "${OUT}" "${STAGE}/hbn-standalone/scripts" "${STAGE}/hbn-dpf/dpf"

# ── Standalone packet ─────────────────────────────────────────────────────────
cp -r "${REPO}/mellanox" "${REPO}/doca_hbn_v3.3.0" "${REPO}/docs" "${STAGE}/hbn-standalone/"
for f in bringup_hbn_bf3.sh status_hbn.sh topology_hbn.sh access_hbn.sh \
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

# ── Credential scan (ABORTS on any hit) ───────────────────────────────────────
echo "== credential scan"
PATTERNS='Aviz@|aviz@123|Dno@123|YourPaSsWoRd|H3lLoW0rLd|MaiBF3|AIF123'
if grep -rnE "${PATTERNS}" "${STAGE}"; then
  echo "!! CREDENTIALS FOUND — build aborted"; exit 1
fi
echo "  clean"

# ── Tarballs + checksums (only these land in ${OUT}) ─────────────────────────
tar -C "${STAGE}" -czf "${OUT}/hbn-standalone-${DATE}.tar.gz" hbn-standalone
tar -C "${STAGE}" -czf "${OUT}/hbn-dpf-${DATE}.tar.gz" hbn-dpf
cd "${OUT}"
sha256sum ./*.tar.gz > SHA256SUMS
echo "== done"
cat SHA256SUMS
