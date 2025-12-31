#!/usr/bin/env bash
set -euo pipefail

# =========================
# Paper-grade Signature Speed Benchmark (Provider-safe)
# - DOES NOT use `openssl speed` for PQC (unsupported for 3rd-party providers)
# - Uses openssl genpkey + pkeyutl loops timed by timeout+trap
# - One long-lived container to reduce overhead
# - Writes CSV + raw logs; STRICT=1 fails on real execution errors
# =========================

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"
STRICT="${STRICT:-1}"

# Optional: separate keygen timing window (defaults to BENCH_SECONDS)
KEYGEN_SECONDS="${KEYGEN_SECONDS:-${BENCH_SECONDS}}"

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

isnum() {
  local x="${1:-}"
  [[ "$x" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]
}

# ---------- Container lifecycle ----------
RUN_ID="${RUN_ID:-$(date -u +'%Y%m%dT%H%M%SZ')}"
cname="sigbench-${RUN_ID}"

echo "[INFO] $(ts) Signature speed: mode=${MODE} run_id=${RUN_ID} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS} STRICT=${STRICT}"
echo "[INFO] $(ts) IMG=${IMG}"
echo "[INFO] $(ts) Pulling image once..."
docker pull "${IMG}" >/dev/null 2>&1 || true

cleanup() {
  docker rm -f "${cname}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[INFO] $(ts) Starting long-lived container ${cname}..."
docker run -d --rm --name "${cname}" "${IMG}" sh -lc "sleep infinity" >/dev/null

# Helper: exec a shell script in container via stdin (robust quoting)
exec_in_container() {
  docker exec -i "${cname}" sh -s
}

# ---------- Core benchmark primitive ----------
# Runs a command in a tight loop for T seconds inside container; prints COUNT to stdout.
# Uses timeout to send TERM; trap prints the counter on TERM.
bench_count() {
  local seconds="$1"
  shift
  local cmd="$*"

  exec_in_container <<SH
set -eu
OPENSSL=/opt/openssl/bin/openssl
[ -x "\$OPENSSL" ] || OPENSSL="\$(command -v openssl || true)"
[ -n "\$OPENSSL" ] || { echo "NO_OPENSSL" >&2; exit 127; }

# Ensure timeout exists
command -v timeout >/dev/null 2>&1 || { echo "NO_TIMEOUT" >&2; exit 127; }

T="${seconds}"

# Loop with trap so timeout still yields count
timeout -k 2 "\${T}" sh -c '
  set -eu
  c=0
  trap "echo \$c; exit 0" TERM INT
  while :; do
    ${cmd} >/dev/null 2>&1
    c=\$((c+1))
  done
'
SH
}

# ---------- Algorithm-specific bench ----------
# Outputs: "keygens_s,sign_s,verify_s" or returns nonzero on real errors
bench_alg() {
  local alg="$1"  # ecdsap256 | mldsa44 | mldsa65 | falcon512 | falcon1024

  # Provider args & keygen recipe
  local prov=""
  local keygen=""
  if [ "${alg}" = "ecdsap256" ]; then
    prov="-provider default"
    keygen='"\$OPENSSL" genpkey '"${prov}"' -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "\$KEY"'
  else
    prov="-provider oqsprovider -provider default"
    keygen='"\$OPENSSL" genpkey '"${prov}"' -algorithm '"${alg}"' -out "\$KEY"'
  fi

  # Prepare workspace + message/key/pub inside container (one-time per call)
  # Then run 3 benchmarks: keygen, sign, verify (using pkeyutl)
  exec_in_container <<SH
set -eu
OPENSSL=/opt/openssl/bin/openssl
[ -x "\$OPENSSL" ] || OPENSSL="\$(command -v openssl || true)"
[ -n "\$OPENSSL" ] || { echo "NO_OPENSSL" >&2; exit 127; }

command -v timeout >/dev/null 2>&1 || { echo "NO_TIMEOUT" >&2; exit 127; }

ALG="${alg}"
PROV='${prov}'
T_SIGN="${BENCH_SECONDS}"
T_KEYGEN="${KEYGEN_SECONDS}"

WORK="/tmp/sigbench"
mkdir -p "\$WORK"
KEY="\$WORK/key.pem"
PUB="\$WORK/pub.pem"
MSG="\$WORK/msg.bin"
SIG="\$WORK/sig.bin"

# stable message
printf "pqc-bench-paper" > "\$MSG"

# generate one key for sign/verify
${keygen} >/dev/null 2>&1 || { echo "KEYGEN_FAILED" >&2; exit 2; }

# pubkey
"\$OPENSSL" pkey \${PROV} -in "\$KEY" -pubout -out "\$PUB" >/dev/null 2>&1 || { echo "PUBOUT_FAILED" >&2; exit 3; }

# make one signature to ensure verify path works
"\$OPENSSL" pkeyutl \${PROV} -sign -inkey "\$KEY" -in "\$MSG" -out "\$SIG" >/dev/null 2>&1 || { echo "SIGN_SETUP_FAILED" >&2; exit 4; }
"\$OPENSSL" pkeyutl \${PROV} -verify -pubin -inkey "\$PUB" -in "\$MSG" -sigfile "\$SIG" >/dev/null 2>&1 || { echo "VERIFY_SETUP_FAILED" >&2; exit 5; }

# Function: count loops for a given body command
count_loop() {
  local T="\$1"
  shift
  local BODY="\$*"
  timeout -k 2 "\${T}" sh -c "
    set -eu
    c=0
    trap 'echo \$c; exit 0' TERM INT
    while :; do
      \${BODY} >/dev/null 2>&1
      c=\$((c+1))
    done
  "
}

# 1) keygen count (overwrite KEY each time)
KEYGEN_COUNT="\$(count_loop "\${T_KEYGEN}" ${keygen} || true)"
# 2) sign count (overwrite SIG)
SIGN_COUNT="\$(count_loop "\${T_SIGN}" "\"\$OPENSSL\" pkeyutl \${PROV} -sign -inkey \"\$KEY\" -in \"\$MSG\" -out \"\$SIG\"" || true)"
# 3) verify count
VERIFY_COUNT="\$(count_loop "\${T_SIGN}" "\"\$OPENSSL\" pkeyutl \${PROV} -verify -pubin -inkey \"\$PUB\" -in \"\$MSG\" -sigfile \"\$SIG\"" || true)"

# Validate numeric
case "\$KEYGEN_COUNT" in (*[!0-9]*|"") echo "KEYGEN_COUNT_BAD:\$KEYGEN_COUNT" >&2; exit 10;; esac
case "\$SIGN_COUNT" in (*[!0-9]*|"") echo "SIGN_COUNT_BAD:\$SIGN_COUNT" >&2; exit 11;; esac
case "\$VERIFY_COUNT" in (*[!0-9]*|"") echo "VERIFY_COUNT_BAD:\$VERIFY_COUNT" >&2; exit 12;; esac

# Print counts only; host computes /s precisely
echo "\$KEYGEN_COUNT,\$SIGN_COUNT,\$VERIFY_COUNT"
SH
}

