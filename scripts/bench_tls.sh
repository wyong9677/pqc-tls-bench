#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
NET="pqcnet"
PORT=4433
TIMESEC="${TIMESEC:-5}"

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

container_find_openssl='
find_openssl() {
  for p in /opt/openssl32/bin/openssl /opt/openssl/bin/openssl /usr/local/bin/openssl /usr/bin/openssl /usr/local/ssl/bin/openssl; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  command -v openssl >/dev/null 2>&1 && { command -v openssl; return 0; }
  command -v find >/dev/null 2>&1 || return 1
  f="$(find /opt /usr/local /usr -maxdepth 6 -type f -name openssl 2>/dev/null | head -n 1 || true)"
  [ -n "$f" ] && [ -x "$f" ] && { echo "$f"; return 0; }
  return 1
}
OPENSSL="$(find_openssl || true)"
[ -n "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }
'

# 从容器动态提取 groups（尽可能兼容不同输出格式）
get_groups() {
  docker run --rm "${IMG}" sh -lc "
    set -e
    ${container_find_openssl}
    out=\"\$(${container_find_openssl} ; \"\$OPENSSL\" list -groups 2>/dev/null || true)\"
    # 解析：去空白/冒号/括号/逗号，只保留看起来像 token 的字段
    echo \"\$out\" | sed -e 's/^[[:space:]]*//; s/[,:].*$//; s/[()]//g' \
      | awk 'NF>0 {print \$1}' \
      | grep -E '^[A-Za-z0-9._-]+$' \
      | sort -u
  " 2>/dev/null || true
}

# 选择 classic 与 pq/hybrid
select_groups() {
  local groups="$1"

  # classic：优先 X25519，其次 P-256/secp256r1，其次任意
  local classic
  classic="$(echo "$groups" | grep -iE '^x25519$' | head -n1 || true)"
  [ -z "$classic" ] && classic="$(echo "$groups" | grep -iE 'secp256r1|prime256v1|p-256|p256' | head -n1 || true)"
  [ -z "$classic" ] && classic="$(echo "$groups" | head -n1 || true)"

  # pq/hybrid：优先含 MLKEM/KYBER/OQS 的 token
  local pq
  pq="$(echo "$groups" | grep -iE 'mlkem|kyber|oqs' | head -n1 || true)"

  echo "${classic}|${pq}"
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

run_one_group() {
  local label="$1"
  local group="$2"   # 允许为空：表示不传 -groups
  local providers="$3"

  echo "=== TLS throughput: ${label} group=${group:-<default>} ==="
  echo "Providers: ${providers}"

  docker rm -f server >/dev/null 2>&1 || true
  docker run -d --rm --name server --network "$NET" "${IMG}" sh -lc "
    set -e
    ${container_find_openssl}
    \"\$OPENSSL\" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout /tmp/key.pem -out /tmp/cert.pem -subj \"/CN=localhost\" -days 1 >/dev/null 2>&1

    GOPT=\"\"
    if [ -n \"${group}\" ]; then
      GOPT=\"-groups ${group}\"
    fi

    \"\$OPENSSL\" s_server -accept ${PORT} -tls1_3 \
      -cert /tmp/cert.pem -key /tmp/key.pem \
      \$GOPT \
      ${providers} \
      -quiet
  " >/dev/null

  if ! wait_server_ready; then
    echo "ERROR: server not ready (label=${label}, group=${group:-default})"
    docker logs server 2>&1 | tail -n 200 || true
    exit 1
  fi

  timeout "$((TIMESEC + 15))"s docker run --rm --network "$NET" "${IMG}" sh -lc "
    set -e
    ${container_find_openssl}
    GOPT=\"\"
    if [ -n \"${group}\" ]; then
      GOPT=\"-groups ${group}\"
    fi
    \"\$OPENSSL\" s_time -connect server:${PORT} -tls1_3 -new -time ${TIMESEC} \$GOPT ${providers}
  "
  echo
}

GROUPS="$(get_groups)"
if [ -z "${GROUPS}" ]; then
  echo "WARN: could not parse any TLS groups from 'openssl list -groups'. Falling back to default negotiation."
  run_one_group "default" "" "-provider default"
  exit 0
fi

echo "Parsed groups (head):"
echo "$GROUPS" | head -n 30
echo

sel="$(select_groups "$GROUPS")"
CLASSIC="${sel%%|*}"
PQ="${sel##*|}"

# classic 走 default provider
run_one_group "classic" "${CLASSIC}" "-provider default"

# pq/hybrid 如果能选到，则跑第二组（加载 oqsprovider）
if [ -n "${PQ}" ]; then
  run_one_group "pqc_or_hybrid" "${PQ}" "-provider oqsprovider -provider default"
else
  echo "NOTE: no pq/hybrid-looking group found; only classic baseline produced."
fi
