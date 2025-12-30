#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"
BENCH_SECONDS="${BENCH_SECONDS:-2}"

# 先跑最小集合，后续你可以扩展
CLASSICAL=("ecdsap256" "ecdsa")
PQC=("mldsa44" "mldsa65" "falcon512" "falcon1024")

echo "=== Signature speed benchmark (smoke) ==="
echo "Image: ${IMG}"
echo "Seconds per test: ${BENCH_SECONDS}"
echo

docker run --rm \
  -e BENCH_SECONDS="${BENCH_SECONDS}" \
  "${IMG}" sh -lc '
    set -e

    echo "== OpenSSL ==" 
    openssl version -a | head -n 40 || true
    echo
    echo "== Providers ==" 
    openssl list -providers || true
    echo

    echo "== Signature algorithms (head) =="
    # 不同 OpenSSL 版本/构建支持的 list 子命令可能不同，所以做容错
    (openssl list -signature-algorithms 2>/dev/null | head -n 120) || true
    echo

    bench_seconds="${BENCH_SECONDS}"

    run_speed () {
      prov="$1"; alg="$2"
      echo "--- ${alg} (${prov}) ---"
      # speed 输出很长，先跑通阶段建议只保留关键行
      # 但为了可复现，仍然保留完整输出
      if openssl speed -seconds "${bench_seconds}" ${prov} "${alg}" 2>/dev/null; then
        echo
        return 0
      else
        echo "skip(${alg}): not supported in this build"
        echo
        return 0
      fi
    }

    # 经典基线：只走 default provider（更稳）
    # 先试 ecdsap256，不行再试 ecdsa
    run_speed "-provider default" "ecdsap256" || true
    run_speed "-provider default" "ecdsa" || true

    # PQC：显式加载 oqsprovider（并保留 default 以支持混合解析）
    for a in mldsa44 mldsa65 falcon512 falcon1024; do
      run_speed "-provider oqsprovider -provider default" "${a}" || true
    done
  '
