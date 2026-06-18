#!/bin/bash
# ═══════════════════════════════════════════════
#  user.sh — RBAC Kullanıcı Yönetimi + 2FA
# ═══════════════════════════════════════════════

SRVCTL_USERS_DIR="/etc/srvctl/users"

cmd_user() {
    require_root
    case "${1:-help}" in
        add)      _user_add "${@:2}" ;;
        remove)   _user_remove "${@:2}" ;;
        list)     _user_list ;;
        info)     _user_info "${@:2}" ;;
        grant)    _user_grant "${@:2}" ;;
        revoke)   _user_revoke "${@:2}" ;;
        key)      _user_key "${@:2}" ;;
        2fa)      _user_2fa "${@:2}" ;;
        audit)    _user_audit "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl user <add|remove|list|info|grant|revoke|key|2fa|audit>"
            echo ""
            echo "    add <username> [--role=admin|developer|viewer]"
            echo "    remove <username>"
            echo "    list"
            echo "    info <username>"
            echo "    grant <username> <domain>     Domain erişimi ver"
            echo "    revoke <username> <domain>    Domain erişimini kaldır"
            echo "    key add <username> <pubkey>   SSH key ekle"
            echo "    key remove <username>         SSH key kaldır"
            echo "    2fa setup <username>          TOTP 2FA etkinleştir"
            echo "    2fa disable <username>        2FA devre dışı bırak"
            echo "    audit [username]              İşlem geçmişi"
            echo ""
            echo "  Roller:"
            echo "    admin       Tüm komutlara erişim"
            echo "    developer   deploy, domain info, backup, status"
            echo "    viewer      status, domain list, domain info"
            echo ""
            ;;
    esac
}

