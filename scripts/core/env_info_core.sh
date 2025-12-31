#!/usr/bin/env bash
set -euo pipefail

OUTDIR="${1:?usage: env_info_core.sh /out}"
mkdir -p "${OUTDIR}"

MODE="${MODE:-paper}"   # smoke/paper
STRICT="${STRICT:-1}"   # paper 默认 1；smoke 可设 0

ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
info(){ echo "[INFO] $(ts) $*"; }
die(){ echo "[ERROR] $(ts) $*" >&2; exit 1; }

OPENSSL="/opt/openssl/bin/openssl"
if [ ! -x "${OPENSSL}" ]; then
  OPENSSL="$(command -v openssl 2>/dev/null || true)"
fi
[ -x "${OPENSSL}" ] || die "openssl not found (neither /opt/openssl/bin/openssl nor in PATH)"

# Derive MODULESDIR; do NOT override OPENSSL_MODULES
MODULESDIR="$("${OPENSSL}" version -m 2>/dev/null | awk -F'"' '/MODULESDIR/{print $2; exit}' || true)"
if [ -z "${MODULESDIR}" ]; then
  MODULESDIR="/opt/openssl/lib64/ossl-modules"
fi

OUT="${OUTDIR}/env_info.txt"
: > "${OUT}"

{
  echo "=== container uname ==="
  uname -a || true
  echo

  echo "=== openssl bin ==="
  echo "OPENSSL_BIN=${OPENSSL}"
  echo

  echo "=== openssl version -a ==="
  "${OPENSSL}" version -a | head -n 200 || true
  echo

  echo "=== openssl version -m (MODULESDIR) ==="
  "${OPENSSL}" version -m | head -n 80 || true
  echo "MODULESDIR=${MODULESDIR}"
  echo

  echo "=== modulesdir listing (head) ==="
  (ls -la "${MODULESDIR}" 2>/dev/null || true) | head -n 200
  echo

  echo "=== provider sanity: default ==="
  "${OPENSSL}" list -providers -provider-path "${MODULESDIR}" -provider default || true
  echo

  echo "=== provider sanity: oqsprovider ==="
  # oqsprovider may not exist in some images; show output regardless
  "${OPENSSL}" list -providers -provider-path "${MODULESDIR}" -provider oqsprovider -provider default || true
  echo

  echo "=== signature algorithms (head) ==="
  "${OPENSSL}" list -signature-algorithms -provider-path "${MODULESDIR}" -provider default -provider oqsprovider 2>/dev/null | head -n 250 || true
  echo

  echo "=== groups (head) ==="
  "${OPENSSL}" list -groups -provider-path "${MODULESDIR}" -provider default -provider oqsprovider 2>/dev/null | head -n 250 || true
  echo
} | tee "${OUT}" >/dev/null

# Fail-fast in strict mode if default provider clearly missing
if [ "${STRICT}" = "1" ]; then
  if ! grep -qE 'name:[[:space:]]+OpenSSL Default Provider|default' "${OUT}"; then
    die "default provider not detected in env_info; check MODULESDIR and provider modules"
  fi
fi

info "OK. env_info: ${OUT}"
echo "${OUT}"
