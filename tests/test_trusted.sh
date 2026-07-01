#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/trusted.sh"

WORK="$(mktemp -d)"

# ── parse_validate: çöp ayıklama ──
cat > "${WORK}/raw" <<'RAW'
173.245.48.0/20
# yorum satırı
103.21.244.0/22

not-an-ip
2400:cb00::/32
999.999.1.1
198.51.100.7
RAW
out="$(_trusted_parse_validate "${WORK}/raw")"
assert_contains "$out" "173.245.48.0/20" "geçerli v4 CIDR geçer"
assert_contains "$out" "198.51.100.7" "geçerli v4 IP geçer"
assert_contains "$out" "2400:cb00::/32" "geçerli v6 CIDR geçer"
assert_not_contains "$out" "not-an-ip" "geçersiz satır ayıklanır"
assert_not_contains "$out" "999.999" "aralık-dışı v4 ayıklanır"
assert_not_contains "$out" "yorum" "yorum ayıklanır"

# ── sane ──
printf 'a\nb\nc\n' > "${WORK}/three"
assert_ok   _trusted_sane 2 "${WORK}/three"
assert_fail _trusted_sane 5 "${WORK}/three"
: > "${WORK}/empty"
assert_fail _trusted_sane 1 "${WORK}/empty"
assert_fail _trusted_sane 1 "${WORK}/yok-dosya"

rm -rf "$WORK"
test_summary
