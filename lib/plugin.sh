#!/bin/bash
# ═══════════════════════════════════════════════
#  plugin.sh — Plugin Sistemi
#  srvctl'yi modüler olarak genişlet
# ═══════════════════════════════════════════════

SRVCTL_PLUGINS_DIR="${SRVCTL_ROOT:-/usr/local/srvctl}/plugins"

cmd_plugin() {
    case "${1:-help}" in
        install)  _plugin_install "${@:2}" ;;
        remove)   _plugin_remove "${@:2}" ;;
        list)     _plugin_list ;;
        enable)   _plugin_enable "${@:2}" ;;
        disable)  _plugin_disable "${@:2}" ;;
        create)   _plugin_create "${@:2}" ;;
        *)
            echo ""
            echo "  Kullanım: srvctl plugin <install|remove|list|enable|disable|create>"
            echo ""
            echo "    install <git_url>       Plugin kur (git repo)"
            echo "    remove <isim>           Plugin kaldır"
            echo "    list                    Yüklü plugin'leri listele"
            echo "    enable <isim>           Plugin'i aktifleştir"
            echo "    disable <isim>          Plugin'i devre dışı bırak"
            echo "    create <isim>           Yeni plugin iskeleti oluştur"
            echo ""
            ;;
    esac
}

_plugin_install() {
    require_root
    local source="$1"
    [[ -z "$source" ]] && error "Git URL veya plugin dizini belirtilmedi."

    mkdir -p "${SRVCTL_PLUGINS_DIR}"

    local plugin_name
    plugin_name=$(basename "$source" .git)

    if [[ -d "${SRVCTL_PLUGINS_DIR}/${plugin_name}" ]]; then
        error "Plugin zaten yüklü: ${plugin_name}"
    fi

    step "1/3" "Plugin indiriliyor: ${plugin_name}"

    if [[ -d "$source" ]]; then
        cp -r "$source" "${SRVCTL_PLUGINS_DIR}/${plugin_name}"
    else
        git clone --depth 1 "$source" "${SRVCTL_PLUGINS_DIR}/${plugin_name}" 2>/dev/null || \
            error "Plugin indirilemedi: ${source}"
    fi

    # Manifest kontrol
    if [[ ! -f "${SRVCTL_PLUGINS_DIR}/${plugin_name}/plugin.conf" ]]; then
        rm -rf "${SRVCTL_PLUGINS_DIR}/${plugin_name}"
        error "Geçersiz plugin: plugin.conf bulunamadı"
    fi

    step "2/3" "Plugin doğrulanıyor..."

    # plugin.conf oku
    # shellcheck disable=SC1090
    source "${SRVCTL_PLUGINS_DIR}/${plugin_name}/plugin.conf"

    # Hook script'leri kontrol et
    local main_script="${SRVCTL_PLUGINS_DIR}/${plugin_name}/main.sh"
    if [[ -f "$main_script" ]]; then
        bash -n "$main_script" 2>/dev/null || {
            rm -rf "${SRVCTL_PLUGINS_DIR}/${plugin_name}"
            error "Plugin syntax hatası: main.sh"
        }
    fi

    step "3/3" "Plugin aktifleştiriliyor..."

    # Aktif olarak işaretle
    touch "${SRVCTL_PLUGINS_DIR}/${plugin_name}/.enabled"

    # Install hook varsa çalıştır
    if [[ -f "${SRVCTL_PLUGINS_DIR}/${plugin_name}/hooks/install.sh" ]]; then
        bash "${SRVCTL_PLUGINS_DIR}/${plugin_name}/hooks/install.sh" 2>/dev/null || true
    fi

    success "Plugin yüklendi: ${plugin_name}"
    echo "  Versiyon:    ${PLUGIN_VERSION:-1.0.0}"
    echo "  Açıklama:    ${PLUGIN_DESCRIPTION:-Belirtilmemiş}"
    echo "  Komut:       srvctl ${plugin_name}"
    echo ""

    log_action "PLUGIN INSTALL: ${plugin_name}"
}

_plugin_remove() {
    require_root
    local name="$1"
    [[ -z "$name" ]] && error "Plugin adı belirtilmedi."
    [[ ! -d "${SRVCTL_PLUGINS_DIR}/${name}" ]] && error "Plugin bulunamadı: ${name}"

    confirm "Plugin silinecek: ${name}. Devam?" || return 0

    # Uninstall hook
    if [[ -f "${SRVCTL_PLUGINS_DIR}/${name}/hooks/uninstall.sh" ]]; then
        bash "${SRVCTL_PLUGINS_DIR}/${name}/hooks/uninstall.sh" 2>/dev/null || true
    fi

    rm -rf "${SRVCTL_PLUGINS_DIR}/${name}"
    success "Plugin kaldırıldı: ${name}"
    log_action "PLUGIN REMOVE: ${name}"
}

