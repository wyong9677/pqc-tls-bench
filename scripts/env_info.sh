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

  find_openssl() {
    for p in \
      /opt/openssl32/bin/openssl \
      /opt/openssl/bin/openssl \
      /usr/local/bin/openssl \
      /usr/bin/openssl \
      /usr/local/ssl/bin/openssl
    do
      if [ -x "$p" ]; then echo "$p"; return 0; fi
    done
    if command -v openssl >/dev/null 2>&1; then
      command -v openssl
      return 0
    fi
    if command -v find >/dev/null 2>&1; then
      # 只在 /opt /usr/local /usr 下找，避免过慢
      f="$(find /opt /usr/local /usr -maxdepth 4 -type f -name openssl 2>/dev/null | head -n 1 || true)"
      if [ -n "$f" ] && [ -x "$f" ]; then echo "$f"; return 0; fi
    fi
    return 1
  }

  OPENSSL="$(find_openssl || true)"
  if [ -z "$OPENSSL" ]; then
    echo "ERROR: openssl not found in container PATH or common locations."
    echo "Tip: OQS images often place it under /opt/openssl32/bin/openssl." 1>&2
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

  echo "== tls groups (head) =="
  ("$OPENSSL" list -groups 2>/dev/null | head -n 160) || true
  echo

  echo "== signature algorithms (head) =="
  ("$OPENSSL" list -signature-algorithms 2>/dev/null | head -n 160) || true
  echo

  echo "== python3 =="
  (python3 --version || true)
'
