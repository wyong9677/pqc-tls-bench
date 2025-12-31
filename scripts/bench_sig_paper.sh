#!/usr/bin/env bash
set -euo pipefail

# Paper-grade signature benchmark (robust, provider-safe)
# - No openssl speed (not reliable for 3rd-party provider algs)
# - ECDSA P-256: openssl dgst -sha256 -sign/-verify
# - PQC: openssl pkeyutl -sign/-verify with oqsprovider
# - Counting uses wall-clock time window with `date +%s` (portable; no timeout/trap quirks)
# - Warmup is light (few operations), not timed
# - Writes sig_speed.csv + raw logs; STRICT controls fail-fast

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

RUN_ID="${RUN_ID:-$(date -u +'%Y%m%dT%H%M%SZ')}"
OUTDIR="${RESULTS_DIR}/${RUN_ID}"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"
STRICT="${STRICT:-1}"

# message size (bytes), keep constant for paper
MSG_BYTES="${MSG_BYTES:-32}"

rawdir="${OUTDIR}/sig_speed_raw"
mkdir -p "${rawdir}"

csv="${OUTDIR}/sig_speed.csv"
warnlog="${OUTDIR}/sig_speed_warnings.log"
: > "${warnlog}"
echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s,ok,err,raw_file" > "${csv}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
info() { echo "[INFO] $(ts) $*"; }
warn() { echo "[WARN] $(ts) $*" | tee -a "${warnlog}" 1>&2; }

record_row() {
  local r="$1" alg="$2" keygens="$3" sign="$4" verify="$5" ok="$6" err="$7" raw="$8"
  err="${err//\"/\"\"}"
  raw="${raw//\"/\"\"}"
  echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens},${sign},${verify},${ok},\"${err}\",\"${raw}\"" >> "${csv}"
}

rate() {
  local count="$1" secs="$2"
  awk -v c="${count}" -v t="${secs}" 'BEGIN{ if(t<=0){print "nan"; exit} printf "%.1f", (c/t) }'
}

die_or_warn() {
  local msg="$1"
  warn "${msg}"
  if [ "${STRICT}" = "1" ]; then
    echo "[ERROR] $(ts) ${msg}" 1>&2
    exit 1
  fi
}

# --- container lifecycle ---
cname="sigbench-${RUN_ID}"

info "Signature speed: mode=${MODE} run_id=${RUN_ID} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS} STRICT=${STRICT}"
info "IMG=${IMG}"
info "Pulling image once..."
docker pull "${IMG}" >/dev/null 2>&1 || true

cleanup() { docker rm -f "${cname}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

info "Starting long-lived container ${cname}..."
docker run -d --rm --name "${cname}" "${IMG}" sh -lc "sleep infinity" >/dev/null

# run in container (stdin script)
exec_in_container() {
  docker exec -i "${cname}" sh -s
}

# container-side benchmark: print "keygen_cnt,sign_cnt,verify_cnt"
# Uses date-based end time; counts only successful ops.
bench_counts() {
  local alg="$1"
  local seconds="$2"

  docker exec -i "${cname}" env ALG="${alg}" T="${seconds}" MSG_BYTES="${MSG_BYTES}" sh -s <<'SH'
set -eu

OPENSSL=/opt/openssl/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
[ -n "$OPENSSL" ] || { echo "NO_OPENSSL" >&2; exit 127; }

# ensure date exists
command -v date >/dev/null 2>&1 || { echo "NO_DATE" >&2; exit 127; }

# best-effort provider module path
if [ -z "${OPENSSL_MODULES:-}" ]; then
  [ -d /usr/local/lib/ossl-modules ] && export OPENSSL_MODULES=/usr/local/lib/ossl-modules
  [ -d /opt/oqs-provider/lib ] && export OPENSSL_MODULES=/opt/oqs-provider/lib
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

# fixed-size msg
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
    ecdsap256)
      "$OPENSSL" pkey $PROV_DEF -in "$KEY" -pubout -out "$PUB" >/dev/null 2>&1
      ;;
    *)
      "$OPENSSL" pkey $PROV_PQC -in "$KEY" -pubout -out "$PUB" >/dev/null 2>&1
      ;;
  esac
}

sign_once() {
  case "$ALG" in
    ecdsap256)
      "$OPENSSL" dgst $PROV_DEF -sha256 -sign "$KEY" -out "$SIG" "$MSG" >/dev/null 2>&1
      ;;
    *)
      "$OPENSSL" pkeyutl $PROV_PQC -sign -inkey "$KEY" -in "$MSG" -out "$SIG" >/dev/null 2>&1
      ;;
  esac
}

verify_once() {
  case "$ALG" in
    ecdsap256)
      "$OPENSSL" dgst $PROV_DEF -sha256 -verify "$PUB" -signature "$SIG" "$MSG" >/dev/null 2>&1
      ;;
    *)
      "$OPENSSL" pkeyutl $PROV_PQC -verify -pubin -inkey "$PUB" -in "$MSG" -sigfile "$SIG" >/dev/null 2>&1
      ;;
  esac
}

# setup sanity once
keygen_once || { echo "KEYGEN_FAILED" >&2; exit 2; }
pubout_once || { echo "PUBOUT_FAILED" >&2; exit 3; }
sign_once   || { echo "SIGN_SETUP_FAILED" >&2; exit 4; }
verify_once || { echo "VERIFY_SETUP_FAILED" >&2; exit 5; }

end_epoch=$(( $(date +%s) + T ))

count_window() {
  which="$1"
  c=0
  # loop until end time
  while [ "$(date +%s)" -lt "$end_epoch" ]; do
    if [ "$which" = "keygen" ]; then
      keygen_once && c=$((c+1)) || true
    elif [ "$which" = "sign" ]; then
      sign_once && c=$((c+1)) || true
    else
      verify_once && c=$((c+1)) || true
    fi
  done
  echo "$c"
}

