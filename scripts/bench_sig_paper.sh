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

# ---------------- helpers ----------------
FIND_OPENSSL='
set -e
export LC_ALL=C
OPENSSL=/opt/openssl/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl || true)"
[ -n "$OPENSSL" ] || { echo "ERROR: openssl not found" 1>&2; exit 127; }
echo "$OPENSSL"
'

is_num() {
  awk 'BEGIN{ok=0} { if($0 ~ /^[0-9]+([.][0-9]+)?$/) ok=1 } END{exit(ok?0:1)}' <<<"${1:-}"
}

die() { echo "ERROR: $*" 1>&2; exit 1; }

# PQC: 优先“算法行表格”，否则 fallback “块格式”
parse_pqc() {
  local alg="$1"
  local text="$2"

  if ! awk -v a="$alg" '
      BEGIN{IGNORECASE=1; found=0}
      $1==a && $2 ~ /^[0-9]+([.][0-9]+)?$/ && $3 ~ /^[0-9]+([.][0-9]+)?$/ && $4 ~ /^[0-9]+([.][0-9]+)?$/ {
        print $2 "," $3 "," $4;
        found=1; exit
      }
      END{ if(!found) exit 1 }
    ' <<<"$text"
  then
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

# ECDSA:
# - 若出现 signs/s verifs/s 则按块格式
# - 否则按 OpenSSL ecdsa 表格行： "256 bits ecdsa (nistp256) ... <sign/s> <verify/s>"
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
    return 0
  fi

  # 兼容你贴出的真实格式：取 “256 bits ecdsa (nistp256)” 这一行最后两列
  awk '
    BEGIN{sg=""; vf=""; found=0}
    $1=="256" && $2=="bits" && $3=="ecdsa" {
      # last two fields should be sign/s verify/s
      s=$(NF-1); v=$NF
      if (s ~ /^[0-9]+([.][0-9]+)?$/ && v ~ /^[0-9]+([.][0-9]+)?$/) {
        sg=s; vf=v; found=1; exit
      }
    }
    END{
      if(!found){ print ","; exit 0 }
      print sg "," vf
    }
  ' <<<"$text"
}

# ---------------- runners ----------------
run_speed_pqc() {
  local alg="$1"
  docker run --rm "${IMG}" sh -lc "
    set -e
    export LC_ALL=C
    OPENSSL=\$(${FIND_OPENSSL})
    \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider oqsprovider -provider default ${alg}
  " 2>/dev/null || true
}

run_speed_ecdsa() {
  docker run --rm "${IMG}" sh -lc "
    set -e
    export LC_ALL=C
    OPENSSL=\$(${FIND_OPENSSL})

    if \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider default ecdsap256 >/tmp/out 2>/dev/null; then
      cat /tmp/out
      exit 0
    fi

    \"\$OPENSSL\" speed -seconds ${BENCH_SECONDS} -provider default ecdsa 2>/dev/null || true
  "
}

# ---------------- meta capture ----------------
docker run --rm "${IMG}" sh -lc "
  set -e
  export LC_ALL=C
  OPENSSL=\$(${FIND_OPENSSL})
  echo \"OPENSSL_PATH=\$OPENSSL\"
  \"\$OPENSSL\" version -a || true
  echo
  echo \"== providers ==\"
  \"\$OPENSSL\" list -providers 2>/dev/null || true
" > "${metadir}/openssl_env.txt" 2>&1 || true

# ---------------- warmup ----------------
for _ in $(seq 1 "${WARMUP}"); do
  run_speed_ecdsa >/dev/null 2>&1 || true
  for alg in "mldsa44" "mldsa65" "falcon512" "falcon1024"; do
    run_speed_pqc "$alg" >/dev/null 2>&1 || true
  done
done

# ---------------- benchmark ----------------
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
      IFS=',' read -r sign verify < <(parse_ecdsa "$out")
      keygens=""
    else
      IFS=',' read -r keygens sign verify < <(parse_pqc "${alg}" "$out")
    fi

    # paper 模式：严格数值校验
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

# 末尾复核：paper 模式不允许空字段
if [ "${MODE}" = "paper" ]; then
  awk -F, '
    NR==1{next}
    {
      alg=$4; kg=$5; sg=$6; vf=$7
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
