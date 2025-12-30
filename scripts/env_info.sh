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

echo "=== Container sanity check (single run) ==="
echo "Image: ${IMG}"
echo "Requested OPENSSL_BIN: ${OPENSSL_BIN}"
echo

docker run --rm -e OPENSSL_BIN="${OPENSSL_BIN}" "${IMG}" sh -lc '
  set -e

  pick_openssl() {
    # 1) 用户指定的 OPENSSL_BIN
    if [ -n "${OPENSSL_BIN:-}" ]; then
      if [ -x "$OPENSSL_BIN" ] || command -v "$OPENSSL_BIN" >/dev/null 2>&1; then
        echo "$OPENSSL_BIN"
        return 0
      fi
    fi
    # 2) fallback: openssl
    if command -v openssl >/dev/null 2>&1; then
      echo "openssl"
      return 0
    fi
    return 1
  }

  BIN="$(pick_openssl || true)"
  if [ -z "$BIN" ]; then
    echo "ERROR: cannot find openssl binary in container."
    exit 1
  fi

  echo "OPENSSL_BIN inside container: $BIN"
  case "$BIN" in
    /*) ls -l "$BIN" 2>/dev/null || true ;;
  esac
  echo

  echo "== openssl version (head) =="
  "$BIN" version -a 2>/dev/null | head -n 40 || true
  echo

  echo "== providers =="
  "$BIN" list -providers 2>/dev/null || true
  echo

  echo "== tls groups (head) =="
  "$BIN" list -groups 2>/dev/null | head -n 120 || true
'
