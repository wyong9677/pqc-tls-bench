#!/usr/bin/env bash
set -euo pipefail

MODE="${MODE:-paper}"
IMG="${IMG:?IMG is required (e.g. openquantumsafe/oqs-ossl3:latest)}"
RESULTS_DIR="${RESULTS_DIR:-results}"

TS="$(date -u +'%Y%m%dT%H%M%SZ')"
SHA="$(git rev-parse --short HEAD 2>/dev/null || true)"
RUN_ID="${TS}${SHA:+_${SHA}}"
RUN_DIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "${RUN_DIR}"

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

# write meta (argparse flags)
python3 scripts/write_meta.py \
  --outdir "${RUN_DIR}" \
  --mode "${MODE}" \
  --img "${IMG}" \
  --git_sha "${SHA:-}"

# Container: use sh only (oqs-ossl3 may not have bash)
docker run --rm \
  -v "$(pwd):/work:ro" -w /work \
  -v "${RUN_DIR}:/out" \
  -e MODE \
  "${IMG}" sh /work/scripts/core/env_info_core.sh /out \
  |& tee "${RUN_DIR}/env_info.log"

docker run --rm \
  -v "$(pwd):/work:ro" -w /work \
  -v "${RUN_DIR}:/out" \
  -e MODE -e REPEATS -e WARMUP -e BENCH_SECONDS -e STRICT \
  "${IMG}" sh /work/scripts/core/sig_bench_core.sh /out \
  |& tee "${RUN_DIR}/sig_bench.log"

echo "[OK] RUN_DIR=${RUN_DIR}"
