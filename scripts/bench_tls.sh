#!/usr/bin/env bash
set -euo pipefail

IMG="openquantumsafe/oqs-ossl3:latest"
NET="pqcnet"
PORT="4433"
TIMESEC="20"

# 先跑经典与混合两组（混合组名若不支持，会在日志里看到可用列表）
GROUPS=("X25519" "X25519MLKEM768")

echo "=== OpenSSL & provider info ==="
docker run --rm "$IMG" sh -lc 'openssl version -a; echo; openssl list -providers'

echo
echo "=== Supported TLS groups ==="
docker run --rm "$IMG" sh -lc 'openssl list -tls-groups -provider oqsprovider -provider default 2>/dev/null || openssl list -groups || true'

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

for G in "${GROUPS[@]}"; do
  echo
  echo "--------------------------------------"
  echo "TLS 1.3 handshake benchmark: group=$G"
  echo "--------------------------------------"

  docker rm -f pqc-server >/dev/null 2>&1 || true
  docker run -d --rm --name pqc-server --network "$NET" "$IMG" sh -lc "
    set -e
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout /tmp/key.pem -out /tmp/cert.pem -subj '/CN=localhost' -days 1 >/dev/null 2>&1
    openssl s_server -accept $PORT -tls1_3 \
      -cert /tmp/cert.pem -key /tmp/key.pem \
      -groups $G -quiet
  " >/dev/null

  sleep 1

  set +e
  docker run --rm --network "$NET" "$IMG" sh -lc "
    openssl s_time -connect pqc-server:$PORT -tls1_3 -new -time $TIMESEC \
      -provider oqsprovider -provider default
  "
  rc=$?
  set -e

  if [ $rc -ne 0 ]; then
    echo "!! FAILED for group=$G (exit=$rc)"
    echo "!! Server log:"
    docker logs pqc-server || true
  fi

  docker rm -f pqc-server >/dev/null 2>&1 || true
done

docker network rm "$NET" >/dev/null 2>&1 || true
echo "=== Done ==="
