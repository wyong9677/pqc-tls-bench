#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need docker
need python3

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

# defaults should match workflow knobs (smoke/paper controlled by env)
REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-2}"
TIMESEC="${TIMESEC:-15}"

# TLS config (override per experiment)
TLS_PROVIDERS="${TLS_PROVIDERS:-default}"          # e.g. "default" or "oqsprovider,default"
TLS_GROUPS="${TLS_GROUPS:-X25519}"                # e.g. "X25519" or "p256_kyber768" (if supported)
TLS_CERT_KEYALG="${TLS_CERT_KEYALG:-ec_p256}"      # "ec_p256" OR "mldsa65" OR "falcon512" etc
TLS_SERVER_EXTRA_ARGS="${TLS_SERVER_EXTRA_ARGS:-}" # optional extra s_server args (simple tokens)
TLS_CLIENT_EXTRA_ARGS="${TLS_CLIENT_EXTRA_ARGS:-}" # optional extra s_time args (simple tokens)

RUN_ID="${RUN_ID:-$(default_run_id)}"

# Prefer OUTDIR if workflow exports it (recommended: OUTDIR=$RUN_DIR)
OUTDIR="${OUTDIR:-${RESULTS_DIR}/${RUN_ID}}"
mkdir -p "${OUTDIR}"

# --- meta.json (host) ---
CONFIG_JSON="$(
  TLS_PROVIDERS="${TLS_PROVIDERS}" \
  TLS_GROUPS="${TLS_GROUPS}" \
  TLS_CERT_KEYALG="${TLS_CERT_KEYALG}" \
  TLS_SERVER_EXTRA_ARGS="${TLS_SERVER_EXTRA_ARGS}" \
  TLS_CLIENT_EXTRA_ARGS="${TLS_CLIENT_EXTRA_ARGS}" \
  REPEATS="${REPEATS}" \
  WARMUP="${WARMUP}" \
  TIMESEC="${TIMESEC}" \
  python3 - <<'PY'
import os, json
cfg = {
  "benchmark": "tls_throughput_s_time",
  "repeats": int(os.environ["REPEATS"]),
  "warmup": int(os.environ["WARMUP"]),
  "timesec": int(os.environ["TIMESEC"]),
  "providers": os.environ.get("TLS_PROVIDERS",""),
  "groups": os.environ.get("TLS_GROUPS",""),
  "cert_keyalg": os.environ.get("TLS_CERT_KEYALG",""),
  "server_extra_args": os.environ.get("TLS_SERVER_EXTRA_ARGS",""),
  "client_extra_args": os.environ.get("TLS_CLIENT_EXTRA_ARGS",""),
  "execution": "single_container_localhost",
}
print(json.dumps(cfg))
PY
)"
write_meta_json "${OUTDIR}" "${MODE}" "${IMG}" "${CONFIG_JSON}"

info "TLS throughput: mode=${MODE} run_id=${RUN_ID} outdir=${OUTDIR}"
info "repeats=${REPEATS} warmup=${WARMUP} time=${TIMESEC}s"
info "providers=${TLS_PROVIDERS} groups=${TLS_GROUPS} cert_keyalg=${TLS_CERT_KEYALG}"

# --- run core inside container ---
# Requirements:
# - scripts/core/tls_throughput_core.sh must be POSIX-safe (sh) and executable
# - it writes /out/tls_throughput.csv
WORKDIR="$(cd "${SCRIPT_DIR}/.." && pwd)"  # repo root if scripts/ is in repo root
CORE="/work/scripts/core/tls_throughput_core.sh"

if [ ! -f "${WORKDIR}/scripts/core/tls_throughput_core.sh" ]; then
  die "missing core: ${WORKDIR}/scripts/core/tls_throughput_core.sh"
fi

docker run --rm \
  -v "${WORKDIR}:/work:ro" \
  -v "${OUTDIR}:/out" \
  -w /work \
  -e MODE="${MODE}" \
  -e REPEATS="${REPEATS}" \
  -e WARMUP="${WARMUP}" \
  -e TIMESEC="${TIMESEC}" \
  -e TLS_PROVIDERS="${TLS_PROVIDERS}" \
  -e TLS_GROUPS="${TLS_GROUPS}" \
  -e TLS_CERT_KEYALG="${TLS_CERT_KEYALG}" \
  -e TLS_SERVER_EXTRA_ARGS="${TLS_SERVER_EXTRA_ARGS}" \
  -e TLS_CLIENT_EXTRA_ARGS="${TLS_CLIENT_EXTRA_ARGS}" \
  "${IMG}" sh -lc "${CORE} /out" \
  |& tee "${OUTDIR}/tls_throughput.log"

# basic sanity (fail fast if nonsense)
test -f "${OUTDIR}/tls_throughput.csv" || die "tls_throughput.csv not produced"
lines="$(wc -l < "${OUTDIR}/tls_throughput.csv")"
[ "${lines}" -ge 2 ] || die "tls_throughput.csv too short (lines=${lines})"

echo
echo "OK. CSV: ${OUTDIR}/tls_throughput.csv"
echo "Log: ${OUTDIR}/tls_throughput.log"
echo "Meta: ${OUTDIR}/meta.json"
