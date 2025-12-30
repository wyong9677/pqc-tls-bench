#!/usr/bin/env bash
set -euo pipefail

# =========================
# Paper-grade Signature Speed Benchmark (FINAL)
# - non-fatal by default (does NOT abort on parse issues)
# - preserves raw logs for auditability
# - writes stable CSV with ok/err markers
# - robust parsing for OpenSSL 3.x outputs (incl. oqsprovider speed)
# =========================

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-7}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-20}"

# STRICT=1 => any missing/non-numeric metrics aborts (CI mode)
STRICT="${STRICT:-0}"

if [ "${MODE}" = "smoke" ]; then
  REPEATS=1
  WARMUP=1
  BENCH_SECONDS=5
fi

# Algorithms (baseline + PQC)
SIGS=("ecdsap256" "mldsa44" "mldsa65" "falcon512" "falcon1024")

mkdir -p "${RESULTS_DIR}"
rawdir="${RESULTS_DIR}/sig_speed_raw"
mkdir -p "${rawdir}"

csv="${RESULTS_DIR}/sig_speed.csv"
warnlog="${RESULTS_DIR}/sig_speed_warnings.log"
: > "${warnlog}"

# Stable CSV schema for paper/reproducibility
echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s,ok,err,raw_file" > "${csv}"

echo "=== Signature speed (paper-grade, FINAL) ==="
echo "mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS} STRICT=${STRICT}"
echo "IMG=${IMG}"
echo "RESULTS_DIR=${RESULTS_DIR}"
echo

# Force C locale to avoid decimal separator issues
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
  # CSV-safe quoting for err/raw path
  err="${err//\"/\"\"}"
  raw="${raw//\"/\"\"}"
  echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens},${sign},${verify},${ok},\"${err}\",\"${raw}\"" >> "${csv}"
}

isnum() {
  local x="${1:-}"
  [[ "$x" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]
}

# In-container: locate openssl
FIND_OPENSSL='
export LC_ALL=C
OPENSSL=/opt/openssl/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
[ -n "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }
echo "$OPENSSL"
'

# Run ECDSA table (ensures nistp256 line exists)
run_speed_ecdsa() {
  docker run --rm "${IMG}" sh -lc "
    set -e
    export LC_ALL=C
    OPENSSL=\$(${FIND_OPENSSL})
    \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider default ecdsa 2>&1
  "
}

# Run PQC speed with oqsprovider + default
run_speed_pqc() {
  local alg="$1"
  docker run --rm "${IMG}" sh -lc "
    set -e
    export LC_ALL=C
    OPENSSL=\$(${FIND_OPENSSL})
    \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider oqsprovider -provider default ${alg} 2>&1
  "
}

# Parse ECDSA P-256 line:
# Example:
#  256 bits ecdsa (nistp256)   0.0000s   0.0001s  43514.7  14540.3
# We extract last 2 numeric tokens (sign/s, verify/s)
parse_ecdsa_p256() {
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
  '
}

# Parse PQC row:
# Example:
# mldsa44 ... keygens/s  sign/s  verify/s
# mldsa44 0.000035s ...  28760.9 12257.1 31295.6
# We match $1==alg and extract last 3 numeric tokens (keygens/s, sign/s, verify/s)
parse_pqc() {
  local alg="$1"
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
  '
}

# ================= warmup (not recorded) =================
for _ in $(seq 1 "${WARMUP}"); do
  run_speed_ecdsa >/dev/null 2>&1 || true
  for alg in "mldsa44" "mldsa65" "falcon512" "falcon1024"; do
    run_speed_pqc "$alg" >/dev/null 2>&1 || true
  done
done

# ================= main runs =================
for r in $(seq 1 "${REPEATS}"); do
  for alg in "${SIGS[@]}"; do
    rawfile="${rawdir}/rep${r}_${alg}.txt"

    if [ "${alg}" = "ecdsap256" ]; then
      out="$(run_speed_ecdsa || true)"
      printf "%s\n" "$out" > "${rawfile}"

      sign="" verify=""
      if IFS=',' read -r sign verify < <(printf "%s\n" "$out" | parse_ecdsa_p256); then
        if isnum "$sign" && isnum "$verify"; then
          echo "rep=${r} alg=${alg} sign/s=${sign} verify/s=${verify}"
          # keygen intentionally blank for ECDSA
          record_row "${r}" "${alg}" "" "${sign}" "${verify}" 1 "" "${rawfile}"
        else
          warn "ECDSA non-numeric metrics (rep=${r}). sign=${sign:-} verify=${verify:-}. raw=${rawfile}"
          record_row "${r}" "${alg}" "" "" "" 0 "ECDSA_NON_NUMERIC" "${rawfile}"
        fi
      else
        warn "ECDSA P-256 row not found (rep=${r}). raw=${rawfile}"
        record_row "${r}" "${alg}" "" "" "" 0 "ECDSA_ROW_NOT_FOUND" "${rawfile}"
      fi

      continue
    fi

    # PQC algorithms
    out="$(run_speed_pqc "${alg}" || true)"
    printf "%s\n" "$out" > "${rawfile}"

    keygens="" sign="" verify=""
    if IFS=',' read -r keygens sign verify < <(printf "%s\n" "$out" | parse_pqc "${alg}"); then
      if isnum "$keygens" && isnum "$sign" && isnum "$verify"; then
        echo "rep=${r} alg=${alg} keygens/s=${keygens} sign/s=${sign} verify/s=${verify}"
        record_row "${r}" "${alg}" "${keygens}" "${sign}" "${verify}" 1 "" "${rawfile}"
      else
        warn "PQC non-numeric metrics for alg=${alg} (rep=${r}). keygens=${keygens:-} sign=${sign:-} verify=${verify:-}. raw=${rawfile}"
        record_row "${r}" "${alg}" "" "" "" 0 "PQC_NON_NUMERIC" "${rawfile}"
      fi
    else
      warn "PQC row not found for alg=${alg} (rep=${r}). raw=${rawfile}"
      record_row "${r}" "${alg}" "" "" "" 0 "PQC_ROW_NOT_FOUND" "${rawfile}"
    fi
  done
done

echo
echo "CSV: ${csv}"
echo "Raw: ${rawdir}/rep*_*.txt"
echo "Warnings: ${warnlog}"
