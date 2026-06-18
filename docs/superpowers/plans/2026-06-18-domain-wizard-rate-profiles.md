# Domain Wizard + Per-Domain Rate-Limit Profilleri — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `srvctl`'ye argümansız `domain add` interaktif sihirbazı ve PHP-geneli per-domain rate-limit profilleri eklemek.

**Architecture:** Rate-limit hızları, IP-başına global "kademe" zone'ları olarak `init.sh` tarafından `/etc/nginx/conf.d/00-srvctl-ratelimit.conf` içine yazılır. Profiller `conf/rate-profiles.conf` içinde veri olarak tutulur; her domain'in seçtiği profil `/var/www/<domain>/.srvctl-meta` içinde saklanır ve vhost render'ında token olarak uygulanır. Yeni mantık küçük, saf, env-değişkeniyle yönlendirilebilir yardımcı fonksiyonlara konur; böylece root/nginx olmadan dev makinede unit-test edilebilir.

**Tech Stack:** Bash (pure), nginx `limit_req`/`limit_conn`, hafif kendi-yazımı bash test harness (harici bağımlılık yok), shellcheck.

## Global Constraints

- **Dil:** Tüm kullanıcıya görünen string'ler ve kod yorumları **Türkçe** (mevcut konvansiyon).
- **Onay konvansiyonu:** `confirm()` ve interaktif sorular `evet`/`hayır` bekler (`y`/`yes` değil).
- **Her script başında:** `set -euo pipefail` (mevcut dosyalar zaten içeriyor; yeni `tests/*.sh` de içerecek).
- **Çekirdek helper'ları yeniden kullan:** `info/success/warn/error/step/header/divider`, `require_root`, `safe_name`, `render_template`, `domain_exists`, `read_credentials`, `log_action`. **`error` çağrısı script'i sonlandırır.**
- **Geriye uyum:** Argümanlı `domain add` davranışı ve mevcut `general/login/api/conn_per_ip` zone adları korunur.
- **Runtime ≠ repo:** Kod `/usr/local/srvctl/`'de çalışır; `SRVCTL_ROOT` core.sh ve bin/srvctl'de sabittir. Dev makinede yalnızca saf yardımcılar test edilir; tam domain-provizyon (useradd, certbot, nginx reload) **gerçek Ubuntu sunucuda** doğrulanır.
- **Test çalıştırma:** `bash tests/run.sh` (dev makinede). Sunucu-doğrulaması adımları ayrıca işaretli.
- **Profil alan sırası** (`conf/rate-profiles.conf`, `:` ayraçlı): `1=ad 2=req_zone 3=req_burst 4=login_zone 5=login_burst 6=conn_limit`.

---

## Task 1: Test harness + rate-profiles.conf + profil yardımcıları (core.sh)

**Files:**
- Create: `tests/lib.sh`
- Create: `tests/run.sh`
- Create: `tests/test_rate_profiles.sh`
- Create: `conf/rate-profiles.conf`
- Modify: `lib/core.sh` (sonuna yardımcılar ekle, ~line 155)

**Interfaces:**
- Produces:
  - `tests/lib.sh`: `assert_eq <actual> <expected> <msg>`, `assert_contains <haystack> <needle> <msg>`, `assert_not_contains <haystack> <needle> <msg>`, `assert_ok <cmd...>`, `assert_fail <cmd...>`; sayaç değişkenleri `TESTS_RUN`/`TESTS_FAIL`; `test_summary`.
  - `lib/core.sh`: `rate_profile_line <profile>`, `rate_profile_field <profile> <n>`, `rate_profile_names`, `rate_profile_resolve <profile>` (stdout = geçerli profil adı; geçersizse `standard`), `rate_profile_load <profile>` (global `RL_PROFILE/RL_REQ_ZONE/RL_REQ_BURST/RL_LOGIN_ZONE/RL_LOGIN_BURST/RL_CONN` set eder). Env override: `SRVCTL_RATE_PROFILES`.

- [ ] **Step 1: `conf/rate-profiles.conf` oluştur**

```
# ═══════════════════════════════════════════════
#  srvctl — Rate-Limit Profilleri
#  Format: profil:req_zone:req_burst:login_zone:login_burst:conn_limit
#  Zone'lar lib/init.sh tarafından nginx'e tanımlanır.
# ═══════════════════════════════════════════════
strict:rl_strict:10:login_strict:3:20
standard:rl_standard:20:login_standard:5:50
relaxed:rl_relaxed:50:login_relaxed:8:100
api:rl_api:100:login_relaxed:8:200
```

- [ ] **Step 2: `tests/lib.sh` (assertion kütüphanesi) oluştur**

```bash
#!/bin/bash
# Hafif bash test assertion kütüphanesi (harici bağımlılık yok)
set -uo pipefail

TESTS_RUN=0
TESTS_FAIL=0

_green() { printf '\033[0;32m%s\033[0m' "$1"; }
_red()   { printf '\033[0;31m%s\033[0m' "$1"; }

assert_eq() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$1" == "$2" ]]; then
        echo "  $(_green PASS) ${3:-}"
    else
        echo "  $(_red FAIL) ${3:-}  (beklenen='$2' alınan='$1')"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

assert_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$1" == *"$2"* ]]; then
        echo "  $(_green PASS) ${3:-}"
    else
        echo "  $(_red FAIL) ${3:-}  ('$2' bulunamadı)"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

assert_not_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$1" != *"$2"* ]]; then
        echo "  $(_green PASS) ${3:-}"
    else
        echo "  $(_red FAIL) ${3:-}  ('$2' bulunmamalıydı)"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

assert_ok() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        echo "  $(_green PASS) komut başarılı: $*"
    else
        echo "  $(_red FAIL) komut başarısız olmamalıydı: $*"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

assert_fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        echo "  $(_red FAIL) komut başarısız olmalıydı: $*"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    else
        echo "  $(_green PASS) komut beklendiği gibi başarısız: $*"
    fi
}

test_summary() {
    echo ""
    echo "  Toplam: ${TESTS_RUN}, Başarısız: ${TESTS_FAIL}"
    [[ "$TESTS_FAIL" -eq 0 ]]
}
```

- [ ] **Step 3: `tests/run.sh` (runner) oluştur**

