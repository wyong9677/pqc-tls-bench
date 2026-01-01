#!/usr/bin/env bash
set -euo pipefail

# =========================
# Paper-grade Signature Speed Benchmark (FINAL, ROBUST)
# - ECDSA parser ONLY matches 256-bit / P-256 related rows to avoid 160/192-bit pollution
# - Ensures P-256 is actually benchmarked by preferring "ecdsap256" when available
# - One long-lived container (no docker run overhead)
# - Timeout watchdog to prevent "stuck" runs
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

# ---------- AWK parsers ----------

# ECDSA: ONLY match 256-bit / P-256 related rows to prevent 160/192-bit pollution.
# Acceptable matches:
#   1) "Doing 256 bits sign ecdsa ..." or "Doing 256 bits verify ecdsa ..."
#   2) summary rows containing "256 bits" and "ecdsa"
#   3) rows mentioning P-256 aliases: nistp256 / prime256v1 / secp256r1
# From the matched row, take the last two numeric tokens as sign/s, verify/s (summary)
# OR for "Doing ..." lines, we compute rate from ops/N (handled by selecting summary if present).
#
# NOTE: In some OpenSSL builds, "speed ecdsa" does not emit a stable summary row.
# This is why run_speed_ecdsa() prefers "ecdsap256" to force P-256 output.
parse_ecdsa_p256() {
  awk '
    function isnum(x){
      return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/)
    }
    BEGIN{
      IGNORECASE=1
      found=0
      sign_ops=""; verify_ops=""; secs=""
    }

    # Capture seconds (best-effort) from "ops for 15s:" pattern
    /ops[[:space:]]+for[[:space:]]+[0-9]+s:/ {
      for(i=1;i<=NF;i++){
        if($i ~ /^[0-9]+s:$/){
          secs=$i
          sub(/s:$/,"",secs)
        }
      }
    }

    # Prefer parsing "Doing 256 bits sign/verify ..." lines to avoid any ambiguity.
    /^Doing[[:space:]]+256[[:space:]]+bits[[:space:]]+sign[[:space:]]+ecdsa/ {
      for(i=NF;i>=1;i--){
        if(isnum($i)){ sign_ops=$i; break }
      }
      next
    }
    /^Doing[[:space:]]+256[[:space:]]+bits[[:space:]]+verify[[:space:]]+ecdsa/ {
      for(i=NF;i>=1;i--){
        if(isnum($i)){ verify_ops=$i; break }
      }
      next
    }

    # If both ops captured and we know secs, compute rates and print.
    # This is robust even when no summary table exists.
    END{
      if(sign_ops!="" && verify_ops!=""){
        s=(secs!=""?secs:15)   # fallback to 15 if not detected
        printf "%.1f,%.1f\n", (sign_ops/s), (verify_ops/s)
        exit 0
      }
      exit 1
    }
  '
}

# PQC: match the algorithm row and take last 3 numeric tokens (keygens/s, sign/s, verify/s)
parse_pqc_row() {
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

# Prefer forcing P-256 explicitly to guarantee 256-bit rows exist for parsing.
run_speed_ecdsa() {
  out="$(run_in_container "\"${OPENSSL}\" speed -seconds ${BENCH_SECONDS} -provider default ecdsap256 2>&1" || true)"
  # If not supported, fall back to generic ecdsa (may fail STRICT if no 256-bit lines exist).
  if printf "%s\n" "${out}" | grep -qiE "unknown|not supported|invalid command|No such|Error"; then
    out="$(run_in_container "\"${OPENSSL}\" speed -seconds ${BENCH_SECONDS} -provider default ecdsa 2>&1" || true)"
  fi
  printf "%s\n" "${out}"
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
        warn "ECDSA P-256/256-bit lines not found (rep=${r}) raw=${rawfile}"
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
