# srvctl Faz 2 / T1 — Dosya-Sahiplik Modeli + harden-fs — Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** RC1 kök-nedenini kapatmak: per-domain base dizinini `root:root 751` yaparak kontrol dosyalarını tamper-proof kılmak, `assert_root_owned_path`'i per-domain "hardened" marker ile fail-closed kapıya çevirmek ve mevcut domain'leri taşıyan `srvctl security harden-fs` komutunu eklemek.

**Architecture:** Sahiplik modeli iki fonksiyona ayrılır: `_domain_fs_plan` (HEDEF durumu yazan saf/test edilebilir fonksiyon — dry-run ve unit-test bunu kullanır) ve `_domain_apply_fs_ownership` (gerçek chown/chmod — broad-chown-then-reclaim; yalnız Ubuntu host'ta doğrulanır). Politika `_require_owned_or_warn` sarmalayıcısında: per-domain `state/<d>/hardened` marker varsa ve dosya root-owned değilse `error` (tamper), yoksa `warn`+devam (migrate edilmemiş — eski domain'leri kırmaz).

**Tech Stack:** Bash (pure), mevcut bash test harness (`tests/`), `stat` (portable GNU/BSD), `setfacl`. Hedef runtime Ubuntu 22.04 root; geliştirme/test macOS.

## Yürütme ortamları (KRİTİK)

Bu plan **iki ortamda** çalışır. Her task başlığında ortam etiketi var:
- **[macOS-TDD]** — saf-bash mantık; `bash tests/run.sh` ile macOS'ta tam TDD. Bunlar şimdi uygulanabilir/test edilebilir.
- **[HOST]** — gerçek `chown`/`chmod`/provisioning etkisi; **yalnız Ubuntu root host'ta** doğrulanır. Kod tam verilir; "test" yerine bir **host-doğrulama prosedürü** vardır. macOS'ta uygulanırsa kod yazılır ama gerçek etki doğrulanamaz.

Uygulayan: önce tüm **[macOS-TDD]** task'larını TDD ile bitir; **[HOST]** task'larını bir Ubuntu staging domain'inde doğrula.

## Global Constraints

