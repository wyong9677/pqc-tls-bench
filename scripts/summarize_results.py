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
            s = x.strip()
            if s == "" or s.lower() == "nan":
                return float("nan")
            return float(s)
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
    # sample std (n-1) is more standard for reporting variability
    return statistics.mean(vals), statistics.stdev(vals)

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
    lo = means[int((alpha/2)*iters)]
    hi = means[int((1-alpha/2)*iters)-1]
    return lo, hi

def fmt(x, nd=2):
    if x is None:
        return "—"
    if isinstance(x, float) and math.isnan(x):
        return "—"
    return f"{x:.{nd}f}"

def fmt_pm(mean, std, nd=1):
    if mean is None or (isinstance(mean, float) and math.isnan(mean)):
        return "—"
    if std is None or (isinstance(std, float) and math.isnan(std)):
        return "—"
    return f"{mean:.{nd}f}±{std:.{nd}f}"

def main(results_dir):
    out=[]
    js={"tls_throughput":{}, "tls_latency_adj":{}, "sig_speed":{}}

    # ================= TLS throughput =================
    tp=os.path.join(results_dir,"tls_throughput.csv")
    if os.path.exists(tp):
        rows=read_csv(tp)
        vals=[to_float(r.get("conn_user_sec")) for r in rows]
        m,s=mean_std(vals)
        lo,hi=bootstrap_ci(vals)
        out.append("## TLS Throughput (OpenSSL s_time)\n")
        out.append(
            f"- repeats={len(clean(vals))} mean={fmt(m)} conn/user-sec, "
            f"std={fmt(s)}, 95% CI=[{fmt(lo)}, {fmt(hi)}]\n\n"
        )
        js["tls_throughput"]={"n":len(clean(vals)),"mean":m,"std":s,"ci95":[lo,hi]}

    # ================= TLS latency =================
    lat=os.path.join(results_dir,"tls_latency_summary.csv")
    if os.path.exists(lat):
        rows=read_csv(lat)
        metrics = {
            "p50":[to_float(r.get("adj_p50_ms")) for r in rows],
            "p95":[to_float(r.get("adj_p95_ms")) for r in rows],
            "p99":[to_float(r.get("adj_p99_ms")) for r in rows],
            "mean":[to_float(r.get("adj_mean_ms")) for r in rows],
        }
        out.append("## TLS Latency (Adjusted: docker exec baseline removed)\n")
        js["tls_latency_adj"]={}
        for name, vals in metrics.items():
            m,s=mean_std(vals)
            lo,hi=bootstrap_ci(vals)
            out.append(f"- {name}: mean={fmt(m)} ms, std={fmt(s)}, 95% CI=[{fmt(lo)}, {fmt(hi)}]\n")
            js["tls_latency_adj"][name]={"n":len(clean(vals)),"mean":m,"std":s,"ci95":[lo,hi]}
        out.append("\n")

    # ================= Signature speed =================
    sig=os.path.join(results_dir,"sig_speed.csv")
    if os.path.exists(sig):
        rows=read_csv(sig)

        # If CSV has ok column, keep only ok==1
        has_ok = ("ok" in rows[0]) if rows else False
        if has_ok:
            rows = [r for r in rows if str(r.get("ok","")).strip() == "1"]

        by_alg=defaultdict(lambda: {"keygens":[], "sign":[], "verify":[]})
        for r in rows:
            alg=(r.get("alg") or "").strip()
            if not alg:
                continue
            by_alg[alg]["keygens"].append(to_float(r.get("keygens_s")))
            by_alg[alg]["sign"].append(to_float(r.get("sign_s")))
            by_alg[alg]["verify"].append(to_float(r.get("verify_s")))

        # Stable, paper-friendly ordering
        preferred = ["ecdsap256","mldsa44","mldsa65","falcon512","falcon1024"]
        algs = [a for a in preferred if a in by_alg] + sorted([a for a in by_alg if a not in preferred])

        out.append("## Signature Micro-benchmark (OpenSSL speed)\n")
        out.append("| Algorithm | KeyGen (mean±std) | Sign (mean±std) | Verify (mean±std) |\n")
        out.append("|---|---:|---:|---:|\n")
        js["sig_speed"]={}

        for alg in algs:
            d = by_alg[alg]
            km,ks=mean_std(d["keygens"])
            sm,ss=mean_std(d["sign"])
            vm,vs=mean_std(d["verify"])

            # ECDSA: keygen is not reported (avoid misleading)
            if alg.lower().startswith("ecdsa"):
                keygen_cell="—"
                js_keygen=None
            else:
                keygen_cell=fmt_pm(km,ks,nd=1) if len(clean(d["keygens"]))>0 else "—"
                js_keygen={"mean":km,"std":ks} if len(clean(d["keygens"]))>0 else None

            sign_cell = fmt_pm(sm,ss,nd=1) if len(clean(d["sign"]))>0 else "—"
            verify_cell = fmt_pm(vm,vs,nd=1) if len(clean(d["verify"]))>0 else "—"

            out.append(f"| {alg} | {keygen_cell} | {sign_cell} | {verify_cell} |\n")

            js["sig_speed"][alg]={
                "keygens": js_keygen,
                "sign": ({"mean":sm,"std":ss} if len(clean(d["sign"]))>0 else None),
                "verify": ({"mean":vm,"std":vs} if len(clean(d["verify"]))>0 else None),
            }

        out.append(
            "\n*Note: ECDSA key generation is not benchmarked by OpenSSL speed; "
            "only signing and verification throughput are reported.*\n\n"
        )

    # ================= write JSON =================
    with open(os.path.join(results_dir,"paper_summary.json"),"w",encoding="utf-8") as fjson:
        json.dump(js,fjson,indent=2)

    print("# Paper-ready Benchmark Tables\n")
    print("".join(out))
    print(f"\n(Artifacts) paper_summary.json written under {results_dir}\n")

if __name__=="__main__":
    if len(sys.argv)!=2:
        print("usage: summarize_results_paper.py <results_dir>", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1])
