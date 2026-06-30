#!/bin/bash
# ═══════════════════════════════════════════════
#  webhook.sh — Webhook Auto-Deploy Listener
#  GitHub/GitLab push → otomatik deploy
# ═══════════════════════════════════════════════

# Yapılandırma:
#   WEBHOOK_PORT=9443
#   WEBHOOK_SECRET=xxxxxx (GitHub/GitLab secret)

WEBHOOK_PORT="${WEBHOOK_PORT:-9443}"
WEBHOOK_PID_FILE="/var/run/srvctl-webhook.pid"
WEBHOOK_LOG="/usr/local/srvctl/logs/webhook.log"
# Listener yalnızca 127.0.0.1'e bağlanır (nginx arkasında); 9443 dışa açılmaz.
WEBHOOK_BIND="${WEBHOOK_BIND:-127.0.0.1}"

# _webhook_verify_sig <secret> <payload> <header_value>
# GitHub X-Hub-Signature-256 doğrulaması (fail-closed).
# 0 döner ANCAK header dolu VE 'sha256='+HMAC-SHA256(secret,payload)'a eşitse.
# Eksik/boş header, boş secret veya yanlış imza → 1. Çıkış/çıktı yapmaz.
_webhook_verify_sig() {
    local secret="$1" payload="$2" header="$3"
    # Secret yoksa veya header boşsa fail-closed
    [[ -z "$secret" ]] && return 1
    [[ -z "$header" ]] && return 1

    local expected
    expected="sha256=$(printf '%s' "$payload" \
        | openssl dgst -sha256 -hmac "$secret" 2>/dev/null \
        | awk '{print $NF}')"
    # Hesaplama başarısız olduysa (boş hash) reddet
    [[ "$expected" == "sha256=" ]] && return 1

    # Sabit-zamanlı karşılaştırma: her iki dizgenin SHA-256'sını al,
    # böylece uzunluk farkı ve byte-byte erken-çıkış sızıntısı olmaz.
    local h_recv h_exp
    h_recv="$(printf '%s' "$header"   | openssl dgst -sha256 | awk '{print $NF}')"
    h_exp="$(printf '%s' "$expected"  | openssl dgst -sha256 | awk '{print $NF}')"
    [[ "$h_recv" == "$h_exp" ]] && return 0
    return 1
}

cmd_webhook() {
    require_root
    case "${1:-help}" in
        start)  _webhook_start ;;
        stop)   _webhook_stop ;;
        status) _webhook_status ;;
        setup)  _webhook_setup "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl webhook <start|stop|status|setup>"
            echo ""
            echo "    start              Webhook listener'ı başlat"
            echo "    stop               Webhook listener'ı durdur"
            echo "    status             Listener durumu"
            echo "    setup <domain>     Domain için webhook yapılandır"
            echo ""
            echo "  GitHub/GitLab'da webhook URL'si:"
            echo "    https://sunucu-ip:${WEBHOOK_PORT}/deploy/<domain>"
            echo ""
            ;;
    esac
}

_webhook_setup() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Domain belirtilmedi."
    domain_exists "$domain" || error "Domain bulunamadı."

    local sname
    sname=$(safe_name "$domain")
    local secret
    secret=$(generate_password 32)

    # Webhook config dosyası
    mkdir -p /etc/srvctl/webhooks
    cat > "/etc/srvctl/webhooks/${sname}.conf" << WHCONF
WEBHOOK_DOMAIN=${domain}
WEBHOOK_SECRET=${secret}
WEBHOOK_BRANCH=main
WEBHOOK_AUTO_DEPLOY=true
WEBHOOK_HEALTH_CHECK=true
WEBHOOK_NOTIFY=true
WHCONF
    chmod 600 "/etc/srvctl/webhooks/${sname}.conf"

    header "Webhook Yapılandırıldı: ${domain}"
    echo "  URL:      https://SUNUCU_IP:${WEBHOOK_PORT}/deploy/${sname}"
    echo "  Secret:   ${secret}"
    echo "  Branch:   main"
    echo ""
    echo "  GitHub'da:"
    echo "    Settings → Webhooks → Add webhook"
    echo "    Payload URL:  https://SUNUCU_IP:${WEBHOOK_PORT}/deploy/${sname}"
    echo "    Content type: application/json"
    echo "    Secret:       ${secret}"
    echo "    Events:       Just the push event"
    echo ""

    log_action "WEBHOOK SETUP: ${domain}"
}

