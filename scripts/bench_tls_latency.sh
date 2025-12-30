#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
NET="pqcnet"
PORT=4433
N="${N:-10}"
ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-2}"

CANDIDATE_GROUPS=("X25519" "X25519MLKEM768" "SecP256r1MLKEM768" "MLKEM768")

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
if [ "${#SELECTED[@]}" -gt 2 ]; then
  SELECTED=("${SELECTED[@]:0:2}")
fi

echo "Selected groups: ${SELECTED[*]}"
echo

for g in "${SELECTED[@]}"; do
  echo "=== TLS latency: group=${g} ==="
  PROVIDERS="$(pick_providers "$g")"
  echo "Providers: ${PROVIDERS}"

  docker rm -f server >/dev/null 2>&1 || true
  docker run -d --rm --name server --network "$NET" "${IMG}" sh -lc "
    set -e
    ${container_find_openssl}
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

  docker run --rm --network "$NET" \
    -e N="${N}" -e ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT}" \
    "${IMG}" sh -lc "
      set -e
      ${container_find_openssl}
      command -v python3 >/dev/null 2>&1 || { echo 'ERROR: python3 not found' 1>&2; exit 127; }

      python3 - << 'PY'
import os, subprocess, time, math, statistics

N = int(os.environ.get("N","10"))
TO = float(os.environ.get("ATTEMPT_TIMEOUT","2"))

# OPENSSL_BIN 从 shell 注入
OPENSSL = os.environ.get("OPENSSL_BIN","openssl")
PROVIDERS = os.environ.get("PROVIDERS","").split()

cmd = [OPENSSL, "s_client", "-connect", "server:4433", "-tls1_3", "-brief"] + PROVIDERS

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
    if not lats: return float("nan")
    k=(len(lats)-1)*p/100.0
    f=math.floor(k); c=math.ceil(k)
    if f==c: return lats[int(k)]
    return lats[f]*(c-k)+lats[c]*(k-f)

sr = (ok*100.0/N) if N>0 else float("nan")
mean = statistics.mean(lats) if lats else float("nan")
print(f"attempts={N} ok={ok} failures={fail} success_rate={sr:.1f}% "
      f"ms: p50={pct(50):.2f} p95={pct(95):.2f} p99={pct(99):.2f} mean={mean:.2f}")
PY
    " -e OPENSSL_BIN="$(docker run --rm "${IMG}" sh -lc "${container_find_openssl}; echo \"\$OPENSSL\"")" \
      -e PROVIDERS="${PROVIDERS}"

  echo
done
