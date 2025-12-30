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

# ---- container snippet: find openssl ----
container_find_openssl='
find_openssl() {
  for p in /opt/openssl32/bin/openssl /opt/openssl/bin/openssl /usr/local/bin/openssl /usr/bin/openssl /usr/local/ssl/bin/openssl; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  command -v openssl >/dev/null 2>&1 && { command -v openssl; return 0; }
  if command -v find >/dev/null 2>&1; then
    f="$(find /opt /usr/local /usr -maxdepth 6 -type f -name openssl 2>/dev/null | head -n 1 || true)"
    [ -n "$f" ] && [ -x "$f" ] && { echo "$f"; return 0; }
  fi
  return 1
}
OPENSSL="$(find_openssl || true)"
[ -n "$OPENSSL" ] || { echo "ERROR: openssl not found in container" 1>&2; exit 127; }
'

# ---- diagnostic: print openssl path + raw groups ----
echo "== Diagnostic: openssl path + raw 'list -groups' (head) =="
docker run --rm "${IMG}" sh -lc "
  set -e
  ${container_find_openssl}
  echo \"OPENSSL_BIN=\$OPENSSL\"
  echo
  echo \"-- openssl version (head) --\"
  \"\$OPENSSL\" version -a 2>&1 | head -n 20 || true
  echo
  echo \"-- openssl list -groups (head) --\"
  \"\$OPENSSL\" list -groups 2>&1 | head -n 120 || true
" || true
echo

# ---- get groups tokens (robust; never hard-fail) ----
get_groups_tokens() {
  docker run --rm "${IMG}" sh -lc "
    ${container_find_openssl}
    # 输出原始 groups，并尽量提取 token：去缩进、去冒号/逗号/括号，只取第一列
    \"\$OPENSSL\" list -groups 2>/dev/null \
      | sed -e 's/^[[:space:]]*//' -e 's/[,:].*$//' -e 's/[()]//g' \
      | awk 'NF>0{print \$1}' \
      | grep -E '^[A-Za-z0-9._-]+$' \
      | sort -u
  " 2>/dev/null || true
}

GROUPS="$(get_groups_tokens || true)"
if [ -n "$GROUPS" ]; then
  echo "Parsed group tokens (head):"
  echo "$GROUPS" | head -n 30
  echo
else
  echo "WARN: could not parse any group tokens; will run with default group negotiation (no -groups)."
  echo
fi

pick_classic_group() {
  # 优先 x25519（大小写不敏感），否则选第一条
  local g
  g="$(echo "$GROUPS" | grep -iE '^x25519$' | head -n1 || true)"
  [ -z "$g" ] && g="$(echo "$GROUPS" | head -n1 || true)"
  echo "$g"
}

pick_pq_group() {
  # 优先带 mlkem/kyber/oqs 的 token
  local g
  g="$(echo "$GROUPS" | grep -iE 'mlkem|kyber|oqs' | head -n1 || true)"
  echo "$g"
}

wait_server_ready() {
  local tries=20 i=1
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
  local group="${2:-}"         # 允许为空 => 不传 -groups
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

# classic：如果解析到了 group，就用；否则默认协商
CLASSIC="$(pick_classic_group || true)"
if [ -n "$CLASSIC" ]; then
  run_one "classic" "$CLASSIC" "-provider default"
else
  run_one "classic_default" "" "-provider default"
fi

# pq/hybrid：只有解析到看起来像 mlkem/kyber/oqs 的 group 才跑
PQ="$(pick_pq_group || true)"
if [ -n "$PQ" ]; then
  run_one "pqc_or_hybrid" "$PQ" "-provider oqsprovider -provider default"
else
  echo "NOTE: no pq/hybrid-looking group token found; done."
fi
