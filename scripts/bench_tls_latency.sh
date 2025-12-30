#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
NET="pqcnet"
PORT=4433
N="${N:-10}"          # 冒烟默认 10
ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-2}"  # 单次握手 timeout（秒）

# classic + (可用则跑) hybrid
GROUPS=("X25519" "X25519MLKEM768")

cleanup() {
  docker rm -f server >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== bench_tls_latency.sh (smoke) ==="
echo "Image: ${IMG}"
echo "Attempts (N): ${N}"
echo "Attempt timeout: ${ATTEMPT_TIMEOUT}s"
echo

# Sanity: openssl in container
docker run --rm "${IMG}" sh -lc 'command -v openssl >/dev/null 2>&1; openssl version -a >/dev/null 2>&1 || true'

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

gen_cert='
set -e
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout /tmp/key.pem -out /tmp/cert.pem -subj "/CN=localhost" -days 1 >/dev/null 2>&1
'

group_available() {
  local g="$1"
  docker run --rm "${IMG}" sh -lc "openssl list -groups 2>/dev/null | grep -qx '${g}'"
}

wait_server_ready() {
  local tries=20
  local i=1
  while [ $i -le $tries ]; do
    if docker run --rm --network "$NET" "${IMG}" sh -lc \
      "timeout 2s openssl s_client -connect server:${PORT} -tls1_3 -brief </dev/null >/dev/null 2>&1"; then
      return 0
    fi
    sleep 0.2
    i=$((i+1))
  done
  return 1
}

for g in "${GROUPS[@]}"; do
  if ! group_available "$g"; then
    echo "=== skip group (not available): ${g} ==="
    echo
    continue
  fi

  echo "=== TLS latency: group=${g} attempts=${N} ==="

  # providers：classic -> default；hybrid/PQ -> oqsprovider+default
  PROVIDERS="-provider default"
  case "$g" in
    *MLKEM*|*KYBER*|mlkem*|kyber*) PROVIDERS="-provider oqsprovider -provider default" ;;
  esac

  docker rm -f server >/dev/null 2>&1 || true
  docker run -d --rm --name server --network "$NET" "${IMG}" sh -lc "
    set -e
    ${gen_cert}
    openssl s_server -accept ${PORT} -tls1_3 \
      -cert /tmp/cert.pem -key /tmp/key.pem \
      -groups ${g} \
      ${PROVIDERS} \
      -quiet
  " >/dev/null

  if ! wait_server_ready; then
    echo "ERROR: server not ready for group=${g}"
    echo "--- server logs ---"
    docker logs server 2>&1 | tail -n 200 || true
    exit 1
  fi

  # 在容器内做 N 次测量并直接算分位数/均值（减少宿主 /tmp 依赖）
  docker run --rm --network "$NET" "${IMG}" sh -lc "
    set -e
    python3 - << 'PY'
import subprocess, time, math, statistics, os
N = int(os.environ.get('N','10'))
TO = float(os.environ.get('ATTEMPT_TIMEOUT','2'))
providers = os.environ.get('PROVIDERS','-provider default').split()
cmd = ['openssl','s_client','-connect','server:${PORT}','-tls1_3','-brief'] + providers

lats=[]
ok=0
fail=0
for i in range(N):
    t0=time.time_ns()
    try:
        subprocess.run(cmd, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=TO, check=False)
        t1=time.time_ns()
        lats.append((t1-t0)/1e6)
        ok += 1
    except subprocess.TimeoutExpired:
        fail += 1

lats.sort()
def pct(p):
    if not lats:
        return float('nan')
    k=(len(lats)-1)*p/100.0
    f=math.floor(k); c=math.ceil(k)
    if f==c:
        return lats[int(k)]
    return lats[f]*(c-k)+lats[c]*(k-f)

sr = (ok*100.0/N) if N>0 else float('nan')
mean = statistics.mean(lats) if lats else float('nan')
print(f'attempts={N} ok={ok} failures={fail} success_rate={sr:.1f}% '
      f'ms: p50={pct(50):.2f} p95={pct(95):.2f} p99={pct(99):.2f} mean={mean:.2f}')
PY
  " -e N="${N}" -e ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT}" -e PROVIDERS="${PROVIDERS}"

  echo
done
