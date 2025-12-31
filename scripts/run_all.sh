#!/usr/bin/env bash
set -euo pipefail

MODE="${MODE:-paper}"
IMG="${IMG:?IMG is required (e.g. openquantumsafe/oqs-ossl3:latest or ...@sha256:...)}"
RESULTS_DIR="${RESULTS_DIR:-results}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] missing command: $1" >&2; exit 127; }; }
need docker
need python3

TS="$(date -u +'%Y%m%dT%H%M%SZ')"
SHA="$(git rev-parse --short HEAD 2>/dev/null || true)"
RUN_ID="${TS}${SHA:+_${SHA}}"
RUN_DIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "${RUN_DIR}"

# IMPORTANT: absolute paths for docker bind mounts (Actions runner needs this)
WORK_ABS="$(pwd)"
RUN_DIR_ABS="$(cd "${RUN_DIR}" && pwd)"

# knobs
if [ "${MODE}" = "smoke" ]; then
  REPEATS="${REPEATS:-1}"
  WARMUP="${WARMUP:-1}"
  TIMESEC="${TIMESEC:-5}"
  N="${N:-50}"
  ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-2}"
  BENCH_SECONDS="${BENCH_SECONDS:-5}"
  STRICT="${STRICT:-0}"
else
  REPEATS="${REPEATS:-5}"
  WARMUP="${WARMUP:-2}"
  TIMESEC="${TIMESEC:-15}"
  N="${N:-200}"
  ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-3}"
  BENCH_SECONDS="${BENCH_SECONDS:-15}"
  STRICT="${STRICT:-1}"
fi

echo "[INFO] MODE=${MODE}"
echo "[INFO] IMG=${IMG}"
echo "[INFO] RUN_DIR=${RUN_DIR}"
echo "[INFO] RUN_DIR_ABS=${RUN_DIR_ABS}"

# meta.json config (host-side)
CONFIG_JSON="$(python3 - <<PY
import json
cfg = {
  "mode": "${MODE}",
  "repeats": int("${REPEATS}"),
  "warmup": int("${WARMUP}"),
  "timesec": float("${TIMESEC}"),
  "n": int("${N}"),
  "attempt_timeout": float("${ATTEMPT_TIMEOUT}"),
  "bench_seconds": float("${BENCH_SECONDS}"),
  "strict": int("${STRICT}"),
}
print(json.dumps(cfg, sort_keys=True))
PY
)"

python3 scripts/write_meta.py \
  --outdir "${RUN_DIR_ABS}" \
  --mode "${MODE}" \
  --img "${IMG}" \
  --git_sha "${SHA:-}" \
  --config_json "${CONFIG_JSON}"

echo "${RUN_DIR}/meta.json"

# Common docker invocation:
# - /work is repo (read-only)
# - /out is results dir (bind-mounted ABSOLUTE)
DOCKER_COMMON=(
  docker run --rm
  -v "${WORK_ABS}:/work:ro" -w /work
  -v "${RUN_DIR_ABS}:/out"
  -e MODE="${MODE}"
  -e REPEATS="${REPEATS}"
  -e WARMUP="${WARMUP}"
  -e TIMESEC="${TIMESEC}"
  -e N="${N}"
  -e ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT}"
  -e BENCH_SECONDS="${BENCH_SECONDS}"
  -e STRICT="${STRICT}"
  "${IMG}" sh
)

# env info
"${DOCKER_COMMON[@]}" /work/scripts/core/env_info_core.sh /out |& tee "${RUN_DIR}/env_info.log"

# TLS throughput / latency（如果你 core 脚本已存在就打开；不存在就先注释）
if [ -f "scripts/core/tls_throughput_core.sh" ]; then
  "${DOCKER_COMMON[@]}" /work/scripts/core/tls_throughput_core.sh /out |& tee "${RUN_DIR}/tls_throughput.log"
fi
if [ -f "scripts/core/tls_latency_core.sh" ]; then
  "${DOCKER_COMMON[@]}" /work/scripts/core/tls_latency_core.sh /out |& tee "${RUN_DIR}/tls_latency.log"
fi

# signature bench
"${DOCKER_COMMON[@]}" /work/scripts/core/sig_bench_core.sh /out |& tee "${RUN_DIR}/sig_bench.log"

# host-side summarize (optional, if you want)
if [ -f "scripts/summarize_results.py" ]; then
  python3 scripts/summarize_results.py "${RUN_DIR}" |& tee "${RUN_DIR}/summarize.log" || true
fi

echo "[OK] RUN_DIR=${RUN_DIR}"
