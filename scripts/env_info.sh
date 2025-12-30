#!/usr/bin/env bash
set -euo pipefail

IMG="openquantumsafe/oqs-ossl3:latest"

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

echo "=== OpenSSL & Providers (inside container) ==="
docker run --rm "$IMG" sh -lc '
  openssl version -a || true
  echo
  openssl list -providers || true
  echo
  echo "=== TLS Groups ==="
  openssl list -groups 2>/dev/null | head -n 200 || true
'
