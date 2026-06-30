#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

mkdir -p "${WEB_ROOT}/example.com"
# Gerçek .credentials biçimi: düz KEY=value
cat > "${WEB_ROOT}/example.com/.credentials" <<EOF
DOMAIN=example.com
SAFE_NAME=example_com
WEB_USER=web_example_com
PHP_VERSION=8.3
DB_NAME=db_example_com
DB_USER=usr_example_com
DB_PASS=S3cretPass00
REDIS_USER=redis_example_com
REDIS_PASS=R3disPass00
REDIS_PREFIX=example_com
EOF

unset DOMAIN SAFE_NAME WEB_USER PHP_VERSION DB_NAME DB_USER DB_PASS REDIS_USER REDIS_PASS REDIS_PREFIX
read_credentials example.com
assert_eq "${DOMAIN:-}"       "example.com"      "DOMAIN"
assert_eq "${WEB_USER:-}"     "web_example_com"  "WEB_USER"
assert_eq "${PHP_VERSION:-}"  "8.3"              "PHP_VERSION"
assert_eq "${DB_PASS:-}"      "S3cretPass00"     "DB_PASS"
assert_eq "${REDIS_PREFIX:-}" "example_com"      "REDIS_PREFIX"

# ── source EDİLMEMELİ: dosyaya enjekte edilen komut çalışmaz ──
rm -f "${WEB_ROOT}/pwned3"
printf 'EVIL=$(touch %s/pwned3)\n' "$WEB_ROOT" >> "${WEB_ROOT}/example.com/.credentials"
read_credentials example.com
assert_eq "$(test -e "${WEB_ROOT}/pwned3" && echo VAR || echo YOK)" "YOK" "read_credentials source etmiyor"

# meta yoksa hata vermez
assert_ok read_credentials yokboyle.com

rm -rf "$WEB_ROOT"
test_summary
