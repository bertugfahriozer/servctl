#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

mkdir -p "${WEB_ROOT}/example.com"

# write_meta: yeni anahtar oluşturur
write_meta example.com RATE_PROFILE strict
assert_contains "$(cat "${WEB_ROOT}/example.com/.srvctl-meta")" "RATE_PROFILE=strict" "yeni anahtar yazıldı"

# write_meta: mevcut anahtarı günceller (duplicate yok)
write_meta example.com RATE_PROFILE relaxed
assert_contains "$(cat "${WEB_ROOT}/example.com/.srvctl-meta")" "RATE_PROFILE=relaxed" "anahtar güncellendi"
assert_eq "$(grep -c '^RATE_PROFILE=' "${WEB_ROOT}/example.com/.srvctl-meta")" "1" "duplicate yok"

# read_meta: değişkenleri yükler
unset RATE_PROFILE
write_meta example.com SENSITIVE_PATHS 'login|admin'
read_meta example.com
assert_eq "${RATE_PROFILE:-}"    "relaxed"     "read_meta RATE_PROFILE"
assert_eq "${SENSITIVE_PATHS:-}" "login|admin" "read_meta SENSITIVE_PATHS"

# read_meta: meta yoksa hata vermez
assert_ok read_meta yokboyle.com

rm -rf "$WEB_ROOT"
test_summary
