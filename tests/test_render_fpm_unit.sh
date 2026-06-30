#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
source "${REPO_ROOT}/lib/domain.sh"

_domain_render_fpm_unit example.com 8.3

conf="$(cat "${SRVCTL_FPM_DIR}/example_com.conf")"
assert_contains "$conf" "[global]"                       "config global bölümü"
assert_contains "$conf" "[example_com]"                  "config pool bölümü (pool.conf.tpl)"
assert_contains "$conf" "user = web_example_com"         "pool user web_user"
assert_contains "$conf" "php8.3-fpm-example_com.sock"    "socket yolu (değişmez)"
assert_not_contains "$conf" "{{"                         "config leftover token yok"

unit="$(cat "${SRVCTL_SYSTEMD_DIR}/srvctl-fpm-example_com.service")"
assert_contains "$unit" "Slice=srvctl-example_com.slice"      "unit slice"
assert_contains "$unit" "AppArmorProfile=srvctl-example_com"  "unit apparmor"
assert_contains "$unit" "php-fpm8.3"                          "unit php sürümü"

rm -rf "$WEB_ROOT" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR"
test_summary
