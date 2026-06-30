#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/backup.sh"

assert_ok declare -F _backup_files_tar

dom="ornek.com"
base="${WEB_ROOT}/${dom}"
mkdir -p "${base}/public_html"
echo "<?php" > "${base}/public_html/index.php"
echo "DB_PASS=GIZLI" > "${base}/.credentials"
echo "RATE_PROFILE=standard" > "${base}/.srvctl-meta"

out="$(mktemp -d)/files.tar.gz"
_backup_files_tar "$dom" "$WEB_ROOT" "$out"

assert_ok test -f "$out"
members="$(tar -tzf "$out" 2>/dev/null)"

# public_html girmeli, sır/kontrol dosyaları girMEmeli
assert_contains "$members" "${dom}/public_html/index.php" "public_html arşivde"
assert_not_contains "$members" ".credentials" ".credentials arşivde DEĞİL"
assert_not_contains "$members" ".srvctl-meta" ".srvctl-meta arşivde DEĞİL"

# Relatif yol: hiçbir üye '/' ile başlamamalı (safe_extract uyumu)
assert_not_contains "$members" "/${dom}/" "üyeler mutlak yol DEĞİL"
first_char="$(printf '%s\n' "$members" | head -1 | cut -c1)"
# first_char tek karakter; '/' olmamalı. İlk üye '${dom}' ile başlamalı.
assert_not_contains "$first_char" "/" "ilk üye '/' ile başlamıyor (relatif)"
assert_contains "$(printf '%s\n' "$members" | head -1)" "$dom" "ilk üye relatif (${dom}...)"

rm -rf "$WEB_ROOT" "$(dirname "$out")"
test_summary
