#!/usr/bin/env bash
set -euo pipefail

OUTDIR="${1:?usage: sig_bench_core.sh /out}"
mkdir -p "${OUTDIR}"

MODE="${MODE:-paper}"
REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"
STRICT="${STRICT:-1}"

# Algorithms (keep names consistent with your tables)
SIGS_DEFAULT="ecdsap256,mldsa44,mldsa65,falcon512,falcon1024"
SIGS="${SIGS:-${SIGS_DEFAULT}}"

OPENSSL="/opt/openssl/bin/openssl"
if [ ! -x "${OPENSSL}" ]; then OPENSSL="$(command -v openssl)"; fi

csv="${OUTDIR}/sig_speed.csv"
rawdir="${OUTDIR}/sig_speed_raw"
warnlog="${OUTDIR}/sig_speed_warnings.log"
mkdir -p "${rawdir}"
: > "${warnlog}"

echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s,keygens_ok,signs_ok,verifies_ok,keygens_fail,signs_fail,verifies_fail,notes,raw_keygen,raw_sign,raw_verify" > "${csv}"

msg="${OUTDIR}/sig_msg.bin"
printf "hello\n" > "${msg}"

providers_pqc=(-provider oqsprovider -provider default)
providers_def=(-provider default)

now_ns() { date +%s%N; }

bench_loop() {
  # args: seconds, cmd...
  local secs="$1"; shift
  local t0 t1 deadline ok=0 fail=0 rc
  t0="$(now_ns)"
  deadline="$((t0 + secs*1000000000))"
  while :; do
    t1="$(now_ns)"
    [ "${t1}" -ge "${deadline}" ] && break
    if "$@" >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      fail=$((fail+1))
    fi
  done
  t1="$(now_ns)"
  local elapsed_s
  elapsed_s="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.6f",(b-a)/1000000000.0}')"
  local ops_s
  ops_s="$(awk -v n="$ok" -v s="$elapsed_s" 'BEGIN{if(s>0) printf "%.2f", n/s; else print "0"}')"
  echo "${ops_s},${ok},${fail}"
}

smoke_check_ecdsa() {
  local d="$1"
  mkdir -p "${d}"
  "${OPENSSL}" genpkey "${providers_def[@]}" -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${d}/key.pem" >/dev/null 2>&1 || return 1
  "${OPENSSL}" pkey "${providers_def[@]}" -in "${d}/key.pem" -pubout -out "${d}/pub.pem" >/dev/null 2>&1 || return 1
  "${OPENSSL}" dgst "${providers_def[@]}" -sha256 -sign "${d}/key.pem" -out "${d}/sig.bin" "${msg}" >/dev/null 2>&1 || return 1
  "${OPENSSL}" dgst "${providers_def[@]}" -sha256 -verify "${d}/pub.pem" -signature "${d}/sig.bin" "${msg}" >/dev/null 2>&1 || return 1
  return 0
}

smoke_check_pqc() {
  local alg="$1" d="$2"
  mkdir -p "${d}"
  "${OPENSSL}" genpkey "${providers_pqc[@]}" -algorithm "${alg}" -out "${d}/key.pem" >/dev/null 2>&1 || return 1
  "${OPENSSL}" pkey "${providers_pqc[@]}" -in "${d}/key.pem" -pubout -out "${d}/pub.pem" >/dev/null 2>&1 || return 1
  "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -sign -inkey "${d}/key.pem" -in "${msg}" -out "${d}/sig.bin" >/dev/null 2>&1 || return 1
  "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -verify -pubin -inkey "${d}/pub.pem" -in "${msg}" -sigfile "${d}/sig.bin" >/dev/null 2>&1 || return 1
  return 0
}

IFS=',' read -r -a ALG_LIST <<< "${SIGS}"

# Warmup (not recorded): just do one smoke per alg to load provider/caches
for _ in $(seq 1 "${WARMUP}"); do
  for alg in "${ALG_LIST[@]}"; do
    d="/tmp/sig_warm_${alg}"
    if [ "${alg}" = "ecdsap256" ]; then
      smoke_check_ecdsa "${d}" >/dev/null 2>&1 || true
    else
      smoke_check_pqc "${alg}" "${d}" >/dev/null 2>&1 || true
    fi
  done
done