_webhook_start() {
    if [[ -f "$WEBHOOK_PID_FILE" ]]; then
        local pid
        pid=$(cat "$WEBHOOK_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            warn "Webhook listener zaten çalışıyor (PID: ${pid})"
            return 0
        fi
    fi

    info "Webhook listener başlatılıyor (port: ${WEBHOOK_PORT})..."

    # socat ile lightweight HTTP listener
    if ! command -v socat &>/dev/null; then
        error "socat kurulu değil. Kurun: apt install socat"
    fi

    # systemd service oluştur
    cat > /etc/systemd/system/srvctl-webhook.service << SERVICE
[Unit]
Description=srvctl Webhook Listener
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/srvctl/lib/webhook-listener.sh
Restart=always
RestartSec=5
User=root
Group=root
StandardOutput=append:${WEBHOOK_LOG}
StandardError=append:${WEBHOOK_LOG}

[Install]
WantedBy=multi-user.target
SERVICE

    # Listener script'i oluştur
    cat > /usr/local/srvctl/lib/webhook-listener.sh << 'LISTENER'
#!/bin/bash
# srvctl Webhook HTTP Listener
# socat tabanlı, hafif webhook handler

SRVCTL_ROOT="/usr/local/srvctl"
WEBHOOK_PORT="${WEBHOOK_PORT:-9443}"

source "${SRVCTL_ROOT}/conf/srvctl.conf"
source "${SRVCTL_ROOT}/lib/core.sh"

handle_request() {
    local request=""
    local content_length=0
    local body=""

    # HTTP request headers oku
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r')
        [[ -z "$line" ]] && break
        request+="${line}\n"
        if [[ "$line" =~ ^Content-Length:\ ([0-9]+) ]]; then
            content_length="${BASH_REMATCH[1]}"
        fi
    done

    # Body oku
    if [[ $content_length -gt 0 ]]; then
        body=$(head -c "$content_length")
    fi

    # URL'den domain çıkar
    local path
    path=$(echo -e "$request" | head -1 | awk '{print $2}')

    if [[ "$path" =~ ^/deploy/([a-zA-Z0-9_]+)$ ]]; then
        local sname="${BASH_REMATCH[1]}"
        local conf="/etc/srvctl/webhooks/${sname}.conf"

        if [[ -f "$conf" ]]; then
            source "$conf"

            # Signature doğrulama (GitHub)
            local hub_sig
            hub_sig=$(echo -e "$request" | grep -i "X-Hub-Signature-256" | awk '{print $2}' | tr -d '\r')
            if [[ -n "$hub_sig" && -n "${WEBHOOK_SECRET}" ]]; then
                local expected
                expected="sha256=$(echo -n "$body" | openssl dgst -sha256 -hmac "${WEBHOOK_SECRET}" | awk '{print $2}')"
                if [[ "$hub_sig" != "$expected" ]]; then
                    echo -e "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nInvalid signature"
                    log_action "WEBHOOK REJECTED: ${sname} (invalid signature)"
                    return
                fi
            fi

            # Branch kontrolü
            local push_branch
            push_branch=$(echo "$body" | jq -r '.ref // empty' 2>/dev/null | sed 's|refs/heads/||')
            if [[ -n "$push_branch" && "$push_branch" != "${WEBHOOK_BRANCH:-main}" ]]; then
                echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nSkipped (branch: ${push_branch})"
                return
            fi

            # Deploy başlat
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nDeploy started: ${WEBHOOK_DOMAIN}"

            # Asenkron deploy
            (
                sleep 2
                /usr/local/srvctl/bin/srvctl deploy "${WEBHOOK_DOMAIN}" "${WEBHOOK_BRANCH:-main}" 2>&1 | \
                    tee -a "${SRVCTL_ROOT}/logs/webhook.log"

                # Bildirim
                if [[ "${WEBHOOK_NOTIFY}" == "true" ]]; then
                    source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null
                    send_notification "🚀 Auto-Deploy" "${WEBHOOK_DOMAIN} (branch: ${push_branch:-main})" "success" 2>/dev/null || true
                fi
            ) &

            log_action "WEBHOOK DEPLOY: ${WEBHOOK_DOMAIN} (branch=${push_branch:-main})"
        else
            echo -e "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nDomain not configured"
        fi
    elif [[ "$path" == "/health" ]]; then
        echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nOK"
    else
        echo -e "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot found"
    fi
}

# Ana döngü
socat TCP-LISTEN:${WEBHOOK_PORT},reuseaddr,fork SYSTEM:"/usr/local/srvctl/lib/webhook-listener.sh handle"

# Handle mode
if [[ "${1:-}" == "handle" ]]; then
    handle_request
fi
LISTENER
    chmod +x /usr/local/srvctl/lib/webhook-listener.sh

    # UFW'de port aç
    ufw allow "${WEBHOOK_PORT}/tcp" comment "srvctl-webhook" > /dev/null 2>&1

    # Başlat
    systemctl daemon-reload
    systemctl enable srvctl-webhook
    systemctl start srvctl-webhook

    success "Webhook listener aktif (port: ${WEBHOOK_PORT})"
    log_action "WEBHOOK START: port=${WEBHOOK_PORT}"
}

_webhook_stop() {
    systemctl stop srvctl-webhook 2>/dev/null
    systemctl disable srvctl-webhook 2>/dev/null
    success "Webhook listener durduruldu"
    log_action "WEBHOOK STOP"
}

_webhook_status() {
    header "Webhook Listener Durumu"

    if systemctl is-active srvctl-webhook > /dev/null 2>&1; then
        echo -e "  Durum: ${GREEN}● aktif${NC} (port: ${WEBHOOK_PORT})"
    else
        echo -e "  Durum: ${RED}● kapalı${NC}"
    fi

    divider

    echo -e "  ${CYAN}Yapılandırılmış Domain'ler${NC}"
    for conf in /etc/srvctl/webhooks/*.conf; do
        [[ ! -f "$conf" ]] && continue
        # shellcheck disable=SC1090
        source "$conf"
        echo "  🔗 ${WEBHOOK_DOMAIN} (branch: ${WEBHOOK_BRANCH:-main})"
    done

    divider

    echo -e "  ${CYAN}Son Webhook İşlemleri${NC}"
    tail -10 "${WEBHOOK_LOG}" 2>/dev/null || echo "  Log yok"

    echo ""
}
