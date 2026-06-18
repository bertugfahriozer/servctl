#!/bin/bash
# ═══════════════════════════════════════════════
#  changelog.sh — Değişiklik Kaydı
#  Her srvctl işlemi zaman damgalı olarak loglanır
# ═══════════════════════════════════════════════

CHANGELOG_FILE="${SRVCTL_ROOT:-/usr/local/srvctl}/logs/changelog.log"

cmd_changelog() {
    case "${1:-help}" in
        show)  _changelog_show "${@:2}" ;;
        tail)  _changelog_tail "${@:2}" ;;
        search) _changelog_search "${@:2}" ;;
        export) _changelog_export "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl changelog <show|tail|search|export>"
            echo ""
            echo "    show [N]             Son N işlemi göster (varsayılan: 20)"
            echo "    tail                 Canlı takip (tail -f)"
            echo "    search <terim>       Arama yap"
            echo "    export [dosya]       Değişiklikleri dışa aktar"
            echo ""
            ;;
    esac
}

_changelog_show() {
    local count="${1:-20}"
    header "Son ${count} İşlem"

    if [[ ! -f "$CHANGELOG_FILE" ]]; then
        info "Henüz kayıt yok."
        return
    fi

    printf "  ${DIM}%-20s %-12s %-50s${NC}\n" "TARİH" "KULLANICI" "İŞLEM"
    divider

    tail -"$count" "$CHANGELOG_FILE" 2>/dev/null | while IFS='|' read -r timestamp user action; do
        printf "  %-20s %-12s %-50s\n" "$timestamp" "$user" "$action"
    done

    echo ""
}

_changelog_tail() {
    info "Canlı takip (Ctrl+C ile çıkın)..."
    tail -f "$CHANGELOG_FILE" 2>/dev/null || error "Changelog dosyası bulunamadı."
}

_changelog_search() {
    local term="$1"
    [[ -z "$term" ]] && error "Arama terimi belirtilmedi."

    header "Arama: ${term}"

    grep -i "$term" "$CHANGELOG_FILE" 2>/dev/null | tail -30 | \
    while IFS='|' read -r timestamp user action; do
        printf "  %-20s %-12s %-50s\n" "$timestamp" "$user" "$action"
    done

    echo ""
}

_changelog_export() {
    local output="${1:-/tmp/srvctl-changelog-$(date +%Y%m%d).txt}"

    if [[ ! -f "$CHANGELOG_FILE" ]]; then
        error "Changelog dosyası bulunamadı."
    fi

    cp "$CHANGELOG_FILE" "$output"
    success "Changelog dışa aktarıldı: ${output}"
}

# ─── core.sh'den çağrılan log fonksiyonu ───
# log_to_changelog "İşlem açıklaması"
log_to_changelog() {
    local action="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user="${SUDO_USER:-root}"

    mkdir -p "$(dirname "$CHANGELOG_FILE")"
    echo "${timestamp}|${user}|${action}" >> "$CHANGELOG_FILE"
}