```bash
#!/bin/bash
# Tüm tests/test_*.sh dosyalarını çalıştırır.
# Kullanım: bash tests/run.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Saf yardımcılar repo içindeki conf/template'leri kullansın
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"

total_fail=0
for tf in tests/test_*.sh; do
    [[ -f "$tf" ]] || continue
    echo ""
    echo "═══ ${tf} ═══"
    bash "$tf" || total_fail=$((total_fail + 1))
done

echo ""
if [[ "$total_fail" -eq 0 ]]; then
    echo "TÜM TEST DOSYALARI GEÇTİ"
else
    echo "${total_fail} TEST DOSYASI BAŞARISIZ"
fi
exit "$total_fail"
```

- [ ] **Step 4: `tests/test_rate_profiles.sh` — başarısız testi yaz**

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# rate_profile_field: standard profili doğru alanlar
assert_eq "$(rate_profile_field standard 2)" "rl_standard" "standard req_zone"
assert_eq "$(rate_profile_field standard 3)" "20"          "standard req_burst"
assert_eq "$(rate_profile_field standard 6)" "50"          "standard conn"
assert_eq "$(rate_profile_field api 4)"      "login_relaxed" "api login_zone"

# rate_profile_resolve: bilinmeyen → standard
assert_eq "$(rate_profile_resolve bilinmeyen 2>/dev/null)" "standard" "geçersiz→standard"
assert_eq "$(rate_profile_resolve strict 2>/dev/null)"     "strict"   "geçerli korunur"
assert_eq "$(rate_profile_resolve '' 2>/dev/null)"         "standard" "boş→standard"

# rate_profile_names: 4 profil
assert_eq "$(rate_profile_names | tr '\n' ' ')" "strict standard relaxed api " "profil adları"

# rate_profile_load: global RL_* değişkenleri
rate_profile_load relaxed
assert_eq "$RL_REQ_ZONE"   "rl_relaxed"   "load req_zone"
assert_eq "$RL_REQ_BURST"  "50"           "load req_burst"
assert_eq "$RL_LOGIN_ZONE" "login_relaxed" "load login_zone"
assert_eq "$RL_CONN"       "100"          "load conn"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 5: Testi çalıştır, başarısız olduğunu doğrula**

Run: `bash tests/run.sh`
Expected: FAIL — `rate_profile_field: command not found` benzeri hatalar (fonksiyonlar henüz yok).

- [ ] **Step 6: `lib/core.sh` sonuna profil yardımcılarını ekle**

`read_credentials` fonksiyonundan sonra (dosya sonu, ~line 155) ekle:

```bash

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
```

- [ ] **Step 7: Testi çalıştır, geçtiğini doğrula**

Run: `bash tests/run.sh`
Expected: PASS — `test_rate_profiles.sh` tüm assertion'lar PASS, "TÜM TEST DOSYALARI GEÇTİ".

- [ ] **Step 8: shellcheck**

Run: `shellcheck lib/core.sh tests/lib.sh tests/run.sh tests/test_rate_profiles.sh`
Expected: Yeni eklenen kodda hata yok (mevcut `# shellcheck disable` yorumları korunur).

- [ ] **Step 9: Commit**

```bash
git add tests/lib.sh tests/run.sh tests/test_rate_profiles.sh conf/rate-profiles.conf lib/core.sh
git commit -m "feat: rate-limit profil yardımcıları + bash test harness"
```

---

## Task 2: Meta dosyası yardımcıları (core.sh)

**Files:**
- Modify: `lib/core.sh` (profil yardımcılarından sonra)
- Create: `tests/test_meta.sh`

**Interfaces:**
- Consumes: `WEB_ROOT` (core.sh `load_config`), `tests/lib.sh`.
- Produces: `read_meta <domain>` (varsa `${WEB_ROOT}/<domain>/.srvctl-meta` dosyasını source eder → `RATE_PROFILE`, `SENSITIVE_PATHS`), `write_meta <domain> <key> <value>` (upsert; dosya yoksa oluşturur, root:644).

- [ ] **Step 1: `tests/test_meta.sh` — başarısız testi yaz**

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

mkdir -p "${WEB_ROOT}/example.com"

# write_meta: yeni anahtar oluşturur
write_meta example.com RATE_PROFILE strict
assert_contains "$(cat "${WEB_ROOT}/example.com/.srvctl-meta")" "RATE_PROFILE=strict" "yeni anahtar yazıldı"

# write_meta: mevcut anahtarı günceller (duplicate yok)
write_meta example.com RATE_PROFILE relaxed
assert_contains "$(cat "${WEB_ROOT}/example.com/.srvctl-meta")" "RATE_PROFILE=relaxed" "anahtar güncellendi"
assert_eq "$(grep -c '^RATE_PROFILE=' "${WEB_ROOT}/example.com/.srvctl-meta")" "1" "duplicate yok"

# read_meta: değişkenleri yükler
unset RATE_PROFILE
write_meta example.com SENSITIVE_PATHS 'login|admin'
read_meta example.com
assert_eq "${RATE_PROFILE:-}"    "relaxed"     "read_meta RATE_PROFILE"
assert_eq "${SENSITIVE_PATHS:-}" "login|admin" "read_meta SENSITIVE_PATHS"

# read_meta: meta yoksa hata vermez
assert_ok read_meta yokboyle.com

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Testi çalıştır, başarısız olduğunu doğrula**

Run: `bash tests/test_meta.sh`
Expected: FAIL — `write_meta: command not found`.

- [ ] **Step 3: `lib/core.sh`'ye meta yardımcılarını ekle**

`rate_profile_load` fonksiyonundan sonra ekle:

```bash

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
    if [[ -f "$meta_file" ]] && grep -q "^${key}=" "$meta_file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$meta_file"
    else
        echo "${key}=${value}" >> "$meta_file"
    fi
    chmod 644 "$meta_file" 2>/dev/null || true
    chown root:root "$meta_file" 2>/dev/null || true
}
```

- [ ] **Step 4: Testi çalıştır, geçtiğini doğrula**

