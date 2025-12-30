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
metadir="${RESULTS_DIR}/meta"
mkdir -p "${rawdir}" "${metadir}"

echo "repeat,mode,seconds,alg,keygens_s,sign_s,verify_s" > "${csv}"

echo "=== Signature speed (paper-grade, audited) ==="
echo "mode=${MODE} repeats=${REPEATS} warmup=${WARMUP} seconds=${BENCH_SECONDS}"
echo "IMG=${IMG}"
echo

# ---------- helpers ----------
# 在容器中定位 openssl，可复用
FIND_OPENSSL='
set -e
export LC_ALL=C
OPENSSL=/opt/openssl/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
[ -n "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }
echo "$OPENSSL"
'

# 纯数字（整数或小数），不接受科学计数法
is_num() {
  awk 'BEGIN{ok=0} { if($0 ~ /^[0-9]+([.][0-9]+)?$/) ok=1 } END{exit(ok?0:1)}' <<<"${1:-}"
}

die() { echo "ERROR: $*" 1>&2; exit 1; }

# 解析 PQC 输出：
# 1) 优先匹配按算法行的表格格式：alg keygen sign verify
# 2) 否则回退到包含 "keygens/s","signs/s","verifs/s" 的块格式
parse_pqc() {
  local alg="$1"
  local text="$2"

  # 尝试表格格式
  if ! awk -v a="$alg" '
      BEGIN{IGNORECASE=1; found=0}
      $1==a && $2 ~ /^[0-9]+([.][0-9]+)?$/ && $3 ~ /^[0-9]+([.][0-9]+)?$/ && $4 ~ /^[0-9]+([.][0-9]+)?$/ {
        print $2 "," $3 "," $4;
        found=1;
        exit
      }
      END{ if(!found) exit 1 }
    ' <<<"$text"
  then
    # 回退到块格式
    awk '
      /keygens\/s/ { if($2 ~ /^[0-9]+([.][0-9]+)?$/) kg=$2 }
      /signs\/s/  { if($2 ~ /^[0-9]+([.][0-9]+)?$/) sg=$2 }
      /verifs\/s/ { if($2 ~ /^[0-9]+([.][0-9]+)?$/) vf=$2 }
      END{
        if(kg=="") kg="";
        if(sg=="") sg="";
        if(vf=="") vf="";
        print kg "," sg "," vf
      }
    ' <<<"$text"
  fi
}

# 解析 ECDSA 输出：
# - 如果有 "signs/s" 字样，按块格式取 signs/verifs
# - 否则按 ecdsa 表格中 "sign 256 bits num"/"verify 256 bits num" 取
parse_ecdsa() {
  local text="$1"
  if grep -q "signs/s" <<<"$text"; then
    awk '
      /signs\/s/  { if($2 ~ /^[0-9]+([.][0-9]+)?$/) sg=$2 }
      /verifs\/s/ { if($2 ~ /^[0-9]+([.][0-9]+)?$/) vf=$2 }
      END{
        if(sg=="") sg="";
        if(vf=="") vf="";
        print sg "," vf
      }
    ' <<<"$text"
  else
    awk '
      $1=="sign"   && $2=="256" && $4 ~ /^[0-9]+([.][0-9]+)?$/ {sg=$4}
      $1=="verify" && $2=="256" && $4 ~ /^[0-9]+([.][0-9]+)?$/ {vf=$4}
      END{
        if(sg=="") sg="";
        if(vf=="") vf="";
        print sg "," vf
      }
    ' <<<"$text"
  fi
}

# 跑 PQC（oqsprovider + default）
run_speed_pqc() {
  local alg="$1"
  docker run --rm "${IMG}" sh -lc "
    set -e
    export LC_ALL=C
    OPENSSL=\$(${FIND_OPENSSL})
    \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider oqsprovider -provider default ${alg}
  " 2>/dev/null || true
}

# 跑 ECDSA：先试 ecdsap256，再回退 ecdsa 表
run_speed_ecdsa() {
  docker run --rm "${IMG}" sh -lc "
    set -e
    export LC_ALL=C
    OPENSSL=\$(${FIND_OPENSSL})

    # attempt 1: ecdsap256，如果支持则优先使用
    if \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider default ecdsap256 >/tmp/out 2>/dev/null; then
      cat /tmp/out
      exit 0
    fi

    # attempt 2: 泛用 ecdsa 表格
    \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider default ecdsa 2>/dev/null || true
  "
}

# ---------- meta capture (作为审稿证据) ----------
docker run --rm "${IMG}" sh -lc "
  set -e
  export LC_ALL=C
  OPENSSL=\$(${FIND_OPENSSL})
  echo \"OPENSSL_PATH=\$OPENSSL\"
  \"\$OPENSSL\" version -a || true
  echo
  echo \"== providers ==\"
  \"\$OPENSSL\" list -providers 2>/dev/null || true
  echo
  echo \"== algorithms (public-key) ==\"
  \"\$OPENSSL\" list -public-key-algorithms 2>/dev/null || true
" > "${metadir}/openssl_env.txt" 2>&1 || true

# ---------- warmup ----------
for _ in $(seq 1 "${WARMUP}"); do
  run_speed_ecdsa >/dev/null 2>&1 || true
  for alg in "mldsa44" "mldsa65" "falcon512" "falcon1024"; do
    run_speed_pqc "$alg" >/dev/null 2>&1 || true
  done
done

# ---------- benchmark ----------
for r in $(seq 1 "${REPEATS}"); do
  for alg in "${SIGS[@]}"; do
    if [ "${alg}" = "ecdsap256" ]; then
      out="$(run_speed_ecdsa || true)"
    else
      out="$(run_speed_pqc "${alg}" || true)"
    fi

    # 保存原始输出，方便 debug / 佐证
    printf "%s\n" "$out" > "${rawdir}/rep${r}_${alg}.txt"

    keygens="" ; sign="" ; verify=""

    if [ "${alg}" = "ecdsap256" ]; then
      IFS=',' read -r sign verify < <(parse_ecdsa "$out")
      keygens=""  # ECDSA 不做 keygen 统计
    else
      IFS=',' read -r keygens sign verify < <(parse_pqc "${alg}" "$out")
    fi

    # paper 模式下严格校验：不允许空值/非数字悄悄混入 CSV
    if [ "${MODE}" = "paper" ]; then
      if [ "${alg}" = "ecdsap256" ]; then
        is_num "${sign:-}"   || die "ECDSA sign missing/non-numeric (rep=${r}). See ${rawdir}/rep${r}_${alg}.txt"
        is_num "${verify:-}" || die "ECDSA verify missing/non-numeric (rep=${r}). See ${rawdir}/rep${r}_${alg}.txt"
      else
        is_num "${keygens:-}" || die "${alg} keygens missing/non-numeric (rep=${r}). See ${rawdir}/rep${r}_${alg}.txt"
        is_num "${sign:-}"    || die "${alg} sign missing/non-numeric (rep=${r}). See ${rawdir}/rep${r}_${alg}.txt"
        is_num "${verify:-}"  || die "${alg} verify missing/non-numeric (rep=${r}). See ${rawdir}/rep${r}_${alg}.txt"
      fi
    fi

    echo "rep=${r} alg=${alg} keygens/s=${keygens:-} sign/s=${sign:-} verify/s=${verify:-}"
    echo "${r},${MODE},${BENCH_SECONDS},${alg},${keygens},${sign},${verify}" >> "${csv}"
  done
done

# ---------- post-check ----------
if [ "${MODE}" = "paper" ]; then
  # 再次扫一遍 CSV，确保没有空 numeric 字段
  awk -F, '
    NR==1{next}
    {
      alg=$4
      kg=$5; sg=$6; vf=$7
      if (alg=="ecdsap256") {
        if (sg=="" || vf=="") { print "BAD ECDSA row at line " NR > "/dev/stderr"; exit 2 }
      } else {
        if (kg=="" || sg=="" || vf=="") { print "BAD PQC row at line " NR " alg=" alg > "/dev/stderr"; exit 2 }
      }
    }
  ' "${csv}"
fi

echo
echo "CSV: ${csv}"
echo "Raw: ${rawdir}/rep*_*.txt"
echo "Meta: ${metadir}/openssl_env.txt"
