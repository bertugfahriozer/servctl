#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"

out="$(render_template "${SRVCTL_TEMPLATES}/php-fpm/fpm-global.conf.tpl" \
    DOMAIN=example.com SAFE_NAME=example_com WEB_ROOT=/var/www)"
assert_contains "$out" "[global]"                                  "global bölümü"
assert_contains "$out" "pid = /run/srvctl/fpm-example_com.pid"     "per-domain pid"
assert_contains "$out" "daemonize = no"                            "daemonize no"
assert_contains "$out" "/var/www/example.com/logs/php-fpm-master.log" "master error_log"
assert_not_contains "$out" "{{"                                    "leftover token yok"

rm -rf "$WEB_ROOT"
test_summary
