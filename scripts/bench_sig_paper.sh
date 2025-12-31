#!/usr/bin/env bash
set -euo pipefail

# =========================
# Paper-grade Signature Speed Benchmark (FINAL, robust + fast)
# - single persistent container (docker exec) to reduce overhead
# - robust parsing:
#   * ECDSA: parse ONLY the summary table row "256 bits ecdsa ..."
#   * PQC  : parse the summary table row "<alg> ... <keygens/s> <sign/s> <verify/s>"
# - non-fatal by default (STRICT=0): never lose partial results
# =========================

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-7}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-20}"
STRICT="${STRICT:-0}"          # STRICT=1 => any parse/run failure exits non-zero
EXEC_TIMEOUT="${EXEC_TIMEOUT:-0}"  # seconds; 0 => no timeout wrapper

if [ "${MODE}" = "smoke" ]; then
  REPEATS=1
  WARMUP=1
  BENCH_SECONDS=5
fi

SIGS=("ecdsap256" "mldsa44" "mldsa65" "falcon512" "falcon1024")

mkdir -p "${RESULTS_DIR}"
rawdir="${RESULTS_DIR}/sig_speed_raw"
mkdir -p "${rawdir}"

csv="${RESULTS_DIR}/sig_speed.csv"
warnlog="${RESULTS_DIR}/sig_speed_warnings.log"
: > "${warnlog}"

# Stable CSV schema (paper-friendly + audit)
echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s,ok,err,raw_file" > "${csv}"

echo "=== Signature speed (paper-grade, FINAL) ==="
echo "mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS} STRICT=${STRICT}"
echo "IMG=${IMG}"
echo "RESULTS_DIR=${RESULTS_DIR}"
echo

export LC_ALL=C

warn() {
  local msg="$1"
  echo "[WARN] ${msg}" | tee -a "${warnlog}" 1>&2
  if [ "${STRICT}" = "1" ]; then
    exit 1
  fi
}

record_row() {
  local r="$1" alg="$2" keygens="$3" sign="$4" verify="$5" ok="$6" err="$7" raw="$8"
  err="${err//\"/\"\"}"
  raw="${raw//\"/\"\"}"
  echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens},${sign},${verify},${ok},\"${err}\",\"${raw}\"" >> "${csv}"
}

isnum() {
  local x="${1:-}"
  [[ "$x" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]
}

# Optional timeout wrapper (Linux coreutils). If unavailable, run directly.
run_with_timeout() {
  if [ "${EXEC_TIMEOUT}" != "0" ] && command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status "${EXEC_TIMEOUT}" "$@"
  else
    "$@"
  fi
}

# Start one persistent container
CID="$(docker run -d --rm -e LC_ALL=C "${IMG}" sh -lc 'sleep infinity')"
cleanup() {
  docker kill "${CID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Locate openssl inside container once
OPENSSL="$(
  docker exec "${CID}" sh -lc '
    OPENSSL=/opt/openssl/bin/openssl
    [ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
    [ -n "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }
    echo "$OPENSSL"
  '
)"

# Run commands inside container, capture to raw file
run_ecdsa_to_file() {
  local rawfile="$1"
  run_with_timeout docker exec "${CID}" sh -lc \
    "\"${OPENSSL}\" speed -seconds ${BENCH_SECONDS} -provider default ecdsa" \
    > "${rawfile}" 2>&1
}

run_pqc_to_file() {
  local alg="$1" rawfile="$2"
  run_with_timeout docker exec "${CID}" sh -lc \
    "\"${OPENSSL}\" speed -seconds ${BENCH_SECONDS} -provider oqsprovider -provider default ${alg}" \
    > "${rawfile}" 2>&1
}

# Parse ECDSA P-256 from SUMMARY TABLE ROW only:
# Example summary row:
#  256 bits ecdsa (nistp256)   0.0000s   0.0001s  43514.7  14540.3
# We take the last 2 numeric tokens => sign/s, verify/s
parse_ecdsa_p256() {
  awk '
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) }
    BEGIN{ found=0 }
    $1=="256" && $2=="bits" && tolower($3)=="ecdsa" {
      n=0
      for(i=NF;i>=1;i--){
        if(isnum($i)){
          a[2-n]=$i
          n++
          if(n==2) break
        }
      }
      if(n==2){
        found=1
        print a[1] "," a[2]
        exit
      }
    }
    END{ if(found==0) exit 1 }
  '
}

# Parse PQC summary row:
# Example:
#                     mldsa44 ... keygens/s sign/s verify/s
#                     mldsa44 0.000035s ... 28760.9 12257.1 31295.6
# We match $1==alg (case-sensitive in practice) and take last 3 numeric tokens
parse_pqc() {
  local alg="$1"
  awk -v alg="$alg" '
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) }
    BEGIN{ found=0 }
    $1==alg {
      n=0
      for(i=NF;i>=1;i--){
        if(isnum($i)){
          a[3-n]=$i
          n++
          if(n==3) break
        }
      }
      if(n==3){
        found=1
        print a[1] "," a[2] "," a[3]
        exit
      }
    }
    END{ if(found==0) exit 1 }
  '
}

