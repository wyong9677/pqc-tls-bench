#!/usr/bin/env bash
set -euo pipefail

# 镜像由 workflow 控制；默认用 latest（保证能 pull）
IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"

# openssl 真实路径由 workflow Probe step 写入；默认尝试 openssl
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

echo "=== Host ==="
uname -a || true
echo

echo "=== CPU ==="
lscpu || true
echo

echo "=== Memory ==="
free -h || true
echo

echo "=== Docker ==="
docker --version || true
echo

echo "=== Container sanity check ==="
echo "Image: ${IMG}"
echo "OPENSSL_BIN: ${OPENSSL_BIN}"

docker run --rm "${IMG}" sh -lc "
  if [ -x \"${OPENSSL_BIN}\" ] || command -v \"${OPENSSL_BIN}\" >/dev/null 2>&1; then
    echo \"OPENSSL_BIN inside container: ${OPENSSL_BIN}\"
    \"${OPENSSL_BIN}\" version -a | head -n 40
  else
    echo 'ERROR: cannot execute OPENSSL_BIN inside container'
    exit 1
  fi
"
echo

echo "=== Providers (inside container) ==="
docker run --rm "${IMG}" sh -lc "
  \"${OPENSSL_BIN}\" list -providers || true
"
echo

echo "=== TLS Groups (inside container) ==="
docker run --rm "${IMG}" sh -lc "
  \"${OPENSSL_BIN}\" list -groups 2>/dev/null | head -n 200 || true
"
