#!/usr/bin/env bash
set -euo pipefail

# Signature micro-benchmark (paper-grade, provider-safe)
# - Fixes OPENSSL_MODULES pitfall (do NOT override it)
# - Uses MODULESDIR from `openssl version -m` and passes -provider-path explicitly
# - ECDSA P-256 baseline included
# - PQC sign/verify: try dgst first, fallback to pkeyutl
# - Output CSV schema (expected by summarize_results.py):
#   repeat,mode,seconds,alg,keygens_s,sign_s,verify_s

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need docker

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"
STRICT="${STRICT:-1}"
MSG_BYTES="${MSG_BYTES:-32}"

RUN_ID="${RUN_ID:-$(default_run_id)}"
# IMPORTANT: prefer OUTDIR from workflow (OUTDIR=$RUN_DIR)
OUTDIR="${OUTDIR:-${RESULTS_DIR}/${RUN_ID}}"
rawdir="${OUTDIR}/sig_speed_raw"
mkdir -p "${rawdir}"

csv="${OUTDIR}/sig_speed.csv"
warnlog="${OUTDIR}/sig_speed_warnings.log"
: > "${warnlog}"

warnf(){ warn "$*" | true; echo "[WARN] $(ts) $*" >> "${warnlog}" || true; }

echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s" > "${csv}"

cname="sigbench-${RUN_ID}"
cleanup(){ docker rm -f "${cname}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

info "Signature speed: mode=${MODE} run_id=${RUN_ID} outdir=${OUTDIR} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS} STRICT=${STRICT}"
info "IMG=${IMG}"

docker pull "${IMG}" >/dev/null 2>&1 || true
info "Starting long-lived container ${cname}..."
docker run -d --rm --name "${cname}" "${IMG}" sh -lc "sleep infinity" >/dev/null

# Run benchmark inside container; prints ONE line: "keygen_cnt,sign_cnt,verify_cnt"
# Also writes small diagnostics to stderr (captured in raw file)
bench_counts_in_container() {
  local alg="$1" seconds="$2"

  docker exec -i "${cname}" env ALG="${alg}" T="${seconds}" MSG_BYTES="${MSG_BYTES}" sh -s <<'SH'
set -eu

OPENSSL=/opt/openssl/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl 2>/dev/null || true)"
[ -x "$OPENSSL" ] || { echo "NO_OPENSSL" >&2; exit 127; }

# Determine MODULESDIR; do NOT set OPENSSL_MODULES (can break default provider)
MODULESDIR="$("$OPENSSL" version -m 2>/dev/null | awk -F'"' '/MODULESDIR/{print $2; exit}')"
[ -n "${MODULESDIR:-}" ] || MODULESDIR="/opt/openssl/lib64/ossl-modules"

PROV_PATH="-provider-path ${MODULESDIR}"
PROV_DEF="${PROV_PATH} -provider default"
PROV_PQC="${PROV_PATH} -provider oqsprovider -provider default"

ALG="${ALG:?}"
T="${T:?}"
MSG_BYTES="${MSG_BYTES:?}"

WORK="/tmp/sigbench_${ALG}"
mkdir -p "$WORK"
KEY="$WORK/key.pem"
PUB="$WORK/pub.pem"
MSG="$WORK/msg.bin"
SIG="$WORK/sig.bin"

dd if=/dev/zero of="$MSG" bs="$MSG_BYTES" count=1 2>/dev/null

# Helper: keypair
keypair_once() {
  case "$ALG" in
    ecdsap256)
      "$OPENSSL" genpkey $PROV_DEF -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$KEY" >/dev/null 2>&1
      "$OPENSSL" pkey   $PROV_DEF -in "$KEY" -pubout -out "$PUB" >/dev/null 2>&1
      ;;
    mldsa44|mldsa65|falcon512|falcon1024)
      "$OPENSSL" genpkey $PROV_PQC -algorithm "$ALG" -out "$KEY" >/dev/null 2>&1
      "$OPENSSL" pkey    $PROV_PQC -in "$KEY" -pubout -out "$PUB" >/dev/null 2>&1
      ;;
    *)
      echo "UNKNOWN_ALG:$ALG" >&2
      return 9
      ;;
  esac
}

# Sign/verify method selection for PQC (some providers behave differently)
SIG_METHOD="dgst"  # default try

sign_once_dgst() {
  "$OPENSSL" dgst $PROV_DEF -sha256 -sign "$KEY" -out "$SIG" "$MSG" >/dev/null 2>&1
}
verify_once_dgst() {
  "$OPENSSL" dgst $PROV_DEF -sha256 -verify "$PUB" -signature "$SIG" "$MSG" >/dev/null 2>&1
}

sign_once_pkeyutl() {
  "$OPENSSL" pkeyutl $PROV_PQC -sign -inkey "$KEY" -in "$MSG" -out "$SIG" >/dev/null 2>&1
}
verify_once_pkeyutl() {
  "$OPENSSL" pkeyutl $PROV_PQC -verify -pubin -inkey "$PUB" -in "$MSG" -sigfile "$SIG" >/dev/null 2>&1
}

sign_once() {
  case "$ALG" in
    ecdsap256) sign_once_dgst ;;
    *)
      if [ "$SIG_METHOD" = "dgst" ]; then sign_once_dgst; else sign_once_pkeyutl; fi
      ;;
  esac
}