Run: `bash tests/test_meta.sh`
Expected: PASS — tüm assertion'lar PASS.

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck lib/core.sh tests/test_meta.sh
git add lib/core.sh tests/test_meta.sh
git commit -m "feat: per-domain .srvctl-meta read/write yardımcıları"
```

---

## Task 3: vhost template'lerini parametreleştir

**Files:**
- Modify: `templates/nginx/vhost.conf.tpl` (line 22-23, 39, 77-78)
- Modify: `templates/nginx/vhost-ssl.conf.tpl` (line 39-40, 53, 86-87)
- Create: `tests/test_vhost_render.sh`

**Interfaces:**
- Consumes: `render_template` (core.sh), `rate_profile_load` (Task 1), `DEFAULT_SENSITIVE_PATHS` (Task 1).
- Produces: token'lı template'ler. Yeni token'lar: `{{RL_REQ_ZONE}} {{RL_REQ_BURST}} {{RL_LOGIN_ZONE}} {{RL_LOGIN_BURST}} {{RL_CONN}} {{RL_SENSITIVE_PATHS}}`.

- [ ] **Step 1: `tests/test_vhost_render.sh` — başarısız testi yaz**

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

rate_profile_load strict
out=$(render_template "${REPO_ROOT}/templates/nginx/vhost.conf.tpl" \
    "DOMAIN=example.com" "SAFE_NAME=example_com" "WEB_ROOT=/var/www" "PHP_VERSION=8.3" \
    "RL_REQ_ZONE=${RL_REQ_ZONE}" "RL_REQ_BURST=${RL_REQ_BURST}" \
    "RL_LOGIN_ZONE=${RL_LOGIN_ZONE}" "RL_LOGIN_BURST=${RL_LOGIN_BURST}" \
    "RL_CONN=${RL_CONN}" "RL_SENSITIVE_PATHS=${DEFAULT_SENSITIVE_PATHS}")

assert_contains "$out" "limit_req zone=rl_strict burst=10 nodelay;" "general limit_req"
assert_contains "$out" "limit_conn conn_per_ip 20;"                 "conn limit"
assert_contains "$out" "limit_req zone=login_strict burst=3 nodelay;" "login limit_req"
assert_contains "$out" 'wp-login\.php'                              "hassas yol regex"
assert_contains "$out" "storage|bootstrap|config"                  "geniş blocked-dir"
assert_not_contains "$out" "{{"                                     "leftover token yok"

# SSL template aynı token'ları çözer
out_ssl=$(render_template "${REPO_ROOT}/templates/nginx/vhost-ssl.conf.tpl" \
    "DOMAIN=example.com" "SAFE_NAME=example_com" "WEB_ROOT=/var/www" "PHP_VERSION=8.3" \
    "RL_REQ_ZONE=${RL_REQ_ZONE}" "RL_REQ_BURST=${RL_REQ_BURST}" \
    "RL_LOGIN_ZONE=${RL_LOGIN_ZONE}" "RL_LOGIN_BURST=${RL_LOGIN_BURST}" \
    "RL_CONN=${RL_CONN}" "RL_SENSITIVE_PATHS=${DEFAULT_SENSITIVE_PATHS}")
assert_contains "$out_ssl" "limit_req zone=rl_strict burst=10 nodelay;" "ssl general limit_req"
assert_not_contains "$out_ssl" "{{" "ssl leftover token yok"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Testi çalıştır, başarısız olduğunu doğrula**

Run: `bash tests/test_vhost_render.sh`
Expected: FAIL — token'lar henüz hardcoded değerler (`zone=general burst=20`), assertion'lar başarısız.

- [ ] **Step 3: `templates/nginx/vhost.conf.tpl` düzenle**

Line 21-23'ü değiştir:
```
    # ─── Rate Limiting ───
    limit_req zone={{RL_REQ_ZONE}} burst={{RL_REQ_BURST}} nodelay;
    limit_conn conn_per_ip {{RL_CONN}};
