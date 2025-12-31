#!/usr/bin/env bash
set -euo pipefail

# Paper-grade signature benchmark (provider-safe, low-noise)
# - ECDSA: openssl dgst -sha256 -sign/-verify
# - PQC:   openssl pkeyutl -sign/-verify (oqsprovider)
# - One long-lived container for stability
# - No openssl speed dependency
# - Writes sig_speed.csv + raw logs; STRICT controls fail-fast

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"
STRICT="${STRICT:-1}"

# Message size (bytes) affects sign/verify cost; keep constant for paper
MSG_BYTES="${MSG_BYTES:-32}"

RUN_ID="${RUN_ID:-$(date -u +'%Y%m%dT%H%M%SZ')}"
OUTDIR="${RESULTS_DIR}/${RUN_ID}"
rawdir="${OUTDIR}/sig_speed_raw"
mkdir -p "${rawdir}"

csv="${OUTDIR}/sig_speed.csv"
warnlog="${OUTDIR}/sig_speed_warnings.log"
: > "${warnlog}"
echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s,ok,err,raw_file" > "${csv}"

export LC_ALL=C

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_info() { echo "[INFO] $(ts) $*"; }
log_warn() { echo "[WARN] $(ts) $*" | tee -a "${warnlog}" 1>&2; }

die_or_warn() {
  local msg="$1"
  log_warn "${msg}"
  if [ "${STRICT}" = "1" ]; then
    echo "[ERROR] $(ts) ${msg}" 1>&2
    exit 1
  fi
}

record_row() {
  local r="$1" alg="$2" keygens="$3" sign="$4" verify="$5" ok="$6" err="$7" raw="$8"
  err="${err//\"/\"\"}"
  raw="${raw//\"/\"\"}"
  echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens},${sign},${verify},${ok},\"${err}\",\"${raw}\"" >> "${csv}"
}

rate() {
  # count seconds -> prints rate with 1 decimal
  local count="$1" secs="$2"
  awk -v c="${count}" -v t="${secs}" 'BEGIN{ if(t<=0){print "nan"; exit} printf "%.1f", (c/t) }'
}

# ---------- container lifecycle ----------
cname="sigbench-${RUN_ID}"

log_info "Signature speed: mode=${MODE} run_id=${RUN_ID} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS} STRICT=${STRICT}"
log_info "IMG=${IMG}"
log_info "Pulling image once..."
docker pull "${IMG}" >/dev/null 2>&1 || true

