#!/usr/bin/env bash
set -euo pipefail

IMG="${IMG:-openquantumsafe/oqs-ossl3:latest}"

echo "=== Host ==="
uname -a || true
echo

echo "=== CPU ==="
lscpu || true
echo

echo "=== Memory ==="
free -h || true
echo

echo "=== Docker ==="
docker --version || true
echo

echo "=== Container sanity (single run) ==="
echo "Image: ${IMG}"
echo

docker run --rm "${IMG}" sh -lc '
  set -e

  find_openssl() {
    for p in \
      /opt/openssl32/bin/openssl \
      /opt/openssl/bin/openssl \
      /usr/local/bin/openssl \
      /usr/bin/openssl \
      /usr/local/ssl/bin/openssl
    do
      [ -x "$p" ] && { echo "$p"; return 0; }
    done
    command -v openssl >/dev/null 2>&1 && { command -v openssl; return 0; }
    if command -v find >/dev/null 2>&1; then
      f="$(find /opt /usr/local /usr -maxdepth 6 -type f -name openssl 2>/dev/null | head -n 1 || true)"
      [ -n "$f" ] && [ -x "$f" ] && { echo "$f"; return 0; }
    fi
    return 1
  }

  OPENSSL="$(find_openssl || true)"
  if [ -z "$OPENSSL" ]; then
    echo "ERROR: openssl not found in container PATH or common locations." 1>&2
    exit 127
  fi

  echo "OPENSSL_BIN=$OPENSSL"
  echo

  echo "== openssl version (head) =="
  "$OPENSSL" version -a | head -n 60 || true
  echo

  echo "== providers =="
  "$OPENSSL" list -providers || true
  echo

  echo "== list help (head) =="
  # 关键：看该 openssl 支持哪些 list 子命令/选项，便于兼容 groups 输出差异
  "$OPENSSL" list -help 2>&1 | head -n 120 || true
  echo

  echo "== tls groups candidate 1: list -groups =="
  # 不要吞 stderr，否则你看不到“该子命令不可用/需要 provider”的错误
  "$OPENSSL" list -groups 2>&1 | head -n 200 || true
  echo

  echo "== tls groups candidate 2: list -tls-groups =="
  "$OPENSSL" list -tls-groups 2>&1 | head -n 200 || true
  echo

  echo "== tls groups candidate 3: list -cipher-groups =="
  "$OPENSSL" list -cipher-groups 2>&1 | head -n 200 || true
  echo

  echo "== signature algorithms (head) =="
  "$OPENSSL" list -signature-algorithms 2>&1 | head -n 200 || true
  echo

  echo "== python3 =="
  python3 --version 2>&1 || true
'
