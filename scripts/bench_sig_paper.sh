#!/usr/bin/env bash
set -euo pipefail

# Signature micro-benchmark (paper-grade, provider-safe)
# - No openssl speed parsing (avoids output-format drift)
# - ECDSA P-256: openssl dgst -sha256 -sign/-verify
# - PQC: openssl pkeyutl -sign/-verify with oqsprovider
# - Counting: wall-clock time window (date +%s) with chunked loops to reduce date overhead
# - Output CSV schema: repeat,mode,seconds,alg,keygens_s,sign_s,verify_s

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
OUTDIR="${RESULTS_DIR}/${RUN_ID}"
rawdir="${OUTDIR}/sig_speed_raw"
mkdir -p "${rawdir}"

csv="${OUTDIR}/sig_speed.csv"
warnlog="${OUTDIR}/sig_speed_warnings.log"
: > "${warnlog}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
info(){ echo "[INFO] $(ts) $*"; }
warn(){ echo "[WARN] $(ts) $*" | tee -a "${warnlog}" 1>&2; }
die(){ echo "[ERROR] $(ts) $*" 1>&2; exit 1; }

# CSV header expected by summarize_results.py
echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s" > "${csv}"

cname="sigbench-${RUN_ID}"
cleanup(){ docker rm -f "${cname}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

info "Signature speed: mode=${MODE} run_id=${RUN_ID} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS} STRICT=${STRICT}"
info "IMG=${IMG}"
docker pull "${IMG}" >/dev/null 2>&1 || true
info "Starting long-lived container ${cname}..."
docker run -d --rm --name "${cname}" "${IMG}" sh -lc "sleep infinity" >/dev/null

# Run benchmark inside container; prints ONE line: "keygen_cnt,sign_cnt,verify_cnt"
bench_counts_in_container() {
  local alg="$1" seconds="$2"

  docker exec -i "${cname}" env ALG="${alg}" T="${seconds}" MSG_BYTES="${MSG_BYTES}" sh -s <<'SH'
set -eu

OPENSSL=/opt/openssl/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
[ -n "$OPENSSL" ] || { echo "NO_OPENSSL" >&2; exit 127; }

command -v date >/dev/null 2>&1 || { echo "NO_DATE" >&2; exit 127; }

# best-effort provider module path (oqsprovider)
if [ -z "${OPENSSL_MODULES:-}" ]; then
  for d in /usr/local/lib/ossl-modules /usr/lib/x86_64-linux-gnu/ossl-modules /opt/oqs-provider/lib; do
    if [ -f "$d/oqsprovider.so" ]; then export OPENSSL_MODULES="$d"; break; fi
  done
fi

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

PROV_DEF="-provider default"
PROV_PQC="-provider oqsprovider -provider default"

keygen_once() {
  case "$ALG" in
    ecdsap256)
      "$OPENSSL" genpkey $PROV_DEF -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$KEY" >/dev/null 2>&1
      ;;
    mldsa44|mldsa65|falcon512|falcon1024)
      "$OPENSSL" genpkey $PROV_PQC -algorithm "$ALG" -out "$KEY" >/dev/null 2>&1
      ;;
    *)
      echo "UNKNOWN_ALG:$ALG" >&2
      return 9
      ;;
  esac
}

pubout_once() {
  case "$ALG" in
    ecdsap256) "$OPENSSL" pkey $PROV_DEF -in "$KEY" -pubout -out "$PUB" >/dev/null 2>&1 ;;
    *)         "$OPENSSL" pkey $PROV_PQC -in "$KEY" -pubout -out "$PUB" >/dev/null 2>&1 ;;
  esac
}

sign_once() {
  case "$ALG" in
    ecdsap256) "$OPENSSL" dgst $PROV_DEF -sha256 -sign "$KEY" -out "$SIG" "$MSG" >/dev/null 2>&1 ;;
    *)         "$OPENSSL" pkeyutl $PROV_PQC -sign -inkey "$KEY" -in "$MSG" -out "$SIG" >/dev/null 2>&1 ;;
  esac
}

