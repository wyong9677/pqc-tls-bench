#!/usr/bin/env sh
set -eu

# POSIX-safe TLS latency core (paper-grade stability)
# Usage: tls_latency_core.sh /out
# Env:
#   MODE, REPEATS, WARMUP, N, ATTEMPT_TIMEOUT, STRICT
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
STRICT="${STRICT:-1}"

TLS_PROVIDERS="${TLS_PROVIDERS:-default}"
TLS_GROUPS="${TLS_GROUPS:-X25519}"
TLS_CERT_KEYALG="${TLS_CERT_KEYALG:-ec_p256}"
TLS_SERVER_EXTRA_ARGS="${TLS_SERVER_EXTRA_ARGS:-}"
TLS_CLIENT_EXTRA_ARGS="${TLS_CLIENT_EXTRA_ARGS:-}"

PORT="${PORT:-4433}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date; }
info(){ echo "[INFO] $(ts) $*"; }
warn(){ echo "[WARN] $(ts) $*" >&2; }
die(){  echo "[ERROR] $(ts) $*" >&2; exit 1; }

OPENSSL="/opt/openssl/bin/openssl"
if [ ! -x "${OPENSSL}" ]; then
  OPENSSL="$(command -v openssl 2>/dev/null || true)"
fi
[ -n "${OPENSSL}" ] && [ -x "${OPENSSL}" ] || die "openssl not found"

# timeout may not exist in some minimal images
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"

# Use openssl's MODULESDIR when possible (important for oqsprovider stability)
MODULESDIR="$("${OPENSSL}" version -m 2>/dev/null | awk -F'"' '/MODULESDIR/{print $2; exit}' || true)"
if [ -z "${MODULESDIR}" ]; then
  MODULESDIR="/usr/local/lib/ossl-modules"
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

# ----- build args as newline-separated token files (no set -- $(cat ...) pitfalls) -----
build_provider_args() {
  : > "${tmp}/prov.args"
  # Always include provider-path for stability
  printf "%s\n%s\n" "-provider-path" "${MODULESDIR}" >> "${tmp}/prov.args"

  echo "${TLS_PROVIDERS}" | awk -F',' '{
    for (i=1;i<=NF;i++){
      gsub(/^[ \t]+|[ \t]+$/,"",$i);
      if ($i!="") { print "-provider"; print $i; }
    }
  }' >> "${tmp}/prov.args"
}

build_groups_args() {
  : > "${tmp}/grp.args"
  if [ -n "${TLS_GROUPS}" ]; then
    printf "%s\n%s\n" "-groups" "${TLS_GROUPS}" >> "${tmp}/grp.args"
  fi
}

# Convert newline token file -> "$@" safely (POSIX): read tokens into positional params
load_args_file() {
  f="$1"
  set --
  # shellcheck disable=SC2162
  while IFS= read line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    set -- "$@" "$line"
  done < "$f"
  echo "$#"
}

provider_sanity() {
  # default should be loadable; oqsprovider may not
  if ! "${OPENSSL}" list -providers -provider-path "${MODULESDIR}" -provider default >/dev/null 2>&1; then
    die "default provider cannot be loaded (MODULESDIR=${MODULESDIR})"
  fi
  if echo "${TLS_PROVIDERS}" | grep -qi "oqsprovider"; then
    if ! "${OPENSSL}" list -providers -provider-path "${MODULESDIR}" -provider oqsprovider -provider default >/dev/null 2>&1; then
      if [ "${STRICT}" = "1" ]; then
        die "oqsprovider requested but cannot be loaded (MODULESDIR=${MODULESDIR})"
      else
        warn "oqsprovider requested but cannot be loaded; continuing because STRICT=0"
      fi
    fi
  fi
}

make_cert() {
  # build args
  load_args_file "${tmp}/prov.args" >/dev/null
  # now "$@" are provider args
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
  load_args_file "${tmp}/prov.args" >/dev/null
  provc="$#"
  # stash prov args
  prov_args="$*"

  load_args_file "${tmp}/grp.args" >/dev/null
  grp_args="$*"

  # shellcheck disable=SC2086
  sh -c '
    OPENSSL="$1"; PORT="$2"; CERT="$3"; KEY="$4"; PROV_ARGS="$5"; GRP_ARGS="$6"; EXTRA="$7"; LOG="$8";
    # Using eval only on trusted token strings we constructed (prov/grp); EXTRA is "simple tokens" by contract.
    eval set -- $PROV_ARGS $GRP_ARGS
    "$OPENSSL" s_server -accept "$PORT" -tls1_3 -cert "$CERT" -key "$KEY" "$@" $EXTRA -quiet >"$LOG" 2>&1 &
    echo $! 
  ' sh "${OPENSSL}" "${PORT}" "${tmp}/cert.pem" "${tmp}/key.pem" "${prov_args}" "${grp_args}" "${TLS_SERVER_EXTRA_ARGS}" "${tmp}/server.log" \
    > "${tmp}/server.pid"
}

