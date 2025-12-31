#!/usr/bin/env bash
set -euo pipefail

ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
info(){ echo "[INFO] $(ts) $*"; }
die(){  echo "[ERROR] $(ts) $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

need docker
need python3

IMG="${IMG:?IMG is required (digest recommended)}"
MODE="${MODE:-paper}"
RESULTS_DIR="${RESULTS_DIR:-results}"

if [ -z "${RUN_ID:-}" ]; then
  TS_ID="$(date -u +'%Y%m%dT%H%M%SZ')"
  SHA="$(git rev-parse --short HEAD 2>/dev/null || true)"
  if [ -n "${SHA}" ]; then RUN_ID="${TS_ID}_${SHA}"; else RUN_ID="${TS_ID}"; fi
fi

RUN_DIR="${RUN_DIR:-${RESULTS_DIR}/${RUN_ID}}"
mkdir -p "${RUN_DIR}"

RUN_DIR_ABS="$(RUN_DIR="${RUN_DIR}" python3 - <<'PY'
import os
print(os.path.abspath(os.environ["RUN_DIR"]))
PY
)"

info "MODE=${MODE}"
info "IMG=${IMG}"
info "RUN_ID=${RUN_ID}"
info "RUN_DIR=${RUN_DIR}"
info "RUN_DIR_ABS=${RUN_DIR_ABS}"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
TIMESEC="${TIMESEC:-15}"
N="${N:-200}"
ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-3}"
BENCH_SECONDS="${BENCH_SECONDS:-15}"
STRICT="${STRICT:-1}"

TLS_PROVIDERS="${TLS_PROVIDERS:-default}"
TLS_GROUPS="${TLS_GROUPS:-X25519}"
TLS_CERT_KEYALG="${TLS_CERT_KEYALG:-ec_p256}"
TLS_SERVER_EXTRA_ARGS="${TLS_SERVER_EXTRA_ARGS:-}"
TLS_CLIENT_EXTRA_ARGS="${TLS_CLIENT_EXTRA_ARGS:-}"

SIGS="${SIGS:-ecdsap256,mldsa44,mldsa65,falcon512,falcon1024}"
MSG_BYTES="${MSG_BYTES:-32}"

for f in \
  scripts/core/env_info_core.sh \
  scripts/core/tls_throughput_core.sh \
  scripts/core/tls_latency_core.sh \
  scripts/core/sig_bench_core.sh \
  scripts/summarize_results.py
do
  [ -f "$f" ] || die "missing required file: $f"
done

chmod +x scripts/core/*.sh >/dev/null 2>&1 || true
chmod +x scripts/*.py >/dev/null 2>&1 || true

docker pull "${IMG}" >/dev/null 2>&1 || true

run_core_in_container() {
  label="$1"
  core="$2"
  info "== ${label} =="
  docker run --rm \
    -v "${RUN_DIR_ABS}:/out" \
    -v "$(pwd):/work" \
    -w /work \
    -e MODE="${MODE}" \
    -e REPEATS="${REPEATS}" \
    -e WARMUP="${WARMUP}" \
    -e TIMESEC="${TIMESEC}" \
    -e N="${N}" \
    -e ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT}" \
    -e BENCH_SECONDS="${BENCH_SECONDS}" \
    -e STRICT="${STRICT}" \
    -e TLS_PROVIDERS="${TLS_PROVIDERS}" \
    -e TLS_GROUPS="${TLS_GROUPS}" \
    -e TLS_CERT_KEYALG="${TLS_CERT_KEYALG}" \
    -e TLS_SERVER_EXTRA_ARGS="${TLS_SERVER_EXTRA_ARGS}" \
    -e TLS_CLIENT_EXTRA_ARGS="${TLS_CLIENT_EXTRA_ARGS}" \
    -e SIGS="${SIGS}" \
    -e MSG_BYTES="${MSG_BYTES}" \
    "${IMG}" sh -lc "set -eu; sh '${core}' /out"
}

run_core_in_container "env_info_core"       "scripts/core/env_info_core.sh"
run_core_in_container "tls_throughput_core" "scripts/core/tls_throughput_core.sh"
run_core_in_container "tls_latency_core"    "scripts/core/tls_latency_core.sh"
run_core_in_container "sig_bench_core"      "scripts/core/sig_bench_core.sh"

info "== host step: summarize_results.py =="
python3 scripts/summarize_results.py "${RUN_DIR}" |& tee "${RUN_DIR}/summarize.log"
