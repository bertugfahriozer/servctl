#!/bin/bash
# ═══════════════════════════════════════════════
#  core.sh — Ortak fonksiyonlar
# ═══════════════════════════════════════════════

SRVCTL_VERSION="1.0.0"
SRVCTL_ROOT="/usr/local/srvctl"
SRVCTL_CONF="${SRVCTL_ROOT}/conf/srvctl.conf"
SRVCTL_LOG="${SRVCTL_ROOT}/logs/srvctl.log"
SRVCTL_TEMPLATES="${SRVCTL_ROOT}/templates"

# ─── Renkler ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Log Fonksiyonları ───
info()    { echo -e "  ${BLUE}ℹ${NC}  $*"; }
success() { echo -e "  ${GREEN}✓${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "  ${RED}✗${NC}  $*" >&2; exit 1; }
step()    { echo -e "  ${CYAN}[${1}]${NC} ${2}"; }

log_action() {
    mkdir -p "$(dirname "${SRVCTL_LOG}")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$(whoami)] $*" >> "${SRVCTL_LOG}"
}

# ─── Ayırıcılar ───
header() {
    echo ""
    echo -e "  ${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}  $*${NC}"
    echo -e "  ${BOLD}═══════════════════════════════════════════════${NC}"
    echo ""
}

divider() {
    echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
}

# ─── Yapılandırma ───
load_config() {
    if [[ -f "$SRVCTL_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$SRVCTL_CONF"
    fi
    # Varsayılanlar
    DEFAULT_PHP_VERSION="${DEFAULT_PHP_VERSION:-8.3}"
    SSH_PORT="${SSH_PORT:-2222}"
    WEB_ROOT="${WEB_ROOT:-/var/www}"
    BACKUP_DIR="${BACKUP_DIR:-/backups}"
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
    DEPLOYER_USER="${DEPLOYER_USER:-deployer}"
}

load_config

# ─── Yardımcı Fonksiyonlar ───

# ─── Portable stat sarmalayıcıları (GNU -c / BSD -f) ───
# macOS geliştirme kutusunda GNU stat yoktur; ikisini de dene.

# Bir yolun sahibinin kullanıcı adını yaz
_stat_owner() {
    stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1"
}

# Bir yolun octal izinlerini yaz
_stat_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# ─── Girdi Doğrulayıcıları (PREDIKAT: 0=geçerli 1=geçersiz; çıktı YOK, exit YOK) ───
# Çağıran taraf karar verir:  validate_x "$v" || error "..."

# Domain adı: harf/rakam ile başlar-biter, içeride .-, '..'/'/'/baştaki nokta yok, ≤253
validate_domain() {
    local name="$1"
    [[ -n "$name" ]] || return 1
    (( ${#name} <= 253 )) || return 1
    [[ "$name" == *".."* ]] && return 1
    [[ "$name" == *"/"* ]] && return 1
    [[ "$name" == "."* ]] && return 1
    [[ "$name" == *"."* ]] && [[ "$name" == *".-"* ]] && return 1
    [[ "$name" == *"-."* ]] && return 1
    [[ "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]
}

# Güvenli tanımlayıcı (DB adı/kullanıcı): yalnız harf/rakam/alt-çizgi
assert_safe_ident() {
    [[ "$1" =~ ^[a-zA-Z0-9_]+$ ]]
}

# PHP versiyonu: N.N
assert_php_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+$ ]]
}

# nginx regex token: yalnız [A-Za-z0-9_./|-]; {,},;,boşluk,newline yasak
assert_regex_safe() {
    local v="$1"
    [[ -n "$v" ]] || return 1
    [[ "$v" == *"{"* || "$v" == *"}"* || "$v" == *";"* ]] && return 1
    [[ "$v" =~ [[:space:]] ]] && return 1
    [[ "$v" =~ ^[A-Za-z0-9_./\|-]+$ ]]
}

# Linux kullanıcı adı: [a-z_] ile başlar, [a-z0-9_-], ≤32
validate_username() {
    local v="$1"
    (( ${#v} <= 32 )) || return 1
    [[ "$v" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

# IPv4/IPv6/CIDR
validate_ip_or_cidr() {
    local v="$1" addr="$1" prefix="" max=""
    [[ -n "$v" ]] || return 1
    if [[ "$v" == */* ]]; then
        addr="${v%/*}"; prefix="${v#*/}"
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    fi
    # IPv4?
    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local o
        for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
            (( o <= 255 )) || return 1
        done
        max=32
    # IPv6? (kabaca: hex grupları ve :: kısaltması)
    elif [[ "$addr" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ || "$addr" =~ ^::1$ || "$addr" =~ ^([0-9a-fA-F]{0,4}:)+:?([0-9a-fA-F]{0,4})$ ]]; then
        max=128
    else
        return 1
    fi
    if [[ -n "$prefix" ]]; then
        (( prefix <= max )) || return 1
    fi
    return 0
}

# İşaretsiz tamsayı; opsiyonel üst sınır
validate_uint() {
    local v="$1" max="${2:-}"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    if [[ -n "$max" ]]; then
        (( v <= max )) || return 1
    fi
    return 0
}

# Ülke kodu: 2 büyük harf
validate_country() {
    [[ "$1" =~ ^[A-Z]{2}$ ]]
}

# Root kontrolü
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Bu komut root yetkisi gerektirir. Kullanım: sudo srvctl $*"
    fi
}

# Domain adından güvenli kullanıcı adı üret
# example.com → example_com
safe_name() {
    echo "$1" | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]'
}

# Domain varlığını kontrol et
domain_exists() {
    local domain="$1"
    [[ -d "${WEB_ROOT}/${domain}" ]]
}

# Güçlü şifre üret
generate_password() {
    local length="${1:-24}"
    openssl rand -base64 48 | tr -d '/+=\n' | head -c "$length"
}

# PHP versiyonunun kurulu olup olmadığını kontrol et
php_version_exists() {
    local ver="$1"
    [[ -x "/usr/sbin/php-fpm${ver}" ]] || [[ -f "/etc/php/${ver}/fpm/php-fpm.conf" ]]
}

# Nginx config test
nginx_test() {
    if ! nginx -t 2>/dev/null; then
        error "Nginx yapılandırma hatası! 'nginx -t' ile kontrol edin."
    fi
}

# Onay iste
confirm() {
    local message="${1:-Devam etmek istiyor musunuz?}"
    read -rp "  ${message} (evet/hayır): " answer
    [[ "$answer" == "evet" ]]
}

# Template dosyasını işle — değişkenleri yerine koy
# Kullanım: render_template template.tpl VAR1=value1 VAR2=value2
render_template() {
    local template="$1"
    shift

    if [[ ! -f "$template" ]]; then
        error "Template bulunamadı: ${template}"
    fi

    local content
    content=$(cat "$template")

    for pair in "$@"; do
        local key="${pair%%=*}"
        local value="${pair#*=}"
        content="${content//\{\{${key}\}\}/${value}}"
    done

    echo "$content"
}

# Servis durumunu kontrol et
service_is_active() {
    systemctl is-active "$1" > /dev/null 2>&1
}

# Tüm domain'leri listele (sadece isimler)
list_all_domains() {
    for dir in "${WEB_ROOT}"/*/; do
        [[ -d "$dir" ]] && basename "$dir"
    done
}

# Credentials dosyasını oku
read_credentials() {
    local domain="$1"
    local creds_file="${WEB_ROOT}/${domain}/.credentials"
    if [[ -f "$creds_file" ]]; then
        # shellcheck disable=SC1090
        source "$creds_file"
    fi
}

# ─── Rate-Limit Profilleri ───
SRVCTL_RATE_PROFILES="${SRVCTL_RATE_PROFILES:-${SRVCTL_ROOT}/conf/rate-profiles.conf}"

# PHP-geneli varsayılan hassas yol regex'i (login/admin brute-force koruması)
DEFAULT_SENSITIVE_PATHS='login|admin|auth|panel|dashboard|wp-login\.php|wp-admin|user/login'

# Bir profilin conf satırını getir (yorum/boş satırlar hariç)
rate_profile_line() {
    [[ -f "$SRVCTL_RATE_PROFILES" ]] || return 1
    grep -E "^${1}:" "$SRVCTL_RATE_PROFILES" 2>/dev/null | grep -v '^#' | head -1
}

# Bir profilin N. alanını getir (1=ad 2=req_zone 3=req_burst 4=login_zone 5=login_burst 6=conn)
rate_profile_field() {
    local line
    line=$(rate_profile_line "$1") || return 1
    [[ -z "$line" ]] && return 1
    echo "$line" | cut -d: -f"$2"
}

# Tüm profil adlarını listele
rate_profile_names() {
    [[ -f "$SRVCTL_RATE_PROFILES" ]] || return 1
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$SRVCTL_RATE_PROFILES" | cut -d: -f1
}

# Geçerli profil adını döndür; geçersiz/boş ise 'standard'a düş (uyarı stderr'e)
rate_profile_resolve() {
    local profile="$1"
    if [[ -n "$profile" && -n "$(rate_profile_line "$profile")" ]]; then
        echo "$profile"
    else
        [[ -n "$profile" ]] && warn "Bilinmeyen rate-limit profili: ${profile} — 'standard' kullanılıyor" >&2
        echo "standard"
    fi
}

# Profili global RL_* değişkenlerine yükle
rate_profile_load() {
    local profile
    profile=$(rate_profile_resolve "$1")
    RL_PROFILE="$profile"
    RL_REQ_ZONE=$(rate_profile_field "$profile" 2)
    RL_REQ_BURST=$(rate_profile_field "$profile" 3)
    RL_LOGIN_ZONE=$(rate_profile_field "$profile" 4)
    RL_LOGIN_BURST=$(rate_profile_field "$profile" 5)
    RL_CONN=$(rate_profile_field "$profile" 6)
}

# ─── Per-Domain Meta (sır değil) ───

# Domain meta dosyasını oku → RATE_PROFILE, SENSITIVE_PATHS değişkenlerine
read_meta() {
    local meta_file="${WEB_ROOT}/${1}/.srvctl-meta"
    if [[ -f "$meta_file" ]]; then
        # shellcheck disable=SC1090
        source "$meta_file"
    fi
}

# Meta dosyasına key=value ekle/güncelle (yoksa oluştur)
write_meta() {
    local domain="$1" key="$2" value="$3"
    local meta_file="${WEB_ROOT}/${domain}/.srvctl-meta"
    # Mevcut anahtarı çıkar (varsa), sonra %q-escape'li olarak yeniden ekle.
    # sed yerine grep-filtre: keyfi değerlerde (| & \ vb.) ve BSD/GNU sed farkında güvenli.
    if [[ -f "$meta_file" ]]; then
        grep -v "^${key}=" "$meta_file" > "${meta_file}.tmp" 2>/dev/null || true
        mv "${meta_file}.tmp" "$meta_file"
    fi
    printf '%s=%q\n' "$key" "$value" >> "$meta_file"
    chmod 644 "$meta_file" 2>/dev/null || true
    chown root:root "$meta_file" 2>/dev/null || true
}
