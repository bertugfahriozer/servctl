#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SITES_AVAILABLE="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
source "${REPO_ROOT}/lib/domain.sh"

mkdir -p "${WEB_ROOT}/example.com"

# 1) Temiz (assert_regex_safe geçen) meta değeri normal şekilde uygulanır.
write_meta example.com SENSITIVE_PATHS 'admin|backend'
_domain_write_vhost example.com 8.3 relaxed http
conf=$(cat "${SITES_AVAILABLE}/example.com.conf")
assert_contains "$conf" 'location ~ ^/(admin|backend) {' "temiz meta sensitive uygulandı"

# 2) Kötü amaçlı meta (boşluk + süslü parantez içeren nginx kaçışı) RENDER'a ULAŞMAMALI.
#    assert_regex_safe reddedince DEFAULT_SENSITIVE_PATHS'e düşülür.
#    Not: template zaten meşru 'deny all' bloğu içerdiğinden o dize değil,
#    enjeksiyona özgü değerler (/pwn, süslü parantez kalıntısı) kontrol edilir.
write_meta example.com SENSITIVE_PATHS 'admin) { deny all; } location ~ /pwn {'
_domain_write_vhost example.com 8.3 relaxed http 2>/dev/null
conf=$(cat "${SITES_AVAILABLE}/example.com.conf")
assert_not_contains "$conf" "/pwn"       "enjekte edilen location bloğu yok"
assert_contains     "$conf" 'wp-login\.php' "varsayılan hassas yollara düşüldü"
assert_not_contains "$conf" "{{"         "leftover token yok"

rm -rf "$WEB_ROOT" "$SITES_AVAILABLE"
test_summary
