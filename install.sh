#!/bin/bash
# ═══════════════════════════════════════════════
#  srvctl — Kurulum Script'i
#  Ubuntu 22.04 LTS üzerinde srvctl'yi kurar
#
#  Kullanım: sudo bash install.sh
# ═══════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/usr/local/srvctl"

# ─── Root kontrolü ───
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}✗${NC}  Bu script root olarak çalıştırılmalıdır."
    echo "  Kullanım: sudo bash install.sh"
    exit 1
fi

# ─── OS kontrolü ───
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID}" != "ubuntu" ]]; then
        echo -e "${YELLOW}⚠${NC}  Bu script Ubuntu için tasarlanmıştır. (Tespit: ${ID})"
        read -rp "  Devam etmek istiyor musunuz? (evet/hayır): " cont
        [[ "$cont" != "evet" ]] && exit 0
    fi
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  srvctl — Kurulum${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""

# ─── Kaynak dizini tespit et ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Eski kurulumu kontrol et ───
if [[ -d "$INSTALL_DIR" ]]; then
    echo -e "${YELLOW}⚠${NC}  Mevcut kurulum tespit edildi: ${INSTALL_DIR}"
    read -rp "  Üzerine yazmak istiyor musunuz? (evet/hayır): " overwrite
    if [[ "$overwrite" != "evet" ]]; then
        echo "  Kurulum iptal edildi."
        exit 0
    fi
    # Mevcut conf dosyasını koru
    if [[ -f "${INSTALL_DIR}/conf/srvctl.conf" ]]; then
        cp "${INSTALL_DIR}/conf/srvctl.conf" "/tmp/srvctl.conf.bak"
        echo -e "${GREEN}✓${NC}  Mevcut yapılandırma yedeklendi: /tmp/srvctl.conf.bak"
    fi
fi

# ─── 1. Dizin yapısı ───
echo -e "  ${CYAN}[1/5]${NC} Dizin yapısı oluşturuluyor..."
mkdir -p "${INSTALL_DIR}"/{bin,lib,templates,conf,logs}
mkdir -p "${INSTALL_DIR}/templates"/{nginx,php-fpm,apparmor,logrotate,systemd,cgroups,seccomp}

# ─── 2. Dosyaları kopyala ───
echo -e "  ${CYAN}[2/5]${NC} Dosyalar kopyalanıyor..."

# bin/
cp "${SCRIPT_DIR}/bin/srvctl" "${INSTALL_DIR}/bin/srvctl"
chmod +x "${INSTALL_DIR}/bin/srvctl"

# lib/
for lib_file in "${SCRIPT_DIR}"/lib/*.sh; do
    [[ -f "$lib_file" ]] && cp "$lib_file" "${INSTALL_DIR}/lib/"
done
chmod +x "${INSTALL_DIR}"/lib/*.sh

# templates/
for tpl_dir in nginx php-fpm apparmor logrotate systemd cgroups seccomp; do
    if [[ -d "${SCRIPT_DIR}/templates/${tpl_dir}" ]]; then
        cp "${SCRIPT_DIR}/templates/${tpl_dir}/"* "${INSTALL_DIR}/templates/${tpl_dir}/" 2>/dev/null || true
    fi
done

# conf/ (mevcut conf varsa koruyarak)
if [[ -f "/tmp/srvctl.conf.bak" ]]; then
    cp "/tmp/srvctl.conf.bak" "${INSTALL_DIR}/conf/srvctl.conf"
    rm -f "/tmp/srvctl.conf.bak"
    echo -e "${GREEN}✓${NC}  Mevcut yapılandırma korundu"
elif [[ ! -f "${INSTALL_DIR}/conf/srvctl.conf" ]]; then
    cp "${SCRIPT_DIR}/conf/srvctl.conf" "${INSTALL_DIR}/conf/srvctl.conf"
fi

# ─── 3. Symlink ───
echo -e "  ${CYAN}[3/5]${NC} PATH'e ekleniyor..."
ln -sf "${INSTALL_DIR}/bin/srvctl" /usr/local/bin/srvctl

# ─── 4. İzinler ───
echo -e "  ${CYAN}[4/5]${NC} İzinler ayarlanıyor..."
chmod 700 "${INSTALL_DIR}"
chmod 600 "${INSTALL_DIR}/conf/srvctl.conf"
chmod 750 "${INSTALL_DIR}/bin" "${INSTALL_DIR}/lib"
chown -R root:root "${INSTALL_DIR}"

# ─── 5. Log dizini ───
echo -e "  ${CYAN}[5/5]${NC} Log dizini hazırlanıyor..."
mkdir -p "${INSTALL_DIR}/logs"
touch "${INSTALL_DIR}/logs/srvctl.log"
chmod 640 "${INSTALL_DIR}/logs/srvctl.log"

# ─── Doğrulama ───
echo ""
if command -v srvctl &>/dev/null; then
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✅ srvctl başarıyla kuruldu!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    echo ""
    echo "  Versiyon:  $(srvctl version 2>/dev/null || echo '1.0.0')"
    echo "  Konum:     ${INSTALL_DIR}"
    echo "  Komut:     srvctl"
    echo ""
    echo "  Yapılandırma:"
    echo "    ${INSTALL_DIR}/conf/srvctl.conf"
    echo ""
    echo -e "  ${BOLD}Sonraki adımlar:${NC}"
    echo ""
    echo "    1. Yapılandırmayı düzenleyin:"
    echo "       nano ${INSTALL_DIR}/conf/srvctl.conf"
    echo ""
    echo "    2. SSH key'inizi ayarlayın (PasswordAuth kapatılacak!):"
    echo "       ssh-copy-id -p 2222 user@server"
    echo ""
    echo "    3. Sunucuyu hazırlayın:"
    echo "       sudo srvctl init"
    echo ""
    echo "    4. İlk domain'i ekleyin:"
    echo "       sudo srvctl domain add example.com"
    echo ""
else
    echo -e "${RED}✗${NC}  Kurulum başarısız olmuş olabilir."
    echo "  Kontrol edin: ls -la ${INSTALL_DIR}/bin/srvctl"
    exit 1
fi
