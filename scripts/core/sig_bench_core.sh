#!/usr/bin/env bash
set -euo pipefail

# Guard: MUST be bash
[ -n "${BASH_VERSION:-}" ] || {
  echo "[ERROR] sig_bench_core.sh must be run with bash" >&2
  exit 2
}

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
[ -x "${OPENSSL}" ] || OPENSSL="$(command -v openssl)"
[ -x "${OPENSSL}" ] || { echo "openssl not found" >&2; exit 127; }

MODULESDIR="$("${OPENSSL}" version -m | awk -F'"' '/MODULESDIR/{print $2}')"
provpath=(-provider-path "${MODULESDIR}")

providers_def=("${provpath[@]}" -provider default)
providers_pqc=("${provpath[@]}" -provider oqsprovider -provider default)

csv="${OUTDIR}/sig_speed.csv"
rawdir="${OUTDIR}/sig_speed_raw"
warnlog="${OUTDIR}/sig_speed_warnings.log"
mkdir -p "${rawdir}"
: > "${warnlog}"

echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s" > "${csv}"

msg="${OUTDIR}/sig_msg.bin"
dd if=/dev/zero of="${msg}" bs="${MSG_BYTES}" count=1 2>/dev/null || echo test > "${msg}"

now_ns(){ date +%s%N; }

bench_loop() {
  local secs="$1"; shift
  local ok=0 fail=0
  local end_s=$(( $(date +%s) + secs ))

  while :; do
    for ((i=0;i<CHUNK;i++)); do
      "$@" >/dev/null 2>&1 && ((ok++)) || ((fail++))
    done
    [ "$(date +%s)" -ge "${end_s}" ] && break
  done

  local elapsed
  elapsed="$(awk -v a="$(now_ns)" -v b="$(now_ns)" 'BEGIN{print (b-a)/1e9}')"
  awk -v n="${ok}" -v s="${elapsed}" 'BEGIN{printf "%.2f,%d,%d\n", n/s, n, 0}'
}

IFS=',' read -r -a ALG_LIST <<< "${SIGS}"

for ((r=1;r<=REPEATS;r++)); do
  for alg in "${ALG_LIST[@]}"; do
    keydir="/tmp/sig_${r}_${alg}"
    mkdir -p "${keydir}"

    if [ "${alg}" = "ecdsap256" ]; then
      "${OPENSSL}" genpkey "${providers_def[@]}" -algorithm EC \
        -pkeyopt ec_paramgen_curve:P-256 -out "${keydir}/k.pem"
      "${OPENSSL}" pkey "${providers_def[@]}" -in "${keydir}/k.pem" -pubout -out "${keydir}/p.pem"
      "${OPENSSL}" dgst "${providers_def[@]}" -sha256 -sign "${keydir}/k.pem" -out "${keydir}/s.bin" "${msg}"
      "${OPENSSL}" dgst "${providers_def[@]}" -sha256 -verify "${keydir}/p.pem" -signature "${keydir}/s.bin" "${msg}"
    else
      "${OPENSSL}" genpkey "${providers_pqc[@]}" -algorithm "${alg}" -out "${keydir}/k.pem"
      "${OPENSSL}" pkey "${providers_pqc[@]}" -in "${keydir}/k.pem" -pubout -out "${keydir}/p.pem"
      "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -sign -inkey "${keydir}/k.pem" -in "${msg}" -out "${keydir}/s.bin"
      "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -verify -pubin -inkey "${keydir}/p.pem" -in "${msg}" -sigfile "${keydir}/s.bin"
    fi

    kg="$(bench_loop "${BENCH_SECONDS}" "${OPENSSL}" genpkey "${providers_pqc[@]}" -algorithm "${alg}" -out "${keydir}/k.pem")"
    sg="$(bench_loop "${BENCH_SECONDS}" "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -sign -inkey "${keydir}/k.pem" -in "${msg}" -out "${keydir}/s.bin")"
    vg="$(bench_loop "${BENCH_SECONDS}" "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -verify -pubin -inkey "${keydir}/p.pem" -in "${msg}" -sigfile "${keydir}/s.bin")"

    IFS=',' read -r kgs _ _ <<< "${kg}"
    IFS=',' read -r sgs _ _ <<< "${sg}"
    IFS=',' read -r vgs _ _ <<< "${vg}"

    echo "${r},${MODE},${BENCH_SECONDS},${alg},${kgs},${sgs},${vgs}" >> "${csv}"
  done
done

echo "${csv}"
