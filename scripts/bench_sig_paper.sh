#!/usr/bin/env bash
set -euo pipefail

# =========================
# Paper-grade Signature Speed Benchmark (FINAL, ROBUST)
# - Robust ECDSA parser (OpenSSL-version agnostic)
# - One long-lived container (no docker run overhead)
# - Timeout watchdog to avoid stuck runs
# - CSV always written; STRICT=1 enforces no silent nulls
# =========================

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"

# STRICT=1 => abort on missing/non-numeric metrics
STRICT="${STRICT:-0}"

# Extra watchdog (seconds) added on top of BENCH_SECONDS
WATCHDOG_EXTRA="${WATCHDOG_EXTRA:-45}"

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

export LC_ALL=C

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

warn() {
  local msg="$1"
  echo "[WARN] $(ts) ${msg}" | tee -a "${warnlog}" 1>&2
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

# ---------- AWK parsers (FINAL, ROBUST) ----------

# ECDSA: match any ECDSA result line with "bits" and take last two numeric tokens
# This is stable across OpenSSL versions/providers.
parse_ecdsa_p256() {
  awk '
    function isnum(x){
      return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/)
    }
    BEGIN{ found=0 }
    /ecdsa/ && /bits/ {
      n=0
      for(i=NF;i>=1;i--){
        if(isnum($i)){
          a[2-n]=$i
          n++
          if(n==2) break
        }
      }
      if(n==2){
        print a[1] "," a[2]
        found=1
        exit
      }
    }
    END{ exit(found?0:1) }
  '
}

# PQC: match the algorithm row and take last 3 numeric tokens
parse_pqc_row() {
  local alg="$1"
  awk -v alg="$alg" '
    function isnum(x){
      return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/)
    }
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
        print a[1] "," a[2] "," a[3]
        found=1
        exit
      }
    }
    END{ exit(found?0:1) }
  '
}

# ---------- Start one long-lived container ----------
echo "=== Signature speed (paper-grade, FINAL, ROBUST) ==="
echo "mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS} STRICT=${STRICT}"
echo "IMG=${IMG}"
echo "RESULTS_DIR=${RESULTS_DIR}"
echo "[INFO] $(ts) pulling image once..."
docker pull "${IMG}" >/dev/null

name="sigbench-$$"
echo "[INFO] $(ts) starting container ${name}..."
cid="$(docker run -d --rm --name "${name}" "${IMG}" sh -lc 'trap "exit 0" TERM INT; while :; do sleep 3600; done')"
cleanup() { docker rm -f "${cid}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Locate openssl once
OPENSSL="$(
  docker exec "${cid}" sh -lc '
    export LC_ALL=C
    OPENSSL=/opt/openssl/bin/openssl
    [ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
    [ -n "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }
    echo "$OPENSSL"
  '
)"

# Provide timeout wrapper inside container (if available)
TIMEOUT_CMD="$(
  docker exec "${cid}" sh -lc '
    if command -v timeout >/dev/null 2>&1; then
      echo "timeout"
    else
      echo ""
    fi
  '
)"

run_in_container() {
  if [ -n "${TIMEOUT_CMD}" ]; then
    local wd=$((BENCH_SECONDS + WATCHDOG_EXTRA))
    docker exec "${cid}" sh -lc "export LC_ALL=C; timeout -k 5 ${wd}s $*"
  else
    docker exec "${cid}" sh -lc "export LC_ALL=C; $*"
  fi
}

run_speed_ecdsa() {
  run_in_container "\"${OPENSSL}\" speed -seconds ${BENCH_SECONDS} -provider default ecdsa 2>&1" || true
}

run_speed_pqc() {
  local alg="$1"
  run_in_container "\"${OPENSSL}\" speed -seconds ${BENCH_SECONDS} -provider oqsprovider -provider default ${alg} 2>&1" || true
}

# ---------- Warmup ----------
echo "[INFO] $(ts) warmup=${WARMUP} (not recorded)"
for _ in $(seq 1 "${WARMUP}"); do
  run_speed_ecdsa >/dev/null 2>&1 || true
  for a in "mldsa44" "mldsa65" "falcon512" "falcon1024"; do
    run_speed_pqc "$a" >/dev/null 2>&1 || true
  done
done

# ---------- Main runs ----------
for r in $(seq 1 "${REPEATS}"); do
  for alg in "${SIGS[@]}"; do
    rawfile="${rawdir}/rep${r}_${alg}.txt"
    echo "[RUN] rep=${r}/${REPEATS} alg=${alg}"

    if [ "${alg}" = "ecdsap256" ]; then
      out="$(run_speed_ecdsa)"
      printf "%s\n" "${out}" > "${rawfile}"

      sign="" verify=""
      if IFS=',' read -r sign verify < <(printf "%s\n" "${out}" | parse_ecdsa_p256); then
        if isnum "${sign}" && isnum "${verify}"; then
          echo "  -> sign/s=${sign} verify/s=${verify}"
          record_row "${r}" "${alg}" "" "${sign}" "${verify}" 1 "" "${rawfile}"
        else
          warn "ECDSA non-numeric (rep=${r}) sign=${sign:-} verify=${verify:-} raw=${rawfile}"
          record_row "${r}" "${alg}" "" "" "" 0 "ECDSA_NON_NUMERIC" "${rawfile}"
        fi
      else
        warn "ECDSA row not found (rep=${r}) raw=${rawfile}"
        record_row "${r}" "${alg}" "" "" "" 0 "ECDSA_ROW_NOT_FOUND" "${rawfile}"
      fi
      continue
    fi

    out="$(run_speed_pqc "${alg}")"
    printf "%s\n" "${out}" > "${rawfile}"

    keygens="" sign="" verify=""
    if IFS=',' read -r keygens sign verify < <(printf "%s\n" "${out}" | parse_pqc_row "${alg}"); then
      if isnum "${keygens}" && isnum "${sign}" && isnum "${verify}"; then
        echo "  -> keygens/s=${keygens} sign/s=${sign} verify/s=${verify}"
        record_row "${r}" "${alg}" "${keygens}" "${sign}" "${verify}" 1 "" "${rawfile}"
      else
        warn "PQC non-numeric (rep=${r} alg=${alg}) keygens=${keygens:-} sign=${sign:-} verify=${verify:-} raw=${rawfile}"
        record_row "${r}" "${alg}" "" "" "" 0 "PQC_NON_NUMERIC" "${rawfile}"
      fi
    else
      warn "PQC row not found (rep=${r} alg=${alg}) raw=${rawfile}"
      record_row "${r}" "${alg}" "" "" "" 0 "PQC_ROW_NOT_FOUND" "${rawfile}"
    fi
  done
done

echo
echo "CSV: ${csv}"
echo "Raw: ${rawdir}/rep*_*.txt"
echo "Warnings: ${warnlog}"
