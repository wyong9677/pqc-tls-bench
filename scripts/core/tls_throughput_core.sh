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

OPENSSL="/opt/openssl/bin/openssl"
if [ ! -x "${OPENSSL}" ]; then
  OPENSSL="$(command -v openssl 2>/dev/null || true)"
fi
[ -n "${OPENSSL}" ] && [ -x "${OPENSSL}" ] || die "openssl not found"

MODULESDIR="$("${OPENSSL}" version -m 2>/dev/null | awk -F'"' '/MODULESDIR/{print $2; exit}' || true)"
[ -n "${MODULESDIR}" ] || MODULESDIR="/usr/local/lib/ossl-modules"

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t tlsbench)"
cleanup() {
  if [ -f "${tmp}/server.pid" ]; then
    pid="$(cat "${tmp}/server.pid" 2>/dev/null || true)"
    [ -n "${pid}" ] && kill "${pid}" >/dev/null 2>&1 || true
  fi
  rm -rf "${tmp}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

csv="${OUTDIR}/tls_throughput.csv"
echo "repeat,mode,timesec,providers,groups,cert_keyalg,connections,real_s,user_s,sys_s,conn_user_sec" > "${csv}"

build_provider_args() {
  : > "${tmp}/prov.args"
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

append_args_file() {
  f="$1"
  while IFS= read line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    set -- "$@" "$line"
  done < "$f"
}

provider_sanity() {
  if ! "${OPENSSL}" list -providers -provider-path "${MODULESDIR}" -provider default >/dev/null 2>&1; then
    die "default provider cannot be loaded (MODULESDIR=${MODULESDIR})"
  fi
  if echo "${TLS_PROVIDERS}" | grep -qi "oqsprovider"; then
    if ! "${OPENSSL}" list -providers -provider-path "${MODULESDIR}" -provider oqsprovider -provider default >/dev/null 2>&1; then
      [ "${STRICT}" = "1" ] && die "oqsprovider requested but cannot be loaded (MODULESDIR=${MODULESDIR})"
      warn "oqsprovider requested but cannot be loaded; continuing because STRICT=0"
    fi
  fi
}

make_cert() {
  set --
  append_args_file "${tmp}/prov.args"
  if [ "${TLS_CERT_KEYALG}" = "ec_p256" ]; then
    "${OPENSSL}" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "${tmp}/key.pem" -out "${tmp}/cert.pem" -subj "/CN=localhost" -days 1 \
      "$@" >/dev/null 2>&1 || die "cert generation failed (ec_p256)"
  else
    "${OPENSSL}" req -x509 -newkey "${TLS_CERT_KEYALG}" -nodes \
      -keyout "${tmp}/key.pem" -out "${tmp}/cert.pem" -subj "/CN=localhost" -days 1 \
      "$@" >/dev/null 2>&1 || die "cert generation failed (alg=${TLS_CERT_KEYALG})"
  fi
}

start_server() {
  set --
  append_args_file "${tmp}/prov.args"
  append_args_file "${tmp}/grp.args"
  # bind explicitly to IPv4 loopback for stability
  # shellcheck disable=SC2086
  "${OPENSSL}" s_server -accept "127.0.0.1:${PORT}" -tls1_3 \
    -cert "${tmp}/cert.pem" -key "${tmp}/key.pem" \
    "$@" ${TLS_SERVER_EXTRA_ARGS} \
    -quiet >"${tmp}/server.log" 2>&1 &
  echo $! > "${tmp}/server.pid"
}

wait_server_ready() {
  # require multiple consecutive successes
  need_ok=3
  ok=0
  i=1
  while [ $i -le 60 ]; do
    set --
    append_args_file "${tmp}/prov.args"
    append_args_file "${tmp}/grp.args"
    # shellcheck disable=SC2086
    if "${OPENSSL}" s_client -connect "127.0.0.1:${PORT}" -tls1_3 -brief \
        "$@" ${TLS_CLIENT_EXTRA_ARGS} </dev/null >/dev/null 2>&1; then
      ok=$((ok+1))
      [ "${ok}" -ge "${need_ok}" ] && return 0
    else
      ok=0
    fi
    i=$((i+1))
    sleep 0.1
  done
  warn "TLS server not ready; tail server.log:"
  tail -n 120 "${tmp}/server.log" 2>/dev/null >&2 || true
  return 1
}

dump_diagnostics() {
  warn "==== BEGIN stime.out (first 200 lines) ===="
  sed -n '1,200p' "${tmp}/stime.out" 2>/dev/null >&2 || true
  warn "==== END stime.out ===="
  warn "==== BEGIN server.log (last 120 lines) ===="
  tail -n 120 "${tmp}/server.log" 2>/dev/null >&2 || true
  warn "==== END server.log ===="
}

run_stime() {
  set --
  append_args_file "${tmp}/prov.args"
  append_args_file "${tmp}/grp.args"

  rc=0
  # IMPORTANT: no pipe; keep real exit code
  # shellcheck disable=SC2086
  "${OPENSSL}" s_time -connect "127.0.0.1:${PORT}" -tls1_3 -time "${TIMESEC}" -new \
    "$@" ${TLS_CLIENT_EXTRA_ARGS} >"${tmp}/stime.out" 2>&1 || rc=$?

  # parse
  conn_user_sec="$(awk 'match($0,/([0-9.]+)[[:space:]]+connections\/user[[:space:]]+sec/,m){print m[1]; exit}' "${tmp}/stime.out" 2>/dev/null || true)"
  conns="$(awk 'match($0,/^([0-9]+)[[:space:]]+connections[[:space:]]+in[[:space:]]+[0-9.]+s;/,m){print m[1]; exit}' "${tmp}/stime.out" 2>/dev/null || true)"
  real_s="$(awk 'match($0,/real[[:space:]]+([0-9.]+)s/,m){x=m[1]} END{if(x!="") print x}' "${tmp}/stime.out" 2>/dev/null || true)"
  user_s="$(awk 'match($0,/user[[:space:]]+([0-9.]+)s/,m){x=m[1]} END{if(x!="") print x}' "${tmp}/stime.out" 2>/dev/null || true)"
  sys_s="$(awk  'match($0,/sys[[:space:]]+([0-9.]+)s/,m){x=m[1]} END{if(x!="") print x}'  "${tmp}/stime.out" 2>/dev/null || true)"

  [ -n "${real_s}" ] || real_s="$(awk 'match($0,/connections[[:space:]]+in[[:space:]]+([0-9.]+)s;/,m){print m[1]; exit}' "${tmp}/stime.out" 2>/dev/null || true)"
  [ -n "${user_s}" ] || user_s="${real_s:-0}"
  [ -n "${sys_s}"  ] || sys_s="0"

  conns="${conns:-0}"
  real_s="${real_s:-0}"
  user_s="${user_s:-0}"

  if [ -z "${conn_user_sec}" ]; then
    conn_user_sec="nan"
    if awk "BEGIN{exit !(${user_s} > 0)}"; then
      conn_user_sec="$(awk -v c="${conns}" -v u="${user_s}" 'BEGIN{printf "%.2f", c/u}')"
    fi
  fi

  # FAIL-FAST for paper-grade
  if [ "${STRICT}" = "1" ]; then
    # any non-zero rc, or 0 connections, is a hard failure
    if [ "${rc}" -ne 0 ] || [ "${conns}" -eq 0 ] || [ "${conn_user_sec}" = "nan" ]; then
      warn "s_time failed or produced zero connections (rc=${rc}, conns=${conns}, conn_user_sec=${conn_user_sec})"
      dump_diagnostics
      exit 1
    fi
  fi

  echo "${conns},${real_s},${user_s},${sys_s},${conn_user_sec}"
}

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

echo "${csv}"
