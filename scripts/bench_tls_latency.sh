#!/usr/bin/env bash
set -euo pipefail

IMG="openquantumsafe/oqs-ossl3:0.12.0"
NET="pqcnet"
PORT=4433
N="${N:-50}"

GROUPS=("X25519")

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

gen_cert='
set -e
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout /tmp/key.pem -out /tmp/cert.pem -subj "/CN=localhost" -days 1 >/dev/null 2>&1
'

for g in "${GROUPS[@]}"; do
  echo "=== TLS latency distribution: $g (N=$N) ==="

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

  # 采样 N 次握手耗时（毫秒）
  docker run --rm --network "$NET" "$IMG" sh -lc "
    i=1
    while [ \$i -le $N ]; do
      t0=\$(date +%s%N)
      echo | openssl s_client -connect server:$PORT -tls1_3 \
        -provider oqsprovider -provider default -brief >/dev/null 2>&1 || true
      t1=\$(date +%s%N)
      echo \$(( (t1 - t0)/1000000 ))
      i=\$((i+1))
    done
  " | sort -n > /tmp/lats_ms.txt

  count=$(wc -l < /tmp/lats_ms.txt)
  p50_idx=$(( (count*50 + 99)/100 ))
  p95_idx=$(( (count*95 + 99)/100 ))
  p99_idx=$(( (count*99 + 99)/100 ))

  p50=$(sed -n "${p50_idx}p" /tmp/lats_ms.txt)
  p95=$(sed -n "${p95_idx}p" /tmp/lats_ms.txt)
  p99=$(sed -n "${p99_idx}p" /tmp/lats_ms.txt)

  mean=$(awk '{s+=$1} END{if(NR>0) printf "%.2f", s/NR; else print "nan"}' /tmp/lats_ms.txt)

  echo "count=$count ms: p50=$p50 p95=$p95 p99=$p99 mean=$mean"
  echo
done

docker rm -f server >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
