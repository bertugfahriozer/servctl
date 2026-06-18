#!/bin/bash
# ═══════════════════════════════════════════════
#  status.sh — Sunucu Durum Özeti
# ═══════════════════════════════════════════════

cmd_status() {
    echo ""
    echo -e "  ${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}  📊 srvctl — Sunucu Durumu${NC}"
    echo -e "  ${BOLD}═══════════════════════════════════════════════${NC}"
    echo ""

    # ═══ SİSTEM ═══
    echo -e "  ${CYAN}Sistem${NC}"
    echo "  Hostname:   $(hostname -f 2>/dev/null || hostname)"
    echo "  OS:         $(lsb_release -ds 2>/dev/null || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    echo "  Kernel:     $(uname -r)"
    echo "  Uptime:     $(uptime -p 2>/dev/null || uptime)"
    echo "  srvctl:     v${SRVCTL_VERSION}"
    divider

    # ═══ KAYNAKLAR ═══
    echo -e "  ${CYAN}Kaynaklar${NC}"

    # CPU
    local cpu_cores
    cpu_cores=$(grep -c processor /proc/cpuinfo 2>/dev/null || echo "?")
    local load
    load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
    echo "  CPU:        ${cpu_cores} core, load: ${load}"

    # RAM
    local ram_info
    ram_info=$(free -h 2>/dev/null | awk '/Mem:/ {printf "%s / %s (boş: %s)", $3, $2, $4}')
    echo "  RAM:        ${ram_info}"

    # Swap
    local swap_info
    swap_info=$(free -h 2>/dev/null | awk '/Swap:/ {printf "%s / %s", $3, $2}')
    echo "  Swap:       ${swap_info}"

    # Disk
    local disk_info
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s / %s (%s kullanılıyor)", $3, $2, $5}')
    echo "  Disk (/):   ${disk_info}"

    # Web root disk
    if [[ -d "$WEB_ROOT" ]]; then
        local web_size
        web_size=$(du -sh "$WEB_ROOT" 2>/dev/null | awk '{print $1}')
        echo "  Web root:   ${web_size} (${WEB_ROOT})"
    fi

    # Backup disk
    if [[ -d "$BACKUP_DIR" ]]; then
        local backup_size
        backup_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
        echo "  Yedekler:   ${backup_size} (${BACKUP_DIR})"
    fi

    divider

    # ═══ SERVİSLER ═══
    echo -e "  ${CYAN}Servisler${NC}"

    local services=(
        "nginx"
        "php${DEFAULT_PHP_VERSION}-fpm"
        "mariadb"
        "redis-server"
        "fail2ban"
        "apparmor"
        "auditd"
        "ufw"
    )

    for svc in "${services[@]}"; do
        local status_text
        local status_icon
        if systemctl is-active "$svc" > /dev/null 2>&1; then
            status_icon="${GREEN}●${NC}"
            status_text="aktif"
        elif systemctl is-enabled "$svc" > /dev/null 2>&1; then
            status_icon="${YELLOW}●${NC}"
            status_text="durdu (enabled)"
        else
            status_icon="${RED}●${NC}"
            status_text="kapalı"
        fi
        printf "  %b %-25s %s\n" "$status_icon" "$svc" "$status_text"
    done

    divider

    # ═══ DOMAİNLER ═══
    echo -e "  ${CYAN}Domain'ler${NC}"
    local domain_count=0

    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")
        local sname
        sname=$(safe_name "$domain")
        local size
        size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')

        local ssl_icon="${RED}✗${NC}"
        [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && ssl_icon="${GREEN}✓${NC}"

        printf "  %-30s %-8s SSL:%b\n" "$domain" "$size" "$ssl_icon"
        domain_count=$((domain_count + 1))
    done

    if [[ $domain_count -eq 0 ]]; then
        echo "  Henüz domain eklenmemiş."
        echo "  Eklemek için: sudo srvctl domain add <domain>"
    fi

    echo ""
    echo "  Toplam: ${domain_count} domain"

    divider

    # ═══ FAİL2BAN ═══
    echo -e "  ${CYAN}Fail2Ban${NC}"
    if command -v fail2ban-client &>/dev/null && service_is_active fail2ban; then
        local total_banned=0
        while IFS= read -r jail; do
            jail=$(echo "$jail" | xargs)
            [[ -z "$jail" ]] && continue
            local banned
            banned=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
            total_banned=$((total_banned + ${banned:-0}))
            echo "  ${jail}: ${banned:-0} banned"
        done < <(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/\n/g')
        echo "  Toplam banned: ${total_banned}"
    else
        echo "  Fail2Ban çalışmıyor"
    fi

    divider

    # ═══ SON YEDEK ═══
    echo -e "  ${CYAN}Son Yedek${NC}"
    if [[ -d "$BACKUP_DIR" ]]; then
        local last_backup
        last_backup=$(ls -td "${BACKUP_DIR}"/*/ 2>/dev/null | head -1)
        if [[ -n "$last_backup" ]]; then
            echo "  $(basename "$last_backup") ($(du -sh "$last_backup" 2>/dev/null | awk '{print $1}'))"
        else
            echo "  Henüz yedek yok"
        fi
    fi

    echo ""
}
