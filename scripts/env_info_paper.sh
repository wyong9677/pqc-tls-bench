#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

need docker
need python3

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

RUN_ID="${RUN_ID:-$(default_run_id)}"
OUTDIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "${OUTDIR}"

out="${OUTDIR}/env_info.txt"
: > "${out}"

{
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
  docker info 2>/dev/null | head -n 120 || true
  echo

  echo "=== Host Python ==="
  python3 --version || true
  echo

  echo "=== Git ==="
  git rev-parse HEAD 2>/dev/null || true
  echo

  echo "=== Container sanity ==="
  docker run --rm "${IMG}" sh -lc '
    set -e
    OPENSSL=/opt/openssl/bin/openssl
    [ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
    echo "OPENSSL_BIN=$OPENSSL"
    [ -x "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }

    echo
    echo "== openssl version =="
    "$OPENSSL" version -a | head -n 120 || true
    echo
    echo "== providers =="
    "$OPENSSL" list -providers || true
    echo
    echo "== signature algorithms (head) =="
    "$OPENSSL" list -signature-algorithms 2>/dev/null | head -n 200 || true
    echo
    echo "== groups (head) =="
    "$OPENSSL" list -groups 2>/dev/null | head -n 200 || true
  '
} | tee "${out}"

echo
echo "OK. env_info: ${out}"
