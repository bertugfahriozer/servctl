#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

tmpf="$(mktemp)"
chmod 640 "$tmpf"

# _stat_owner: boş olmayan bir sahip adı döndürür
owner="$(_stat_owner "$tmpf")"
assert_eq "$(test -n "$owner" && echo yes)" "yes" "_stat_owner boş değil"
# çalıştıran kullanıcı sahip olmalı (macOS dev: whoami)
assert_eq "$owner" "$(whoami)" "_stat_owner geçerli sahip"

# _stat_mode: sadece rakamlardan oluşan octal mod döndürür
mode="$(_stat_mode "$tmpf")"
assert_eq "$(test -n "$mode" && echo yes)" "yes" "_stat_mode boş değil"
assert_eq "$(printf '%s' "$mode" | grep -Eqc '^[0-7]+$' >/dev/null; [[ "$mode" =~ ^[0-7]+$ ]] && echo yes)" "yes" "_stat_mode octal"
# chmod 640 → 640 ile bitmeli (macOS '640', GNU '640')
assert_contains "$mode" "640" "_stat_mode 640 modunu okur"

rm -f "$tmpf"
rm -rf "$WEB_ROOT"
test_summary
