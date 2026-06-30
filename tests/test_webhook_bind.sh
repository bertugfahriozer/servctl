#!/bin/bash
# T5.3 — listener 127.0.0.1'e bağlanmalı, 9443 UFW'de dışa açılmamalı,
# setup boş secret üretmemeli (statik/birim assert'ler; root/socat gerekmez).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"

SRC="$(cat "${REPO_ROOT}/lib/webhook.sh")"

echo "── webhook bind & UFW sertleştirme ──"

# socat TCP-LISTEN 127.0.0.1'e bind olmalı
assert_contains "$SRC" "TCP-LISTEN:\${WEBHOOK_PORT},bind=127.0.0.1" \
    "socat listener 127.0.0.1'e bind olmalı"

# 9443 artık UFW'de dışa açılmamalı (eski 'ufw allow ...webhook' kaldırıldı)
assert_not_contains "$SRC" 'ufw allow "${WEBHOOK_PORT}/tcp"' \
    "webhook portu UFW'de dışa açılmamalı"

# setup secret üretimini doğrulamalı: 'generate_password 32' sonrası boşluk kontrolü
assert_contains "$SRC" "Webhook secret üretilemedi" \
    "setup boş secret'i fail-closed reddetmeli"

rm -rf "$WEB_ROOT"
test_summary
