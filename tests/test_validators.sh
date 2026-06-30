#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# ─── validate_domain ───
for good in example.com a.b.c sub-domain.example.co.uk x x9 9x.io; do
    assert_ok validate_domain "$good"
done
for bad in "" "../etc" "a/b" ".leading" "trailing." "a..b" "-bad.com" "bad-.com" "UPPER.com.with space" "$(printf 'a\nb')"; do
    assert_fail validate_domain "$bad"
done
# 253'ten uzun reddedilir
long="$(printf 'a%.0s' {1..254})"
assert_fail validate_domain "$long"

# ─── assert_safe_ident ───
for good in usr_example_com db_x A1_b 0underscore; do assert_ok assert_safe_ident "$good"; done
for bad in "" "a-b" "a.b" "a b" "a;b" 'a$b' "a/b"; do assert_fail assert_safe_ident "$bad"; done

# ─── assert_php_version ───
for good in 8.3 7.4 10.20 5.6; do assert_ok assert_php_version "$good"; done
for bad in "" 8 8.3.1 "8 .3" v8.3 "8.x" "8."; do assert_fail assert_php_version "$bad"; done

# ─── assert_regex_safe (nginx token) ───
for good in 'login|admin' 'wp-login\.php' 'a/b/c' 'auth|panel|dashboard' 'user/login'; do
    assert_ok assert_regex_safe "$good"
done
for bad in "" 'a{1}' 'a}b' 'a;b' 'a b' "$(printf 'a\nb')" 'a$b' 'a"b' 'a*b' 'a(b)'; do
    assert_fail assert_regex_safe "$bad"
done

# ─── validate_username ───
for good in deployer web_example_com a _x ab-c d_e; do assert_ok validate_username "$good"; done
for bad in "" "1user" "-user" "Upper" "a b" "a;b" "$(printf 'x%.0s' {1..33})"; do
    assert_fail validate_username "$bad"
done

# ─── validate_ip_or_cidr ───
for good in 1.2.3.4 10.0.0.0/8 192.168.1.1/32 ::1 2001:db8::1 2001:db8::/32 fe80::1; do
    assert_ok validate_ip_or_cidr "$good"
done
for bad in "" 256.1.1.1 1.2.3 1.2.3.4/33 "1.2.3.4 " "a.b.c.d" "10.0.0.0/-1" "::gggg"; do
    assert_fail validate_ip_or_cidr "$bad"
done

# ─── validate_uint ───
for good in 0 1 65535 2222; do assert_ok validate_uint "$good"; done
for bad in "" -1 1.5 "1 " a1 " 1"; do assert_fail validate_uint "$bad"; done
# üst sınırlı
assert_ok   validate_uint 65535 65535
assert_fail validate_uint 65536 65535
assert_ok   validate_uint 0 100

# ─── validate_country ───
for good in TR US DE GB; do assert_ok validate_country "$good"; done
for bad in "" tr USA T1 "T R" "T"; do assert_fail validate_country "$bad"; done

rm -rf "$WEB_ROOT"
test_summary
