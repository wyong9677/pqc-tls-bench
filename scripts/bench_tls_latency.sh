#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
NET="pqcnet"
PORT="${PORT:-4433}"
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

# 启动 server（容器内）
docker run -d --rm --name server --network "$NET" "${IMG}" sh -lc "
  set -e
  OPENSSL=/opt/openssl/bin/openssl
  [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
  [ -n \"\$OPENSSL\" ] || { echo 'ERROR: openssl not found in container' 1>&2; exit 127; }

  \"\$OPENSSL\" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout /tmp/key.pem -out /tmp/cert.pem -subj \"/CN=localhost\" -days 1 >/dev/null 2>&1

  \"\$OPENSSL\" s_server -accept ${PORT} -tls1_3 \
    -cert /tmp/cert.pem -key /tmp/key.pem \
    -provider default \
    -quiet
" >/dev/null

# 等待 server ready
tries=30
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
  echo "--- server logs (tail) ---"
  docker logs server 2>&1 | tail -n 200 || true
  exit 1
fi

# 容器内采样：输出每次握手耗时(ms) + 统计 OK/FAIL（始终输出到 stderr）
ms_list="$(
  docker run --rm --network "$NET" -e N="$N" -e TO="$ATTEMPT_TIMEOUT" -e PORT="$PORT" "${IMG}" sh -lc '
    set +e  # 采样阶段不因单次失败退出
    OPENSSL=/opt/openssl/bin/openssl
    [ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
    if [ -z "$OPENSSL" ]; then
      echo "ERROR: openssl not found in container" 1>&2
      exit 127
    fi

    n="${N}"
    to="${TO}"
    port="${PORT:-4433}"

    ok=0
    fail=0
    i=1
    while [ "$i" -le "$n" ]; do
      t0=$(date +%s%N 2>/dev/null || echo 0)
      if timeout "${to}s" "$OPENSSL" s_client -connect "server:${port}" -tls1_3 -brief -provider default </dev/null >/dev/null 2>&1; then
        t1=$(date +%s%N 2>/dev/null || echo 0)
        if [ "$t0" != "0" ] && [ "$t1" != "0" ]; then
          echo $(( (t1 - t0)/1000000 ))
        else
          # 极端情况下 date 不支持 %N，给一个占位值（避免空输出导致 host 侧误判）
          echo 0
        fi
        ok=$((ok+1))
      else
        fail=$((fail+1))
      fi
      i=$((i+1))
    done

    echo "OK=${ok} FAIL=${fail} ATTEMPTS=${n}" 1>&2
    exit 0
  ' 2> /tmp/tls_lat_okfail.log || true
)"

# 解析 OK/FAIL（保证总会输出一行摘要）
ok="$(grep -Eo 'OK=[0-9]+' /tmp/tls_lat_okfail.log | tail -n1 | cut -d= -f2 || echo 0)"
fail="$(grep -Eo 'FAIL=[0-9]+' /tmp/tls_lat_okfail.log | tail -n1 | cut -d= -f2 || echo 0)"
attempts="$N"
success_rate="$(python3 - <<PY
ok=int(${ok}); n=int(${attempts})
print(f"{(ok*100.0/n):.1f}" if n>0 else "nan")
PY
)"

# 可观测性：输出采样条数
sample_count="$(python3 - <<PY
vals = [v for v in """${ms_list}""".split() if v.strip()!=""]
print(len(vals))
PY
)"
echo "samples_collected=${sample_count} attempts=${attempts} ok=${ok} fail=${fail} success_rate=${success_rate}%"

# 空/全失败也必须给出可用结果行（避免文件只有头部）
if [ "${sample_count}" -eq 0 ] || [ "${ok}" -eq 0 ]; then
  echo "count=0 ms: p50=nan p95=nan p99=nan mean=nan (no successful handshakes)"
  echo
  exit 0
fi

# host python3 统计分位数（保证输出一行统计）
python3 - <<'PY' <<<"${ms_list}"
import sys, math, statistics

vals = [float(x) for x in sys.stdin.read().split() if x.strip() != ""]
vals.sort()

def pct(p):
    k = (len(vals)-1) * p / 100.0
    f = math.floor(k); c = math.ceil(k)
    if f == c:
        return vals[int(k)]
    return vals[f] * (c-k) + vals[c] * (k-f)

mean = statistics.mean(vals)
print(f"count={len(vals)} ms: p50={pct(50):.2f} p95={pct(95):.2f} p99={pct(99):.2f} mean={mean:.2f}")
PY

echo
