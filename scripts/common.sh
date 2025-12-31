#!/usr/bin/env bash
set -euo pipefail

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

die() { echo "[ERROR] $(ts) $*" 1>&2; exit 1; }

info() { echo "[INFO] $(ts) $*" 1>&2; }

warn() { echo "[WARN] $(ts) $*" 1>&2; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# run_id: default to UTC timestamp + short git sha (if available)
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

# Write meta.json for a run
write_meta_json() {
  local outdir="$1"
  local mode="$2"
  local img="$3"
  local config_json="$4"

  mkdir -p "${outdir}"
  local git_sha
  git_sha="$(git rev-parse HEAD 2>/dev/null || true)"

  python3 - <<PY
import json, os, platform, subprocess, datetime

outdir=${outdir!r}
meta = {
  "timestamp_utc": datetime.datetime.utcnow().isoformat() + "Z",
  "mode": ${mode!r},
  "img": ${img!r},
  "git_sha": ${git_sha!r},
  "host": {
    "platform": platform.platform(),
    "python": platform.python_version(),
  },
  "config": json.loads(${config_json!r}),
}

# docker version / info (best-effort)
def sh(cmd):
  try:
    return subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)[:4000]
  except Exception as e:
    return f"ERROR: {e}"

meta["docker"] = {
  "version": sh(["docker","--version"]),
}

with open(os.path.join(outdir, "meta.json"), "w", encoding="utf-8") as f:
  json.dump(meta, f, indent=2)
PY
}
