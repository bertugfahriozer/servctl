#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

mkdir -p "${WEB_ROOT}/example.com"
SIDE="$(mktemp -u)"
cat > "${WEB_ROOT}/example.com/.credentials" <<CREDS
PHP_VERSION=8.2
WEB_USER=web_example_com
EVIL=\$(touch ${SIDE})
CREDS

# _domain_row "<dir>/" -> "domain|php|user|ssl|chroot"
row="$(_domain_row "${WEB_ROOT}/example.com/")"
assert_eq "$(echo "$row" | cut -d'|' -f1)" "example.com"      "domain alanı"
assert_eq "$(echo "$row" | cut -d'|' -f2)" "8.2"              "php parse edildi"
assert_eq "$(echo "$row" | cut -d'|' -f3)" "web_example_com"  "user parse edildi"
assert_fail test -e "${SIDE}"  "source değil — yan-etki oluşmadı"

# .credentials yoksa: php/user safe_name'den türetilir
mkdir -p "${WEB_ROOT}/Foo.Bar"
row2="$(_domain_row "${WEB_ROOT}/Foo.Bar/")"
assert_eq "$(echo "$row2" | cut -d'|' -f2)" "${DEFAULT_PHP_VERSION}" "php fallback"
assert_eq "$(echo "$row2" | cut -d'|' -f3)" "web_foo_bar"            "user fallback (safe_name)"

# Stale carryover yok: ilk domain PHP_VERSION=8.2 set etti, ikincide sızmamalı
assert_not_contains "$row2" "8.2" "stale carryover yok"

rm -f "${SIDE}"
rm -rf "$WEB_ROOT"
test_summary
