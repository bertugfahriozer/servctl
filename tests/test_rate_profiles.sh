#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# rate_profile_field: standard profili doğru alanlar
assert_eq "$(rate_profile_field standard 2)" "rl_standard" "standard req_zone"
assert_eq "$(rate_profile_field standard 3)" "20"          "standard req_burst"
assert_eq "$(rate_profile_field standard 6)" "50"          "standard conn"
assert_eq "$(rate_profile_field api 4)"      "login_relaxed" "api login_zone"

# rate_profile_resolve: bilinmeyen → standard
assert_eq "$(rate_profile_resolve bilinmeyen 2>/dev/null)" "standard" "geçersiz→standard"
assert_eq "$(rate_profile_resolve strict 2>/dev/null)"     "strict"   "geçerli korunur"
assert_eq "$(rate_profile_resolve '' 2>/dev/null)"         "standard" "boş→standard"

# rate_profile_names: 4 profil
assert_eq "$(rate_profile_names | tr '\n' ' ')" "strict standard relaxed api " "profil adları"

# rate_profile_load: global RL_* değişkenleri
rate_profile_load relaxed
assert_eq "$RL_REQ_ZONE"   "rl_relaxed"   "load req_zone"
assert_eq "$RL_REQ_BURST"  "50"           "load req_burst"
assert_eq "$RL_LOGIN_ZONE" "login_relaxed" "load login_zone"
assert_eq "$RL_CONN"       "100"          "load conn"

rm -rf "$WEB_ROOT"
test_summary
