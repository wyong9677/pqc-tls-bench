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
            s = x.strip().lower()
            if s in ("", "nan", "none", "null"):
                return float("nan")
        return float(x)
    except Exception:
        return float("nan")

def clean(vals):
    return [v for v in vals if not math.isnan(v)]

def mean_std(vals):
    vals = clean(vals)
    if not vals:
        return float("nan"), float("nan")
    if len(vals) == 1:
        return vals[0], 0.0
    return statistics.mean(vals), statistics.pstdev(vals)

def bootstrap_ci(vals, iters=2000, alpha=0.05, seed=7):
    vals = clean(vals)
    if len(vals) < 2:
        return float("nan"), float("nan")
    rng = random.Random(seed)
    n = len(vals)
    means = []
    for _ in range(iters):
        sample = [vals[rng.randrange(n)] for _ in range(n)]
        means.append(statistics.mean(sample))
    means.sort()
    lo = means[int((alpha/2) * iters)]
    hi = means[int((1 - alpha/2) * iters) - 1]
    return lo, hi

def fmt_num(x, nd=2):
    if math.isnan(x):
        return "nan"
    return f"{x:.{nd}f}"

def cell_mean_std(m, s, nd=1):
    """Markdown cell: mean±std; if mean is NaN -> '—'."""
    if math.isnan(m):
        return "—"
    if math.isnan(s):
        # 极端情况：只有 mean，没有 std
        return f"{m:.{nd}f}±—"
    return f"{m:.{nd}f}±{s:.{nd}f}"

def json_stat(m, s):
    """JSON object for mean/std; NaN -> None (strict JSON)."""
    if math.isnan(m):
        return None
    if math.isnan(s):
        return {"mean": m, "std": None}
    return {"mean": m, "std": s}

def main(results_dir):
    out = []
    js = {"tls_throughput": {}, "tls_latency_adj": {}, "sig_speed": {}}

    # ================= TLS throughput =================
    tp = os.path.join(results_dir, "tls_throughput.csv")
    if os.path.exists(tp):
        rows = read_csv(tp)
        vals = [to_float(r.get("conn_user_sec")) for r in rows]

        m, s = mean_std(vals)
        lo, hi = bootstrap_ci(vals)

        out.append("## TLS Throughput (OpenSSL s_time)\n")
        out.append(
            f"- repeats={len(clean(vals))} mean={fmt_num(m)} conn/user-sec, "
            f"std={fmt_num(s)}, 95% CI=[{fmt_num(lo)}, {fmt_num(hi)}]\n\n"
        )

        js["tls_throughput"] = {
            "n": len(clean(vals)),
            "mean": None if math.isnan(m) else m,
            "std": None if math.isnan(s) else s,
            "ci95": [None if math.isnan(lo) else lo, None if math.isnan(hi) else hi],
        }

    # ================= TLS latency =================
    lat = os.path.join(results_dir, "tls_latency_summary.csv")
    if os.path.exists(lat):
        rows = read_csv(lat)
        metrics = {
            "p50": [to_float(r.get("adj_p50_ms")) for r in rows],
            "p95": [to_float(r.get("adj_p95_ms")) for r in rows],
            "p99": [to_float(r.get("adj_p99_ms")) for r in rows],
            "mean": [to_float(r.get("adj_mean_ms")) for r in rows],
        }

        out.append("## TLS Latency (Adjusted: docker exec baseline removed)\n")
        js["tls_latency_adj"] = {}

        for name, vals in metrics.items():
            m, s = mean_std(vals)
            lo, hi = bootstrap_ci(vals)

            out.append(
                f"- {name}: mean={fmt_num(m)} ms, std={fmt_num(s)}, "
                f"95% CI=[{fmt_num(lo)}, {fmt_num(hi)}]\n"
            )

            js["tls_latency_adj"][name] = {
                "n": len(clean(vals)),
                "mean": None if math.isnan(m) else m,
                "std": None if math.isnan(s) else s,
                "ci95": [None if math.isnan(lo) else lo, None if math.isnan(hi) else hi],
            }

        out.append("\n")

    # ================= Signature speed (robust & strict) =================
    sig = os.path.join(results_dir, "sig_speed.csv")
    if os.path.exists(sig):
        rows = read_csv(sig)
        by_alg = defaultdict(lambda: {"keygens": [], "sign": [], "verify": []})

        for r in rows:
            alg = (r.get("alg") or "").strip()
            if not alg:
                continue
            by_alg[alg]["keygens"].append(to_float(r.get("keygens_s")))
            by_alg[alg]["sign"].append(to_float(r.get("sign_s")))
            by_alg[alg]["verify"].append(to_float(r.get("verify_s")))

        out.append("## Signature Micro-benchmark (OpenSSL speed)\n")
        out.append("| Algorithm | KeyGen (mean±std) | Sign (mean±std) | Verify (mean±std) |\n")
        out.append("|---|---:|---:|---:|\n")

        js["sig_speed"] = {}

        # 稳定输出顺序：把 ecdsa 放前，其余按名称排序
        def alg_sort_key(a):
            al = a.lower()
            if al.startswith("ecdsa"):
                return (0, al)
            return (1, al)

        for alg in sorted(by_alg.keys(), key=alg_sort_key):
            d = by_alg[alg]
            km, ks = mean_std(d["keygens"])
            sm, ss = mean_std(d["sign"])
            vm, vs = mean_std(d["verify"])

            is_ecdsa = alg.lower().startswith("ecdsa")

            # KeyGen：ECDSA 明确不测；其他算法若缺失则 —
            if is_ecdsa:
                keygen_cell = "—"
                js_keygen = None
            else:
                keygen_cell = cell_mean_std(km, ks, nd=1)
                js_keygen = json_stat(km, ks)

            # Sign/Verify：任何 NaN 都不允许出现在表格中（用 —），JSON 用 null
            sign_cell = cell_mean_std(sm, ss, nd=1)
            verify_cell = cell_mean_std(vm, vs, nd=1)

            js_sign = json_stat(sm, ss)
            js_verify = json_stat(vm, vs)

            out.append(f"| {alg} | {keygen_cell} | {sign_cell} | {verify_cell} |\n")

            js["sig_speed"][alg] = {
                "keygens": js_keygen,
                "sign": js_sign,
                "verify": js_verify,
            }

        out.append(
            "\n*Note: ECDSA key generation is not benchmarked by OpenSSL speed. "
            "If signing/verification throughput is unavailable in the raw CSV, it is reported as “—” (null in JSON) rather than NaN.*\n\n"
        )

    # ================= write JSON sidecar (strict JSON) =================
    with open(os.path.join(results_dir, "paper_summary.json"), "w", encoding="utf-8") as fjson:
        # allow_nan=False: ensures no NaN/Infinity in output (artifact-friendly)
        json.dump(js, fjson, indent=2, allow_nan=False)

    print("# Paper-ready Benchmark Tables\n")
    print("".join(out))
    print(f"\n(Artifacts) paper_summary.json written under {results_dir}\n")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: summarize_results_paper.py <results_dir>", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1])