```

Line 39'u (CI4 uygulama dizinleri) değiştir:
```
    location ~ ^/(app|system|vendor|modules|writable|private|tests|node_modules|\.composer|storage|bootstrap|config|database|routes|resources|var)/ {
```

Line 77-78'i değiştir:
```
    location ~ ^/({{RL_SENSITIVE_PATHS}}) {
        limit_req zone={{RL_LOGIN_ZONE}} burst={{RL_LOGIN_BURST}} nodelay;
```

- [ ] **Step 4: `templates/nginx/vhost-ssl.conf.tpl` düzenle**

Line 38-40'ı değiştir:
```
    # ─── Rate Limiting ───
    limit_req zone={{RL_REQ_ZONE}} burst={{RL_REQ_BURST}} nodelay;
    limit_conn conn_per_ip {{RL_CONN}};
```

Line 53'ü değiştir:
```
    location ~ ^/(app|system|vendor|modules|writable|private|tests|node_modules|\.composer|storage|bootstrap|config|database|routes|resources|var)/ {
```

Line 86-87'yi değiştir:
```
    location ~ ^/({{RL_SENSITIVE_PATHS}}) {
        limit_req zone={{RL_LOGIN_ZONE}} burst={{RL_LOGIN_BURST}} nodelay;
```

- [ ] **Step 5: Testi çalıştır, geçtiğini doğrula**

Run: `bash tests/test_vhost_render.sh`
Expected: PASS — tüm assertion'lar PASS.

- [ ] **Step 6: Commit**

```bash
git add templates/nginx/vhost.conf.tpl templates/nginx/vhost-ssl.conf.tpl tests/test_vhost_render.sh
git commit -m "feat: vhost template'lerine rate-limit profil token'ları"
```

---

## Task 4: init.sh — kademe zone'ları (render_ratelimit_zones)

**Files:**
- Modify: `lib/init.sh` (`_install_nginx`, ~line 186-276)
- Create: `tests/test_ratelimit_zones.sh`

**Interfaces:**
- Produces: `render_ratelimit_zones()` (stdout = nginx http-context rate-limit kademe blokları). `_install_nginx` bu çıktıyı `/etc/nginx/conf.d/00-srvctl-ratelimit.conf`'a yazar ve nginx.conf'a `include /etc/nginx/conf.d/*.conf;` ekler.
- Consumes: yok (saf fonksiyon).

- [ ] **Step 1: `tests/test_ratelimit_zones.sh` — başarısız testi yaz**

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/init.sh"

out=$(render_ratelimit_zones)
assert_contains "$out" 'zone=rl_strict:10m rate=3r/s'     "rl_strict zone"
assert_contains "$out" 'zone=rl_standard:10m rate=10r/s'  "rl_standard zone"
assert_contains "$out" 'zone=rl_relaxed:10m rate=30r/s'   "rl_relaxed zone"
assert_contains "$out" 'zone=rl_api:10m rate=60r/s'       "rl_api zone"
assert_contains "$out" 'zone=login_strict:10m rate=3r/m'  "login_strict zone"
assert_contains "$out" 'zone=login_standard:10m rate=5r/m' "login_standard zone"
assert_contains "$out" 'zone=login_relaxed:10m rate=10r/m' "login_relaxed zone"
assert_contains "$out" 'limit_req_status 429;'            "429 status"
assert_contains "$out" 'limit_conn_status 429;'           "conn 429 status"
# conn_per_ip nginx.conf'ta zaten tanımlı; burada tekrar tanımlanmamalı
assert_not_contains "$out" 'limit_conn_zone'              "conn_zone tekrar tanımlanmaz"

test_summary
```

- [ ] **Step 2: Testi çalıştır, başarısız olduğunu doğrula**

Run: `bash tests/test_ratelimit_zones.sh`
Expected: FAIL — `render_ratelimit_zones: command not found`.

- [ ] **Step 3: `lib/init.sh`'ye `render_ratelimit_zones` ekle**

`_install_nginx() {` satırının **hemen üstüne** (~line 185) ekle:

```bash
# Rate-limit kademe zone'larını üret (http context — conf.d include için).
# conn_per_ip zone'u nginx.conf'ta tanımlı olduğundan burada tekrar edilmez.
render_ratelimit_zones() {
    cat << 'RLZONES'
# srvctl — rate-limit kademe zone'ları (otomatik üretildi, elle düzenlemeyin)
limit_req_zone $binary_remote_addr zone=rl_strict:10m rate=3r/s;
limit_req_zone $binary_remote_addr zone=rl_standard:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=rl_relaxed:10m rate=30r/s;
limit_req_zone $binary_remote_addr zone=rl_api:10m rate=60r/s;
limit_req_zone $binary_remote_addr zone=login_strict:10m rate=3r/m;
limit_req_zone $binary_remote_addr zone=login_standard:10m rate=5r/m;
limit_req_zone $binary_remote_addr zone=login_relaxed:10m rate=10r/m;
limit_req_status 429;
limit_conn_status 429;
RLZONES
}

```

- [ ] **Step 4: nginx.conf heredoc'una conf.d include ekle**

`lib/init.sh` line 264 (`    include /etc/nginx/sites-enabled/*.conf;`) **üstüne** şu satırı ekle (heredoc içi, literal):

```
    include /etc/nginx/conf.d/*.conf;
```

- [ ] **Step 5: Zone dosyasını yazan çağrıyı ekle**

`lib/init.sh` line 268 (`    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled`) **üstüne** ekle:

```bash
    # Kademe rate-limit zone'larını conf.d'ye yaz (nginx -t öncesi)
    mkdir -p /etc/nginx/conf.d
    render_ratelimit_zones > /etc/nginx/conf.d/00-srvctl-ratelimit.conf
```

- [ ] **Step 6: Testi çalıştır, geçtiğini doğrula**

Run: `bash tests/test_ratelimit_zones.sh`
Expected: PASS.

- [ ] **Step 7: shellcheck + commit**

```bash
shellcheck lib/init.sh tests/test_ratelimit_zones.sh
git add lib/init.sh tests/test_ratelimit_zones.sh
git commit -m "feat: init.sh kademe rate-limit zone'ları (conf.d) + 429 status"
```

**Sunucu doğrulaması (manuel, Ubuntu):** `sudo srvctl init` sonrası `nginx -t` başarılı; `grep rl_standard /etc/nginx/conf.d/00-srvctl-ratelimit.conf` eşleşir.

---

## Task 5: _domain_write_vhost + _domain_add entegrasyonu

**Files:**
- Modify: `lib/domain.sh` (`_domain_add` arg parse ~47-60; vhost render ~183-222; meta yazımı; yeni `_domain_write_vhost`)
- Create: `tests/test_domain_write_vhost.sh`

**Interfaces:**
- Consumes: `rate_profile_load`, `read_meta`, `DEFAULT_SENSITIVE_PATHS` (Task 1-2), `render_template`, `safe_name`, `SRVCTL_TEMPLATES`.
- Produces: `_domain_write_vhost <domain> <php_version> <profile> <mode>` (`mode`=`http`|`ssl`; `/etc/nginx/sites-available/<domain>.conf` yazar — test için `SITES_AVAILABLE` env'i ile override edilebilir). `_domain_add` artık `--rate=<profil>`, `--no-ssl`, `--sensitive=<regex>` flag'lerini de tanır ve `.srvctl-meta`'ya `RATE_PROFILE`/`SENSITIVE_PATHS` yazar.

- [ ] **Step 1: `tests/test_domain_write_vhost.sh` — başarısız testi yaz**

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SITES_AVAILABLE="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

mkdir -p "${WEB_ROOT}/example.com"

_domain_write_vhost example.com 8.3 relaxed http
conf=$(cat "${SITES_AVAILABLE}/example.com.conf")
assert_contains "$conf" "limit_req zone=rl_relaxed burst=50 nodelay;" "relaxed profil uygulandı"
assert_contains "$conf" "limit_conn conn_per_ip 100;"                 "relaxed conn"
assert_not_contains "$conf" "{{"                                      "leftover token yok"

# Meta'daki SENSITIVE_PATHS override edilir
write_meta example.com SENSITIVE_PATHS 'admin|backend'
_domain_write_vhost example.com 8.3 relaxed http
conf=$(cat "${SITES_AVAILABLE}/example.com.conf")
assert_contains "$conf" 'location ~ ^/(admin|backend) {' "meta sensitive override"

rm -rf "$WEB_ROOT" "$SITES_AVAILABLE"
test_summary
```

- [ ] **Step 2: Testi çalıştır, başarısız olduğunu doğrula**

Run: `bash tests/test_domain_write_vhost.sh`
Expected: FAIL — `_domain_write_vhost: command not found`.

- [ ] **Step 3: `lib/domain.sh`'ye `_domain_write_vhost` ekle**

`_domain_add()` fonksiyonunun **üstüne** (~line 46, `cmd_domain` `}`'sinden sonra) ekle:

```bash
# vhost config'i seçili profil + meta ile üret ve yaz.
# mode: "http" → vhost.conf.tpl, "ssl" → vhost-ssl.conf.tpl
# SITES_AVAILABLE env'i test için override edilebilir (varsayılan /etc/nginx/sites-available).
_domain_write_vhost() {
    local domain="$1" php_version="$2" profile="$3" mode="$4"
    local sites="${SITES_AVAILABLE:-/etc/nginx/sites-available}"
    local sname
    sname=$(safe_name "$domain")
    local tpl="${SRVCTL_TEMPLATES}/nginx/vhost.conf.tpl"
    [[ "$mode" == "ssl" ]] && tpl="${SRVCTL_TEMPLATES}/nginx/vhost-ssl.conf.tpl"

    rate_profile_load "$profile"

    # Hassas yollar: meta override yoksa varsayılan
    local sensitive="${DEFAULT_SENSITIVE_PATHS}"
    read_meta "$domain"
    [[ -n "${SENSITIVE_PATHS:-}" ]] && sensitive="${SENSITIVE_PATHS}"

    render_template "$tpl" \
        "DOMAIN=${domain}" \
        "SAFE_NAME=${sname}" \
        "WEB_ROOT=${WEB_ROOT}" \
        "PHP_VERSION=${php_version}" \
        "RL_REQ_ZONE=${RL_REQ_ZONE}" \
        "RL_REQ_BURST=${RL_REQ_BURST}" \
        "RL_LOGIN_ZONE=${RL_LOGIN_ZONE}" \
        "RL_LOGIN_BURST=${RL_LOGIN_BURST}" \
        "RL_CONN=${RL_CONN}" \
        "RL_SENSITIVE_PATHS=${sensitive}" \
        > "${sites}/${domain}.conf"
}

```

- [ ] **Step 4: Testi çalıştır, geçtiğini doğrula**

Run: `bash tests/test_domain_write_vhost.sh`
Expected: PASS.

- [ ] **Step 5: `_domain_add` arg parse'ı genişlet (flag'ler + meta)**

`lib/domain.sh` `_domain_add()` fonksiyonunun başını (`_domain_add() {` satırından `php_version_exists ... || error ...` satırına kadar, ~line 47-63) şununla değiştir:

```bash
_domain_add() {
    # Argümansız (pozisyonel domain yok) çağrı → interaktif sihirbaz
    local _has_domain=false _a
    for _a in "$@"; do [[ "$_a" != -* ]] && _has_domain=true; done
    if [[ "$_has_domain" == false ]]; then
        _domain_add_wizard
        return
    fi

    local domain=""
    local php_version="${DEFAULT_PHP_VERSION}"
    local rate_profile="standard"
    local do_ssl=true
    local sensitive_paths="${DEFAULT_SENSITIVE_PATHS}"

    # Argümanları parse et
    for arg in "$@"; do
        case "$arg" in
            --php=*)       php_version="${arg#--php=}" ;;
            --rate=*)      rate_profile="${arg#--rate=}" ;;
            --sensitive=*) sensitive_paths="${arg#--sensitive=}" ;;
            --no-ssl)      do_ssl=false ;;
            -*) warn "Bilinmeyen seçenek: ${arg}" ;;
            *) domain="$arg" ;;
        esac
    done

    [[ -z "$domain" ]] && error "Domain belirtilmedi. Kullanım: srvctl domain add example.com [--php=8.3] [--rate=standard]"
    domain_exists "$domain" && error "Domain zaten mevcut: ${domain}"
    php_version_exists "$php_version" || error "PHP ${php_version} kurulu değil. Önce kurun."
    rate_profile="$(rate_profile_resolve "$rate_profile")"
```

(Not: `_domain_add_wizard` Task 6'da eklenir; bu task'tan sonra ama Task 6'dan önce çalıştırılırsa argümanlı `domain add` etkilenmez — `_has_domain=true` dalı sihirbazı çağırmaz.)

- [ ] **Step 6: Meta yazımını ve vhost çağrısını entegre et**

`lib/domain.sh`'de Nginx Vhost adımını (line 183-199) şununla değiştir:

```bash
    # ─── 5. Nginx Vhost ───
    current=$((current + 1))
    step "${current}/${total}" "Nginx vhost oluşturuluyor... (profil: ${rate_profile})"

    write_meta "$domain" "RATE_PROFILE" "$rate_profile"
    write_meta "$domain" "SENSITIVE_PATHS" "$sensitive_paths"

    _domain_write_vhost "$domain" "$php_version" "$rate_profile" http

    ln -sf "/etc/nginx/sites-available/${domain}.conf" \
        "/etc/nginx/sites-enabled/${domain}.conf"

    nginx_test
    systemctl reload nginx
    success "Nginx vhost aktif"
```

Ardından SSL adımını (line 201-222) şununla değiştir (SSL'i `do_ssl`'e bağla, SSL render'ını helper'a devret):

```bash
    # ─── 6. SSL (Let's Encrypt) ───
    current=$((current + 1))
    if [[ "$do_ssl" == true ]]; then
        step "${current}/${total}" "SSL sertifikası alınıyor..."
        if certbot --nginx -d "${domain}" \
            --non-interactive --agree-tos --redirect \
            -m "admin@${domain}" 2>/dev/null; then

            _domain_write_vhost "$domain" "$php_version" "$rate_profile" ssl
            nginx_test && systemctl reload nginx
            success "SSL aktif (Let's Encrypt + HSTS)"
        else
            warn "SSL alınamadı — DNS ayarlarını kontrol edin"
            warn "Sonra çalıştırın: certbot --nginx -d ${domain}"
        fi
    else
        step "${current}/${total}" "SSL atlandı (--no-ssl)"
        info "Sonra almak için: certbot --nginx -d ${domain}"
    fi
```

- [ ] **Step 7: Regresyon — tüm testler + shellcheck**

Run: `bash tests/run.sh && shellcheck lib/domain.sh`
Expected: Tüm test dosyaları PASS; domain.sh'de yeni kodda shellcheck hatası yok.

- [ ] **Step 8: Commit**

```bash
git add lib/domain.sh tests/test_domain_write_vhost.sh
git commit -m "feat: _domain_write_vhost + domain add profil/meta/--no-ssl entegrasyonu"
```

**Sunucu doğrulaması (manuel):** `sudo srvctl domain add test.com --rate=strict --no-ssl` → vhost'ta `zone=rl_strict`; `.srvctl-meta` `RATE_PROFILE=strict` içerir.

---

## Task 6: İnteraktif sihirbaz (bare domain add)

**Files:**
- Modify: `lib/domain.sh` (yeni `_domain_wizard_collect`, `_domain_add_wizard`)
- Create: `tests/test_wizard.sh`

**Interfaces:**
- Consumes: `rate_profile_names` (Task 1), `domain_exists`, `confirm` (core.sh), `DEFAULT_PHP_VERSION`, `DEFAULT_SENSITIVE_PATHS`; `_domain_add` (Task 5).
- Produces: `_domain_wizard_collect()` (stdin'den girdi alır; global `WIZ_DOMAIN/WIZ_PHP/WIZ_PROFILE/WIZ_SSL/WIZ_SENSITIVE` set eder; iptalde `return 1`). `_domain_add_wizard()` (collect → argv kur → `_domain_add`).

- [ ] **Step 1: `tests/test_wizard.sh` — başarısız testi yaz**

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

# Tüm varsayılanlar (boş satırlar) + confirm=evet.
# Process substitution (< <(...)) kullanılır: redirect subshell YARATMAZ, böylece
# WIZ_* global'leri mevcut shell'de kalır ve assert edilebilir. (Pipe `|` subshell yaratır — kullanma.)
_domain_wizard_collect < <(printf 'example.com\n\n\n\n\nevet\n') >/dev/null 2>&1
rc_default=$?
assert_eq "$rc_default"    "0"                            "varsayılan akış rc=0"
assert_eq "$WIZ_DOMAIN"    "example.com"                  "wizard domain"
assert_eq "$WIZ_PHP"       "${DEFAULT_PHP_VERSION}"       "wizard php varsayılan"
assert_eq "$WIZ_PROFILE"   "standard"                     "wizard profil varsayılan"
assert_eq "$WIZ_SSL"       "evet"                         "wizard ssl varsayılan"
assert_eq "$WIZ_SENSITIVE" "${DEFAULT_SENSITIVE_PATHS}"   "wizard hassas varsayılan"

# Özel değerler + iptal (confirm=hayır → return 1)
_domain_wizard_collect < <(printf 'site.com\n8.2\nstrict\nhayir\nadmin|x\nhayır\n') >/dev/null 2>&1
rc_cancel=$?
assert_eq "$rc_cancel"    "1"          "iptal → rc=1"
assert_eq "$WIZ_DOMAIN"   "site.com"   "iptal öncesi domain set edilmiş"
assert_eq "$WIZ_PROFILE"  "strict"     "iptal öncesi profil set edilmiş"

rm -rf "$WEB_ROOT"
test_summary
```

> Not: Pipe (`cmd | { ...; }`) bash'te grup komutu **subshell**'de çalıştırır → `WIZ_*` ana shell'e dönmez. Bu yüzden test, `< <(printf ...)` (process substitution + redirect) kullanır: fonksiyon mevcut shell'de çalışır, yalnızca stdin yönlenir, global'ler korunur.

- [ ] **Step 2: Testi çalıştır, başarısız olduğunu doğrula**

Run: `bash tests/test_wizard.sh`
Expected: FAIL — `_domain_wizard_collect: command not found`.

- [ ] **Step 3: `lib/domain.sh`'ye sihirbazı ekle**

`_domain_write_vhost` fonksiyonundan **sonra**, `_domain_add`'in üstüne ekle:

```bash
# Sihirbaz: girdileri toplar, WIZ_* global değişkenlerine yazar. İptalde 1 döner.
_domain_wizard_collect() {
    WIZ_DOMAIN=""; WIZ_PHP=""; WIZ_PROFILE=""; WIZ_SSL="evet"; WIZ_SENSITIVE=""
    local domain php_version profile ssl_ans sensitive

    # 1. Domain
    while :; do
        read -rp "  Domain adı (örn. example.com): " domain
        [[ -z "$domain" ]] && { warn "Domain boş olamaz."; continue; }
        if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
            warn "Geçersiz domain formatı."; continue
        fi
        domain_exists "$domain" && { warn "Domain zaten mevcut: ${domain}"; continue; }
        break
    done

    # 2. PHP sürümü
    read -rp "  PHP sürümü [${DEFAULT_PHP_VERSION}]: " php_version
    php_version="${php_version:-${DEFAULT_PHP_VERSION}}"

    # 3. Rate-limit profili
    echo "  Profiller: $(rate_profile_names | tr '\n' ' ')"
    read -rp "  Rate-limit profili [standard]: " profile
    profile="${profile:-standard}"

    # 4. SSL
    read -rp "  SSL şimdi alınsın mı? (evet/hayır) [evet]: " ssl_ans
    ssl_ans="${ssl_ans:-evet}"

    # 5. Hassas yollar
    echo "  Varsayılan hassas yollar: ${DEFAULT_SENSITIVE_PATHS}"
    read -rp "  Değiştir (boş = varsayılan): " sensitive
    sensitive="${sensitive:-${DEFAULT_SENSITIVE_PATHS}}"

    # Özet
    divider
    echo "  Domain:    ${domain}"
    echo "  PHP:       ${php_version}"
    echo "  Profil:    ${profile}"
    echo "  SSL:       ${ssl_ans}"
    echo "  Hassas:    ${sensitive}"
    divider

    WIZ_DOMAIN="$domain"; WIZ_PHP="$php_version"; WIZ_PROFILE="$profile"
    WIZ_SSL="$ssl_ans"; WIZ_SENSITIVE="$sensitive"

    confirm "Bu ayarlarla devam edilsin mi?" || return 1
    return 0
}

# Sihirbaz: girdi toplar ve _domain_add'i kurulu argümanlarla çağırır.
_domain_add_wizard() {
    header "Yeni Domain — İnteraktif Kurulum"
    _domain_wizard_collect || { info "İptal edildi."; return 1; }

    local args=("$WIZ_DOMAIN" "--php=${WIZ_PHP}" "--rate=${WIZ_PROFILE}" "--sensitive=${WIZ_SENSITIVE}")
    [[ "$WIZ_SSL" != "evet" ]] && args+=("--no-ssl")
    _domain_add "${args[@]}"
}

```

- [ ] **Step 4: Testi çalıştır, geçtiğini doğrula**

Run: `bash tests/test_wizard.sh`
Expected: PASS — varsayılanlar doğru, iptal `RC=1`.

- [ ] **Step 5: Regresyon + shellcheck + commit**

```bash
bash tests/run.sh && shellcheck lib/domain.sh tests/test_wizard.sh
git add lib/domain.sh tests/test_wizard.sh
git commit -m "feat: argümansız domain add interaktif sihirbazı"
```

**Sunucu doğrulaması (manuel):** Argümansız `sudo srvctl domain add` → sihirbaz akışı; özet sonrası `evet` → domain kurulur. `sudo srvctl domain add x.com --php=8.3` → sihirbaz açılmaz (eski davranış).

---

## Task 7: `domain rate-limit` alt-komutu

**Files:**
- Modify: `lib/domain.sh` (`cmd_domain` dispatch + help ~9-45; yeni `_domain_rate_limit`, `_rate_limit_list`)
- Create: `tests/test_rate_limit_cmd.sh`

**Interfaces:**
- Consumes: `rate_profile_names/field/line/load`, `read_meta/write_meta`, `read_credentials`, `_domain_write_vhost`, `domain_exists`, `nginx_test`-yerine doğrudan `nginx -t` (sunucu), `log_action`.
- Produces: `cmd_domain` içinde `rate-limit) _domain_rate_limit "${@:2}" ;;`. `_domain_rate_limit <domain> <profil> | --show | --list`. `_rate_limit_list()` (profilleri tablo olarak stdout'a basar).

- [ ] **Step 1: `tests/test_rate_limit_cmd.sh` — başarısız testi yaz**

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

# --list tüm profilleri ve değerlerini basar
out=$(_rate_limit_list)
assert_contains "$out" "strict"   "list strict satırı"
assert_contains "$out" "rl_api"   "list api zone"
assert_contains "$out" "100"      "list relaxed conn"

# --show meta'dan profili okur
mkdir -p "${WEB_ROOT}/example.com"
write_meta example.com RATE_PROFILE relaxed
out=$(_domain_rate_limit example.com --show)
assert_contains "$out" "relaxed"     "show profil"
assert_contains "$out" "rl_relaxed"  "show req zone"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Testi çalıştır, başarısız olduğunu doğrula**

Run: `bash tests/test_rate_limit_cmd.sh`
Expected: FAIL — `_rate_limit_list: command not found`.

- [ ] **Step 3: `_rate_limit_list` ve `_domain_rate_limit` ekle**

`lib/domain.sh` sonuna ekle:

```bash
# ═══════════════════════════════════════════════
#  DOMAIN RATE-LIMIT — per-domain profil yönetimi
# ═══════════════════════════════════════════════
_rate_limit_list() {
    header "Rate-Limit Profilleri"
    printf "  %-10s %-12s %-6s %-15s %-6s %s\n" "PROFİL" "REQ_ZONE" "BURST" "LOGIN_ZONE" "BURST" "CONN"
    divider
    local p
    for p in $(rate_profile_names); do
        printf "  %-10s %-12s %-6s %-15s %-6s %s\n" \
            "$p" \
            "$(rate_profile_field "$p" 2)" \
            "$(rate_profile_field "$p" 3)" \
            "$(rate_profile_field "$p" 4)" \
            "$(rate_profile_field "$p" 5)" \
            "$(rate_profile_field "$p" 6)"
    done
}

_domain_rate_limit() {
    # require_root yalnızca yazma (profil değiştirme) için; --show/--list salt-okunur.
    local domain="" profile="" action="set" arg
    for arg in "$@"; do
        case "$arg" in
            --show) action="show" ;;
            --list) action="list" ;;
            -*)     warn "Bilinmeyen seçenek: ${arg}" ;;
            *)      if [[ -z "$domain" ]]; then domain="$arg"; else profile="$arg"; fi ;;
        esac
    done

    if [[ "$action" == "list" ]]; then
        _rate_limit_list
        return
    fi

    [[ -z "$domain" ]] && error "Kullanım: srvctl domain rate-limit <domain> <profil> | --show | --list"
    domain_exists "$domain" || error "Domain bulunamadı: ${domain}"

    if [[ "$action" == "show" ]]; then
        read_meta "$domain"
        rate_profile_load "${RATE_PROFILE:-standard}"
        info "Domain: ${domain}"
        echo "  Profil:        ${RL_PROFILE}"
        echo "  İstek zone:    ${RL_REQ_ZONE} (burst ${RL_REQ_BURST})"
        echo "  Login zone:    ${RL_LOGIN_ZONE} (burst ${RL_LOGIN_BURST})"
        echo "  Bağlantı/IP:   ${RL_CONN}"
        return
    fi

    # ─── Profil değiştir (root gerekir) ───
    require_root
    [[ -z "$profile" ]] && error "Profil belirtilmedi. Kullanım: srvctl domain rate-limit ${domain} <profil>"
    [[ -z "$(rate_profile_line "$profile")" ]] && error "Geçersiz profil: ${profile} (srvctl domain rate-limit --list)"

    read_credentials "$domain"
    local php_version="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
    local conf="/etc/nginx/sites-available/${domain}.conf"
    local mode="http"
    grep -q 'listen 443' "$conf" 2>/dev/null && mode="ssl"

    # Mevcut config'i yedekle (atomic geri dönüş)
    local backup="${conf}.bak.$$"
    cp "$conf" "$backup"

    _domain_write_vhost "$domain" "$php_version" "$profile" "$mode"

    if nginx -t 2>/dev/null; then
        rm -f "$backup"
        write_meta "$domain" "RATE_PROFILE" "$profile"
        systemctl reload nginx
        log_action "domain rate-limit ${domain} → ${profile}"
        success "Rate-limit profili güncellendi: ${domain} → ${profile}"
    else
        mv "$backup" "$conf"
        error "Nginx testi başarısız — değişiklik geri alındı. Profil değişmedi."
    fi
}
```

- [ ] **Step 4: `cmd_domain` dispatch + help'e ekle**

`lib/domain.sh` line 20 (`        migrate)   _domain_migrate "${@:2}" ;;`) **altına** ekle:

```bash
        rate-limit) _domain_rate_limit "${@:2}" ;;
```

Aynı fonksiyondaki help bloğunda (line 39, `migrate <domain> <user@host>` satırından sonra) ekle:

```bash
            echo "    rate-limit <domain> <profil>    Rate-limit profilini değiştir/göster"
```

- [ ] **Step 5: Testi çalıştır, geçtiğini doğrula**

Run: `bash tests/test_rate_limit_cmd.sh`
Expected: PASS.

- [ ] **Step 6: Regresyon + shellcheck + commit**

```bash
bash tests/run.sh && shellcheck lib/domain.sh tests/test_rate_limit_cmd.sh
git add lib/domain.sh tests/test_rate_limit_cmd.sh
git commit -m "feat: domain rate-limit alt-komutu (set/--show/--list, atomic rollback)"
```

**Sunucu doğrulaması (manuel):** `sudo srvctl domain rate-limit example.com strict` → reload + `429`; bilinçli bozuk profil → eski config geri yüklenir, nginx ayakta.

---

## Task 8: Audit kontrolü + completions + install + dokümantasyon

**Files:**
- Modify: `lib/security.sh` (per-domain döngü ~176)
- Modify: `completions/srvctl.bash` (domain_cmds + rate-limit profil tamamlama)
- Modify: `completions/srvctl.zsh` (domain_cmds)
- Modify: `install.sh` (rate-profiles.conf kopyalama)
- Modify: `bin/srvctl` (domain help satırı, ~line 80)
- Modify: `README.md` (komut + profil dokümantasyonu)
- Create: `tests/test_audit_check.sh`

**Interfaces:**
- Consumes: `_check` (security.sh audit kapsamı), `rate_profile_names`.
- Produces: audit'e per-domain `limit_req` varlık kontrolü; completions'a `rate-limit`; install'a profil conf kopyası.

- [ ] **Step 1: `tests/test_audit_check.sh` — başarısız testi yaz**

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

# security.sh'de per-domain limit_req kontrolü tanımlı mı (string seviyesinde)
assert_ok grep -q "rate-limit uygulanmış" "${REPO_ROOT}/lib/security.sh"
assert_ok grep -q "limit_req " "${REPO_ROOT}/lib/security.sh"

# completions rate-limit içeriyor mu
assert_ok grep -q "rate-limit" "${REPO_ROOT}/completions/srvctl.bash"
assert_ok grep -q "rate-limit" "${REPO_ROOT}/completions/srvctl.zsh"

# install.sh rate-profiles.conf kopyalıyor mu
assert_ok grep -q "rate-profiles.conf" "${REPO_ROOT}/install.sh"

test_summary
```

- [ ] **Step 2: Testi çalıştır, başarısız olduğunu doğrula**

Run: `bash tests/test_audit_check.sh`
Expected: FAIL — grep'ler eşleşmez.

- [ ] **Step 3: `lib/security.sh` per-domain kontrol ekle**

Line 176 (`            "test -S /run/php/php${php_ver}-fpm-${sname}.sock 2>/dev/null"`) **altına** ekle:

```bash

        # Rate-limit profili uygulanmış mı
        _check "${domain}: rate-limit uygulanmış" \
            "grep -q 'limit_req ' /etc/nginx/sites-available/${domain}.conf 2>/dev/null"
```

- [ ] **Step 4: `completions/srvctl.bash` güncelle**

Line 24'ü değiştir:
```bash
            local domain_cmds="add remove list info clone suspend unsuspend php-switch resources staging migrate rate-limit"
```

Line 27-30 (`elif [[ ${COMP_CWORD} -eq 3 ]]` bloğu) şununla değiştir:
```bash
            elif [[ ${COMP_CWORD} -eq 3 ]]; then
                # Domain adı tamamlama
                _srvctl_complete_domains
            elif [[ ${COMP_CWORD} -eq 4 && "${COMP_WORDS[2]}" == "rate-limit" ]]; then
                COMPREPLY=($(compgen -W "strict standard relaxed api" -- "$cur"))
            fi
```

- [ ] **Step 5: `completions/srvctl.zsh` güncelle**

Line 52'den sonra (`'migrate:Sunucular arası taşı'`) ekle:
```
                        'rate-limit:Rate-limit profilini değiştir/göster'
```

- [ ] **Step 6: `install.sh` rate-profiles.conf kopyalama**

`install.sh` line 94 (`fi` — srvctl.conf koruma bloğu sonu) **altına** ekle:

```bash

# rate-profiles.conf (yoksa kopyala; mevcut özelleştirmeyi koru)
if [[ ! -f "${INSTALL_DIR}/conf/rate-profiles.conf" ]]; then
    cp "${SCRIPT_DIR}/conf/rate-profiles.conf" "${INSTALL_DIR}/conf/rate-profiles.conf"
fi
```

- [ ] **Step 7: `bin/srvctl` domain help satırı**

`bin/srvctl` line 80 (`domain resources` echo satırı) **altına** ekle:

```bash
        echo -e "    ${CYAN}domain rate-limit${NC} <domain> <profil> Rate-limit profili"
```

- [ ] **Step 8: `README.md` dokümantasyon**

`README.md`'de "Domain — Operasyonel (v2.0)" bloğuna (line 73-82 civarı) ekle:
```bash
sudo srvctl domain rate-limit example.com strict     # profil: strict|standard|relaxed|api
sudo srvctl domain rate-limit example.com --show     # mevcut profili göster
sudo srvctl domain rate-limit --list                 # profilleri listele
```

Ve "Domain — Temel" bloğuna not ekle (line 65 civarı, `domain add` satırından sonra):
```
# Argümansız `domain add` interaktif sihirbazı başlatır (domain, PHP, rate-limit profili, SSL).
```

- [ ] **Step 9: Testi çalıştır, geçtiğini doğrula**

Run: `bash tests/test_audit_check.sh`
Expected: PASS.

- [ ] **Step 10: Completions sözdizimi + tam regresyon + shellcheck**

Run:
```bash
bash -n completions/srvctl.bash && bash tests/run.sh && shellcheck lib/security.sh install.sh bin/srvctl
```
Expected: Tüm test dosyaları PASS; sözdizimi/shellcheck hatası yok.

- [ ] **Step 11: Commit**

```bash
git add lib/security.sh completions/srvctl.bash completions/srvctl.zsh install.sh bin/srvctl README.md tests/test_audit_check.sh
git commit -m "feat: audit rate-limit kontrolü + completions + install + dokümantasyon"
```

**Sunucu doğrulaması (manuel):** `sudo srvctl security audit` → her domain için "rate-limit uygulanmış" PASS. Tab-completion `srvctl domain rate-limit <TAB>` profil adlarını önerir.

---

## Notlar

- **Dev makinede test edilebilir** (Task 1-8 unit testleri): profil parser, meta read/write, template render, zone emitter, vhost write helper, wizard input toplama, rate-limit list/show, audit/completions/install string kontrolleri.
- **Yalnızca gerçek Ubuntu sunucuda doğrulanır:** tam `domain add` provizyonu (useradd, chroot, certbot), `init` ile nginx zone yazımı + reload, `domain rate-limit` canlı reload/rollback, gerçek `429` yanıtı. Her ilgili task'ın sonunda "Sunucu doğrulaması" notu var.
- **Kapsam dışı (spec ile uyumlu):** çok-framework app-type matrisi, docroot subdir seçimi, profil oluşturma komutu (conf elle düzenlenir).
