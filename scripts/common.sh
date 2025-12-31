#!/usr/bin/env bash
set -euo pipefail

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

die() { echo "[ERROR] $(ts) $*" 1>&2; exit 1; }

info() { echo "[INFO] $(ts) $*" 1>&2; }

warn() { echo "[WARN] $(ts) $*" 1>&2; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# run_id: UTC timestamp + short git sha (if available)
default_run_id() {
  local t sha
  t="$(date -u +"%Y%m%dT%H%M%SZ")"
  sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
  if [ -n "${sha}" ]; then echo "${t}_${sha}"; else echo "${t}"; fi
}

# Convert comma-separated providers into "-provider X -provider Y"
providers_to_args() {
  local p="$1" out=""
  IFS=',' read -r -a arr <<<"$p"
  for x in "${arr[@]}"; do
    x="$(echo "$x" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$x" ] && out="${out} -provider ${x}"
  done
  echo "$out"
}

# Write meta.json for a run (paper-grade provenance)
# Usage: write_meta_json "<outdir>" "<mode>" "<img_digest>" "<config_json_string>"
write_meta_json() {
  local outdir="$1"
  local mode="$2"
  local img="$3"
  local config_json="$4"

  mkdir -p "${outdir}"

  # git sha best-effort
  local git_sha
  git_sha="$(git rev-parse HEAD 2>/dev/null || true)"

  # IMPORTANT:
  # Do NOT embed bash variables into python code with ${var!r}.
  # Pass everything via environment variables to avoid shell substitution issues.
  OUTDIR="${outdir}" \
  MODE="${mode}" \
  IMG="${img}" \
  GIT_SHA="${git_sha}" \
  CONFIG_JSON="${config_json}" \
  python3 - <<'PY'
import json, os, platform, subprocess, datetime

outdir = os.environ.get("OUTDIR","")
mode = os.environ.get("MODE","")
img = os.environ.get("IMG","")
git_sha = os.environ.get("GIT_SHA","")
config_raw = os.environ.get("CONFIG_JSON","")

def sh(cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)[:4000]
    except Exception as e:
        return f"ERROR: {e}"

try:
    config = json.loads(config_raw) if config_raw else {}
except Exception as e:
    config = {"_config_json_parse_error": str(e), "_config_json_raw": config_raw[:2000]}

meta = {
    "timestamp_utc": datetime.datetime.utcnow().isoformat() + "Z",
    "mode": mode,
    "img": img,
    "git_sha": git_sha,
    "host": {
        "platform": platform.platform(),
        "python": platform.python_version(),
    },
    "docker": {
        "version": sh(["docker","--version"]),
    },
    "config": config,
}

path = os.path.join(outdir, "meta.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2)
print(path)
PY
}
