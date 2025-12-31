#!/usr/bin/env sh
set -eu

# POSIX-safe TLS latency core
# Usage: tls_latency_core.sh /out
# Env:
#   MODE, REPEATS, WARMUP, N, ATTEMPT_TIMEOUT
#   TLS_PROVIDERS (comma-separated, default: default)
#   TLS_GROUPS (default: X25519)
#   TLS_CERT_KEYALG (default: ec_p256)
#   TLS_SERVER_EXTRA_ARGS, TLS_CLIENT_EXTRA_ARGS (optional; simple tokens)
# Output:
#   tls_latency_samples.csv, tls_latency_summary.csv, tls_latency_raw/rep*.txt

OUTDIR="${1:?usage: tls_latency_core.sh /out}"
mkdir -p "${OUTDIR}"

MODE="${MODE:-paper}"
REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
N="${N:-200}"
ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-3}"

TLS_PROVIDERS="${TLS_PROVIDERS:-default}"
TLS_GROUPS="${TLS_GROUPS:-X25519}"
TLS_CERT_KEYALG="${TLS_CERT_KEYALG:-ec_p256}"
TLS_SERVER_EXTRA_ARGS="${TLS_SERVER_EXTRA_ARGS:-}"
TLS_CLIENT_EXTRA_ARGS="${TLS_CLIENT_EXTRA_ARGS:-}"

PORT="${PORT:-4433}"

OPENSSL="/opt/openssl/bin/openssl"
if [ ! -x "${OPENSSL}" ]; then
  OPENSSL="$(command -v openssl 2>/dev/null || true)"
fi
if [ -z "${OPENSSL}" ] || [ ! -x "${OPENSSL}" ]; then
  echo "ERROR: openssl not found" >&2
  exit 127
fi

# temp dir
tmp="$(mktemp -d 2>/dev/null || mktemp -d -t tlsbench)"
cleanup() {
  if [ -f "${tmp}/server.pid" ]; then
    pid="$(cat "${tmp}/server.pid" 2>/dev/null || true)"
    if [ -n "${pid}" ]; then
      kill "${pid}" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "${tmp}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

samples_csv="${OUTDIR}/tls_latency_samples.csv"
summary_csv="${OUTDIR}/tls_latency_summary.csv"
rawdir="${OUTDIR}/tls_latency_raw"
mkdir -p "${rawdir}"

echo "repeat,mode,n,timeout_s,sample_idx,lat_ms,ok" > "${samples_csv}"
echo "repeat,mode,n,timeout_s,ok,fail,p50_ms,p95_ms,p99_ms,mean_ms,std_ms" > "${summary_csv}"

# ----- build args (POSIX: no arrays) -----
build_provider_args() {
  : > "${tmp}/prov.args"
  echo "${TLS_PROVIDERS}" | awk -F',' '{
    for (i=1;i<=NF;i++){
      gsub(/^[ \t]+|[ \t]+$/,"",$i);
      if ($i!="") print "-provider\n" $i
    }
  }' >> "${tmp}/prov.args"
}

build_groups_args() {
  : > "${tmp}/grp.args"
  if [ -n "${TLS_GROUPS}" ]; then
    printf "%s\n%s\n" "-groups" "${TLS_GROUPS}" >> "${tmp}/grp.args"
  fi
}

make_cert() {
  set -- $(cat "${tmp}/prov.args" 2>/dev/null || true)
  if [ "${TLS_CERT_KEYALG}" = "ec_p256" ]; then
    "${OPENSSL}" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "${tmp}/key.pem" -out "${tmp}/cert.pem" -subj "/CN=localhost" -days 1 \
      "$@" >/dev/null 2>&1
  else
    "${OPENSSL}" req -x509 -newkey "${TLS_CERT_KEYALG}" -nodes \
      -keyout "${tmp}/key.pem" -out "${tmp}/cert.pem" -subj "/CN=localhost" -days 1 \
      "$@" >/dev/null 2>&1
  fi
}

start_server() {
  set -- $(cat "${tmp}/prov.args" 2>/dev/null || true) $(cat "${tmp}/grp.args" 2>/dev/null || true)
  # TLS_SERVER_EXTRA_ARGS: best-effort simple tokens
  # shellcheck disable=SC2086
  "${OPENSSL}" s_server -accept "${PORT}" -tls1_3 \
    -cert "${tmp}/cert.pem" -key "${tmp}/key.pem" \
    "$@" ${TLS_SERVER_EXTRA_ARGS} \
    -quiet >"${tmp}/server.log" 2>&1 &
  echo $! > "${tmp}/server.pid"
}

