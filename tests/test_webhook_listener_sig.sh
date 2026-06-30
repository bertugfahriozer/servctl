#!/bin/bash
# T5.2 — webhook-listener.sh heredoc'una gömülü imza fonksiyonu, dosya-kapsamlı
# _webhook_verify_sig ile birebir aynı fail-closed davranışı göstermeli.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"

# webhook.sh içindeki listener heredoc'unu diske çıkar (LISTENER ... LISTENER arası).
LISTENER_OUT="${WEB_ROOT}/webhook-listener.sh"
awk '/<< .LISTENER.$/{f=1;next} /^LISTENER$/{f=0} f' \
    "${REPO_ROOT}/lib/webhook.sh" > "$LISTENER_OUT"

# Heredoc gerçek socat/core.sh gerektirmeden _webhook_verify_sig tanımını
# içermeli. Tanımı izole edip source et (socat ana döngüsünü çalıştırmadan).
assert_contains "$(cat "$LISTENER_OUT")" "_webhook_verify_sig()" \
    "listener heredoc'u _webhook_verify_sig tanımını içermeli"

# Fonksiyon tanımını ayıkla ve source et (yan etki yok, sadece tanım)
SIG_FN="${WEB_ROOT}/sig_fn.sh"
awk '/^_webhook_verify_sig\(\) \{/{f=1} f{print} /^\}/{if(f)exit}' \
    "$LISTENER_OUT" > "$SIG_FN"
# shellcheck disable=SC1090
source "$SIG_FN"

SECRET="testsecret123"
PAYLOAD='{"ref":"refs/heads/main"}'
GOOD="sha256=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')"

echo "── listener gömülü imza fonksiyonu ──"
assert_ok   _webhook_verify_sig "$SECRET" "$PAYLOAD" "$GOOD"
assert_fail _webhook_verify_sig "$SECRET" "$PAYLOAD" "sha256=bad"
assert_fail _webhook_verify_sig "$SECRET" "$PAYLOAD" ""
assert_fail _webhook_verify_sig ""       "$PAYLOAD" "$GOOD"

# Handler'ın WEBHOOK_SECRET zorunluluğu: heredoc gövdesi boş-secret
# kontrolünü ve 403 yolunu içermeli (statik assert).
BODY="$(cat "$LISTENER_OUT")"
assert_contains "$BODY" "403 Forbidden" "handler 403 yolu içermeli"
assert_contains "$BODY" '_webhook_verify_sig "${WEBHOOK_SECRET' \
    "handler imza doğrulamasını _webhook_verify_sig ile yapmalı"
assert_not_contains "$BODY" 'if [[ -n "$hub_sig" && -n "${WEBHOOK_SECRET}" ]]' \
    "eski fail-open koşulu (header boşsa atla) kalmamalı"

rm -rf "$WEB_ROOT"
test_summary
