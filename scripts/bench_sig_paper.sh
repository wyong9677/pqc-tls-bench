#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:?IMG is required (e.g., openquantumsafe/oqs-ossl3:latest)}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"              # paper | smoke

REPEATS="${REPEATS:-7}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"

if [ "${MODE}" = "smoke" ]; then
  REPEATS=1
  WARMUP=1
  BENCH_SECONDS=3
fi

SIGS=("ecdsap256" "mldsa44" "mldsa65" "falcon512" "falcon1024")

csv="${RESULTS_DIR}/sig_speed.csv"
rawdir="${RESULTS_DIR}/sig_speed_raw"
mkdir -p "${rawdir}"
echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s" > "${csv}"

echo "=== Signature speed (paper-grade, audited) ==="
echo "mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS}"
echo "IMG=${IMG}"
echo

die() {
  echo "ERROR: $*" 1>&2
  exit 1
}

# Accept: 123 | 123.45 | 1.23e+04
is_num() {
  [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]
}

FIND_OPENSSL='
export LC_ALL=C
OPENSSL=/opt/openssl/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
[ -n "$OPENSSL" ] || { echo "openssl_not_found" 1>&2; exit 127; }
echo "$OPENSSL"
'

# ---- helpers: scan numeric tokens robustly ----
# Return the first numeric token in the current line; else empty
awk_first_num='
function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) }
{
  for(i=1;i<=NF;i++){
    if(isnum($i)){ print $i; exit 0 }
  }
  print ""
}
'

# Parse PQC "block-ish" output by scanning the first numeric token after each marker.
parse_block_pqc() {
  awk '
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) }
    function firstnum(   i){ for(i=1;i<=NF;i++) if(isnum($i)) return $i; return "" }

    /keygens\/s/ { v=firstnum(); if(v!="") kg=v }
    /signs\/s/   { v=firstnum(); if(v!="") sg=v }
    /verifs\/s/  { v=firstnum(); if(v!="") vf=v }

    END { print kg "," sg "," vf }
  '
}

# Parse PQC from a line containing alg and at least 3 numeric tokens anywhere on that line.
parse_table_row_alg_any() {
  local alg="$1"
  awk -v A="${alg}" '
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) }
    function collect3(   i,c,arr){
      c=0
      for(i=1;i<=NF;i++){
        if(isnum($i)){ c++; arr[c]=$i; if(c==3) break }
      }
      if(c==3) print arr[1] "," arr[2] "," arr[3]; else print ",,"
    }

    # match if algorithm name appears as a whole word on the line
    {
      line=$0
      if(line ~ ("(^|[[:space:]])" A "([[:space:]]|$)")){
        collect3()
        found=1
        exit 0
      }
    }
    END { if(!found) print ",," }
  '
}

# ECDSA: parse from block (rare)
parse_block_ecdsa() {
  awk '
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) }
    function firstnum(   i){ for(i=1;i<=NF;i++) if(isnum($i)) return $i; return "" }

    /signs\/s/  { v=firstnum(); if(v!="") sg=v }
    /verifs\/s/ { v=firstnum(); if(v!="") vf=v }
    END { print sg "," vf }
  '
}

# ECDSA: parse from standard table row containing "256 bits" and "ecdsa" by taking last 2 numeric tokens.
parse_ecdsa_256_table() {
  awk '
    function tolower_str(s,    i,c,out){ out=""; for(i=1;i<=length(s);i++){c=substr(s,i,1); out=out tolower(c)}; return out }
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) }

    {
      low=tolower_str($0)
      if (low ~ /256 bits/ && low ~ /ecdsa/) {
        # scan numeric tokens, keep the last two
        s=""; v=""
        for(i=1;i<=NF;i++){
          if(isnum($i)){ s=v; v=$i }
        }
        if(isnum(s) && isnum(v)){
          print s "," v
          found=1
          exit 0
        }
      }
    }
    END { if(!found) print "," }
  '
}

