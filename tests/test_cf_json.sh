#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/cloudflare.sh"

# Normal kayıt: alanlar doğru yerleşir, geçerli JSON üretir.
body=$(_cf_dns_add_body "A" "www.example.com" "1.2.3.4" "true")
assert_eq "$(echo "$body" | jq -r '.type')"     "A"               "type alanı"
assert_eq "$(echo "$body" | jq -r '.name')"     "www.example.com" "name alanı"
assert_eq "$(echo "$body" | jq -r '.content')"  "1.2.3.4"         "content alanı"
assert_eq "$(echo "$body" | jq -r '.proxied')"  "true"            "proxied boolean"

# Çift tırnak içeren içerik JSON'u BOZMAMALI (enjeksiyon değil, kaçışlı string).
evil='v=spf1 "include:evil" -all'
body=$(_cf_dns_add_body "TXT" "example.com" "$evil" "false")
assert_ok   bash -c "echo '$body' | jq -e . >/dev/null"   "kötü içerikle bile geçerli JSON"
assert_eq "$(echo "$body" | jq -r '.content')" "$evil"    "content tam ve kaçışlı korundu"
assert_eq "$(echo "$body" | jq -r '.proxied')" "false"    "proxied false (TXT)"

rm -rf "$WEB_ROOT"
test_summary
