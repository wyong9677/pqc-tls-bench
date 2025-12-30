#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
NET="pqcnet"
PORT=4433
N="${N:-10}"
ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-2}"

cleanup() {
  docker rm -f server >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== bench_tls_latency.sh ==="
echo "Image: ${IMG}"
echo "N: ${N}  attempt_timeout: ${ATTEMPT_TIMEOUT}s"
echo

# host python3 必须可用（方案B核心）
python3 --version >/dev/null 2>&1 || { echo "ERROR: host python3 not available"; exit 1; }

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

# 启动 server
docker run -d --rm --name server --network "$NET" "${IMG}" sh -lc "
  set -e
  OPENSSL=/opt/openssl/bin/openssl
  [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
  [ -n \"\$OPENSSL\" ] || exit 127

  \"\$OPENSSL\" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout /tmp/key.pem -out /tmp/cert.pem -subj \"/CN=localhost\" -days 1 >/dev/null 2>&1

  \"\$OPENSSL\" s_server -accept ${PORT} -tls1_3 \
    -cert /tmp/cert.pem -key /tmp/key.pem \
    -provider default \
    -quiet
" >/dev/null

# 等待 ready
tries=25
i=1
while [ $i -le $tries ]; do
  if docker run --rm --network "$NET" "${IMG}" sh -lc "
    OPENSSL=/opt/openssl/bin/openssl
    [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
    [ -n \"\$OPENSSL\" ] || exit 127
    timeout 2s \"\$OPENSSL\" s_client -connect server:${PORT} -tls1_3 -brief </dev/null >/dev/null 2>&1
  "; then
    break
  fi
  sleep 0.2
  i=$((i+1))
done
if [ $i -gt $tries ]; then
  echo "ERROR: server not ready"
  docker logs server 2>&1 | tail -n 200 || true
  exit 1
fi

# 容器内采样：输出每次成功握手耗时(ms)
ms_list="$(
  docker run --rm --network "$NET" -e N="$N" -e TO="$ATTEMPT_TIMEOUT" "${IMG}" sh -lc '
    set -e
    OPENSSL=/opt/openssl/bin/openssl
    [ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
    [ -n "$OPENSSL" ] || exit 127

    n="${N}"
    to="${TO}"

    i=1
    while [ "$i" -le "$n" ]; do
      t0=$(date +%s%N)
      if timeout "${to}s" "$OPENSSL" s_client -connect server:4433 -tls1_3 -brief -provider default </dev/null >/dev/null 2>&1; then
        t1=$(date +%s%N)
        echo $(( (t1 - t0)/1000000 ))
      fi
      i=$((i+1))
    done
  ' || true
)"

if [ -z "${ms_list}" ]; then
  echo "attempts=${N} ok=0 (no successful handshakes)"
  exit 0
fi

# host python3 统计分位数
python3 - <<'PY' <<<"${ms_list}"
import sys, math, statistics

vals = [float(x) for x in sys.stdin.read().split()]
vals.sort()

def pct(p):
    k=(len(vals)-1)*p/100.0
    f=math.floor(k); c=math.ceil(k)
    if f==c:
        return vals[int(k)]
    return vals[f]*(c-k)+vals[c]*(k-f)

mean = statistics.mean(vals)
print(f"count={len(vals)} ms: p50={pct(50):.2f} p95={pct(95):.2f} p99={pct(99):.2f} mean={mean:.2f}")
PY

echo
