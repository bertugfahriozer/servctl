#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/backup.sh"

# Call-site sarmalayıcısı var mı?
assert_ok declare -F _backup_restore_files

work="$(mktemp -d)"
dest="$(mktemp -d)"

# 1) Zararsız, RELATİF arşiv → kabul edilmeli ve dest altına çıkmalı
mkdir -p "${work}/iyi/altdizin"
echo "merhaba" > "${work}/iyi/altdizin/dosya.txt"
( cd "$work" && tar czf "${work}/iyi.tar.gz" iyi )
assert_ok _backup_restore_files "${work}/iyi.tar.gz" "$dest"
assert_ok test -f "${dest}/iyi/altdizin/dosya.txt"

# 2) Path-traversal (../) içeren arşiv → reddedilmeli, hedefin DIŞINA yazılmamalı
canary="${dest}/../kacti.txt"
rm -f "$canary"
mkdir -p "${work}/payload"
echo "kotu" > "${work}/payload/kacti.txt"
# ../kacti.txt üyesi üreten arşiv (GNU/BSD tar uyumlu)
( cd "${work}/payload" && tar czf "${work}/slip.tar.gz" -C "${work}/payload" --transform 's,^,../,' kacti.txt 2>/dev/null \
    || tar czf "${work}/slip.tar.gz" -C "${work}" ../payload/kacti.txt 2>/dev/null )
assert_fail _backup_restore_files "${work}/slip.tar.gz" "$dest"
assert_ok test ! -e "$canary"

rm -rf "$WEB_ROOT" "$work" "$dest"
test_summary
