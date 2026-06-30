#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/lib/security.sh"

mkdir -p "${WEB_ROOT}/example.com"
out="$(_harden_fpm_dry example.com)"
assert_contains "$out" "example.com"                          "domain"
assert_contains "$out" "srvctl-fpm-example_com.service"       "oluşturulacak unit"
assert_contains "$out" "/etc/srvctl/fpm/example_com.conf"     "oluşturulacak config"
# dry-run hiçbir dosya yazmamalı:
assert_eq "$(ls /etc/srvctl/fpm/example_com.conf 2>/dev/null; echo done)" "done" "dry-run yazmadı"
assert_ok bash -c "source '${REPO_ROOT}/lib/core.sh'; source '${REPO_ROOT}/lib/domain.sh'; source '${REPO_ROOT}/lib/security.sh'; WEB_ROOT='${WEB_ROOT}' _harden_fpm_dry yokboyle.com"

rm -rf "$WEB_ROOT"
test_summary
