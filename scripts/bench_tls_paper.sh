#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

need docker
need python3

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-7}"
WARMUP="${WARMUP:-2}"
TIMESEC="${TIMESEC:-20}"

# TLS config (override per experiment)
TLS_PROVIDERS="${TLS_PROVIDERS:-default}"          # e.g. "default" or "oqsprovider,default"
TLS_GROUPS="${TLS_GROUPS:-}"                      # e.g. "X25519" or "p256_kyber768" etc (if supported)
TLS_CERT_KEYALG="${TLS_CERT_KEYALG:-ec_p256}"      # "ec_p256" OR "mldsa65" OR "falcon512" etc
TLS_SERVER_EXTRA_ARGS="${TLS_SERVER_EXTRA_ARGS:-}" # optional extra s_server args
TLS_CLIENT_EXTRA_ARGS="${TLS_CLIENT_EXTRA_ARGS:-}" # optional extra s_time/s_client args

RUN_ID="${RUN_ID:-$(default_run_id)}"
OUTDIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "${OUTDIR}"

NET="pqcnet-${RUN_ID}"
PORT=4433

cleanup() {
  docker rm -f "server-${RUN_ID}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

rawdir="${OUTDIR}/tls_throughput_raw"
mkdir -p "${rawdir}"
csv="${OUTDIR}/tls_throughput.csv"
echo "repeat,mode,timesec,providers,groups,cert_keyalg,connections,user_sec,conn_user_sec,real_seconds,ok,raw_file" > "${csv}"

CONFIG_JSON="$(python3 - <<PY
import json
print(json.dumps({
  "benchmark": "tls_throughput_s_time",
  "repeats": int(${REPEATS}),
  "warmup": int(${WARMUP}),
  "timesec": int(${TIMESEC}),
  "providers": ${TLS_PROVIDERS!r},
  "groups": ${TLS_GROUPS!r},
  "cert_keyalg": ${TLS_CERT_KEYALG!r},
  "server_extra_args": ${TLS_SERVER_EXTRA_ARGS!r},
  "client_extra_args": ${TLS_CLIENT_EXTRA_ARGS!r},
}))
PY
)"
write_meta_json "${OUTDIR}" "${MODE}" "${IMG}" "${CONFIG_JSON}"

info "TLS throughput: mode=${MODE} run_id=${RUN_ID} repeats=${REPEATS} warmup=${WARMUP} time=${TIMESEC}s"
info "providers=${TLS_PROVIDERS} groups=${TLS_GROUPS:-<default>} cert_keyalg=${TLS_CERT_KEYALG}"

docker network rm "${NET}" >/dev/null 2>&1 || true
docker network create "${NET}" >/dev/null

providers_args="$(providers_to_args "${TLS_PROVIDERS}")"

