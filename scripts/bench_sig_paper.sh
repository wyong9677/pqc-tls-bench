#!/usr/bin/env bash
set -euo pipefail

# ========= Paper-grade Signature Benchmark (Robust + Provider-safe) =========
# - No openssl speed
# - ECDSA P-256: openssl dgst -sha256 -sign/-verify
# - PQC: openssl pkeyutl -sign/-verify with oqsprovider
# - One long-lived container
# - Every run writes raw stdout/stderr for forensics
# - STRICT=1 fails fast with raw excerpt
# ==========================================================================

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"
STRICT="${STRICT:-1}"

# message size in bytes (keep constant for paper)
MSG_BYTES="${MSG_BYTES:-32}"

RUN_ID="${RUN_ID:-$(date -u +'%Y%m%dT%H%M%SZ')}"
OUTDIR="${RESULTS_DIR}/${RUN_ID}"
rawdir="${OUTDIR}/sig_speed_raw"
mkdir -p "${rawdir}"

csv="${OUTDIR}/sig_speed.csv"
warnlog="${OUTDIR}/sig_speed_warnings.log"
: > "${warnlog}"
echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s,ok,err,raw_file" > "${csv}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
info() { echo "[INFO] $(ts) $*"; }
warn() { echo "[WARN] $(ts) $*" | tee -a "${warnlog}" 1>&2; }

# host-side error trap (gives line + last command)
trap 'rc=$?; echo "[ERROR] $(ts) bench_sig_paper.sh failed rc=${rc} at line ${LINENO}: ${BASH_COMMAND}" 1>&2; exit $rc' ERR

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

# Run one alg once inside container and print counts "keygen,sign,verify"
# All stderr is preserved; caller should tee to raw file for visibility.
run_counts_in_container() {
  local alg="$1"
  docker exec -i "${cname}" env ALG="${alg}" T="${BENCH_SECONDS}" MSG_BYTES="${MSG_BYTES}" sh -s <<'SH'
set -eu

OPENSSL=/opt/openssl/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
[ -n "$OPENSSL" ] || { echo "NO_OPENSSL" >&2; exit 127; }
command -v timeout >/dev/null 2>&1 || { echo "NO_TIMEOUT" >&2; exit 127; }

# try to set OPENSSL_MODULES if image uses non-default module path
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

# fixed message
dd if=/dev/zero of="$MSG" bs="$MSG_BYTES" count=1 2>/dev/null

PROV_DEF="-provider default"
PROV_PQC="-provider oqsprovider -provider default"

keygen_once() {
  case "$ALG" in
    ecdsap256)
      "$OPENSSL" genpkey $PROV_DEF -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$KEY"
      ;;
    mldsa44|mldsa65|falcon512|falcon1024)
      "$OPENSSL" genpkey $PROV_PQC -algorithm "$ALG" -out "$KEY"
      ;;
    *)
      echo "UNKNOWN_ALG:$ALG" >&2; return 9
      ;;
  esac
}

pubout_once() {
  case "$ALG" in
    ecdsap256) "$OPENSSL" pkey $PROV_DEF -in "$KEY" -pubout -out "$PUB" ;;
    *)         "$OPENSSL" pkey $PROV_PQC -in "$KEY" -pubout -out "$PUB" ;;
  esac
}

sign_once() {
  case "$ALG" in
    ecdsap256) "$OPENSSL" dgst $PROV_DEF -sha256 -sign "$KEY" -out "$SIG" "$MSG" ;;
    *)         "$OPENSSL" pkeyutl $PROV_PQC -sign -inkey "$KEY" -in "$MSG" -out "$SIG" ;;
  esac
}

verify_once() {
  case "$ALG" in
    ecdsap256) "$OPENSSL" dgst $PROV_DEF -sha256 -verify "$PUB" -signature "$SIG" "$MSG" ;;
    *)         "$OPENSSL" pkeyutl $PROV_PQC -verify -pubin -inkey "$PUB" -in "$MSG" -sigfile "$SIG" ;;
  esac
}

# setup sanity
keygen_once >/dev/null 2>&1 || { echo "KEYGEN_FAILED" >&2; exit 2; }
pubout_once >/dev/null 2>&1 || { echo "PUBOUT_FAILED" >&2; exit 3; }
sign_once   >/dev/null 2>&1 || { echo "SIGN_SETUP_FAILED" >&2; exit 4; }
verify_once >/dev/null 2>&1 || { echo "VERIFY_SETUP_FAILED" >&2; exit 5; }

count_loop() {
  # arg1: which=keygen|sign|verify
  which="$1"
  timeout -k 2 "$T" sh -c '
    set -eu
    c=0
    trap "echo $c; exit 0" TERM INT
    while :; do
      case "'"$which"'" in
        keygen) keygen_once >/dev/null 2>&1 ;;
        sign)   sign_once   >/dev/null 2>&1 ;;
        verify) verify_once >/dev/null 2>&1 ;;
      esac
      c=$((c+1))
    done
  ' 2>/dev/null || true
}

# Export functions into subshell environment for timeout sh -c
# POSIX sh doesn't export functions; so we inline by re-defining for each loop using here-doc:
count_keygen() {
  timeout -k 2 "$T" sh -s <<'EOS' || true
set -eu
c=0
trap 'echo $c; exit 0' TERM INT
while :; do
  keygen_once >/dev/null 2>&1
  c=$((c+1))
done
EOS
}

count_sign() {
  timeout -k 2 "$T" sh -s <<'EOS' || true
set -eu
c=0
trap 'echo $c; exit 0' TERM INT
while :; do
  sign_once >/dev/null 2>&1
  c=$((c+1))
done
EOS
}

