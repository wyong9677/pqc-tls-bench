#!/usr/bin/env bash
set -euo pipefail

# 从 workflow 读取 IMG；不要写死
IMG="${IMG:-openquantumsafe/oqs-ossl3:0.12.0}"
NET="pqcnet"
PORT=4433
N="${N:-50}"

GROUPS=("X25519")

# ---- Sanity check：容器内是否有 openssl ----
docker run --rm "${IMG}" sh -lc '
  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl not found inside container"
    exit 1
  fi
' >/dev/null

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

gen_cert='
set -e
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout /tmp/key.pem -out /tmp/cert.pem -subj "/CN=localhost" -days 1 >/dev/null 2>&1
'

# ---- 等待 server 就绪（替代 sleep 1）----
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
  echo "=== TLS latency distribution: $g (N=$N) ==="
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

  # 采样 N 次握手耗时（毫秒）。失败的握手不计入样本，但会统计失败数。
  docker run --rm --network "$NET" "$IMG" sh -lc "
    ok=0
    fail=0
    while [ \$ok -lt $N ]; do
      t0=\$(date +%s%N)
      if echo | openssl s_client -connect server:$PORT -tls1_3 \
          -provider oqsprovider -provider default -brief >/dev/null 2>&1; then
        t1=\$(date +%s%N)
        echo \$(( (t1 - t0)/1000000 ))
        ok=\$((ok+1))
      else
        fail=\$((fail+1))
      fi
      # 防止 CI 偶发抖动导致死循环：失败太多就退出
      if [ \$fail -gt 50 ]; then
        echo \"ERROR: too many handshake failures (\$fail)\" 1>&2
        exit 2
      fi
    done
    echo \"FAILURES=\$fail\" 1>&2
  " 2> /tmp/failures.log | sort -n > /tmp/lats_ms.txt

  # 读取失败次数（从 stderr）
  failures=$(grep -Eo 'FAILURES=[0-9]+' /tmp/failures.log | tail -n1 | cut -d= -f2 || echo "0")

  count=$(wc -l < /tmp/lats_ms.txt)
  p50_idx=$(( (count*50 + 99)/100 ))
  p95_idx=$(( (count*95 + 99)/100 ))
  p99_idx=$(( (count*99 + 99)/100 ))

  p50=$(sed -n "${p50_idx}p" /tmp/lats_ms.txt)
  p95=$(sed -n "${p95_idx}p" /tmp/lats_ms.txt)
  p99=$(sed -n "${p99_idx}p" /tmp/lats_ms.txt)

  mean=$(awk '{s+=$1} END{if(NR>0) printf "%.2f", s/NR; else print "nan"}' /tmp/lats_ms.txt)

  echo "count=$count failures=$failures ms: p50=$p50 p95=$p95 p99=$p99 mean=$mean"
  echo
done

docker rm -f server >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
