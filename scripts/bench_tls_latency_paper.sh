#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

need docker
need python3

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
N="${N:-200}"
ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-3}"

# TLS config (same knobs as throughput)
TLS_PROVIDERS="${TLS_PROVIDERS:-default}"
TLS_GROUPS="${TLS_GROUPS:-}"
TLS_CERT_KEYALG="${TLS_CERT_KEYALG:-ec_p256}"
TLS_SERVER_EXTRA_ARGS="${TLS_SERVER_EXTRA_ARGS:-}"
TLS_CLIENT_EXTRA_ARGS="${TLS_CLIENT_EXTRA_ARGS:-}"

RUN_ID="${RUN_ID:-$(default_run_id)}"
OUTDIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "${OUTDIR}"

NET="pqcnet-${RUN_ID}"
PORT=4433

cleanup() {
  docker rm -f "server-${RUN_ID}" "client-${RUN_ID}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

providers_args="$(providers_to_args "${TLS_PROVIDERS}")"

samples_csv="${OUTDIR}/tls_latency_samples.csv"
summary_csv="${OUTDIR}/tls_latency_summary.csv"
rawdir="${OUTDIR}/tls_latency_raw"
mkdir -p "${rawdir}"

echo "repeat,mode,n,timeout_s,sample_idx,lat_ms,ok" > "${samples_csv}"
echo "repeat,mode,n,timeout_s,ok,fail,p50_ms,p95_ms,p99_ms,mean_ms,std_ms" > "${summary_csv}"

CONFIG_JSON="$(python3 - <<PY
import json
print(json.dumps({
  "benchmark": "tls_latency",
  "repeats": int(${REPEATS}),
  "warmup": int(${WARMUP}),
  "n": int(${N}),
  "timeout_s": float(${ATTEMPT_TIMEOUT}),
  "providers": ${TLS_PROVIDERS!r},
  "groups": ${TLS_GROUPS!r},
  "cert_keyalg": ${TLS_CERT_KEYALG!r},
  "server_extra_args": ${TLS_SERVER_EXTRA_ARGS!r},
  "client_extra_args": ${TLS_CLIENT_EXTRA_ARGS!r},
}))
PY
)"
write_meta_json "${OUTDIR}" "${MODE}" "${IMG}" "${CONFIG_JSON}"

info "TLS latency: mode=${MODE} run_id=${RUN_ID} repeats=${REPEATS} warmup=${WARMUP} N=${N} timeout=${ATTEMPT_TIMEOUT}s"
info "providers=${TLS_PROVIDERS} groups=${TLS_GROUPS:-<default>} cert_keyalg=${TLS_CERT_KEYALG}"

docker network rm "${NET}" >/dev/null 2>&1 || true
docker network create "${NET}" >/dev/null

