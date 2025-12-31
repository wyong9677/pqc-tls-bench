cd ~/pqc-tls-bench
mkdir -p scripts

cat > scripts/run_all.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

MODE="${MODE:-paper}"
IMG="${IMG:?IMG is required (e.g. openquantumsafe/oqs-ossl3:latest)}"
RESULTS_DIR="${RESULTS_DIR:-results}"

die() { echo "[FATAL] $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

need python3
need docker

[ -f "scripts/write_meta.py" ] || die "Missing scripts/write_meta.py"
[ -f "scripts/core/env_info_core.sh" ] || die "Missing scripts/core/env_info_core.sh"
[ -f "scripts/core/sig_bench_core.sh" ] || die "Missing scripts/core/sig_bench_core.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR_ABS="${ROOT_DIR}/${RESULTS_DIR}"
mkdir -p "${RESULTS_DIR_ABS}"

TS="$(date -u +'%Y%m%dT%H%M%SZ')"
SHA="$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || true)"
RUN_ID="${TS}${SHA:+_${SHA}}"
RUN_DIR="${RESULTS_DIR_ABS}/${RUN_ID}"
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
echo "[INFO] ROOT_DIR=${ROOT_DIR}"
echo "[INFO] RUN_DIR=${RUN_DIR}"
echo "[INFO] REPEATS=${REPEATS} WARMUP=${WARMUP} TIMESEC=${TIMESEC} N=${N} ATTEMPT_TIMEOUT=${ATTEMPT_TIMEOUT} BENCH_SECONDS=${BENCH_SECONDS} STRICT=${STRICT}"

CONFIG_JSON="$(
  REPEATS="${REPEATS}" WARMUP="${WARMUP}" TIMESEC="${TIMESEC}" N="${N}" \
  ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT}" BENCH_SECONDS="${BENCH_SECONDS}" STRICT="${STRICT}" \
  python3 - <<'PY'
import os, json
cfg = {
  "repeats": int(os.environ["REPEATS"]),
  "warmup": int(os.environ["WARMUP"]),
  "timesec": int(os.environ["TIMESEC"]),
  "n": int(os.environ["N"]),
  "attempt_timeout": float(os.environ["ATTEMPT_TIMEOUT"]),
  "bench_seconds": int(os.environ["BENCH_SECONDS"]),
  "strict": int(os.environ["STRICT"]),
}
print(json.dumps(cfg))
PY
)"

python3 "${ROOT_DIR}/scripts/write_meta.py" \
  --outdir "${RUN_DIR}" \
  --mode "${MODE}" \
  --img "${IMG}" \
  --git_sha "${SHA:-}" \
  --config_json "${CONFIG_JSON}" \
  |& tee "${RUN_DIR}/write_meta.log"

# Container might not have bash -> sh only
docker run --rm \
  -v "${ROOT_DIR}:/work:ro" -w /work \
  -v "${RUN_DIR}:/out" \
  -e MODE -e REPEATS -e WARMUP -e TIMESEC -e N -e ATTEMPT_TIMEOUT -e BENCH_SECONDS -e STRICT \
  "${IMG}" sh /work/scripts/core/env_info_core.sh /out \
  |& tee "${RUN_DIR}/env_info.log"

docker run --rm \
  -v "${ROOT_DIR}:/work:ro" -w /work \
  -v "${RUN_DIR}:/out" \
  -e MODE -e REPEATS -e WARMUP -e TIMESEC -e N -e ATTEMPT_TIMEOUT -e BENCH_SECONDS -e STRICT \
  "${IMG}" sh /work/scripts/core/sig_bench_core.sh /out \
  |& tee "${RUN_DIR}/sig_bench.log"

echo "[OK] RUN_DIR=${RUN_DIR}"
SH

chmod +x scripts/run_all.sh