cleanup() { docker rm -f "${cname}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log_info "Starting long-lived container ${cname}..."
docker run -d --rm --name "${cname}" "${IMG}" sh -lc "sleep infinity" >/dev/null

exec_in_container() {
  docker exec -i "${cname}" sh -s
}

# bench one algorithm inside container; prints "keygen_cnt,sign_cnt,verify_cnt"
bench_alg_counts() {
  local alg="$1"

  exec_in_container <<SH
set -eu

OPENSSL=/opt/openssl/bin/openssl
[ -x "\$OPENSSL" ] || OPENSSL="\$(command -v openssl || true)"
[ -n "\$OPENSSL" ] || { echo "NO_OPENSSL" >&2; exit 127; }

command -v timeout >/dev/null 2>&1 || { echo "NO_TIMEOUT" >&2; exit 127; }

# Best-effort: ensure module path if present (helps some images)
if [ -z "\${OPENSSL_MODULES:-}" ]; then
  if [ -d /opt/oqs-provider/lib ]; then export OPENSSL_MODULES=/opt/oqs-provider/lib; fi
  if [ -d /usr/local/lib/ossl-modules ]; then export OPENSSL_MODULES=/usr/local/lib/ossl-modules; fi
fi

ALG="${alg}"
T="${BENCH_SECONDS}"
MSG_BYTES="${MSG_BYTES}"

WORK="/tmp/sigbench_\$ALG"
mkdir -p "\$WORK"
KEY="\$WORK/key.pem"
PUB="\$WORK/pub.pem"
MSG="\$WORK/msg.bin"
SIG="\$WORK/sig.bin"

# fixed-size message
# (dd avoids head portability issues)
dd if=/dev/zero of="\$MSG" bs="\$MSG_BYTES" count=1 2>/dev/null

# provider args and commands
PROV_DEFAULT="-provider default"
PROV_PQC="-provider oqsprovider -provider default"

# --- keygen + pubout + baseline signature (one-time) ---
case "\$ALG" in
  ecdsap256)
    # Keygen
    "\$OPENSSL" genpkey \$PROV_DEFAULT -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "\$KEY" >/dev/null 2>&1 || { echo "KEYGEN_FAILED" >&2; exit 2; }
    "\$OPENSSL" pkey \$PROV_DEFAULT -in "\$KEY" -pubout -out "\$PUB" >/dev/null 2>&1 || { echo "PUBOUT_FAILED" >&2; exit 3; }
    # Baseline sign/verify check
    "\$OPENSSL" dgst \$PROV_DEFAULT -sha256 -sign "\$KEY" -out "\$SIG" "\$MSG" >/dev/null 2>&1 || { echo "SIGN_SETUP_FAILED" >&2; exit 4; }
    "\$OPENSSL" dgst \$PROV_DEFAULT -sha256 -verify "\$PUB" -signature "\$SIG" "\$MSG" >/dev/null 2>&1 || { echo "VERIFY_SETUP_FAILED" >&2; exit 5; }
    ;;
  mldsa44|mldsa65|falcon512|falcon1024)
    "\$OPENSSL" genpkey \$PROV_PQC -algorithm "\$ALG" -out "\$KEY" >/dev/null 2>&1 || { echo "KEYGEN_FAILED" >&2; exit 2; }
    "\$OPENSSL" pkey \$PROV_PQC -in "\$KEY" -pubout -out "\$PUB" >/dev/null 2>&1 || { echo "PUBOUT_FAILED" >&2; exit 3; }
    "\$OPENSSL" pkeyutl \$PROV_PQC -sign -inkey "\$KEY" -in "\$MSG" -out "\$SIG" >/dev/null 2>&1 || { echo "SIGN_SETUP_FAILED" >&2; exit 4; }
    "\$OPENSSL" pkeyutl \$PROV_PQC -verify -pubin -inkey "\$PUB" -in "\$MSG" -sigfile "\$SIG" >/dev/null 2>&1 || { echo "VERIFY_SETUP_FAILED" >&2; exit 5; }
    ;;
  *)
    echo "UNKNOWN_ALG:\$ALG" >&2
    exit 9
    ;;
esac

# --- 1) keygen count (overwrite KEY) ---
KEYGEN_COUNT="\$(
  timeout -k 2 "\$T" sh -s <<'EOS' || true
set -eu
c=0
trap 'echo $c; exit 0' TERM INT
while :; do
  # ALG and OPENSSL/PROV/KEY are inherited from parent shell via env expansion in outer scope
  c=$((c+1))
done
EOS
)"

# We need a separate timeout script per ALG to avoid eval; implement via case duplication:
KEYGEN_COUNT="\$(
  timeout -k 2 "\$T" sh -s <<EOS || true
set -eu
OPENSSL="\$OPENSSL"
ALG="\$ALG"
KEY="\$KEY"
PROV_DEFAULT="\$PROV_DEFAULT"
PROV_PQC="\$PROV_PQC"
c=0
trap 'echo \$c; exit 0' TERM INT
while :; do
  case "\$ALG" in
    ecdsap256)
      "\$OPENSSL" genpkey \$PROV_DEFAULT -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "\$KEY" >/dev/null 2>&1
      ;;
    *)
      "\$OPENSSL" genpkey \$PROV_PQC -algorithm "\$ALG" -out "\$KEY" >/dev/null 2>&1
      ;;
  esac
  c=\$((c+1))
done
EOS
)"

# --- 2) sign count (overwrite SIG) ---
SIGN_COUNT="\$(
  timeout -k 2 "\$T" sh -s <<EOS || true
