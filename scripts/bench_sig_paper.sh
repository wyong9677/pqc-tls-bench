#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# Paper-grade Signature Speed Benchmark (FINAL, optimized)
# - single docker container for the whole run (fast, no 36min stall)
# - streaming logs (CI won't think it's stuck)
# - robust parsing for OpenSSL 3.x / oqsprovider output
# - non-fatal by default (STRICT=0): write ok/err to CSV + warnings.log
# ==========================================================

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-7}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-20}"
STRICT="${STRICT:-0}"   # STRICT=1 => fail on any parse/metric issue

if [ "${MODE}" = "smoke" ]; then
  REPEATS=1
  WARMUP=1
  BENCH_SECONDS=5
fi

# Baseline + PQC
SIGS=("ecdsap256" "mldsa44" "mldsa65" "falcon512" "falcon1024")

mkdir -p "${RESULTS_DIR}"
rawdir="${RESULTS_DIR}/sig_speed_raw"
mkdir -p "${rawdir}"

csv="${RESULTS_DIR}/sig_speed.csv"
warnlog="${RESULTS_DIR}/sig_speed_warnings.log"
: > "${warnlog}"

# Stable CSV schema (paper/reproducibility)
echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s,ok,err,raw_file" > "${csv}"

echo "=== Signature speed (paper-grade, FINAL optimized) ==="
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

csv_escape() {
  # escape double quotes for CSV quoted fields
  local s="$1"
  s="${s//\"/\"\"}"
  printf "%s" "$s"
}

record_row() {
  local r="$1" alg="$2" keygens="$3" sign="$4" verify="$5" ok="$6" err="$7" raw="$8"
  err="$(csv_escape "$err")"
  raw="$(csv_escape "$raw")"
  # keygens/sign/verify: keep blank if unavailable (better than NaN for papers)
  echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens},${sign},${verify},${ok},\"${err}\",\"${raw}\"" >> "${csv}"
}

isnum() {
  local x="${1:-}"
  [[ "$x" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]
}

# ----- Run everything inside ONE container (fast) -----
# We mount RESULTS_DIR to /out and write raw logs there.
docker run --rm \
  -e "LC_ALL=C" \
  -e "BENCH_SECONDS=${BENCH_SECONDS}" \
  -e "REPEATS=${REPEATS}" \
  -e "WARMUP=${WARMUP}" \
  -e "MODE=${MODE}" \
  -v "$(cd "${RESULTS_DIR}" && pwd)":/out \
  "${IMG}" \
  sh -lc '
set -eu

export LC_ALL=C
BENCH_SECONDS="${BENCH_SECONDS}"
REPEATS="${REPEATS}"
WARMUP="${WARMUP}"
MODE="${MODE}"

RAW_DIR=/out/sig_speed_raw
mkdir -p "$RAW_DIR"

OPENSSL=/opt/openssl/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
[ -n "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }

# Use timeout if available to prevent pathological hangs
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    # wall timeout: BENCH_SECONDS + 30s buffer
    timeout "$((BENCH_SECONDS+30))" "$@"
  else
    "$@"
  fi
}

run_ecdsa() {
  # Always use "ecdsa" table output; parse nistp256 line outside container.
  run_with_timeout "$OPENSSL" speed -seconds "$BENCH_SECONDS" -provider default ecdsa 2>&1
}

run_pqc() {
  alg="$1"
  run_with_timeout "$OPENSSL" speed -seconds "$BENCH_SECONDS" -provider oqsprovider -provider default "$alg" 2>&1
}

# Warmup (not recorded)
i=1
while [ "$i" -le "$WARMUP" ]; do
  run_ecdsa >/dev/null 2>&1 || true
  for alg in mldsa44 mldsa65 falcon512 falcon1024; do
    run_pqc "$alg" >/dev/null 2>&1 || true
  done
  i=$((i+1))
done

# Main runs: write raw logs; host parses them and writes CSV
r=1
while [ "$r" -le "$REPEATS" ]; do
  # ECDSA
  echo "[RUN] rep=$r alg=ecdsap256"
  run_ecdsa | tee "$RAW_DIR/rep${r}_ecdsap256.txt" >/dev/null || true

  # PQC
  for alg in mldsa44 mldsa65 falcon512 falcon1024; do
    echo "[RUN] rep=$r alg=$alg"
    run_pqc "$alg" | tee "$RAW_DIR/rep${r}_${alg}.txt" >/dev/null || true
  done

  r=$((r+1))
done
'

# ----- Host-side parsing (robust) -----
# Parse ECDSA P-256 line (nistp256): take the last 2 numeric tokens on that line.
parse_ecdsa_p256_from_file() {
  awk '
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) }
    /ecdsa/ && /nistp256/ {
      n=0
      for(i=NF;i>=1;i--){
        if(isnum($i)){
          a[2-n]=$i
          n++
          if(n==2) break
        }
      }
      if(n==2){ print a[1] "," a[2]; exit 0 }
    }
    END{ exit 1 }
  ' "$1"
}

