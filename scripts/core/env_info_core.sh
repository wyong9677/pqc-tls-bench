#!/usr/bin/env bash
set -euo pipefail

OUTDIR="${1:?usage: env_info_core.sh /out}"
mkdir -p "${OUTDIR}"

OPENSSL="/opt/openssl/bin/openssl"
if [ ! -x "${OPENSSL}" ]; then
  OPENSSL="$(command -v openssl)"
fi

{
  echo "=== container uname ==="
  uname -a || true
  echo

  echo "=== openssl ==="
  "${OPENSSL}" version -a || true
  echo

  echo "=== providers (default + oqsprovider) ==="
  "${OPENSSL}" list -providers -provider default -provider oqsprovider || true
  echo

  echo "=== groups (if supported) ==="
  "${OPENSSL}" list -groups -provider default -provider oqsprovider 2>/dev/null || true
  echo
} | tee "${OUTDIR}/env_info.txt" >/dev/null

echo "${OUTDIR}/env_info.txt"
