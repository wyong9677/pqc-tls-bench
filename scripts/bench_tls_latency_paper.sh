#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
N="${N:-200}"
ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-3}"

if [ "${MODE}" = "smoke" ]; then
  REPEATS=1
  WARMUP=1
  N=20
  ATTEMPT_TIMEOUT=2
fi

NET="pqcnet"
PORT=4433

cleanup() {
  docker rm -f server client >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

python3 --version >/dev/null 2>&1 || { echo "ERROR: host python3 not available"; exit 1; }

samples_csv="${RESULTS_DIR}/tls_latency_samples.csv"
summary_csv="${RESULTS_DIR}/tls_latency_summary.csv"
echo "repeat,mode,n,attempt_timeout_ms,sample_idx,lat_raw_ms,lat_adj_ms,ok" > "${samples_csv}"
echo "repeat,mode,n,attempt_timeout_s,ok,fail,exec_baseline_ms,p50_ms,p95_ms,p99_ms,mean_ms,std_ms" > "${summary_csv}"

echo "=== bench_tls_latency.sh (paper-grade) ==="
echo "mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} N=${N} timeout=${ATTEMPT_TIMEOUT}s"
echo

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

# server
docker run -d --rm --name server --network "$NET" "${IMG}" sh -lc "
  set -e
  OPENSSL=/opt/openssl/bin/openssl
  [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
  [ -n \"\$OPENSSL\" ] || exit 127
  \"\$OPENSSL\" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout /tmp/key.pem -out /tmp/cert.pem -subj \"/CN=localhost\" -days 1 >/dev/null 2>&1
  \"\$OPENSSL\" s_server -accept ${PORT} -tls1_3 \
    -cert /tmp/cert.pem -key /tmp/key.pem -provider default -quiet
" >/dev/null

# client (idle)
docker run -d --rm --name client --network "$NET" "${IMG}" sh -lc "sleep infinity" >/dev/null

# wait ready
for _ in $(seq 1 30); do
  if docker exec client sh -lc "
    OPENSSL=/opt/openssl/bin/openssl; [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
    timeout 2s \"\$OPENSSL\" s_client -connect server:${PORT} -tls1_3 -brief -provider default </dev/null >/dev/null 2>&1
  "; then break; fi
  sleep 0.2
done

# warmup handshakes (not recorded)
for _ in $(seq 1 "${WARMUP}"); do
  docker exec client sh -lc "
    OPENSSL=/opt/openssl/bin/openssl; [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
    timeout ${ATTEMPT_TIMEOUT}s \"\$OPENSSL\" s_client -connect server:${PORT} -tls1_3 -brief -provider default </dev/null >/dev/null 2>&1
  " >/dev/null 2>&1 || true
done

export IMG NET PORT N ATTEMPT_TIMEOUT samples_csv summary_csv MODE

python3 - <<'PY'
import os, subprocess, time, statistics, math

MODE=os.environ["MODE"]
N=int(os.environ["N"])
TO=float(os.environ["ATTEMPT_TIMEOUT"])
samples_csv=os.environ["samples_csv"]
summary_csv=os.environ["summary_csv"]

def run_cmd(cmd):
    return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode

def pct(vals, p):
    vals=sorted(vals)
    k=(len(vals)-1)*p/100.0
    f=math.floor(k); c=math.ceil(k)
    if f==c: return vals[int(k)]
    return vals[f]*(c-k)+vals[c]*(k-f)

def docker_exec_latency(cmd_list):
    t0=time.perf_counter_ns()
    rc=run_cmd(cmd_list)
    t1=time.perf_counter_ns()
    return rc, (t1-t0)/1e6  # ms

# build exec commands
handshake = ["docker","exec","client","sh","-lc", f'''
OPENSSL=/opt/openssl/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
[ -n "$OPENSSL" ] || exit 127
timeout {TO:.0f}s "$OPENSSL" s_client -connect server:{os.environ["PORT"]} -tls1_3 -brief -provider default </dev/null >/dev/null 2>&1
'''.strip()]

noop = ["docker","exec","client","sh","-lc","true"]

REPEATS=int(os.environ.get("REPEATS","5"))

for rep in range(1, REPEATS+1):
    # 1) baseline: docker exec overhead distribution (noop)
    exec_lat=[]
    for _ in range(N):
        _, ms = docker_exec_latency(noop)
        exec_lat.append(ms)
    exec_baseline = pct(exec_lat, 50)  # use p50 baseline for robustness

    # 2) handshake samples
    raw=[]
    adj=[]
    ok=0
    fail=0
    for i in range(1, N+1):
        rc, ms = docker_exec_latency(handshake)
        if rc==0:
            ok += 1
            raw.append(ms)
            adj_ms = max(0.0, ms - exec_baseline)
            adj.append(adj_ms)
            with open(samples_csv,"a",encoding="utf-8") as f:
                f.write(f"{rep},{MODE},{N},{int(TO*1000)},{i},{ms:.4f},{adj_ms:.4f},1\n")
        else:
            fail += 1
            with open(samples_csv,"a",encoding="utf-8") as f:
                f.write(f"{rep},{MODE},{N},{int(TO*1000)},{i},nan,nan,0\n")

    if ok==0:
        with open(summary_csv,"a",encoding="utf-8") as f:
            f.write(f"{rep},{MODE},{N},{TO},{ok},{fail},{exec_baseline:.4f},nan,nan,nan,nan,nan\n")
        continue

    mean=statistics.mean(adj)
    std=statistics.pstdev(adj) if len(adj)>1 else 0.0
    p50=pct(adj,50); p95=pct(adj,95); p99=pct(adj,99)

    with open(summary_csv,"a",encoding="utf-8") as f:
        f.write(f"{rep},{MODE},{N},{TO},{ok},{fail},{exec_baseline:.4f},{p50:.4f},{p95:.4f},{p99:.4f},{mean:.4f},{std:.4f}\n")

    print(f"[rep {rep}] ok={ok}/{N} exec_baseline_p50_ms={exec_baseline:.2f} adj_ms: p50={p50:.2f} p95={p95:.2f} p99={p99:.2f} mean={mean:.2f} std={std:.2f}")

PY

echo
echo "Samples CSV : ${samples_csv}"
echo "Summary CSV : ${summary_csv}"
