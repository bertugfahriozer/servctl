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

# ─── Katı key=value okuyucu (ASLA source/eval) ───
# Kullanım: read_kv_file <dosya> KEY1 KEY2 ...
# Her KEY için: ^KEY= ile eşleşen İLK satırı bul, ilk '='ten sonrasını
# (ham, tırnak çözmeden) global KEY değişkenine ata. Eksik anahtar → değişkene
# dokunma. Her durumda 0 döner. Komut-subst/eval ASLA tetiklenmez.
read_kv_file() {
    local file="$1"; shift
    [[ -f "$file" ]] || return 0
    local k line
    for k in "$@"; do
        line="$(grep -F "${k}=" "$file" 2>/dev/null | head -1)" || true
        [[ -n "$line" ]] || continue
        # İlk '='ten sonrasını ata — komut-substitution YOK (printf -v atama)
        printf -v "$k" '%s' "${line#*=}"
    done
    return 0
}

# ─── Sahiplik kapısı (PREDIKAT: 0=güvenli 1=güvensiz; exit YOK) ───
# <path> ve ${WEB_ROOT}'a kadar (dahil) tüm üst dizinler root sahipli,
# symlink değil ve grup/diğer-yazılabilir değil mi? Değilse 1 döner.
assert_root_owned_path() {
    local path="$1"
    [[ -e "$path" ]] || return 1

    local cur="$path"
    # WEB_ROOT'un kanonik kökü; döngü buraya gelince dahil edip durur.
    local stop
    stop="$(cd "${WEB_ROOT}" 2>/dev/null && pwd -P)" || return 1

    while :; do
        # symlink olmamalı (dosya veya ara dizin)
        [[ -L "$cur" ]] && return 1

        local owner mode
        owner="$(_stat_owner "$cur")" || return 1
        mode="$(_stat_mode "$cur")"   || return 1
        [[ "$owner" == "root" ]] || return 1
        # grup-yazılabilir (mod & 020) veya diğer-yazılabilir (mod & 002) yasak.
        # mode son iki octal hanesi: grup, diğer.
        local last2="${mode: -2}"
        local grp="${last2:0:1}" oth="${last2:1:1}"
        (( (grp & 2) == 0 )) || return 1
        (( (oth & 2) == 0 )) || return 1

        # WEB_ROOT köküne ulaştıysak (onu da kontrol ettik) bitir.
        local curp
        curp="$(cd "$(dirname "$cur")" 2>/dev/null && pwd -P)/$(basename "$cur")" 2>/dev/null || curp="$cur"
        [[ "$cur" == "$stop" || "$curp" == "$stop" ]] && return 0

        local parent
        parent="$(dirname "$cur")"
        [[ "$parent" == "$cur" ]] && return 0   # '/'a ulaştık (WEB_ROOT'tan yukarı çıkma)
        cur="$parent"
    done
}

# ─── Güvenli FS oluşturma (umask 077 altında) ───
# chown macOS dev kutusunda başarısız olabilir → guard'lı; mod/varlık test edilir.
secure_file() {
    local path="$1" mode="${2:-600}"
    ( umask 077; : > "$path" 2>/dev/null || true )
    [[ -e "$path" ]] || { umask 077; : > "$path"; }
    chmod "$mode" "$path"
    chown root:root "$path" 2>/dev/null || true
}

secure_dir() {
    local path="$1" mode="${2:-700}"
    ( umask 077; mkdir -p "$path" )
    chmod "$mode" "$path"
    chown root:root "$path" 2>/dev/null || true
}

