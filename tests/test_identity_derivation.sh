#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# Bozuk/saldırgan PHP_VERSION içeren .credentials
mkdir -p "${WEB_ROOT}/example.com"
cat > "${WEB_ROOT}/example.com/.credentials" <<CREDS
PHP_VERSION=8.3/../../bin
DB_NAME=evil; DROP DATABASE x
CREDS

# _derive_php: geçersiz versiyon -> fallback'e düşmeli (path/komut enjeksiyonu yok)
assert_eq "$(_derive_php example.com 8.3)" "8.3" "geçersiz PHP_VERSION fallback'e düştü"

# Geçerli versiyon -> aynen döner
mkdir -p "${WEB_ROOT}/ok.com"
cat > "${WEB_ROOT}/ok.com/.credentials" <<CREDS
PHP_VERSION=8.2
CREDS
assert_eq "$(_derive_php ok.com 8.3)" "8.2" "geçerli PHP_VERSION aynen döndü"

# .credentials yok -> fallback
assert_eq "$(_derive_php yok.com 8.1)" "8.1" "credentials yok -> fallback"

# Kimlik türetme: safe_name -> db_/usr_/web_ deterministik
sn="$(safe_name "Foo.Bar")"
assert_eq "$sn"          "foo_bar"      "safe_name"
assert_eq "db_${sn}"     "db_foo_bar"   "db identifier türetildi"
assert_eq "usr_${sn}"    "usr_foo_bar"  "usr identifier türetildi"
assert_eq "web_${sn}"    "web_foo_bar"  "web identifier türetildi"

rm -rf "$WEB_ROOT"
test_summary
