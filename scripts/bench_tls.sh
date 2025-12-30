#!/usr/bin/env bash
set -euo pipefail

# 从 workflow 读取 IMG；若未设置才用默认（不要用 latest）
IMG="${IMG:-openquantumsafe/oqs-ossl3:0.12.0}"
NET="pqcnet"
PORT=4433
TIMESEC="${TIMESEC:-15}"

# 先固定为 classical：X25519（保证 baseline 能跑通）
GROUPS=("X25519")

# ---- Sanity check：容器内是否有 openssl ----
docker run --rm "${IMG}" sh -lc '
  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl not found inside container"
    exit 1
  fi
  openssl version -a >/dev/null 2>&1 || true
'

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

gen_cert='
set -e
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout /tmp/key.pem -out /tmp/cert.pem -subj "/CN=localhost" -days 1 >/dev/null 2>&1
'

# ---- 等待 server 就绪（替代 sleep 1，CI 更稳）----
wait_server_ready() {
  local tries=30
  local i=1
  while [ $i -le $tries ]; do
    if docker run --rm --network "$NET" "$IMG" sh -lc \
      "echo | openssl s_client -connect server:${PORT} -tls1_3 -brief >/dev/null 2>&1"; then
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
  echo

  docker rm -f server >/dev/null 2>&1 || true
  docker run -d --rm --name server --network "$NET" "$IMG" sh -lc "
    $gen_cert
    openssl s_server -accept $PORT -tls1_3 \
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
    openssl s_time -connect server:$PORT -tls1_3 -new -time $TIMESEC \
      -provider oqsprovider -provider default
  "

  echo
done

docker rm -f server >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
