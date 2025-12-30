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
  rm -f /tmp/tls_lat_samples_ms.txt /tmp/tls_lat_okfail.log >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== bench_tls_latency.sh (host-timed) ==="
echo "Image: ${IMG}"
echo "N: ${N}  attempt_timeout: ${ATTEMPT_TIMEOUT}s"
echo

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
  echo "samples_collected=0 attempts=${N} ok=0 fail=${N} success_rate=0.0%"
  echo "count=0 ms: p50=nan p95=nan p99=nan mean=nan (server not ready)"
  echo
  exit 0
fi

# host 侧采样文件
: > /tmp/tls_lat_samples_ms.txt
: > /tmp/tls_lat_okfail.log

# 用 host python3 计时：每次调用一个 client 容器做真实握手
export IMG NET PORT N ATTEMPT_TIMEOUT
python3 - <<'PY'
import os, subprocess, time, math, statistics

IMG = os.environ["IMG"]
NET = os.environ["NET"]
PORT = os.environ["PORT"]
N = int(os.environ.get("N","10"))
TO = float(os.environ.get("ATTEMPT_TIMEOUT","2"))

samples=[]
ok=0
fail=0

# client 容器内只做一次 s_client；不依赖 python/date
client_cmd = [
    "docker","run","--rm","--network",NET, IMG, "sh","-lc",
    # 使用容器内的 openssl 绝对路径优先
    f'''
OPENSSL=/opt/openssl/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
[ -n "$OPENSSL" ] || exit 127
timeout {TO:.0f}s "$OPENSSL" s_client -connect server:{PORT} -tls1_3 -brief -provider default </dev/null >/dev/null 2>&1
'''
]

for _ in range(N):
    t0 = time.perf_counter_ns()
    # 不用 check=True，避免非0直接抛异常；用 returncode 判断
    p = subprocess.run(client_cmd)
    t1 = time.perf_counter_ns()
    if p.returncode == 0:
        ok += 1
        samples.append((t1 - t0)/1e6)  # ms
    else:
        fail += 1

# 输出给父脚本读取（写文件由父脚本完成更直观，但这里直接落文件也可）
with open("/tmp/tls_lat_okfail.log","w",encoding="utf-8") as f:
    f.write(f"OK={ok} FAIL={fail} ATTEMPTS={N}\n")

with open("/tmp/tls_lat_samples_ms.txt","w",encoding="utf-8") as f:
    for v in samples:
        f.write(f"{v}\n")
PY

ok="$(grep -Eo 'OK=[0-9]+' /tmp/tls_lat_okfail.log | tail -n1 | cut -d= -f2 || echo 0)"
fail="$(grep -Eo 'FAIL=[0-9]+' /tmp/tls_lat_okfail.log | tail -n1 | cut -d= -f2 || echo 0)"
attempts="$N"
sample_count="$(wc -l </tmp/tls_lat_samples_ms.txt | tr -d ' ')"
success_rate="$(python3 -c "ok=int('${ok}'); n=int('${attempts}'); print(f'{(ok*100.0/n):.1f}' if n>0 else 'nan')")"

echo "samples_collected=${sample_count} attempts=${attempts} ok=${ok} fail=${fail} success_rate=${success_rate}%"

if [ "${sample_count}" -eq 0 ] || [ "${ok}" -eq 0 ]; then
  echo "count=0 ms: p50=nan p95=nan p99=nan mean=nan (no successful handshakes)"
  echo
  exit 0
fi

# 统计分位数/均值（从文件读，稳定输出一行）
export TLS_LAT_FILE="/tmp/tls_lat_samples_ms.txt"
python3 -c '
import os, math, statistics

path=os.environ["TLS_LAT_FILE"]
vals=[]
with open(path,"r",encoding="utf-8") as f:
    for line in f:
        line=line.strip()
        if not line: 
            continue
        vals.append(float(line))
vals.sort()

def pct(p):
    k=(len(vals)-1)*p/100.0
    f=math.floor(k); c=math.ceil(k)
    if f==c:
        return vals[int(k)]
    return vals[f]*(c-k)+vals[c]*(k-f)

mean=statistics.mean(vals)
print(f"count={len(vals)} ms: p50={pct(50):.2f} p95={pct(95):.2f} p99={pct(99):.2f} mean={mean:.2f}")
'

echo