verify_once() {
  case "$ALG" in
    ecdsap256) "$OPENSSL" dgst $PROV_DEF -sha256 -verify "$PUB" -signature "$SIG" "$MSG" >/dev/null 2>&1 ;;
    *)         "$OPENSSL" pkeyutl $PROV_PQC -verify -pubin -inkey "$PUB" -in "$MSG" -sigfile "$SIG" >/dev/null 2>&1 ;;
  esac
}

# Setup sanity
keygen_once || { echo "KEYGEN_FAILED" >&2; exit 2; }
pubout_once || { echo "PUBOUT_FAILED" >&2; exit 3; }
sign_once   || { echo "SIGN_SETUP_FAILED" >&2; exit 4; }
verify_once || { echo "VERIFY_SETUP_FAILED" >&2; exit 5; }

end=$(( $(date +%s) + T ))

# Chunked loop reduces date() overhead, improves throughput accuracy
count_window() {
  which="$1"
  c=0
  while :; do
    # do a chunk of ops
    i=0
    while [ "$i" -lt 200 ]; do
      case "$which" in
        keygen) keygen_once && c=$((c+1)) || true ;;
        sign)   sign_once   && c=$((c+1)) || true ;;
        verify) verify_once && c=$((c+1)) || true ;;
      esac
      i=$((i+1))
    done
    now="$(date +%s)"
    [ "$now" -ge "$end" ] && break
  done
  echo "$c"
}

k="$(count_window keygen)"
s="$(count_window sign)"
v="$(count_window verify)"

case "$k" in (*[!0-9]*|"") echo "KEYGEN_COUNT_BAD:$k" >&2; exit 10;; esac
case "$s" in (*[!0-9]*|"") echo "SIGN_COUNT_BAD:$s" >&2; exit 11;; esac
case "$v" in (*[!0-9]*|"") echo "VERIFY_COUNT_BAD:$v" >&2; exit 12;; esac

echo "${k},${s},${v}"
SH
}

rate() { awk -v c="$1" -v t="$2" 'BEGIN{ if(t<=0){print "nan"; exit} printf "%.1f", (c/t) }'; }

# Light warmup: just ensure setup works; no timed loops
warmup_once() {
  local alg="$1"
  bench_counts_in_container "${alg}" 1 >/dev/null 2>&1 || true
}

info "Warmup=${WARMUP} (not recorded)"
for _ in $(seq 1 "${WARMUP}"); do
  warmup_once ecdsap256
  for a in mldsa44 mldsa65 falcon512 falcon1024; do warmup_once "$a"; done
done

# Main
for r in $(seq 1 "${REPEATS}"); do
  for alg in ecdsap256 mldsa44 mldsa65 falcon512 falcon1024; do
    raw="${rawdir}/rep${r}_${alg}.txt"
    info "RUN rep=${r}/${REPEATS} alg=${alg}"

    if ! bench_counts_in_container "${alg}" "${BENCH_SECONDS}" > "${raw}" 2>&1; then
      warn "SIG_BENCH_FAILED rep=${r} alg=${alg} raw=${raw}"
      sed -n '1,80p' "${raw}" 1>&2 || true
      if [ "${STRICT}" = "1" ]; then exit 1; else continue; fi
    fi

    line="$(head -n 1 "${raw}" | tr -d '\r')"
    IFS=',' read -r kc sc vc <<<"${line}" || true
    if ! [[ "${kc}" =~ ^[0-9]+$ && "${sc}" =~ ^[0-9]+$ && "${vc}" =~ ^[0-9]+$ ]]; then
      warn "NON_NUMERIC_COUNTS rep=${r} alg=${alg} line=${line} raw=${raw}"
      sed -n '1,80p' "${raw}" 1>&2 || true
      if [ "${STRICT}" = "1" ]; then exit 1; else continue; fi
    fi

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