keygen_cnt="$(count_window keygen)"
sign_cnt="$(count_window sign)"
verify_cnt="$(count_window verify)"

# validate numeric
case "$keygen_cnt" in (*[!0-9]*|"") echo "KEYGEN_COUNT_BAD:$keygen_cnt" >&2; exit 10;; esac
case "$sign_cnt"   in (*[!0-9]*|"") echo "SIGN_COUNT_BAD:$sign_cnt" >&2; exit 11;; esac
case "$verify_cnt" in (*[!0-9]*|"") echo "VERIFY_COUNT_BAD:$verify_cnt" >&2; exit 12;; esac

echo "${keygen_cnt},${sign_cnt},${verify_cnt}"
SH
}

# light warmup: just ensure primitives work (no timing)
warmup_once() {
  local alg="$1"
  exec_in_container <<SH >/dev/null 2>&1 || true
set -eu
OPENSSL=/opt/openssl/bin/openssl
[ -x "\$OPENSSL" ] || OPENSSL="\$(command -v openssl || true)"
[ -n "\$OPENSSL" ] || exit 0
ALG="${alg}"
WORK="/tmp/sigwarm_\$ALG"
mkdir -p "\$WORK"
KEY="\$WORK/key.pem"; PUB="\$WORK/pub.pem"; MSG="\$WORK/msg.bin"; SIG="\$WORK/sig.bin"
dd if=/dev/zero of="\$MSG" bs="${MSG_BYTES}" count=1 2>/dev/null
PROV_DEF="-provider default"
PROV_PQC="-provider oqsprovider -provider default"
if [ "\$ALG" = "ecdsap256" ]; then
  "\$OPENSSL" genpkey \$PROV_DEF -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "\$KEY" >/dev/null 2>&1 || exit 0
  "\$OPENSSL" pkey \$PROV_DEF -in "\$KEY" -pubout -out "\$PUB" >/dev/null 2>&1 || exit 0
  "\$OPENSSL" dgst \$PROV_DEF -sha256 -sign "\$KEY" -out "\$SIG" "\$MSG" >/dev/null 2>&1 || exit 0
  "\$OPENSSL" dgst \$PROV_DEF -sha256 -verify "\$PUB" -signature "\$SIG" "\$MSG" >/dev/null 2>&1 || exit 0
else
  "\$OPENSSL" genpkey \$PROV_PQC -algorithm "\$ALG" -out "\$KEY" >/dev/null 2>&1 || exit 0
  "\$OPENSSL" pkey \$PROV_PQC -in "\$KEY" -pubout -out "\$PUB" >/dev/null 2>&1 || exit 0
  "\$OPENSSL" pkeyutl \$PROV_PQC -sign -inkey "\$KEY" -in "\$MSG" -out "\$SIG" >/dev/null 2>&1 || exit 0
  "\$OPENSSL" pkeyutl \$PROV_PQC -verify -pubin -inkey "\$PUB" -in "\$MSG" -sigfile "\$SIG" >/dev/null 2>&1 || exit 0
fi
SH
}

# ---------- warmup ----------
info "Warmup=${WARMUP} (not recorded)"
for _ in $(seq 1 "${WARMUP}"); do
  warmup_once "ecdsap256"
  for a in mldsa44 mldsa65 falcon512 falcon1024; do warmup_once "$a"; done
done

# ---------- main ----------
for r in $(seq 1 "${REPEATS}"); do
  for alg in ecdsap256 mldsa44 mldsa65 falcon512 falcon1024; do
    rawfile="${rawdir}/rep${r}_${alg}.txt"
    info "RUN rep=${r}/${REPEATS} alg=${alg}"

    if ! bench_counts "${alg}" "${BENCH_SECONDS}" > "${rawfile}" 2>&1; then
      warn "SIG_BENCH_FAILED rep=${r} alg=${alg} raw=${rawfile}"
      sed -n '1,60p' "${rawfile}" 1>&2 || true
      record_row "${r}" "${alg}" "" "" "" 0 "SIG_BENCH_FAILED" "${rawfile}"
      if [ "${STRICT}" = "1" ]; then exit 1; else continue; fi
    fi

    out="$(head -n 1 "${rawfile}" | tr -d '\r')"
    IFS=',' read -r keygen_cnt sign_cnt verify_cnt <<<"${out}" || true
    if ! [[ "${keygen_cnt}" =~ ^[0-9]+$ && "${sign_cnt}" =~ ^[0-9]+$ && "${verify_cnt}" =~ ^[0-9]+$ ]]; then
      warn "NON_NUMERIC_COUNTS rep=${r} alg=${alg} out=${out} raw=${rawfile}"
      record_row "${r}" "${alg}" "" "" "" 0 "NON_NUMERIC_COUNTS" "${rawfile}"
      if [ "${STRICT}" = "1" ]; then exit 1; else continue; fi
    fi

    keygens_s="$(rate "${keygen_cnt}" "${BENCH_SECONDS}")"
    sign_s="$(rate "${sign_cnt}" "${BENCH_SECONDS}")"
    verify_s="$(rate "${verify_cnt}" "${BENCH_SECONDS}")"

    echo "  -> keygens/s=${keygens_s} sign/s=${sign_s} verify/s=${verify_s}"
    record_row "${r}" "${alg}" "${keygens_s}" "${sign_s}" "${verify_s}" 1 "" "${rawfile}"
  done
done

echo
echo "CSV: ${csv}"
echo "Raw: ${rawdir}/rep*_*.txt"
echo "Warnings: ${warnlog}"
