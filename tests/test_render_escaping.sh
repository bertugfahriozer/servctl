#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

tpl="${WEB_ROOT}/v.tpl"
printf 'server_name {{DOMAIN}};\nlocation ~ /{{PATHS}} { return 403; }\n' > "$tpl"

# ── Temiz değerler: substitution çalışır, çıktı doğru ──
out="$(render_template "$tpl" DOMAIN=example.com PATHS='login|admin')"
assert_contains "$out" "server_name example.com;" "temiz DOMAIN yerleşti"
assert_contains "$out" "/login|admin {"           "temiz PATHS yerleşti"
assert_not_contains "$out" "{{DOMAIN}}"           "token kalmadı"

# ── newline içeren değer: render_template EXIT eder (error) ──
# error exit ettiği için ALT-KABUKTA çalıştır; non-zero exit beklenir.
bad_nl="$(printf 'evil\ninjected')"
assert_fail bash -c '
  source "'"${REPO_ROOT}"'/lib/core.sh"
  render_template "'"$tpl"'" DOMAIN="evil
injected"
'
# daha net: değişkenle geçir
assert_fail env BADVAL="$bad_nl" bash -c '
  source "'"${REPO_ROOT}"'/lib/core.sh"
  render_template "'"$tpl"'" DOMAIN="$BADVAL"
'

# ── CR içeren değer de reddedilir ──
bad_cr="$(printf 'evil\rinjected')"
assert_fail env BADVAL="$bad_cr" bash -c '
  source "'"${REPO_ROOT}"'/lib/core.sh"
  render_template "'"$tpl"'" PATHS="$BADVAL"
'

# ── newline reddi çıktı üretmeden olur (dosyaya yazılmaz) ──
out2="$(env BADVAL="$bad_nl" bash -c '
  source "'"${REPO_ROOT}"'/lib/core.sh"
  render_template "'"$tpl"'" DOMAIN="$BADVAL"
' 2>/dev/null)" || true
assert_not_contains "$out2" "injected" "newline değeri çıktıya sızmadı"

rm -rf "$WEB_ROOT"
test_summary
