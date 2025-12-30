#!/usr/bin/env bash
set -euo pipefail

# =========================
# Paper-grade Signature Speed Benchmark (FINAL, robust)
# - single long-lived container (fast, avoids "stuck" cold-start loops)
# - robust parsing for OpenSSL speed outputs (ECDSA table + oqsprovider PQC)
# - stable CSV schema with ok/err/raw_file
# - STRICT=0 default: never aborts; STRICT=1: abort on first parse/run error
# =========================

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-7}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-20}"
STRICT="${STRICT:-0}"

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

echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s,ok,err,raw_file" > "${csv}"

echo "=== Signature speed (paper-grade, FINAL robust) ==="
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

# Portable timeout command if available (Linux: timeout, macOS+coreutils: gtimeout)
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

# Give each openssl speed a hard wall-time budget to prevent indefinite hangs
# (seconds + slack). If no timeout binary exists, runs without it.
RUN_BUDGET="$((BENCH_SECONDS + 60))"

run_with_timeout() {
  if [ -n "${TIMEOUT_BIN}" ]; then
    "${TIMEOUT_BIN}" --preserve-status "${RUN_BUDGET}" "$@"
  else
    "$@"
  fi
}

echo "[info] docker pull (shows progress if needed)..."
docker pull "${IMG}"
echo

# Start ONE container
cid="$(docker run -d --rm "${IMG}" sh -lc 'trap : TERM INT; while :; do sleep 3600; done')"
cleanup() { docker rm -f "${cid}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Find openssl once
OPENSSL="$(docker exec "${cid}" sh -lc '
  export LC_ALL=C
  OPENSSL=/opt/openssl/bin/openssl
  [ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
  [ -n "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }
  echo "$OPENSSL"
')"

docker_exec_speed() {
  # args: provider_args... alg_or_group
  # prints stdout+stderr
  run_with_timeout docker exec "${cid}" sh -lc "
    set -e
    export LC_ALL=C
    \"${OPENSSL}\" speed -seconds ${BENCH_SECONDS} $* 2>&1
  " || true
}

# -------- parsers --------

# ECDSA P-256 row (nistp256): extract last 2 numeric tokens (sign/s, verify/s)
parse_ecdsa_p256() {
  awk '
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) }
    /nistp256/ {
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

# PQC row: line whose first field == alg, extract last 3 numeric tokens
parse_pqc_row() {
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

# -------- warmup --------
echo "[info] warmup start (this can take ~ ${WARMUP} * ${#SIGS[@]} * ${BENCH_SECONDS}s)..."
for w in $(seq 1 "${WARMUP}"); do
  echo "[warmup] round ${w}/${WARMUP} ecdsa(p256)"
  docker_exec_speed "-provider default ecdsa" >/dev/null 2>&1 || true

  for alg in "mldsa44" "mldsa65" "falcon512" "falcon1024"; do
    echo "[warmup] round ${w}/${WARMUP} ${alg}"
    docker_exec_speed "-provider oqsprovider -provider default ${alg}" >/dev/null 2>&1 || true
  done
done
echo "[info] warmup done"
echo

# -------- main runs --------
for r in $(seq 1 "${REPEATS}"); do
  echo "[run] repeat ${r}/${REPEATS}"
  for alg in "${SIGS[@]}"; do
    rawfile="${rawdir}/rep${r}_${alg}.txt"

    if [ "${alg}" = "ecdsap256" ]; then
      out="$(docker_exec_speed "-provider default ecdsa")"
      printf "%s\n" "${out}" > "${rawfile}"

      sign="" verify=""
      if IFS=',' read -r sign verify < <(printf "%s\n" "${out}" | parse_ecdsa_p256); then
        if isnum "${sign}" && isnum "${verify}"; then
          echo "  rep=${r} alg=${alg} sign/s=${sign} verify/s=${verify}"
          record_row "${r}" "${alg}" "" "${sign}" "${verify}" 1 "" "${rawfile}"
        else
          warn "ECDSA metrics non-numeric rep=${r} sign=${sign:-} verify=${verify:-} raw=${rawfile}"
          record_row "${r}" "${alg}" "" "" "" 0 "ECDSA_NON_NUMERIC" "${rawfile}"
        fi
      else
        warn "ECDSA nistp256 row not found rep=${r} raw=${rawfile}"
        record_row "${r}" "${alg}" "" "" "" 0 "ECDSA_ROW_NOT_FOUND" "${rawfile}"
      fi
      continue
    fi

    out="$(docker_exec_speed "-provider oqsprovider -provider default ${alg}")"
    printf "%s\n" "${out}" > "${rawfile}"

    keygens="" sign="" verify=""
    if IFS=',' read -r keygens sign verify < <(printf "%s\n" "${out}" | parse_pqc_row "${alg}"); then
      if isnum "${keygens}" && isnum "${sign}" && isnum "${verify}"; then
        echo "  rep=${r} alg=${alg} keygens/s=${keygens} sign/s=${sign} verify/s=${verify}"
        record_row "${r}" "${alg}" "${keygens}" "${sign}" "${verify}" 1 "" "${rawfile}"
      else
        warn "PQC metrics non-numeric alg=${alg} rep=${r} keygens=${keygens:-} sign=${sign:-} verify=${verify:-} raw=${rawfile}"
        record_row "${r}" "${alg}" "" "" "" 0 "PQC_NON_NUMERIC" "${rawfile}"
      fi
    else
      warn "PQC row not found alg=${alg} rep=${r} raw=${rawfile}"
      record_row "${r}" "${alg}" "" "" "" 0 "PQC_ROW_NOT_FOUND" "${rawfile}"
    fi
  done
done

echo
echo "CSV: ${csv}"
echo "Raw: ${rawdir}/rep*_*.txt"
echo "Warnings: ${warnlog}"
