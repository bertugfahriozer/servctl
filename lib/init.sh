#!/bin/bash
# ═══════════════════════════════════════════════
#  init.sh — Sunucu İlk Kurulumu (tek seferlik)
#  12 güvenlik katmanını otomatik yapılandırır
# ═══════════════════════════════════════════════

cmd_init() {
    require_root

    header "srvctl init — Sunucu İlk Kurulumu"

    local total=10
    local current=0

    # ─── 1. Sistem Güncellemesi ───
    current=$((current + 1))
    step "${current}/${total}" "Sistem güncelleniyor..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq \
        software-properties-common curl wget gnupg2 \
        unattended-upgrades apt-listchanges \
        acl auditd audispd-plugins \
        apparmor apparmor-utils \
        logrotate rsync git jq certbot \
        python3-certbot-nginx \
        > /dev/null 2>&1
    success "Sistem güncellendi ve bağımlılıklar kuruldu"

    # ─── 2. Kernel Hardening ───
    current=$((current + 1))
    step "${current}/${total}" "Kernel güvenlik ayarları..."
    cat > /etc/sysctl.d/99-srvctl-security.conf << 'SYSCTL'
# ─── Network Security ───
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
# IPv6 kapalı
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
# ─── Kernel Security ───
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
kernel.sysrq = 0
# ─── Filesystem ───
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
SYSCTL
    sysctl -p /etc/sysctl.d/99-srvctl-security.conf > /dev/null 2>&1
    success "Kernel hardening uygulandı"

    # ─── 3. Process izolasyonu ───
    current=$((current + 1))
    step "${current}/${total}" "Process izolasyonu (hidepid)..."
    if ! grep -q "hidepid=2" /etc/fstab; then
        echo "proc /proc proc defaults,hidepid=2,gid=adm 0 0" >> /etc/fstab
    fi
    if ! grep -q "/run/shm.*noexec" /etc/fstab; then
        echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0" >> /etc/fstab
    fi
    mount -o remount /proc 2>/dev/null || true
    success "hidepid=2 aktif — process'ler izole"

    # ─── 4. SSH Hardening ───
    current=$((current + 1))
    step "${current}/${total}" "SSH güvenlik ayarları (Port: ${SSH_PORT})..."
    cat > /etc/ssh/sshd_config.d/99-srvctl.conf << SSHCONF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group16-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
SSHCONF
    systemctl restart sshd 2>/dev/null || true
    success "SSH hardening uygulandı"

    # ─── 5. Firewall ───
    current=$((current + 1))
    step "${current}/${total}" "Firewall (UFW)..."
    ufw --force reset > /dev/null 2>&1
    ufw default deny incoming > /dev/null 2>&1
    ufw default allow outgoing > /dev/null 2>&1
    ufw allow "${SSH_PORT}/tcp" comment 'SSH' > /dev/null 2>&1
    ufw allow 80/tcp comment 'HTTP' > /dev/null 2>&1
    ufw allow 443/tcp comment 'HTTPS' > /dev/null 2>&1
    ufw limit "${SSH_PORT}/tcp" > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
    success "UFW aktif — sadece ${SSH_PORT}, 80, 443 açık"

    # ─── 6. Nginx ───
    current=$((current + 1))
    step "${current}/${total}" "Nginx kuruluyor..."
    _install_nginx
    success "Nginx kuruldu ve yapılandırıldı"

    # ─── 7. PHP-FPM ───
    current=$((current + 1))
    step "${current}/${total}" "PHP-FPM kuruluyor..."
    _install_php
    success "PHP-FPM kuruldu"

    # ─── 8. MariaDB ───
    current=$((current + 1))
    step "${current}/${total}" "MariaDB kuruluyor..."
    _install_mariadb
    success "MariaDB kuruldu ve güvenlik ayarları yapıldı"

    # ─── 9. Redis ───
    current=$((current + 1))
    step "${current}/${total}" "Redis kuruluyor..."
    _install_redis
    success "Redis kuruldu (ACL aktif)"

    # ─── 10. Fail2Ban + auditd ───
    current=$((current + 1))
    step "${current}/${total}" "Fail2Ban + auditd kuruluyor..."
    _install_fail2ban
    _install_auditd
    _setup_cron_jobs
    _create_deployer_user
    success "Fail2Ban + auditd aktif"

    # ─── Dizinler ───
    mkdir -p "${WEB_ROOT}" "${BACKUP_DIR}" "${SRVCTL_ROOT}/logs"

    # ─── Otomatik güvenlik güncellemeleri ───
    dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true

    header "✅ Sunucu Kurulumu Tamamlandı!"

    echo "  SSH Port:        ${SSH_PORT}"
    echo "  MariaDB root:    /root/.my.cnf"
    echo "  Redis admin:     ${SRVCTL_CONF}"
    echo "  Web root:        ${WEB_ROOT}"
    echo "  Yedek dizini:    ${BACKUP_DIR}"
    echo ""
    echo -e "  ${BOLD}Sonraki adım:${NC}  sudo srvctl domain add <domain.com>"
    echo ""

    log_action "INIT completed successfully"
}

