#!/usr/bin/env sh
set -eu

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
SIGS="${SIGS:-$SIGS_DEFAULT}"

ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date; }
info(){ echo "[INFO] $(ts) $*"; }
warn(){ echo "[WARN] $(ts) $*" >&2; }
die(){  echo "[ERROR] $(ts) $*" >&2; exit 1; }

OPENSSL="/opt/openssl/bin/openssl"
if [ ! -x "$OPENSSL" ]; then
  OPENSSL="$(command -v openssl 2>/dev/null || true)"
fi
[ -n "${OPENSSL}" ] && [ -x "${OPENSSL}" ] || die "openssl not found"

MODULESDIR="$("${OPENSSL}" version -m 2>/dev/null | awk -F'"' '/MODULESDIR/{print $2; exit}' || true)"
[ -n "${MODULESDIR}" ] || MODULESDIR="/usr/local/lib/ossl-modules"

csv="${OUTDIR}/sig_speed.csv"
rawdir="${OUTDIR}/sig_speed_raw"
warnlog="${OUTDIR}/sig_speed_warnings.log"
mkdir -p "${rawdir}"
: > "${warnlog}"

echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s" > "${csv}"

msg="${OUTDIR}/sig_msg.bin"
dd if=/dev/zero of="${msg}" bs="${MSG_BYTES}" count=1 2>/dev/null || printf "hello\n" > "${msg}"

prov_def="-provider-path ${MODULESDIR} -provider default"
prov_pqc="-provider-path ${MODULESDIR} -provider oqsprovider -provider default"

provider_sanity() {
  if ! ${OPENSSL} list -providers -provider-path "${MODULESDIR}" -provider default >/dev/null 2>&1; then
    die "default provider cannot be loaded (MODULESDIR=${MODULESDIR})"
  fi
  # only require oqsprovider when SIGS includes pqc algs and STRICT=1
  if echo "${SIGS}" | grep -Eq '(mldsa|falcon)'; then
    if ! ${OPENSSL} list -providers -provider-path "${MODULESDIR}" -provider oqsprovider -provider default >/dev/null 2>&1; then
      if [ "${STRICT}" = "1" ]; then
        die "oqsprovider missing/unloadable (MODULESDIR=${MODULESDIR}) but PQC requested"
      else
        warn "oqsprovider missing/unloadable; PQC benches may fail (STRICT=0)"
      fi
    fi
  fi
}

keygen_once() {
  alg="$1"; key="$2"
  case "$alg" in
    ecdsap256)
      ${OPENSSL} genpkey ${prov_def} -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$key" >/dev/null 2>&1
      ;;
    *)
      ${OPENSSL} genpkey ${prov_pqc} -algorithm "$alg" -out "$key" >/dev/null 2>&1
      ;;
  esac
}

pubout_once() {
  alg="$1"; key="$2"; pub="$3"
  case "$alg" in
    ecdsap256) ${OPENSSL} pkey ${prov_def} -in "$key" -pubout -out "$pub" >/dev/null 2>&1 ;;
    *)         ${OPENSSL} pkey ${prov_pqc} -in "$key" -pubout -out "$pub" >/dev/null 2>&1 ;;
  esac
}

sign_once() {
  alg="$1"; key="$2"; msg="$3"; sig="$4"
  case "$alg" in
    ecdsap256) ${OPENSSL} dgst ${prov_def} -sha256 -sign "$key" -out "$sig" "$msg" >/dev/null 2>&1 ;;
    *)         ${OPENSSL} pkeyutl ${prov_pqc} -sign -inkey "$key" -in "$msg" -out "$sig" >/dev/null 2>&1 ;;
  esac
}

verify_once() {
  alg="$1"; pub="$2"; msg="$3"; sig="$4"
  case "$alg" in
    ecdsap256) ${OPENSSL} dgst ${prov_def} -sha256 -verify "$pub" -signature "$sig" "$msg" >/dev/null 2>&1 ;;
    *)         ${OPENSSL} pkeyutl ${prov_pqc} -verify -pubin -inkey "$pub" -in "$msg" -sigfile "$sig" >/dev/null 2>&1 ;;
  esac
}

