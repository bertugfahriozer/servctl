#!/bin/bash
# ═══════════════════════════════════════════════
#  security.sh — Güvenlik Denetimi
#  Tüm katmanları kontrol edip skor verir
# ═══════════════════════════════════════════════

# ───────────────────────────────────────────────────────────────
#  Eval'siz kontrol çalıştırıcı (saf, test edilebilir).
#  Kullanım: _security_run_check <on_ok_fn> <on_bad_fn> <label> <cmd...>
#  cmd argv olarak DOĞRUDAN çalıştırılır — asla eval/string-expand edilmez.
# ───────────────────────────────────────────────────────────────
_security_run_check() {
    local on_ok="$1" on_bad="$2" label="$3"
    shift 3
    if "$@" >/dev/null 2>&1; then
        "$on_ok" "$label"
    else
        "$on_bad" "$label"
    fi
}

cmd_security() {
    require_root
    case "${1:-help}" in
        audit) _security_audit ;;
        *)
            echo ""
            echo "  Kullanım: srvctl security audit"
            echo ""
            ;;
    esac
}

_security_audit() {
    header "🔒 Güvenlik Denetimi"

    local pass=0
    local fail=0
    local warn_count=0

    # ─── Check fonksiyonları ───
    _pass() { echo -e "  ${GREEN}✅ PASS${NC}  $1"; pass=$((pass + 1)); }
    _fail() { echo -e "  ${RED}❌ FAIL${NC}  $1"; fail=$((fail + 1)); }
    _warn_result() { echo -e "  ${YELLOW}⚠️  WARN${NC}  $1"; warn_count=$((warn_count + 1)); }

    # Kullanım: _check "<etiket>" <cmd> <arg...>   (eval YOK — argv doğrudan çalışır)
    _check() {
        local label="$1"; shift
        _security_run_check _pass _fail "$label" "$@"
    }

    _warn_check() {
        local label="$1"; shift
        _security_run_check _pass _warn_result "$label" "$@"
    }

    # ═══ OS GÜVENLİĞİ ═══
    echo ""
    echo -e "  ${CYAN}── OS Güvenliği ──${NC}"
    _check "UFW firewall aktif" \
        bash -c "ufw status 2>/dev/null | grep -q 'Status: active'"
    _check "SSH root login kapalı" \
        bash -c "grep -rq 'PermitRootLogin no' /etc/ssh/sshd_config.d/ 2>/dev/null"
    _check "SSH şifre auth kapalı" \
        bash -c "grep -rq 'PasswordAuthentication no' /etc/ssh/sshd_config.d/ 2>/dev/null"
    _check "SSH varsayılan port değil" \
        bash -c "! grep -rq 'Port 22\$' /etc/ssh/sshd_config.d/ 2>/dev/null"
    _check "hidepid=2 aktif" \
        grep -q hidepid=2 /etc/fstab
    _check "Kernel hardening aktif" \
        test -f /etc/sysctl.d/99-srvctl-security.conf
    _check "symlink koruması (sysctl)" \
        bash -c "sysctl -n fs.protected_symlinks 2>/dev/null | grep -q '1'"
    _check "ASLR aktif (randomize_va_space=2)" \
        bash -c 'test "$(sysctl -n kernel.randomize_va_space 2>/dev/null)" -eq 2'
    _warn_check "Otomatik güvenlik güncellemeleri" \
        systemctl is-enabled unattended-upgrades

    # ═══ SERVİSLER ═══
    echo ""
    echo -e "  ${CYAN}── Servisler ──${NC}"
    _check "Nginx çalışıyor" systemctl is-active nginx
    _check "PHP-FPM çalışıyor" systemctl is-active "php${DEFAULT_PHP_VERSION}-fpm"
    _check "MariaDB çalışıyor" systemctl is-active mariadb
    _check "Redis çalışıyor" systemctl is-active redis-server
    _check "Fail2Ban çalışıyor" systemctl is-active fail2ban
    _check "auditd çalışıyor" systemctl is-active auditd
    _check "AppArmor çalışıyor" systemctl is-active apparmor

    # ═══ NGİNX ═══
    echo ""
    echo -e "  ${CYAN}── Nginx ──${NC}"
    _check "server_tokens off" \
        grep -q 'server_tokens off' /etc/nginx/nginx.conf
    _check "Varsayılan site kapalı" \
        bash -c "! test -f /etc/nginx/sites-enabled/default"
    _check "disable_symlinks aktif" \
        grep -q disable_symlinks /etc/nginx/nginx.conf
    _check "Rate limiting tanımlı" \
        grep -q limit_req_zone /etc/nginx/nginx.conf

    # ═══ MariaDB ═══
    echo ""
    echo -e "  ${CYAN}── MariaDB ──${NC}"
    _check "Sadece localhost dinliyor" \
        grep -q 'bind-address = 127.0.0.1' /etc/mysql/mariadb.conf.d/99-srvctl-security.cnf
    _check "local-infile kapalı" \
        grep -q 'local-infile = 0' /etc/mysql/mariadb.conf.d/99-srvctl-security.cnf
    _check "symbolic-links kapalı" \
        grep -q 'symbolic-links = 0' /etc/mysql/mariadb.conf.d/99-srvctl-security.cnf
    _check "Root şifresi ayarlı" \
        test -f /root/.my.cnf
    _warn_check "Anonim kullanıcı yok" \
        bash -c "! mysql -N -e \"SELECT User FROM mysql.user WHERE User=''\" 2>/dev/null | grep -q '.'"

    # ═══ Redis ═══
    echo ""
    echo -e "  ${CYAN}── Redis ──${NC}"
    _check "Sadece localhost dinliyor" \
        grep -q 'bind 127.0.0.1' /etc/redis/redis.conf
    _check "Protected mode açık" \
        grep -q 'protected-mode yes' /etc/redis/redis.conf
    _check "ACL dosyası mevcut" \
        test -f /etc/redis/users.acl
    _check "Default kullanıcı kapalı" \
        grep -q 'user default off' /etc/redis/users.acl
    _check "FLUSHALL devre dışı" \
        grep -q 'rename-command FLUSHALL' /etc/redis/redis.conf

    # ═══ PHP GÜVENLİĞİ ═══
    echo ""
    echo -e "  ${CYAN}── PHP Güvenliği ──${NC}"
    local php_ini="/etc/php/${DEFAULT_PHP_VERSION}/fpm/conf.d/99-srvctl-security.ini"
    _check "expose_php = Off" \
        grep -q 'expose_php = Off' "${php_ini}"
    _check "display_errors = Off" \
        grep -q 'display_errors = Off' "${php_ini}"
    _check "allow_url_fopen = Off" \
        grep -q 'allow_url_fopen = Off' "${php_ini}"
    _check "allow_url_include = Off" \
        grep -q 'allow_url_include = Off' "${php_ini}"
    _check "disable_functions tanımlı" \
        grep -q disable_functions "${php_ini}"
    _check "Varsayılan www pool kapalı" \
        bash -c "! test -f /etc/php/${DEFAULT_PHP_VERSION}/fpm/pool.d/www.conf"

    # ═══ DOMAİN İZOLASYONU ═══
    echo ""
    echo -e "  ${CYAN}── Domain İzolasyonu ──${NC}"
    local domain_count=0

    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain sname php_ver PHP_VERSION
        domain=$(basename "$dir")
        sname=$(safe_name "$domain")
        php_ver="${DEFAULT_PHP_VERSION}"

        # Credentials'tan PHP versiyon bilgisini parse et (source DEĞİL); her döngüde sıfırla
        if [[ -f "${dir}.credentials" ]]; then
            PHP_VERSION=""
            read_kv_file "${dir}.credentials" PHP_VERSION
            if [[ -n "$PHP_VERSION" ]] && assert_php_version "$PHP_VERSION"; then
                php_ver="$PHP_VERSION"
            fi
        fi

        # Chroot kontrol (php_ver assert_php_version'dan geçti, sname safe_name türevi)
        _check "${domain}: chroot aktif" \
            grep -q chroot "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf"

        # AppArmor kontrol
        _warn_check "${domain}: AppArmor enforce" \
            bash -c "aa-status 2>/dev/null | grep -q 'srvctl-${sname}'"

        # Dosya izinleri
        local perm
        perm=$(stat -c %a "${dir}" 2>/dev/null)
        if [[ "$perm" == "750" ]]; then
            _pass "${domain}: dosya izinleri 750"
        else
            _fail "${domain}: dosya izinleri ${perm} (750 olmalı)"
        fi

        # Socket izinleri
        _check "${domain}: FPM socket mevcut" \
            test -S "/run/php/php${php_ver}-fpm-${sname}.sock"

        domain_count=$((domain_count + 1))
    done

    if [[ $domain_count -eq 0 ]]; then
        info "Henüz domain eklenmemiş"
    fi

    # ═══ Fail2Ban ═══
    echo ""
    echo -e "  ${CYAN}── Fail2Ban ──${NC}"
    local total_banned=0
    while IFS= read -r jail; do
        jail=$(echo "$jail" | xargs)
        [[ -z "$jail" ]] && continue
        local banned
        banned=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
        total_banned=$((total_banned + ${banned:-0}))
        info "${jail}: ${banned:-0} banned IP"
    done < <(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/\n/g')

    # ═══════════════════════════════════════════════════════════════
    #  security.sh — EK KONTROL BLOĞU (Faz 1/7 yeni katmanlar)
    #
    #  Aşağıdaki bloğu lib/security.sh içindeki _security_audit
    #  fonksiyonunda "═══ SONUÇ ═══" satırının HEMEN ÜSTÜNE ekleyin.
    #  (_check/_pass/_fail yardımcıları o fonksiyon kapsamında tanımlı.)
    # ═══════════════════════════════════════════════════════════════

    # ═══ GELİŞMİŞ KATMANLAR (Faz 1) ═══
    echo ""
    echo -e "  ${CYAN}── Gelişmiş Güvenlik ──${NC}"

    _warn_check "ModSecurity WAF aktif" \
        grep -q 'modsecurity on' /etc/nginx/nginx.conf
    _warn_check "OWASP CRS yüklü" \
        test -d /etc/nginx/owasp-crs/rules
    _warn_check "AIDE veritabanı mevcut" \
        bash -c "test -f /var/lib/aide/aide.db.gz -o -f /var/lib/aide/aide.db"
    _warn_check "ClamAV daemon çalışıyor" \
        systemctl is-active clamav-daemon
    _warn_check "cgroups v2 aktif" \
        test -f /sys/fs/cgroup/cgroup.controllers
    _warn_check "srvctl parent slice tanımlı" \
        test -f /etc/systemd/system/srvctl.slice
    _warn_check "PHP-FPM seccomp hardening (SystemCallFilter)" \
        test -f "/etc/systemd/system/php${DEFAULT_PHP_VERSION}-fpm.service.d/10-srvctl-seccomp.conf"
    _warn_check "GeoIP veritabanı mevcut" \
        test -f /usr/share/GeoIP/GeoIP.dat


    # ═══ SONUÇ ═══
    echo ""
    divider
    local total=$((pass + fail + warn_count))
    local score=0
    [[ $total -gt 0 ]] && score=$(( (pass * 100) / total ))

    printf "  ${GREEN}PASS: %-5s${NC}  ${RED}FAIL: %-5s${NC}  ${YELLOW}WARN: %-5s${NC}\n" "$pass" "$fail" "$warn_count"

    local score_color="$RED"
    if [[ $score -ge 90 ]]; then
        score_color="$GREEN"
    elif [[ $score -ge 70 ]]; then
        score_color="$YELLOW"
    fi

    echo ""
    echo -e "  Güvenlik Skoru: ${BOLD}${score_color}${score}/100${NC}"

    if [[ $fail -gt 0 ]]; then
        echo ""
        warn "FAIL olan kontrolleri düzeltin ve tekrar çalıştırın."
    fi

    if [[ $total_banned -gt 0 ]]; then
        echo ""
        info "Toplam ${total_banned} IP banned (Fail2Ban)"
    fi

    echo ""

    log_action "SECURITY AUDIT: pass=${pass} fail=${fail} warn=${warn_count} score=${score}/100"
}