# ================= warmup (not recorded) =================
echo "[INFO] warmup=${WARMUP} (not recorded)"
for _ in $(seq 1 "${WARMUP}"); do
  tmp="${rawdir}/_warmup_ecdsa.txt"
  run_ecdsa_to_file "${tmp}" >/dev/null 2>&1 || true
  for alg in "mldsa44" "mldsa65" "falcon512" "falcon1024"; do
    tmp="${rawdir}/_warmup_${alg}.txt"
    run_pqc_to_file "${alg}" "${tmp}" >/dev/null 2>&1 || true
  done
done
rm -f "${rawdir}/_warmup_"*.txt >/dev/null 2>&1 || true

# ================= main runs =================
for r in $(seq 1 "${REPEATS}"); do
  for alg in "${SIGS[@]}"; do
    rawfile="${rawdir}/rep${r}_${alg}.txt"
    echo "[RUN] rep=${r}/${REPEATS} alg=${alg}"

    if [ "${alg}" = "ecdsap256" ]; then
      if ! run_ecdsa_to_file "${rawfile}"; then
        warn "ECDSA run failed (rep=${r}). raw=${rawfile}"
        record_row "${r}" "${alg}" "" "" "" 0 "ECDSA_RUN_FAILED" "${rawfile}"
        continue
      fi

      sign="" verify=""
      if IFS=',' read -r sign verify < <(parse_ecdsa_p256 < "${rawfile}"); then
        if isnum "${sign}" && isnum "${verify}"; then
          echo "rep=${r} alg=${alg} sign/s=${sign} verify/s=${verify}"
          record_row "${r}" "${alg}" "" "${sign}" "${verify}" 1 "" "${rawfile}"
        else
          warn "ECDSA non-numeric metrics (rep=${r}). sign=${sign:-} verify=${verify:-}. raw=${rawfile}"
          record_row "${r}" "${alg}" "" "" "" 0 "ECDSA_NON_NUMERIC" "${rawfile}"
        fi
      else
        warn "ECDSA P-256 summary row not found (rep=${r}). raw=${rawfile}"
        record_row "${r}" "${alg}" "" "" "" 0 "ECDSA_ROW_NOT_FOUND" "${rawfile}"
      fi

      continue
    fi

    # PQC
    if ! run_pqc_to_file "${alg}" "${rawfile}"; then
      warn "PQC run failed alg=${alg} (rep=${r}). raw=${rawfile}"
      record_row "${r}" "${alg}" "" "" "" 0 "PQC_RUN_FAILED" "${rawfile}"
      continue
    fi

    keygens="" sign="" verify=""
    if IFS=',' read -r keygens sign verify < <(parse_pqc "${alg}" < "${rawfile}"); then
      if isnum "${keygens}" && isnum "${sign}" && isnum "${verify}"; then
        echo "rep=${r} alg=${alg} keygens/s=${keygens} sign/s=${sign} verify/s=${verify}"
        record_row "${r}" "${alg}" "${keygens}" "${sign}" "${verify}" 1 "" "${rawfile}"
      else
        warn "PQC non-numeric metrics alg=${alg} (rep=${r}). keygens=${keygens:-} sign=${sign:-} verify=${verify:-}. raw=${rawfile}"
        record_row "${r}" "${alg}" "" "" "" 0 "PQC_NON_NUMERIC" "${rawfile}"
      fi
    else
      warn "PQC summary row not found alg=${alg} (rep=${r}). raw=${rawfile}"
      record_row "${r}" "${alg}" "" "" "" 0 "PQC_ROW_NOT_FOUND" "${rawfile}"
    fi
  done
done

echo
echo "CSV: ${csv}"
echo "Raw: ${rawdir}/rep*_*.txt"
echo "Warnings: ${warnlog}"
