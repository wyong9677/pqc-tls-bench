#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
TIMESEC="${TIMESEC:-15}"

if [ "${MODE}" = "smoke" ]; then
  REPEATS=2
  WARMUP=1
  TIMESEC=5
fi

NET="pqcnet"
PORT=4433

cleanup() {
  docker rm -f server >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

csv="${RESULTS_DIR}/tls_throughput.csv"
echo "run,mode,timesec,conn_user_sec" > "${csv}"

echo "=== bench_tls.sh (throughput) ==="
echo "mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} timesec=${TIMESEC}"
echo

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

# start server once
docker run -d --rm --name server --network "$NET" "${IMG}" sh -lc "
  set -e
  OPENSSL=/opt/openssl/bin/openssl
  [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
  [ -n \"\$OPENSSL\" ] || exit 127
  \"\$OPENSSL\" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout /tmp/key.pem -out /tmp/cert.pem -subj \"/CN=localhost\" -days 1 >/dev/null 2>&1
  \"\$OPENSSL\" s_server -accept ${PORT} -tls1_3 \
    -cert /tmp/cert.pem -key /tmp/key.pem -provider default -quiet
" >/dev/null

# wait ready
for _ in $(seq 1 30); do
  if docker run --rm --network "$NET" "${IMG}" sh -lc "
    OPENSSL=/opt/openssl/bin/openssl; [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
    timeout 2s \"\$OPENSSL\" s_client -connect server:${PORT} -tls1_3 -brief </dev/null >/dev/null 2>&1
  "; then break; fi
  sleep 0.2
done

run_one() {
  docker run --rm --network "$NET" "${IMG}" sh -lc "
    set -e
    OPENSSL=/opt/openssl/bin/openssl
    [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
    \"\$OPENSSL\" s_time -connect server:${PORT} -tls1_3 -new -time ${TIMESEC} -provider default 2>/dev/null
  " || true
}

# warmup
for _ in $(seq 1 "${WARMUP}"); do
  run_one >/dev/null 2>&1 || true
done

for r in $(seq 1 "${REPEATS}"); do
  out="$(run_one)"
  # extract "xxxx.xx connections/user sec"
  val="$(printf "%s\n" "$out" | awk '/connections\/user sec/ {print $(NF-2); exit 0}')"
  [ -n "${val}" ] || val="nan"
  echo "run=${r} conn_user_sec=${val}"
  echo "${r},${MODE},${TIMESEC},${val}" >> "${csv}"
done

echo
echo "CSV written: ${csv}"
