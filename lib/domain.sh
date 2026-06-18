#!/bin/bash
# ═══════════════════════════════════════════════
#  domain.sh — Domain CRUD Operasyonları
#  Her domain için 12 güvenlik katmanı otomatik
# ═══════════════════════════════════════════════

cmd_domain() {
    require_root
    case "${1:-help}" in
        add)       _domain_add "${@:2}" ;;
        remove)    _domain_remove "${@:2}" ;;
        list)      _domain_list ;;
        info)      _domain_info "${@:2}" ;;
        clone)     _domain_clone "${@:2}" ;;
        suspend)   _domain_suspend "${@:2}" ;;
        unsuspend) _domain_unsuspend "${@:2}" ;;
        php-switch) _domain_php_switch "${@:2}" ;;
        resources) _domain_resources "${@:2}" ;;
        staging)   _domain_staging "${@:2}" ;;
        migrate)   _domain_migrate "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl domain <komut>"
            echo ""
            echo "  Temel:"
            echo "    add <domain> [--php=8.3]        Yeni domain ekle"
            echo "    remove <domain>                 Domain kaldır"
            echo "    list                            Tüm domain'leri listele"
            echo "    info <domain>                   Domain bilgisi"
            echo ""
            echo "  Operasyonel:"
            echo "    clone <kaynak> <hedef>          Domain klonla (DB + dosya)"
            echo "    suspend <domain>                Bakım moduna al"
            echo "    unsuspend <domain>              Bakım modundan çıkar"
            echo "    php-switch <domain> <versiyon>  PHP versiyonu değiştir"
            echo "    resources <domain> [seçenekler] Kaynak limitleri (cgroups v2)"
            echo "    staging <domain>                Staging ortamı oluştur"
            echo "    migrate <domain> <user@host>    Sunucular arası taşı"
            echo ""
            ;;
    esac
}

