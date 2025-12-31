#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need docker

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

RUN_ID="${RUN_ID:-$(default_run_id)}"

# Prefer OUTDIR if workflow exports it (recommended: OUTDIR=$RUN_DIR)
OUTDIR="${OUTDIR:-${RESULTS_DIR}/${RUN_ID}}"
mkdir -p "${OUTDIR}"

out="${OUTDIR}/env_info.txt"
: > "${out}"

{
  echo "=== Benchmark Meta ==="
  echo "timestamp_utc=$(date -u +'%Y-%m-%dT%H:%M:%SZ' || true)"
  echo "mode=${MODE}"
  echo "run_id=${RUN_ID}"
  echo "img=${IMG}"
  echo "results_dir=${RESULTS_DIR}"
  echo "outdir=${OUTDIR}"
  echo

  echo "=== Host ==="
  uname -a || true
  echo

  echo "=== Host OS ==="
  (cat /etc/os-release 2>/dev/null || true)
  echo

  echo "=== CPU ==="
  lscpu 2>/dev/null || true
  echo

  echo "=== Memory ==="
  free -h 2>/dev/null || true
  echo

  echo "=== Docker ==="
  docker --version || true
  # avoid pipefail breakage; best-effort
  (docker info 2>/dev/null | head -n 160) || true
  echo

  echo "=== Host Python ==="
  if command -v python3 >/dev/null 2>&1; then
    python3 --version || true
    python3 -c 'import sys; print("python_executable=", sys.executable)' 2>/dev/null || true
  else
    echo "python3: NOT FOUND (ok for env_info)"
  fi
  echo

  echo "=== Git ==="
  git rev-parse HEAD 2>/dev/null || true
  git status --porcelain 2>/dev/null || true
  echo

  echo "=== Container sanity ==="
  docker run --rm "${IMG}" sh -lc '
    set -eu

    echo "== container os-release =="
    (cat /etc/os-release 2>/dev/null || true)
    echo

    OPENSSL=/opt/openssl/bin/openssl
    if [ ! -x "$OPENSSL" ]; then OPENSSL="$(command -v openssl 2>/dev/null || true)"; fi
    echo "OPENSSL_BIN=$OPENSSL"
    if [ -z "$OPENSSL" ] || [ ! -x "$OPENSSL" ]; then
      echo "ERROR: openssl not found" >&2
      exit 127
    fi
    echo

    echo "== openssl version -a (head) =="
    ("$OPENSSL" version -a 2>/dev/null | head -n 160) || true
    echo

    echo "== openssl config paths =="
    # show where openssl is looking for config/modules
    ("$OPENSSL" version -d 2>/dev/null || true)
    ("$OPENSSL" version -m 2>/dev/null || true)
    echo

    echo "== providers =="
    ("$OPENSSL" list -providers 2>/dev/null || true)
    echo

    echo "== signature algorithms (head) =="
    ("$OPENSSL" list -signature-algorithms 2>/dev/null | head -n 240) || true
    echo

    echo "== groups (head) =="
    ("$OPENSSL" list -groups 2>/dev/null | head -n 240) || true
    echo

    echo "== provider modules dirs (best-effort) =="
    # Not all images expose these; do not fail if missing
    ls -la /opt/openssl/lib64/ossl-modules 2>/dev/null || true
    ls -la /opt/openssl/lib/ossl-modules 2>/dev/null || true
    echo

    echo "== oqsprovider presence (best-effort) =="
    # try to locate oqsprovider module if available
    find / -maxdepth 4 -type f -name "*oqsprovider*" 2>/dev/null | head -n 50 || true
  '
} | tee "${out}"

echo
echo "OK. env_info: ${out}"