count_verify() {
  timeout -k 2 "$T" sh -s <<'EOS' || true
set -eu
c=0
trap 'echo $c; exit 0' TERM INT
while :; do
  verify_once >/dev/null 2>&1
  c=$((c+1))
done
EOS
}

# BUT: the above subshells cannot see shell functions (keygen_once/sign_once/verify_once).
# So we do counts in THIS shell (no extra sh -s), using timeout to stop the loop:
count_in_this_shell() {
  which="$1"
  c=0
  trap 'echo $c; exit 0' TERM INT
  while :; do
    case "$which" in
      keygen) keygen_once >/dev/null 2>&1 ;;
      sign)   sign_once   >/dev/null 2>&1 ;;
      verify) verify_once >/dev/null 2>&1 ;;
    esac
    c=$((c+1))
  done
}

# run the loops in this shell, terminated by timeout sending TERM
KEYGEN_COUNT="$(timeout -k 2 "$T" sh -c 'kill -TERM $$' >/dev/null 2>&1 & timeout_pid=$!; wait $timeout_pid 2>/dev/null || true; )"
# The above doesn't actually run the loop. So instead: run timeout directly on this shell script:
# We emulate by running a child shell that contains the loop fully (with functions), using a single script block.

count_block() {
  which="$1"
  timeout -k 2 "$T" sh -s <<EOS || true
set -eu
OPENSSL="$OPENSSL"
ALG="$ALG"
KEY="$KEY"
PUB="$PUB"
MSG="$MSG"
SIG="$SIG"
PROV_DEF="$PROV_DEF"
PROV_PQC="$PROV_PQC"

keygen_once() {
  case "\$ALG" in
    ecdsap256) "\$OPENSSL" genpkey \$PROV_DEF -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "\$KEY" ;;
    *)         "\$OPENSSL" genpkey \$PROV_PQC -algorithm "\$ALG" -out "\$KEY" ;;
  esac
}
pubout_once() {
  case "\$ALG" in
    ecdsap256) "\$OPENSSL" pkey \$PROV_DEF -in "\$KEY" -pubout -out "\$PUB" ;;
    *)         "\$OPENSSL" pkey \$PROV_PQC -in "\$KEY" -pubout -out "\$PUB" ;;
  esac
}
sign_once() {
  case "\$ALG" in
    ecdsap256) "\$OPENSSL" dgst \$PROV_DEF -sha256 -sign "\$KEY" -out "\$SIG" "\$MSG" ;;
    *)         "\$OPENSSL" pkeyutl \$PROV_PQC -sign -inkey "\$KEY" -in "\$MSG" -out "\$SIG" ;;
  esac
}
verify_once() {
  case "\$ALG" in
    ecdsap256) "\$OPENSSL" dgst \$PROV_DEF -sha256 -verify "\$PUB" -signature "\$SIG" "\$MSG" ;;
    *)         "\$OPENSSL" pkeyutl \$PROV_PQC -verify -pubin -inkey "\$PUB" -in "\$MSG" -sigfile "\$SIG" ;;
  esac
}

# ensure inputs exist
[ -s "\$MSG" ] || exit 20
[ -s "\$KEY" ] || exit 21
[ -s "\$PUB" ] || exit 22
[ -s "\$SIG" ] || exit 23

c=0
trap 'echo \$c; exit 0' TERM INT
while :; do
  case "${which}" in
    keygen) keygen_once >/dev/null 2>&1 ;;
    sign)   sign_once   >/dev/null 2>&1 ;;
    verify) verify_once >/dev/null 2>&1 ;;
  esac
  c=\$((c+1))
done
EOS
}

KEYGEN_COUNT="$(count_block keygen)"
SIGN_COUNT="$(count_block sign)"
VERIFY_COUNT="$(count_block verify)"

case "$KEYGEN_COUNT" in (*[!0-9]*|"") echo "KEYGEN_COUNT_BAD:$KEYGEN_COUNT" >&2; exit 10;; esac
case "$SIGN_COUNT"   in (*[!0-9]*|"") echo "SIGN_COUNT_BAD:$SIGN_COUNT" >&2; exit 11;; esac
case "$VERIFY_COUNT" in (*[!0-9]*|"") echo "VERIFY_COUNT_BAD:$VERIFY_COUNT" >&2; exit 12;; esac

echo "${KEYGEN_COUNT},${SIGN_COUNT},${VERIFY_COUNT}"
SH
}

# ---------- warmup ----------
info "Warmup=${WARMUP} (not recorded)"
for _ in $(seq 1 "${WARMUP}"); do
  run_counts_in_container "ecdsap256" >/dev/null 2>&1 || true
  for a in mldsa44 mldsa65 falcon512 falcon1024; do
    run_counts_in_container "$a" >/dev/null 2>&1 || true
  done
done

# ---------- main ----------
for r in $(seq 1 "${REPEATS}"); do
  for alg in ecdsap256 mldsa44 mldsa65 falcon512 falcon1024; do
    rawfile="${rawdir}/rep${r}_${alg}.txt"
    info "RUN rep=${r}/${REPEATS} alg=${alg}"

    # capture both stdout+stderr to raw
    if ! run_counts_in_container "${alg}" > "${rawfile}" 2>&1; then
      # show excerpt to action logs
      warn "SIG_BENCH_FAILED rep=${r} alg=${alg} raw=${rawfile}"
      sed -n '1,40p' "${rawfile}" 1>&2 || true
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
