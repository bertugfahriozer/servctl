#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

# _domain_add CLI yolu, sihirbaz dışı çağrıda validate_domain kapısını uygulamalı.
# Mutasyon komutları (require_root, useradd...) macOS'ta çalışmadığından, kapının
# kendisini ince bir yardımcıyla test ediyoruz: _domain_add_validate_gate <domain>
# -> validate_domain başarısızsa 1 döner (error/exit YOK, predicate gibi davranır).

# İyi domain'ler
assert_ok   _domain_add_validate_gate "example.com"
assert_ok   _domain_add_validate_gate "sub.example.co.uk"

# Kötü domain'ler — path traversal / slash / boş / baştaki nokta
assert_fail _domain_add_validate_gate "bad/../name"
assert_fail _domain_add_validate_gate "a/b"
assert_fail _domain_add_validate_gate ".leadingdot.com"
assert_fail _domain_add_validate_gate "evil;rm -rf"
assert_fail _domain_add_validate_gate ""

rm -rf "$WEB_ROOT"
test_summary
