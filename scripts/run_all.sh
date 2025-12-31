#!/usr/bin/env bash
set -euo pipefail

MODE="${MODE:-paper}"
IMG="${IMG:?IMG is required (e.g. openquantumsafe/oqs-ossl3@sha256:...)}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-${ROOT}/results}"

TS="$(date -u +'%Y%m%dT%H%M%SZ')"
SHA="$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || true)"
RUN_ID="${TS}${SHA:+_${SHA}}"
RUN_DIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "${RUN_DIR}"

# Mode knobs
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

# Write meta.json on host (stable; python exists on host)
python3 "${ROOT}/scripts/write_meta.py" \
  --outdir "${RUN_DIR}" \
  --mode "${MODE}" \
  --img "${IMG}" \
  --git_sha "${SHA:-}" \
  --config_json "$(python3 - <<PY
import json, os
cfg = {
  "repeats": int(os.environ.get("REPEATS","0") or 0),
  "warmup": int(os.environ.get("WARMUP","0") or 0),
  "timesec": int(os.environ.get("TIMESEC","0") or 0),
  "n": int(os.environ.get("N","0") or 0),
  "attempt_timeout": float(os.environ.get("ATTEMPT_TIMEOUT","0") or 0),
  "bench_seconds": int(os.environ.get("BENCH_SECONDS","0") or 0),
  "strict": int(os.environ.get("STRICT","0") or 0),
}
print(json.dumps(cfg))
PY
)"

# Convenience: mount repo + outdir, run core scripts inside container
DOCKER_RUN=(docker run --rm
  -v "${ROOT}:/work:ro" -w /work
  -v "${RUN_DIR}:/out"
  -e MODE="${MODE}"
  -e REPEATS="${REPEATS}"
  -e WARMUP="${WARMUP}"
  -e TIMESEC="${TIMESEC}"
  -e N="${N}"
  -e ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT}"
  -e BENCH_SECONDS="${BENCH_SECONDS}"
  -e STRICT="${STRICT}"
  "${IMG}"
)

# 1) env info (container-side)
"${DOCKER_RUN[@]}" bash /work/scripts/core/env_info_core.sh /out |& tee "${RUN_DIR}/env_info.log"

# 2) TLS throughput (container-side, single container localhost server+client)
"${DOCKER_RUN[@]}" bash /work/scripts/core/tls_throughput_core.sh /out |& tee "${RUN_DIR}/tls_throughput.log"

# 3) TLS latency (container-side, single container localhost server+client)
"${DOCKER_RUN[@]}" bash /work/scripts/core/tls_latency_core.sh /out |& tee "${RUN_DIR}/tls_latency.log"

# 4) Signature benchmark (container-side, stable ECDSA baseline + PQC)
"${DOCKER_RUN[@]}" bash /work/scripts/core/sig_bench_core.sh /out |& tee "${RUN_DIR}/sig_bench.log"

# 5) Summarize on host (paper tables + JSON)
python3 "${ROOT}/scripts/summarize_results.py" "${RUN_DIR}" |& tee "${RUN_DIR}/summarize.log"

echo
echo "[OK] RUN_DIR=${RUN_DIR}"
