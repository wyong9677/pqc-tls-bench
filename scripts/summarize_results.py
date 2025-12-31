#!/usr/bin/env python3
import sys, os, csv, math, statistics, random, json
from collections import defaultdict

def read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

def to_float(x):
    try:
        if x is None:
            return float("nan")
        if isinstance(x, str):
            xs = x.strip().lower()
            if xs in ("", "nan", "na", "none"):
                return float("nan")
        return float(x)
    except Exception:
        return float("nan")

def is_trueish(x):
    if x is None:
        return True
    s = str(x).strip().lower()
    if s == "":
        return True
    return s in ("1", "true", "yes", "y", "ok")

def clean(vals):
    return [v for v in vals if not math.isnan(v)]

def mean_std(vals):
    vals = clean(vals)
    if not vals:
        return float("nan"), float("nan")
    if len(vals) == 1:
        return vals[0], 0.0
    return statistics.mean(vals), statistics.pstdev(vals)

def median(vals):
    vals = clean(vals)
    if not vals:
        return float("nan")
    return statistics.median(vals)

def bootstrap_ci(vals, stat="mean", iters=2000, alpha=0.05, seed=7):
    vals = clean(vals)
    if len(vals) < 2:
        return float("nan"), float("nan")
    rng = random.Random(seed)
    n = len(vals)
    stats = []
    for _ in range(iters):
        sample = [vals[rng.randrange(n)] for _ in range(n)]
        if stat == "median":
            stats.append(statistics.median(sample))
        else:
            stats.append(statistics.mean(sample))
    stats.sort()
    lo_idx = int((alpha/2) * iters)
    hi_idx = int((1 - alpha/2) * iters) - 1
    lo_idx = max(0, min(iters-1, lo_idx))
    hi_idx = max(0, min(iters-1, hi_idx))
    return stats[lo_idx], stats[hi_idx]

def f(x, nd=2):
    if math.isnan(x):
        return "nan"
    return f"{x:.{nd}f}"

