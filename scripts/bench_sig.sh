#!/usr/bin/env bash
set -euo pipefail

IMG="openquantumsafe/oqs-ossl3:latest"
SECONDS="${SECONDS:-5}"

# 先跑最稳的：ECDSA
# PQ 签名是否支持要看镜像内 openssl speed 是否识别；先尝试，不识别就 skip
SIGS=("ecdsap256" "mldsa44" "mldsa65" "falcon512" "falcon1024")

echo "=== Signature speed benchmark (seconds=${SECONDS}) ==="
docker run --rm "$IMG" sh -lc "
  openssl version -a || true
  echo
  for a in ${SIGS[*]}; do
    echo \"--- openssl speed \$a ---\"
    openssl speed -seconds $SECONDS -provider oqsprovider -provider default \$a 2>/dev/null \
      || echo \"skip(\$a): not supported\"
    echo
  done
"