set -eu
OPENSSL="\$OPENSSL"
ALG="\$ALG"
KEY="\$KEY"
PUB="\$PUB"
MSG="\$MSG"
SIG="\$SIG"
PROV_DEFAULT="\$PROV_DEFAULT"
PROV_PQC="\$PROV_PQC"
c=0
trap 'echo \$c; exit 0' TERM INT
while :; do
  case "\$ALG" in
    ecdsap256)
      "\$OPENSSL" dgst \$PROV_DEFAULT -sha256 -sign "\$KEY" -out "\$SIG" "\$MSG" >/dev/null 2>&1
      ;;
    *)
      "\$OPENSSL" pkeyutl \$PROV_PQC -sign -inkey "\$KEY" -in "\$MSG" -out "\$SIG" >/dev/null 2>&1
      ;;
  esac
  c=\$((c+1))
done
EOS
)"

# --- 3) verify count ---
VERIFY_COUNT="\$(
  timeout -k 2 "\$T" sh -s <<EOS || true
set -eu
OPENSSL="\$OPENSSL"
ALG="\$ALG"
KEY="\$KEY"
PUB="\$PUB"
MSG="\$MSG"
SIG="\$SIG"
PROV_DEFAULT="\$PROV_DEFAULT"
PROV_PQC="\$PROV_PQC"
c=0
trap 'echo \$c; exit 0' TERM INT
while :; do
  case "\$ALG" in
    ecdsap256)
      "\$OPENSSL" dgst \$PROV_DEFAULT -sha256 -verify "\$PUB" -signature "\$SIG" "\$MSG" >/dev/null 2>&1
      ;;
    *)
      "\$OPENSSL" pkeyutl \$PROV_PQC -verify -pubin -inkey "\$PUB" -in "\$MSG" -sigfile "\$SIG" >/dev/null 2>&1
      ;;
  esac
  c=\$((c+1))
done
EOS
)"

# validate numeric
case "\$KEYGEN_COUNT" in (*[!0-9]*|"") echo "KEYGEN_COUNT_BAD:\$KEYGEN_COUNT" >&2; exit 10;; esac
case "\$SIGN_COUNT" in (*[!0-9]*|"") echo "SIGN_COUNT_BAD:\$SIGN_COUNT" >&2; exit 11;; esac
case "\$VERIFY_COUNT" in (*[!0-9]*|"") echo "VERIFY_COUNT_BAD:\$VERIFY_COUNT" >&2; exit 12;; esac

echo "\$KEYGEN_COUNT,\$SIGN_COUNT,\$VERIFY_COUNT"
SH
}

# ---------- warmup ----------
log_info "Warmup=${WARMUP} (not recorded)"
for _ in $(seq 1 "${WARMUP}"); do
  bench_alg_counts "ecdsap256" >/dev/null 2>&1 || true
  for a in mldsa44 mldsa65 falcon512 falcon1024; do
    bench_alg_counts "$a" >/dev/null 2>&1 || true
  done
done

# ---------- main ----------
for r in $(seq 1 "${REPEATS}"); do
  for alg in ecdsap256 mldsa44 mldsa65 falcon512 falcon1024; do
    rawfile="${rawdir}/rep${r}_${alg}.txt"
    log_info "RUN rep=${r}/${REPEATS} alg=${alg}"

    out=""
    if ! out="$(bench_alg_counts "${alg}" 2>&1)"; then
      printf "%s\n" "${out}" > "${rawfile}"
      die_or_warn "SIG_BENCH_FAILED rep=${r} alg=${alg} raw=${rawfile} out=$(printf "%s" "${out}" | head -c 240)"
      record_row "${r}" "${alg}" "" "" "" 0 "SIG_BENCH_FAILED" "${rawfile}"
      continue
    fi

    printf "%s\n" "${out}" > "${rawfile}"

    IFS=',' read -r keygen_cnt sign_cnt verify_cnt <<<"${out}" || true
    if ! [[ "${keygen_cnt}" =~ ^[0-9]+$ && "${sign_cnt}" =~ ^[0-9]+$ && "${verify_cnt}" =~ ^[0-9]+$ ]]; then
      die_or_warn "NON_NUMERIC_COUNTS rep=${r} alg=${alg} out=${out} raw=${rawfile}"
      record_row "${r}" "${alg}" "" "" "" 0 "NON_NUMERIC_COUNTS" "${rawfile}"
      continue
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
