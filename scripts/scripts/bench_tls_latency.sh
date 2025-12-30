#!/usr/bin/env bash
set -euo pipefail

IMG="openquantumsafe/oqs-ossl3:latest"
NET="pqcnet"
PORT=4433
N=200

GROUPS=("X25519" "X25519MLKEM768")

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

gen_cert='
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout /tmp/key.pem -out /tmp/cert.pem -subj "/CN=localhost" -days 1
'

for g in "${GROUPS[@]}"; do
  echo "=== TLS latency distribution: $g ==="

  docker rm -f server >/dev/null 2>&1 || true
  docker run -d --rm --name server --network "$NET" "$IMG" sh -lc "
    $gen_cert
    openssl s_server -accept $PORT -tls1_3 \
      -cert /tmp/cert.pem -key /tmp/key.pem \
      -groups $g -quiet
  "

  sleep 1

  docker run --rm --network "$NET" "$IMG" sh -lc "
python3 - << 'PY'
import subprocess, time, statistics, math
N=200
cmd=['openssl','s_client','-connect','server:4433','-tls1_3','-brief']
l=[]
for _ in range(N):
    t0=time.time_ns()
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t1=time.time_ns()
    l.append((t1-t0)/1e6)
l.sort()
def p(x): return l[int(len(l)*x/100)]
print(f'p50={p(50):.2f}ms p95={p(95):.2f}ms p99={p(99):.2f}ms mean={statistics.mean(l):.2f}ms')
PY
  "
done

docker rm -f server >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
