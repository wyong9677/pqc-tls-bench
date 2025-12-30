#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
BENCH_SECONDS="${BENCH_SECONDS:-2}"

echo "=== bench_sig.sh ==="
echo "Image: ${IMG}"
echo "BENCH_SECONDS: ${BENCH_SECONDS}"
echo

docker run --rm -e BENCH_SECONDS="${BENCH_SECONDS}" "${IMG}" sh -lc '
  set -e
  command -v openssl >/dev/null 2>&1
  command -v python3 >/dev/null 2>&1

  echo "== openssl =="; openssl version -a | head -n 25 || true
  echo "== providers =="; openssl list -providers || true
  echo

  # 取签名算法列表（可能为空，做容错）
  SIGLIST="$(openssl list -signature-algorithms 2>/dev/null || true)"
  echo "== signature algorithms (head) =="; echo "$SIGLIST" | head -n 80 || true
  echo

  # 选择一个 PQ 签名算法：优先 mldsa44，其次 falcon512（存在才跑）
  pick_pq() {
    for a in mldsa44 mldsa65 mldsa87 falcon512 falcon1024 sphincssha2128fsimple; do
      echo "$SIGLIST" | grep -qiE "(^|[[:space:]])${a}([[:space:]]|$)" && { echo "$a"; return 0; }
    done
    return 1
  }

  PQALG="$(pick_pq || true)"
  if [ -z "$PQALG" ]; then
    echo "NOTE: no preferred PQ signature algorithm found in this build; will only benchmark ECDSA."
  else
    echo "Selected PQ signature algorithm: $PQALG"
  fi
  echo

  python3 - << PY
import os, subprocess, time, tempfile, pathlib

BENCH = float(os.environ.get("BENCH_SECONDS","2"))

def run(cmd):
  return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

def timed_loop(cmd, seconds):
  n=0
  t0=time.perf_counter()
  while time.perf_counter() - t0 < seconds:
    run(cmd)
    n += 1
  dt=time.perf_counter() - t0
  return n, (n/dt if dt>0 else float("nan"))

def bench_ecdsa(tmp):
  msg = tmp/"msg.bin"; msg.write_bytes(b"x"*32)
  key = tmp/"ecdsa_key.pem"; pub = tmp/"ecdsa_pub.pem"; sig = tmp/"ecdsa.sig"

  # ECDSA P-256 (default provider)
  subprocess.run(["openssl","genpkey","-algorithm","EC","-pkeyopt","ec_paramgen_curve:P-256","-out",str(key)],
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
  subprocess.run(["openssl","pkey","-in",str(key),"-pubout","-out",str(pub)],
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

  sign_cmd = ["openssl","pkeyutl","-sign","-inkey",str(key),"-in",str(msg),"-out",str(sig)]
  verify_cmd = ["openssl","pkeyutl","-verify","-pubin","-inkey",str(pub),"-in",str(msg),"-sigfile",str(sig)]

  # 先做一次确保可用
  subprocess.run(sign_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
  subprocess.run(verify_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

  n_s, ops_s = timed_loop(sign_cmd, BENCH)
  n_v, ops_v = timed_loop(verify_cmd, BENCH)
  print(f"ECDSA_P256 sign_ops_per_s={ops_s:.1f} verify_ops_per_s={ops_v:.1f} (loops sign={n_s} verify={n_v}, seconds={BENCH})")

def bench_pq(tmp, alg):
  msg = tmp/"msg.bin"; msg.write_bytes(b"x"*32)
  key = tmp/"pq_key.pem"; pub = tmp/"pq_pub.pem"; sig = tmp/"pq.sig"

  # PQ key via oqsprovider
  gen_cmd = ["openssl","genpkey","-algorithm",alg,"-provider","oqsprovider","-provider","default","-out",str(key)]
  r = run(gen_cmd)
  if r.returncode != 0:
    print(f"{alg} SKIP (genpkey failed)")
    return

  r = run(["openssl","pkey","-in",str(key),"-pubout","-out",str(pub),"-provider","oqsprovider","-provider","default"])
  if r.returncode != 0:
    print(f"{alg} SKIP (pubout failed)")
    return

  sign_cmd = ["openssl","pkeyutl","-sign","-inkey",str(key),"-in",str(msg),"-out",str(sig),
              "-provider","oqsprovider","-provider","default"]
  verify_cmd = ["openssl","pkeyutl","-verify","-pubin","-inkey",str(pub),"-in",str(msg),"-sigfile",str(sig),
                "-provider","oqsprovider","-provider","default"]

  r = run(sign_cmd)
  if r.returncode != 0:
    print(f"{alg} SKIP (sign failed)")
    return
  r = run(verify_cmd)
  if r.returncode != 0:
    print(f"{alg} SKIP (verify failed)")
    return

  n_s, ops_s = timed_loop(sign_cmd, BENCH)
  n_v, ops_v = timed_loop(verify_cmd, BENCH)
  print(f"{alg} sign_ops_per_s={ops_s:.1f} verify_ops_per_s={ops_v:.1f} (loops sign={n_s} verify={n_v}, seconds={BENCH})")

with tempfile.TemporaryDirectory() as d:
  tmp = pathlib.Path(d)
  bench_ecdsa(tmp)
  pqalg = os.environ.get("PQALG","").strip()
  if pqalg:
    bench_pq(tmp, pqalg)
PY
' -e PQALG="$(docker run --rm "${IMG}" sh -lc 'openssl list -signature-algorithms 2>/dev/null || true' | grep -iEo '(mldsa44|mldsa65|mldsa87|falcon512|falcon1024|sphincssha2128fsimple)' | head -n1 || true)"
