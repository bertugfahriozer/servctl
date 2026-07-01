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

# ── render_realip ──
printf '173.245.48.0/20\n2400:cb00::/32\n' > "${WORK}/cf"
r="$(_trusted_render_realip "${WORK}/cf")"
assert_contains "$r" "set_real_ip_from 173.245.48.0/20;" "v4 set_real_ip_from"
assert_contains "$r" "set_real_ip_from 2400:cb00::/32;" "v6 set_real_ip_from"
assert_contains "$r" "real_ip_header CF-Connecting-IP;" "real_ip_header satırı"

# ── compute_ignoreip: dedup + tek satır ──
printf '1.1.1.1\n2.2.2.2\n' > "${WORK}/a"
printf '2.2.2.2\n3.3.3.3\n' > "${WORK}/b"
line="$(_trusted_compute_ignoreip "127.0.0.1/8" "${WORK}/a" "${WORK}/b")"
assert_contains "$line" "127.0.0.1/8" "base var"
assert_contains "$line" "3.3.3.3" "b'den IP var"
assert_eq "$(printf '%s\n' "$line" | grep -o '2\.2\.2\.2' | wc -l | tr -d ' ')" "1" "dedup: 2.2.2.2 bir kez"
assert_eq "$(printf '%s' "$line" | grep -c '')" "1" "tek satır (yeni-satır yok)"

rm -rf "$WORK"
test_summary
