#!/usr/bin/env sh
set -eu

# POSIX-safe TLS throughput core
# Usage: tls_throughput_core.sh /out
# Env:
#   MODE, REPEATS, WARMUP, TIMESEC
#   TLS_PROVIDERS (comma-separated, default: default)
#   TLS_GROUPS (default: X25519)
#   TLS_CERT_KEYALG (default: ec_p256)
#   TLS_SERVER_EXTRA_ARGS, TLS_CLIENT_EXTRA_ARGS (optional, shell-style words; keep simple)

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

PORT="${PORT:-4433}"

# Pick openssl inside image
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
  # stop server if still running
  if [ -f "${tmp}/server.pid" ]; then
    pid="$(cat "${tmp}/server.pid" 2>/dev/null || true)"
    if [ -n "${pid}" ]; then
      kill "${pid}" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "${tmp}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

csv="${OUTDIR}/tls_throughput.csv"
echo "repeat,mode,timesec,providers,groups,cert_keyalg,connections,real_s,user_s,sys_s,conn_user_sec" > "${csv}"

# ----- helpers -----

# Trim leading/trailing spaces
trim() {
  # POSIX trim: use awk
  echo "$1" | awk '{$1=$1; print}'
}

# Build provider args file (one token per line) for safe expansion
# We avoid arrays entirely (POSIX).
build_provider_args() {
  : > "${tmp}/prov.args"
  # split by comma using awk
  echo "${TLS_PROVIDERS}" | awk -F',' '{
    for (i=1;i<=NF;i++){
      gsub(/^[ \t]+|[ \t]+$/,"",$i);
      if ($i!="") print "-provider\n" $i
    }
  }' >> "${tmp}/prov.args"
}

# Build groups arg file
build_groups_args() {
  : > "${tmp}/grp.args"
  if [ -n "${TLS_GROUPS}" ]; then
    printf "%s\n%s\n" "-groups" "${TLS_GROUPS}" >> "${tmp}/grp.args"
  fi
}

# Create cert+key
make_cert() {
  # shellcheck disable=SC2086
  if [ "${TLS_CERT_KEYALG}" = "ec_p256" ]; then
    # Read args from files into command line with xargs -0? not portable.
    # Use set -- with command substitution from file (safe because we control content).
    set -- $(cat "${tmp}/prov.args" 2>/dev/null || true)
    "${OPENSSL}" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "${tmp}/key.pem" -out "${tmp}/cert.pem" -subj "/CN=localhost" -days 1 \
      "$@" >/dev/null 2>&1
  else
    set -- $(cat "${tmp}/prov.args" 2>/dev/null || true)
    "${OPENSSL}" req -x509 -newkey "${TLS_CERT_KEYALG}" -nodes \
      -keyout "${tmp}/key.pem" -out "${tmp}/cert.pem" -subj "/CN=localhost" -days 1 \
      "$@" >/dev/null 2>&1
  fi
}

start_server() {
  # server args: providers + groups + extras
  set -- $(cat "${tmp}/prov.args" 2>/dev/null || true) $(cat "${tmp}/grp.args" 2>/dev/null || true)
  # TLS_SERVER_EXTRA_ARGS is best-effort; keep it simple words only
  # shellcheck disable=SC2086
  "${OPENSSL}" s_server -accept "${PORT}" -tls1_3 \
    -cert "${tmp}/cert.pem" -key "${tmp}/key.pem" \
    "$@" ${TLS_SERVER_EXTRA_ARGS} \
    -quiet >"${tmp}/server.log" 2>&1 &
  echo $! > "${tmp}/server.pid"
}