# Start server
docker run -d --rm --name "server-${RUN_ID}" --network "${NET}" "${IMG}" sh -lc "
  set -e
  OPENSSL=/opt/openssl/bin/openssl
  [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
  [ -n \"\$OPENSSL\" ] || exit 127

  PROVIDERS='${providers_args}'

  if [ '${TLS_CERT_KEYALG}' = 'ec_p256' ]; then
    \"\$OPENSSL\" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout /tmp/key.pem -out /tmp/cert.pem -subj \"/CN=localhost\" -days 1 \${PROVIDERS} >/dev/null 2>&1
  else
    \"\$OPENSSL\" req -x509 -newkey '${TLS_CERT_KEYALG}' -nodes \
      -keyout /tmp/key.pem -out /tmp/cert.pem -subj \"/CN=localhost\" -days 1 \${PROVIDERS} >/dev/null 2>&1
  fi

  GROUPS_ARG=''
  if [ -n '${TLS_GROUPS}' ]; then GROUPS_ARG=\"-groups ${TLS_GROUPS}\"; fi

  \"\$OPENSSL\" s_server -accept ${PORT} -tls1_3 \
    -cert /tmp/cert.pem -key /tmp/key.pem \
    \${PROVIDERS} \${GROUPS_ARG} ${TLS_SERVER_EXTRA_ARGS} \
    -quiet
" >/dev/null

# Start client container (idle)
docker run -d --rm --name "client-${RUN_ID}" --network "${NET}" "${IMG}" sh -lc "sleep infinity" >/dev/null

# Wait ready
ready=0
for _ in $(seq 1 40); do
  if docker exec "client-${RUN_ID}" sh -lc "
    OPENSSL=/opt/openssl/bin/openssl
    [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
    PROVIDERS='${providers_args}'
    GROUPS_ARG=''
    if [ -n '${TLS_GROUPS}' ]; then GROUPS_ARG=\"-groups ${TLS_GROUPS}\"; fi
    timeout 2s \"\$OPENSSL\" s_client -connect server-${RUN_ID}:${PORT} -tls1_3 -brief \${PROVIDERS} \${GROUPS_ARG} ${TLS_CLIENT_EXTRA_ARGS} </dev/null >/dev/null 2>&1
  "; then
    ready=1; break
  fi
  sleep 0.2
done
[ "${ready}" -eq 1 ] || die "TLS server not ready"

# Warmup (inside container loop, no per-sample docker exec)
for _ in $(seq 1 "${WARMUP}"); do
  docker exec "client-${RUN_ID}" sh -lc "
    OPENSSL=/opt/openssl/bin/openssl
    [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
    PROVIDERS='${providers_args}'
    GROUPS_ARG=''
    if [ -n '${TLS_GROUPS}' ]; then GROUPS_ARG=\"-groups ${TLS_GROUPS}\"; fi
    timeout ${ATTEMPT_TIMEOUT}s \"\$OPENSSL\" s_client -connect server-${RUN_ID}:${PORT} -tls1_3 -brief \${PROVIDERS} \${GROUPS_ARG} ${TLS_CLIENT_EXTRA_ARGS} </dev/null >/dev/null 2>&1
  " >/dev/null 2>&1 || true
done

pct_py='
import math
def pct(vals,p):
    vals=sorted(vals)
    if not vals: return float("nan")
    k=(len(vals)-1)*p/100.0
    f=int(math.floor(k)); c=int(math.ceil(k))
    if f==c: return vals[f]
    return vals[f]*(c-k)+vals[c]*(k-f)
'

for r in $(seq 1 "${REPEATS}"); do
  rawfile="${rawdir}/rep${r}.txt"
  info "RUN rep=${r}/${REPEATS}"

  # One docker exec for N samples; measure inside container; output: "idx,lat_ms,ok"
  docker exec "client-${RUN_ID}" sh -lc "
    set -e
    OPENSSL=/opt/openssl/bin/openssl
    [ -x \"\$OPENSSL\" ] || OPENSSL=\"\$(command -v openssl || true)\"
    PROVIDERS='${providers_args}'
    GROUPS_ARG=''
    if [ -n '${TLS_GROUPS}' ]; then GROUPS_ARG=\"-groups ${TLS_GROUPS}\"; fi

    # prefer python3 inside container if available for robust timing
    if command -v python3 >/dev/null 2>&1; then
      python3 - <<'PY'
import os, subprocess, time, sys
N=int(os.environ["N"])
TO=float(os.environ["TO"])
PORT=os.environ["PORT"]
extra=os.environ.get("EXTRA","")
providers=os.environ.get("PROVIDERS","")
groups=os.environ.get("GROUPS","")

cmd_base=f'''OPENSSL=/opt/openssl/bin/openssl
[ -x \"$OPENSSL\" ] || OPENSSL=\"$(command -v openssl || true)\"
timeout {TO}s \"$OPENSSL\" s_client -connect {PORT} -tls1_3 -brief {providers} {groups} {extra} </dev/null >/dev/null 2>&1
'''.strip()

def run_one():
    t0=time.perf_counter_ns()
    rc=subprocess.call(["sh","-lc",cmd_base])
    t1=time.perf_counter_ns()
    return rc, (t1-t0)/1e6

for i in range(1,N+1):
    rc, ms = run_one()
    ok = 1 if rc==0 else 0
    sys.stdout.write(f\"{i},{ms:.4f},{ok}\\n\")
PY
    else
      # fallback: date +%s%N (best-effort)
      i=1
      while [ \$i -le ${N} ]; do
        t0=\$(date +%s%N)
        timeout ${ATTEMPT_TIMEOUT}s \"\$OPENSSL\" s_client -connect server-${RUN_ID}:${PORT} -tls1_3 -brief \${PROVIDERS} \${GROUPS_ARG} ${TLS_CLIENT_EXTRA_ARGS} </dev/null >/dev/null 2>&1
        rc=\$?
        t1=\$(date +%s%N)
        # ms = (t1 - t0)/1e6
        ms=\$(awk -v a=\"\$t0\" -v b=\"\$t1\" 'BEGIN{printf \"%.4f\", (b-a)/1000000.0}')
        ok=0; [ \$rc -eq 0 ] && ok=1
        echo \"\${i},\${ms},\${ok}\"
        i=\$((i+1))
      done
    fi
  " \
  N="${N}" TO="${ATTEMPT_TIMEOUT}" PORT="server-${RUN_ID}:${PORT}" \
  PROVIDERS="${providers_args}" GROUPS="${TLS_GROUPS:+-groups ${TLS_GROUPS}}" EXTRA="${TLS_CLIENT_EXTRA_ARGS}" \
  | tee "${rawfile}" >/dev/null

  # Append samples CSV and compute summary on host (no docker exec overhead in samples)
  python3 - <<PY
import csv, math, statistics, sys

raw_path=${rawfile!r}
samples_csv=${samples_csv!r}
summary_csv=${summary_csv!r}
rep=int(${r})
mode=${MODE!r}
N=int(${N})
TO=float(${ATTEMPT_TIMEOUT})

ok_vals=[]
ok=0; fail=0

with open(raw_path,"r",encoding="utf-8") as f:
    for line in f:
        line=line.strip()
        if not line: continue
        i_s, ms_s, ok_s = line.split(",")
        i=int(i_s); ms=float(ms_s); ok_flag=int(ok_s)
        with open(samples_csv,"a",encoding="utf-8",newline="") as out:
            out.write(f"{rep},{mode},{N},{TO},{i},{ms:.4f},{ok_flag}\\n")
        if ok_flag==1:
            ok += 1
            ok_vals.append(ms)
        else:
            fail += 1

def pct(vals,p):
    vals=sorted(vals)
    if not vals: return float("nan")
    k=(len(vals)-1)*p/100.0
    f=int(math.floor(k)); c=int(math.ceil(k))
    if f==c: return vals[f]
    return vals[f]*(c-k)+vals[c]*(k-f)

if ok_vals:
    mean=statistics.mean(ok_vals)
    std=statistics.pstdev(ok_vals) if len(ok_vals)>1 else 0.0
    p50=pct(ok_vals,50); p95=pct(ok_vals,95); p99=pct(ok_vals,99)
else:
    mean=std=p50=p95=p99=float("nan")

with open(summary_csv,"a",encoding="utf-8") as out:
    out.write(f"{rep},{mode},{N},{TO},{ok},{fail},{p50:.4f},{p95:.4f},{p99:.4f},{mean:.4f},{std:.4f}\\n")

print(f"[rep {rep}] ok={ok}/{N} p50={p50:.2f} p95={p95:.2f} p99={p99:.2f} mean={mean:.2f} std={std:.2f}")
PY

done

echo
echo "OK. Summary CSV: ${summary_csv}"
echo "Samples CSV: ${samples_csv}"
echo "Raw: ${rawdir}/rep*.txt"
echo "Meta: ${OUTDIR}/meta.json"
