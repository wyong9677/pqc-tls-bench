#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

NET="pqcnet"
PORT=4433
N="${N:-50}"

GROUPS=("X25519")

echo "=== bench_tls_latency.sh ==="
echo "Image: ${IMG}"
echo "OPENSSL_BIN: ${OPENSSL_BIN}"
echo "N: ${N}"
echo

# --- Sanity check (container) ---
docker run --rm -e OPENSSL_BIN="${OPENSSL_BIN}" "${IMG}" sh -lc '
  if [ -x "$OPENSSL_BIN" ] || command -v "$OPENSSL_BIN" >/dev/null 2>&1; then
    "$OPENSSL_BIN" version -a >/dev/null 2>&1 || true
    exit 0
  fi
  echo "ERROR: cannot execute OPENSSL_BIN inside container: $OPENSSL_BIN"
  exit 1
' >/dev/null

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

gen_cert='
set -e
"$OPENSSL_BIN" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout /tmp/key.pem -out /tmp/cert.pem -subj "/CN=localhost" -days 1 >/dev/null 2>&1
'

wait_server_ready() {
  local tries=30
  local i=1
  while [ $i -le $tries ]; do
    if docker run --rm --network "$NET" \
      -e OPENSSL_BIN="${OPENSSL_BIN}" \
      "$IMG" sh -lc \
      "timeout 3s sh -lc 'echo | \"\$OPENSSL_BIN\" s_client -connect server:${PORT} -tls1_3 -brief >/dev/null 2>&1'"; then
      return 0
    fi
    sleep 0.2
    i=$((i+1))
  done
  return 1
}

for g in "${GROUPS[@]}"; do
  echo "=== TLS latency distribution: $g (N=$N) ==="

  docker rm -f server >/dev/null 2>&1 || true
  docker run -d --rm --name server --network "$NET" \
    -e OPENSSL_BIN="${OPENSSL_BIN}" \
    "$IMG" sh -lc "
      set -e
      ${gen_cert}
      \"\$OPENSSL_BIN\" s_server -accept ${PORT} -tls1_3 \
        -cert /tmp/cert.pem -key /tmp/key.pem \
        -groups ${g} \
        -provider oqsprovider -provider default \
        -quiet
    " >/dev/null

  if ! wait_server_ready; then
    echo "ERROR: server not ready for group=${g}"
    echo "--- server logs ---"
    docker logs server 2>&1 | tail -n 200 || true
    exit 1
  fi

  # 采样 N 次握手耗时（毫秒）。失败的握手不计入样本，但会统计失败数。
  docker run --rm --network "$NET" \
    -e OPENSSL_BIN="${OPENSSL_BIN}" \
    "$IMG" sh -lc "
      ok=0
      fail=0
      while [ \$ok -lt ${N} ]; do
        t0=\$(date +%s%N)

        # 单次握手强制 3 秒超时，避免 CI 卡住
        if timeout 3s sh -lc 'echo | \"\$OPENSSL_BIN\" s_client -connect server:${PORT} -tls1_3 \
              -provider oqsprovider -provider default -brief >/dev/null 2>&1'; then
          t1=\$(date +%s%N)
          echo \$(( (t1 - t0)/1000000 ))
          ok=\$((ok+1))
        else
          fail=\$((fail+1))
        fi

        # 防止偶发抖动导致死循环
        if [ \$fail -gt 50 ]; then
          echo \"ERROR: too many handshake failures (\$fail)\" 1>&2
          exit 2
        fi
      done
      echo \"FAILURES=\$fail\" 1>&2
    " 2> /tmp/failures.log | sort -n > /tmp/lats_ms.txt

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
