#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

mkdir -p "${WEB_ROOT}/example.com"
f="${WEB_ROOT}/example.com/.credentials"
echo "DB_PASS=x" > "$f"   # macOS: kullanıcı-sahipli → assert_root_owned_path 1 döner

# 1) marker YOK + root-owned değil → warn + 0 (migrate edilmemiş, kırılmaz)
assert_ok _require_owned_or_warn example.com "$f"

# 2) marker VAR + root-owned değil → 1 (tamper) ; warn'u stderr'e at, exit yok
mkdir -p "${SRVCTL_STATE_DIR}/example.com"; : > "${SRVCTL_STATE_DIR}/example.com/hardened"
assert_fail _require_owned_or_warn example.com "$f"

# 3) _domain_is_hardened doğru çalışır
assert_ok   _domain_is_hardened example.com
assert_fail _domain_is_hardened yokboyle.com

# 4) assert_root_owned_path stub'lanırsa (root-owned taklidi) → her durumda 0
assert_root_owned_path() { return 0; }
assert_ok _require_owned_or_warn example.com "$f"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
