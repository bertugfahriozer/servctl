#!/bin/bash
# ═══════════════════════════════════════════════
#  ip.sh — IP Engelleme / İzin Listesi Yönetimi
# ═══════════════════════════════════════════════

cmd_ip() {
    require_root
    case "${1:-help}" in
        ban)       _ip_ban "${@:2}" ;;
        unban)     _ip_unban "${@:2}" ;;
        whitelist) _ip_whitelist "${@:2}" ;;
        blacklist) _ip_blacklist "${@:2}" ;;
        list)      _ip_list ;;
        geoblock)  _ip_geoblock "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl ip <ban|unban|whitelist|blacklist|list|geoblock>"
            echo ""
            echo "    ban <ip> [süre]           IP'yi engelle (varsayılan: 24h)"
            echo "    unban <ip>                IP engelini kaldır"
            echo "    whitelist add <ip>        Beyaz listeye ekle"
            echo "    whitelist remove <ip>     Beyaz listeden çıkar"
            echo "    blacklist add <ip>        Kalıcı engelle"
            echo "    blacklist remove <ip>     Kalıcı engeli kaldır"
            echo "    list                      Engelli IP'leri listele"
            echo "    geoblock add <ülke_kodu>  Ülkeyi engelle (TR, RU, CN...)"
            echo "    geoblock remove <ülke>    Ülke engelini kaldır"
            echo "    geoblock list             Engelli ülkeleri listele"
            echo ""
            ;;
    esac
}

_ip_ban() {
    local ip="$1"
    local duration="${2:-86400}"  # varsayılan 24 saat

    [[ -z "$ip" ]] && error "IP belirtilmedi."

    # UFW ile engelle
    ufw insert 1 deny from "$ip" to any comment "srvctl-ban-$(date +%s)" > /dev/null 2>&1
    success "IP engellendi: ${ip} (${duration}s)"

    # Süre sonunda otomatik kaldır
    if [[ "$duration" != "permanent" ]]; then
        (sleep "$duration" && ufw delete deny from "$ip" to any 2>/dev/null) &
        info "Otomatik kaldırılacak: ${duration} saniye sonra"
    fi

    # Bildirim
    source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null
    send_notification "🚫 IP Engellendi" "IP: ${ip} (süre: ${duration}s)" "warning" 2>/dev/null || true

    log_action "IP BAN: ${ip} (duration=${duration})"
}

_ip_unban() {
    local ip="$1"
    [[ -z "$ip" ]] && error "IP belirtilmedi."

    ufw delete deny from "$ip" to any 2>/dev/null
    # Fail2Ban'dan da kaldır
    for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/ /g'); do
        fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null || true
    done

    success "IP engeli kaldırıldı: ${ip}"
    log_action "IP UNBAN: ${ip}"
}

_ip_whitelist() {
    local action="$1" ip="$2"
    local whitelist_file="/etc/srvctl/ip-whitelist.conf"
    mkdir -p /etc/srvctl

    case "$action" in
        add)
            [[ -z "$ip" ]] && error "IP belirtilmedi."
            echo "$ip" >> "$whitelist_file"
            sort -u -o "$whitelist_file" "$whitelist_file"

            # Fail2Ban'a ignoreip olarak ekle
            if ! grep -q "$ip" /etc/fail2ban/jail.local 2>/dev/null; then
                sed -i "s|^ignoreip = |ignoreip = ${ip} |" /etc/fail2ban/jail.local
                systemctl reload fail2ban 2>/dev/null || true
            fi

            # Nginx'e güvenilir IP olarak ekle
            _update_nginx_whitelist

            success "Beyaz listeye eklendi: ${ip}"
            log_action "IP WHITELIST ADD: ${ip}"
            ;;
        remove)
            [[ -z "$ip" ]] && error "IP belirtilmedi."
            sed -i "/^${ip}$/d" "$whitelist_file" 2>/dev/null
            success "Beyaz listeden çıkarıldı: ${ip}"
            log_action "IP WHITELIST REMOVE: ${ip}"
            ;;
        *)
            error "Kullanım: srvctl ip whitelist <add|remove> <ip>"
            ;;
    esac
}

_ip_blacklist() {
    local action="$1" ip="$2"
    local blacklist_file="/etc/srvctl/ip-blacklist.conf"
    mkdir -p /etc/srvctl

    case "$action" in
        add)
            [[ -z "$ip" ]] && error "IP belirtilmedi."
            echo "$ip" >> "$blacklist_file"
            sort -u -o "$blacklist_file" "$blacklist_file"

            # UFW'ye kalıcı engel
            ufw insert 1 deny from "$ip" to any comment "srvctl-blacklist" > /dev/null 2>&1

            # Nginx deny listesini güncelle
            _update_nginx_blacklist

            success "Kalıcı engellendi: ${ip}"
            log_action "IP BLACKLIST ADD: ${ip}"
            ;;
        remove)
            [[ -z "$ip" ]] && error "IP belirtilmedi."
            sed -i "/^${ip}$/d" "$blacklist_file" 2>/dev/null
            ufw delete deny from "$ip" to any 2>/dev/null

            _update_nginx_blacklist

            success "Kalıcı engel kaldırıldı: ${ip}"
            log_action "IP BLACKLIST REMOVE: ${ip}"
            ;;
        *)
            error "Kullanım: srvctl ip blacklist <add|remove> <ip>"
            ;;
    esac
}

