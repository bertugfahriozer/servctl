#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/init.sh"

out=$(render_ratelimit_zones)
assert_contains "$out" 'zone=rl_strict:10m rate=3r/s'     "rl_strict zone"
assert_contains "$out" 'zone=rl_standard:10m rate=10r/s'  "rl_standard zone"
assert_contains "$out" 'zone=rl_relaxed:10m rate=30r/s'   "rl_relaxed zone"
assert_contains "$out" 'zone=rl_api:10m rate=60r/s'       "rl_api zone"
assert_contains "$out" 'zone=login_strict:10m rate=3r/m'  "login_strict zone"
assert_contains "$out" 'zone=login_standard:10m rate=5r/m' "login_standard zone"
assert_contains "$out" 'zone=login_relaxed:10m rate=10r/m' "login_relaxed zone"
assert_contains "$out" 'limit_req_status 429;'            "429 status"
assert_contains "$out" 'limit_conn_status 429;'           "conn 429 status"
# conn_per_ip nginx.conf'ta zaten tanımlı; burada tekrar tanımlanmamalı
assert_not_contains "$out" 'limit_conn_zone'              "conn_zone tekrar tanımlanmaz"

test_summary
