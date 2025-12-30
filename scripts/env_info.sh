#!/usr/bin/env bash
set -euo pipefail

# 从 workflow 读取 IMG；不要用 latest
IMG="${IMG:-openquantumsafe/oqs-ossl3:0.12.0}"

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
docker run --rm "${IMG}" sh -lc '
  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl not found inside container"
    exit 1
  fi
  command -v openssl
  openssl version -a
'
echo

echo "=== Providers (inside container) ==="
docker run --rm "${IMG}" sh -lc '
  openssl list -providers || true
'
echo

echo "=== TLS Groups (inside container) ==="
docker run --rm "${IMG}" sh -lc '
  openssl list -groups 2>/dev/null | head -n 200 || true
'
