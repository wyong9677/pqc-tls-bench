#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"

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

echo "=== Container sanity (single run) ==="
echo "Image: ${IMG}"
echo

docker run --rm "${IMG}" sh -lc '
  set -e
  echo "== kernel =="; uname -a || true
  echo
  echo "== openssl =="; openssl version -a | head -n 40 || true
  echo
  echo "== providers =="; openssl list -providers || true
  echo
  echo "== tls groups (head) =="; (openssl list -groups 2>/dev/null | head -n 160 || true)
  echo
  echo "== signature algorithms (head) =="; (openssl list -signature-algorithms 2>/dev/null | head -n 160 || true)
  echo
  echo "== python3 =="; (python3 --version || true)
'
