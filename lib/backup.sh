#!/bin/bash
# ═══════════════════════════════════════════════
#  backup.sh — Yedekleme & Geri Yükleme
# ═══════════════════════════════════════════════

cmd_backup() {
    require_root
    case "${1:-help}" in
        run)     _backup_run "${@:2}" ;;
        list)    _backup_list ;;
        restore) _backup_restore "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl backup <run|list|restore>"
            echo ""
            echo "    run [domain]              Yedekleme çalıştır"
            echo "    list                      Yedekleri listele"
            echo "    restore <yedek_dizini>    Geri yükleme"
            echo ""
            ;;
    esac
}

# Yedek kök + per-run dizinini güvenli oluştur (0700 root:root).
# Saf yardımcı: mysql/nginx gerektirmez.
_backup_prepare_dir() {
    local run_dir="$1"
    secure_dir "$BACKUP_DIR" 700
    secure_dir "$run_dir" 700
}

# Tek bir yedek artefaktını 0600 root:root kilitle.
_backup_secure_artifact() {
    secure_file "$1" 600
}

# Restore: tek bir files tarball'ını güvenle çıkar (zip-slip/symlink reddi).
# safe_extract mutlak yol/'..'/symlink üyesi varsa çıkarmadan reddeder.
# Saf yardımcı: mysql/systemctl gerektirmez.
_backup_restore_files() {
    local tar_gz="$1" dest="$2"
    safe_extract "$tar_gz" "$dest"
}

# Per-domain dosya tarball'ı (relatif yol + sır/kontrol dosyalarını hariç tut).
# .credentials/.srvctl-meta sır/kontrol dosyalarıdır; yedek paketine girmemeli
# (paket world-readable olabilir + safe_extract restore'u için relatif yol şart).
# Saf yardımcı: mysql/nginx gerektirmez.
_backup_files_tar() {
    local domain="$1" web_root="$2" out_tar="$3"
    tar czf "$out_tar" -C "$web_root" \
        --exclude='*.log' \
        --exclude="${domain}/cache/*" \
        --exclude="${domain}/releases/*" \
        --exclude="${domain}/sessions/*" \
        --exclude="${domain}/tmp/*" \
        --exclude="${domain}/.credentials" \
        --exclude="${domain}/.srvctl-meta" \
        --exclude="${domain}/.deploy-repo" \
        "$domain"
}

_backup_run() {
    local target_domain="$1"
    local today
    today=$(date +%Y%m%d_%H%M%S)
    local backup_path="${BACKUP_DIR}/${today}"

    # Yedek kökü + per-run dizini 0700 root:root
    _backup_prepare_dir "${backup_path}"

    header "Yedekleme: ${today}"

    # ─── Veritabanı Yedekleri ───
    step "DB" "Veritabanları yedekleniyor..."
    local db_count=0

    while IFS= read -r db; do
        [[ -z "$db" ]] && continue

        # Hedef domain varsa, sadece o domain'in DB'sini yedekle
        if [[ -n "$target_domain" ]]; then
            local target_db="db_$(safe_name "$target_domain")"
            [[ "$db" != "$target_db" ]] && continue
        fi

        mysqldump --single-transaction --quick --lock-tables=false \
            "$db" 2>/dev/null | gzip > "${backup_path}/${db}.sql.gz"
        _backup_secure_artifact "${backup_path}/${db}.sql.gz"
        db_count=$((db_count + 1))
    done < <(mysql -N -e "SHOW DATABASES" 2>/dev/null | \
        grep -vE "^(information_schema|performance_schema|mysql|sys)$")

    success "${db_count} veritabanı yedeklendi"

    # ─── Dosya Yedekleri ───
    step "FILES" "Dosyalar yedekleniyor..."
    local file_count=0

    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")

        # Hedef domain varsa, sadece onu yedekle
        if [[ -n "$target_domain" && "$domain" != "$target_domain" ]]; then
            continue
        fi

        # Relatif yol + .credentials/.srvctl-meta hariç (safe_extract uyumlu, sır sızdırmaz)
        _backup_files_tar "$domain" "${WEB_ROOT}" "${backup_path}/${domain}-files.tar.gz" \
            2>/dev/null || warn "Dosya yedeklemesinde hata: ${domain}"
        _backup_secure_artifact "${backup_path}/${domain}-files.tar.gz"

        file_count=$((file_count + 1))
    done

    success "${file_count} domain dosyası yedeklendi"

    # ─── Redis Yedek ───
    step "REDIS" "Redis yedekleniyor..."
    local redis_admin_pass
    redis_admin_pass=$(grep "^REDIS_ADMIN_PASS=" "${SRVCTL_CONF}" 2>/dev/null | cut -d= -f2)
    if [[ -n "$redis_admin_pass" ]]; then
        # Parolayı argv'den uzak tut: REDISCLI_AUTH env (ps'te görünmez).
        REDISCLI_AUTH="$redis_admin_pass" redis-cli --user admin --no-auth-warning BGSAVE 2>/dev/null || true
        sleep 2
    fi
    cp /var/lib/redis/dump.rdb "${backup_path}/redis.rdb" 2>/dev/null || true
    _backup_secure_artifact "${backup_path}/redis.rdb"
    success "Redis yedeklendi"

    # ─── Config yedek ───
    step "CONFIG" "Konfigürasyonlar yedekleniyor..."
    tar czf "${backup_path}/configs.tar.gz" \
        /etc/nginx/sites-available/ \
        /etc/php/ \
        /etc/redis/ \
        /etc/mysql/mariadb.conf.d/ \
        /etc/apparmor.d/srvctl-* \
        /etc/fail2ban/jail.local \
        /usr/local/srvctl/conf/ \
        2>/dev/null || true
    _backup_secure_artifact "${backup_path}/configs.tar.gz"
    success "Konfigürasyonlar yedeklendi"

    # ─── Toplam boyut ───
    local total_size
    total_size=$(du -sh "${backup_path}" 2>/dev/null | awk '{print $1}')

    # ─── Eski yedekleri temizle ───
    local cleaned=0
    if [[ -d "$BACKUP_DIR" ]]; then
        while IFS= read -r old_backup; do
            [[ -z "$old_backup" ]] && continue
            rm -rf "$old_backup"
            cleaned=$((cleaned + 1))
        done < <(find "${BACKUP_DIR}" -maxdepth 1 -type d -mtime +"${BACKUP_RETENTION_DAYS}" ! -name "$(basename "${BACKUP_DIR}")")
    fi

    header "✅ Yedekleme Tamamlandı"

    echo "  Dizin:    ${backup_path}"
    echo "  Boyut:    ${total_size}"
    echo "  DB:       ${db_count} adet"
    echo "  Dosya:    ${file_count} domain"
    if [[ $cleaned -gt 0 ]]; then
        echo "  Temizlik: ${cleaned} eski yedek silindi"
    fi
    echo ""

    log_action "BACKUP: ${backup_path} (size=${total_size}, dbs=${db_count}, files=${file_count})"
}