# ═══════════════════════════════════════════════
#  DOMAIN ADD — 10 adımda tam güvenlikli domain
# ═══════════════════════════════════════════════
_domain_add() {
    local domain=""
    local php_version="${DEFAULT_PHP_VERSION}"

    # Argümanları parse et
    for arg in "$@"; do
        case "$arg" in
            --php=*) php_version="${arg#--php=}" ;;
            -*) warn "Bilinmeyen seçenek: ${arg}" ;;
            *) domain="$arg" ;;
        esac
    done

    [[ -z "$domain" ]] && error "Domain belirtilmedi. Kullanım: srvctl domain add example.com [--php=8.3]"
    domain_exists "$domain" && error "Domain zaten mevcut: ${domain}"
    php_version_exists "$php_version" || error "PHP ${php_version} kurulu değil. Önce kurun."

    # Değişkenler
    local sname
    sname=$(safe_name "$domain")
    local web_user="web_${sname}"
    local base="${WEB_ROOT}/${domain}"
    local db_name="db_${sname}"
    local db_user="usr_${sname}"
    local db_pass
    db_pass=$(generate_password 24)
    local redis_user="redis_${sname}"
    local redis_pass
    redis_pass=$(generate_password 24)

    header "Yeni Domain: ${domain}"

    local total=10
    local current=0

    # ─── 1. Linux Kullanıcısı ───
    current=$((current + 1))
    step "${current}/${total}" "Linux kullanıcısı: ${web_user}"

    groupadd "${web_user}" 2>/dev/null || true
    useradd --system --no-create-home --shell /usr/sbin/nologin \
        -g "${web_user}" "${web_user}" 2>/dev/null || true
    usermod -aG "${web_user}" www-data 2>/dev/null || true

    # Deployer'a erişim ver
    if id "${DEPLOYER_USER}" &>/dev/null; then
        usermod -aG "${web_user}" "${DEPLOYER_USER}" 2>/dev/null || true
    fi

    success "Kullanıcı oluşturuldu"

    # ─── 2. Dizin Yapısı ───
    current=$((current + 1))
    step "${current}/${total}" "Dizin yapısı oluşturuluyor..."

    mkdir -p "${base}"/{public_html,private,logs,tmp,sessions,releases,shared}
    mkdir -p "${base}/private"/{app,modules,system,vendor}
    mkdir -p "${base}/private/writable"/{cache,logs,session,uploads}

    # Chroot için gerekli dizinler
    mkdir -p "${base}"/{dev,etc,lib,lib64}
    mkdir -p "${base}/usr"/{lib,share/zoneinfo}
    mkdir -p "${base}/etc/ssl/certs"

    # İzinler
    chown -R "${web_user}:${web_user}" "${base}"
    chmod 750 "${base}"
    chmod 750 "${base}/public_html"
    chmod 750 "${base}/private"
    chmod 770 "${base}/tmp" "${base}/sessions"
    chmod -R 770 "${base}/private/writable"
    chmod 750 "${base}/logs"
    chmod o-rwx "${base}"

    # ACL
    setfacl -R -m "u:www-data:rx" "${base}/public_html" 2>/dev/null || true
    setfacl -R -d -m "u:www-data:rx" "${base}/public_html" 2>/dev/null || true
    setfacl -R -m "o::---" "${base}" 2>/dev/null || true

    success "Dizin yapısı hazır"

    # ─── 3. Chroot Ortamı ───
    current=$((current + 1))
    step "${current}/${total}" "Chroot ortamı hazırlanıyor..."

    # /dev aygıtları
    [[ ! -c "${base}/dev/null" ]] && mknod -m 0666 "${base}/dev/null" c 1 3 2>/dev/null || true
    [[ ! -c "${base}/dev/urandom" ]] && mknod -m 0444 "${base}/dev/urandom" c 1 9 2>/dev/null || true
    [[ ! -c "${base}/dev/zero" ]] && mknod -m 0666 "${base}/dev/zero" c 1 5 2>/dev/null || true

    # Temel sistem dosyaları
    cp /etc/resolv.conf "${base}/etc/" 2>/dev/null || true
    cp /etc/hosts "${base}/etc/" 2>/dev/null || true
    cp /etc/nsswitch.conf "${base}/etc/" 2>/dev/null || true
    cp /etc/localtime "${base}/etc/" 2>/dev/null || true
    cp /etc/ssl/certs/ca-certificates.crt "${base}/etc/ssl/certs/" 2>/dev/null || true
    cp -r /usr/share/zoneinfo "${base}/usr/share/" 2>/dev/null || true

    # Shared libraries (PHP-FPM için)
    local php_fpm_bin="/usr/sbin/php-fpm${php_version}"
    if [[ -x "$php_fpm_bin" ]]; then
        while IFS= read -r lib; do
            [[ -z "$lib" ]] && continue
            local dir
            dir=$(dirname "$lib")
            mkdir -p "${base}${dir}"
            cp -n "$lib" "${base}${lib}" 2>/dev/null || true
        done < <(ldd "$php_fpm_bin" 2>/dev/null | awk '{print $3}' | grep -v '^$')

        # ld-linux loader
        local loader
        loader=$(ldd "$php_fpm_bin" 2>/dev/null | grep 'ld-linux' | awk '{print $1}')
        if [[ -n "$loader" && -f "$loader" ]]; then
            mkdir -p "${base}$(dirname "$loader")"
            cp -n "$loader" "${base}${loader}" 2>/dev/null || true
        fi
    fi

    success "Chroot ortamı hazır"

    # ─── 4. PHP-FPM Pool (chroot) ───
    current=$((current + 1))
    step "${current}/${total}" "PHP-FPM pool (chroot jail)..."

    render_template "${SRVCTL_TEMPLATES}/php-fpm/pool.conf.tpl" \
        "SAFE_NAME=${sname}" \
        "DOMAIN=${domain}" \
        "WEB_USER=${web_user}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_version}" \
        > "/etc/php/${php_version}/fpm/pool.d/${sname}.conf"

    systemctl reload "php${php_version}-fpm" 2>/dev/null || \
        systemctl restart "php${php_version}-fpm"
    success "PHP-FPM pool aktif (chroot: ${base})"

    # ─── 5. Nginx Vhost ───
    current=$((current + 1))
    step "${current}/${total}" "Nginx vhost oluşturuluyor..."

    render_template "${SRVCTL_TEMPLATES}/nginx/vhost.conf.tpl" \
        "DOMAIN=${domain}" \
        "SAFE_NAME=${sname}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_version}" \
        > "/etc/nginx/sites-available/${domain}.conf"

    ln -sf "/etc/nginx/sites-available/${domain}.conf" \
        "/etc/nginx/sites-enabled/${domain}.conf"

    nginx_test
    systemctl reload nginx
    success "Nginx vhost aktif"

    # ─── 6. SSL (Let's Encrypt) ───
    current=$((current + 1))
    step "${current}/${total}" "SSL sertifikası alınıyor..."

    if certbot --nginx -d "${domain}" \
        --non-interactive --agree-tos --redirect \
        -m "admin@${domain}" 2>/dev/null; then

        # SSL aldıktan sonra özel SSL template'i uygula
        render_template "${SRVCTL_TEMPLATES}/nginx/vhost-ssl.conf.tpl" \
            "DOMAIN=${domain}" \
            "SAFE_NAME=${sname}" \
            "WEB_ROOT=${WEB_ROOT}" \
            "PHP_VERSION=${php_version}" \
            > "/etc/nginx/sites-available/${domain}.conf"

        nginx_test && systemctl reload nginx
        success "SSL aktif (Let's Encrypt + HSTS)"
    else
        warn "SSL alınamadı — DNS ayarlarını kontrol edin"
        warn "Sonra çalıştırın: certbot --nginx -d ${domain}"
    fi

    # ─── 7. AppArmor Profili ───
    current=$((current + 1))
    step "${current}/${total}" "AppArmor profili (enforce)..."

    render_template "${SRVCTL_TEMPLATES}/apparmor/profile.tpl" \
        "SAFE_NAME=${sname}" \
        "DOMAIN=${domain}" \
        "WEB_USER=${web_user}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_version}" \
        > "/etc/apparmor.d/srvctl-${sname}"

    apparmor_parser -r "/etc/apparmor.d/srvctl-${sname}" 2>/dev/null || true
    aa-enforce "/etc/apparmor.d/srvctl-${sname}" 2>/dev/null || \
        warn "AppArmor profili yüklenemedi — manuel kontrol edin"

    success "AppArmor profili enforce modda"

    # ─── 8. MariaDB ───
    current=$((current + 1))
    step "${current}/${total}" "Veritabanı oluşturuluyor..."

    mysql -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
    mysql -e "GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,ALTER,INDEX,DROP,CREATE TEMPORARY TABLES,LOCK TABLES,REFERENCES,TRIGGER ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
    # FILE yetkisini kaldır (dosya sistemi okuma/yazma engellemek için)
    mysql -e "REVOKE ALL PRIVILEGES ON *.* FROM '${db_user}'@'localhost';" 2>/dev/null || true
    mysql -e "GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,ALTER,INDEX,DROP,CREATE TEMPORARY TABLES,LOCK TABLES,REFERENCES,TRIGGER ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    success "DB: ${db_name} / User: ${db_user}"

    # ─── 9. Redis ACL ───
    current=$((current + 1))
    step "${current}/${total}" "Redis ACL ekleniyor..."

    # Mevcut ACL'den aynı kullanıcıyı sil (varsa)
    sed -i "/^user ${redis_user} /d" /etc/redis/users.acl 2>/dev/null || true

    # Yeni ACL ekle
    echo "user ${redis_user} on >${redis_pass} ~${sname}:* &* +@all -@dangerous -CONFIG -DEBUG -KEYS -FLUSHALL -FLUSHDB -SHUTDOWN" \
        >> /etc/redis/users.acl

    # ACL'i yeniden yükle
    local redis_admin_pass
    redis_admin_pass=$(grep "^REDIS_ADMIN_PASS=" "${SRVCTL_CONF}" 2>/dev/null | cut -d= -f2)
    if [[ -n "$redis_admin_pass" ]]; then
        redis-cli --user admin --pass "$redis_admin_pass" ACL LOAD 2>/dev/null || \
            systemctl restart redis-server
    else
        systemctl restart redis-server
    fi

    success "Redis ACL: ${redis_user} → ${sname}:*"

    # ─── 10. Logrotate ───
    current=$((current + 1))
    step "${current}/${total}" "Logrotate yapılandırılıyor..."

    render_template "${SRVCTL_TEMPLATES}/logrotate/domain.tpl" \
        "DOMAIN=${domain}" \
        "WEB_USER=${web_user}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_version}" \
        > "/etc/logrotate.d/srvctl-${sname}"

    success "Logrotate aktif"

    # ─── Credentials Dosyası ───
    cat > "${base}/.credentials" << CREDS
