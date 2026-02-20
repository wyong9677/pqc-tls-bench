#!/usr/bin/env bash
set -euo pipefail

# =========================
# Paper-grade Signature Speed Benchmark (ROBUST)
#
# Fixes:
# 1) Detect supported signature algorithms inside container (oqsprovider) before benchmarking.
# 2) If an algorithm is unsupported / unknown, record ok=0 row and continue (no early abort).
# 3) STRICT=1 now fails the job at the END if any ok=0 rows exist, instead of exiting on first warn.
# 4) PQC parser is more tolerant (case-insensitive + prefix match).
#
# IMPORTANT CHANGE (2026-02-20):
# - Use algorithm tokens that actually exist in openssl list output for this image,
#   e.g. p256_mldsa44 / p384_mldsa65 / p521_mldsa87 instead of bare mldsa44/mldsa65.
# =========================

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"

STRICT="${STRICT:-0}"
WATCHDOG_EXTRA="${WATCHDOG_EXTRA:-45}"

if [ "${MODE}" = "smoke" ]; then
  REPEATS=1
  WARMUP=1
  BENCH_SECONDS=5
fi

# Desired algorithms (targets). These will be filtered by "supported" list inside container.
# Use HYBRID tokens that are present in your openssl_sigalgs.txt for oqsprovider.
# (You can comment out items you don't want in the paper table.)
SIGS_DESIRED=(
  "ecdsap256"
  "p256_mldsa44"
  "p384_mldsa65"
  "p521_mldsa87"
  "p256_falcon512"
  "p521_falcon1024"
  # If you also want pure Falcon (non-hybrid) in the same table, uncomment:
  # "falcon512"
  # "falcon1024"
)

mkdir -p "${RESULTS_DIR}"
rawdir="${RESULTS_DIR}/sig_speed_raw"
mkdir -p "${rawdir}"

csv="${RESULTS_DIR}/sig_speed.csv"
warnlog="${RESULTS_DIR}/sig_speed_warnings.log"
supportlog="${rawdir}/openssl_sigalgs.txt"

: > "${warnlog}"
echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s,ok,err,raw_file" > "${csv}"

export LC_ALL=C

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

HAD_ERROR=0

warn() {
  local msg="$1"
  echo "[WARN] $(ts) ${msg}" | tee -a "${warnlog}" 1>&2
  HAD_ERROR=1
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

# ECDSA parser:
# Parse "Doing <bits> bits sign/verify ecdsa ops for <Ns:> <OPS>" lines.
# OPS is the numeric token immediately after "<Ns:>" token.
# Output: "sign_s,verify_s,bits_used"
# Selection:
#   - If 256-bit sign+verify present => use 256
#   - Else use the highest bits where both sign and verify exist
parse_ecdsa_rate() {
  awk -v secs_default="${BENCH_SECONDS}" '
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) }
    BEGIN{ IGNORECASE=1 }

    /^Doing[[:space:]]+[0-9]+[[:space:]]+bits[[:space:]]+sign[[:space:]]+ecdsa/ {
      bits=$2
      s=""; ops=""
      for(i=1;i<=NF;i++){
        if($i ~ /^[0-9.]+s:$/){
          s=$i; sub(/s:$/,"",s)
          if(i+1<=NF && isnum($(i+1))) ops=$(i+1)
          break
        }
      }
      if(ops!=""){
        sign_ops[bits]=ops
        sign_secs[bits]=(s!=""?s:secs_default)
      }
      next
    }

    /^Doing[[:space:]]+[0-9]+[[:space:]]+bits[[:space:]]+verify[[:space:]]+ecdsa/ {
      bits=$2
      s=""; ops=""
      for(i=1;i<=NF;i++){
        if($i ~ /^[0-9.]+s:$/){
          s=$i; sub(/s:$/,"",s)
          if(i+1<=NF && isnum($(i+1))) ops=$(i+1)
          break
        }
      }
      if(ops!=""){
        verify_ops[bits]=ops
        verify_secs[bits]=(s!=""?s:secs_default)
      }
      next
    }

    END{
      if( (256 in sign_ops) && (256 in verify_ops) ){
        sign_s = sign_ops[256] / sign_secs[256]
        verify_s = verify_ops[256] / verify_secs[256]
        printf "%.1f,%.1f,256\n", sign_s, verify_s
        exit 0
      }

      best=-1
      for(b in sign_ops){
        if( (b in verify_ops) && (b+0 > best) ) best=b+0
      }
      if(best>=0){
        sign_s = sign_ops[best] / sign_secs[best]
        verify_s = verify_ops[best] / verify_secs[best]
        printf "%.1f,%.1f,%d\n", sign_s, verify_s, best
        exit 0
      }

      exit 1
    }
  '
}

