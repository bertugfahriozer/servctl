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

# CF listesinden nginx real-ip bloğu üret (stdout). Yalnız Cloudflare aralıkları.
_trusted_render_realip() {
    local file="$1" ip
    echo "# srvctl — Cloudflare real IP (otomatik oluşturuldu)"
    if [[ -f "$file" ]]; then
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && echo "set_real_ip_from ${ip};"
        done < "$file"
    fi
    echo "real_ip_header CF-Connecting-IP;"
}

# ignoreip satırını türet: base + verilen dosyalardaki IP'ler, sıra-koruyan dedup,
# tek satır (stdout). Eksik dosyalar atlanır.
_trusted_compute_ignoreip() {
    local base="$1"; shift
    local f ip
    {
        printf '%s\n' "$base"
        for f in "$@"; do
            [[ -f "$f" ]] || continue
            while IFS= read -r ip; do
                [[ -n "$ip" ]] && printf '%s\n' "$ip"
            done < "$f"
        done
    } | awk 'NF && !seen[$0]++' | paste -sd' ' -
}
