#!/usr/bin/env bash
set -euo pipefail

OUTDIR="${1:?usage: sig_bench_core.sh /out}"
mkdir -p "${OUTDIR}"

MODE="${MODE:-paper}"
REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"
STRICT="${STRICT:-1}"
MSG_BYTES="${MSG_BYTES:-32}"
CHUNK="${CHUNK:-200}"

SIGS_DEFAULT="ecdsap256,mldsa44,mldsa65,falcon512,falcon1024"
SIGS="${SIGS:-${SIGS_DEFAULT}}"

OPENSSL="/opt/openssl/bin/openssl"
[ -x "${OPENSSL}" ] || OPENSSL="$(command -v openssl 2>/dev/null || true)"
[ -x "${OPENSSL}" ] || { echo "[ERROR] openssl not found" >&2; exit 127; }

csv="${OUTDIR}/sig_speed.csv"
rawdir="${OUTDIR}/sig_speed_raw"
warnlog="${OUTDIR}/sig_speed_warnings.log"
mkdir -p "${rawdir}"
: > "${warnlog}"

ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
info(){ echo "[INFO] $(ts) $*"; }
warn(){ echo "[WARN] $(ts) $*" | tee -a "${warnlog}" >&2; }
die(){  echo "[ERROR] $(ts) $*" >&2; exit 1; }

MODULESDIR="$("${OPENSSL}" version -m 2>/dev/null | awk -F'"' '/MODULESDIR/{print $2; exit}' || true)"
provpath=()
[ -n "${MODULESDIR}" ] && provpath=(-provider-path "${MODULESDIR}")

providers_def=("${provpath[@]}" -provider default)
providers_pqc=("${provpath[@]}" -provider oqsprovider -provider default)

echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s,keygens_ok,signs_ok,verifies_ok,keygens_fail,signs_fail,verifies_fail,notes,raw_keygen,raw_sign,raw_verify" > "${csv}"

msg="${OUTDIR}/sig_msg.bin"
if ! dd if=/dev/zero of="${msg}" bs="${MSG_BYTES}" count=1 2>/dev/null; then
  printf "hello\n" > "${msg}"
fi

now_s(){ date +%s; }

bench_loop() {
  local secs="$1"; shift
  local ok=0 fail=0
  local start_s end_s elapsed_s ops_s
  local deadline chunk_i

  start_s="$(now_s)"
  deadline=$(( start_s + secs ))

  while :; do
    chunk_i=0
    while [ "${chunk_i}" -lt "${CHUNK}" ]; do
      if "$@" >/dev/null 2>&1; then
        ok=$((ok+1))
      else
        fail=$((fail+1))
      fi
      chunk_i=$((chunk_i+1))
    done
    [ "$(now_s)" -ge "${deadline}" ] && break
  done

  end_s="$(now_s)"
  elapsed_s="$(awk -v a="$start_s" -v b="$end_s" 'BEGIN{print b-a}')"
  ops_s="$(awk -v n="$ok" -v s="$elapsed_s" 'BEGIN{ if(s>0) printf "%.2f", n/s; else print "0.00" }')"
  echo "${ops_s},${ok},${fail}"
}

provider_sanity() {
  "${OPENSSL}" list -providers "${provpath[@]}" -provider default >/dev/null 2>&1 \
    || die "default provider unavailable"

  if echo "${SIGS}" | grep -Eq '(mldsa|falcon)'; then
    if ! "${OPENSSL}" list -providers "${provpath[@]}" -provider oqsprovider -provider default >/dev/null 2>&1; then
      [ "${STRICT}" = "1" ] && die "oqsprovider required but unavailable"
      warn "oqsprovider unavailable; PQC results may be invalid"
    fi
  fi
}

# ---- smoke checks omitted for brevity (same as yours, unchanged) ----
# ---- main loop omitted for brevity (logic unchanged) ----

info "Signature core bench ready (paper-grade)"