# PQC parser:
# Match algorithm row and take last 3 numeric tokens (keygens/s, sign/s, verify/s).
# - case-insensitive
# - allow $1 starting with alg (prefix match)
parse_pqc_row() {
  local alg="$1"
  awk -v alg="$alg" '
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) }
    BEGIN{
      found=0
      IGNORECASE=1
      alg_l=tolower(alg)
    }
    {
      t=tolower($1)
      if(t==alg_l || index(t,alg_l)==1){
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
    }
    END{ exit(found?0:1) }
  '
}

# ---------- Start one long-lived container ----------
echo "=== Signature speed (paper-grade, ROBUST) ==="
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

OPENSSL="$(
  docker exec "${cid}" sh -lc '
    export LC_ALL=C
    OPENSSL=/opt/openssl/bin/openssl
    [ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
    [ -n "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }
    echo "$OPENSSL"
  '
)"

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

# Prefer P-256 specific benchmark if supported, else fallback to generic "ecdsa".
run_speed_ecdsa() {
  out="$(run_in_container "\"${OPENSSL}\" speed -seconds ${BENCH_SECONDS} -provider default ecdsap256 2>&1" || true)"
  if printf "%s\n" "${out}" | grep -qiE "unknown|not supported|invalid|Error|No such"; then
    out="$(run_in_container "\"${OPENSSL}\" speed -seconds ${BENCH_SECONDS} -provider default ecdsa 2>&1" || true)"
  fi
  printf "%s\n" "${out}"
}

run_speed_pqc() {
  local alg="$1"
  run_in_container "\"${OPENSSL}\" speed -seconds ${BENCH_SECONDS} -provider oqsprovider -provider default ${alg} 2>&1" || true
}

# ---------- Discover supported signature algorithms (oqsprovider) ----------
echo "[INFO] $(ts) discovering supported signature algorithms (oqsprovider)..."
sigalgs_out="$(run_in_container "\"${OPENSSL}\" list -signature-algorithms -provider oqsprovider -provider default 2>&1" || true)"
printf "%s\n" "${sigalgs_out}" > "${supportlog}"

supported_set=" "
while IFS= read -r line; do
  l="${line#"${line%%[![:space:]]*}"}"
  [ -z "${l}" ] && continue
  case "${l}" in
    *"Signature algorithms"*|*"Provided"*|*"providers"* ) continue ;;
  esac
  token="${l%%[[:space:]]*}"
  token_l="$(printf "%s" "${token}" | tr '[:upper:]' '[:lower:]')"
  supported_set+=" ${token_l} "
done < "${supportlog}"

is_supported_sigalg() {
  local a_l
  a_l="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "${supported_set}" == *" ${a_l} "* ]]
}

# Build final SIGS list:
SIGS=()
for a in "${SIGS_DESIRED[@]}"; do
  if [ "${a}" = "ecdsap256" ]; then
    SIGS+=("${a}")
    continue
  fi
  if is_supported_sigalg "${a}"; then
    SIGS+=("${a}")
  else
    echo "[INFO] $(ts) alg not supported in this image: ${a}"
  fi
