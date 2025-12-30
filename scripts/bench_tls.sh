#!/usr/bin/env bash
set -euo pipefail

IMG="openquantumsafe/oqs-ossl3:latest"
NET="pqcnet"
PORT=4433
TIMESEC=15

# 你想测的候选组（不保证都存在，下面会自动过滤）
CANDIDATE_GROUPS=("X25519" "X25519MLKEM768" "SecP256r1MLKEM768")

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

# 1) 读取镜像里真实支持的 TLS groups，并过滤候选组
echo "=== Discover supported TLS groups in container ==="
SUPPORTED_GROUPS="$(docker run --rm "$IMG" sh -lc 'openssl list -groups 2>/dev/null || true')"
echo "$SUPPORTED_GROUPS" | head -n 120 || true
echo

GROUPS=()
for g in "${CANDIDATE_GROUPS[@]}"; do
  if echo "$SUPPORTED_GROUPS" | grep -qE "(^|[[:space:]])${g}($|[[:space:]])"; then
    GROUPS+=("$g")
  fi
done

if [ "${#GROUPS[@]}" -eq 0 ]; then
  echo "ERROR: None of the candidate groups are supported by the container image."
  echo "Please inspect the 'openssl list -groups' output above and update CANDIDATE_GROUPS."
  exit 1
fi

echo "=== Will benchmark groups: ${GROUPS[*]} ==="
echo

gen_cert='
set -e
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout /tmp/key.pem -out /tmp/cert.pem -subj "/CN=localhost" -days 1 >/dev/null 2>&1
'

# 2) 端口就绪探测函数（避免 sleep 1 偶发失败）
wait_server_ready() {
  local tries=30
  local i=1
  while [ $i -le $tries ]; do
    if docker run --rm --network "$NET" "$IMG" sh -lc "echo | openssl s_client -connect server:${PORT} -tls1_3 -brief >/dev/null 2>&1"; then
      return 0
    fi
    sleep 0.2
    i=$((i+1))
  done
  return 1
}

for g in "${GROUPS[@]}"; do
  echo "=== TLS handshake throughput: group=${g} ==="

  docker rm -f server >/dev/null 2>&1 || true

  # 3) server：显式加载 provider，固定 group
  docker run -d --rm --name server --network "$NET" "$IMG" sh -lc "
    $gen_cert
    openssl s_server -accept $PORT -tls1_3 \
      -cert /tmp/cert.pem -key /tmp/key.pem \
      -groups $g \
      -provider oqsprovider -provider default \
      -quiet
  " >/dev/null

  if ! wait_server_ready; then
    echo "ERROR: server not ready for group=${g}"
    docker logs server || true
    exit 1
  fi

  # 4) client：显式加载 provider + s_time（全握手）
  docker run --rm --network "$NET" "$IMG" sh -lc "
    openssl s_time -connect server:$PORT -tls1_3 -new -time $TIMESEC \
      -provider oqsprovider -provider default
  "

  echo
done

docker rm -f server >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
