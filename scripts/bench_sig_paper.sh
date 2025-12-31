#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need docker
need python3

IMG="${IMG:?IMG is required (e.g. openquantumsafe/oqs-ossl3@sha256:...)}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"
WATCHDOG_EXTRA="${WATCHDOG_EXTRA:-20}"

# Paper mode should fail-fast by default
STRICT="${STRICT:-}"
if [ -z "${STRICT}" ]; then
  if [ "${MODE}" = "paper" ]; then STRICT=1; else STRICT=0; fi
fi

RUN_ID="${RUN_ID:-$(default_run_id)}"
OUTDIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "${OUTDIR}"

# Algorithm set (override if desired)
SIGS_DEFAULT=("ecdsap256" "mldsa44" "mldsa65" "falcon512" "falcon1024")
SIGS=("${SIGS_DEFAULT[@]}")
if [ -n "${SIGS_CSV:-}" ]; then
  IFS=',' read -r -a SIGS <<<"${SIGS_CSV}"
fi

rawdir="${OUTDIR}/sig_speed_raw"
mkdir -p "${rawdir}"
csv="${OUTDIR}/sig_speed.csv"
warnlog="${OUTDIR}/sig_speed_warnings.log"
: > "${warnlog}"

echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s,ok,err,raw_file" > "${csv}"

# Meta
CONFIG_JSON="$(python3 - <<PY
import json
print(json.dumps({
  "benchmark": "sig_speed",
  "repeats": int(${REPEATS}),
  "warmup": int(${WARMUP}),
  "seconds": int(${BENCH_SECONDS}),
  "watchdog_extra": int(${WATCHDOG_EXTRA}),
  "algs": ${SIGS[@]@Q},
  "strict": int(${STRICT}),
}))
PY
)"
write_meta_json "${OUTDIR}" "${MODE}" "${IMG}" "${CONFIG_JSON}"

info "Signature speed: mode=${MODE} run_id=${RUN_ID} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS} STRICT=${STRICT}"
info "IMG=${IMG}"

info "Pulling image once..."
docker pull "${IMG}" >/dev/null

name="sigbench-${RUN_ID}"
info "Starting long-lived container ${name}..."
cid="$(docker run -d --rm --name "${name}" "${IMG}" sh -lc 'trap "exit 0" TERM INT; while :; do sleep 3600; done')"
cleanup() { docker rm -f "${cid}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

OPENSSL="$(
  docker exec "${cid}" sh -lc '
    OPENSSL=/opt/openssl/bin/openssl
    [ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
    [ -n "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }
    echo "$OPENSSL"
  '
)"

HAS_TIMEOUT="$(
  docker exec "${cid}" sh -lc 'command -v timeout >/dev/null 2>&1 && echo 1 || echo 0'
)"

run_in_container() {
  local cmd="$1"
  if [ "${HAS_TIMEOUT}" = "1" ]; then
    local wd=$((BENCH_SECONDS + WATCHDOG_EXTRA))
    docker exec "${cid}" sh -lc "timeout -k 5 ${wd}s ${cmd}"
  else
    docker exec "${cid}" sh -lc "${cmd}"
  fi
}

warnlog_append() {
  local msg="$1"
  echo "[WARN] $(ts) ${msg}" | tee -a "${warnlog}" 1>&2
  if [ "${STRICT}" = "1" ]; then
    die "${msg}"
  fi
}

record_row() {
  local r="$1" alg="$2" keygens="$3" sign="$4" verify="$5" ok="$6" err="$7" raw="$8"
  err="${err//\"/\"\"}"
  raw="${raw//\"/\"\"}"
  echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens},${sign},${verify},${ok},\"${err}\",\"${raw}\"" >> "${csv}"
}

run_speed() {
  local alg="$1"
  local providers args
  # ECDSA uses default provider only; PQC uses oqsprovider+default
  if [ "${alg}" = "ecdsap256" ]; then
    providers="default"
  else
    providers="oqsprovider,default"
  fi
  args="$(providers_to_args "${providers}")"
  # IMPORTANT:
  # - ecdsap256 (NOT "ecdsa") to avoid running all curves and exploding runtime
  # - alg name must be passed explicitly
  run_in_container "\"${OPENSSL}\" speed -seconds ${BENCH_SECONDS} ${args} ${alg} 2>&1" || true
}

# Warmup
info "Warmup=${WARMUP} (not recorded)"
for _ in $(seq 1 "${WARMUP}"); do
  for alg in "${SIGS[@]}"; do
    run_speed "${alg}" >/dev/null 2>&1 || true
  done
done

# Main
for r in $(seq 1 "${REPEATS}"); do
  for alg in "${SIGS[@]}"; do
    rawfile="${rawdir}/rep${r}_${alg}.txt"
    info "RUN rep=${r}/${REPEATS} alg=${alg}"

    out="$(run_speed "${alg}")"
    printf "%s\n" "${out}" > "${rawfile}"

    # Parse on host using stable parser
    parsed=""
    if parsed="$(python3 "${SCRIPT_DIR}/parse_sig_speed.py" --alg "${alg}" --raw "${rawfile}" 2>/dev/null)"; then
      IFS=',' read -r keygens sign verify <<<"${parsed}"
      if [ "${alg}" = "ecdsap256" ]; then
        echo "  -> sign/s=${sign} verify/s=${verify}"
        record_row "${r}" "${alg}" "" "${sign}" "${verify}" 1 "" "${rawfile}"
      else
        echo "  -> keygens/s=${keygens} sign/s=${sign} verify/s=${verify}"
        record_row "${r}" "${alg}" "${keygens}" "${sign}" "${verify}" 1 "" "${rawfile}"
      fi
    else
      # Determine error category
      err="PARSE_FAILED"
      python3 "${SCRIPT_DIR}/parse_sig_speed.py" --alg "${alg}" --raw "${rawfile}" 1>/dev/null 2>"${OUTDIR}/_parse_err.tmp" || true
      if grep -q "ECDSA_ROW_NOT_FOUND" "${OUTDIR}/_parse_err.tmp" 2>/dev/null; then err="ECDSA_ROW_NOT_FOUND"; fi
      if grep -q "PQC_ROW_NOT_FOUND" "${OUTDIR}/_parse_err.tmp" 2>/dev/null; then err="PQC_ROW_NOT_FOUND"; fi
      warnlog_append "${err} rep=${r} alg=${alg} raw=${rawfile}"
      record_row "${r}" "${alg}" "" "" "" 0 "${err}" "${rawfile}"
    fi
  done
done

echo
echo "OK. CSV: ${csv}"
echo "Raw: ${rawdir}/rep*_*.txt"
echo "Warnings: ${warnlog}"
echo "Meta: ${OUTDIR}/meta.json"