done

echo "[INFO] $(ts) desired SIGS: ${SIGS_DESIRED[*]}"
echo "[INFO] $(ts) bench SIGS (filtered): ${SIGS[*]}"
echo "[INFO] $(ts) supported list saved to: ${supportlog}"

# ---------- Warmup ----------
echo "[INFO] $(ts) warmup=${WARMUP} (not recorded)"
for _ in $(seq 1 "${WARMUP}"); do
  run_speed_ecdsa >/dev/null 2>&1 || true
  for a in "${SIGS_DESIRED[@]}"; do
    [ "${a}" = "ecdsap256" ] && continue
    if is_supported_sigalg "${a}"; then
      run_speed_pqc "$a" >/dev/null 2>&1 || true
    fi
  done
done

# ---------- Main runs ----------
for r in $(seq 1 "${REPEATS}"); do
  # record rows for unsupported algs (kept for robustness; with updated SIGS_DESIRED there should be none)
  for a in "${SIGS_DESIRED[@]}"; do
    [ "${a}" = "ecdsap256" ] && continue
    if ! is_supported_sigalg "${a}"; then
      rawfile="${rawdir}/rep${r}_${a}.txt"
      printf "%s\n" "UNSUPPORTED_ALGORITHM: ${a}" > "${rawfile}"
      warn "Skipping unsupported algorithm (rep=${r} alg=${a}). See ${supportlog}"
      record_row "${r}" "${a}" "" "" "" 0 "UNSUPPORTED_ALGORITHM" "${rawfile}"
    fi
  done

  for alg in "${SIGS[@]}"; do
    rawfile="${rawdir}/rep${r}_${alg}.txt"
    echo "[RUN] rep=${r}/${REPEATS} alg=${alg}"

    if [ "${alg}" = "ecdsap256" ]; then
      out="$(run_speed_ecdsa)"
      printf "%s\n" "${out}" > "${rawfile}"

      sign="" verify="" bits_used=""
      if IFS=',' read -r sign verify bits_used < <(printf "%s\n" "${out}" | parse_ecdsa_rate); then
        if isnum "${sign}" && isnum "${verify}"; then
          err=""
          if [ "${bits_used}" != "256" ]; then
            err="ECDSA_FALLBACK_BITS=${bits_used}"
          fi
          echo "  -> sign/s=${sign} verify/s=${verify} (bits=${bits_used})"
          record_row "${r}" "${alg}" "" "${sign}" "${verify}" 1 "${err}" "${rawfile}"
        else
          warn "ECDSA non-numeric (rep=${r}) sign=${sign:-} verify=${verify:-} raw=${rawfile}"
          record_row "${r}" "${alg}" "" "" "" 0 "ECDSA_NON_NUMERIC" "${rawfile}"
        fi
      else
        warn "ECDSA sign/verify ops not found (rep=${r}) raw=${rawfile}"
        record_row "${r}" "${alg}" "" "" "" 0 "ECDSA_ROW_NOT_FOUND" "${rawfile}"
      fi
      continue
    fi

    out="$(run_speed_pqc "${alg}")"
    printf "%s\n" "${out}" > "${rawfile}"

    if printf "%s\n" "${out}" | grep -qi "Unknown algorithm"; then
      warn "openssl speed: Unknown algorithm (rep=${r} alg=${alg}) raw=${rawfile}"
      record_row "${r}" "${alg}" "" "" "" 0 "UNKNOWN_ALGORITHM" "${rawfile}"
      continue
    fi

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
echo "Supported alg list: ${supportlog}"

if [ "${STRICT}" = "1" ] && [ "${HAD_ERROR}" = "1" ]; then
  echo "[ERROR] $(ts) STRICT=1: one or more algorithms failed/unsupported. See: ${warnlog}" 1>&2
  exit 1
fi
