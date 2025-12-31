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
CHUNK="${CHUNK:-200}"     # 每次检查一次时间，减少计时开销（论文级建议 200~500）

# Algorithms (names consistent with tables)
SIGS_DEFAULT="ecdsap256,mldsa44,mldsa65,falcon512,falcon1024"
SIGS="${SIGS:-${SIGS_DEFAULT}}"

OPENSSL="/opt/openssl/bin/openssl"
if [ ! -x "${OPENSSL}" ]; then
  OPENSSL="$(command -v openssl 2>/dev/null || true)"
fi
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

# ---- Determine MODULESDIR and enforce provider-path (stability across runners/images) ----
MODULESDIR="$("${OPENSSL}" version -m 2>/dev/null | awk -F'"' '/MODULESDIR/{print $2; exit}' || true)"
if [ -z "${MODULESDIR}" ]; then
  # conservative fallback (won't hurt if unused)
  MODULESDIR="/usr/local/lib/ossl-modules"
fi
provpath=(-provider-path "${MODULESDIR}")

providers_def=("${provpath[@]}" -provider default)
providers_pqc=("${provpath[@]}" -provider oqsprovider -provider default)

# CSV header: keep first 7 columns compatible with summarize_results.py
echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s,keygens_ok,signs_ok,verifies_ok,keygens_fail,signs_fail,verifies_fail,notes,raw_keygen,raw_sign,raw_verify" > "${csv}"

# message
msg="${OUTDIR}/sig_msg.bin"
dd if=/dev/zero of="${msg}" bs="${MSG_BYTES}" count=1 2>/dev/null || printf "hello\n" > "${msg}"

now_ns() { date +%s%N; }

# bench_loop: reduced timing overhead via chunked execution
# prints: ops_s,ok,fail
bench_loop() {
  local secs="$1"; shift
  local ok=0 fail=0
  local start_ns end_ns elapsed_s
  local end_s chunk_i

  start_ns="$(now_ns)"
  end_s=$(( $(date +%s) + secs ))

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

    # 只在每个 chunk 后检查一次时间
    [ "$(date +%s)" -ge "${end_s}" ] && break
  done

  end_ns="$(now_ns)"
  elapsed_s="$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{printf "%.6f",(b-a)/1000000000.0}')"
  # 用 ok 计算吞吐（失败会自然拉低 ok）
  local ops_s
  ops_s="$(awk -v n="$ok" -v s="$elapsed_s" 'BEGIN{ if(s>0) printf "%.2f", n/s; else print "0.00" }')"
  echo "${ops_s},${ok},${fail}"
}

# provider sanity (fail-fast for paper)
provider_sanity() {
  # default provider should always work
  if ! "${OPENSSL}" list -providers "${provpath[@]}" -provider default >/dev/null 2>&1; then
    die "default provider cannot be loaded (MODULESDIR=${MODULESDIR})"
  fi

  # oqsprovider may be absent depending on image; in STRICT=1 we must fail if PQC algs requested
  if ! "${OPENSSL}" list -providers "${provpath[@]}" -provider oqsprovider -provider default >/dev/null 2>&1; then
    if [[ "${SIGS}" == *mldsa* || "${SIGS}" == *falcon* ]]; then
      if [ "${STRICT}" = "1" ]; then
        die "oqsprovider cannot be loaded (MODULESDIR=${MODULESDIR}). PQC benchmarks requested but provider missing."
      else
        warn "oqsprovider cannot be loaded; PQC benches likely to fail. STRICT=0 so continuing."
      fi
    fi
  fi
}

smoke_check_ecdsa() {
  local d="$1"
  mkdir -p "${d}"
  "${OPENSSL}" genpkey "${providers_def[@]}" -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${d}/key.pem" >/dev/null 2>&1 || return 1
  "${OPENSSL}" pkey   "${providers_def[@]}" -in "${d}/key.pem" -pubout -out "${d}/pub.pem" >/dev/null 2>&1 || return 1
  "${OPENSSL}" dgst   "${providers_def[@]}" -sha256 -sign "${d}/key.pem" -out "${d}/sig.bin" "${msg}" >/dev/null 2>&1 || return 1
  "${OPENSSL}" dgst   "${providers_def[@]}" -sha256 -verify "${d}/pub.pem" -signature "${d}/sig.bin" "${msg}" >/dev/null 2>&1 || return 1
  return 0
}

smoke_check_pqc() {
  local alg="$1" d="$2"
  mkdir -p "${d}"
  "${OPENSSL}" genpkey "${providers_pqc[@]}" -algorithm "${alg}" -out "${d}/key.pem" >/dev/null 2>&1 || return 1
  "${OPENSSL}" pkey   "${providers_pqc[@]}" -in "${d}/key.pem" -pubout -out "${d}/pub.pem" >/dev/null 2>&1 || return 1
  "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -sign -inkey "${d}/key.pem" -in "${msg}" -out "${d}/sig.bin" >/dev/null 2>&1 || return 1
  "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -verify -pubin -inkey "${d}/pub.pem" -in "${msg}" -sigfile "${d}/sig.bin" >/dev/null 2>&1 || return 1
  return 0
}

