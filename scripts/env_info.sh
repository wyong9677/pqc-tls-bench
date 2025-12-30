#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
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
echo

docker run --rm \
  -e OPENSSL_BIN="${OPENSSL_BIN}" \
  "${IMG}" sh -lc '
    echo "OPENSSL_BIN inside container: $OPENSSL_BIN"

    # 如果是绝对路径，打印一下文件信息，方便排错
    case "$OPENSSL_BIN" in
      /*) ls -l "$OPENSSL_BIN" 2>/dev/null || true ;;
    esac

    if [ -x "$OPENSSL_BIN" ] || command -v "$OPENSSL_BIN" >/dev/null 2>&1; then
      "$OPENSSL_BIN" version -a | head -n 60
    else
      echo "ERROR: cannot execute OPENSSL_BIN inside container: $OPENSSL_BIN"
      exit 1
    fi
  '
echo

echo "=== Providers (inside container) ==="
docker run --rm \
  -e OPENSSL_BIN="${OPENSSL_BIN}" \
  "${IMG}" sh -lc '
    "$OPENSSL_BIN" list -providers || true
  '
echo

echo "=== TLS Groups (inside container) ==="
docker run --rm \
  -e OPENSSL_BIN="${OPENSSL_BIN}" \
  "${IMG}" sh -lc '
    "$OPENSSL_BIN" list -groups 2>/dev/null | head -n 200 || true
  '