_backup_list() {
    echo ""
    echo -e "  ${BOLD}Yedekler${NC}"
    divider
    printf "  ${DIM}%-25s %-10s %-10s${NC}\n" "TARİH" "BOYUT" "İÇERİK"
    divider

    local count=0
    for dir in "${BACKUP_DIR}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local name
        name=$(basename "$dir")
        local size
        size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
        local contents
        contents=$(ls "$dir" 2>/dev/null | wc -l)

        printf "  %-25s %-10s %-10s\n" "$name" "$size" "${contents} dosya"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        echo "  Henüz yedek yok."
    fi

    divider
    echo "  Toplam: ${count} yedek"
    echo ""
}

_backup_restore() {
    local backup_path="$1"
    [[ -z "$backup_path" ]] && error "Yedek dizini belirtilmedi."

    # Tam yol yoksa BACKUP_DIR altında ara
    if [[ ! -d "$backup_path" ]]; then
        backup_path="${BACKUP_DIR}/${backup_path}"
    fi
    [[ -d "$backup_path" ]] || error "Yedek bulunamadı: ${backup_path}"

    header "Geri Yükleme: $(basename "${backup_path}")"

    warn "Bu işlem mevcut verilerin ÜZERİNE yazacaktır!"
    confirm "Devam etmek istiyor musunuz?" || { info "İptal edildi."; return 0; }

    # DB geri yükleme
    for sql_gz in "${backup_path}"/*.sql.gz; do
        [[ ! -f "$sql_gz" ]] && continue
        local db_name
        db_name=$(basename "$sql_gz" .sql.gz)
        step "DB" "Geri yükleniyor: ${db_name}"
        zcat "$sql_gz" | mysql "$db_name" 2>/dev/null && \
            success "DB geri yüklendi: ${db_name}" || \
            warn "DB geri yükleme hatası: ${db_name}"
    done

    # Dosya geri yükleme (safe_extract — zip-slip/symlink reddi, WEB_ROOT altına)
    for tar_gz in "${backup_path}"/*-files.tar.gz; do
        [[ ! -f "$tar_gz" ]] && continue
        local domain
        domain=$(basename "$tar_gz" -files.tar.gz)
        step "FILES" "Geri yükleniyor: ${domain}"
        if _backup_restore_files "$tar_gz" "${WEB_ROOT}"; then
            success "Dosyalar geri yüklendi: ${domain}"
        else
            warn "Güvenli çıkarma reddedildi (mutlak yol/.. /symlink): ${domain}"
            warn "Eski mutlak yollu yedekler için güvenilir ortamda manuel çıkarın."
        fi
    done

    # Redis
    if [[ -f "${backup_path}/redis.rdb" ]]; then
        step "REDIS" "Redis geri yükleniyor..."
        systemctl stop redis-server 2>/dev/null || true
        cp "${backup_path}/redis.rdb" /var/lib/redis/dump.rdb
        chown redis:redis /var/lib/redis/dump.rdb
        systemctl start redis-server
        success "Redis geri yüklendi"
    fi

    success "Geri yükleme tamamlandı"
    log_action "RESTORE: $(basename "${backup_path}")"
}
