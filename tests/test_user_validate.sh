#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/user.sh"

# Geçerli kullanıcı adları
assert_ok   _user_add_validate_gate "deployer"
assert_ok   _user_add_validate_gate "ci_bot-1"
assert_ok   _user_add_validate_gate "_svc"

# Geçersiz: path traversal, boşluk, sudoers enjeksiyonu, büyük harf, baştaki rakam, 32+
assert_fail _user_add_validate_gate "../root"
assert_fail _user_add_validate_gate "a b"
assert_fail _user_add_validate_gate "x ALL=(root)"
assert_fail _user_add_validate_gate "Admin"
assert_fail _user_add_validate_gate "1abc"
assert_fail _user_add_validate_gate ""
assert_fail _user_add_validate_gate "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  # 35 > 32

rm -rf "$WEB_ROOT"
test_summary
