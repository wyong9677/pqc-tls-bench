#!/usr/bin/env bash
set -euo pipefail

# 从 workflow 读取 IMG；默认用 latest（保证能 pull），不要再用 0.12.0
IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"

# 不要用 SECONDS（bash 特殊变量）；改成自定义变量
BENCH_SECONDS="${BENCH_SECONDS:-5}"

# 从 workflow 的 Probe step 读取 openssl 实际路径；默认尝试 openssl
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

# 尽量覆盖 classical + PQ（不支持的会自动 skip）
SIGS=("ecdsap256" "mldsa44" "mldsa65" "falcon512" "falcon1024")

echo "=== Signature speed benchmark ==="
echo "Image: ${IMG}"
echo "OPENSSL_BIN: ${OPENSSL_BIN}"
echo "Seconds per test: ${BENCH_SECONDS}"
echo

# ---- Sanity check：容器内是否能执行 OPENSSL_BIN ----
docker run --rm "${IMG}" sh -lc "
  if [ -x \"${OPENSSL_BIN}\" ] || command -v \"${OPENSSL_BIN}\" >/dev/null 2>&1; then
    \"${OPENSSL_BIN}\" version -a | head -n 20
  else
    echo 'ERROR: cannot execute OPENSSL_BIN inside container'
    echo 'Tip: ensure workflow Probe step sets OPENSSL_BIN and scripts use it.'
    exit 1
  fi
"

echo

# ---- 正式 benchmark ----
docker run --rm "${IMG}" sh -lc "
  for a in ${SIGS[*]}; do
    echo \"--- \$a ---\"
    \"${OPENSSL_BIN}\" speed -seconds ${BENCH_SECONDS} \
      -provider oqsprovider -provider default \
      \$a 2>/dev/null \
      || echo \"skip(\$a): not supported in this build\"
    echo
  done
"
