#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

# Tüm varsayılanlar (boş satırlar) + confirm=evet.
# Process substitution (< <(...)) kullanılır: redirect subshell YARATMAZ, böylece
# WIZ_* global'leri mevcut shell'de kalır ve assert edilebilir. (Pipe `|` subshell yaratır — kullanma.)
_domain_wizard_collect < <(printf 'example.com\n\n\n\n\nevet\n') >/dev/null 2>&1
rc_default=$?
assert_eq "$rc_default"    "0"                            "varsayılan akış rc=0"
assert_eq "$WIZ_DOMAIN"    "example.com"                  "wizard domain"
assert_eq "$WIZ_PHP"       "${DEFAULT_PHP_VERSION}"       "wizard php varsayılan"
assert_eq "$WIZ_PROFILE"   "standard"                     "wizard profil varsayılan"
assert_eq "$WIZ_SSL"       "evet"                         "wizard ssl varsayılan"
assert_eq "$WIZ_SENSITIVE" "${DEFAULT_SENSITIVE_PATHS}"   "wizard hassas varsayılan"

# Özel değerler + iptal (confirm=hayır → return 1)
_domain_wizard_collect < <(printf 'site.com\n8.2\nstrict\nhayir\nadmin|x\nhayır\n') >/dev/null 2>&1
rc_cancel=$?
assert_eq "$rc_cancel"    "1"          "iptal → rc=1"
assert_eq "$WIZ_DOMAIN"   "site.com"   "iptal öncesi domain set edilmiş"
assert_eq "$WIZ_PROFILE"  "strict"     "iptal öncesi profil set edilmiş"

rm -rf "$WEB_ROOT"
test_summary
