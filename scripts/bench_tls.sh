#!/usr/bin/env bash
set -euo pipefail

IMG="openquantumsafe/oqs-ossl3:latest"
NET="pqcnet"
PORT=4433
TIMESEC=15

# 先固定为 classical：X25519（保证必然存在）
GROUPS=("X25519")

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

gen_cert='
set -e
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout /tmp/key.pem -out /tmp/cert.pem -subj "/CN=localhost" -days 1 >/dev/null 2>&1
'

for g in "${GROUPS[@]}"; do
  echo "=== TLS handshake throughput: $g ==="

  docker rm -f server >/dev/null 2>&1 || true
  docker run -d --rm --name server --network "$NET" "$IMG" sh -lc "
    $gen_cert
    openssl s_server -accept $PORT -tls1_3 \
      -cert /tmp/cert.pem -key /tmp/key.pem \
      -groups $g \
      -provider oqsprovider -provider default \
      -quiet
  " >/dev/null

  sleep 1

  docker run --rm --network "$NET" "$IMG" sh -lc "
    openssl s_time -connect server:$PORT -tls1_3 -new -time $TIMESEC \
      -provider oqsprovider -provider default
  "

  echo
done

docker rm -f server >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
