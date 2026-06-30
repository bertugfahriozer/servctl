#!/bin/bash
# T5.1 — _webhook_verify_sig birim testleri (root/socat/nginx gerektirmez)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
# lib/webhook.sh source'lanır: cmd_webhook require_root içerir ama yalnızca
# çağrıldığında çalışır; source sadece fonksiyonları tanımlar (root tetiklenmez).
source "${REPO_ROOT}/lib/webhook.sh"

# Sabit secret + payload; beklenen imzayı openssl ile hesapla
SECRET="testsecret123"
PAYLOAD='{"ref":"refs/heads/main"}'
GOOD_HMAC="$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')"
GOOD_HEADER="sha256=${GOOD_HMAC}"

echo "── _webhook_verify_sig ──"

# Doğru imza → 0
assert_ok   _webhook_verify_sig "$SECRET" "$PAYLOAD" "$GOOD_HEADER"

# Yanlış imza → 1
assert_fail _webhook_verify_sig "$SECRET" "$PAYLOAD" "sha256=deadbeef"

# Eksik/boş header → 1
assert_fail _webhook_verify_sig "$SECRET" "$PAYLOAD" ""

# Boş secret → 1 (secret yoksa fail-closed)
assert_fail _webhook_verify_sig "" "$PAYLOAD" "$GOOD_HEADER"

# 'sha256=' prefix'i olmayan ama doğru ham hash → 1 (prefix zorunlu)
assert_fail _webhook_verify_sig "$SECRET" "$PAYLOAD" "$GOOD_HMAC"

# Doğru imza ama farklı payload → 1
assert_fail _webhook_verify_sig "$SECRET" '{"ref":"refs/heads/dev"}' "$GOOD_HEADER"

rm -rf "$WEB_ROOT"
test_summary
