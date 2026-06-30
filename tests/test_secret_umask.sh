#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# domain.sh'i source et — _domain_write_credentials saf yardımcısı için.
# (cmd_domain require_root çağırır ama biz sadece yardımcıyı çağırıyoruz.)
source "${REPO_ROOT}/lib/domain.sh"

# Helper var mı?
assert_ok declare -F _domain_write_credentials

# Bir domain dizini hazırla
dom="ornek.com"
base="${WEB_ROOT}/${dom}"
mkdir -p "$base"

# Sırrı yaz
_domain_write_credentials "$dom" "$base" "web_ornek_com" "8.3" \
    "db_ornek_com" "usr_ornek_com" "SecretDbPass123" \
    "redis_ornek_com" "SecretRedisPass456" "ornek_com:"

# Dosya 0600 olmalı (sahiplik macOS'ta root olamaz, mod test edilir)
mode="$(_stat_mode "${base}/.credentials")"
assert_eq "$mode" "600" ".credentials modu 0600"

# İçerik düz KEY=value, parolalar yazıldı
content="$(cat "${base}/.credentials")"
assert_contains "$content" "DB_PASS=SecretDbPass123" "DB_PASS yazıldı"
assert_contains "$content" "REDIS_PASS=SecretRedisPass456" "REDIS_PASS yazıldı"
assert_contains "$content" "DOMAIN=ornek.com" "DOMAIN yazıldı"
assert_contains "$content" "REDIS_PREFIX=ornek_com:" "REDIS_PREFIX yazıldı"

rm -rf "$WEB_ROOT"
test_summary
