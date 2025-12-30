#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
BENCH_SECONDS="${BENCH_SECONDS:-5}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

SIGS=("ecdsap256" "mldsa44" "mldsa65" "falcon512" "falcon1024")

echo "=== Signature speed benchmark ==="
echo "Image: ${IMG}"
echo "OPENSSL_BIN: ${OPENSSL_BIN}"
echo "Seconds per test: ${BENCH_SECONDS}"
echo

# --- Sanity + providers（更可解释） ---
docker run --rm \
  -e OPENSSL_BIN="${OPENSSL_BIN}" \
  "${IMG}" sh -lc '
    if [ -x "$OPENSSL_BIN" ] || command -v "$OPENSSL_BIN" >/dev/null 2>&1; then
      "$OPENSSL_BIN" version -a | head -n 20
      echo
      "$OPENSSL_BIN" list -providers || true
    else
      echo "ERROR: cannot execute OPENSSL_BIN inside container: $OPENSSL_BIN"
      exit 1
    fi
  '

echo

# --- Benchmark ---
docker run --rm \
  -e OPENSSL_BIN="${OPENSSL_BIN}" \
  -e BENCH_SECONDS="${BENCH_SECONDS}" \
  "${IMG}" sh -lc '
    SIGS="ecdsap256 mldsa44 mldsa65 falcon512 falcon1024"
    for a in $SIGS; do
      echo "--- $a ---"
      "$OPENSSL_BIN" speed -seconds "$BENCH_SECONDS" \
        -provider oqsprovider -provider default \
        "$a" 2>/dev/null \
        || echo "skip($a): not supported in this build"
      echo
    done
  '