# Start server
docker run -d --rm --name "server-${RUN_ID}" --network "${NET}" "${IMG}" sh -lc "
  set -e
  OPENSSL=/opt/openssl/bin/openssl
  [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
  [ -n \"\$OPENSSL\" ] || exit 127

  PROVIDERS='${providers_args}'

  # Generate cert/key
  if [ '${TLS_CERT_KEYALG}' = 'ec_p256' ]; then
    \"\$OPENSSL\" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout /tmp/key.pem -out /tmp/cert.pem -subj \"/CN=localhost\" -days 1 \${PROVIDERS} >/dev/null 2>&1
  else
    # PQ signature keys
    \"\$OPENSSL\" req -x509 -newkey '${TLS_CERT_KEYALG}' -nodes \
      -keyout /tmp/key.pem -out /tmp/cert.pem -subj \"/CN=localhost\" -days 1 \${PROVIDERS} >/dev/null 2>&1
  fi

  # TLS groups (best-effort): pass only if set
  GROUPS_ARG=''
  if [ -n '${TLS_GROUPS}' ]; then
    GROUPS_ARG=\"-groups ${TLS_GROUPS}\"
  fi

  \"\$OPENSSL\" s_server -accept ${PORT} -tls1_3 \
    -cert /tmp/cert.pem -key /tmp/key.pem \
    \${PROVIDERS} \${GROUPS_ARG} ${TLS_SERVER_EXTRA_ARGS} \
    -quiet
" >/dev/null

# Wait ready
ready=0
for _ in $(seq 1 40); do
  if docker run --rm --network "${NET}" "${IMG}" sh -lc "
    OPENSSL=/opt/openssl/bin/openssl
    [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
    PROVIDERS='${providers_args}'
    GROUPS_ARG=''
    if [ -n '${TLS_GROUPS}' ]; then GROUPS_ARG=\"-groups ${TLS_GROUPS}\"; fi
    timeout 2s \"\$OPENSSL\" s_client -connect server-${RUN_ID}:${PORT} -tls1_3 -brief \${PROVIDERS} \${GROUPS_ARG} ${TLS_CLIENT_EXTRA_ARGS} </dev/null >/dev/null 2>&1
  "; then
    ready=1; break
  fi
  sleep 0.2
done

if [ "${ready}" -ne 1 ]; then
  die "TLS server not ready (check docker logs server-${RUN_ID})"
fi

run_one() {
  docker run --rm --network "${NET}" "${IMG}" sh -lc "
    set -e
    OPENSSL=/opt/openssl/bin/openssl
    [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
    PROVIDERS='${providers_args}'
    GROUPS_ARG=''
    if [ -n '${TLS_GROUPS}' ]; then GROUPS_ARG=\"-groups ${TLS_GROUPS}\"; fi
    \"\$OPENSSL\" s_time -connect server-${RUN_ID}:${PORT} -tls1_3 -new -time ${TIMESEC} \${PROVIDERS} \${GROUPS_ARG} ${TLS_CLIENT_EXTRA_ARGS}
  " || true
}

# Warmup
for _ in $(seq 1 "${WARMUP}"); do
  run_one >/dev/null 2>&1 || true
done

for r in $(seq 1 "${REPEATS}"); do
  out="$(run_one)"
  rawfile="${rawdir}/rep${r}.txt"
  printf "%s\n" "${out}" > "${rawfile}"

  connections="$(printf "%s\n" "$out" | awk 'match($0,/^([0-9]+)[[:space:]]+connections[[:space:]]+in[[:space:]]+[0-9.]+s;/,m){print m[1]; exit}')"
  usersec="$(printf "%s\n" "$out" | awk 'match($0,/connections[[:space:]]+in[[:space:]]+([0-9.]+)s;/,m){print m[1]; exit}')"
  conn_user_sec="$(printf "%s\n" "$out" | awk 'match($0,/;[[:space:]]*([0-9.]+)[[:space:]]+connections\/user[[:space:]]+sec/,m){print m[1]; exit}')"
  realsec="$(printf "%s\n" "$out" | awk 'match($0,/connections[[:space:]]+in[[:space:]]+([0-9.]+)[[:space:]]+real[[:space:]]+seconds/,m){print m[1]; exit}')"

  ok=1
  if [ -z "${conn_user_sec}" ]; then ok=0; conn_user_sec="nan"; fi
  connections="${connections:-nan}"
  usersec="${usersec:-nan}"
  realsec="${realsec:-nan}"

  echo "${r},${MODE},${TIMESEC},${TLS_PROVIDERS},${TLS_GROUPS},${TLS_CERT_KEYALG},${connections},${usersec},${conn_user_sec},${realsec},${ok},\"${rawfile}\"" >> "${csv}"
  info "rep=${r} conn_user_sec=${conn_user_sec}"
done

echo
echo "OK. CSV: ${csv}"
echo "Raw: ${rawdir}/rep*.txt"
echo "Meta: ${OUTDIR}/meta.json"