# ═══════════════════════════════════════════════
#  srvctl credentials — ${domain}
#  Oluşturulma: $(date '+%Y-%m-%d %H:%M:%S')
#  DİKKAT: Bu dosyayı güvenli bir yere yedekleyin!
# ═══════════════════════════════════════════════
DOMAIN=${domain}
SAFE_NAME=${sname}
WEB_USER=${web_user}
PHP_VERSION=${php_version}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASS=${db_pass}
REDIS_USER=${redis_user}
REDIS_PASS=${redis_pass}
REDIS_PREFIX=${sname}:
CREDS
    chmod 600 "${base}/.credentials"
    chown root:root "${base}/.credentials"

    # ─── Hoşgeldin sayfası ───
    cat > "${base}/public_html/index.php" << 'INDEXPHP'
<?php
echo '<h1>Domain is active</h1>';
echo '<p>Server time: ' . date('Y-m-d H:i:s') . '</p>';
echo '<p>PHP version: ' . PHP_VERSION . '</p>';
INDEXPHP
    chown "${web_user}:${web_user}" "${base}/public_html/index.php"

    # ─── Sonuç ───
    header "✅ Domain başarıyla eklendi: ${domain}"

    echo "  Web root:       ${base}/public_html"
    echo "  Private:        ${base}/private"
    echo "  PHP:            ${php_version} (chroot: ${base})"
    divider
    echo "  DB Name:        ${db_name}"
    echo "  DB User:        ${db_user}"
    echo "  DB Pass:        ${db_pass}"
    divider
    echo "  Redis User:     ${redis_user}"
    echo "  Redis Pass:     ${redis_pass}"
    echo "  Redis Prefix:   ${sname}:"
    divider
    echo "  Credentials:    ${base}/.credentials"
    echo ""
    echo -e "  ${BOLD}Sonraki adım:${NC}  srvctl deploy ${domain}"
    echo ""

    log_action "DOMAIN ADD: ${domain} (user=${web_user}, php=${php_version}, db=${db_name})"
}

