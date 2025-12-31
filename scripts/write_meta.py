#!/usr/bin/env python3
import argparse, json, os, platform, datetime, subprocess

def sh(cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)[:4000]
    except Exception as e:
        return f"ERROR: {e}"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--mode", required=True)
    ap.add_argument("--img", required=True)
    ap.add_argument("--git_sha", default="")
    ap.add_argument("--config_json", default="{}")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    meta = {
        "timestamp_utc": datetime.datetime.utcnow().isoformat() + "Z",
        "mode": args.mode,
        "img": args.img,
        "git_sha": args.git_sha,
        "host": {
            "platform": platform.platform(),
            "python": platform.python_version(),
        },
        "docker": {
            "version": sh(["docker","--version"]),
        },
        "config": json.loads(args.config_json or "{}"),
    }

    with open(os.path.join(args.outdir, "meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)

    print(os.path.join(args.outdir, "meta.json"))

if __name__ == "__main__":
    main()