# ═══════════════════════════════════════════════
#  HELPER FONKSİYONLAR
# ═══════════════════════════════════════════════

_install_nginx() {
    # Nginx'in kurulu olup olmadığını kontrol et
    if ! command -v nginx &>/dev/null; then
        apt-get install -y -qq nginx > /dev/null 2>&1
    fi

    # Ana yapılandırma
    cat > /etc/nginx/nginx.conf << 'NGINXCONF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    # ─── Temel ───
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    types_hash_max_size 2048;
    client_max_body_size 50M;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # ─── Log Format ───
    log_format security '$remote_addr - $remote_user [$time_local] '
                        '"$request" $status $body_bytes_sent '
                        '"$http_referer" "$http_user_agent" '
                        '$request_time $upstream_response_time';

    access_log /var/log/nginx/access.log security;
    error_log /var/log/nginx/error.log warn;

    # ─── Gzip ───
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml application/xml+rss text/javascript
               image/svg+xml application/font-woff2;

    # ─── Rate Limiting ───
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
    limit_req_zone $binary_remote_addr zone=api:10m rate=30r/s;
    limit_conn_zone $binary_remote_addr zone=conn_per_ip:10m;

    # ─── SSL ───
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # ─── Symlink Koruması ───
    disable_symlinks if_not_owner;

    # ─── Bilinmeyen Domain Reddet ───
    server {
        listen 80 default_server;
        server_name _;
        return 444;
    }

    include /etc/nginx/sites-enabled/*.conf;
}
NGINXCONF

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    # Varsayılan site'ı kaldır
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/conf.d/default.conf

    systemctl enable nginx > /dev/null 2>&1
    nginx -t 2>/dev/null && systemctl restart nginx
}

_install_php() {
    # Ondrej PPA
    if [[ ! -f /etc/apt/sources.list.d/ondrej-*.list ]] && ! grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
        add-apt-repository -y ppa:ondrej/php > /dev/null 2>&1
        apt-get update -qq
    fi

    # PHP versiyonlarını kur
    for ver in 8.2 8.3; do
        if ! php_version_exists "$ver"; then
            apt-get install -y -qq \
                "php${ver}-fpm" "php${ver}-cli" "php${ver}-mysql" "php${ver}-redis" \
                "php${ver}-curl" "php${ver}-gd" "php${ver}-mbstring" "php${ver}-xml" \
                "php${ver}-zip" "php${ver}-intl" "php${ver}-bcmath" "php${ver}-opcache" \
                "php${ver}-readline" "php${ver}-soap" \
                > /dev/null 2>&1 || warn "PHP ${ver} kurulumunda bazı paketler atlandı"
        fi

        # PHP güvenlik ayarları
        cat > "/etc/php/${ver}/fpm/conf.d/99-srvctl-security.ini" << 'PHPINI'
expose_php = Off
display_errors = Off
display_startup_errors = Off
log_errors = On
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
disable_functions = exec,passthru,shell_exec,system,proc_open,popen,proc_close,proc_get_status,proc_nice,proc_terminate,pcntl_alarm,pcntl_exec,pcntl_fork,pcntl_get_last_error,pcntl_getpriority,pcntl_setpriority,pcntl_signal,pcntl_signal_dispatch,pcntl_strerror,pcntl_wait,pcntl_waitpid,pcntl_wexitstatus,pcntl_wifexited,pcntl_wifsignaled,pcntl_wifstopped,pcntl_wstopsig,pcntl_wtermsig,dl,putenv,show_source,highlight_file
file_uploads = On
upload_max_filesize = 50M
post_max_size = 55M
max_file_uploads = 10
session.cookie_httponly = 1
session.cookie_secure = 1
session.use_strict_mode = 1
session.cookie_samesite = Strict
session.use_only_cookies = 1
session.name = __Secure_SID
session.gc_maxlifetime = 3600
max_execution_time = 60
max_input_time = 60
memory_limit = 256M
max_input_vars = 5000
allow_url_fopen = Off
allow_url_include = Off
cgi.fix_pathinfo = 0
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = 0
opcache.save_comments = 1
PHPINI

        # Varsayılan www pool'unu devre dışı bırak
        if [[ -f "/etc/php/${ver}/fpm/pool.d/www.conf" ]]; then
            mv "/etc/php/${ver}/fpm/pool.d/www.conf" "/etc/php/${ver}/fpm/pool.d/www.conf.disabled" 2>/dev/null || true
        fi

        systemctl enable "php${ver}-fpm" > /dev/null 2>&1
        systemctl restart "php${ver}-fpm" 2>/dev/null || true
    done
}

_install_mariadb() {
    if ! command -v mysql &>/dev/null; then
        apt-get install -y -qq mariadb-server mariadb-client > /dev/null 2>&1
    fi

    # Güvenlik yapılandırması
    cat > /etc/mysql/mariadb.conf.d/99-srvctl-security.cnf << 'MARIADB'
[mysqld]
bind-address = 127.0.0.1
local-infile = 0
symbolic-links = 0
secure-file-priv = /var/lib/mysql-files
log_error = /var/log/mysql/error.log
slow_query_log = ON
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
innodb_buffer_pool_size = 1G
innodb_log_file_size = 256M
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1
max_connections = 200
thread_cache_size = 16
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[client]
default-character-set = utf8mb4
MARIADB

    mkdir -p /var/lib/mysql-files
    systemctl enable mariadb > /dev/null 2>&1
    systemctl restart mariadb

    # Root şifresi ayarla
    local root_pass
    root_pass=$(generate_password 32)

    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${root_pass}';" 2>/dev/null || true
    mysql -u root -p"${root_pass}" -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
    mysql -u root -p"${root_pass}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost');" 2>/dev/null || true
    mysql -u root -p"${root_pass}" -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
    mysql -u root -p"${root_pass}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true

    # Root credentials dosyası
    cat > /root/.my.cnf << MYCNF
[client]
user=root
password=${root_pass}
MYCNF
    chmod 600 /root/.my.cnf

    info "MariaDB root şifresi: /root/.my.cnf"
}

_install_redis() {
    if ! command -v redis-server &>/dev/null; then
        apt-get install -y -qq redis-server > /dev/null 2>&1
    fi

    local redis_admin_pass
    redis_admin_pass=$(generate_password 32)

    # Redis yapılandırması
    cat > /etc/redis/redis.conf << REDISCONF
# ─── Ağ ───
bind 127.0.0.1
port 6379
protected-mode yes
tcp-backlog 511
timeout 300
tcp-keepalive 300

# ─── ACL ───
aclfile /etc/redis/users.acl

# ─── Tehlikeli Komutları Devre Dışı Bırak ───
rename-command FLUSHALL ""
rename-command FLUSHDB ""
rename-command CONFIG ""
rename-command DEBUG ""
rename-command KEYS ""

# ─── Memory ───
maxmemory 512mb
maxmemory-policy allkeys-lru

# ─── Persistence ───
save 900 1
save 300 10
save 60 10000
dir /var/lib/redis
dbfilename dump.rdb

# ─── Logging ───
loglevel notice
logfile /var/log/redis/redis-server.log
REDISCONF

    # ACL dosyası
    cat > /etc/redis/users.acl << REDISACL
# srvctl Redis ACL
# Admin kullanıcısı — sadece sunucu yönetimi
user admin on >${redis_admin_pass} ~* &* +@all

# Default kullanıcıyı devre dışı bırak
user default off nopass ~* &* -@all
REDISACL

    chmod 640 /etc/redis/redis.conf /etc/redis/users.acl
    chown redis:redis /etc/redis/redis.conf /etc/redis/users.acl

    systemctl enable redis-server > /dev/null 2>&1
    systemctl restart redis-server

    # Admin şifresini kaydet
    if grep -q "REDIS_ADMIN_PASS" "${SRVCTL_CONF}" 2>/dev/null; then
        sed -i "s|^REDIS_ADMIN_PASS=.*|REDIS_ADMIN_PASS=${redis_admin_pass}|" "${SRVCTL_CONF}"
    else
        echo "REDIS_ADMIN_PASS=${redis_admin_pass}" >> "${SRVCTL_CONF}"
    fi

    info "Redis admin şifresi: ${SRVCTL_CONF}"
}

_install_fail2ban() {
    if ! command -v fail2ban-client &>/dev/null; then
        apt-get install -y -qq fail2ban > /dev/null 2>&1
    fi

    cat > /etc/fail2ban/jail.local << FAIL2BAN
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
banaction = ufw
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 3
bantime = 86400

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 3

[nginx-botsearch]
enabled = true
filter = nginx-botsearch
logpath = /var/log/nginx/access.log
maxretry = 2

[nginx-req-limit]
enabled = true
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 5
FAIL2BAN

    systemctl enable fail2ban > /dev/null 2>&1
    systemctl restart fail2ban
}

_install_auditd() {
    cat > /etc/audit/rules.d/99-srvctl.rules << 'AUDIT'
# srvctl audit kuralları
-w /var/www/ -p wa -k web_changes
-w /etc/nginx/ -p wa -k nginx_config
-w /etc/php/ -p wa -k php_config
-w /etc/mysql/ -p wa -k mysql_config
-w /etc/redis/ -p wa -k redis_config
-w /etc/sudoers -p wa -k sudoers_change
-w /etc/passwd -p wa -k passwd_change
-w /etc/shadow -p wa -k shadow_change
-w /etc/ssh/ -p wa -k ssh_config
-w /usr/local/srvctl/ -p wa -k srvctl_config
AUDIT

    systemctl enable auditd > /dev/null 2>&1
    systemctl restart auditd 2>/dev/null || true
}

_setup_cron_jobs() {
    local crontab_content
    crontab_content=$(crontab -l 2>/dev/null || true)

    # SSL yenileme (günde 2 kez)
    if ! echo "$crontab_content" | grep -q "certbot renew"; then
        (echo "$crontab_content"; echo "0 3,15 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx' >> /usr/local/srvctl/logs/ssl.log 2>&1") | crontab -
    fi

    # Günlük yedekleme
    crontab_content=$(crontab -l 2>/dev/null || true)
    if ! echo "$crontab_content" | grep -q "srvctl backup"; then
        (echo "$crontab_content"; echo "0 4 * * * /usr/local/srvctl/bin/srvctl backup run >> /usr/local/srvctl/logs/backup.log 2>&1") | crontab -
    fi
}

_create_deployer_user() {
    if ! id "${DEPLOYER_USER}" &>/dev/null; then
        useradd -m -s /bin/bash "${DEPLOYER_USER}"
        mkdir -p "/home/${DEPLOYER_USER}/.ssh"
        chmod 700 "/home/${DEPLOYER_USER}/.ssh"
        chown -R "${DEPLOYER_USER}:${DEPLOYER_USER}" "/home/${DEPLOYER_USER}/.ssh"

        # Sudo izinleri (sadece reload)
        cat > "/etc/sudoers.d/${DEPLOYER_USER}" << SUDOERS
${DEPLOYER_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl reload php*-fpm
${DEPLOYER_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx
${DEPLOYER_USER} ALL=(root) NOPASSWD: /usr/local/srvctl/bin/srvctl deploy *
SUDOERS
        chmod 440 "/etc/sudoers.d/${DEPLOYER_USER}"

        info "Deployer kullanıcısı: ${DEPLOYER_USER}"
        warn "SSH key ekleyin: /home/${DEPLOYER_USER}/.ssh/authorized_keys"
    fi
}