# Parse PQC alg row: match first field == alg; take last 3 numeric tokens on that line.
parse_pqc_from_file() {
  local alg="$1" file="$2"
  awk -v alg="$alg" '
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) }
    $1==alg {
      n=0
      for(i=NF;i>=1;i--){
        if(isnum($i)){
          a[3-n]=$i
          n++
          if(n==3) break
        }
      }
      if(n==3){ print a[1] "," a[2] "," a[3]; exit 0 }
    }
    END{ exit 1 }
  ' "$file"
}

# Build CSV from raw logs
for r in $(seq 1 "${REPEATS}"); do
  # ECDSA
  efile="${rawdir}/rep${r}_ecdsap256.txt"
  if [ -f "$efile" ]; then
    sign="" verify=""
    if IFS=',' read -r sign verify < <(parse_ecdsa_p256_from_file "$efile"); then
      if isnum "$sign" && isnum "$verify"; then
        echo "rep=${r} alg=ecdsap256 sign/s=${sign} verify/s=${verify}"
        record_row "${r}" "ecdsap256" "" "${sign}" "${verify}" 1 "" "${efile}"
      else
        warn "ECDSA non-numeric (rep=${r}) sign=${sign:-} verify=${verify:-} file=${efile}"
        record_row "${r}" "ecdsap256" "" "" "" 0 "ECDSA_NON_NUMERIC" "${efile}"
      fi
    else
      warn "ECDSA nistp256 row not found (rep=${r}) file=${efile}"
      record_row "${r}" "ecdsap256" "" "" "" 0 "ECDSA_ROW_NOT_FOUND" "${efile}"
    fi
  else
    warn "Missing raw file for ECDSA (rep=${r}) file=${efile}"
    record_row "${r}" "ecdsap256" "" "" "" 0 "ECDSA_RAW_MISSING" "${efile}"
  fi

  # PQC
  for alg in "mldsa44" "mldsa65" "falcon512" "falcon1024"; do
    pfile="${rawdir}/rep${r}_${alg}.txt"
    if [ -f "$pfile" ]; then
      keygens="" sign="" verify=""
      if IFS=',' read -r keygens sign verify < <(parse_pqc_from_file "$alg" "$pfile"); then
        if isnum "$keygens" && isnum "$sign" && isnum "$verify"; then
          echo "rep=${r} alg=${alg} keygens/s=${keygens} sign/s=${sign} verify/s=${verify}"
          record_row "${r}" "${alg}" "${keygens}" "${sign}" "${verify}" 1 "" "${pfile}"
        else
          warn "PQC non-numeric (rep=${r} alg=${alg}) keygens=${keygens:-} sign=${sign:-} verify=${verify:-} file=${pfile}"
          record_row "${r}" "${alg}" "" "" "" 0 "PQC_NON_NUMERIC" "${pfile}"
        fi
      else
        warn "PQC row not found (rep=${r} alg=${alg}) file=${pfile}"
        record_row "${r}" "${alg}" "" "" "" 0 "PQC_ROW_NOT_FOUND" "${pfile}"
      fi
    else
      warn "Missing raw file (rep=${r} alg=${alg}) file=${pfile}"
      record_row "${r}" "${alg}" "" "" "" 0 "PQC_RAW_MISSING" "${pfile}"
    fi
  done
done

echo
echo "CSV: ${csv}"
echo "Raw: ${rawdir}/rep*_*.txt"
echo "Warnings: ${warnlog}"
