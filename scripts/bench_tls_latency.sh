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

get_groups() {
  docker run --rm "${IMG}" sh -lc "
    set -e
    ${container_find_openssl}
    out=\"\$(${container_find_openssl} ; \"\$OPENSSL\" list -groups 2>/dev/null || true)\"
    echo \"\$out\" | sed -e 's/^[[:space:]]*//; s/[,:].*$//; s/[()]//g' \
      | awk 'NF>0 {print \$1}' \
      | grep -E '^[A-Za-z0-9._-]+$' \
      | sort -u
  " 2>/dev/null || true
}

select_groups() {
  local groups="$1"
  local classic pq
  classic="$(echo "$groups" | grep -iE '^x25519$' | head -n1 || true)"
  [ -z "$classic" ] && classic="$(echo "$groups" | grep -iE 'secp256r1|prime256v1|p-256|p256' | head -n1 || true)"
  [ -z "$classic" ] && classic="$(echo "$groups" | head -n1 || true)"
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

run_latency() {
  local label="$1"
  local group="$2"     # 可为空
  local providers="$3" # provider flags

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

  docker run --rm --network "$NET" \
    -e N="${N}" -e ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT}" \
    "${IMG}" sh -lc "
      set -e
      ${container_find_openssl}
      command -v python3 >/dev/null 2>&1 || { echo 'ERROR: python3 not found' 1>&2; exit 127; }

      GOPT=[]
      grp='${group}'
      if grp:
        GOPT=['-groups', grp]

      prov='${providers}'
      prov_args=prov.split() if prov else []

      python3 - << 'PY'
import os, subprocess, time, math, statistics

N = int(os.environ.get('N','10'))
TO = float(os.environ.get('ATTEMPT_TIMEOUT','2'))

OPENSSL = os.environ['OPENSSL_BIN']
PORT = '4433'
# PROVIDERS/GROUP_ARGS 由外层注入
PROV = os.environ.get('PROV','').split()
GROUP = os.environ.get('GROUP','').strip()

cmd = [OPENSSL,'s_client','-connect',f'server:{PORT}','-tls1_3','-brief']
if GROUP:
  cmd += ['-groups', GROUP]
cmd += PROV

lats=[]
ok=0
fail=0
for _ in range(N):
  t0=time.time_ns()
  try:
    subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=TO, check=False)
    t1=time.time_ns()
    lats.append((t1-t0)/1e6)
    ok += 1
  except subprocess.TimeoutExpired:
    fail += 1

lats.sort()
def pct(p):
  if not lats: return float('nan')
  k=(len(lats)-1)*p/100.0
  f=math.floor(k); c=math.ceil(k)
  if f==c: return lats[int(k)]
  return lats[f]*(c-k)+lats[c]*(k-f)

sr = (ok*100.0/N) if N else float('nan')
mean = statistics.mean(lats) if lats else float('nan')
print(f'attempts={N} ok={ok} failures={fail} success_rate={sr:.1f}% '
      f'ms: p50={pct(50):.2f} p95={pct(95):.2f} p99={pct(99):.2f} mean={mean:.2f}')
PY
    " -e OPENSSL_BIN="$(docker run --rm "${IMG}" sh -lc "${container_find_openssl}; echo \"\$OPENSSL\"")" \
      -e PROV="${providers}" \
      -e GROUP="${group}"

  echo
}

GROUPS="$(get_groups)"
if [ -z "$GROUPS" ]; then
  echo "WARN: could not parse any TLS groups. Falling back to default negotiation."
  run_latency "default" "" "-provider default"
  exit 0
fi

echo "Parsed groups (head):"
echo "$GROUPS" | head -n 30
echo

sel="$(select_groups "$GROUPS")"
CLASSIC="${sel%%|*}"
PQ="${sel##*|}"

run_latency "classic" "${CLASSIC}" "-provider default"
if [ -n "$PQ" ]; then
  run_latency "pqc_or_hybrid" "${PQ}" "-provider oqsprovider -provider default"
else
  echo "NOTE: no pq/hybrid-looking group found; only classic baseline produced."
fi