# ═══════════════════════════════════════════════
#  DOMAIN REMOVE
# ═══════════════════════════════════════════════
_domain_remove() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Domain belirtilmedi."
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname
    sname=$(safe_name "$domain")
    local web_user="web_${sname}"
    local base="${WEB_ROOT}/${domain}"

    echo ""
    warn "⚠️  ${domain} ve TÜM VERİLERİ silinecek!"
    warn "Bu işlem geri alınamaz."
    echo ""

    if ! confirm "Silmek istediğinizden emin misiniz?"; then
        info "İptal edildi."
        return 0
    fi

    # Credentials'dan bilgileri oku
    local php_version="${DEFAULT_PHP_VERSION}"
    local db_name="db_${sname}"
    local db_user="usr_${sname}"
    read_credentials "$domain"

    info "Son yedek alınıyor..."
    mkdir -p "${BACKUP_DIR}"
    tar czf "${BACKUP_DIR}/${domain}-final-$(date +%Y%m%d_%H%M%S).tar.gz" \
        "${base}" 2>/dev/null || true

    # 1. Nginx
    rm -f "/etc/nginx/sites-enabled/${domain}.conf" \
          "/etc/nginx/sites-available/${domain}.conf"
    nginx -t 2>/dev/null && systemctl reload nginx

    # 2. PHP-FPM pool
    rm -f "/etc/php/${php_version}/fpm/pool.d/${sname}.conf"
    systemctl reload "php${php_version}-fpm" 2>/dev/null || true

    # 3. AppArmor
    aa-disable "/etc/apparmor.d/srvctl-${sname}" 2>/dev/null || true
    rm -f "/etc/apparmor.d/srvctl-${sname}"

    # 4. MariaDB
    mysql -e "DROP DATABASE IF EXISTS \`${db_name}\`;" 2>/dev/null || true
    mysql -e "DROP USER IF EXISTS '${db_user}'@'localhost';" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true

    # 5. Redis ACL
    sed -i "/^user redis_${sname} /d" /etc/redis/users.acl 2>/dev/null || true
    systemctl restart redis-server 2>/dev/null || true

    # 6. SSL sertifikası
    certbot delete --cert-name "${domain}" --non-interactive 2>/dev/null || true

    # 7. Logrotate
    rm -f "/etc/logrotate.d/srvctl-${sname}"

    # 8. Dosyalar
    rm -rf "${base}"

    # 9. Linux kullanıcısı
    userdel "${web_user}" 2>/dev/null || true
    groupdel "${web_user}" 2>/dev/null || true

    success "Domain kaldırıldı: ${domain}"
    info "Son yedek: ${BACKUP_DIR}/${domain}-final-*.tar.gz"

    log_action "DOMAIN REMOVE: ${domain}"
}