_user_add() {
    local username=""
    local role="developer"

    for arg in "$@"; do
        case "$arg" in
            --role=*) role="${arg#--role=}" ;;
            *) username="$arg" ;;
        esac
    done

    [[ -z "$username" ]] && error "Kullanıcı adı belirtilmedi."
    [[ "$role" =~ ^(admin|developer|viewer)$ ]] || error "Geçersiz rol: ${role}. (admin|developer|viewer)"

    mkdir -p "${SRVCTL_USERS_DIR}"

    [[ -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı zaten mevcut: ${username}"

    # Linux kullanıcısı oluştur
    if ! id "$username" &>/dev/null; then
        useradd -m -s /bin/bash "$username"
        info "Linux kullanıcısı oluşturuldu: ${username}"
    fi

    # SSH dizini
    mkdir -p "/home/${username}/.ssh"
    chmod 700 "/home/${username}/.ssh"
    chown -R "${username}:${username}" "/home/${username}/.ssh"

    # Kullanıcı yapılandırma dosyası
    cat > "${SRVCTL_USERS_DIR}/${username}.conf" << USERCONF
# srvctl kullanıcısı: ${username}
# Oluşturulma: $(date '+%Y-%m-%d %H:%M:%S')
ROLE=${role}
DOMAINS=
CREATED=$(date +%s)
LAST_LOGIN=
2FA_ENABLED=false
2FA_SECRET=
USERCONF
    chmod 600 "${SRVCTL_USERS_DIR}/${username}.conf"

    # sudoers — role göre izinler
    _update_sudoers "$username" "$role"

    success "Kullanıcı oluşturuldu: ${username} (rol: ${role})"
    log_action "USER ADD: ${username} (role=${role})"
}

_user_remove() {
    local username="$1"
    [[ -z "$username" ]] && error "Kullanıcı adı belirtilmedi."
    [[ ! -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı bulunamadı."

    confirm "Kullanıcı silinecek: ${username}. Devam?" || return 0

    # sudoers'dan kaldır
    rm -f "/etc/sudoers.d/srvctl-${username}"

    # Kullanıcı config'i sil
    rm -f "${SRVCTL_USERS_DIR}/${username}.conf"

    # Opsiyonel: Linux kullanıcısını da sil
    if confirm "Linux kullanıcısını da silmek ister misiniz? (home dizini silinir)"; then
        userdel -r "$username" 2>/dev/null || true
    fi

    success "Kullanıcı silindi: ${username}"
    log_action "USER REMOVE: ${username}"
}

_user_list() {
    header "srvctl Kullanıcıları"

    printf "  ${DIM}%-15s %-12s %-30s %-6s${NC}\n" "KULLANICI" "ROL" "DOMAİNLER" "2FA"
    divider

    for conf in "${SRVCTL_USERS_DIR}"/*.conf; do
        [[ ! -f "$conf" ]] && continue
        local username
        username=$(basename "$conf" .conf)

        # shellcheck disable=SC1090
        source "$conf"

        local twofa_icon="❌"
        [[ "${2FA_ENABLED:-false}" == "true" ]] && twofa_icon="✅"

        printf "  %-15s %-12s %-30s %-6s\n" "$username" "${ROLE}" "${DOMAINS:-tümü}" "$twofa_icon"
    done

    echo ""
}

_user_info() {
    local username="$1"
    [[ -z "$username" ]] && error "Kullanıcı adı belirtilmedi."
    [[ ! -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı bulunamadı."

    # shellcheck disable=SC1090
    source "${SRVCTL_USERS_DIR}/${username}.conf"

    header "Kullanıcı: ${username}"

    echo "  Rol:            ${ROLE}"
    echo "  Domain'ler:     ${DOMAINS:-tümü (admin)}"
    echo "  Oluşturulma:    $(date -d "@${CREATED}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${CREATED}")"
    echo "  Son giriş:      ${LAST_LOGIN:-bilinmiyor}"
    echo "  2FA:            ${2FA_ENABLED:-false}"

    divider

    # SSH key'ler
    echo -e "  ${CYAN}SSH Key'ler${NC}"
    if [[ -f "/home/${username}/.ssh/authorized_keys" ]]; then
        local key_count
        key_count=$(wc -l < "/home/${username}/.ssh/authorized_keys")
        echo "  ${key_count} key tanımlı"
    else
        echo "  Henüz key eklenmemiş"
    fi

    divider

    # Son işlemler
    echo -e "  ${CYAN}Son İşlemler${NC}"
    grep "\[${username}\]" "${SRVCTL_LOG}" 2>/dev/null | tail -5 || echo "  İşlem kaydı yok"

    echo ""
}

_user_grant() {
    local username="$1" domain="$2"
    [[ -z "$domain" ]] && error "Kullanım: srvctl user grant <username> <domain>"
    [[ ! -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı bulunamadı."

    local current_domains
    current_domains=$(grep "^DOMAINS=" "${SRVCTL_USERS_DIR}/${username}.conf" | cut -d= -f2)

    if [[ -z "$current_domains" ]]; then
        sed -i "s|^DOMAINS=|DOMAINS=${domain}|" "${SRVCTL_USERS_DIR}/${username}.conf"
    else
        sed -i "s|^DOMAINS=.*|DOMAINS=${current_domains},${domain}|" "${SRVCTL_USERS_DIR}/${username}.conf"
    fi

    # Domain'in web grubuna ekle
    local sname
    sname=$(safe_name "$domain")
    usermod -aG "web_${sname}" "$username" 2>/dev/null || true

    success "${username} → ${domain} erişimi verildi"
    log_action "USER GRANT: ${username} → ${domain}"
}

_user_revoke() {
    local username="$1" domain="$2"
    [[ -z "$domain" ]] && error "Kullanım: srvctl user revoke <username> <domain>"
    [[ ! -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı bulunamadı."

    # Domain'i listeden kaldır
    local current
    current=$(grep "^DOMAINS=" "${SRVCTL_USERS_DIR}/${username}.conf" | cut -d= -f2)
    local new_domains
    new_domains=$(echo "$current" | tr ',' '\n' | grep -v "^${domain}$" | tr '\n' ',' | sed 's/,$//')
    sed -i "s|^DOMAINS=.*|DOMAINS=${new_domains}|" "${SRVCTL_USERS_DIR}/${username}.conf"

    # Gruptan çıkar
    local sname
    sname=$(safe_name "$domain")
    gpasswd -d "$username" "web_${sname}" 2>/dev/null || true

    success "${username} → ${domain} erişimi kaldırıldı"
    log_action "USER REVOKE: ${username} → ${domain}"
}

_user_key() {
    local action="$1" username="$2" pubkey="$3"

    case "$action" in
        add)
            [[ -z "$pubkey" ]] && error "Kullanım: srvctl user key add <username> <pubkey_dosyası_veya_string>"
            [[ ! -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı bulunamadı."

            local auth_keys="/home/${username}/.ssh/authorized_keys"
            mkdir -p "/home/${username}/.ssh"

            # Dosya mı string mi?
            if [[ -f "$pubkey" ]]; then
                cat "$pubkey" >> "$auth_keys"
            else
                echo "$pubkey" >> "$auth_keys"
            fi

            chmod 600 "$auth_keys"
            chown "${username}:${username}" "$auth_keys"

            success "SSH key eklendi: ${username}"
            log_action "USER KEY ADD: ${username}"
            ;;
        remove)
            [[ -z "$username" ]] && error "Kullanıcı adı belirtilmedi."
            > "/home/${username}/.ssh/authorized_keys" 2>/dev/null
            success "Tüm SSH key'ler kaldırıldı: ${username}"
            log_action "USER KEY REMOVE: ${username}"
            ;;
        *)
            error "Kullanım: srvctl user key <add|remove> <username>"
            ;;
    esac
}

_user_2fa() {
    local action="$1" username="$2"
    [[ -z "$username" ]] && error "Kullanıcı adı belirtilmedi."
    [[ ! -f "${SRVCTL_USERS_DIR}/${username}.conf" ]] && error "Kullanıcı bulunamadı."

    case "$action" in
        setup)
            # google-authenticator yüklü mü?
            if ! command -v google-authenticator &>/dev/null; then
                info "libpam-google-authenticator kuruluyor..."
                apt-get install -y -qq libpam-google-authenticator > /dev/null 2>&1 || \
                    error "google-authenticator kurulamadı."
            fi

            # TOTP secret oluştur
            local secret
            secret=$(head -c 20 /dev/urandom | base32 | head -c 16)

            sed -i "s|^2FA_ENABLED=.*|2FA_ENABLED=true|" "${SRVCTL_USERS_DIR}/${username}.conf"
            sed -i "s|^2FA_SECRET=.*|2FA_SECRET=${secret}|" "${SRVCTL_USERS_DIR}/${username}.conf"

            # google-authenticator dosyasını oluştur
            su - "$username" -c "google-authenticator -t -d -f -r 3 -R 30 -W -s /home/${username}/.google_authenticator" 2>/dev/null || {
                # Manuel oluştur
                echo "${secret}" > "/home/${username}/.google_authenticator"
                echo '"RATE_LIMIT 3 30' >> "/home/${username}/.google_authenticator"
                echo '" DISALLOW_REUSE' >> "/home/${username}/.google_authenticator"
                echo '" TOTP_AUTH' >> "/home/${username}/.google_authenticator"
                chmod 400 "/home/${username}/.google_authenticator"
                chown "${username}:${username}" "/home/${username}/.google_authenticator"
            }

            # PAM yapılandır
            if ! grep -q "pam_google_authenticator" /etc/pam.d/sshd 2>/dev/null; then
                echo "auth required pam_google_authenticator.so" >> /etc/pam.d/sshd
                sed -i 's/^ChallengeResponseAuthentication no/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null
                systemctl restart sshd 2>/dev/null || true
            fi

            header "2FA Etkinleştirildi: ${username}"
            echo "  Secret Key:  ${secret}"
            echo ""
            echo "  Google Authenticator veya benzeri uygulamaya"
            echo "  bu secret key'i girin."
            echo ""
            echo "  veya QR kodu için:"
            echo "  otpauth://totp/srvctl:${username}?secret=${secret}&issuer=srvctl"
            echo ""

            log_action "USER 2FA SETUP: ${username}"
            ;;
        disable)
            sed -i "s|^2FA_ENABLED=.*|2FA_ENABLED=false|" "${SRVCTL_USERS_DIR}/${username}.conf"
            rm -f "/home/${username}/.google_authenticator"
            success "2FA devre dışı bırakıldı: ${username}"
            log_action "USER 2FA DISABLE: ${username}"
            ;;
        *)
            error "Kullanım: srvctl user 2fa <setup|disable> <username>"
            ;;
    esac
}

_user_audit() {
    local username="$1"

    header "İşlem Geçmişi"

    if [[ -n "$username" ]]; then
        grep "\[${username}\]" "${SRVCTL_LOG}" 2>/dev/null | tail -30 || echo "  Kayıt yok"
    else
        tail -50 "${SRVCTL_LOG}" 2>/dev/null || echo "  Kayıt yok"
    fi

    echo ""
}

_update_sudoers() {
    local username="$1"
    local role="$2"
    local sudoers_file="/etc/sudoers.d/srvctl-${username}"

    case "$role" in
        admin)
            cat > "$sudoers_file" << SUDOERS
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl *
SUDOERS
            ;;
        developer)
            cat > "$sudoers_file" << SUDOERS
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl deploy *
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl domain info *
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl domain list
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl backup run *
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl status
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl ssl status
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl monitor *
SUDOERS
            ;;
        viewer)
            cat > "$sudoers_file" << SUDOERS
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl status
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl domain list
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl domain info *
${username} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl ssl status
SUDOERS
            ;;
    esac
    chmod 440 "$sudoers_file"
}
