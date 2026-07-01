#!/bin/bash
# ═══════════════════════════════════════════════
#  srvctl — Güvenilir Edge-IP Senkronu (Cloudflare + UptimeRobot)
#  IP listelerini çeker, allowlist'e (fail2ban ignoreip) işler,
#  Cloudflare için nginx real-IP restorasyonu kurar.
# ═══════════════════════════════════════════════

# Ham IP listesini satır-satır doğrula; yalnız geçerli IP/CIDR'leri stdout'a yaz.
# Yorumlar (#...), boş satırlar, CR ve geçersiz satırlar ayıklanır. Dosya yoksa boş.
_trusted_parse_validate() {
    local file="$1" line
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                 # satır-içi yorumu at
        line="${line//[$' \t\r']/}"        # boşluk/tab/CR temizle
        [[ -n "$line" ]] || continue
        validate_ip_or_cidr "$line" && echo "$line"
    done < "$file"
}

# Liste yeterli mi (boş/çöp yanıt koruması). $1=min satır sayısı, $2=dosya.
_trusted_sane() {
    local min="$1" file="$2" count
    [[ -f "$file" ]] || return 1
    count=$(grep -c . "$file" 2>/dev/null || echo 0)
    (( count >= min ))
}
