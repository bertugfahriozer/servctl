#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"

out="$(render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-fpm.service.tpl" \
    DOMAIN=example.com SAFE_NAME=example_com PHP_VERSION=8.3)"
assert_contains "$out" "Slice=srvctl-example_com.slice"            "cgroups slice"
assert_contains "$out" "AppArmorProfile=srvctl-example_com"        "AppArmor attach"
assert_contains "$out" "ExecStart=/usr/sbin/php-fpm8.3 --nodaemonize --fpm-config /etc/srvctl/fpm/example_com.conf" "ExecStart php sürümü"
assert_contains "$out" "Description=srvctl PHP-FPM (example.com)"  "açıklama"
assert_contains "$out" "ExecReload=/bin/kill -USR2 \$MAINPID"      "MAINPID korunur (token değil)"
assert_not_contains "$out" "{{"                                    "leftover token yok"

rm -rf "$WEB_ROOT"
test_summary
