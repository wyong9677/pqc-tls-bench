#!/usr/bin/env sh
set -eu

# POSIX-safe TLS throughput core (paper-grade stability)
# Usage: tls_throughput_core.sh /out
# Env:
#   MODE, REPEATS, WARMUP, TIMESEC, STRICT
#   TLS_PROVIDERS (comma-separated, default: default)
#   TLS_GROUPS (default: X25519)
#   TLS_CERT_KEYALG (default: ec_p256)
#   TLS_SERVER_EXTRA_ARGS, TLS_CLIENT_EXTRA_ARGS (optional; simple tokens only)
# Output:
#   tls_throughput.csv

OUTDIR="${1:?usage: tls_throughput_core.sh /out}"
mkdir -p "${OUTDIR}"

MODE="${MODE:-paper}"
REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
TIMESEC="${TIMESEC:-15}"
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

# Pick openssl inside image
OPENSSL="/opt/openssl/bin/openssl"
if [ ! -x "${OPENSSL}" ]; then
  OPENSSL="$(command -v openssl 2>/dev/null || true)"
fi
[ -n "${OPENSSL}" ] && [ -x "${OPENSSL}" ] || die "openssl not found"

# Use OpenSSL's MODULESDIR when possible (stabilizes oqsprovider loading)
MODULESDIR="$("${OPENSSL}" version -m 2>/dev/null | awk -F'"' '/MODULESDIR/{print $2; exit}' || true)"
if [ -z "${MODULESDIR}" ]; then
  MODULESDIR="/usr/local/lib/ossl-modules"
fi

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

csv="${OUTDIR}/tls_throughput.csv"
echo "repeat,mode,timesec,providers,groups,cert_keyalg,connections,real_s,user_s,sys_s,conn_user_sec" > "${csv}"

# ---------- args files (one token per line; avoids bash arrays / set -- $(cat ...)) ----------
build_provider_args() {
  : > "${tmp}/prov.args"
  # Always include provider-path (important for oqsprovider stability)
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

# Read token file -> append into current "$@" safely (POSIX)
append_args_file() {
  f="$1"
  # shellcheck disable=SC2162
  while IFS= read line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    set -- "$@" "$line"
  done < "$f"
}

provider_sanity() {
  # default must load
  if ! "${OPENSSL}" list -providers -provider-path "${MODULESDIR}" -provider default >/dev/null 2>&1; then
    die "default provider cannot be loaded (MODULESDIR=${MODULESDIR})"
  fi
  # if oqsprovider requested, it must load under STRICT=1
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
  set --
  append_args_file "${tmp}/prov.args"

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
  set --
  append_args_file "${tmp}/prov.args"
  append_args_file "${tmp}/grp.args"

  # TLS_SERVER_EXTRA_ARGS: best-effort simple tokens only
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
    set --
    append_args_file "${tmp}/prov.args"
    append_args_file "${tmp}/grp.args"
    # shellcheck disable=SC2086
    if "${OPENSSL}" s_client -connect "127.0.0.1:${PORT}" -tls1_3 -brief \
        "$@" ${TLS_CLIENT_EXTRA_ARGS} </dev/null >/dev/null 2>&1; then
      return 0
    fi
    i=$((i+1))
    sleep 0.1
  done
  warn "TLS server not ready; tail server.log:"
  tail -n 80 "${tmp}/server.log" 2>/dev/null >&2 || true
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
  set --
  append_args_file "${tmp}/prov.args"
  append_args_file "${tmp}/grp.args"

  # shellcheck disable=SC2086
  "${OPENSSL}" s_time -connect "127.0.0.1:${PORT}" -tls1_3 -time "${TIMESEC}" -new \
    "$@" ${TLS_CLIENT_EXTRA_ARGS} 2>&1 \
    | tee "${tmp}/stime.out" >/dev/null

  # Prefer direct "connections/user sec" if present
  conn_user_sec="$(awk '
    match($0,/([0-9.]+)[[:space:]]+connections\/user[[:space:]]+sec/,m){print m[1]; exit}
  ' "${tmp}/stime.out" 2>/dev/null || true)"

  # Common OpenSSL line: "123 connections in 0.34s; ..."
  conns="$(awk '
    match($0,/^([0-9]+)[[:space:]]+connections[[:space:]]+in[[:space:]]+[0-9.]+s;/,m){print m[1]; exit}
  ' "${tmp}/stime.out" 2>/dev/null || true)"

  # If time-like lines exist: "real 1.23s" "user 0.45s" "sys 0.12s"
  real_s="$(awk 'match($0,/real[[:space:]]+([0-9.]+)s/,m){x=m[1]} END{if(x!="") print x}' "${tmp}/stime.out" 2>/dev/null || true)"
  user_s="$(awk 'match($0,/user[[:space:]]+([0-9.]+)s/,m){x=m[1]} END{if(x!="") print x}' "${tmp}/stime.out" 2>/dev/null || true)"
  sys_s="$(awk  'match($0,/sys[[:space:]]+([0-9.]+)s/,m){x=m[1]} END{if(x!="") print x}'  "${tmp}/stime.out" 2>/dev/null || true)"

  # If no real/user/sys present, fall back to "connections in Xs" as real_s/user_s proxy
  if [ -z "${real_s}" ]; then
    real_s="$(awk 'match($0,/connections[[:space:]]+in[[:space:]]+([0-9.]+)s;/,m){print m[1]; exit}' "${tmp}/stime.out" 2>/dev/null || true)"
  fi
  if [ -z "${user_s}" ]; then
    # not ideal, but better than empty for downstream; keep sys as 0
    user_s="${real_s:-0}"
  fi
  if [ -z "${sys_s}" ]; then
    sys_s="0"
  fi

  conns="${conns:-0}"
  real_s="${real_s:-0}"
  user_s="${user_s:-0}"

  # If conn_user_sec missing, compute from conns/user_s where possible
  if [ -z "${conn_user_sec}" ]; then
    conn_user_sec="nan"
    if awk "BEGIN{exit !(${user_s} > 0)}"; then
      conn_user_sec="$(awk -v c="${conns}" -v u="${user_s}" 'BEGIN{printf "%.2f", c/u}')"
    fi
  fi

  echo "${conns},${real_s},${user_s},${sys_s},${conn_user_sec}"
}

# ---------- main ----------
info "TLS throughput core: mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} time=${TIMESEC}s STRICT=${STRICT}"
info "OPENSSL=${OPENSSL} MODULESDIR=${MODULESDIR} providers=${TLS_PROVIDERS} groups=${TLS_GROUPS} cert_keyalg=${TLS_CERT_KEYALG}"

build_provider_args
build_groups_args
provider_sanity

make_cert
start_server
wait_server_ready || die "server not ready"

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
  info "rep=${r}/${REPEATS} connections=${conns} conn_user_sec=${conn_user_sec}"
  r=$((r+1))
done

stop_server
echo "${csv}"
