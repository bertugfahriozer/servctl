#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

# --list tüm profilleri ve değerlerini basar
out=$(_rate_limit_list)
assert_contains "$out" "strict"   "list strict satırı"
assert_contains "$out" "rl_api"   "list api zone"
assert_contains "$out" "100"      "list relaxed conn"

# --show meta'dan profili okur
mkdir -p "${WEB_ROOT}/example.com"
write_meta example.com RATE_PROFILE relaxed
out=$(_domain_rate_limit example.com --show)
assert_contains "$out" "relaxed"     "show profil"
assert_contains "$out" "rl_relaxed"  "show req zone"

rm -rf "$WEB_ROOT"
test_summary
