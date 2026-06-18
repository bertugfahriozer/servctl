#!/bin/bash
# ═══════════════════════════════════════════════
#  deploy.sh — Git-based Zero-Downtime Deploy
#  Atomic symlink switch ile kesintisiz deploy
# ═══════════════════════════════════════════════

cmd_deploy() {
    require_root

    local domain="$1"
    local branch="${2:-main}"

    [[ -z "$domain" ]] && error "Kullanım: srvctl deploy <domain> [branch]"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    local sname
    sname=$(safe_name "$domain")
    local base="${WEB_ROOT}/${domain}"
    local release_dir="${base}/releases/$(date +%Y%m%d_%H%M%S)"
    local shared_dir="${base}/shared"
    local public_dir="${base}/public_html"

    # Credentials oku
    read_credentials "$domain"
    local php_version="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
    local web_user="${WEB_USER:-web_${sname}}"

    header "Deploy: ${domain} (branch: ${branch})"

    # ─── Git repo URL ───
    local repo_url=""
    local repo_file="${base}/.deploy-repo"

    if [[ -f "$repo_file" ]]; then
        repo_url=$(cat "$repo_file")
    fi

    if [[ -z "$repo_url" ]]; then
        read -rp "  Git repo URL'si: " repo_url
        [[ -z "$repo_url" ]] && error "Repo URL'si boş olamaz."
        echo "$repo_url" > "$repo_file"
        chmod 600 "$repo_file"
        chown root:root "$repo_file"
        info "Repo kaydedildi: ${repo_file}"
    fi

    # ─── 1. Clone ───
    step "1/7" "Git clone (branch: ${branch})..."
    mkdir -p "${base}/releases"
    git clone --depth 1 --branch "${branch}" "${repo_url}" "${release_dir}" 2>/dev/null || \
        error "Git clone başarısız. Repo URL'si ve branch'i kontrol edin."
    success "Clone tamamlandı"

    # ─── 2. Composer Install ───
    step "2/7" "Composer install..."
    if [[ -f "${release_dir}/composer.json" ]]; then
        cd "${release_dir}"
        if command -v composer &>/dev/null; then
            composer install --no-dev --optimize-autoloader --no-interaction --quiet 2>/dev/null
            success "Composer paketleri yüklendi"
        else
            warn "Composer bulunamadı — elle kurun: apt install composer"
        fi
    else
        info "composer.json bulunamadı — atlanıyor"
    fi

    # ─── 3. Shared dosyalar ───
    step "3/7" "Shared dosyalar bağlanıyor..."
    mkdir -p "${shared_dir}"

    # .env dosyası
    if [[ -f "${shared_dir}/.env" ]]; then
        ln -sf "${shared_dir}/.env" "${release_dir}/.env"
        success ".env bağlandı"
    else
        warn ".env bulunamadı: ${shared_dir}/.env"
        warn "Oluşturun: cp ${release_dir}/env ${shared_dir}/.env && nano ${shared_dir}/.env"
    fi

    # writable dizini (shared)
    if [[ -d "${shared_dir}/writable" ]]; then
        rm -rf "${release_dir}/writable"
        ln -sf "${shared_dir}/writable" "${release_dir}/writable"
        success "writable/ bağlandı (shared)"
    else
        # İlk deploy ise, mevcut writable'ı shared'a taşı
        if [[ -d "${release_dir}/writable" ]]; then
            cp -r "${release_dir}/writable" "${shared_dir}/writable"
            rm -rf "${release_dir}/writable"
            ln -sf "${shared_dir}/writable" "${release_dir}/writable"
            success "writable/ shared'a taşındı"
        fi
    fi

    # ─── 4. CI4 Dizin Yapısını Ayarla ───
    step "4/7" "CI4 dizin yapısı ayarlanıyor..."
    # public dizinindeki index.php'yi public_html'e yönlendir
    local ci4_public="${release_dir}/public"
    if [[ ! -d "$ci4_public" ]]; then
        ci4_public="${release_dir}"
    fi

    # ─── 5. Sahiplik ve İzinler ───
    step "5/7" "İzinler ayarlanıyor..."
    chown -R "${web_user}:${web_user}" "${release_dir}"
    chmod -R 750 "${release_dir}"

    # writable dizini yazılabilir olmalı
    if [[ -d "${shared_dir}/writable" ]]; then
        chmod -R 770 "${shared_dir}/writable"
        chown -R "${web_user}:${web_user}" "${shared_dir}/writable"
    fi

    success "İzinler ayarlandı"

    # ─── 6. Atomic Switch ───
    step "6/7" "Atomic switch (zero-downtime)..."

    # Eski public_html'i yedekle
    if [[ -d "$public_dir" && ! -L "$public_dir" ]]; then
        mv "$public_dir" "${base}/public_html.bak.$(date +%s)" 2>/dev/null || true
    fi

    # CI4'te public dizini varsa onu kullan, yoksa release kökünü
    if [[ -d "${release_dir}/public" ]]; then
        ln -sfn "${release_dir}/public" "$public_dir"
    else
        ln -sfn "${release_dir}" "$public_dir"
    fi

    success "Atomic switch tamamlandı"

    # ─── 7. Reload ───
    step "7/7" "Servisler yenileniyor..."
    systemctl reload "php${php_version}-fpm" 2>/dev/null || true

    # Eski release'leri temizle (son 5'i tut)
    if [[ -d "${base}/releases" ]]; then
        cd "${base}/releases"
        local release_count
        release_count=$(find . -maxdepth 1 -type d ! -name '.' | wc -l)
        if [[ $release_count -gt 5 ]]; then
            ls -t | tail -n +"6" | xargs -r rm -rf
            info "Eski release'ler temizlendi (son 5 tutuldu)"
        fi
    fi

    success "Servisler yenilendi"

    header "✅ Deploy Tamamlandı: ${domain}"

    echo "  Release:        ${release_dir}"
    echo "  Branch:         ${branch}"
    echo "  public_html →   $(readlink -f "$public_dir" 2>/dev/null)"
    echo ""

    log_action "DEPLOY: ${domain} (branch=${branch}, release=$(basename "${release_dir}"))"
}
