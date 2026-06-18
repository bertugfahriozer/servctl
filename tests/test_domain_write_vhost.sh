#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SITES_AVAILABLE="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
# core.sh SRVCTL_TEMPLATES'i sabit yola atar; test için repo templates klasörüne yönlendir
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
source "${REPO_ROOT}/lib/domain.sh"

mkdir -p "${WEB_ROOT}/example.com"

_domain_write_vhost example.com 8.3 relaxed http
conf=$(cat "${SITES_AVAILABLE}/example.com.conf")
assert_contains "$conf" "limit_req zone=rl_relaxed burst=50 nodelay;" "relaxed profil uygulandı"
assert_contains "$conf" "limit_conn conn_per_ip 100;"                 "relaxed conn"
assert_not_contains "$conf" "{{"                                      "leftover token yok"

# Meta'daki SENSITIVE_PATHS override edilir
write_meta example.com SENSITIVE_PATHS 'admin|backend'
_domain_write_vhost example.com 8.3 relaxed http
conf=$(cat "${SITES_AVAILABLE}/example.com.conf")
assert_contains "$conf" 'location ~ ^/(admin|backend) {' "meta sensitive override"

rm -rf "$WEB_ROOT" "$SITES_AVAILABLE"
test_summary
