#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

NET="pqcnet"
PORT=4433
TIMESEC="${TIMESEC:-15}"

GROUPS=("X25519")

echo "=== bench_tls.sh ==="
echo "Image: ${IMG}"
echo "OPENSSL_BIN: ${OPENSSL_BIN}"
echo "TIMESEC: ${TIMESEC}"
echo

# --- Sanity check (container) ---
docker run --rm -e OPENSSL_BIN="${OPENSSL_BIN}" "${IMG}" sh -lc '
  if [ -x "$OPENSSL_BIN" ] || command -v "$OPENSSL_BIN" >/dev/null 2>&1; then
    "$OPENSSL_BIN" version -a >/dev/null 2>&1 || true
    exit 0
  fi
  echo "ERROR: cannot execute OPENSSL_BIN inside container: $OPENSSL_BIN"
  exit 1
'

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

# 证书生成脚本（在容器内执行）
gen_cert='
set -e
"$OPENSSL_BIN" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout /tmp/key.pem -out /tmp/cert.pem -subj "/CN=localhost" -days 1 >/dev/null 2>&1
'

# --- Wait until server is ready (with timeout per attempt) ---
wait_server_ready() {
  local tries=30
  local i=1
  while [ $i -le $tries ]; do
    if docker run --rm --network "$NET" \
      -e OPENSSL_BIN="${OPENSSL_BIN}" \
      "${IMG}" sh -lc \
      "timeout 3s sh -lc 'echo | \"\$OPENSSL_BIN\" s_client -connect server:${PORT} -tls1_3 -brief >/dev/null 2>&1'"; then
      return 0
    fi
    sleep 0.2
    i=$((i+1))
  done
  return 1
}

for g in "${GROUPS[@]}"; do
  echo "=== TLS handshake throughput: $g ==="

  docker rm -f server >/dev/null 2>&1 || true
  docker run -d --rm --name server --network "$NET" \
    -e OPENSSL_BIN="${OPENSSL_BIN}" \
    "${IMG}" sh -lc "
      set -e
      ${gen_cert}
      \"\$OPENSSL_BIN\" s_server -accept ${PORT} -tls1_3 \
        -cert /tmp/cert.pem -key /tmp/key.pem \
        -groups ${g} \
        -provider oqsprovider -provider default \
        -quiet
    " >/dev/null

  if ! wait_server_ready; then
    echo "ERROR: server not ready for group=${g}"
    echo "--- server logs ---"
    docker logs server 2>&1 | tail -n 200 || true
    exit 1
  fi

  # s_time 也加整体 timeout，避免异常挂住
  docker run --rm --network "$NET" \
    -e OPENSSL_BIN="${OPENSSL_BIN}" \
    "${IMG}" sh -lc "
      timeout $((TIMESEC + 20))s \"\$OPENSSL_BIN\" s_time \
        -connect server:${PORT} -tls1_3 -new -time ${TIMESEC} \
        -provider oqsprovider -provider default
    "

  echo
done

docker rm -f server >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