rate() {
  # args: count seconds -> prints rate with 1 decimal
  local count="$1" secs="$2"
  awk -v c="${count}" -v t="${secs}" 'BEGIN{ if(t<=0){print "nan"; exit} printf "%.1f", (c/t) }'
}

# ---------- Warmup ----------
echo "[INFO] $(ts) Warmup=${WARMUP} (not recorded)"
for _ in $(seq 1 "${WARMUP}"); do
  bench_alg "ecdsap256" >/dev/null 2>&1 || true
  for a in "mldsa44" "mldsa65" "falcon512" "falcon1024"; do
    bench_alg "$a" >/dev/null 2>&1 || true
  done
done

# ---------- Main benchmark ----------
for r in $(seq 1 "${REPEATS}"); do
  for alg in "ecdsap256" "mldsa44" "mldsa65" "falcon512" "falcon1024"; do
    rawfile="${rawdir}/rep${r}_${alg}.txt"
    echo "[INFO] $(ts) RUN rep=${r}/${REPEATS} alg=${alg}"

    out=""
    if ! out="$(bench_alg "${alg}" 2>&1)"; then
      printf "%s\n" "${out}" > "${rawfile}"
      warn "SIG_BENCH_FAILED rep=${r} alg=${alg} raw=${rawfile} out=$(printf "%s" "${out}" | head -c 200)"
      record_row "${r}" "${alg}" "" "" "" 0 "SIG_BENCH_FAILED" "${rawfile}"
      continue
    fi

    printf "%s\n" "${out}" > "${rawfile}"

    IFS=',' read -r keygen_cnt sign_cnt verify_cnt <<<"${out}" || true
    if ! [[ "${keygen_cnt}" =~ ^[0-9]+$ && "${sign_cnt}" =~ ^[0-9]+$ && "${verify_cnt}" =~ ^[0-9]+$ ]]; then
      warn "NON_NUMERIC_COUNTS rep=${r} alg=${alg} out=${out} raw=${rawfile}"
      record_row "${r}" "${alg}" "" "" "" 0 "NON_NUMERIC_COUNTS" "${rawfile}"
      continue
    fi

    keygens_s="$(rate "${keygen_cnt}" "${KEYGEN_SECONDS}")"
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