verify_once() {
  case "$ALG" in
    ecdsap256) verify_once_dgst ;;
    *)
      if [ "$SIG_METHOD" = "dgst" ]; then verify_once_dgst; else verify_once_pkeyutl; fi
      ;;
  esac
}

# ---- Setup sanity (fail-fast) ----
if ! keypair_once; then echo "KEYGEN_FAILED" >&2; exit 2; fi

# Decide PQC method if needed
case "$ALG" in
  ecdsap256)
    SIG_METHOD="dgst"
    ;;
  *)
    # try dgst first using default provider path (some builds support it)
    if sign_once_dgst && verify_once_dgst; then
      SIG_METHOD="dgst"
    else
      # fallback pkeyutl with oqsprovider
      if sign_once_pkeyutl && verify_once_pkeyutl; then
        SIG_METHOD="pkeyutl"
      else
        echo "SIGN_VERIFY_UNSUPPORTED" >&2
        exit 6
      fi
    fi
    ;;
esac

echo "MODULESDIR=${MODULESDIR}" >&2
echo "SIG_METHOD=${SIG_METHOD}" >&2

# ---- Counting ----
end=$(( $(date +%s) + T ))

count_window_keygen() {
  c=0
  while :; do
    i=0
    while [ "$i" -lt 50 ]; do
      keypair_once && c=$((c+1)) || true
      i=$((i+1))
    done
    now="$(date +%s)"
    [ "$now" -ge "$end" ] && break
  done
  echo "$c"
}

count_window_sign() {
  # ensure we have a valid keypair before measuring sign rate
  keypair_once >/dev/null 2>&1 || true
  c=0
  while :; do
    i=0
    while [ "$i" -lt 200 ]; do
      sign_once && c=$((c+1)) || true
      i=$((i+1))
    done
    now="$(date +%s)"
    [ "$now" -ge "$end" ] && break
  done
  echo "$c"
}

count_window_verify() {
  # ensure keypair + signature exist before measuring verify rate
  keypair_once >/dev/null 2>&1 || true
  sign_once    >/dev/null 2>&1 || true
  c=0
  while :; do
    i=0
    while [ "$i" -lt 200 ]; do
      verify_once && c=$((c+1)) || true
      i=$((i+1))
    done
    now="$(date +%s)"
    [ "$now" -ge "$end" ] && break
  done
  echo "$c"
}

k="$(count_window_keygen)"
s="$(count_window_sign)"
v="$(count_window_verify)"

case "$k" in (*[!0-9]*|"") echo "KEYGEN_COUNT_BAD:$k" >&2; exit 10;; esac
case "$s" in (*[!0-9]*|"") echo "SIGN_COUNT_BAD:$s" >&2; exit 11;; esac
case "$v" in (*[!0-9]*|"") echo "VERIFY_COUNT_BAD:$v" >&2; exit 12;; esac

echo "${k},${s},${v}"
SH
}

rate() { awk -v c="$1" -v t="$2" 'BEGIN{ if(t<=0){print "nan"; exit} printf "%.1f", (c/t) }'; }

# Warmup: 1s sanity checks only
info "Warmup=${WARMUP} (sanity only, not recorded)"
for _ in $(seq 1 "${WARMUP}"); do
  bench_counts_in_container ecdsap256 1 >/dev/null 2>&1 || true
  for a in mldsa44 mldsa65 falcon512 falcon1024; do
    bench_counts_in_container "$a" 1 >/dev/null 2>&1 || true
  done
done

# Main
for r in $(seq 1 "${REPEATS}"); do
  for alg in ecdsap256 mldsa44 mldsa65 falcon512 falcon1024; do
    raw="${rawdir}/rep${r}_${alg}.txt"
    info "RUN rep=${r}/${REPEATS} alg=${alg}"

    if ! bench_counts_in_container "${alg}" "${BENCH_SECONDS}" > "${raw}" 2>&1; then
      warnf "SIG_BENCH_FAILED rep=${r} alg=${alg} raw=${raw}"
      sed -n '1,120p' "${raw}" 1>&2 || true
      if [ "${STRICT}" = "1" ]; then exit 1; else continue; fi
    fi

    # First line must be counts
    line="$(grep -E '^[0-9]+,[0-9]+,[0-9]+$' "${raw}" | head -n 1 | tr -d '\r' || true)"
    if [ -z "${line}" ]; then
      warnf "COUNTS_LINE_NOT_FOUND rep=${r} alg=${alg} raw=${raw}"
      sed -n '1,120p' "${raw}" 1>&2 || true
      if [ "${STRICT}" = "1" ]; then exit 1; else continue; fi
    fi

    IFS=',' read -r kc sc vc <<<"${line}"

    keygens_s="$(rate "${kc}" "${BENCH_SECONDS}")"
    sign_s="$(rate "${sc}" "${BENCH_SECONDS}")"
    verify_s="$(rate "${vc}" "${BENCH_SECONDS}")"

    echo "  -> keygens/s=${keygens_s} sign/s=${sign_s} verify/s=${verify_s}"
    echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens_s},${sign_s},${verify_s}" >> "${csv}"
  done
done

echo
echo "CSV: ${csv}"
echo "Raw: ${rawdir}/rep*_*.txt"
echo "Warnings: ${warnlog}"