for r in $(seq 1 "${REPEATS}"); do
  echo "[INFO] rep=${r}/${REPEATS} seconds=${BENCH_SECONDS}"
  for alg in "${ALG_LIST[@]}"; do
    notes=""
    base="${rawdir}/rep${r}_${alg}"
    keydir="/tmp/sig_${r}_${alg}"
    mkdir -p "${keydir}"

    # smoke must pass (otherwise measurements meaningless)
    if [ "${alg}" = "ecdsap256" ]; then
      if ! smoke_check_ecdsa "${keydir}"; then
        notes="SMOKE_FAILED"
        echo "[WARN] ${alg} smoke failed" | tee -a "${warnlog}" >/dev/null
        if [ "${STRICT}" = "1" ]; then
          echo "[ERROR] STRICT=1 and smoke failed for ${alg}" | tee -a "${warnlog}" >/dev/null
          exit 1
        fi
      fi
    else
      if ! smoke_check_pqc "${alg}" "${keydir}"; then
        notes="SMOKE_FAILED"
        echo "[WARN] ${alg} smoke failed" | tee -a "${warnlog}" >/dev/null
        if [ "${STRICT}" = "1" ]; then
          echo "[ERROR] STRICT=1 and smoke failed for ${alg}" | tee -a "${warnlog}" >/dev/null
          exit 1
        fi
      fi
    fi

    # KEYGEN bench
    key_raw="${base}_keygen.txt"
    if [ "${alg}" = "ecdsap256" ]; then
      res="$(bench_loop "${BENCH_SECONDS}" "${OPENSSL}" genpkey "${providers_def[@]}" -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${keydir}/key.pem")"
    else
      res="$(bench_loop "${BENCH_SECONDS}" "${OPENSSL}" genpkey "${providers_pqc[@]}" -algorithm "${alg}" -out "${keydir}/key.pem")"
    fi
    echo "${res}" > "${key_raw}"
    IFS=',' read -r keygens_s key_ok key_fail <<< "${res}"

    # Prepare fixed key + pub + sig for sign/verify loops
    if [ "${alg}" = "ecdsap256" ]; then
      "${OPENSSL}" genpkey "${providers_def[@]}" -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${keydir}/fixed_key.pem" >/dev/null 2>&1
      "${OPENSSL}" pkey   "${providers_def[@]}" -in "${keydir}/fixed_key.pem" -pubout -out "${keydir}/fixed_pub.pem" >/dev/null 2>&1
      "${OPENSSL}" dgst   "${providers_def[@]}" -sha256 -sign "${keydir}/fixed_key.pem" -out "${keydir}/fixed_sig.bin" "${msg}" >/dev/null 2>&1
    else
      "${OPENSSL}" genpkey "${providers_pqc[@]}" -algorithm "${alg}" -out "${keydir}/fixed_key.pem" >/dev/null 2>&1
      "${OPENSSL}" pkey   "${providers_pqc[@]}" -in "${keydir}/fixed_key.pem" -pubout -out "${keydir}/fixed_pub.pem" >/dev/null 2>&1
      "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -sign -inkey "${keydir}/fixed_key.pem" -in "${msg}" -out "${keydir}/fixed_sig.bin" >/dev/null 2>&1
    fi

    # SIGN bench (reuse fixed key; overwrite sig output)
    sign_raw="${base}_sign.txt"
    if [ "${alg}" = "ecdsap256" ]; then
      res="$(bench_loop "${BENCH_SECONDS}" "${OPENSSL}" dgst "${providers_def[@]}" -sha256 -sign "${keydir}/fixed_key.pem" -out "${keydir}/sig.bin" "${msg}")"
    else
      res="$(bench_loop "${BENCH_SECONDS}" "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -sign -inkey "${keydir}/fixed_key.pem" -in "${msg}" -out "${keydir}/sig.bin")"
    fi
    echo "${res}" > "${sign_raw}"
    IFS=',' read -r sign_s sign_ok sign_fail <<< "${res}"

    # VERIFY bench (reuse fixed pub+sig)
    verify_raw="${base}_verify.txt"
    if [ "${alg}" = "ecdsap256" ]; then
      res="$(bench_loop "${BENCH_SECONDS}" "${OPENSSL}" dgst "${providers_def[@]}" -sha256 -verify "${keydir}/fixed_pub.pem" -signature "${keydir}/fixed_sig.bin" "${msg}")"
    else
      res="$(bench_loop "${BENCH_SECONDS}" "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -verify -pubin -inkey "${keydir}/fixed_pub.pem" -in "${msg}" -sigfile "${keydir}/fixed_sig.bin")"
    fi
    echo "${res}" > "${verify_raw}"
    IFS=',' read -r verify_s verify_ok verify_fail <<< "${res}"

    # Hard correctness guard for paper-grade
    if [ "${STRICT}" = "1" ]; then
      if awk "BEGIN{exit !(${verify_ok}>0)}"; then :; else
        echo "[ERROR] verify_ok==0 for ${alg} (rep=${r}). This indicates verify path is broken." | tee -a "${warnlog}" >/dev/null
        exit 1
      fi
    fi

    echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens_s},${sign_s},${verify_s},${key_ok},${sign_ok},${verify_ok},${key_fail},${sign_fail},${verify_fail},${notes},${key_raw},${sign_raw},${verify_raw}" >> "${csv}"
    echo "  -> ${alg} keygens/s=${keygens_s} sign/s=${sign_s} verify/s=${verify_s}"
  done
done

echo "${csv}"
echo "${warnlog}"