_plugin_list() {
    header "Yüklü Plugin'ler"

    printf "  ${DIM}%-20s %-10s %-8s %-35s${NC}\n" "İSİM" "VERSİYON" "DURUM" "AÇIKLAMA"
    divider

    local count=0
    for plugin_dir in "${SRVCTL_PLUGINS_DIR}"/*/; do
        [[ ! -d "$plugin_dir" ]] && continue
        local name
        name=$(basename "$plugin_dir")

        local version="?" description="?" status_text

        if [[ -f "${plugin_dir}/plugin.conf" ]]; then
            # shellcheck disable=SC1090
            source "${plugin_dir}/plugin.conf"
            version="${PLUGIN_VERSION:-?}"
            description="${PLUGIN_DESCRIPTION:-?}"
        fi

        if [[ -f "${plugin_dir}/.enabled" ]]; then
            status_text="${GREEN}aktif${NC}"
        else
            status_text="${DIM}kapalı${NC}"
        fi

        printf "  %-20s %-10s %-8b %-35s\n" "$name" "$version" "$status_text" "$description"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        echo "  Henüz plugin yüklenmemiş."
    fi

    divider
    echo "  Toplam: ${count} plugin"
    echo ""
}

_plugin_enable() {
    local name="$1"
    [[ -z "$name" ]] && error "Plugin adı belirtilmedi."
    [[ ! -d "${SRVCTL_PLUGINS_DIR}/${name}" ]] && error "Plugin bulunamadı."

    touch "${SRVCTL_PLUGINS_DIR}/${name}/.enabled"
    success "Plugin aktifleştirildi: ${name}"
}

_plugin_disable() {
    local name="$1"
    [[ -z "$name" ]] && error "Plugin adı belirtilmedi."
    [[ ! -d "${SRVCTL_PLUGINS_DIR}/${name}" ]] && error "Plugin bulunamadı."

    rm -f "${SRVCTL_PLUGINS_DIR}/${name}/.enabled"
    success "Plugin devre dışı bırakıldı: ${name}"
}

_plugin_create() {
    local name="$1"
    [[ -z "$name" ]] && error "Plugin adı belirtilmedi."

    local dir="${SRVCTL_PLUGINS_DIR}/${name}"
    mkdir -p "${dir}/hooks"

    # plugin.conf
    cat > "${dir}/plugin.conf" << CONF
PLUGIN_NAME="${name}"
PLUGIN_VERSION="1.0.0"
PLUGIN_DESCRIPTION="Yeni plugin açıklaması"
PLUGIN_AUTHOR="$(whoami)"
PLUGIN_COMMANDS="${name}"
CONF

    # main.sh
    cat > "${dir}/main.sh" << 'MAIN'
#!/bin/bash
# Plugin ana modülü

cmd_PLUGIN_NAME() {
    case "${1:-help}" in
        hello)
            echo "  Merhaba, plugin çalışıyor!"
            ;;
        *)
            echo ""
            echo "  Kullanım: srvctl PLUGIN_NAME <hello>"
            echo ""
            ;;
    esac
}
MAIN
    sed -i "s/PLUGIN_NAME/${name}/g" "${dir}/main.sh"

    # install/uninstall hooks
    echo '#!/bin/bash' > "${dir}/hooks/install.sh"
    echo '# Kurulum sonrası çalışır' >> "${dir}/hooks/install.sh"
    echo '#!/bin/bash' > "${dir}/hooks/uninstall.sh"
    echo '# Kaldırma öncesi çalışır' >> "${dir}/hooks/uninstall.sh"

    chmod +x "${dir}/main.sh" "${dir}/hooks/"*.sh

    success "Plugin iskeleti oluşturuldu: ${dir}"
    echo ""
    echo "  Düzenleyin: nano ${dir}/main.sh"
    echo "  Etkinleştirin: srvctl plugin enable ${name}"
    echo ""
}

# ─── Plugin Loader (core.sh tarafından çağrılır) ───
load_plugins() {
    [[ ! -d "$SRVCTL_PLUGINS_DIR" ]] && return

    for plugin_dir in "${SRVCTL_PLUGINS_DIR}"/*/; do
        [[ ! -d "$plugin_dir" ]] && continue
        [[ ! -f "${plugin_dir}/.enabled" ]] && continue
        [[ ! -f "${plugin_dir}/main.sh" ]] && continue

        # shellcheck disable=SC1090
        source "${plugin_dir}/main.sh"
    done
}