wait_server_ready() {
  i=1
  while [ $i -le 40 ]; do
    if client_once_no_timeout >/dev/null 2>&1; then
      return 0
    fi
    i=$((i+1))
    sleep 0.1
  done
  warn "TLS server not ready; tail server.log:"
  tail -n 80 "${tmp}/server.log" 2>/dev/null >&2 || true
  return 1
}

client_once_no_timeout() {
  load_args_file "${tmp}/prov.args" >/dev/null
  prov_args="$*"
  load_args_file "${tmp}/grp.args" >/dev/null
  grp_args="$*"

  # shellcheck disable=SC2086
  sh -c '
    OPENSSL="$1"; PORT="$2"; PROV_ARGS="$3"; GRP_ARGS="$4"; EXTRA="$5";
    eval set -- $PROV_ARGS $GRP_ARGS
    "$OPENSSL" s_client -connect "127.0.0.1:$PORT" -tls1_3 -brief "$@" $EXTRA </dev/null >/dev/null 2>&1
  ' sh "${OPENSSL}" "${PORT}" "${prov_args}" "${grp_args}" "${TLS_CLIENT_EXTRA_ARGS}"
}

client_once() {
  if [ -n "${TIMEOUT_BIN}" ]; then
    "${TIMEOUT_BIN}" "${ATTEMPT_TIMEOUT}s" sh -c '
      exec "$1" "$2"
    ' sh sh -c "client_once_no_timeout" >/dev/null 2>&1
  fi
  # If timeout not available, best-effort run without hard timeout
  client_once_no_timeout
}

# Prefer portable timestamp: if %N not supported, fall back to seconds and compute ms coarsely
have_ns=1
t_test="$(date +%s%N 2>/dev/null || true)"
case "${t_test}" in
  *N*|"") have_ns=0 ;;
esac

elapsed_ms() {
  a="$1"; b="$2"
  awk -v a="$a" -v b="$b" 'BEGIN{printf "%.4f",(b-a)/1000000.0}'
}

calc_stats() {
  f="$1"
  awk -F',' '
    $3==1 { vals[n++]=$2; sum+=$2; sumsq+=$2*$2; ok++ }
    $3!=1 { fail++ }
    END{
      if(ok==0){
        printf "0,%d,nan,nan,nan,nan,nan\n", fail
        exit
      }
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
info "TLS latency core: mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} N=${N} timeout=${ATTEMPT_TIMEOUT}s STRICT=${STRICT}"
info "OPENSSL=${OPENSSL} MODULESDIR=${MODULESDIR} providers=${TLS_PROVIDERS} groups=${TLS_GROUPS} cert_keyalg=${TLS_CERT_KEYALG}"

build_provider_args
build_groups_args
provider_sanity

make_cert
start_server
wait_server_ready || die "server not ready"

# warmup (not recorded)
w=1
while [ $w -le "${WARMUP}" ]; do
  client_once >/dev/null 2>&1 || true
  w=$((w+1))
done

r=1
while [ $r -le "${REPEATS}" ]; do
  rawfile="${rawdir}/rep${r}.txt"
  info "rep=${r}/${REPEATS}"
  : > "${rawfile}"

  i=1
  while [ $i -le "${N}" ]; do
    if [ "${have_ns}" = "1" ]; then
      t0="$(date +%s%N)"
    else
      t0="$(date +%s)"
    fi

    if client_once; then rc=0; else rc=$?; fi

    if [ "${have_ns}" = "1" ]; then
      t1="$(date +%s%N)"
      ms="$(elapsed_ms "$t0" "$t1")"
    else
      t1="$(date +%s)"
      # coarse fallback: seconds -> ms
      ms="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f",(b-a)*1000.0}')"
    fi

    ok=0
    [ "${rc}" -eq 0 ] && ok=1

    echo "${i},${ms},${ok}" >> "${rawfile}"
    echo "${r},${MODE},${N},${ATTEMPT_TIMEOUT},${i},${ms},${ok}" >> "${samples_csv}"

    i=$((i+1))
  done

  stats="$(calc_stats "${rawfile}")"
  ok="$(echo "${stats}"   | awk -F',' '{print $1}')"
  fail="$(echo "${stats}" | awk -F',' '{print $2}')"
  p50="$(echo "${stats}"  | awk -F',' '{print $3}')"
  p95="$(echo "${stats}"  | awk -F',' '{print $4}')"
  p99="$(echo "${stats}"  | awk -F',' '{print $5}')"
  mean="$(echo "${stats}" | awk -F',' '{print $6}')"
  std="$(echo "${stats}"  | awk -F',' '{print $7}')"

  if [ "${STRICT}" = "1" ] && [ "${ok}" = "0" ]; then
    die "rep=${r} all attempts failed (ok=0). Check providers/groups/cert_keyalg and server.log."
  fi

  echo "${r},${MODE},${N},${ATTEMPT_TIMEOUT},${ok},${fail},${p50},${p95},${p99},${mean},${std}" >> "${summary_csv}"
  r=$((r+1))
done

echo "${summary_csv}"