_ip_list() {
    header "IP Engel/İzin Listeleri"

    echo -e "  ${CYAN}Beyaz Liste${NC}"
    if [[ -f /etc/srvctl/ip-whitelist.conf ]]; then
        while IFS= read -r ip; do
            echo "    ✅ ${ip}"
        done < /etc/srvctl/ip-whitelist.conf
    else
        echo "    (boş)"
    fi

    divider

    echo -e "  ${CYAN}Kara Liste (Kalıcı)${NC}"
    if [[ -f /etc/srvctl/ip-blacklist.conf ]]; then
        while IFS= read -r ip; do
            echo "    🚫 ${ip}"
        done < /etc/srvctl/ip-blacklist.conf
    else
        echo "    (boş)"
    fi

    divider

    echo -e "  ${CYAN}Fail2Ban Bans (Geçici)${NC}"
    if command -v fail2ban-client &>/dev/null; then
        while IFS= read -r jail; do
            jail=$(echo "$jail" | xargs)
            [[ -z "$jail" ]] && continue
            local banned_ips
            banned_ips=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list" | sed 's/.*://')
            [[ -n "$banned_ips" ]] && echo "    ${jail}: ${banned_ips}"
        done < <(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/\n/g')
    fi

    divider

    echo -e "  ${CYAN}GeoIP Engelli Ülkeler${NC}"
    if [[ -f /etc/srvctl/geoblock.conf ]]; then
        while IFS= read -r country; do
            echo "    🌍 ${country}"
        done < /etc/srvctl/geoblock.conf
    else
        echo "    (boş)"
    fi

    echo ""
}

_ip_geoblock() {
    local action="$1" country="$2"
    local geoblock_file="/etc/srvctl/geoblock.conf"
    mkdir -p /etc/srvctl

    case "$action" in
        add)
            [[ -z "$country" ]] && error "Ülke kodu belirtilmedi (ör: CN, RU, KP)"
            country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
            echo "$country" >> "$geoblock_file"
            sort -u -o "$geoblock_file" "$geoblock_file"

            _update_nginx_geoblock
            success "Ülke engellendi: ${country}"
            log_action "GEOBLOCK ADD: ${country}"
            ;;
        remove)
            [[ -z "$country" ]] && error "Ülke kodu belirtilmedi."
            country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
            sed -i "/^${country}$/d" "$geoblock_file" 2>/dev/null

            _update_nginx_geoblock
            success "Ülke engeli kaldırıldı: ${country}"
            log_action "GEOBLOCK REMOVE: ${country}"
            ;;
        list)
            if [[ -f "$geoblock_file" ]]; then
                echo ""
                echo -e "  ${BOLD}Engelli Ülkeler${NC}"
                divider
                while IFS= read -r c; do
                    echo "  🌍 ${c}"
                done < "$geoblock_file"
                echo ""
            else
                info "GeoIP engeli tanımlanmamış"
            fi
            ;;
        *)
            error "Kullanım: srvctl ip geoblock <add|remove|list> [ülke_kodu]"
            ;;
    esac
}

_update_nginx_whitelist() {
    local conf="/etc/nginx/conf.d/srvctl-whitelist.conf"
    echo "# srvctl IP whitelist — otomatik oluşturuldu" > "$conf"
    if [[ -f /etc/srvctl/ip-whitelist.conf ]]; then
        while IFS= read -r ip; do
            echo "allow ${ip};" >> "$conf"
        done < /etc/srvctl/ip-whitelist.conf
    fi
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
}

_update_nginx_blacklist() {
    local conf="/etc/nginx/conf.d/srvctl-blacklist.conf"
    echo "# srvctl IP blacklist — otomatik oluşturuldu" > "$conf"
    if [[ -f /etc/srvctl/ip-blacklist.conf ]]; then
        while IFS= read -r ip; do
            echo "deny ${ip};" >> "$conf"
        done < /etc/srvctl/ip-blacklist.conf
    fi
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
}

_update_nginx_geoblock() {
    local conf="/etc/nginx/conf.d/srvctl-geoblock.conf"
    local geoblock_file="/etc/srvctl/geoblock.conf"

    if [[ ! -f "$geoblock_file" || ! -s "$geoblock_file" ]]; then
        rm -f "$conf"
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
        return
    fi

    cat > "$conf" << 'GEOHEAD'
# srvctl GeoIP blocking — otomatik oluşturuldu
# GeoIP modülü gerektirir: apt install libnginx-mod-http-geoip geoip-database
geo $blocked_country {
    default 0;
GEOHEAD

    # GeoIP veritabanından ülke CIDR'lerini dahil et
    while IFS= read -r country; do
        echo "    # ${country} — bloklanacak" >> "$conf"
    done < "$geoblock_file"

    echo "}" >> "$conf"
    echo "" >> "$conf"
    echo "# Kullanım: server bloğuna ekleyin:" >> "$conf"
    echo "#   if (\$blocked_country) { return 444; }" >> "$conf"

    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
}
