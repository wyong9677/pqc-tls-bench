#!/usr/bin/env bash
set -euo pipefail

IMG="openquantumsafe/oqs-ossl3:latest"
NET="pqcnet"
PORT=4433
N="${N:-100}"   # 先用 100，跑通后再改 200

# 先只跑 classical，等 groups 解析修好后再加 hybrid
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

  docker run --rm --network "$NET" "$IMG" sh -lc "
python3 - << 'PY'
import subprocess, time, statistics, math
N=int('${N}')
cmd=['openssl','s_client','-connect','server:${PORT}','-tls1_3',
     '-provider','oqsprovider','-provider','default','-brief']
l=[]
for _ in range(N):
    t0=time.time_ns()
    subprocess.run(cmd, input=b'', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t1=time.time_ns()
    l.append((t1-t0)/1e6)
l.sort()
def pct(p):
    k=(len(l)-1)*p/100.0
    f=math.floor(k); c=math.ceil(k)
    if f==c: return l[int(k)]
    return l[f]*(c-k)+l[c]*(k-f)
print(f'count={len(l)} ms: p50={pct(50):.2f} p95={pct(95):.2f} p99={pct(99):.2f} mean={statistics.mean(l):.2f}')
PY
  "

  echo
done

docker rm -f server >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
