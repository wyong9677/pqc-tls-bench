#!/usr/bin/env python3
import sys, os, csv, math, statistics
from collections import defaultdict

def read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

def mean_std(vals):
    vals=[v for v in vals if v is not None and not math.isnan(v)]
    if not vals:
        return float("nan"), float("nan")
    if len(vals)==1:
        return vals[0], 0.0
    return statistics.mean(vals), statistics.pstdev(vals)

def fnum(x, nd=2):
    if x is None or (isinstance(x,float) and math.isnan(x)):
        return "nan"
    return f"{x:.{nd}f}"

def main(results_dir):
    out=[]
    out.append("# Paper-ready Benchmark Tables\n")

    # TLS throughput
    tp_path=os.path.join(results_dir,"tls_throughput.csv")
    if os.path.exists(tp_path):
        rows=read_csv(tp_path)
        vals=[float(r["conn_user_sec"]) if r["conn_user_sec"]!="nan" else float("nan") for r in rows]
        m,s=mean_std(vals)
        out.append("## TLS Throughput (OpenSSL s_time)\n")
        out.append(f"- repeats={len(rows)} mean={fnum(m)} conn/user-sec, std={fnum(s)}\n")

    # TLS latency summary (adjusted)
    lat_path=os.path.join(results_dir,"tls_latency_summary.csv")
    if os.path.exists(lat_path):
        rows=read_csv(lat_path)
        p50=[float(r["p50_ms"]) if r["p50_ms"]!="nan" else float("nan") for r in rows]
        p95=[float(r["p95_ms"]) if r["p95_ms"]!="nan" else float("nan") for r in rows]
        p99=[float(r["p99_ms"]) if r["p99_ms"]!="nan" else float("nan") for r in rows]
        mean=[float(r["mean_ms"]) if r["mean_ms"]!="nan" else float("nan") for r in rows]
        out.append("## TLS Latency (Adjusted, docker exec baseline removed)\n")
        for name,vals in [("p50",p50),("p95",p95),("p99",p99),("mean",mean)]:
            m,s=mean_std(vals)
            out.append(f"- {name}: mean={fnum(m)} ms, std={fnum(s)} ms\n")
        out.append("")

    # Signature speed
    sig_path=os.path.join(results_dir,"sig_speed.csv")
    if os.path.exists(sig_path):
        rows=read_csv(sig_path)
        by_alg=defaultdict(list)
        for r in rows:
            alg=r["alg"]
            if r["sign_s"]=="nan": 
                continue
            by_alg[alg].append((
                float(r["keygens_s"]), float(r["sign_s"]), float(r["verify_s"])
            ))
        out.append("## Signature Micro-benchmark (OpenSSL speed)\n")
        out.append("| alg | keygens/s (mean±std) | sign/s (mean±std) | verify/s (mean±std) |\n")
        out.append("|---|---:|---:|---:|\n")
        for alg, lst in by_alg.items():
            ks=[x[0] for x in lst]; ss=[x[1] for x in lst]; vs=[x[2] for x in lst]
            km,ksd=mean_std(ks); sm,ssd=mean_std(ss); vm,vsd=mean_std(vs)
            out.append(f"| {alg} | {fnum(km,1)}±{fnum(ksd,1)} | {fnum(sm,1)}±{fnum(ssd,1)} | {fnum(vm,1)}±{fnum(vsd,1)} |\n")
        out.append("")

    print("".join(out))

if __name__=="__main__":
    if len(sys.argv)!=2:
        print("usage: summarize_results.py <results_dir>", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1])
