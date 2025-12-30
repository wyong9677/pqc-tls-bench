#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
NET="pqcnet"
PORT=4433
TIMESEC="${TIMESEC:-5}"

# 冒烟：最多跑 2 个（classic + 1 个 hybrid/pqc-only 如果存在）
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

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

# 这些 helper 通过“容器内脚本片段”保证 openssl 路径可用
container_find_openssl='
find_openssl() {
  for p in /opt/openssl32/bin/openssl /opt/openssl/bin/openssl /usr/local/bin/openssl /usr/bin/openssl /usr/local/ssl/bin/openssl; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  command -v openssl >/dev/null 2>&1 && { command -v openssl; return 0; }
  command -v find >/dev/null 2>&1 || return 1
  f="$(find /opt /usr/local /usr -maxdepth 4 -type f -name openssl 2>/dev/null | head -n 1 || true)"
  [ -n "$f" ] && [ -x "$f" ] && { echo "$f"; return 0; }
  return 1
}
OPENSSL="$(find_openssl || true)"
[ -n "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }
'

group_available() {
  local g="$1"
  docker run --rm "${IMG}" sh -lc "
    set -e
    ${container_find_openssl}
    \"\$OPENSSL\" list -groups 2>/dev/null | grep -qx '${g}'
  "
}

pick_providers() {
  local g="$1"
  case "$g" in
    *MLKEM*|*KYBER*|mlkem*|kyber*) echo "-provider oqsprovider -provider default" ;;
    *) echo "-provider default" ;;
  esac
}

wait_server_ready() {
  local tries=20 i=1
  while [ $i -le $tries ]; do
    if docker run --rm --network "$NET" "${IMG}" sh -lc "
      set -e
      ${container_find_openssl}
      timeout 2s \"\$OPENSSL\" s_client -connect server:${PORT} -tls1_3 -brief </dev/null >/dev/null 2>&1
    "; then
      return 0
    fi
    sleep 0.2
    i=$((i+1))
  done
  return 1
}

# 选出存在的候选组
SELECTED=()
for g in "${CANDIDATE_GROUPS[@]}"; do
  if group_available "$g"; then
    SELECTED+=("$g")
  fi
done

if [ "${#SELECTED[@]}" -eq 0 ]; then
  echo "ERROR: none of candidate TLS groups available: ${CANDIDATE_GROUPS[*]}"
  exit 1
fi

# 冒烟最多 2 个
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
    ${container_find_openssl}
    # generate cert
    \"\$OPENSSL\" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout /tmp/key.pem -out /tmp/cert.pem -subj \"/CN=localhost\" -days 1 >/dev/null 2>&1

    \"\$OPENSSL\" s_server -accept ${PORT} -tls1_3 \
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

  # s_time: full handshake throughput
  timeout "$((TIMESEC + 15))"s docker run --rm --network "$NET" "${IMG}" sh -lc "
    set -e
    ${container_find_openssl}
    \"\$OPENSSL\" s_time -connect server:${PORT} -tls1_3 -new -time ${TIMESEC} ${PROVIDERS}
  "

  echo
done
