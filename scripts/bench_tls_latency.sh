#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
NET="pqcnet"
PORT=4433
N="${N:-10}"
ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-2}"

cleanup() {
  docker rm -f server >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== bench_tls_latency.sh ==="
echo "Image: ${IMG}"
echo "N: ${N}  attempt_timeout: ${ATTEMPT_TIMEOUT}s"
echo

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

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

run_latency() {
  local label="$1"
  local group="${2:-}"     # 可为空：默认协商
  local providers="$3"

  echo "=== TLS latency: ${label} group=${group:-<default>} ==="
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
    docker logs server 2>&1 | tail -n 200 || true
    exit 1
  fi

  # 纯 shell：测 N 次并计算 p50/p95/p99/mean
  docker run --rm --network "$NET" \
    -e N="${N}" -e ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT}" \
    "${IMG}" sh -lc "
      set -e
      ${container_find_openssl}

      n=\${N}
      to=\${ATTEMPT_TIMEOUT}

      ok=0
      fail=0
      tmp=\$(mktemp)
      : > \"\$tmp\"

      i=1
      while [ \$i -le \"\$n\" ]; do
        t0=\$(date +%s%N)
        if timeout \"\${to}s\" \"\$OPENSSL\" s_client -connect server:${PORT} -tls1_3 -brief \
            ${providers} $( [ -n "${group}" ] && echo "-groups ${group}" ) \
            </dev/null >/dev/null 2>&1; then
          t1=\$(date +%s%N)
          echo \$(( (t1 - t0)/1000000 )) >> \"\$tmp\"
          ok=\$((ok+1))
        else
          fail=\$((fail+1))
        fi
        i=\$((i+1))
      done

      cnt=\$(wc -l < \"\$tmp\" | tr -d \" \")
      if [ \"\$cnt\" -eq 0 ]; then
        echo \"attempts=\$n ok=0 failures=\$fail success_rate=0.0% (no successful handshakes)\"
        rm -f \"\$tmp\"
        exit 0
      fi

      sort -n \"\$tmp\" -o \"\$tmp\"

      # 索引：向上取整
      pidx() { awk -v c=\"\$1\" -v p=\"\$2\" 'BEGIN{print int((c*p+99)/100)}'; }

      p50=\$(sed -n \"\$(pidx \$cnt 50)p\" \"\$tmp\")
      p95=\$(sed -n \"\$(pidx \$cnt 95)p\" \"\$tmp\")
      p99=\$(sed -n \"\$(pidx \$cnt 99)p\" \"\$tmp\")
      mean=\$(awk '{s+=\$1} END{printf \"%.2f\", s/NR}' \"\$tmp\")
      sr=\$(awk -v ok=\"\$ok\" -v n=\"\$n\" 'BEGIN{printf \"%.1f\", (ok*100.0/n)}')

      echo \"attempts=\$n ok=\$ok failures=\$fail success_rate=\${sr}% ms: p50=\${p50} p95=\${p95} p99=\${p99} mean=\${mean}\"
      rm -f \"\$tmp\"
    "

  echo
}

if [ -z "$GROUPS" ]; then
  echo "WARN: could not parse TLS groups from 's_client -groups help'. Running default negotiation only."
  run_latency "classic_default" "" "-provider default"
  exit 0
fi

echo "Parsed TLS group tokens (head):"
echo "$GROUPS" | head -n 40
echo

CLASSIC="$(pick_classic || true)"
PQ="$(pick_pq_or_hybrid || true)"

[ -n "$CLASSIC" ] && run_latency "classic" "$CLASSIC" "-provider default" || run_latency "classic_default" "" "-provider default"

if [ -n "$PQ" ]; then
  run_latency "pqc_or_hybrid" "$PQ" "-provider oqsprovider -provider default"
else
  echo "NOTE: no mlkem/kyber-looking TLS group found; only classic baseline produced."
fi
