#!/usr/bin/env bash
set -euo pipefail

# 从 workflow 读取 IMG；若未设置才使用默认（不要用 latest）
IMG="${IMG:-openquantumsafe/oqs-ossl3:0.12.0}"
SECONDS="${SECONDS:-5}"

# 尽量覆盖 classical + PQ（不支持的会自动 skip）
SIGS=("ecdsap256" "mldsa44" "mldsa65" "falcon512" "falcon1024")

echo "=== Signature speed benchmark ==="
echo "Image: ${IMG}"
echo "Seconds per test: ${SECONDS}"
echo

# ---- Sanity check：容器内是否有 openssl ----
docker run --rm "${IMG}" sh -lc '
  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl not found inside container"
    exit 1
  fi
  openssl version -a
'

echo

# ---- 正式 benchmark ----
docker run --rm "${IMG}" sh -lc "
  for a in ${SIGS[*]}; do
    echo \"--- openssl speed \$a ---\"
    openssl speed -seconds ${SECONDS} \
      -provider oqsprovider -provider default \
      \$a 2>/dev/null \
      || echo \"skip(\$a): not supported in this build\"
    echo
  done
"
