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

# --- container: find openssl ---
container_find_openssl='
find_openssl() {
  for p in /opt/openssl/bin/openssl /opt/openssl32/bin/openssl /usr/local/bin/openssl /usr/bin/openssl /usr/local/ssl/bin/openssl; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  command -v openssl >/dev/null 2>&1 && { command -v openssl; return 0; }
  return 1
}
OPENSSL="$(find_openssl || true)"
[ -n "$OPENSSL" ] || { echo "ERROR: openssl not found in container" 1>&2; exit 127; }
'

echo "== Diagnostic: openssl + s_client -groups help (head) =="
docker run --rm "${IMG}" sh -lc "
  set -e
  ${container_find_openssl}
  echo \"OPENSSL_BIN=\$OPENSSL\"
  \"\$OPENSSL\" version -a 2>&1 | head -n 15 || true
  echo
  # 关键：TLS 组列表从这里拿
  \"\$OPENSSL\" s_client -help 2>&1 | grep -n \"-groups\" -n || true
  echo
  \"\$OPENSSL\" s_client -groups help 2>&1 | head -n 120 || true
" || true
echo

# --- 从 s_client -groups help 提取 token ---
get_tls_groups() {
  docker run --rm "${IMG}" sh -lc "
    ${container_find_openssl}
    \"\$OPENSSL\" s_client -groups help 2>/dev/null \
      | tr ',\\t' '  ' \
      | tr -s ' ' '\n' \
      | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
      | grep -E '^[A-Za-z0-9._-]+$' \
      | grep -viE '^(help|Supported|groups|named|default)$' \
      | sort -u
  " 2>/dev/null || true
}

GROUPS="$(get_tls_groups || true)"

pick_classic() {
  local g=""
  g="$(echo "$GROUPS" | grep -iE '^x25519$' | head -n1 || true)"
  [ -z "$g" ] && g="$(echo "$GROUPS" | grep -iE 'secp256r1|prime256v1|p-256|p256' | head -n1 || true)"
  [ -z "$g" ] && g="$(echo "$GROUPS" | head -n1 || true)"
  echo "$g"
}

pick_pq_or_hybrid() {
  # 优先含 mlkem/kyber（hybrid 通常包含 x25519mlkem...）
  echo "$GROUPS" | grep -iE 'mlkem|kyber' | head -n1 || true
}

wait_server_ready() {
  local tries=25 i=1
  while [ $i -le $tries ]; do
    if docker run --rm --network "$NET" "${IMG}" sh -lc "
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

run_one() {
  local label="$1"
  local group="${2:-}"         # 可为空：默认协商
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
    if [ -n \"${group}\" ]; then GOPT=\"-groups ${group}\"; fi

    \"\$OPENSSL\" s_server -accept ${PORT} -tls1_3 \
      -cert /tmp/cert.pem -key /tmp/key.pem \
      \$GOPT \
      ${providers} \
      -quiet
  " >/dev/null

  if ! wait_server_ready; then
    echo "ERROR: server not ready (label=${label}, group=${group:-default})"
    echo "--- server logs ---"
    docker logs server 2>&1 | tail -n 200 || true
    exit 1
  fi

  timeout "$((TIMESEC + 15))"s docker run --rm --network "$NET" "${IMG}" sh -lc "
    set -e
    ${container_find_openssl}
    GOPT=\"\"
    if [ -n \"${group}\" ]; then GOPT=\"-groups ${group}\"; fi
    \"\$OPENSSL\" s_time -connect server:${PORT} -tls1_3 -new -time ${TIMESEC} \$GOPT ${providers}
  "
  echo
}

if [ -z "$GROUPS" ]; then
  echo "WARN: could not parse TLS groups from 's_client -groups help'. Running default negotiation only."
  run_one "classic_default" "" "-provider default"
  exit 0
fi

echo "Parsed TLS group tokens (head):"
echo "$GROUPS" | head -n 40
echo

CLASSIC="$(pick_classic || true)"
PQ="$(pick_pq_or_hybrid || true)"

# classic：default provider
[ -n "$CLASSIC" ] && run_one "classic" "$CLASSIC" "-provider default" || run_one "classic_default" "" "-provider default"

# pq/hybrid：如果能找到含 mlkem/kyber 的 group，则加载 oqsprovider 运行
if [ -n "$PQ" ]; then
  run_one "pqc_or_hybrid" "$PQ" "-provider oqsprovider -provider default"
else
  echo "NOTE: no mlkem/kyber-looking TLS group found; only classic baseline produced."
fi
