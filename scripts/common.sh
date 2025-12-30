#!/usr/bin/env bash
set -euo pipefail

find_openssl_in_container() {
  docker run --rm "${IMG}" sh -lc '
    for p in /opt/openssl/bin/openssl /opt/openssl32/bin/openssl /usr/local/bin/openssl /usr/bin/openssl /usr/local/ssl/bin/openssl; do
      [ -x "$p" ] && { echo "$p"; exit 0; }
    done
    command -v openssl >/dev/null 2>&1 && { command -v openssl; exit 0; }
    exit 1
  '
}