wait_server_ready() {
  i=1
  while [ $i -le 40 ]; do
    set -- $(cat "${tmp}/prov.args" 2>/dev/null || true) $(cat "${tmp}/grp.args" 2>/dev/null || true)
    # shellcheck disable=SC2086
    if "${OPENSSL}" s_client -connect "127.0.0.1:${PORT}" -tls1_3 -brief \
        "$@" ${TLS_CLIENT_EXTRA_ARGS} </dev/null >/dev/null 2>&1; then
      return 0
    fi
    i=$((i+1))
    sleep 0.1
  done
  echo "ERROR: TLS server not ready; tail server.log:" >&2
  tail -n 60 "${tmp}/server.log" 2>/dev/null >&2 || true
  return 1
}

client_once() {
  set -- $(cat "${tmp}/prov.args" 2>/dev/null || true) $(cat "${tmp}/grp.args" 2>/dev/null || true)
  # shellcheck disable=SC2086
  timeout "${ATTEMPT_TIMEOUT}s" \
    "${OPENSSL}" s_client -connect "127.0.0.1:${PORT}" -tls1_3 -brief \
    "$@" ${TLS_CLIENT_EXTRA_ARGS} </dev/null >/dev/null 2>&1
}

calc_stats() {
  # input: file with "i,ms,ok"
  f="$1"
  awk -F',' '
    $3==1 { vals[n++]=$2; sum+=$2; sumsq+=$2*$2; ok++ }
    $3!=1 { fail++ }
    END{
      if(ok==0){
        printf "0,%d,na,na,na,na,na\n", fail
        exit
      }
      # O(n^2) sort is fine for n<=200
      for(i=0;i<n;i++){
        for(j=i+1;j<n;j++){
          if(vals[j]<vals[i]){
            t=vals[i]; vals[i]=vals[j]; vals[j]=t
          }
        }
      }
      p50=vals[int((n-1)*0.50)]
      p95=vals[int((n-1)*0.95)]
      p99=vals[int((n-1)*0.99)]
      mean=sum/ok
      var=(sumsq/ok)-(mean*mean)
      if(var<0) var=0
      std=sqrt(var)
      printf "%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f\n", ok, fail, p50, p95, p99, mean, std
    }
  ' "$f"
}

# ----- main -----
build_provider_args
build_groups_args

make_cert
start_server
wait_server_ready

# warmup (not recorded)
w=1
while [ $w -le "${WARMUP}" ]; do
  client_once >/dev/null 2>&1 || true
  w=$((w+1))
done

r=1
while [ $r -le "${REPEATS}" ]; do
  rawfile="${rawdir}/rep${r}.txt"
  echo "[INFO] rep=${r}/${REPEATS}"
  : > "${rawfile}"

  i=1
  while [ $i -le "${N}" ]; do
    t0="$(date +%s%N)"
    if client_once; then rc=0; else rc=$?; fi
    t1="$(date +%s%N)"
    ms="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f",(b-a)/1000000.0}')"
    ok=0
    [ "${rc}" -eq 0 ] && ok=1

    echo "${i},${ms},${ok}" >> "${rawfile}"
    echo "${r},${MODE},${N},${ATTEMPT_TIMEOUT},${i},${ms},${ok}" >> "${samples_csv}"

    i=$((i+1))
  done

  stats="$(calc_stats "${rawfile}")"
  ok="$(echo "${stats}" | awk -F',' '{print $1}')"
  fail="$(echo "${stats}" | awk -F',' '{print $2}')"
  p50="$(echo "${stats}" | awk -F',' '{print $3}')"
  p95="$(echo "${stats}" | awk -F',' '{print $4}')"
  p99="$(echo "${stats}" | awk -F',' '{print $5}')"
  mean="$(echo "${stats}" | awk -F',' '{print $6}')"
  std="$(echo "${stats}" | awk -F',' '{print $7}')"

  echo "${r},${MODE},${N},${ATTEMPT_TIMEOUT},${ok},${fail},${p50},${p95},${p99},${mean},${std}" >> "${summary_csv}"
  r=$((r+1))
done

echo "${summary_csv}"