- Tüm kullanıcıya dönük string'ler ve yorumlar **Türkçe**. `confirm()` `evet` bekler.
- Her script `set -euo pipefail`; beklenen başarısızlıkta `|| true`.
- `lib/core.sh`'ta `error` ÇIKAR (exit). Predikatlar `return 0/1`, asla `exit`. Çağıran: `pred ... || error "..."`.
- **`warn` STDOUT'a yazar** — `_require_owned_or_warn` içinde uyarı `warn "..." >&2` ile STDERR'e yönlendirilmeli (yoksa `_domain_write_vhost`'un stdout→nginx-config çıktısını kirletir).
- `_stat_owner`/`_stat_mode` (Faz 1, core.sh) portable; `assert_root_owned_path`/`secure_dir`/`secure_file` (Faz 1) yeniden kullanılır.
- Test yolları env ile override edilebilmeli: `WEB_ROOT`, `SRVCTL_STATE_DIR`. Tablo-tabanlı testler.
- Commit mesajları Türkçe, şu satırla biter: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- macOS'ta `chown root` ve `assert_root_owned_path`'in pozitif (root-owned) dalı **çalışmaz** → bu dallar yalnız [HOST]'ta doğrulanır; macOS testleri reddetme/warn/plan dallarını kapsar.

## Dosya Yapısı

- `lib/core.sh` — `SRVCTL_STATE_DIR` değişkeni; `_domain_is_hardened`, `_require_owned_or_warn` (yeni); `read_credentials`/`read_meta` bunu çağırır.
- `lib/domain.sh` — `_domain_fs_plan` (yeni, saf), `_domain_apply_fs_ownership` (yeni, apply); `_fs_record_before`/`_fs_revert` (yeni); `_domain_add` provisioning bloğu (276-288) yeni helper'a geçer.
- `lib/security.sh` — `cmd_security` içine `harden-fs` dispatch + `_security_harden_fs`, `_harden_fs_dry`/`_harden_fs_apply`/`_harden_fs_revert` (yeni).
- `lib/deploy.sh` — `.deploy-repo` okuması `_require_owned_or_warn` ile kapılanır.
- `tests/` — yeni: `test_fs_plan.sh`, `test_owned_marker_policy.sh`, `test_fs_before_format.sh`, `test_harden_fs_dryrun.sh`, `test_creds_policy_gate.sh`.
- `completions/srvctl.bash`, `completions/srvctl.zsh`, `README.md` — `harden-fs` komutu.

---

### Task 1: `_domain_fs_plan` — hedef sahiplik tablosu **[macOS-TDD]**

**Files:**
- Modify: `lib/domain.sh` (`_domain_write_vhost`'tan hemen önce, dosya başı yardımcı bölgesine ekle)
- Test: `tests/test_fs_plan.sh`

**Interfaces:**
- Consumes: hiçbiri.
- Produces: `_domain_fs_plan <base> <web_user>` → stdout'a `<path>|<owner>|<mode>` satırları yazar (owner: `root` veya `web_user` değeri). chown/chmod YOK. `_harden_fs_dry` (Task 4) ve testler kullanır.

- [ ] **Step 1: Başarısız testi yaz** — `tests/test_fs_plan.sh`:

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

out="$(_domain_fs_plan /var/www/example.com web_example_com)"
assert_contains "$out" "/var/www/example.com|root|751"               "base root:root 751"
assert_contains "$out" "/var/www/example.com/public_html|web_example_com|750" "public_html web 750"
assert_contains "$out" "/var/www/example.com/private/writable|web_example_com|770" "writable web 770"
assert_contains "$out" "/var/www/example.com/dev|root|755"           "chroot dev root"
assert_contains "$out" "/var/www/example.com/etc|root|755"           "chroot etc root"
assert_contains "$out" "/var/www/example.com/.credentials|root|600"  "credentials root 600"
assert_contains "$out" "/var/www/example.com/.srvctl-meta|root|644"  "meta root 644"
assert_contains "$out" "/var/www/example.com/.deploy-repo|root|600"  "deploy-repo root 600"
assert_not_contains "$out" "/var/www/example.com|web_example_com"    "base ASLA web değil"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Çalıştır, FAIL gör** — Run: `bash tests/test_fs_plan.sh` — Beklenen: FAIL (`_domain_fs_plan` tanımsız → çıktı boş, assert'ler düşer).

- [ ] **Step 3: Uygula** — `lib/domain.sh`'a `_domain_write_vhost()` tanımından hemen önce ekle:

```bash
# Bir domain için HEDEF dosya-sahiplik/izin modelini (uygulamadan) yazar.
# Çıktı: "<path>|<owner>|<mode>" satırları. Saf fonksiyon — chown/chmod YOK.
# harden-fs dry-run (Task 4) ve unit-testler bunu kullanır.
_domain_fs_plan() {
    local base="$1" web_user="$2"
    local rows=(
        ".|root|751"
        "dev|root|755" "etc|root|755" "lib|root|755" "lib64|root|755" "usr|root|755"
        ".credentials|root|600" ".srvctl-meta|root|644" ".deploy-repo|root|600"
        "public_html|${web_user}|750"
        "private|${web_user}|750"
        "private/writable|${web_user}|770"
        "logs|${web_user}|750"
        "tmp|${web_user}|770"
        "sessions|${web_user}|770"
        "releases|${web_user}|750"
        "shared|${web_user}|750"
    )
    local row rel owner mode path
    for row in "${rows[@]}"; do
        IFS='|' read -r rel owner mode <<< "$row"
        [[ "$rel" == "." ]] && path="$base" || path="${base}/${rel}"
        printf '%s|%s|%s\n' "$path" "$owner" "$mode"
    done
}
```

- [ ] **Step 4: Çalıştır, PASS gör** — Run: `bash tests/test_fs_plan.sh`

- [ ] **Step 5: Commit**
```bash
git add lib/domain.sh tests/test_fs_plan.sh
git commit -m "$(cat <<'EOF'
feat(T1): _domain_fs_plan — hedef dosya-sahiplik tablosu (saf, test edilebilir)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `SRVCTL_STATE_DIR` + marker + `_require_owned_or_warn` politikası **[macOS-TDD]**

**Files:**
- Modify: `lib/core.sh` (Faz 1 `assert_root_owned_path` tanımından sonra)
- Test: `tests/test_owned_marker_policy.sh`

**Interfaces:**
- Consumes: `assert_root_owned_path` (Faz 1), `warn` (core.sh).
- Produces: `SRVCTL_STATE_DIR` (varsayılan `${SRVCTL_ROOT}/state`, env override); `_domain_is_hardened <domain>` (0=hardened); `_require_owned_or_warn <domain> <file>` PREDIKAT — root-owned ise 0; değilse hardened-marker varsa 1 (tamper), yoksa STDERR'e warn + 0. Caller: `_require_owned_or_warn d f || error "..."`.

- [ ] **Step 1: Başarısız testi yaz** — `tests/test_owned_marker_policy.sh`:

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

mkdir -p "${WEB_ROOT}/example.com"
f="${WEB_ROOT}/example.com/.credentials"
echo "DB_PASS=x" > "$f"   # macOS: kullanıcı-sahipli → assert_root_owned_path 1 döner

# 1) marker YOK + root-owned değil → warn + 0 (migrate edilmemiş, kırılmaz)
assert_ok _require_owned_or_warn example.com "$f"

# 2) marker VAR + root-owned değil → 1 (tamper) ; warn'u stderr'e at, exit yok
mkdir -p "${SRVCTL_STATE_DIR}/example.com"; : > "${SRVCTL_STATE_DIR}/example.com/hardened"
assert_fail _require_owned_or_warn example.com "$f"

# 3) _domain_is_hardened doğru çalışır
assert_ok   _domain_is_hardened example.com
assert_fail _domain_is_hardened yokboyle.com

# 4) assert_root_owned_path stub'lanırsa (root-owned taklidi) → her durumda 0
assert_root_owned_path() { return 0; }
assert_ok _require_owned_or_warn example.com "$f"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
```

- [ ] **Step 2: Çalıştır, FAIL gör** — Run: `bash tests/test_owned_marker_policy.sh` — Beklenen: FAIL (fonksiyonlar tanımsız).

- [ ] **Step 3: Uygula** — `lib/core.sh`'a `assert_root_owned_path` tanımının ALTINA ekle:

```bash
# ─── Per-domain "hardened" durum dizini (root-only) ───
SRVCTL_STATE_DIR="${SRVCTL_STATE_DIR:-${SRVCTL_ROOT}/state}"

# Domain T1 modeline geçmiş mi? (marker root-only state dosyası)
_domain_is_hardened() {
    [[ -f "${SRVCTL_STATE_DIR}/${1}/hardened" ]]
}

# Sahiplik politikası (PREDIKAT: 0=devam, 1=tamper → çağıran error eder).
# root-owned değilse: hardened domain → tamper (1); migrate edilmemiş → warn + 0.
# UYARI STDERR'e gider (yoksa stdout→config çıktılarını kirletir).
_require_owned_or_warn() {
    local domain="$1" file="$2"
    assert_root_owned_path "$file" && return 0
    if _domain_is_hardened "$domain"; then
        return 1
    fi
    warn "Domain '${domain}' henüz hardened değil — 'srvctl security harden-fs ${domain}' önerilir" >&2
    return 0
}
```

- [ ] **Step 4: Çalıştır, PASS gör** — Run: `bash tests/test_owned_marker_policy.sh`

- [ ] **Step 5: Commit**
```bash
git add lib/core.sh tests/test_owned_marker_policy.sh
git commit -m "$(cat <<'EOF'
feat(T1): hardened-marker + _require_owned_or_warn politikası (fail-closed/warn)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `_fs_record_before` / `_fs_revert` — before-state biçimi **[macOS-TDD]** (kayıt) / **[HOST]** (revert apply)

**Files:**
- Modify: `lib/domain.sh` (`_domain_fs_plan`'dan sonra)
- Test: `tests/test_fs_before_format.sh`

**Interfaces:**
- Consumes: `_stat_owner`/`_stat_mode` (Faz 1).
- Produces: `_fs_record_before <base> <outfile>` → her yol için `<path> <owner> <mode>` satırı yazar. `_fs_revert <recfile>` → satırları okuyup `chown`/`chmod` geri uygular (apply [HOST]).

- [ ] **Step 1: Başarısız testi yaz** — `tests/test_fs_before_format.sh`:

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

base="${WEB_ROOT}/example.com"
mkdir -p "${base}/public_html" "${base}/private/writable"
echo "x" > "${base}/.credentials"
rec="$(mktemp)"
_fs_record_before "$base" "$rec"

me="$(whoami)"
assert_contains "$(cat "$rec")" "${base} ${me} "                "base satırı (sahip+mod)"
assert_contains "$(cat "$rec")" "${base}/public_html ${me} "    "public_html satırı"
assert_contains "$(cat "$rec")" "${base}/.credentials ${me} "   "credentials satırı"
# her satır 3 alan (path owner mode)
bad="$(awk 'NF!=3{c++} END{print c+0}' "$rec")"
assert_eq "$bad" "0" "tüm satırlar 3 alan"

rm -f "$rec"; rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Çalıştır, FAIL gör** — Run: `bash tests/test_fs_before_format.sh` — FAIL (tanımsız).

- [ ] **Step 3: Uygula** — `lib/domain.sh`'a `_domain_fs_plan`'dan sonra ekle:

```bash
# Mevcut sahiplik/izinleri kaydet (revert güvenlik ağı). Satır: "<path> <owner> <mode>".
_fs_record_before() {
    local base="$1" out="$2" p
    : > "$out"
    printf '%s %s %s\n' "$base" "$(_stat_owner "$base")" "$(_stat_mode "$base")" >> "$out"
    for p in "$base"/* "$base"/.credentials "$base"/.srvctl-meta "$base"/.deploy-repo; do
        [[ -e "$p" ]] || continue
        printf '%s %s %s\n' "$p" "$(_stat_owner "$p")" "$(_stat_mode "$p")" >> "$out"
    done
}

# Kayıttan geri yükle (chown/chmod — gerçek etki [HOST]).
_fs_revert() {
    local rec="$1" path owner mode
    while read -r path owner mode; do
        [[ -e "$path" ]] || continue
        chown "${owner}:${owner}" "$path" 2>/dev/null || true
        chmod "$mode" "$path" 2>/dev/null || true
    done < "$rec"
}
```

- [ ] **Step 4: Çalıştır, PASS gör** — Run: `bash tests/test_fs_before_format.sh`

- [ ] **Step 5: Commit**
```bash
git add lib/domain.sh tests/test_fs_before_format.sh
git commit -m "$(cat <<'EOF'
feat(T1): _fs_record_before/_fs_revert — sahiplik kaydı + geri yükleme

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `srvctl security harden-fs` — dispatch + dry-run **[macOS-TDD]**

**Files:**
- Modify: `lib/security.sh` (`cmd_security` case + `_security_harden_fs` + `_harden_fs_dry`)
- Test: `tests/test_harden_fs_dryrun.sh`

**Interfaces:**
- Consumes: `_domain_fs_plan` (Task 1), `_stat_owner`/`_stat_mode`, `domain_exists`, `safe_name`, `list_all_domains`.
- Produces: `cmd_security harden-fs ...` dispatch; `_security_harden_fs <args>` (mode: dry varsayılan / `--apply` / `--revert`, `--all`); `_harden_fs_dry <domain>` dry-run çıktısı. (`_harden_fs_apply`/`_harden_fs_revert` Task 6.)

- [ ] **Step 1: Başarısız testi yaz** — `tests/test_harden_fs_dryrun.sh`:

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"
source "${REPO_ROOT}/lib/security.sh"

mkdir -p "${WEB_ROOT}/example.com"/{public_html,private/writable,dev}
echo "x" > "${WEB_ROOT}/example.com/.credentials"

out="$(_harden_fs_dry example.com)"
assert_contains "$out" "example.com"                              "domain başlığı"
assert_contains "$out" "${WEB_ROOT}/example.com -> root:root 751" "base hedefi"
assert_contains "$out" "/public_html -> web_example_com:web_example_com 750" "public_html hedefi"
assert_contains "$out" "/.credentials -> root:root 600"          "credentials hedefi"
# dry-run hiçbir şeyi DEĞİŞTİRMEMELİ: sahiplik hâlâ çalıştıran kullanıcı
assert_eq "$(_stat_owner "${WEB_ROOT}/example.com")" "$(whoami)" "dry-run dokunmadı"
# yok olan domain hata değil, uyarı
assert_ok bash -c "source '${REPO_ROOT}/lib/core.sh'; source '${REPO_ROOT}/lib/domain.sh'; source '${REPO_ROOT}/lib/security.sh'; WEB_ROOT='${WEB_ROOT}' _harden_fs_dry yokboyle.com"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Çalıştır, FAIL gör** — Run: `bash tests/test_harden_fs_dryrun.sh` — FAIL (tanımsız).

- [ ] **Step 3: Uygula** — `lib/security.sh`'ta `cmd_security` case bloğuna satır ekle (mevcut alt-komutların yanına):

```bash
        harden-fs)  _security_harden_fs "${@:2}" ;;
```

Sonra modül içine (dosya sonu yardımcılar bölgesine) ekle:

```bash
# ─── Dosya-sahiplik sertleştirme (T1) ───
# Kullanım: harden-fs <domain>|--all [--apply|--revert]  (varsayılan: dry-run)
_security_harden_fs() {
    local domain="" mode="dry" all=false arg
    for arg in "$@"; do
        case "$arg" in
            --apply)  mode="apply" ;;
            --revert) mode="revert" ;;
            --all)    all=true ;;
            -*)       error "Bilinmeyen seçenek: ${arg}" ;;
            *)        domain="$arg" ;;
        esac
    done
    local targets=() d
    if $all; then
        mapfile -t targets < <(list_all_domains)
    else
        [[ -z "$domain" ]] && error "Kullanım: srvctl security harden-fs <domain>|--all [--apply|--revert]"
        targets=("$domain")
    fi
    for d in "${targets[@]}"; do
        case "$mode" in
            dry)    _harden_fs_dry "$d" ;;
            apply)  _harden_fs_apply "$d" ;;
            revert) _harden_fs_revert "$d" ;;
        esac
    done
}

# Dry-run: hedef modeli + mevcut durumu yaz, hiçbir şeye dokunma.
_harden_fs_dry() {
    local domain="$1" base="${WEB_ROOT}/${domain}" web_user
    web_user="web_$(safe_name "$domain")"
    domain_exists "$domain" || { warn "Domain yok: ${domain}"; return 0; }
    echo "  ── ${domain} (dry-run; uygulamak için --apply) ──"
    local path owner mode
    while IFS='|' read -r path owner mode; do
        [[ -e "$path" ]] || continue
        printf '    %s -> %s:%s %s  (mevcut: %s %s)\n' \
            "$path" "$owner" "$owner" "$mode" "$(_stat_owner "$path")" "$(_stat_mode "$path")"
    done < <(_domain_fs_plan "$base" "$web_user")
}
```

- [ ] **Step 4: Çalıştır, PASS gör** — Run: `bash tests/test_harden_fs_dryrun.sh`

- [ ] **Step 5: Commit**
```bash
git add lib/security.sh tests/test_harden_fs_dryrun.sh
git commit -m "$(cat <<'EOF'
feat(T1): srvctl security harden-fs dispatch + dry-run (varsayılan, dokunmaz)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `_domain_apply_fs_ownership` — gerçek apply **[HOST]**

**Files:**
- Modify: `lib/domain.sh` (`_fs_revert`'ten sonra)
- Test: yok (gerçek `chown root` macOS'ta çalışmaz) — **host-doğrulama prosedürü** aşağıda.

**Interfaces:**
- Consumes: hiçbiri (saf chown/chmod).
- Produces: `_domain_apply_fs_ownership <base> <web_user>` — modeli UYGULAR (broad-chown-then-reclaim). Task 6 (`_harden_fs_apply`) ve Task 7 (`_domain_add`) çağırır.

- [ ] **Step 1: Uygula** — `lib/domain.sh`'a ekle:

```bash
# HEDEF modeli UYGULAR (root gerekir). Strateji: önce tüm ağaç web_user, sonra
# base'in KENDİSİ + chroot sistem dizinleri + kontrol dosyaları root'a geri alınır.
# Böylece web app yazma erişimini korur ama base'de write/unlink yapamaz.
_domain_apply_fs_ownership() {
    local base="$1" web_user="$2"
    # 1. Tüm ağaç web_user
    chown -R "${web_user}:${web_user}" "$base"
    # 2. base dizininin KENDİSİ root (yalnız bu inode — çocuklar web kalır)
    chown root:root "$base"; chmod 751 "$base"
    # 3. chroot sistem dizinleri root (recursive)
    local sysd
    for sysd in dev etc lib lib64 usr; do
        [[ -d "${base}/${sysd}" ]] && { chown -R root:root "${base}/${sysd}"; chmod 755 "${base}/${sysd}"; }
    done
    # 4. kontrol dosyaları root
    local cf
    for cf in .credentials .srvctl-meta .deploy-repo; do
        [[ -e "${base}/${cf}" ]] && chown root:root "${base}/${cf}"
    done
    [[ -e "${base}/.credentials" ]] && chmod 600 "${base}/.credentials"
    [[ -e "${base}/.srvctl-meta" ]] && chmod 644 "${base}/.srvctl-meta"
    [[ -e "${base}/.deploy-repo" ]] && chmod 600 "${base}/.deploy-repo"
    # 5. leaf izinleri (sahiplik zaten web_user)
    chmod 750 "${base}/public_html" "${base}/private" "${base}/logs" 2>/dev/null || true
    chmod 770 "${base}/tmp" "${base}/sessions" 2>/dev/null || true
    chmod -R 770 "${base}/private/writable" 2>/dev/null || true
}
```

- [ ] **Step 2: Sözdizimi kontrolü (macOS'ta yapılabilir)** — Run: `bash -n lib/domain.sh` — Beklenen: hata yok. Run: `bash tests/run.sh` — Beklenen: tüm testler hâlâ yeşil (yeni fonksiyon çağrılmıyor, regresyon yok).

- [ ] **Step 3: Commit**
```bash
git add lib/domain.sh
git commit -m "$(cat <<'EOF'
feat(T1): _domain_apply_fs_ownership — base root:root reclaim (HOST-apply)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4 [HOST]: Ubuntu doğrulama** — Bir staging domain'inde:
```bash
sudo bash -c 'source /usr/local/srvctl/lib/core.sh; source /usr/local/srvctl/lib/domain.sh; _domain_apply_fs_ownership /var/www/test.com web_test_com'
stat -c '%U %a' /var/www/test.com                 # beklenen: root 751
stat -c '%U %a' /var/www/test.com/public_html     # beklenen: web_test_com 750
stat -c '%U %a' /var/www/test.com/dev             # beklenen: root 755
stat -c '%U %a' /var/www/test.com/.credentials    # beklenen: root 600
sudo -u web_test_com rm -f /var/www/test.com/.credentials; echo $?  # beklenen: başarısız (Permission denied)
```
Ayrıca: web sitesi hâlâ açılıyor mu, FPM worker başlıyor mu, writable/cache yazılabiliyor mu.

---

### Task 6: `_harden_fs_apply` / `_harden_fs_revert` wiring **[HOST]**

**Files:**
- Modify: `lib/security.sh` (`_harden_fs_dry`'dan sonra)
- Test: yok (gerçek apply [HOST]) — host-doğrulama aşağıda. macOS: `bash -n` + suite yeşil.

**Interfaces:**
- Consumes: `_fs_record_before`/`_fs_revert`/`_domain_apply_fs_ownership` (Task 3,5), `secure_dir`/`secure_file` (Faz 1), `SRVCTL_STATE_DIR`/`SRVCTL_VERSION`, `domain_exists`, `safe_name`, `nginx_test` veya `nginx -t`.
- Produces: `_harden_fs_apply <domain>`, `_harden_fs_revert <domain>`.

- [ ] **Step 1: Uygula** — `lib/security.sh`'a ekle:

```bash
# Apply: before-state kaydet → modeli uygula → hardened marker yaz.
_harden_fs_apply() {
    local domain="$1" base="${WEB_ROOT}/${domain}" web_user state
    web_user="web_$(safe_name "$domain")"
    domain_exists "$domain" || { warn "Domain yok: ${domain}"; return 0; }
    state="${SRVCTL_STATE_DIR}/${domain}"
    secure_dir "$state" 700
    _fs_record_before "$base" "${state}/fs-before.txt"
    _domain_apply_fs_ownership "$base" "$web_user"
    printf 'hardened %s srvctl-%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${SRVCTL_VERSION}" > "${state}/hardened"
    chmod 600 "${state}/hardened"; chown root:root "${state}/hardened" 2>/dev/null || true
    nginx -t >/dev/null 2>&1 || warn "nginx -t başarısız — config'i kontrol edin (sahiplik nginx'i etkilememeli)"
    success "harden-fs uygulandı: ${domain} (geri al: srvctl security harden-fs ${domain} --revert)"
    log_action "harden-fs apply: ${domain}"
}

# Revert: kayıtlı before-state'ten geri yükle, marker'ı sil.
_harden_fs_revert() {
    local domain="$1" state="${SRVCTL_STATE_DIR}/${domain}"
    [[ -f "${state}/fs-before.txt" ]] || error "before-state yok: ${domain} (revert edilemez)"
    _fs_revert "${state}/fs-before.txt"
    rm -f "${state}/hardened"
    success "harden-fs geri alındı: ${domain}"
    log_action "harden-fs revert: ${domain}"
}
```

- [ ] **Step 2: macOS kontrol** — Run: `bash -n lib/security.sh` ve `bash tests/run.sh` — Beklenen: sözdizimi OK, suite yeşil.

- [ ] **Step 3: Commit**
```bash
git add lib/security.sh
git commit -m "$(cat <<'EOF'
feat(T1): harden-fs --apply/--revert (before-state + marker, HOST)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4 [HOST]: Ubuntu doğrulama**
```bash
srvctl security harden-fs test.com                 # dry-run: plan görünür
srvctl security harden-fs test.com --apply         # uygular
stat -c '%U %a' /var/www/test.com                  # root 751
cat /usr/local/srvctl/state/test.com/hardened      # marker var
srvctl security harden-fs test.com --apply         # idempotent: tekrar sorunsuz
srvctl security harden-fs test.com --revert        # geri alır
stat -c '%U %a' /var/www/test.com                  # eski sahipliğe döner
srvctl security harden-fs --all                    # tüm domain'ler dry-run
```

---

### Task 7: `_domain_add` provisioning'i yeni modele geçir **[HOST]**

**Files:**
- Modify: `lib/domain.sh` (mevcut chown/chmod bloğu ~276-288)
- Test: yok (provisioning gerçek chown [HOST]) — macOS: `bash -n` + suite yeşil.

**Interfaces:**
- Consumes: `_domain_apply_fs_ownership` (Task 5), `secure_dir` (Faz 1), `SRVCTL_STATE_DIR`/`SRVCTL_VERSION`.
- Produces: yeni domain'ler doğuştan hardened (base root:root + marker).

- [ ] **Step 1: Uygula** — `lib/domain.sh`'ta mevcut bloğu:

```bash
    chown -R "${web_user}:${web_user}" "${base}"
    chmod 750 "${base}"
    chmod 750 "${base}/public_html"
    chmod 750 "${base}/private"
    chmod 770 "${base}/tmp" "${base}/sessions"
    chmod -R 770 "${base}/private/writable"
    chmod 750 "${base}/logs"
    chmod o-rwx "${base}"
```

şununla DEĞİŞTİR:

```bash
    # Yeni sahiplik modeli (T1, RC1 düzeltmesi): base root:root, leaf'ler web_user.
    # NOT: eski 'chmod o-rwx base' KALDIRILDI — base artık root:root 751 ve web_user
    # "other" olarak o+x (traverse) iznine ihtiyaç duyar; o-rwx bunu kırardı.
    _domain_apply_fs_ownership "${base}" "${web_user}"
    # Yeni domain doğuştan hardened: marker yaz (fail-closed kapı hemen aktif).
    secure_dir "${SRVCTL_STATE_DIR}/${domain}" 700
    printf 'hardened %s srvctl-%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${SRVCTL_VERSION}" \
        > "${SRVCTL_STATE_DIR}/${domain}/hardened"
    chmod 600 "${SRVCTL_STATE_DIR}/${domain}/hardened"
```

(`setfacl` satırları 286-288 KORUNUR; yalnız `o::---` satırı 288 KALDIRILIR — base'in o+x traverse'ini engellememek için.)

- [ ] **Step 2: macOS kontrol** — Run: `bash -n lib/domain.sh`; `bash tests/run.sh` — Beklenen: sözdizimi OK, suite yeşil.

- [ ] **Step 3: Commit**
```bash
git add lib/domain.sh
git commit -m "$(cat <<'EOF'
feat(T1): domain add provisioning'i yeni sahiplik modeline geçir + marker

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4 [HOST]: Ubuntu doğrulama** — `srvctl domain add yeni.com` → `stat -c '%U %a' /var/www/yeni.com` = root 751; marker var; site açılıyor; web app writable'a yazıyor; `sudo -u web_yeni_com rm /var/www/yeni.com/.credentials` başarısız.

---

### Task 8: `read_credentials`/`read_meta`/`.deploy-repo` fail-closed kapısı **[macOS-TDD]**

**Files:**
- Modify: `lib/core.sh` (`read_credentials`, `read_meta`); `lib/deploy.sh` (`.deploy-repo` okuma); mevcut testleri stderr sessizleştir.
- Test: `tests/test_creds_policy_gate.sh`

**Interfaces:**
- Consumes: `_require_owned_or_warn` (Task 2).
- Produces: `read_credentials`/`read_meta` artık okumadan önce sahiplik kapısı uygular (hardened+tampered → error; migrate-edilmemiş → warn+oku).

- [ ] **Step 1: Başarısız testi yaz** — `tests/test_creds_policy_gate.sh`:

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

mkdir -p "${WEB_ROOT}/example.com"
cat > "${WEB_ROOT}/example.com/.credentials" <<EOF
DOMAIN=example.com
DB_PASS=Secr3t
EOF

# migrate edilmemiş (marker yok): warn (stderr) + değerler okunur
unset DB_PASS
read_credentials example.com 2>/dev/null
assert_eq "${DB_PASS:-}" "Secr3t" "migrate edilmemiş: değer okunur (warn stderr)"

# hardened marker + root-owned-değil (macOS) → tamper → read_credentials EXIT eder
mkdir -p "${SRVCTL_STATE_DIR}/example.com"; : > "${SRVCTL_STATE_DIR}/example.com/hardened"
assert_fail bash -c "
  export WEB_ROOT='${WEB_ROOT}' SRVCTL_STATE_DIR='${SRVCTL_STATE_DIR}'
  source '${REPO_ROOT}/lib/core.sh'
  read_credentials example.com
" 

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
```

- [ ] **Step 2: Çalıştır, FAIL gör** — Run: `bash tests/test_creds_policy_gate.sh` — Beklenen: FAIL (read_credentials henüz kapı uygulamıyor; tamper senaryosunda exit etmiyor).

- [ ] **Step 3: Uygula** — `lib/core.sh`'ta `read_credentials` gövdesini değiştir:

```bash
read_credentials() {
    local domain="$1"
    local creds_file="${WEB_ROOT}/${domain}/.credentials"
    _require_owned_or_warn "$domain" "$creds_file" \
        || error "Güvenlik: ${creds_file} root-owned değil (tamper). Okuma reddedildi."
    read_kv_file "$creds_file" \
        DOMAIN SAFE_NAME WEB_USER PHP_VERSION \
        DB_NAME DB_USER DB_PASS \
        REDIS_USER REDIS_PASS REDIS_PREFIX
}
```

`read_meta` gövdesini değiştir:

```bash
read_meta() {
    local meta_file="${WEB_ROOT}/${1}/.srvctl-meta"
    [[ -f "$meta_file" ]] || return 0
    _require_owned_or_warn "$1" "$meta_file" \
        || error "Güvenlik: ${meta_file} root-owned değil (tamper). Okuma reddedildi."
    read_kv_file "$meta_file" RATE_PROFILE SENSITIVE_PATHS
}
```

`lib/deploy.sh`'ta `.deploy-repo` okumasının ALTINA (repo_url okunduktan sonra, doğrulamadan önce) ekle:

```bash
    [[ -f "$repo_file" ]] && _require_owned_or_warn "$domain" "$repo_file" \
        || true   # repo_file yoksa interaktif sorulur; varsa kapı: tamper'da aşağıdaki validate zaten reddeder
```

(Not: `.deploy-repo` için fail-closed sertleştirme T3'te tamamlanır; T1 yalnız dosya bütünlüğü kapısını ekler. repo_url ayrıca Faz 1 `_deploy_validate_repo_url` ile allowlist'lenir.)

Son olarak mevcut testlerde `read_credentials`/`read_meta` çağrılarının stderr warn'unu sessizleştir (çıktı pristine kalsın): `tests/test_meta.sh`, `tests/test_read_credentials.sh`, `tests/test_domain_write_vhost.sh` içinde ilgili çağrılara `2>/dev/null` ekle (değer assert'leri etkilenmez).

- [ ] **Step 4: Çalıştır, PASS gör** — Run: `bash tests/test_creds_policy_gate.sh` ve `bash tests/run.sh` — Beklenen: yeni test geçer; tam suite yeşil (warn'lar stderr'de, assert'ler bozulmaz).

- [ ] **Step 5: Commit**
```bash
git add lib/core.sh lib/deploy.sh tests/test_creds_policy_gate.sh tests/test_meta.sh tests/test_read_credentials.sh tests/test_domain_write_vhost.sh
git commit -m "$(cat <<'EOF'
feat(T1): read_credentials/read_meta/.deploy-repo fail-closed sahiplik kapısı

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Completions + README + host e2e kontrol listesi **[macOS-TDD doc]** / **[HOST]**

**Files:**
- Modify: `completions/srvctl.bash`, `completions/srvctl.zsh` (security alt-komutlarına `harden-fs`)
- Modify: `README.md` (Güvenlik bölümüne harden-fs + yeni sahiplik modeli)
- Create: `docs/superpowers/plans/2026-06-30-srvctl-phase2-t1-HOST-checklist.md` (uçtan uca host doğrulama)

**Interfaces:** Consumes: hiçbiri. Produces: dokümantasyon + host kontrol listesi.

- [ ] **Step 1: Completions** — `completions/srvctl.bash` ve `.zsh`'ta `security` alt-komut listesine `harden-fs` ekle (mevcut `audit`/`scan` vb. yanına; dosyadaki desene uy).

- [ ] **Step 2: README** — `README.md` "Güvenlik" bölümüne ekle: yeni per-domain dosya-sahiplik modeli (base root:root 751, leaf'ler web_user) ve `srvctl security harden-fs <domain> [--apply|--revert|--all]` komutu (mevcut domain'leri yeni modele taşır; dry-run varsayılan).

- [ ] **Step 3: Host kontrol listesi** — `docs/superpowers/plans/2026-06-30-srvctl-phase2-t1-HOST-checklist.md` oluştur; Task 5/6/7'nin [HOST] doğrulama adımlarını tek bir uçtan-uca senaryoda topla: (1) `srvctl init` temiz Ubuntu; (2) `domain add yeni.com` → sahiplik = root 751 + marker; (3) site açılır, web app writable yazar; (4) `sudo -u web_yeni_com rm .credentials` başarısız; (5) hardened domain'de `.credentials`'ı root olarak boz → `srvctl domain info` tamper error; (6) eski-model bir domain'de `harden-fs --apply` → migrate; `--revert` → geri; (7) `--all` toplu; (8) `srvctl deploy`/`backup`/`rate-limit` hâlâ çalışır.

- [ ] **Step 4: macOS kontrol** — Run: `bash tests/run.sh` (regresyon yok); completions sözdizimi `bash -n completions/srvctl.bash`.

- [ ] **Step 5: Commit**
```bash
git add completions/ README.md docs/superpowers/plans/2026-06-30-srvctl-phase2-t1-HOST-checklist.md
git commit -m "$(cat <<'EOF'
docs(T1): harden-fs completions + README + host e2e kontrol listesi

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review (spec kapsama)

Spec (`2026-06-30-srvctl-phase2-t1-fs-ownership-design.md`) → task eşlemesi:
- **§3 sahiplik modeli** → Task 1 (plan tablosu) + Task 5 (apply). **§4 marker + fail-closed** → Task 2 (marker/politika) + Task 8 (read_* wiring). **§5 harden-fs** → Task 4 (dispatch+dry) + Task 6 (apply/revert/all) + Task 3 (before/revert). **§6 provisioning** → Task 7. **§7 test** → her macOS-TDD task kendi testini getirir; [HOST] task'ları host-doğrulama prosedürü + Task 9 e2e listesi. **§8 dosyalar** → tüm task'lara dağıldı.
- **İsim tutarlılığı:** `_domain_fs_plan`, `_domain_apply_fs_ownership`, `_require_owned_or_warn`, `_domain_is_hardened`, `_fs_record_before`/`_fs_revert`, `_security_harden_fs`/`_harden_fs_dry`/`_harden_fs_apply`/`_harden_fs_revert`, `SRVCTL_STATE_DIR` — task'lar arası birebir.
- **Kritik incelikler plana işlendi:** broad-chown-then-reclaim (Task 5); `warn >&2` ki config kirlenmesin (Task 2,8); `o::---`/`o-rwx` kaldırma (Task 7); macOS'ta root-owned dalın test edilememesi → reddetme/warn/plan dalları test edilir (Task 2,8).
- **Kapsam:** yalnız T1; T3/T7 spec §9'da ayrı. Tek uygulama planına sığar.