def main(run_dir):
    out = []
    js = {"run_dir": run_dir, "quality": {}, "tls_throughput": {}, "tls_latency": {}, "sig_speed": {}}

    # -----------------
    # TLS throughput
    # -----------------
    tp = os.path.join(run_dir, "tls_throughput.csv")
    if os.path.exists(tp):
        rows = read_csv(tp)
        total = len(rows)
        # ok field optional; conn_user_sec must be > 0 to be meaningful
        vals_raw = []
        for r in rows:
            if "ok" in r and not is_trueish(r.get("ok")):
                continue
            v = to_float(r.get("conn_user_sec"))
            if not math.isnan(v) and v > 0:
                vals_raw.append(v)

        n_valid = len(clean(vals_raw))
        m, s = mean_std(vals_raw)
        med = median(vals_raw)
        lo_m, hi_m = bootstrap_ci(vals_raw, stat="mean")
        lo_med, hi_med = bootstrap_ci(vals_raw, stat="median")

        out.append("## TLS Throughput (OpenSSL s_time)\n\n")
        out.append(f"- valid_repeats={n_valid}/{total}\n")
        out.append(f"- mean={f(m)} conn/user-sec, std={f(s)}, 95% CI(mean)=[{f(lo_m)}, {f(hi_m)}]\n")
        out.append(f"- median={f(med)} conn/user-sec, 95% CI(median)=[{f(lo_med)}, {f(hi_med)}]\n\n")

        js["tls_throughput"] = {
            "total_rows": total,
            "n": n_valid,
            "mean": m,
            "std": s,
            "median": med,
            "ci95_mean": [lo_m, hi_m],
            "ci95_median": [lo_med, hi_med],
        }

    # -----------------
    # TLS latency
    # -----------------
    lat = os.path.join(run_dir, "tls_latency_summary.csv")
    if os.path.exists(lat):
        rows = read_csv(lat)
        total = len(rows)

        metrics = {
            "p50_ms": [to_float(r.get("p50_ms")) for r in rows],
            "p95_ms": [to_float(r.get("p95_ms")) for r in rows],
            "p99_ms": [to_float(r.get("p99_ms")) for r in rows],
            "mean_ms": [to_float(r.get("mean_ms")) for r in rows],
            "fail":    [to_float(r.get("fail")) for r in rows],
            "ok":      [to_float(r.get("ok")) for r in rows],
        }

        out.append("## TLS Latency (handshake wall-clock per attempt)\n\n")
        out.append(f"- reps={total}\n\n")

        js["tls_latency"] = {}
        for name in ("p50_ms", "p95_ms", "p99_ms", "mean_ms"):
            vals = metrics[name]
            n_valid = len(clean(vals))
            m, s = mean_std(vals)
            med = median(vals)
            lo_m, hi_m = bootstrap_ci(vals, stat="mean")
            lo_med, hi_med = bootstrap_ci(vals, stat="median")
            out.append(
                f"- {name}: valid={n_valid}/{total}, "
                f"mean={f(m)} ms, std={f(s)}, CI(mean)=[{f(lo_m)}, {f(hi_m)}], "
                f"median={f(med)} ms, CI(median)=[{f(lo_med)}, {f(hi_med)}]\n"
            )
            js["tls_latency"][name] = {
                "total_rows": total,
                "n": n_valid,
                "mean": m,
                "std": s,
                "median": med,
                "ci95_mean": [lo_m, hi_m],
                "ci95_median": [lo_med, hi_med],
            }

        # quality: avg fail rate if available
        ok_vals = clean(metrics["ok"])
        fail_vals = clean(metrics["fail"])
        if ok_vals and fail_vals:
            # compute fail rate per rep as fail/(ok+fail)
            fr = []
            for o, fa in zip(metrics["ok"], metrics["fail"]):
                if math.isnan(o) or math.isnan(fa):
                    continue
                denom = o + fa
                if denom <= 0:
                    continue
                fr.append(fa / denom)
            fr_m = statistics.mean(fr) if fr else float("nan")
            out.append(f"\n- approx_fail_rate_per_attempt (mean over reps) = {f(fr_m,3)}\n\n")
            js["tls_latency"]["fail_rate_mean"] = fr_m
        else:
            out.append("\n- fail/ok columns not reliable; fail-rate not reported.\n\n")

    # -----------------
    # Signature speed
    # -----------------
    sig = os.path.join(run_dir, "sig_speed.csv")
    if os.path.exists(sig):
        rows = read_csv(sig)
        total = len(rows)

        by_alg = defaultdict(lambda: {"keygens_s": [], "sign_s": [], "verify_s": []})
        for r in rows:
            alg = (r.get("alg") or "").strip()
            if not alg:
                continue
            by_alg[alg]["keygens_s"].append(to_float(r.get("keygens_s")))
            by_alg[alg]["sign_s"].append(to_float(r.get("sign_s")))
            by_alg[alg]["verify_s"].append(to_float(r.get("verify_s")))

        out.append("## Signature Micro-benchmark (counted ops over fixed window)\n\n")
        out.append("| Algorithm | KeyGen/s (mean±std) | Sign/s (mean±std) | Verify/s (mean±std) | n |\n")
        out.append("|---|---:|---:|---:|---:|\n")

        js["sig_speed"] = {"total_rows": total, "by_alg": {}}

        for alg in sorted(by_alg.keys()):
            d = by_alg[alg]
            km, ks = mean_std(d["keygens_s"])
            sm, ss = mean_std(d["sign_s"])
            vm, vs = mean_std(d["verify_s"])

            n_alg = max(len(clean(d["sign_s"])), len(clean(d["verify_s"])), len(clean(d["keygens_s"])))
            out.append(
                f"| {alg} | {f(km,1)}±{f(ks,1)} | {f(sm,1)}±{f(ss,1)} | {f(vm,1)}±{f(vs,1)} | {n_alg} |\n"
            )
            js["sig_speed"]["by_alg"][alg] = {
                "keygens_s": {"n": len(clean(d["keygens_s"])), "mean": km, "std": ks},
                "sign_s":    {"n": len(clean(d["sign_s"])), "mean": sm, "std": ss},
                "verify_s":  {"n": len(clean(d["verify_s"])), "mean": vm, "std": vs},
            }

        out.append("\n*Note: rates are computed from successful operation counts within the configured time window; failures reduce counts implicitly.*\n\n")

    # -----------------
    # Data quality summary
    # -----------------
    # lightweight: presence + row counts
    js["quality"] = {
        "has_tls_throughput_csv": os.path.exists(os.path.join(run_dir, "tls_throughput.csv")),
        "has_tls_latency_summary_csv": os.path.exists(os.path.join(run_dir, "tls_latency_summary.csv")),
        "has_sig_speed_csv": os.path.exists(os.path.join(run_dir, "sig_speed.csv")),
    }

    # Write JSON + markdown
    with open(os.path.join(run_dir, "paper_summary.json"), "w", encoding="utf-8") as fjson:
        json.dump(js, fjson, indent=2)

    md_path = os.path.join(run_dir, "paper_tables.md")
    with open(md_path, "w", encoding="utf-8") as fmd:
        fmd.write("# Paper-ready Benchmark Tables\n\n")
        fmd.write("".join(out))

    print(f"OK. Wrote:\n- {md_path}\n- {os.path.join(run_dir,'paper_summary.json')}\n")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: summarize_results.py <run_dir>", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1])
