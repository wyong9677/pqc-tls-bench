#!/usr/bin/env bash
set -euo pipefail

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

OPENSSL="/opt/openssl/bin/openssl"
if [ ! -x "${OPENSSL}" ]; then OPENSSL="$(command -v openssl)"; fi

providers_args=()
IFS=',' read -r -a _p <<< "${TLS_PROVIDERS}"
for p in "${_p[@]}"; do
  p="$(echo "$p" | xargs)"
  [ -n "$p" ] && providers_args+=(-provider "$p")
done

samples_csv="${OUTDIR}/tls_latency_samples.csv"
summary_csv="${OUTDIR}/tls_latency_summary.csv"
rawdir="${OUTDIR}/tls_latency_raw"
mkdir -p "${rawdir}"

echo "repeat,mode,n,timeout_s,sample_idx,lat_ms,ok" > "${samples_csv}"
echo "repeat,mode,n,timeout_s,ok,fail,p50_ms,p95_ms,p99_ms,mean_ms,std_ms" > "${summary_csv}"

PORT=4433
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

make_cert() {
  if [ "${TLS_CERT_KEYALG}" = "ec_p256" ]; then
    "${OPENSSL}" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "${tmp}/key.pem" -out "${tmp}/cert.pem" -subj "/CN=localhost" -days 1 \
      "${providers_args[@]}" >/dev/null 2>&1
  else
    "${OPENSSL}" req -x509 -newkey "${TLS_CERT_KEYALG}" -nodes \
      -keyout "${tmp}/key.pem" -out "${tmp}/cert.pem" -subj "/CN=localhost" -days 1 \
      "${providers_args[@]}" >/dev/null 2>&1
  fi
}

start_server() {
  local groups_arg=()
  [ -n "${TLS_GROUPS}" ] && groups_arg=(-groups "${TLS_GROUPS}")
  "${OPENSSL}" s_server -accept "${PORT}" -tls1_3 \
    -cert "${tmp}/cert.pem" -key "${tmp}/key.pem" \
    "${providers_args[@]}" "${groups_arg[@]}" ${TLS_SERVER_EXTRA_ARGS} \
    -quiet >"${tmp}/server.log" 2>&1 &
  echo $! > "${tmp}/server.pid"
}

stop_server() {
  if [ -f "${tmp}/server.pid" ]; then
    kill "$(cat "${tmp}/server.pid")" >/dev/null 2>&1 || true
  fi
}

client_once() {
  local groups_arg=()
  [ -n "${TLS_GROUPS}" ] && groups_arg=(-groups "${TLS_GROUPS}")
  timeout "${ATTEMPT_TIMEOUT}s" \
    "${OPENSSL}" s_client -connect "127.0.0.1:${PORT}" -tls1_3 -brief \
    "${providers_args[@]}" "${groups_arg[@]}" ${TLS_CLIENT_EXTRA_ARGS} \
    </dev/null >/dev/null 2>&1
}

calc_stats() {
  # input: file with "i,ms,ok"
  local f="$1"
  awk -F',' '
    $3==1 { vals[n++]=$2; sum+=$2; sumsq+=$2*$2; ok++ }
    $3!=1 { fail++ }
    END{
      if(ok==0){
        printf "0,%d,na,na,na,na,na\n", fail
        exit
      }
      # sort vals (simple)
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

make_cert
start_server
sleep 0.3

# warmup
for _ in $(seq 1 "${WARMUP}"); do
  client_once || true
done

for r in $(seq 1 "${REPEATS}"); do
  rawfile="${rawdir}/rep${r}.txt"
  echo "[INFO] rep=${r}/${REPEATS}"
  : > "${rawfile}"

  for i in $(seq 1 "${N}"); do
    t0="$(date +%s%N)"
    if client_once; then rc=0; else rc=$?; fi
    t1="$(date +%s%N)"
    ms="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f",(b-a)/1000000.0}')"
    ok=0; [ "${rc}" -eq 0 ] && ok=1
    echo "${i},${ms},${ok}" >> "${rawfile}"
    echo "${r},${MODE},${N},${ATTEMPT_TIMEOUT},${i},${ms},${ok}" >> "${samples_csv}"
  done

  stats="$(calc_stats "${rawfile}")"
  IFS=',' read -r ok fail p50 p95 p99 mean std <<< "${stats}"
  echo "${r},${MODE},${N},${ATTEMPT_TIMEOUT},${ok},${fail},${p50},${p95},${p99},${mean},${std}" >> "${summary_csv}"
done

stop_server
echo "${summary_csv}"
