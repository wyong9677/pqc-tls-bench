#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"

mkdir -p "${RESULTS_DIR}"

# CI expects env_info.txt (contract)
OUT_TXT="${RESULTS_DIR}/env_info.txt"

# Also keep a .log if you want (optional); comment out if unnecessary
OUT_LOG="${RESULTS_DIR}/env_info.log"

# Tee everything to both txt + log and to console
# (Works with set -euo pipefail)
exec > >(tee "${OUT_TXT}" "${OUT_LOG}") 2>&1

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
docker info 2>/dev/null | head -n 80 || true
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
  export LC_ALL=C
  OPENSSL=/opt/openssl/bin/openssl
  [ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
  echo "OPENSSL_BIN=$OPENSSL"
  [ -x "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }

  echo
  echo "== openssl version (head) =="
  "$OPENSSL" version -a | head -n 80 || true
  echo
  echo "== providers =="
  "$OPENSSL" list -providers || true
  echo
  echo "== signature algorithms (head) =="
  "$OPENSSL" list -signature-algorithms 2>/dev/null | head -n 200 || true
'

echo
echo "[INFO] Wrote: ${OUT_TXT}"
echo "[INFO] Wrote: ${OUT_LOG}"
