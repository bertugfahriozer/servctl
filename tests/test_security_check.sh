#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/security.sh"

# _security_run_check <on_ok_fn> <on_bad_fn> <cmd...>: cmd'yi eval'siz, dogrudan calistirir.
ok()  { echo "OK:$1"; }
bad() { echo "BAD:$1"; }

# Komut başarılı -> on_ok çağrılır
assert_eq "$(_security_run_check ok bad 'doğru kontrol' true)"  "OK:doğru kontrol"  "başarı -> on_ok"
# Komut başarısız -> on_bad çağrılır
assert_eq "$(_security_run_check ok bad 'yanlış kontrol' false)" "BAD:yanlış kontrol" "başarısızlık -> on_bad"

# KRİTİK: argüman eval EDİLMEMELİ. Bir arg olarak komut-subst payload'ı versek bile
# çalışmamalı; düz argv olarak 'test' programına gider.
SIDE="$(mktemp -u)"
# 'test -e <olmayan>' false döner -> bad; ama hicbir sekilde touch CALISMAMALI
_security_run_check ok bad 'enjeksiyon denemesi' test -e "\$(touch ${SIDE})" >/dev/null 2>&1 || true
assert_fail test -e "${SIDE}"  "argümanlar eval edilmedi (yan-etki yok)"

rm -f "${SIDE}"
rm -rf "$WEB_ROOT"
test_summary
