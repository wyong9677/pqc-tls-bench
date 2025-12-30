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

echo "=== Host Python ==="
python3 --version || true
echo

echo "=== Container sanity ==="
echo "Image: ${IMG}"
echo

docker run --rm "${IMG}" sh -lc '
  set -e
  OPENSSL=/opt/openssl/bin/openssl
  [ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
  if [ -z "$OPENSSL" ]; then
    echo "ERROR: openssl not found in container"
    exit 127
  fi

  echo "OPENSSL_BIN=$OPENSSL"
  echo
  echo "== openssl version (head) =="
  "$OPENSSL" version -a | head -n 40 || true
  echo
  echo "== providers =="
  "$OPENSSL" list -providers || true
  echo
  echo "== signature algorithms (head) =="
  "$OPENSSL" list -signature-algorithms 2>&1 | head -n 120 || true
'
