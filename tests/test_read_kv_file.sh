#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

kvf="${WEB_ROOT}/sample.kv"
cat > "$kvf" <<EOF
DOMAIN=example.com
SAFE_NAME=example_com
DB_PASS=Abc123XYZ
IGNORED=should_not_be_read
SENSITIVE_PATHS=login|admin|wp-login\.php
EOF

# Whitelist anahtarları çıkarılır, IGNORED okunmaz
unset DOMAIN SAFE_NAME DB_PASS SENSITIVE_PATHS IGNORED
read_kv_file "$kvf" DOMAIN SAFE_NAME DB_PASS SENSITIVE_PATHS
assert_eq "${DOMAIN:-}"         "example.com"  "DOMAIN okundu"
assert_eq "${SAFE_NAME:-}"      "example_com"  "SAFE_NAME okundu"
assert_eq "${DB_PASS:-}"        "Abc123XYZ"    "DB_PASS okundu"
# değer '=' veya '|' içerse bile ilk '='ten sonrası verbatim
assert_eq "${SENSITIVE_PATHS:-}" 'login|admin|wp-login\.php' "SENSITIVE_PATHS verbatim"
# whitelist'te olmayan anahtar ortama sızmaz
assert_eq "${IGNORED:-UNSET}"   "UNSET"        "IGNORED set edilmedi"

# Eksik anahtar mevcut değişkene dokunmaz
MISSING_KEY="onceki_deger"
read_kv_file "$kvf" MISSING_KEY
assert_eq "${MISSING_KEY}" "onceki_deger" "eksik anahtar dokunulmadı"

# read_kv_file her zaman 0 döner (eksik dosyada bile)
assert_ok read_kv_file "${WEB_ROOT}/yokboyle.kv" DOMAIN

# ── KRİTİK: komut-subst payload'ı ASLA çalışmaz ──
rm -f "${WEB_ROOT}/pwned"
evil="${WEB_ROOT}/evil.kv"
cat > "$evil" <<EOF
DOMAIN=safe.com
EVIL=\$(touch ${WEB_ROOT}/pwned)
DB_PASS=\`touch ${WEB_ROOT}/pwned2\`
EOF
unset DOMAIN EVIL DB_PASS
read_kv_file "$evil" DOMAIN EVIL DB_PASS
# yan-etki dosyaları OLUŞMAMALI
assert_eq "$(test -e "${WEB_ROOT}/pwned"  && echo VAR || echo YOK)" "YOK" "\$() çalışmadı"
assert_eq "$(test -e "${WEB_ROOT}/pwned2" && echo VAR || echo YOK)" "YOK" "backtick çalışmadı"
# EVIL/DB_PASS değeri ham metin olarak alınır (çalıştırılmaz)
assert_eq "${DOMAIN:-}" "safe.com" "evil dosyadan DOMAIN ham okundu"
assert_contains "${EVIL:-}" 'touch' "EVIL ham metin (çalışmadı)"

rm -rf "$WEB_ROOT"
test_summary