# ─── Güvenli arşiv çıkarma (tar/zip-slip + symlink/hardlink reddi) ───
# Çıkarmadan ÖNCE üyeleri listeler; mutlak yol (/), '..' veya symlink/hardlink
# üye varsa HİÇ çıkarmadan 1 döner. Aksi halde dest_dir içine çıkarır, 0 döner.
safe_extract() {
    local archive="$1" dest="$2"
    [[ -f "$archive" ]] || return 1
    [[ -n "$dest" ]] || return 1

    # Verbose listele: 1. sütun mod dizgesi ('l'=symlink, 'h'=hardlink), son sütun ad.
    local listing
    listing="$(tar -tvzf "$archive" 2>/dev/null)" || return 1
    [[ -n "$listing" ]] || return 1

    # Sadece üye adları (mutlak/.. kontrolü için): -tzf isim-bazlı liste.
    local names
    names="$(tar -tzf "$archive" 2>/dev/null)" || return 1

    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        # Mutlak yol
        [[ "$name" == /* ]] && return 1
        # '..' bileşeni (yol içinde herhangi yerde)
        [[ "$name" == ".." || "$name" == "../"* || "$name" == *"/../"* || "$name" == *"/.." ]] && return 1
    done <<< "$names"

    # Symlink/hardlink üyesi: verbose mod dizgesinin ilk karakteri 'l' veya 'h'.
    local line firstchar
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        firstchar="${line:0:1}"
        [[ "$firstchar" == "l" || "$firstchar" == "h" ]] && return 1
    done <<< "$listing"

    # Güvenli: hedefe çıkar.
    mkdir -p "$dest" || return 1
    tar -xzf "$archive" -C "$dest" || return 1
    return 0
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
        # CRLF/config-enjeksiyon koruması: değer satırsonu/CR içeremez.
        # (render-time değişmezi — bu error EXIT eder; charset doğrulaması
        #  çağıran tarafta assert_regex_safe ile yapılır.)
        if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
            error "render_template: '${key}' değeri satırsonu/CR içeriyor — reddedildi"
        fi
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

# Credentials dosyasını oku (source DEĞİL — katı parse)
read_credentials() {
    local domain="$1"
    local creds_file="${WEB_ROOT}/${domain}/.credentials"
    read_kv_file "$creds_file" \
        DOMAIN SAFE_NAME WEB_USER PHP_VERSION \
        DB_NAME DB_USER DB_PASS \
        REDIS_USER REDIS_PASS REDIS_PREFIX
}

# Domain için doğrulanmış PHP versiyonu döndür.
# .credentials'taki PHP_VERSION yalnızca assert_php_version geçerse kullanılır,
# aksi halde verilen fallback (varsayılan DEFAULT_PHP_VERSION) döner.
# Böylece bozuk/saldırgan .credentials root'a path/komut enjekte edemez.
_derive_php() {
    local domain="$1" fallback="${2:-${DEFAULT_PHP_VERSION}}"
    local PHP_VERSION=""
    read_credentials "$domain"
    if [[ -n "${PHP_VERSION:-}" ]] && assert_php_version "${PHP_VERSION}"; then
        echo "${PHP_VERSION}"
    else
        echo "${fallback}"
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

# Domain meta dosyasını oku (source DEĞİL — katı parse)
read_meta() {
    local meta_file="${WEB_ROOT}/${1}/.srvctl-meta"
    read_kv_file "$meta_file" RATE_PROFILE SENSITIVE_PATHS
}

# Meta dosyasına key=value ekle/güncelle (yoksa oluştur)
write_meta() {
    local domain="$1" key="$2" value="$3"
    local meta_file="${WEB_ROOT}/${domain}/.srvctl-meta"
    # Mevcut anahtarı çıkar (varsa), sonra TIRNAKSIZ (%s=%s) yeniden ekle —
    # read_kv_file verbatim okur (source/eval yok), bu yüzden %q gerekmez.
    # sed yerine grep-filtre: keyfi değerlerde (| & \ vb.) ve BSD/GNU sed farkında güvenli.
    if [[ -f "$meta_file" ]]; then
        grep -v "^${key}=" "$meta_file" > "${meta_file}.tmp" 2>/dev/null || true
        mv "${meta_file}.tmp" "$meta_file"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$meta_file"
    chmod 644 "$meta_file" 2>/dev/null || true
    chown root:root "$meta_file" 2>/dev/null || true
}