# ═══════════════════════════════════════════════
#  DOMAIN LIST
# ═══════════════════════════════════════════════
_domain_list() {
    echo ""
    echo -e "  ${BOLD}Kayıtlı Domain'ler${NC}"
    divider
    printf "  ${DIM}%-30s %-8s %-15s %-6s %-8s${NC}\n" "DOMAIN" "PHP" "KULLANICI" "SSL" "CHROOT"
    divider

    local count=0
    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")
        local sname
        sname=$(safe_name "$domain")
        local php_ver="${DEFAULT_PHP_VERSION}"
        local user="web_${sname}"
        local ssl="❌"
        local chroot="❌"

        # Credentials'dan bilgi oku
        if [[ -f "${dir}.credentials" ]]; then
            # shellcheck disable=SC1090
            source "${dir}.credentials"
            php_ver="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
            user="${WEB_USER:-web_${sname}}"
        fi

        # SSL kontrolü
        [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && ssl="✅"

        # Chroot kontrolü
        if [[ -f "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf" ]]; then
            grep -q "chroot" "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf" 2>/dev/null && chroot="✅"
        fi

        printf "  %-30s %-8s %-15s %-6s %-8s\n" "$domain" "$php_ver" "$user" "$ssl" "$chroot"
        count=$((count + 1))
    done

    divider
    echo "  Toplam: ${count} domain"
    echo ""
}

# ═══════════════════════════════════════════════
#  DOMAIN INFO
# ═══════════════════════════════════════════════
_domain_info() {
    local domain="$1"
    [[ -z "$domain" ]] && error "Domain belirtilmedi."
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname
    sname=$(safe_name "$domain")
    local base="${WEB_ROOT}/${domain}"

    header "Domain Bilgisi: ${domain}"

    # Credentials
    if [[ -f "${base}/.credentials" ]]; then
        read_credentials "$domain"
        echo -e "  ${CYAN}Genel${NC}"
        echo "  Kullanıcı:      ${WEB_USER:-web_${sname}}"
        echo "  PHP versiyonu:  ${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
        echo "  Dizin:          ${base}"
        divider
        echo -e "  ${CYAN}Veritabanı${NC}"
        echo "  DB Name:        ${DB_NAME:-db_${sname}}"
        echo "  DB User:        ${DB_USER:-usr_${sname}}"
        echo "  DB Pass:        ${DB_PASS:-[credentials dosyasından okunabilir]}"
        divider
        echo -e "  ${CYAN}Redis${NC}"
        echo "  Redis User:     ${REDIS_USER:-redis_${sname}}"
        echo "  Redis Prefix:   ${REDIS_PREFIX:-${sname}:}"
    else
        warn "Credentials dosyası bulunamadı: ${base}/.credentials"
    fi

    divider

    # Disk kullanımı
    echo -e "  ${CYAN}Kaynaklar${NC}"
    local disk
    disk=$(du -sh "${base}" 2>/dev/null | awk '{print $1}')
    echo "  Disk kullanımı: ${disk}"

    # DB boyutu
    local db_size
    db_size=$(mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) FROM information_schema.tables WHERE table_schema = 'db_${sname}';" 2>/dev/null)
    echo "  DB boyutu:      ${db_size:-0} MB"

    divider

    # Güvenlik durumu
    echo -e "  ${CYAN}Güvenlik Durumu${NC}"

    local php_ver="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"

    # PHP-FPM pool
    local pool_status="${RED}❌ Yok${NC}"
    if [[ -f "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf" ]]; then
        if grep -q "chroot" "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf" 2>/dev/null; then
            pool_status="${GREEN}✅ Aktif (chroot)${NC}"
        else
            pool_status="${YELLOW}⚠️  Aktif (chroot yok)${NC}"
        fi
    fi
    echo -e "  PHP-FPM Pool:   ${pool_status}"

    # AppArmor
    local aa_status="${RED}❌ Yok${NC}"
    if aa-status 2>/dev/null | grep -q "srvctl-${sname}"; then
        aa_status="${GREEN}✅ Enforce${NC}"
    fi
    echo -e "  AppArmor:       ${aa_status}"

    # SSL
    local ssl_status="${RED}❌ Yok${NC}"
    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        local expiry
        expiry=$(openssl x509 -enddate -noout \
            -in "/etc/letsencrypt/live/${domain}/fullchain.pem" 2>/dev/null | cut -d= -f2)
        ssl_status="${GREEN}✅ Aktif (bitiş: ${expiry})${NC}"
    fi
    echo -e "  SSL:            ${ssl_status}"

    # Nginx
    local nginx_status="${RED}❌ Yok${NC}"
    [[ -f "/etc/nginx/sites-enabled/${domain}.conf" ]] && \
        nginx_status="${GREEN}✅ Aktif${NC}"
    echo -e "  Nginx:          ${nginx_status}"

    # Dosya izinleri
    local perm
    perm=$(stat -c %a "${base}" 2>/dev/null)
    local perm_status="${RED}❌ ${perm}${NC}"
    [[ "$perm" == "750" ]] && perm_status="${GREEN}✅ 750${NC}"
    echo -e "  Dosya izinleri: ${perm_status}"

    echo ""
}
