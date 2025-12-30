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

  find_openssl() {
    for p in /opt/openssl32/bin/openssl /opt/openssl/bin/openssl /usr/local/bin/openssl /usr/bin/openssl /usr/local/ssl/bin/openssl; do
      [ -x "$p" ] && { echo "$p"; return 0; }
    done
    command -v openssl >/dev/null 2>&1 && { command -v openssl; return 0; }
    command -v find >/dev/null 2>&1 || return 1
    f="$(find /opt /usr/local /usr -maxdepth 4 -type f -name openssl 2>/dev/null | head -n 1 || true)"
    [ -n "$f" ] && [ -x "$f" ] && { echo "$f"; return 0; }
    return 1
  }

  OPENSSL="$(find_openssl || true)"
  [ -n "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }
  command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found" 1>&2; exit 127; }

  echo "OPENSSL_BIN=$OPENSSL"
  echo "== openssl =="; "$OPENSSL" version -a | head -n 25 || true
  echo "== providers =="; "$OPENSSL" list -providers || true
  echo

  # 探测一个 PQ 签名算法（优先 ML-DSA，其次 Falcon）
  SIGLIST="$("$OPENSSL" list -signature-algorithms 2>/dev/null || true)"
  pick_pq() {
    for a in mldsa44 mldsa65 mldsa87 falcon512 falcon1024; do
      echo "$SIGLIST" | grep -qiE "(^|[[:space:]])${a}([[:space:]]|$)" && { echo "$a"; return 0; }
    done
    return 1
  }
  PQALG="$(pick_pq || true)"
  [ -n "$PQALG" ] && echo "Selected PQ signature algorithm: $PQALG" || echo "NOTE: no PQ signature alg found; only ECDSA will be benchmarked."
  echo

  python3 - << PY
import os, subprocess, time, tempfile, pathlib

OPENSSL = os.environ.get("OPENSSL_BIN")
BENCH = float(os.environ.get("BENCH_SECONDS","2"))
PQALG = os.environ.get("PQALG","").strip()

def run(cmd, check=False):
  return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=check)

def timed_loop(cmd, seconds):
  n=0
  t0=time.perf_counter()
  while time.perf_counter() - t0 < seconds:
    run(cmd, check=False)
    n += 1
  dt=time.perf_counter() - t0
  return n, (n/dt if dt>0 else float("nan"))

def bench_ecdsa(tmp: pathlib.Path):
  msg = tmp/"msg.bin"; msg.write_bytes(b"x"*32)
  key = tmp/"ecdsa_key.pem"; pub = tmp/"ecdsa_pub.pem"; sig = tmp/"ecdsa.sig"

  run([OPENSSL,"genpkey","-algorithm","EC","-pkeyopt","ec_paramgen_curve:P-256","-out",str(key)], check=True)
  run([OPENSSL,"pkey","-in",str(key),"-pubout","-out",str(pub)], check=True)

  sign_cmd = [OPENSSL,"pkeyutl","-sign","-inkey",str(key),"-in",str(msg),"-out",str(sig)]
  verify_cmd = [OPENSSL,"pkeyutl","-verify","-pubin","-inkey",str(pub),"-in",str(msg),"-sigfile",str(sig)]

  run(sign_cmd, check=True); run(verify_cmd, check=True)
  n_s, ops_s = timed_loop(sign_cmd, BENCH)
  n_v, ops_v = timed_loop(verify_cmd, BENCH)
  print(f"ECDSA_P256 sign_ops_per_s={ops_s:.1f} verify_ops_per_s={ops_v:.1f} (loops sign={n_s} verify={n_v}, seconds={BENCH})")

def bench_pq(tmp: pathlib.Path, alg: str):
  msg = tmp/"msg.bin"; msg.write_bytes(b"x"*32)
  key = tmp/"pq_key.pem"; pub = tmp/"pq_pub.pem"; sig = tmp/"pq.sig"

  gen_cmd = [OPENSSL,"genpkey","-algorithm",alg,"-provider","oqsprovider","-provider","default","-out",str(key)]
  r = run(gen_cmd, check=False)
  if r.returncode != 0:
    print(f"{alg} SKIP (genpkey failed)")
    return

  r = run([OPENSSL,"pkey","-in",str(key),"-pubout","-out",str(pub),"-provider","oqsprovider","-provider","default"], check=False)
  if r.returncode != 0:
    print(f"{alg} SKIP (pubout failed)")
    return

  sign_cmd = [OPENSSL,"pkeyutl","-sign","-inkey",str(key),"-in",str(msg),"-out",str(sig),"-provider","oqsprovider","-provider","default"]
  verify_cmd = [OPENSSL,"pkeyutl","-verify","-pubin","-inkey",str(pub),"-in",str(msg),"-sigfile",str(sig),"-provider","oqsprovider","-provider","default"]

  if run(sign_cmd).returncode != 0:
    print(f"{alg} SKIP (sign failed)")
    return
  if run(verify_cmd).returncode != 0:
    print(f"{alg} SKIP (verify failed)")
    return

  n_s, ops_s = timed_loop(sign_cmd, BENCH)
  n_v, ops_v = timed_loop(verify_cmd, BENCH)
  print(f"{alg} sign_ops_per_s={ops_s:.1f} verify_ops_per_s={ops_v:.1f} (loops sign={n_s} verify={n_v}, seconds={BENCH})")

with tempfile.TemporaryDirectory() as d:
  tmp = pathlib.Path(d)
  bench_ecdsa(tmp)
  if PQALG:
    bench_pq(tmp, PQALG)
PY
' -e OPENSSL_BIN="$(docker run --rm "${IMG}" sh -lc '
  for p in /opt/openssl32/bin/openssl /opt/openssl/bin/openssl /usr/local/bin/openssl /usr/bin/openssl /usr/local/ssl/bin/openssl; do
    [ -x "$p" ] && { echo "$p"; exit 0; }
  done
  command -v openssl >/dev/null 2>&1 && { command -v openssl; exit 0; }
  if command -v find >/dev/null 2>&1; then
    f="$(find /opt /usr/local /usr -maxdepth 4 -type f -name openssl 2>/dev/null | head -n 1 || true)"
    [ -n "$f" ] && [ -x "$f" ] && { echo "$f"; exit 0; }
  fi
  exit 1
')" \
  -e PQALG="$(docker run --rm "${IMG}" sh -lc '
  OPENSSL=""
  for p in /opt/openssl32/bin/openssl /opt/openssl/bin/openssl /usr/local/bin/openssl /usr/bin/openssl /usr/local/ssl/bin/openssl; do
    [ -x "$p" ] && { OPENSSL="$p"; break; }
  done
  [ -z "$OPENSSL" ] && command -v openssl >/dev/null 2>&1 && OPENSSL="$(command -v openssl)"
  [ -z "$OPENSSL" ] && exit 0
  SIGLIST="$("$OPENSSL" list -signature-algorithms 2>/dev/null || true)"
  for a in mldsa44 mldsa65 mldsa87 falcon512 falcon1024; do
    echo "$SIGLIST" | grep -qiE "(^|[[:space:]])${a}([[:space:]]|$)" && { echo "$a"; exit 0; }
  done
  exit 0
')"
