#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

rate_profile_load strict
out=$(render_template "${REPO_ROOT}/templates/nginx/vhost.conf.tpl" \
    "DOMAIN=example.com" "SAFE_NAME=example_com" "WEB_ROOT=/var/www" "PHP_VERSION=8.3" \
    "RL_REQ_ZONE=${RL_REQ_ZONE}" "RL_REQ_BURST=${RL_REQ_BURST}" \
    "RL_LOGIN_ZONE=${RL_LOGIN_ZONE}" "RL_LOGIN_BURST=${RL_LOGIN_BURST}" \
    "RL_CONN=${RL_CONN}" "RL_SENSITIVE_PATHS=${DEFAULT_SENSITIVE_PATHS}")

assert_contains "$out" "limit_req zone=rl_strict burst=10 nodelay;" "general limit_req"
assert_contains "$out" "limit_conn conn_per_ip 20;"                 "conn limit"
assert_contains "$out" "limit_req zone=login_strict burst=3 nodelay;" "login limit_req"
assert_contains "$out" 'wp-login\.php'                              "hassas yol regex"
assert_contains "$out" "storage|bootstrap|config"                  "geniş blocked-dir"
assert_not_contains "$out" "{{"                                     "leftover token yok"

# SSL template aynı token'ları çözer
out_ssl=$(render_template "${REPO_ROOT}/templates/nginx/vhost-ssl.conf.tpl" \
    "DOMAIN=example.com" "SAFE_NAME=example_com" "WEB_ROOT=/var/www" "PHP_VERSION=8.3" \
    "RL_REQ_ZONE=${RL_REQ_ZONE}" "RL_REQ_BURST=${RL_REQ_BURST}" \
    "RL_LOGIN_ZONE=${RL_LOGIN_ZONE}" "RL_LOGIN_BURST=${RL_LOGIN_BURST}" \
    "RL_CONN=${RL_CONN}" "RL_SENSITIVE_PATHS=${DEFAULT_SENSITIVE_PATHS}")
assert_contains "$out_ssl" "limit_req zone=rl_strict burst=10 nodelay;" "ssl general limit_req"
assert_not_contains "$out_ssl" "{{" "ssl leftover token yok"

rm -rf "$WEB_ROOT"
test_summary