IFS=',' read -r -a ALG_LIST <<< "${SIGS}"

info "Signature core bench: mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS} STRICT=${STRICT} MSG_BYTES=${MSG_BYTES} CHUNK=${CHUNK}"
info "OPENSSL=${OPENSSL} MODULESDIR=${MODULESDIR}"
provider_sanity

# Warmup (not recorded): load modules/caches
info "Warmup=${WARMUP} (not recorded)"
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
  info "rep=${r}/${REPEATS} seconds=${BENCH_SECONDS}"
  for alg in "${ALG_LIST[@]}"; do
    notes=""
    base="${rawdir}/rep${r}_${alg}"
    keydir="/tmp/sig_${r}_${alg}"
    mkdir -p "${keydir}"

    # smoke must pass to be meaningful (paper-grade)
    if [ "${alg}" = "ecdsap256" ]; then
      if ! smoke_check_ecdsa "${keydir}"; then
        notes="SMOKE_FAILED"
        warn "${alg} smoke failed"
        [ "${STRICT}" = "1" ] && die "STRICT=1 and smoke failed for ${alg}"
      fi
    else
      if ! smoke_check_pqc "${alg}" "${keydir}"; then
        notes="SMOKE_FAILED"
        warn "${alg} smoke failed"
        [ "${STRICT}" = "1" ] && die "STRICT=1 and smoke failed for ${alg}"
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

    # Prepare fixed key + pub + sig for sign/verify loops (fail-fast under set -e)
    if [ "${alg}" = "ecdsap256" ]; then
      "${OPENSSL}" genpkey "${providers_def[@]}" -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${keydir}/fixed_key.pem" >/dev/null 2>&1
      "${OPENSSL}" pkey   "${providers_def[@]}" -in "${keydir}/fixed_key.pem" -pubout -out "${keydir}/fixed_pub.pem" >/dev/null 2>&1
      "${OPENSSL}" dgst   "${providers_def[@]}" -sha256 -sign "${keydir}/fixed_key.pem" -out "${keydir}/fixed_sig.bin" "${msg}" >/dev/null 2>&1
    else
      "${OPENSSL}" genpkey "${providers_pqc[@]}" -algorithm "${alg}" -out "${keydir}/fixed_key.pem" >/dev/null 2>&1
      "${OPENSSL}" pkey   "${providers_pqc[@]}" -in "${keydir}/fixed_key.pem" -pubout -out "${keydir}/fixed_pub.pem" >/dev/null 2>&1
      "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -sign -inkey "${keydir}/fixed_key.pem" -in "${msg}" -out "${keydir}/fixed_sig.bin" >/dev/null 2>&1
    fi

    # SIGN bench
    sign_raw="${base}_sign.txt"
    if [ "${alg}" = "ecdsap256" ]; then
      res="$(bench_loop "${BENCH_SECONDS}" "${OPENSSL}" dgst "${providers_def[@]}" -sha256 -sign "${keydir}/fixed_key.pem" -out "${keydir}/sig.bin" "${msg}")"
    else
      res="$(bench_loop "${BENCH_SECONDS}" "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -sign -inkey "${keydir}/fixed_key.pem" -in "${msg}" -out "${keydir}/sig.bin")"
    fi
    echo "${res}" > "${sign_raw}"
    IFS=',' read -r sign_s sign_ok sign_fail <<< "${res}"

    # VERIFY bench
    verify_raw="${base}_verify.txt"
    if [ "${alg}" = "ecdsap256" ]; then
      res="$(bench_loop "${BENCH_SECONDS}" "${OPENSSL}" dgst "${providers_def[@]}" -sha256 -verify "${keydir}/fixed_pub.pem" -signature "${keydir}/fixed_sig.bin" "${msg}")"
    else
      res="$(bench_loop "${BENCH_SECONDS}" "${OPENSSL}" pkeyutl "${providers_pqc[@]}" -verify -pubin -inkey "${keydir}/fixed_pub.pem" -in "${msg}" -sigfile "${keydir}/fixed_sig.bin")"
    fi
    echo "${res}" > "${verify_raw}"
    IFS=',' read -r verify_s verify_ok verify_fail <<< "${res}"

    # Paper-grade correctness guard
    if [ "${STRICT}" = "1" ]; then
      if ! awk "BEGIN{exit !(${verify_ok}>0)}"; then
        die "verify_ok==0 for ${alg} (rep=${r}). Verify path broken."
      fi
    fi

    echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens_s},${sign_s},${verify_s},${key_ok},${sign_ok},${verify_ok},${key_fail},${sign_fail},${verify_fail},${notes},${key_raw},${sign_raw},${verify_raw}" >> "${csv}"
    info "  -> ${alg} keygens/s=${keygens_s} sign/s=${sign_s} verify/s=${verify_s}"
  done
done

echo "${csv}"
echo "${warnlog}"
