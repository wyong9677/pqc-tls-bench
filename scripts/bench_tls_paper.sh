#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-7}"
WARMUP="${WARMUP:-2}"
TIMESEC="${TIMESEC:-20}"

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
rawdir="${RESULTS_DIR}/tls_throughput_raw"
mkdir -p "${rawdir}"
echo "repeat,mode,timesec,connections,user_sec,conn_user_sec,real_seconds" > "${csv}"

echo "=== TLS throughput (s_time) ==="
echo "mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} time=${TIMESEC}s"
echo

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

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
    \"\$OPENSSL\" s_time -connect server:${PORT} -tls1_3 -new -time ${TIMESEC} -provider default
  " || true
}

# warmup (not recorded)
for _ in $(seq 1 "${WARMUP}"); do
  run_one >/dev/null 2>&1 || true
done

for r in $(seq 1 "${REPEATS}"); do
  out="$(run_one)"
  printf "%s\n" "$out" > "${rawdir}/rep${r}.txt"

  # parse: "XXXX connections in Y.YYs; Z.ZZ connections/user sec"
  connections="$(printf "%s\n" "$out" | awk '/connections in/ {print $1; exit 0}')"
  usersec="$(printf "%s\n" "$out" | awk '/connections in/ {gsub("s;","",$4); print $3; exit 0}')"
  conn_user_sec="$(printf "%s\n" "$out" | awk '/connections\/user sec/ {print $(NF-2); exit 0}')"
  realsec="$(printf "%s\n" "$out" | awk '/connections in [0-9.]+ real seconds/ {print $(NF-2); exit 0}')"

  connections="${connections:-nan}"
  usersec="${usersec:-nan}"
  conn_user_sec="${conn_user_sec:-nan}"
  realsec="${realsec:-nan}"

  echo "rep=${r} conn_user_sec=${conn_user_sec}"
  echo "${r},${MODE},${TIMESEC},${connections},${usersec},${conn_user_sec},${realsec}" >> "${csv}"
done

echo
echo "CSV: ${csv}"
echo "Raw: ${rawdir}/rep*.txt"
