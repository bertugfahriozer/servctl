# srvctl Faz 2 / T7a — Per-Domain FPM Master Unit — Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Her domain'e kendi `srvctl-fpm-<sname>.service` systemd unit'ini vermek; systemd `AppArmorProfile=` + `Slice=` direktifleriyle inert AppArmor profilini ve boş cgroups slice'larını gerçekten FPM worker'larına uygulamak.

**Architecture:** Per-domain FPM config (`/etc/srvctl/fpm/<sname>.conf` = `[global]` + mevcut `pool.conf.tpl` pool bölümü) ve per-domain systemd unit render edilir; unit `AppArmorProfile=srvctl-<sname>` + `Slice=srvctl-<sname>.slice` taşır. Socket yolu değişmez → nginx dokunulmaz. Render mantığı saf (macOS-test edilebilir); `systemctl`/`aa-status`/cgroups [HOST].

**Tech Stack:** Bash (pure), `render_template` (mevcut), systemd, AppArmor, cgroups v2. Hedef Ubuntu 22.04 root; geliştirme/test macOS.

## Yürütme ortamları
- **[macOS-TDD]** — template render + render-helper; `bash tests/run.sh` ile test edilebilir (Task 1, 2, 3, 6-dry).
- **[HOST]** — `systemctl`/`aa-status`/cgroups gerçek etki; Ubuntu root host (Task 4, 5, 6-apply).

## Global Constraints
- Türkçe string/yorum; her script `set -euo pipefail`; `error` ÇIKAR; predikat `return`.
- `render_template <tpl> KEY=value...` `{{KEY}}` token'larını değiştirir (mevcut, core.sh); değerde newline/CR reddi var.
- `safe_name example.com` → `example_com`; `web_user=web_<sname>`. Socket: `/run/php/php<ver>-fpm-<sname>.sock` (DEĞİŞMEZ).
- Test yolları env override: `SRVCTL_TEMPLATES`, `SRVCTL_FPM_DIR` (varsayılan `/etc/srvctl/fpm`), `SRVCTL_SYSTEMD_DIR` (varsayılan `/etc/systemd/system`).
- `pool.conf.tpl` POOL bölümünün TEK kaynağıdır — kopyalanmaz; config = render(fpm-global) + render(pool.conf.tpl).
- Commit mesajları Türkçe + `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## Dosya Yapısı
- `templates/php-fpm/fpm-global.conf.tpl` — yeni; FPM `[global]` bölümü.
- `templates/systemd/srvctl-fpm.service.tpl` — yeni; per-domain unit (AppArmorProfile=+Slice=).
- `lib/domain.sh` — `_domain_render_fpm_unit` (render, macOS); `_domain_activate_fpm_unit` (HOST); `_domain_add`/`_domain_php_switch`/`_domain_remove` entegrasyonu.
- `lib/security.sh` — `harden-fpm` dispatch + `_security_harden_fpm` (dry/apply).
- `install.sh` — template kopya döngüsüne `systemd` (php-fpm zaten var; fpm-global oraya girer).
- `tests/` — yeni: `test_fpm_global_render.sh`, `test_fpm_unit_render.sh`, `test_render_fpm_unit.sh`, `test_harden_fpm_dryrun.sh`.

---

### Task 1: `fpm-global.conf.tpl` + render testi **[macOS-TDD]**

**Files:**
- Create: `templates/php-fpm/fpm-global.conf.tpl`
- Test: `tests/test_fpm_global_render.sh`

**Interfaces:** Consumes: `render_template` (core.sh). Produces: `[global]` bölümlü template; token'lar DOMAIN/SAFE_NAME/WEB_ROOT.

- [ ] **Step 1: Başarısız testi yaz** — `tests/test_fpm_global_render.sh`:

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"

out="$(render_template "${SRVCTL_TEMPLATES}/php-fpm/fpm-global.conf.tpl" \
    DOMAIN=example.com SAFE_NAME=example_com WEB_ROOT=/var/www)"
assert_contains "$out" "[global]"                                  "global bölümü"
assert_contains "$out" "pid = /run/srvctl/fpm-example_com.pid"     "per-domain pid"
assert_contains "$out" "daemonize = no"                            "daemonize no"
assert_contains "$out" "/var/www/example.com/logs/php-fpm-master.log" "master error_log"
assert_not_contains "$out" "{{"                                    "leftover token yok"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Çalıştır, FAIL gör** — Run: `bash tests/test_fpm_global_render.sh` — FAIL (template yok → render_template error/boş).

- [ ] **Step 3: Uygula** — `templates/php-fpm/fpm-global.conf.tpl` oluştur:

```
; ═══════════════════════════════════════════════
;  srvctl per-domain FPM master — {{DOMAIN}}
;  (pool bölümü pool.conf.tpl'den eklenir)
; ═══════════════════════════════════════════════
[global]
pid = /run/srvctl/fpm-{{SAFE_NAME}}.pid
error_log = {{WEB_ROOT}}/{{DOMAIN}}/logs/php-fpm-master.log
daemonize = no
```

- [ ] **Step 4: Çalıştır, PASS gör** — Run: `bash tests/test_fpm_global_render.sh`; ayrıca `bash tests/run.sh`.

- [ ] **Step 5: Commit**
```bash
git add templates/php-fpm/fpm-global.conf.tpl tests/test_fpm_global_render.sh
git commit -m "$(cat <<'EOF'
feat(T7a): fpm-global.conf.tpl — per-domain FPM [global] bölümü

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `srvctl-fpm.service.tpl` + render testi **[macOS-TDD]**

**Files:**
- Create: `templates/systemd/srvctl-fpm.service.tpl`
- Test: `tests/test_fpm_unit_render.sh`

**Interfaces:** Consumes: `render_template`. Produces: per-domain systemd unit; token'lar DOMAIN/SAFE_NAME/PHP_VERSION.

- [ ] **Step 1: Başarısız testi yaz** — `tests/test_fpm_unit_render.sh`:

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"

out="$(render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-fpm.service.tpl" \
    DOMAIN=example.com SAFE_NAME=example_com PHP_VERSION=8.3)"
