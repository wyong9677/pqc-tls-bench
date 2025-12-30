#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:?IMG is required}"
RESULTS_DIR="${RESULTS_DIR:-results}"
MODE="${MODE:-paper}"

REPEATS="${REPEATS:-7}"
WARMUP="${WARMUP:-2}"
BENCH_SECONDS="${BENCH_SECONDS:-20}"

if [ "${MODE}" = "smoke" ]; then
  REPEATS=1
  WARMUP=1
  BENCH_SECONDS=5
fi

SIGS=("ecdsap256" "mldsa44" "mldsa65" "falcon512" "falcon1024")

csv="${RESULTS_DIR}/sig_speed.csv"
rawdir="${RESULTS_DIR}/sig_speed_raw"
mkdir -p "${rawdir}"
echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s" > "${csv}"

echo "=== Signature speed (paper-grade) ==="
echo "mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS}"
echo "IMG=${IMG}"
echo

# 在容器里找到 openssl
FIND_OPENSSL='
OPENSSL=/opt/openssl/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
[ -n "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }
echo "$OPENSSL"
'

# 解析 “块格式”：包含 keygens/s signs/s verifs/s
# 通常适用于 PQC alg（以及某些 build 下的 ecdsap256）
parse_block() {
  # 输出: keygens, sign, verify (可能为空)
  awk '
    /keygens\/s/ {kg=$2}
    /signs\/s/  {sg=$2}
    /verifs\/s/ {vf=$2}
    END{
      if(kg=="") kg="";
      if(sg=="") sg="";
      if(vf=="") vf="";
      print kg "," sg "," vf
    }'
}

# 解析 “ECDSA 表格格式” 中 256 bits 的 sign/verify
# 常见行形如：
# sign   256 bits  <num> ...
# verify 256 bits  <num> ...
parse_ecdsa_256_table() {
  awk '
    $1=="sign"   && $2=="256" {sg=$4}
    $1=="verify" && $2=="256" {vf=$4}
    END{
      if(sg=="") sg="";
      if(vf=="") vf="";
      print sg "," vf
    }'
}

# 跑 PQC speed（oqsprovider+default）
run_speed_pqc() {
  local alg="$1"
  docker run --rm "${IMG}" sh -lc "
    set -e
    OPENSSL=\$(${FIND_OPENSSL})
    \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider oqsprovider -provider default ${alg} 2>/dev/null || true
  "
}

# 跑 ECDSA：优先 ecdsap256；失败则 fallback 到 ecdsa 表
run_speed_ecdsa() {
  docker run --rm "${IMG}" sh -lc "
    set -e
    OPENSSL=\$(${FIND_OPENSSL})

    # 尝试 1：某些构建支持 ecdsap256（并可能输出块格式）
    if \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider default ecdsap256 >/tmp/out 2>/dev/null; then
      cat /tmp/out
      exit 0
    fi

    # 尝试 2：通用方式：ecdsa（表格格式）
    \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider default ecdsa 2>/dev/null || true
  "
}

# warmup：对 ECDSA + PQC 都做一轮
for _ in $(seq 1 "${WARMUP}"); do
  run_speed_ecdsa >/dev/null 2>&1 || true
  for alg in "mldsa44" "mldsa65" "falcon512" "falcon1024"; do
    run_speed_pqc "$alg" >/dev/null 2>&1 || true
  done
done

for r in $(seq 1 "${REPEATS}"); do
  for alg in "${SIGS[@]}"; do
    if [ "${alg}" = "ecdsap256" ]; then
      out="$(run_speed_ecdsa || true)"
    else
      out="$(run_speed_pqc "${alg}" || true)"
    fi

    printf "%s\n" "$out" > "${rawdir}/rep${r}_${alg}.txt"

    keygens="" ; sign="" ; verify=""

    if [ "${alg}" = "ecdsap256" ]; then
      # 情况A：输出包含块格式字段（signs/s, verifs/s）
      if printf "%s\n" "$out" | grep -q "signs/s"; then
        IFS=',' read -r keygens sign verify < <(printf "%s\n" "$out" | parse_block)
        keygens=""  # ECDSA 不报告 keygen（避免误导）
      else
        # 情况B：输出为 ecdsa 表格，从 256 bits 抽取
        IFS=',' read -r sign verify < <(printf "%s\n" "$out" | parse_ecdsa_256_table)
        keygens=""
      fi
    else
      # PQC：用块解析
      IFS=',' read -r keygens sign verify < <(printf "%s\n" "$out" | parse_block)
    fi

    # 不再写 nan：解析失败写空字段，更符合数据规范
    if [ -z "${sign}" ] || [ -z "${verify}" ]; then
      echo "rep=${r} alg=${alg} (missing) keygens/s=${keygens:-} sign/s=${sign:-} verify/s=${verify:-}"
      echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens},${sign},${verify}" >> "${csv}"
      continue
    fi

    echo "rep=${r} alg=${alg} keygens/s=${keygens:-} sign/s=${sign} verify/s=${verify}"
    echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens},${sign},${verify}" >> "${csv}"
  done
done

echo
echo "CSV: ${csv}"
echo "Raw: ${rawdir}/rep*_*.txt"
