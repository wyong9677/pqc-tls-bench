#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

NET="pqcnet"
PORT=4433
TIMESEC="${TIMESEC:-5}"   # 冒烟默认 5s 更快

# 优先保证跑通 classic；hybrid 若可用自动加跑
GROUPS=("X25519" "X25519MLKEM768")

cleanup() {
  docker rm -f server >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== bench_tls.sh ==="
echo "Image: ${IMG}"
echo "OPENSSL_BIN: ${OPENSSL_BIN}"
echo "TIMESEC: ${TIMESEC}"
echo

# --- Sanity check (container) ---
docker run --rm "${IMG}" sh -lc '
  set -e
  command -v openssl >/dev/null 2>&1
  openssl version -a >/dev/null 2>&1 || true
'

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

# 证书生成脚本（容器内执行）
gen_cert='
set -e
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout /tmp/key.pem -out /tmp/cert.pem -subj "/CN=localhost" -days 1 >/dev/null 2>&1
'

# --- Wait until server is ready ---
wait_server_ready() {
  local tries=25
  local i=1
  while [ $i -le $tries ]; do
    if docker run --rm --network "$NET" "${IMG}" sh -lc \
      "timeout 3s openssl s_client -connect server:${PORT} -tls1_3 -brief </dev/null >/dev/null 2>&1"; then
      return 0
    fi
    sleep 0.2
    i=$((i+1))
  done
  return 1
}

# --- helper: check group availability in this build ---
group_available() {
  local g="$1"
  docker run --rm "${IMG}" sh -lc "openssl list -groups 2>/dev/null | grep -qx '${g}'"
}

for g in "${GROUPS[@]}"; do
  if ! group_available "$g"; then
    echo "=== skip group (not available): ${g} ==="
    echo
    continue
  fi

  echo "=== TLS handshake throughput: ${g} ==="

  # provider 策略：classic 只用 default；hybrid/PQ 才加载 oqsprovider
  PROVIDERS="-provider default"
  case "$g" in
    *MLKEM*|*KYBER*|*OQS*|mlkem*|kyber*) PROVIDERS="-provider oqsprovider -provider default" ;;
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

  # s_time：握手吞吐（full handshake），加 timeout 防挂住
  docker run --rm --network "$NET" "${IMG}" sh -lc "
    timeout $((TIMESEC + 15))s openssl s_time \
      -connect server:${PORT} -tls1_3 -new -time ${TIMESEC} \
      ${PROVIDERS}
  "

  echo
done
