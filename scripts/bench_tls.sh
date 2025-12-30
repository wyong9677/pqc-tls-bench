#!/usr/bin/env bash
set -euo pipefail

# 镜像由 workflow 控制；默认用 latest（不要再用 0.12.0）
IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"

# openssl 真实路径由 workflow Probe step 写入；默认尝试 openssl
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

NET="pqcnet"
PORT=4433
TIMESEC="${TIMESEC:-15}"

# baseline：先跑 X25519
GROUPS=("X25519")

# ---- Sanity check：容器内是否能执行 OPENSSL_BIN ----
docker run --rm "${IMG}" sh -lc "
  if [ -x \"${OPENSSL_BIN}\" ] || command -v \"${OPENSSL_BIN}\" >/dev/null 2>&1; then
    \"${OPENSSL_BIN}\" version -a >/dev/null 2>&1 || true
  else
    echo 'ERROR: cannot execute OPENSSL_BIN inside container'
    echo 'Tip: ensure workflow Probe step sets OPENSSL_BIN and scripts use it.'
    exit 1
  fi
"

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

gen_cert='
set -e
"$OPENSSL_BIN" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout /tmp/key.pem -out /tmp/cert.pem -subj "/CN=localhost" -days 1 >/dev/null 2>&1
'

# ---- 等待 server 就绪（替代 sleep 1）----
wait_server_ready() {
  local tries=30
  local i=1
  while [ $i -le $tries ]; do
    if docker run --rm --network "$NET" "$IMG" sh -lc \
      "echo | \"${OPENSSL_BIN}\" s_client -connect server:${PORT} -tls1_3 -brief >/dev/null 2>&1"; then
      return 0
    fi
    sleep 0.2
    i=$((i+1))
  done
  return 1
}

for g in "${GROUPS[@]}"; do
  echo "=== TLS handshake throughput: $g ==="
  echo "Image: ${IMG}"
  echo "OPENSSL_BIN: ${OPENSSL_BIN}"
  echo

  docker rm -f server >/dev/null 2>&1 || true
  docker run -d --rm --name server --network "$NET" "$IMG" sh -lc "
    set -e
    OPENSSL_BIN='${OPENSSL_BIN}'
    $gen_cert
    \"${OPENSSL_BIN}\" s_server -accept $PORT -tls1_3 \
      -cert /tmp/cert.pem -key /tmp/key.pem \
      -groups $g \
      -provider oqsprovider -provider default \
      -quiet
  " >/dev/null

  if ! wait_server_ready; then
    echo "ERROR: server not ready for group=$g"
    exit 1
  fi

  docker run --rm --network "$NET" "$IMG" sh -lc "
    \"${OPENSSL_BIN}\" s_time -connect server:$PORT -tls1_3 -new -time $TIMESEC \
      -provider oqsprovider -provider default
  "

  echo
done

docker rm -f server >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
