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

echo "=== OpenSSL & Providers ==="
docker run --rm "$IMG" sh -lc '
  openssl version -a
  echo
  openssl list -providers
  echo
  echo "TLS groups:"
  openssl list -groups 2>/dev/null | head -n 100 || true
'
