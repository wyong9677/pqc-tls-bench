#!/usr/bin/env bash
# Common utilities for paper-grade PQC/TLS benchmarks
# Safe to source from other scripts.
set -euo pipefail

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

info() { echo "[INFO] $(ts) $*"; }
warn() { echo "[WARN] $(ts) $*" >&2; }
die()  { echo "[ERROR] $(ts) $*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

default_run_id() {
  local ts sha
  ts="$(date -u +'%Y%m%dT%H%M%SZ')"
  sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
  if [ -n "${sha}" ]; then echo "${ts}_${sha}"; else echo "${ts}"; fi
}

# providers_to_args "default" -> "-provider default"
# providers_to_args "oqs"     -> "-provider oqsprovider -provider default"
# providers_to_args "default,oqs" -> "-provider default -provider oqsprovider -provider default" (order kept)
providers_to_args() {
  local p="${1:-default}"
  local out=()
  IFS=',' read -r -a arr <<< "${p}"
  for x in "${arr[@]}"; do
    case "${x}" in
      default) out+=("-provider" "default") ;;
      oqs|oqsprovider) out+=("-provider" "oqsprovider" "-provider" "default") ;;
      *)
        die "unknown provider tag: ${x} (expected: default|oqs)"
        ;;
    esac
  done
  printf "%q " "${out[@]}"
}

# write_meta_json OUTDIR MODE IMG CONFIG_JSON
# - host-side python only; no ${var!r} bash substitution; values passed via env
write_meta_json() {
  local outdir="$1" mode="$2" img="$3" config_json="$4"
  need python3
  mkdir -p "${outdir}"

  OUTDIR="${outdir}" MODE="${mode}" IMG="${img}" CONFIG_JSON="${config_json}" \
  python3 - <<'PY'
import os, json, platform, subprocess, datetime

outdir=os.environ["OUTDIR"]
mode=os.environ.get("MODE","")
img=os.environ.get("IMG","")
cfg=os.environ.get("CONFIG_JSON","{}")

def sh(cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)[:8000]
    except Exception as e:
        return f"ERROR: {e}"

meta = {
  "timestamp_utc": datetime.datetime.utcnow().isoformat() + "Z",
  "mode": mode,
  "img": img,
  "git_sha": sh(["git","rev-parse","HEAD"]).strip(),
  "host": {
    "platform": platform.platform(),
    "python": platform.python_version(),
  },
  "docker": {
    "version": sh(["docker","--version"]).strip(),
  },
  "config": json.loads(cfg) if cfg else {},
}

with open(os.path.join(outdir, "meta.json"), "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2)
print(os.path.join(outdir,"meta.json"))
PY
}
