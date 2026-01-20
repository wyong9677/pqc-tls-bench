# pqc-tls-bench

Benchmark and testing code for PQC-enabled TLS measurements used to support the paper:

**Post-Quantum Cryptography for Artificial Intelligence Applications and Outlook**  
(Submitted as a New Ideas and Trends (long) paper; simulation-first decision artifacts and calibration inputs.)

This repository provides the **code and automation workflows** to (re-)run the benchmark pipeline and summarize results.
The **paper figure/table datasets** are distributed as **Supplementary Material (SM)** via the journal submission system to ensure review-time stability.

---

## What this repository contains

- **CI workflow (paper benchmark pipeline)**:  
  `.github/workflows/pqc-bench-paper.yml`

- **Benchmark scripts** (paper-oriented entry points):  
  `scripts/bench_tls_paper.sh`  
  `scripts/bench_tls_latency_paper.sh`  
  `scripts/bench_sig_paper.sh`  
  `scripts/run_all.sh` (one-shot runner)  
  `scripts/summarize_results.py` (aggregates raw results to CSV summaries)  
  `scripts/env_info_paper.sh` (captures environment metadata)  
  `scripts/common.sh` (shared helpers)

---

## Quick start (local)

### Prerequisites
- Linux/macOS with Bash
- Python 3.x (for `summarize_results.py`)
- Toolchain and dependencies required by the benchmark scripts (see the workflow for the authoritative install steps)

> Note: Some TLS/PQC stacks require specific libraries and build flags. The GitHub Actions workflow is the reference configuration.

### Run everything (paper pipeline)
```bash
cd scripts
bash run_all.sh
