#!/usr/bin/env bash
set -euo pipefail

: "${OPENSSL_MODULES:?OPENSSL_MODULES not set}"
OPENSSL="${OPENSSL:-openssl}"

echo "[smoke] openssl=$($OPENSSL version)"
echo "[smoke] OPENSSL_MODULES=${OPENSSL_MODULES}"
$OPENSSL list -providers -provider oqsprovider -provider default

work="${1:-/tmp/pqc_sig_smoke}"
mkdir -p "$work"
cd "$work"

printf "hello\n" > msg.bin

# ECDSA P-256 baseline
$OPENSSL genpkey -provider default -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ecdsa_p256.key
$OPENSSL pkey   -provider default -in ecdsa_p256.key -pubout -out ecdsa_p256.pub
$OPENSSL dgst   -provider default -sha256 -sign ecdsa_p256.key -out ecdsa_p256.sig msg.bin
$OPENSSL dgst   -provider default -sha256 -verify ecdsa_p256.pub -signature ecdsa_p256.sig msg.bin

# ML-DSA-44
$OPENSSL genpkey -provider oqsprovider -provider default -algorithm mldsa44 -out mldsa44.key
$OPENSSL pkey   -provider oqsprovider -provider default -in mldsa44.key -pubout -out mldsa44.pub
$OPENSSL pkeyutl -provider oqsprovider -provider default -sign -inkey mldsa44.key -in msg.bin -out mldsa44.sig
$OPENSSL pkeyutl -provider oqsprovider -provider default -verify -pubin -inkey mldsa44.pub -in msg.bin -sigfile mldsa44.sig

echo "[smoke] OK"
