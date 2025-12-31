#!/usr/bin/env bash
set -euo pipefail

# Unified CI entrypoint (FINAL, FIXED)

ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
info(){ echo "[INFO] $(ts) $*"; }
die(){  echo "[ERROR] $(ts) $*" >&2; exit 1; }

command -v docker  >/dev/null 2>&1 || die "missing docker"
command -v python3 >/dev/null 2>&1 || die "missing python3"

IMG="${IMG:?IMG required}"
MODE="${MODE:-paper}"
RESULTS_DIR="${RESULTS_DIR:-results}"

# RUN_ID
if [ -z "${RUN_ID:-}" ]; then
  TS="$(date -u +'%Y%m%dT%H%M%SZ')"
  SHA="$(git rev-parse --short HEAD 2>/dev/null || true)"
  RUN_ID="${SHA:+${TS}_${SHA}}"
  RUN_ID="${RUN_ID:-${TS}}"
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

# defaults
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

# sanity
for f in \
  scripts/core/env_info_core.sh \
  scripts/core/tls_throughput_core.sh \
  scripts/core/tls_latency_core.sh \
  scripts/core/sig_bench_core.sh \
  scripts/summarize_results.py
do
  [ -f "$f" ] || die "missing file: $f"
done

chmod +x scripts/core/*.sh scripts/*.py >/dev/null 2>&1 || true
docker pull "${IMG}" >/dev/null 2>&1 || true

run_core_sh() {
  local label="$1" core="$2"
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
    -e STRICT="${STRICT}" \
    -e TLS_PROVIDERS="${TLS_PROVIDERS}" \
    -e TLS_GROUPS="${TLS_GROUPS}" \
    -e TLS_CERT_KEYALG="${TLS_CERT_KEYALG}" \
    -e TLS_SERVER_EXTRA_ARGS="${TLS_SERVER_EXTRA_ARGS}" \
    -e TLS_CLIENT_EXTRA_ARGS="${TLS_CLIENT_EXTRA_ARGS}" \
    "${IMG}" sh -lc "set -eu; sh '${core}' /out"
}

run_core_bash() {
  local label="$1" core="$2"
  info "== ${label} =="
  docker run --rm \
    -v "${RUN_DIR_ABS}:/out" \
    -v "$(pwd):/work" \
    -w /work \
    -e MODE="${MODE}" \
    -e REPEATS="${REPEATS}" \
    -e WARMUP="${WARMUP}" \
    -e BENCH_SECONDS="${BENCH_SECONDS}" \
    -e STRICT="${STRICT}" \
    -e SIGS="${SIGS}" \
    -e MSG_BYTES="${MSG_BYTES}" \
    "${IMG}" bash -lc "set -euo pipefail; '${core}' /out"
}

run_core_sh   "env_info_core"        "scripts/core/env_info_core.sh"
run_core_sh   "tls_throughput_core"  "scripts/core/tls_throughput_core.sh"
run_core_sh   "tls_latency_core"     "scripts/core/tls_latency_core.sh"
run_core_bash "sig_bench_core"       "scripts/core/sig_bench_core.sh"

info "== summarize_results =="
python3 scripts/summarize_results.py "${RUN_DIR}" |& tee "${RUN_DIR}/summarize.log"

info "DONE"
ls -la "${RUN_DIR}" || true
