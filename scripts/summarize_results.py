#!/usr/bin/env python3
import sys, os, csv, math, statistics, random, json
from collections import defaultdict

def read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

def to_float(x):
    try:
        if x is None: return float("nan")
        if isinstance(x, str) and x.lower() == "nan": return float("nan")
        return float(x)
    except:
        return float("nan")

def clean(vals):
    return [v for v in vals if not math.isnan(v)]

def mean_std(vals):
    vals=clean(vals)
    if not vals: return float("nan"), float("nan")
    if len(vals)==1: return vals[0], 0.0
    return statistics.mean(vals), statistics.pstdev(vals)

def bootstrap_ci(vals, iters=2000, alpha=0.05, seed=7):
    vals=clean(vals)
    if len(vals) < 2:
        return float("nan"), float("nan")
    rng=random.Random(seed)
    n=len(vals)
    means=[]
    for _ in range(iters):
        sample=[vals[rng.randrange(n)] for _ in range(n)]
        means.append(statistics.mean(sample))
    means.sort()
    lo=means[int((alpha/2)*iters)]
    hi=means[int((1-alpha/2)*iters)-1]
    return lo, hi

def f(x, nd=2):
    if math.isnan(x): return "nan"
    return f"{x:.{nd}f}"

def main(results_dir):
    out=[]
    js={"tls_throughput":{}, "tls_latency_adj":{}, "sig_speed":{}}

    # TLS throughput
    tp=os.path.join(results_dir,"tls_throughput.csv")
    if os.path.exists(tp):
        rows=read_csv(tp)
        vals=[to_float(r["conn_user_sec"]) for r in rows]
        m,s=mean_std(vals)
        lo,hi=bootstrap_ci(vals)
        out.append("## TLS Throughput (OpenSSL s_time)\n")
        out.append(f"- repeats={len(clean(vals))} mean={f(m)} conn/user-sec, std={f(s)}, 95% CI=[{f(lo)}, {f(hi)}]\n\n")
        js["tls_throughput"]={"n":len(clean(vals)),"mean":m,"std":s,"ci95":[lo,hi]}

    # TLS latency adjusted summary
    lat=os.path.join(results_dir,"tls_latency_summary.csv")
    if os.path.exists(lat):
        rows=read_csv(lat)
        p50=[to_float(r["adj_p50_ms"]) for r in rows]
        p95=[to_float(r["adj_p95_ms"]) for r in rows]
        p99=[to_float(r["adj_p99_ms"]) for r in rows]
        mean=[to_float(r["adj_mean_ms"]) for r in rows]

        out.append("## TLS Latency (Adjusted: docker exec baseline removed)\n")
        for name, vals in [("p50",p50),("p95",p95),("p99",p99),("mean",mean)]:
            m,s=mean_std(vals)
            lo,hi=bootstrap_ci(vals)
            out.append(f"- {name}: mean={f(m)} ms, std={f(s)}, 95% CI=[{f(lo)}, {f(hi)}]\n")
            js["tls_latency_adj"][name]={"n":len(clean(vals)),"mean":m,"std":s,"ci95":[lo,hi]}
        out.append("\n")

    # Signature speed
    sig=os.path.join(results_dir,"sig_speed.csv")
    if os.path.exists(sig):
        rows=read_csv(sig)
        by_alg=defaultdict(lambda: {"keygens":[], "sign":[], "verify":[]})
        for r in rows:
            alg=r["alg"]
            by_alg[alg]["keygens"].append(to_float(r["keygens_s"]))
            by_alg[alg]["sign"].append(to_float(r["sign_s"]))
            by_alg[alg]["verify"].append(to_float(r["verify_s"]))

        out.append("## Signature Micro-benchmark (OpenSSL speed)\n")
        out.append("| alg | keygens/s (mean±std) | sign/s (mean±std) | verify/s (mean±std) |\n")
        out.append("|---|---:|---:|---:|\n")
        js["sig_speed"]={}
        for alg, d in by_alg.items():
            km,ks=mean_std(d["keygens"])
            sm,ss=mean_std(d["sign"])
            vm,vs=mean_std(d["verify"])
            out.append(f"| {alg} | {f(km,1)}±{f(ks,1)} | {f(sm,1)}±{f(ss,1)} | {f(vm,1)}±{f(vs,1)} |\n")
            js["sig_speed"][alg]={"keygens":{"mean":km,"std":ks},"sign":{"mean":sm,"std":ss},"verify":{"mean":vm,"std":vs}}
        out.append("\n")

    # write JSON sidecar
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
