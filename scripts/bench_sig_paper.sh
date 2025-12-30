#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"

if [ "${MODE}" = "smoke" ]; then
  REPEATS=1
  WARMUP=1
  BENCH_SECONDS=5
fi

SIGS=("ecdsap256" "mldsa44" "mldsa65" "falcon512" "falcon1024")

csv="${RESULTS_DIR}/sig_speed.csv"
echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s" > "${csv}"

echo "=== bench_sig.sh (paper-grade) ==="
echo "mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS}"
echo

run_speed() {
  local alg="$1"
  docker run --rm "${IMG}" sh -lc "
    set -e
    OPENSSL=/opt/openssl/bin/openssl
    [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
    [ -n \"\$OPENSSL\" ] || exit 127
    \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider oqsprovider -provider default ${alg} 2>/dev/null || exit 0
  "
}

# warmup (not recorded)
for _ in $(seq 1 "${WARMUP}"); do
  run_speed "ecdsap256" >/dev/null 2>&1 || true
done

for r in $(seq 1 "${REPEATS}"); do
  for alg in "${SIGS[@]}"; do
    out="$(run_speed "${alg}" || true)"
    # parse the line containing alg and the last 3 columns (keygens/s sign/s verify/s)
    line="$(printf "%s\n" "$out" | awk -v a="${alg}" '$1==a {print; exit 0}')"
    if [ -z "${line}" ]; then
      echo "rep=${r} alg=${alg} skip (not supported)"
      echo "${r},${MODE},${BENCH_SECONDS},${alg},nan,nan,nan" >> "${csv}"
      continue
    fi
    keygens="$(echo "$line" | awk '{print $(NF-2)}')"
    sign="$(echo "$line"   | awk '{print $(NF-1)}')"
    verify="$(echo "$line" | awk '{print $(NF)}')"
    echo "rep=${r} alg=${alg} keygens/s=${keygens} sign/s=${sign} verify/s=${verify}"
    echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens},${sign},${verify}" >> "${csv}"
  done
done

echo
echo "CSV written: ${csv}"
