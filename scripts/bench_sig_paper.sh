#!/usr/bin/env bash
set -euo pipefail

# ======================
# Config
# ======================
IMG="${IMG:?IMG is required (e.g., openquantumsafe/oqs-ossl3:latest)}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"              # paper | smoke

REPEATS="${REPEATS:-7}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"

# smoke: fast sanity check
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

# Numeric validator: accepts 123 or 123.45 (no commas, no NaN, no empty)
is_num() {
  [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

# Find openssl inside container, force stable locale
FIND_OPENSSL='
export LC_ALL=C
OPENSSL=/opt/openssl/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
[ -n "$OPENSSL" ] || { echo "openssl_not_found" 1>&2; exit 127; }
echo "$OPENSSL"
'

# ----------------------
# Parsers
# ----------------------

# Parse PQC "block format":
# lines might include:
#   keygens/s  28783.8
#   signs/s    12258.4
#   verifs/s   31404.6
#
# Important: ignore header like "keygens/s signs/s verifs/s"
parse_block_pqc() {
  awk '
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?$/) }
    /keygens\/s/ { if (isnum($2)) kg=$2 }
    /signs\/s/   { if (isnum($2)) sg=$2 }
    /verifs\/s/  { if (isnum($2)) vf=$2 }
    END { print kg "," sg "," vf }
  '
}

# Parse PQC "table row" format:
# e.g.  mldsa44  28783.8  12258.4  31404.6
parse_table_row_alg() {
  local alg="$1"
  awk -v A="${alg}" '
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?$/) }
    $1==A && NF>=4 && isnum($2) && isnum($3) && isnum($4) { print $2 "," $3 "," $4; found=1; exit 0 }
    END { if(!found) print ",," }
  '
}

# Parse ECDSA from "ecdsap256 block" if it exists (rare)
parse_block_ecdsa() {
  awk '
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?$/) }
    /signs\/s/  { if (isnum($2)) sg=$2 }
    /verifs\/s/ { if (isnum($2)) vf=$2 }
    END { print sg "," vf }
  '
}

# Parse ECDSA from standard table output:
# Example you posted:
#                               sign    verify    sign/s verify/s
#  256 bits ecdsa (nistp256)   0.0000s   0.0001s  43514.7  14540.3
#
# We find a line that contains "256 bits" AND "ecdsa" (case-insensitive),
# then take last two fields as sign/s and verify/s.
parse_ecdsa_256_table() {
  awk '
    function tolower_str(s,    i,c,out){ out=""; for(i=1;i<=length(s);i++){c=substr(s,i,1); out=out tolower(c)}; return out }
    function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?$/) }

    {
      line=$0
      low=tolower_str(line)
      if (low ~ /256 bits/ && low ~ /ecdsa/) {
        # sign/s and verify/s are typically the last two columns
        s=$(NF-1); v=$NF
        if (isnum(s) && isnum(v)) {
          print s "," v
          found=1
          exit 0
        }
      }
    }
    END { if(!found) print "," }
  '
}

# ----------------------
# Runners
# ----------------------

run_speed_pqc() {
  local alg="$1"
  docker run --rm "${IMG}" sh -lc "
    set -e
    OPENSSL=\$(${FIND_OPENSSL})
    # oqsprovider + default for PQC
    \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider oqsprovider -provider default ${alg} 2>/dev/null || true
  "
}

run_speed_ecdsa() {
  docker run --rm "${IMG}" sh -lc "
    set -e
    OPENSSL=\$(${FIND_OPENSSL})
    # Try ecdsap256 first (some builds support it)
    if \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider default ecdsap256 >/tmp/out 2>/dev/null; then
      cat /tmp/out
      exit 0
    fi
    # Fallback to 'ecdsa' table (common)
    \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider default ecdsa 2>/dev/null || true
  "
}

# ----------------------
# Warmup
# ----------------------
for _ in $(seq 1 "${WARMUP}"); do
  run_speed_ecdsa >/dev/null 2>&1 || true
  for alg in "mldsa44" "mldsa65" "falcon512" "falcon1024"; do
    run_speed_pqc "$alg" >/dev/null 2>&1 || true
  done
done

# ----------------------
# Measure
# ----------------------
for r in $(seq 1 "${REPEATS}"); do
  for alg in "${SIGS[@]}"; do
    out=""
    if [ "${alg}" = "ecdsap256" ]; then
      out="$(run_speed_ecdsa || true)"
    else
      out="$(run_speed_pqc "${alg}" || true)"
    fi

    raw="${rawdir}/rep${r}_${alg}.txt"
    printf "%s\n" "$out" > "${raw}"

    keygens="" ; sign="" ; verify=""

    if [ "${alg}" = "ecdsap256" ]; then
      # A) block format (if exists)
      if printf "%s\n" "$out" | grep -q "signs/s"; then
        IFS=',' read -r sign verify < <(printf "%s\n" "$out" | parse_block_ecdsa)
      else
        # B) standard ecdsa table
        IFS=',' read -r sign verify < <(printf "%s\n" "$out" | parse_ecdsa_256_table)
      fi

      # Validate ECDSA sign/verify
      if ! is_num "${sign:-}" || ! is_num "${verify:-}"; then
        if [ "${MODE}" = "paper" ]; then
          die "ECDSA sign/verify missing/non-numeric (rep=${r}). See ${raw}"
        fi
        echo "rep=${r} alg=${alg} (missing) sign=${sign:-} verify=${verify:-}"
        echo "${r},${MODE},${BENCH_SECONDS},${alg},,,">> "${csv}"
        continue
      fi

      echo "rep=${r} alg=${alg} sign/s=${sign} verify/s=${verify}"
      echo "${r},${MODE},${BENCH_SECONDS},${alg},,${sign},${verify}" >> "${csv}"
      continue
    fi

    # PQC: prefer table-row parse first (most stable), then fallback to block parse
    IFS=',' read -r keygens sign verify < <(printf "%s\n" "$out" | parse_table_row_alg "${alg}")
    if ! is_num "${keygens:-}" || ! is_num "${sign:-}" || ! is_num "${verify:-}"; then
      IFS=',' read -r keygens sign verify < <(printf "%s\n" "$out" | parse_block_pqc)
    fi

    # Validate PQC
    if ! is_num "${keygens:-}" || ! is_num "${sign:-}" || ! is_num "${verify:-}"; then
      if [ "${MODE}" = "paper" ]; then
        die "PQC metrics missing/non-numeric for alg=${alg} (rep=${r}). See ${raw}"
      fi
      echo "rep=${r} alg=${alg} (missing) keygens=${keygens:-} sign=${sign:-} verify=${verify:-}"
      echo "${r},${MODE},${BENCH_SECONDS},${alg},,," >> "${csv}"
      continue
    fi

    echo "rep=${r} alg=${alg} keygens/s=${keygens} sign/s=${sign} verify/s=${verify}"
    echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens},${sign},${verify}" >> "${csv}"
  done
done

# Final audit: CSV must not contain 'signs'/'verifs' in numeric fields
if awk -F',' 'NR>1 && ($5 ~ /signs|verifs/ || $6 ~ /signs|verifs/ || $7 ~ /signs|verifs/) {exit 1}' "${csv}"; then
  :
else
  die "CSV audit failed: header tokens leaked into numeric columns. Check raw outputs under ${rawdir}"
fi

echo
echo "CSV: ${csv}"
echo "Raw: ${rawdir}/rep*_*.txt"