wait_server_ready() {
  # Probe with s_client until ready (max ~4s)
  i=1
  while [ $i -le 40 ]; do
    set -- $(cat "${tmp}/prov.args" 2>/dev/null || true) $(cat "${tmp}/grp.args" 2>/dev/null || true)
    # shellcheck disable=SC2086
    if "${OPENSSL}" s_client -connect "127.0.0.1:${PORT}" -tls1_3 -brief \
        "$@" ${TLS_CLIENT_EXTRA_ARGS} </dev/null >/dev/null 2>&1; then
      return 0
    fi
    i=$((i+1))
    # 0.1s
    sleep 0.1
  done
  echo "ERROR: TLS server not ready; tail server.log:" >&2
  tail -n 40 "${tmp}/server.log" 2>/dev/null >&2 || true
  return 1
}

stop_server() {
  if [ -f "${tmp}/server.pid" ]; then
    pid="$(cat "${tmp}/server.pid" 2>/dev/null || true)"
    if [ -n "${pid}" ]; then
      kill "${pid}" >/dev/null 2>&1 || true
    fi
  fi
}

run_stime() {
  # Run openssl s_time and parse robustly
  set -- $(cat "${tmp}/prov.args" 2>/dev/null || true) $(cat "${tmp}/grp.args" 2>/dev/null || true)

  # shellcheck disable=SC2086
  "${OPENSSL}" s_time -connect "127.0.0.1:${PORT}" -tls1_3 -time "${TIMESEC}" -new \
    "$@" ${TLS_CLIENT_EXTRA_ARGS} 2>&1 \
    | tee "${tmp}/stime.out" >/dev/null

  # Extract metrics (best-effort across formats)
  conns="$(grep -Eo 'connections[[:space:]]+[0-9]+' "${tmp}/stime.out" | tail -n 1 | awk '{print $2}' || true)"
  real_s="$(grep -E 'real[[:space:]]+[0-9.]+s' "${tmp}/stime.out" | tail -n 1 | awk '{print $2}' | sed 's/s$//' || true)"
  user_s="$(grep -E 'user[[:space:]]+[0-9.]+s' "${tmp}/stime.out" | tail -n 1 | awk '{print $2}' | sed 's/s$//' || true)"
  sys_s="$(grep -E 'sys[[:space:]]+[0-9.]+s' "${tmp}/stime.out" | tail -n 1 | awk '{print $2}' | sed 's/s$//' || true)"

  conns="${conns:-0}"
  real_s="${real_s:-0}"
  user_s="${user_s:-0}"
  sys_s="${sys_s:-0}"

  conn_user_sec="0"
  # compute c/u if u > 0
  if awk "BEGIN{exit !(${user_s} > 0)}"; then
    conn_user_sec="$(awk -v c="${conns}" -v u="${user_s}" 'BEGIN{printf "%.2f", c/u}')"
  fi

  echo "${conns},${real_s},${user_s},${sys_s},${conn_user_sec}"
}

# ----- main -----
build_provider_args
build_groups_args

make_cert
start_server
wait_server_ready

# warmup
i=1
while [ $i -le "${WARMUP}" ]; do
  run_stime >/dev/null 2>&1 || true
  i=$((i+1))
done

r=1
while [ $r -le "${REPEATS}" ]; do
  metrics="$(run_stime)"
  conns="$(echo "${metrics}" | awk -F',' '{print $1}')"
  real_s="$(echo "${metrics}" | awk -F',' '{print $2}')"
  user_s="$(echo "${metrics}" | awk -F',' '{print $3}')"
  sys_s="$(echo "${metrics}" | awk -F',' '{print $4}')"
  conn_user_sec="$(echo "${metrics}" | awk -F',' '{print $5}')"

  echo "${r},${MODE},${TIMESEC},${TLS_PROVIDERS},${TLS_GROUPS},${TLS_CERT_KEYALG},${conns},${real_s},${user_s},${sys_s},${conn_user_sec}" >> "${csv}"
  echo "[rep ${r}] connections=${conns} real_s=${real_s} user_s=${user_s} conn_user_sec=${conn_user_sec}"
  r=$((r+1))
done

stop_server
echo "${csv}"
