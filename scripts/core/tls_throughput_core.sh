#!/usr/bin/env bash
set -euo pipefail

OUTDIR="${1:?usage: tls_throughput_core.sh /out}"
mkdir -p "${OUTDIR}"

MODE="${MODE:-paper}"
REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
TIMESEC="${TIMESEC:-15}"

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

csv="${OUTDIR}/tls_throughput.csv"
echo "repeat,mode,timesec,providers,groups,cert_keyalg,connections,real_s,user_s,sys_s,conn_user_sec" > "${csv}"

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

run_stime() {
  local groups_arg=()
  [ -n "${TLS_GROUPS}" ] && groups_arg=(-groups "${TLS_GROUPS}")

  # openssl s_time output varies; we extract: connections, real/user/sys seconds
  "${OPENSSL}" s_time -connect "127.0.0.1:${PORT}" -tls1_3 -time "${TIMESEC}" \
    -new \
    "${providers_args[@]}" "${groups_arg[@]}" ${TLS_CLIENT_EXTRA_ARGS} 2>&1 \
    | tee "${tmp}/stime.out" >/dev/null

  # robust extraction
  local conns real_s user_s sys_s
  conns="$(grep -Eo 'connections +[0-9]+' "${tmp}/stime.out" | tail -n1 | awk '{print $2}')"
  real_s="$(grep -E 'real +[0-9.]+s' "${tmp}/stime.out" | tail -n1 | awk '{print $2}' | sed 's/s//')"
  user_s="$(grep -E 'user +[0-9.]+s' "${tmp}/stime.out" | tail -n1 | awk '{print $2}' | sed 's/s//')"
  sys_s="$(grep -E 'sys +[0-9.]+s' "${tmp}/stime.out" | tail -n1 | awk '{print $2}' | sed 's/s//')"

  # fallback if format differs
  conns="${conns:-0}"
  real_s="${real_s:-0}"
  user_s="${user_s:-0}"
  sys_s="${sys_s:-0}"

  # conn_user_sec
  conn_user_sec="0"
  if awk "BEGIN{exit !(${user_s}>0)}"; then
    conn_user_sec="$(awk -v c="${conns}" -v u="${user_s}" 'BEGIN{printf "%.2f", c/u}')"
  fi

  echo "${conns},${real_s},${user_s},${sys_s},${conn_user_sec}"
}

# main
make_cert
start_server
sleep 0.3

# warmup
for _ in $(seq 1 "${WARMUP}"); do
  run_stime >/dev/null
done

for r in $(seq 1 "${REPEATS}"); do
  metrics="$(run_stime)"
  IFS=',' read -r conns real_s user_s sys_s conn_user_sec <<< "${metrics}"
  echo "${r},${MODE},${TIMESEC},${TLS_PROVIDERS},${TLS_GROUPS},${TLS_CERT_KEYALG},${conns},${real_s},${user_s},${sys_s},${conn_user_sec}" >> "${csv}"
  echo "[rep ${r}] connections=${conns} real_s=${real_s} user_s=${user_s} conn_user_sec=${conn_user_sec}"
done

stop_server
echo "${csv}"