assert_contains "$out" "Slice=srvctl-example_com.slice"            "cgroups slice"
assert_contains "$out" "AppArmorProfile=srvctl-example_com"        "AppArmor attach"
assert_contains "$out" "ExecStart=/usr/sbin/php-fpm8.3 --nodaemonize --fpm-config /etc/srvctl/fpm/example_com.conf" "ExecStart php sürümü"
assert_contains "$out" "Description=srvctl PHP-FPM (example.com)"  "açıklama"
assert_contains "$out" "ExecReload=/bin/kill -USR2 \$MAINPID"      "MAINPID korunur (token değil)"
assert_not_contains "$out" "{{"                                    "leftover token yok"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Çalıştır, FAIL gör** — Run: `bash tests/test_fpm_unit_render.sh` — FAIL (template yok).

- [ ] **Step 3: Uygula** — `templates/systemd/srvctl-fpm.service.tpl` oluştur:

```
[Unit]
Description=srvctl PHP-FPM ({{DOMAIN}})
After=network.target

[Service]
Type=notify
ExecStart=/usr/sbin/php-fpm{{PHP_VERSION}} --nodaemonize --fpm-config /etc/srvctl/fpm/{{SAFE_NAME}}.conf
ExecReload=/bin/kill -USR2 $MAINPID
Slice=srvctl-{{SAFE_NAME}}.slice
AppArmorProfile=srvctl-{{SAFE_NAME}}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: Çalıştır, PASS gör** — Run: `bash tests/test_fpm_unit_render.sh`; `bash tests/run.sh`.

- [ ] **Step 5: Commit**
```bash
git add templates/systemd/srvctl-fpm.service.tpl tests/test_fpm_unit_render.sh
git commit -m "$(cat <<'EOF'
feat(T7a): srvctl-fpm.service.tpl — per-domain unit (AppArmorProfile=+Slice=)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `_domain_render_fpm_unit` render helper **[macOS-TDD]**