bench_window() {
  # prints count within BENCH_SECONDS, chunked time check
  which="$1"; alg="$2"; key="$3"; pub="$4"; msg="$5"; sig="$6"; secs="$7"
  end=$(( $(date +%s) + secs ))
  c=0
  while :; do
    i=0
    while [ "$i" -lt "${CHUNK}" ]; do
      case "$which" in
        keygen) keygen_once "$alg" "$key" && c=$((c+1)) || true ;;
        sign)   sign_once   "$alg" "$key" "$msg" "$sig" && c=$((c+1)) || true ;;
        verify) verify_once "$alg" "$pub" "$msg" "$sig" && c=$((c+1)) || true ;;
      esac
      i=$((i+1))
    done
    [ "$(date +%s)" -ge "$end" ] && break
  done
  echo "$c"
}

rate() {
  c="$1"; t="$2"
  awk -v c="$c" -v t="$t" 'BEGIN{ if(t<=0){print "nan"; exit} printf "%.1f", (c/t) }'
}

provider_sanity
info "Signature core: mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS} STRICT=${STRICT}"
info "OPENSSL=${OPENSSL} MODULESDIR=${MODULESDIR}"

# parse SIGS list
OLDIFS=$IFS
IFS=','; set -- $SIGS; IFS=$OLDIFS

# warmup (not recorded): just do one functional smoke
w=1
while [ "$w" -le "${WARMUP}" ]; do
  for alg in "$@"; do
    d="/tmp/sig_warm_${alg}"
    mkdir -p "$d"
    key="$d/key.pem"; pub="$d/pub.pem"; sig="$d/sig.bin"
    keygen_once "$alg" "$key" || true
    pubout_once "$alg" "$key" "$pub" || true
    sign_once   "$alg" "$key" "$msg" "$sig" || true
    verify_once "$alg" "$pub" "$msg" "$sig" || true
  done
  w=$((w+1))
done

r=1
while [ "$r" -le "${REPEATS}" ]; do
  for alg in "$@"; do
    d="/tmp/sig_${r}_${alg}"
    mkdir -p "$d"
    key="$d/key.pem"; pub="$d/pub.pem"; sig="$d/sig.bin"

    # smoke must pass if STRICT=1
    if ! keygen_once "$alg" "$key"; then
      echo "[WARN] KEYGEN_FAILED rep=${r} alg=${alg}" >> "${warnlog}"
      [ "${STRICT}" = "1" ] && die "KEYGEN_FAILED rep=${r} alg=${alg}"
      continue
    fi
    pubout_once "$alg" "$key" "$pub" || { [ "${STRICT}" = "1" ] && die "PUBOUT_FAILED rep=${r} alg=${alg}"; continue; }
    sign_once   "$alg" "$key" "$msg" "$sig" || { [ "${STRICT}" = "1" ] && die "SIGN_FAILED rep=${r} alg=${alg}"; continue; }
    verify_once "$alg" "$pub" "$msg" "$sig" || { [ "${STRICT}" = "1" ] && die "VERIFY_FAILED rep=${r} alg=${alg}"; continue; }

    kc="$(bench_window keygen "$alg" "$key" "$pub" "$msg" "$sig" "${BENCH_SECONDS}")"
    sc="$(bench_window sign   "$alg" "$key" "$pub" "$msg" "$sig" "${BENCH_SECONDS}")"
    vc="$(bench_window verify "$alg" "$key" "$pub" "$msg" "$sig" "${BENCH_SECONDS}")"

    keygens_s="$(rate "$kc" "${BENCH_SECONDS}")"
    sign_s="$(rate "$sc" "${BENCH_SECONDS}")"
    verify_s="$(rate "$vc" "${BENCH_SECONDS}")"

    printf "%s\n" "${kc},${sc},${vc}" > "${rawdir}/rep${r}_${alg}.txt"
    echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens_s},${sign_s},${verify_s}" >> "${csv}"
    info "rep=${r}/${REPEATS} alg=${alg} keygens/s=${keygens_s} sign/s=${sign_s} verify/s=${verify_s}"
  done
  r=$((r+1))
done

echo "${csv}"
echo "${warnlog}"
