#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/lib/security.sh"

mkdir -p "${WEB_ROOT}/example.com"/{public_html,private/writable,dev}
echo "x" > "${WEB_ROOT}/example.com/.credentials"

out="$(_harden_fs_dry example.com)"
assert_contains "$out" "example.com"                              "domain başlığı"
assert_contains "$out" "${WEB_ROOT}/example.com -> root:root 751" "base hedefi"
assert_contains "$out" "/public_html -> web_example_com:web_example_com 750" "public_html hedefi"
assert_contains "$out" "/.credentials -> root:root 600"          "credentials hedefi"
# dry-run hiçbir şeyi DEĞİŞTİRMEMELİ: sahiplik hâlâ çalıştıran kullanıcı
assert_eq "$(_stat_owner "${WEB_ROOT}/example.com")" "$(whoami)" "dry-run dokunmadı"
# yok olan domain hata değil, uyarı
assert_ok bash -c "source '${REPO_ROOT}/lib/core.sh'; source '${REPO_ROOT}/lib/domain.sh'; source '${REPO_ROOT}/lib/security.sh'; WEB_ROOT='${WEB_ROOT}' _harden_fs_dry yokboyle.com"

rm -rf "$WEB_ROOT"
test_summary
