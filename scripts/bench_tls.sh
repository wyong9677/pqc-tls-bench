#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
NET="pqcnet"
PORT=4433
TIMESEC="${TIMESEC:-5}"

# 候选组：classic + 常见 hybrid + 常见 pqc-only（存在才跑）
CANDIDATE_GROUPS=("X25519" "X25519MLKEM768" "SecP256r1MLKEM768" "MLKEM768")

cleanup() {
  docker rm -f server >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== bench_tls.sh ==="
echo "Image: ${IMG}"
echo "TIMESEC: ${TIMESEC}"
echo

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

pick_providers() {
  local g="$1"
  # classic 用 default；含 MLKEM/KYBER 的组才加载 oqsprovider
  case "$g" in
    *MLKEM*|*KYBER*|mlkem*|kyber*) echo "-provider oqsprovider -provider default" ;;
    *) echo "-provider default" ;;
  esac
}

# 只跑“存在的”前两组（冒烟更快）；你要更多就把 2 改大
SELECTED=()
for g in "${CANDIDATE_GROUPS[@]}"; do
  if group_available "$g"; then
    SELECTED+=("$g")
  fi
done

if [ "${#SELECTED[@]}" -eq 0 ]; then
  echo "ERROR: no TLS groups available from candidates: ${CANDIDATE_GROUPS[*]}"
  exit 1
fi

# 冒烟：最多跑 2 个
if [ "${#SELECTED[@]}" -gt 2 ]; then
  SELECTED=("${SELECTED[@]:0:2}")
fi

echo "Selected groups: ${SELECTED[*]}"
echo

for g in "${SELECTED[@]}"; do
  echo "=== TLS handshake throughput: group=${g} ==="
  PROVIDERS="$(pick_providers "$g")"
  echo "Providers: ${PROVIDERS}"

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

  # s_time：full handshake 吞吐；加 timeout 防挂住
  timeout "$((TIMESEC + 15))"s docker run --rm --network "$NET" "${IMG}" sh -lc "
    openssl s_time -connect server:${PORT} -tls1_3 -new -time ${TIMESEC} ${PROVIDERS}
  "

  echo
done
