#!/usr/bin/env bash
set -euo pipefail

IMG="openquantumsafe/oqs-ossl3:latest"
SIGS=("ecdsap256" "mldsa44" "mldsa65" "falcon512")

docker run --rm "$IMG" sh -lc "
for s in ${SIGS[*]}; do
  echo \"--- openssl speed \$s ---\"
  openssl speed -seconds 5 \$s || echo skip
  echo
done
"
