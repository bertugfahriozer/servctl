#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# secure_file: yoksa oluşturur, varsayılan 600
f="${WEB_ROOT}/secret.cred"
assert_ok secure_file "$f"
assert_eq "$(test -f "$f" && echo VAR || echo YOK)" "VAR" "secure_file oluşturdu"
assert_eq "$(_stat_mode "$f" | tail -c 4)" "600" "secure_file varsayılan mod 600"

# secure_file: özel mod
f2="${WEB_ROOT}/secret2.cred"
secure_file "$f2" 640
assert_eq "$(_stat_mode "$f2" | tail -c 4)" "640" "secure_file özel mod 640"

# secure_file: var olan dosyanın modunu düzeltir
f3="${WEB_ROOT}/loose.cred"; : > "$f3"; chmod 666 "$f3"
secure_file "$f3"
assert_eq "$(_stat_mode "$f3" | tail -c 4)" "600" "secure_file gevşek modu sıkılaştırır"

# secure_dir: yoksa oluşturur, varsayılan 700
d="${WEB_ROOT}/vault"
assert_ok secure_dir "$d"
assert_eq "$(test -d "$d" && echo VAR || echo YOK)" "VAR" "secure_dir oluşturdu"
assert_eq "$(_stat_mode "$d" | tail -c 4)" "700" "secure_dir varsayılan mod 700"

# secure_dir: özel mod + iç içe (mkdir -p)
d2="${WEB_ROOT}/a/b/c"
secure_dir "$d2" 750
assert_eq "$(test -d "$d2" && echo VAR || echo YOK)" "VAR" "secure_dir iç içe oluşturdu"
assert_eq "$(_stat_mode "$d2" | tail -c 4)" "750" "secure_dir özel mod 750"

rm -rf "$WEB_ROOT"
test_summary
