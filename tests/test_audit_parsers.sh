#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/security.sh"

AA="apparmor module is loaded.
3 profiles are loaded.
2 profiles are in enforce mode.
   /usr/sbin/php-fpm8.3
   srvctl-example_com
1 profiles are in complain mode.
   srvctl-other_com
0 processes are unconfined"

assert_ok   _audit_aa_enforced "$AA" "srvctl-example_com"   "enforce'da → ok"
assert_fail _audit_aa_enforced "$AA" "srvctl-other_com"     "complain'de → fail"
assert_fail _audit_aa_enforced "$AA" "srvctl-yok_com"       "yok → fail"

assert_ok   _audit_seccomp_filtered "$(printf 'Name:\tphp-fpm8.3\nSeccomp:\t2\n')"  "Seccomp 2 → ok"
assert_fail _audit_seccomp_filtered "$(printf 'Seccomp:\t0\n')"                     "Seccomp 0 → fail"
assert_fail _audit_seccomp_filtered "$(printf 'Name:\tx\n')"                        "Seccomp satırı yok → fail"

assert_ok   _audit_in_slice "/srvctl.slice/srvctl-example_com.slice/srvctl-fpm-example_com.service" "srvctl-example_com.slice" "slice içinde → ok"
assert_fail _audit_in_slice "/system.slice/php8.3-fpm.service" "srvctl-example_com.slice"            "slice değil → fail"

rm -rf "$WEB_ROOT"
test_summary
