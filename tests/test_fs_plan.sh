#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

out="$(_domain_fs_plan /var/www/example.com web_example_com)"
assert_contains "$out" "/var/www/example.com|root|751"               "base root:root 751"
assert_contains "$out" "/var/www/example.com/public_html|web_example_com|750" "public_html web 750"
assert_contains "$out" "/var/www/example.com/private/writable|web_example_com|770" "writable web 770"
assert_contains "$out" "/var/www/example.com/dev|root|755"           "chroot dev root"
assert_contains "$out" "/var/www/example.com/etc|root|755"           "chroot etc root"
assert_contains "$out" "/var/www/example.com/.credentials|root|600"  "credentials root 600"
assert_contains "$out" "/var/www/example.com/.srvctl-meta|root|644"  "meta root 644"
assert_contains "$out" "/var/www/example.com/.deploy-repo|root|600"  "deploy-repo root 600"
assert_not_contains "$out" "/var/www/example.com|web_example_com"    "base ASLA web değil"

rm -rf "$WEB_ROOT"
test_summary