# ---- runners (capture stdout+stderr!) ----
run_speed_pqc() {
  local alg="$1"
  docker run --rm "${IMG}" sh -lc "
    set -e
    OPENSSL=\$(${FIND_OPENSSL})
    \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider oqsprovider -provider default ${alg} 2>&1 || true
  "
}

run_speed_ecdsa() {
  docker run --rm "${IMG}" sh -lc "
    set -e
    OPENSSL=\$(${FIND_OPENSSL})

    if \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider default ecdsap256 >/tmp/out 2>&1; then
      cat /tmp/out
      exit 0
    fi

    \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider default ecdsa 2>&1 || true
  "
}

# ---- warmup ----
for _ in $(seq 1 "${WARMUP}"); do
  run_speed_ecdsa >/dev/null 2>&1 || true
  for alg in "mldsa44" "mldsa65" "falcon512" "falcon1024"; do
    run_speed_pqc "$alg" >/dev/null 2>&1 || true
  done
done

# ---- measure ----
for r in $(seq 1 "${REPEATS}"); do
  for alg in "${SIGS[@]}"; do
    if [ "${alg}" = "ecdsap256" ]; then
      out="$(run_speed_ecdsa || true)"
    else
      out="$(run_speed_pqc "${alg}" || true)"
    fi

    raw="${rawdir}/rep${r}_${alg}.txt"
    printf "%s\n" "$out" > "${raw}"

    keygens="" ; sign="" ; verify=""

    if [ "${alg}" = "ecdsap256" ]; then
      if printf "%s\n" "$out" | grep -q "signs/s"; then
        IFS=',' read -r sign verify < <(printf "%s\n" "$out" | parse_block_ecdsa)
      else
        IFS=',' read -r sign verify < <(printf "%s\n" "$out" | parse_ecdsa_256_table)
      fi

      if ! is_num "${sign:-}" || ! is_num "${verify:-}"; then
        echo "---- raw head (${raw}) ----" 1>&2
        sed -n '1,120p' "${raw}" 1>&2 || true
        die "ECDSA sign/verify missing/non-numeric (rep=${r}). See ${raw}"
      fi

      echo "rep=${r} alg=${alg} sign/s=${sign} verify/s=${verify}"
      echo "${r},${MODE},${BENCH_SECONDS},${alg},,${sign},${verify}" >> "${csv}"
      continue
    fi

    # PQC: try "alg line with 3 nums"
    IFS=',' read -r keygens sign verify < <(printf "%s\n" "$out" | parse_table_row_alg_any "${alg}")
    # fallback: block scan
    if ! is_num "${keygens:-}" || ! is_num "${sign:-}" || ! is_num "${verify:-}"; then
      IFS=',' read -r keygens sign verify < <(printf "%s\n" "$out" | parse_block_pqc)
    fi

    if ! is_num "${keygens:-}" || ! is_num "${sign:-}" || ! is_num "${verify:-}"; then
      echo "---- raw head (${raw}) ----" 1>&2
      sed -n '1,120p' "${raw}" 1>&2 || true
      die "PQC metrics missing/non-numeric for alg=${alg} (rep=${r}). See ${raw}"
    fi

    echo "rep=${r} alg=${alg} keygens/s=${keygens} sign/s=${sign} verify/s=${verify}"
    echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens},${sign},${verify}" >> "${csv}"
  done
done

# final audit: forbid header tokens leaking into numeric fields
if awk -F',' 'NR>1 && ($5 ~ /signs|verifs|keygens/ || $6 ~ /signs|verifs|keygens/ || $7 ~ /signs|verifs|keygens/) {exit 1}' "${csv}"; then
  :
else
  die "CSV audit failed: header tokens leaked into numeric columns. Check raw outputs under ${rawdir}"
fi

echo
echo "CSV: ${csv}"
echo "Raw: ${rawdir}/rep*_*.txt"
