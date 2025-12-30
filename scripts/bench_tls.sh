#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
NET="pqcnet"
PORT=4433
TIMESEC="${TIMESEC:-5}"

cleanup() {
  docker rm -f server >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== bench_tls.sh ==="
echo "Image: ${IMG}"
echo "TIMESEC: ${TIMESEC}"
echo

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

container_find_openssl='
find_openssl() {
  for p in /opt/openssl/bin/openssl /opt/openssl32/bin/openssl /usr/local/bin/openssl /usr/bin/openssl /usr/local/ssl/bin/openssl; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  command -v openssl >/dev/null 2>&1 && { command -v openssl; return 0; }
  return 1
}
OPENSSL="$(find_openssl || true)"
[ -n "$OPENSSL" ] || { echo "ERROR: openssl not found in container" 1>&2; exit 127; }
'

echo "== Diagnostic: openssl version (head) =="
docker run --rm "${IMG}" sh -lc "
  set -e
  ${container_find_openssl}
  echo \"OPENSSL_BIN=\$OPENSSL\"
  \"\$OPENSSL\" version -a 2>&1 | head -n 15 || true
" || true
echo

wait_server_ready() {
  local tries=25 i=1
  while [ $i -le $tries ]; do
    if docker run --rm --network "$NET" "${IMG}" sh -lc "
      ${container_find_openssl}
      timeout 2s \"\$OPENSSL\" s_client -connect server:${PORT} -tls1_3 -brief </dev/null >/dev/null 2>&1
    "; then
      return 0
    fi
    sleep 0.2
    i=$((i+1))
  done
  return 1
}

echo "=== TLS throughput: TLS1.3 default negotiation (no -groups) ==="
# 注意：这里不加载 oqsprovider，因为我们也无法指定 group；保持可跑通最重要
PROVIDERS="-provider default"
echo "Providers: ${PROVIDERS}"

docker run -d --rm --name server --network "$NET" "${IMG}" sh -lc "
  set -e
  ${container_find_openssl}
  \"\$OPENSSL\" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout /tmp/key.pem -out /tmp/cert.pem -subj \"/CN=localhost\" -days 1 >/dev/null 2>&1

  \"\$OPENSSL\" s_server -accept ${PORT} -tls1_3 \
    -cert /tmp/cert.pem -key /tmp/key.pem \
    ${PROVIDERS} \
    -quiet
" >/dev/null

if ! wait_server_ready; then
  echo "ERROR: server not ready"
  echo "--- server logs ---"
  docker logs server 2>&1 | tail -n 200 || true
  exit 1
fi

timeout "$((TIMESEC + 15))"s docker run --rm --network "$NET" "${IMG}" sh -lc "
  set -e
  ${container_find_openssl}
  \"\$OPENSSL\" s_time -connect server:${PORT} -tls1_3 -new -time ${TIMESEC} ${PROVIDERS}
"

echo