**Files:**
- Modify: `lib/domain.sh` (`_domain_write_vhost`'tan sonra, yardımcı bölgesi)
- Test: `tests/test_render_fpm_unit.sh`

**Interfaces:**
- Consumes: `render_template`, `safe_name`, `pool.conf.tpl`, `fpm-global.conf.tpl` (Task 1), `srvctl-fpm.service.tpl` (Task 2).
- Produces: `_domain_render_fpm_unit <domain> <php_version>` — `${SRVCTL_FPM_DIR}/<sname>.conf` (global+pool) ve `${SRVCTL_SYSTEMD_DIR}/srvctl-fpm-<sname>.service` dosyalarını RENDER eder (systemctl YOK).

- [ ] **Step 1: Başarısız testi yaz** — `tests/test_render_fpm_unit.sh`:

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_FPM_DIR="$(mktemp -d)"
export SRVCTL_SYSTEMD_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
source "${REPO_ROOT}/lib/domain.sh"

_domain_render_fpm_unit example.com 8.3

conf="$(cat "${SRVCTL_FPM_DIR}/example_com.conf")"
assert_contains "$conf" "[global]"                       "config global bölümü"
assert_contains "$conf" "[example_com]"                  "config pool bölümü (pool.conf.tpl)"
assert_contains "$conf" "user = web_example_com"         "pool user web_user"
assert_contains "$conf" "php-fpm8.3-example_com.sock"    "socket yolu (değişmez)"
assert_not_contains "$conf" "{{"                         "config leftover token yok"

unit="$(cat "${SRVCTL_SYSTEMD_DIR}/srvctl-fpm-example_com.service")"
assert_contains "$unit" "Slice=srvctl-example_com.slice"      "unit slice"
assert_contains "$unit" "AppArmorProfile=srvctl-example_com"  "unit apparmor"
assert_contains "$unit" "php-fpm8.3"                          "unit php sürümü"

rm -rf "$WEB_ROOT" "$SRVCTL_FPM_DIR" "$SRVCTL_SYSTEMD_DIR"
test_summary
```

- [ ] **Step 2: Çalıştır, FAIL gör** — Run: `bash tests/test_render_fpm_unit.sh` — FAIL (`_domain_render_fpm_unit` tanımsız).

- [ ] **Step 3: Uygula** — `lib/domain.sh`'a ekle:

```bash
# Per-domain FPM config (global+pool) + systemd unit dosyalarını RENDER eder.
# systemctl ÇAĞIRMAZ (aktivasyon _domain_activate_fpm_unit, [HOST]).
# Test için SRVCTL_FPM_DIR / SRVCTL_SYSTEMD_DIR override edilebilir.
_domain_render_fpm_unit() {
    local domain="$1" php_version="$2"
    local sname; sname=$(safe_name "$domain")
    local web_user="web_${sname}"
    local fpm_dir="${SRVCTL_FPM_DIR:-/etc/srvctl/fpm}"
    local sysd_dir="${SRVCTL_SYSTEMD_DIR:-/etc/systemd/system}"
    mkdir -p "$fpm_dir" "$sysd_dir"
    # config = [global] + pool (pool.conf.tpl TEK kaynak, kopyalanmaz)
    {
        render_template "${SRVCTL_TEMPLATES}/php-fpm/fpm-global.conf.tpl" \
            "DOMAIN=${domain}" "SAFE_NAME=${sname}" "WEB_ROOT=${WEB_ROOT}"
        render_template "${SRVCTL_TEMPLATES}/php-fpm/pool.conf.tpl" \
            "DOMAIN=${domain}" "SAFE_NAME=${sname}" "WEB_ROOT=${WEB_ROOT}" \
            "PHP_VERSION=${php_version}" "WEB_USER=${web_user}"
    } > "${fpm_dir}/${sname}.conf"
    render_template "${SRVCTL_TEMPLATES}/systemd/srvctl-fpm.service.tpl" \
        "DOMAIN=${domain}" "SAFE_NAME=${sname}" "PHP_VERSION=${php_version}" \
        > "${sysd_dir}/srvctl-fpm-${sname}.service"
}
```

- [ ] **Step 4: Çalıştır, PASS gör** — Run: `bash tests/test_render_fpm_unit.sh`; `bash tests/run.sh`.

- [ ] **Step 5: Commit**
```bash
git add lib/domain.sh tests/test_render_fpm_unit.sh
git commit -m "$(cat <<'EOF'
feat(T7a): _domain_render_fpm_unit — config(global+pool)+unit render (DRY pool)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Aktivasyon + `_domain_add` entegrasyonu + fail-open kaldırma **[HOST]**

**Files:**
- Modify: `lib/domain.sh` (`_domain_activate_fpm_unit` yeni; `_domain_add` FPM bloğu; AppArmor `:432-446`)
- Test: yok (systemctl HOST); macOS: `bash -n` + suite yeşil.

**Interfaces:**
- Consumes: `_domain_render_fpm_unit` (Task 3).
- Produces: `_domain_activate_fpm_unit <domain>` — daemon-reload + enable --now + aktiflik kontrolü.

- [ ] **Step 1: Uygula** — `lib/domain.sh`'a ekle:

```bash
# Render edilmiş unit'i systemd'ye yükle + başlat (HOST). Aktif değilse error.
_domain_activate_fpm_unit() {
    local domain="$1" sname; sname=$(safe_name "$domain")
    systemctl daemon-reload
    systemctl enable --now "srvctl-fpm-${sname}.service" 2>/dev/null
    if systemctl is-active --quiet "srvctl-fpm-${sname}.service"; then
        success "FPM unit aktif: srvctl-fpm-${sname} (Slice + AppArmor enforce)"
    else
        error "srvctl-fpm-${sname} başlatılamadı — 'systemctl status srvctl-fpm-${sname}' kontrol edin"
    fi
}
```

`_domain_add`'in PHP-FPM pool bloğunu (pool.conf.tpl'i `/etc/php/<ver>/fpm/pool.d/`'e yazıp paylaşılan FPM reload eden kısım, ~331-345) şununla DEĞİŞTİR:

```bash
    _domain_render_fpm_unit "${domain}" "${php_version}"
    _domain_activate_fpm_unit "${domain}"
```

AppArmor bloğunu (`:442-446`) — fail-open mesajı kaldır:

```bash
    apparmor_parser -r "/etc/apparmor.d/srvctl-${sname}" 2>/dev/null || true
    aa-enforce "/etc/apparmor.d/srvctl-${sname}" 2>/dev/null || \
        warn "..."
    success "AppArmor profili enforce modda"
```
şununla DEĞİŞTİR (profil yüklenir; gerçek enforce kontrolü):

```bash
    apparmor_parser -r "/etc/apparmor.d/srvctl-${sname}" 2>/dev/null \
        || warn "apparmor_parser başarısız — profil yüklenmedi"
    aa-enforce "/etc/apparmor.d/srvctl-${sname}" 2>/dev/null \
        || warn "aa-enforce başarısız — profil enforce edilemedi"
    # NOT: gerçek attach unit'in AppArmorProfile= direktifiyle olur (Task 3/2);
    # fail-closed audit T7b'de FPM PID'inin enforce göründüğünü doğrular.
    if aa-status 2>/dev/null | grep -q "srvctl-${sname}"; then
        success "AppArmor profili yüklendi (enforce): srvctl-${sname}"
    else
        warn "AppArmor profili 'srvctl-${sname}' aa-status'ta görünmüyor"
    fi
```

- [ ] **Step 2: macOS kontrol** — Run: `bash -n lib/domain.sh`; `bash tests/run.sh` yeşil.

- [ ] **Step 3: Commit**
```bash
git add lib/domain.sh
git commit -m "$(cat <<'EOF'
feat(T7a): domain add per-domain FPM unit aktivasyonu + fail-open mesaj kaldırma

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4 [HOST]: Ubuntu doğrulama** — `srvctl domain add yeni.com` → `systemctl is-active srvctl-fpm-yeni_com` aktif; `aa-status | grep yeni_com` enforce; `systemctl show -p ControlGroup srvctl-fpm-yeni_com` → `srvctl-yeni_com.slice`; site açılır.

---

### Task 5: php-switch + remove entegrasyonu **[HOST]**

**Files:**
- Modify: `lib/domain.sh` (`_domain_php_switch` ~884; `_domain_remove` ~605)
- Test: yok (systemctl HOST); macOS: `bash -n` + suite yeşil.

**Interfaces:** Consumes: `_domain_render_fpm_unit`/`_domain_activate_fpm_unit`. Produces: yok.

- [ ] **Step 1: Uygula** — `_domain_php_switch`'te pool sed + `systemctl reload php<ver>-fpm` bloğunu ([deploy/domain] ~916-921) şununla DEĞİŞTİR:

```bash
    # Unit'i yeni PHP sürümüyle yeniden render + restart (eski sed-pool yerine)
    _domain_render_fpm_unit "${domain}" "${new_ver}"
    systemctl daemon-reload
    systemctl restart "srvctl-fpm-${sname}.service" \
        || error "srvctl-fpm-${sname} yeni sürümle başlatılamadı"
    success "FPM unit php${new_ver}-fpm'e geçti"
```
(chroot lib kopyalama adımı KORUNUR; eski `/etc/php/<old>/fpm/pool.d/<sname>.conf` varsa kaldır.)

`_domain_remove`'da FPM temizliğini ([cgroups slice stop ~605-606 yakını]) şununla genişlet:

```bash
    systemctl disable --now "srvctl-fpm-${sname}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/srvctl-fpm-${sname}.service" "/etc/srvctl/fpm/${sname}.conf"
    systemctl daemon-reload 2>/dev/null || true
```

- [ ] **Step 2: macOS kontrol** — Run: `bash -n lib/domain.sh`; `bash tests/run.sh` yeşil.

- [ ] **Step 3: Commit**
```bash
git add lib/domain.sh
git commit -m "$(cat <<'EOF'
feat(T7a): php-switch unit yeniden-render+restart; remove unit temizliği

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4 [HOST]: Ubuntu doğrulama** — `srvctl domain php-switch yeni.com 8.2` → unit php-fpm8.2 ile restart; site çalışır. `srvctl domain remove yeni.com` → unit + config silinir, `systemctl status srvctl-fpm-yeni_com` = not-found.

---

### Task 6: `srvctl security harden-fpm` migrasyonu **[HOST + macOS-dry]**

**Files:**
- Modify: `lib/security.sh` (`cmd_security` case + `_security_harden_fpm`)
- Test: `tests/test_harden_fpm_dryrun.sh` (dry-run [macOS])

**Interfaces:**
- Consumes: `_domain_render_fpm_unit` (Task 3), `safe_name`, `domain_exists`, `list_all_domains`.
- Produces: `harden-fpm <domain>|--all [--apply]` — mevcut shared-pool domain'leri per-domain unit'e taşır (dry-run varsayılan).

- [ ] **Step 1: Başarısız testi yaz** — `tests/test_harden_fpm_dryrun.sh`:

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/lib/security.sh"

mkdir -p "${WEB_ROOT}/example.com"
out="$(_harden_fpm_dry example.com)"
assert_contains "$out" "example.com"                          "domain"
assert_contains "$out" "srvctl-fpm-example_com.service"       "oluşturulacak unit"
assert_contains "$out" "/etc/srvctl/fpm/example_com.conf"     "oluşturulacak config"
# dry-run hiçbir dosya yazmamalı:
assert_eq "$(ls /etc/srvctl/fpm/example_com.conf 2>/dev/null; echo done)" "done" "dry-run yazmadı"
assert_ok bash -c "source '${REPO_ROOT}/lib/core.sh'; source '${REPO_ROOT}/lib/domain.sh'; source '${REPO_ROOT}/lib/security.sh'; WEB_ROOT='${WEB_ROOT}' _harden_fpm_dry yokboyle.com"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Çalıştır, FAIL gör** — Run: `bash tests/test_harden_fpm_dryrun.sh` — FAIL (tanımsız).

- [ ] **Step 3: Uygula** — `lib/security.sh`'ta `cmd_security` case'ine `harden-fpm)  _security_harden_fpm "${@:2}" ;;` ekle; modüle:

```bash
# Mevcut shared-pool domain'leri per-domain FPM unit'e taşı (T7a).
# Kullanım: harden-fpm <domain>|--all [--apply]   (varsayılan: dry-run)
_security_harden_fpm() {
    local domain="" mode="dry" all=false arg
    for arg in "$@"; do
        case "$arg" in
            --apply) mode="apply" ;;
            --all)   all=true ;;
            -*)      error "Bilinmeyen seçenek: ${arg}" ;;
            *)       domain="$arg" ;;
        esac
    done
    local targets=() d
    if $all; then mapfile -t targets < <(list_all_domains)
    else [[ -z "$domain" ]] && error "Kullanım: srvctl security harden-fpm <domain>|--all [--apply]"; targets=("$domain"); fi
    for d in "${targets[@]}"; do
        [[ "$mode" == "apply" ]] && _harden_fpm_apply "$d" || _harden_fpm_dry "$d"
    done
}

# Dry-run: ne oluşturulacağını yaz, dokunma.
_harden_fpm_dry() {
    local domain="$1" sname; sname=$(safe_name "$domain")
    domain_exists "$domain" || { warn "Domain yok: ${domain}"; return 0; }
    echo "  ── ${domain} (dry-run; uygulamak için --apply) ──"
    echo "    oluştur: /etc/srvctl/fpm/${sname}.conf"
    echo "    oluştur: /etc/systemd/system/srvctl-fpm-${sname}.service (Slice + AppArmorProfile)"
    echo "    kaldır:  /etc/php/<ver>/fpm/pool.d/${sname}.conf (eski shared pool)"
    echo "    systemctl enable --now srvctl-fpm-${sname}"
}
```

`_harden_fpm_apply` ([HOST]):
```bash
_harden_fpm_apply() {
    local domain="$1" sname php_ver
    sname=$(safe_name "$domain")
    domain_exists "$domain" || { warn "Domain yok: ${domain}"; return 0; }
    php_ver=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")
    _domain_render_fpm_unit "$domain" "$php_ver"
    _domain_activate_fpm_unit "$domain"
    rm -f "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf"
    systemctl reload "php${php_ver}-fpm" 2>/dev/null || true
    success "harden-fpm uygulandı: ${domain}"
    log_action "harden-fpm apply: ${domain}"
}
```

- [ ] **Step 4: Çalıştır, PASS gör** — Run: `bash tests/test_harden_fpm_dryrun.sh`; `bash tests/run.sh`.

- [ ] **Step 5: Commit**
```bash
git add lib/security.sh tests/test_harden_fpm_dryrun.sh
git commit -m "$(cat <<'EOF'
feat(T7a): srvctl security harden-fpm — shared-pool → per-domain unit migrasyonu

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6 [HOST]: Ubuntu doğrulama** — eski-model domain'de `harden-fpm <d>` (dry-run plan), `--apply` (unit oluşur+aktif, eski pool kaldırılır, site çalışır), `--all`.

---

### Task 7: install.sh + README + host kontrol listesi **[macOS-code + docs]**

**Files:**
- Modify: `install.sh:64-65,81` (systemd template dizini + kopya); `README.md`
- Create: `docs/superpowers/plans/2026-07-01-srvctl-phase2-t7a-HOST-checklist.md`

**Interfaces:** yok.

- [ ] **Step 1: install.sh** — `mkdir` satırına (`:65`) `systemd` ekle ve kopya döngüsüne (`:81`) `systemd`'yi dahil et:
```bash
mkdir -p "${INSTALL_DIR}/templates"/{nginx,php-fpm,apparmor,logrotate,systemd}
```
```bash
for tpl_dir in nginx php-fpm apparmor logrotate systemd; do
```
(`fpm-global.conf.tpl` zaten `php-fpm` dizininde kopyalanır.)

- [ ] **Step 2: README** — FPM/güvenlik notu: "Her domain kendi `srvctl-fpm-<sname>.service`'inde çalışır; AppArmor profili (`AppArmorProfile=`) ve cgroups slice (`Slice=`) systemd üzerinden gerçekten uygulanır. Mevcut kurulumları taşımak: `srvctl security harden-fpm <domain> [--apply|--all]`."

- [ ] **Step 3: Host kontrol listesi** — `docs/superpowers/plans/2026-07-01-srvctl-phase2-t7a-HOST-checklist.md`: Task 4/5/6 [HOST] adımları tek e2e: (1) domain add → unit aktif, aa-status enforce, ControlGroup slice altında; (2) AppArmor gerçekten kısıtlıyor (`/etc/shadow` deny); (3) MemoryMax stress → OOM-kill; (4) php-switch/remove; (5) harden-fpm migrate; (6) site + deploy regresyon yok.

- [ ] **Step 4: macOS kontrol** — `bash -n install.sh`; `bash tests/run.sh` yeşil.

- [ ] **Step 5: Commit**
```bash
git add install.sh README.md docs/superpowers/plans/2026-07-01-srvctl-phase2-t7a-HOST-checklist.md
git commit -m "$(cat <<'EOF'
docs/build(T7a): install.sh systemd template + README + host kontrol listesi

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review (spec kapsama)

Spec (`2026-07-01-srvctl-phase2-t7a-fpm-unit-design.md`) → task:
- **§3 FPM modeli** → Task 1 (fpm-global) + Task 2 (unit) + Task 3 (render helper, pool.conf.tpl DRY). **§4 attach + fail-open kaldırma** → Task 2 (AppArmorProfile=/Slice= token'ları) + Task 4 (fail-open mesaj). **§5 entegrasyon** → Task 4 (add), Task 5 (php-switch/remove), Task 6 (harden-fpm). **§6 test** → Task 1-3,6-dry macOS-TDD; Task 4-6 [HOST] doğrulama + Task 7 e2e. **§2 install** → Task 7.
- **İsim tutarlılığı:** `_domain_render_fpm_unit`, `_domain_activate_fpm_unit`, `_security_harden_fpm`/`_harden_fpm_dry`/`_harden_fpm_apply`, `SRVCTL_FPM_DIR`/`SRVCTL_SYSTEMD_DIR`, socket `/run/php/php<ver>-fpm-<sname>.sock` — birebir.
- **macOS/HOST ayrımı:** Task 1,2,3 + 6-dry macOS-TDD; 4,5,6-apply HOST. Doğru işaretli.
- **Kapsam:** yalnız T7a; T7b (audit) + T7c (install templates döngüsü zaten Task 7'de kısmen + modsec) ayrı. Not: install.sh systemd template'i T7a'ya ait (Task 7); cgroups/seccomp template kopyası ve modsec daraltma T7c'de.
