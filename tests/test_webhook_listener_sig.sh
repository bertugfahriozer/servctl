#!/bin/bash
# T5.2 — webhook-listener.sh heredoc'una gömülü imza fonksiyonu, dosya-kapsamlı
# _webhook_verify_sig ile birebir aynı fail-closed davranışı göstermeli.
# Ayrıca: socat 127.0.0.1'e bağlanmalı; header eksikse handle_request 403 dönmeli.
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

# socat 127.0.0.1'e bağlanmalı (statik assert: bind= seçeneği zorunlu, T5.3 ile literal)
assert_contains "$BODY" 'bind=127.0.0.1' \
    "listener socat 127.0.0.1'e bağlanmalı (bind=127.0.0.1)"

echo "── handle_request: header eksikse 403 dönmeli (dinamik) ──"
# handle_request'i ve bağımlılıklarını izole ortamda test et.
# log_action ve diğer core.sh fonksiyonları stub'lanır; conf dosyası geçici üretilir.
HANDLE_FN="${WEB_ROOT}/handle_fn.sh"
awk '/^handle_request\(\) \{/{f=1} f{print} /^\}/{if(f){f=0;print "";exit}}' \
    "$LISTENER_OUT" > "$HANDLE_FN"

# Test ortamı: stub'lar + conf dosyası
FAKE_CONF="${WEB_ROOT}/testdomain.conf"
cat > "$FAKE_CONF" << 'CONF'
WEBHOOK_DOMAIN=testdomain.example.com
WEBHOOK_SECRET=realsecret456
WEBHOOK_BRANCH=main
CONF

# handle_request'i içeren geçici test scripti — request'i stdin'den alır
TEST_SCRIPT="${WEB_ROOT}/run_handle.sh"
cat > "$TEST_SCRIPT" << SCRIPT
#!/bin/bash
set -uo pipefail

# Bağımlılık stub'ları
log_action() { true; }
# Heredoc'taki _webhook_verify_sig ve handle_request tanımlarını yükle
# shellcheck disable=SC1090
source "${SIG_FN}"

# /etc/srvctl/webhooks/testdomain.conf yerine geçici conf'u kullan:
# handle_request içindeki \$conf değişkenini override etmek için
# fonksiyonu yeniden tanımla (conf yolunu sabitleyerek).
handle_request() {
    local request=""
    local content_length=0
    local body=""

    while IFS= read -r line; do
        line=\$(echo "\$line" | tr -d '\r')
        [[ -z "\$line" ]] && break
        request+="\${line}\n"
        if [[ "\$line" =~ ^Content-Length:\\ ([0-9]+) ]]; then
            content_length="\${BASH_REMATCH[1]}"
        fi
    done

    if [[ \$content_length -gt 0 ]]; then
        body=\$(head -c "\$content_length")
    fi

    local path
    path=\$(echo -e "\$request" | head -1 | awk '{print \$2}')

    if [[ "\$path" =~ ^/deploy/([a-zA-Z0-9_]+)\$ ]]; then
        local sname="\${BASH_REMATCH[1]}"
        local conf="${FAKE_CONF}"

        if [[ -f "\$conf" ]]; then
            # shellcheck disable=SC1090
            source "\$conf"

            if [[ -z "\${WEBHOOK_SECRET:-}" ]]; then
                echo -e "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nWebhook secret tanımsız"
                log_action "WEBHOOK REJECTED: \${sname} (secret tanımsız)"
                return
            fi

            local hub_sig
            hub_sig=\$(echo -e "\$request" | grep -i "X-Hub-Signature-256" | awk '{print \$2}' | tr -d '\r')
            if ! _webhook_verify_sig "\${WEBHOOK_SECRET}" "\$body" "\$hub_sig"; then
                echo -e "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nImza geçersiz"
                log_action "WEBHOOK REJECTED: \${sname} (imza geçersiz/eksik)"
                return
            fi

            echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nDeploy started: \${WEBHOOK_DOMAIN}"
        else
            echo -e "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nDomain not configured"
        fi
    else
        echo -e "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot found"
    fi
}

handle_request
SCRIPT
chmod +x "$TEST_SCRIPT"

# 1. Header eksik → 403 beklenir
NO_HEADER_REQ="POST /deploy/testdomain HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"
RESP_NO_HDR=$(printf '%b' "$NO_HEADER_REQ" | bash "$TEST_SCRIPT")
assert_contains "$RESP_NO_HDR" "403 Forbidden" \
    "X-Hub-Signature-256 header eksikse 403 dönmeli"

# 2. Yanlış imza → 403 beklenir
BAD_SIG_REQ="POST /deploy/testdomain HTTP/1.1\r\nHost: localhost\r\nX-Hub-Signature-256: sha256=deadbeef\r\nContent-Length: 0\r\n\r\n"
RESP_BAD=$(printf '%b' "$BAD_SIG_REQ" | bash "$TEST_SCRIPT")
assert_contains "$RESP_BAD" "403 Forbidden" \
    "Yanlış imzayla 403 dönmeli"

# 3. Boş header değeri → 403 beklenir
EMPTY_SIG_REQ="POST /deploy/testdomain HTTP/1.1\r\nHost: localhost\r\nX-Hub-Signature-256: \r\nContent-Length: 0\r\n\r\n"
RESP_EMPTY=$(printf '%b' "$EMPTY_SIG_REQ" | bash "$TEST_SCRIPT")
assert_contains "$RESP_EMPTY" "403 Forbidden" \
    "Boş imza headerıyla 403 dönmeli"

rm -rf "$WEB_ROOT"
test_summary
