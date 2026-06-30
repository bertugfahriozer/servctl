# srvctl Güvenlik Sertleştirme — Faz 1 Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** srvctl'in tüm modüllerinde kök-neden ailesinin (RC2/RC3/RC4) savunma katmanını kurmak: root'un web-kullanıcısına ait dosyaları `source`/`eval` etmesini durdurmak, kimlikleri `safe_name`'den türetmek, merkezi girdi doğrulama + escape eklemek, webhook'u fail-closed yapmak ve secret/backup'ları kilitlemek — tamamı macOS'ta unit-test edilebilir.

**Architecture:** Yeni güvenlik mantığı küçük, saf, env-yönlendirilebilir `lib/core.sh` yardımcılarına (validator'lar, `read_kv_file`, `assert_root_owned_path`, `secure_file`/`secure_dir`, `safe_extract`, portable `stat`) konur; bu spine üzerine her modülün çağıran tarafı bağlanır. Doğrulayıcılar **predicate**'tir (0/1 döner, asla `exit` etmez) — böylece mevcut bash test harness'ında (`tests/`) `assert_ok`/`assert_fail` ile test edilebilirler. Faz 1 yapısal sahiplik modeline (T1) dokunmaz; o Faz 2'ye aittir (bkz. spec §8).

**Tech Stack:** Bash (pure), mevcut hafif bash test harness (`tests/lib.sh` + `tests/run.sh`, harici bağımlılık yok), `openssl` (HMAC/parola), `jq` (Cloudflare JSON), `stat` (portable GNU/BSD). Hedef runtime Ubuntu 22.04 root; geliştirme/test macOS.

## Global Constraints

- **Dil:** Tüm kullanıcıya dönük string'ler ve kod yorumları **Türkçe** (proje konvansiyonu). `confirm()`/prompt'lar `evet` bekler.
- **Shell sözleşmesi:** Her script `set -euo pipefail`; beklenen başarısızlıklara `|| true`.
- **Çekirdek:** `error` ÇIKAR (exit) — `lib/core.sh:27`. `load_config` source anında çalışır (`core.sh:63`); doğrulama yalnızca *var-ama-geçersiz* değerde `error` vermeli, varsayılanlarda asla (testler core.sh'i sorunsuz source edebilmeli).
- **Doğrulayıcılar predicate'tir:** `return 0/1`, çıktı yok, `error`/`exit` yok. Fail-closed davranışı ÇAĞIRAN tarafta: `validate_x "$v" || error "..."`.
- **Test edilebilirlik:** Yeni mantık macOS'ta (root/nginx/systemd yok) `bash tests/run.sh` ile yeşil olmalı. Root/nginx/systemd gerektiren adımlar açıkça "entegrasyon (Ubuntu host)" diye işaretli; yine de tam kod düzenlemesi gösterilir.
- **Commit mesajları Türkçe**, şu satırla biter: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **TDD:** Her task önce başarısız test → minimal implementasyon → geçen test → commit.

## Dosya Yapısı (oluşturulan/değiştirilen)

**Spine (yardımcı evi):**
- `lib/core.sh` — yeni primitifler: `_stat_owner`/`_stat_mode`, 8 validator, `read_kv_file`, `assert_root_owned_path`, `secure_file`/`secure_dir`, `safe_extract`, `render_template` newline-reddi; `read_credentials`/`read_meta`/`write_meta` yeniden-yazımı.

**Çağıranlar (her biri spine'dan tüketir):**
- `lib/domain.sh` — `_domain_list` source→parse, kimlik türetme, `_domain_add` `validate_domain`, `_domain_write_vhost` `assert_regex_safe`, mysql secret-off-argv.
- `lib/security.sh` — audit source→parse, `eval` kaldırma.
- `lib/deploy.sh` — kimlik türetme (web_/php).
- `lib/ip.sh` — IP/country/uint doğrulama.
- `lib/user.sh` — `validate_username`.
- `lib/cloudflare.sh` — JSON `jq -n --arg`.
- `lib/init.sh` — `load_config` doğrulama, `/backups`+`/root/.my.cnf` umask/secure.
- `lib/backup.sh` — `safe_extract` restore, artefakt perm, `.credentials` hariç.
- `lib/webhook.sh` — fail-closed imza + localhost bind.

**Testler (yeni):** `tests/test_stat_portable.sh`, `test_validators.sh`, `test_read_kv_file.sh`, `test_read_credentials.sh`, `test_assert_root_owned.sh`, `test_secure_fs.sh`, `test_safe_extract.sh`, `test_render_newline.sh`, `test_identity_derivation.sh`, `test_regex_safe_vhost.sh`, `test_ip_gates.sh`, `test_user_gate.sh`, `test_cf_json.sh`, `test_webhook_sig.sh` (+ mevcut `test_meta.sh` regresyon kapısı). `tests/run.sh` bunları otomatik keşfeder.

## Sıralama & bağımlılıklar

Spine ÖNCE iner (her şey onu çağırır): **F1→F2→F3→F4→F5→F6→F7→F8** (Task 1-8). Ardından bağımsız tema dilimleri herhangi bir sırada inebilir: **T2 (Task 9-11)**, **T4 (Task 12-17)**, **T5 (Task 18-20)**, **T6 (Task 21-25)**. Tema-içi sıra her task'ın "Interfaces/Ordering" notunda. **F9 (Task 26)** en sonda tüm-suite yeşil kapısıdır. Not: T2 dilimi `read_kv_file`/kimlik türetme için F3+F4'e; T4 validator'lara (F2); T6 `secure_*`/`safe_extract`'e (F6/F7) bağlıdır.

---

### Task 1 — [F1] Portable stat helpers (`_stat_owner` / `_stat_mode`)

**Files:** Modify `lib/core.sh` (insert helper block after the `# ─── Yardımcı Fonksiyonlar ───` marker at line 65, before `require_root`). Test: `tests/test_stat_portable.sh`.
**Interfaces:** Consumes: none. Produces: `_stat_owner <path>` (echoes owning username), `_stat_mode <path>` (echoes octal perms). Used by F5 (`assert_root_owned_path`).

- [ ] **Step 1: Write the failing test**
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

tmpf="$(mktemp)"
chmod 640 "$tmpf"

# _stat_owner: boş olmayan bir sahip adı döndürür
owner="$(_stat_owner "$tmpf")"
assert_eq "$(test -n "$owner" && echo yes)" "yes" "_stat_owner boş değil"
# çalıştıran kullanıcı sahip olmalı (macOS dev: whoami)
assert_eq "$owner" "$(whoami)" "_stat_owner geçerli sahip"

# _stat_mode: sadece rakamlardan oluşan octal mod döndürür
mode="$(_stat_mode "$tmpf")"
assert_eq "$(test -n "$mode" && echo yes)" "yes" "_stat_mode boş değil"
assert_eq "$(printf '%s' "$mode" | grep -Eqc '^[0-7]+$' >/dev/null; [[ "$mode" =~ ^[0-7]+$ ]] && echo yes)" "yes" "_stat_mode octal"
# chmod 640 → 640 ile bitmeli (macOS '640', GNU '640')
assert_contains "$mode" "640" "_stat_mode 640 modunu okur"

rm -f "$tmpf"
rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_stat_portable.sh` ; Expected: FAIL with `command not found`/non-zero — `_stat_owner` / `_stat_mode` not yet defined, so the `owner=`/`mode=` captures are empty and assertions fail.

- [ ] **Step 3: Implement** — Insert into `lib/core.sh` immediately after line 65 (`# ─── Yardımcı Fonksiyonlar ───`):
```bash
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
```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_stat_portable.sh`

- [ ] **Step 5: Commit**
```bash
git add lib/core.sh tests/test_stat_portable.sh
git commit -m "$(cat <<'EOF'
feat(core): portable stat sarmalayıcıları (_stat_owner/_stat_mode)

GNU (-c) ve BSD (-f) stat farkını gizler; assert_root_owned_path ve
güvenlik kontrolleri bu primitif üzerinden çalışır.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 2 — [F2] Input validators (8 predicates)

**Files:** Modify `lib/core.sh` (insert a new "Doğrulayıcılar" block after the `_stat_mode` helper from F1). Test: `tests/test_validators.sh`.
**Interfaces:** Consumes: none. Produces (all are PREDICATES — `return 0` valid / `return 1` invalid, NO output, never `error`/exit):
`validate_domain <name>`, `assert_safe_ident <val>`, `assert_php_version <val>`, `assert_regex_safe <val>`, `validate_username <val>`, `validate_ip_or_cidr <val>`, `validate_uint <val> [max]`, `validate_country <val>`. Consumed by F3 (`read_kv_file` callers conceptually), T2/T4 tasks downstream, and F6 (`render_template` callers).

- [ ] **Step 1: Write the failing test**
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# ─── validate_domain ───
for good in example.com a.b.c sub-domain.example.co.uk x x9 9x.io; do
    assert_ok validate_domain "$good"
done
for bad in "" "../etc" "a/b" ".leading" "trailing." "a..b" "-bad.com" "bad-.com" "UPPER.com.with space" "$(printf 'a\nb')"; do
    assert_fail validate_domain "$bad"
done
# 253'ten uzun reddedilir
long="$(printf 'a%.0s' {1..254})"
assert_fail validate_domain "$long"

# ─── assert_safe_ident ───
for good in usr_example_com db_x A1_b 0underscore; do assert_ok assert_safe_ident "$good"; done
for bad in "" "a-b" "a.b" "a b" "a;b" 'a$b' "a/b"; do assert_fail assert_safe_ident "$bad"; done

# ─── assert_php_version ───
for good in 8.3 7.4 10.20 5.6; do assert_ok assert_php_version "$good"; done
for bad in "" 8 8.3.1 "8 .3" v8.3 "8.x" "8."; do assert_fail assert_php_version "$bad"; done

# ─── assert_regex_safe (nginx token) ───
for good in 'login|admin' 'wp-login\.php' 'a/b/c' 'auth|panel|dashboard' 'user/login'; do
    assert_ok assert_regex_safe "$good"
done
for bad in "" 'a{1}' 'a}b' 'a;b' 'a b' "$(printf 'a\nb')" 'a$b' 'a"b' 'a*b' 'a(b)'; do
    assert_fail assert_regex_safe "$bad"
done

# ─── validate_username ───
for good in deployer web_example_com a _x ab-c d_e; do assert_ok validate_username "$good"; done
for bad in "" "1user" "-user" "Upper" "a b" "a;b" "$(printf 'x%.0s' {1..33})"; do
    assert_fail validate_username "$bad"
done

# ─── validate_ip_or_cidr ───
for good in 1.2.3.4 10.0.0.0/8 192.168.1.1/32 ::1 2001:db8::1 2001:db8::/32 fe80::1; do
    assert_ok validate_ip_or_cidr "$good"
done
for bad in "" 256.1.1.1 1.2.3 1.2.3.4/33 "1.2.3.4 " "a.b.c.d" "10.0.0.0/-1" "::gggg"; do
    assert_fail validate_ip_or_cidr "$bad"
done

# ─── validate_uint ───
for good in 0 1 65535 2222; do assert_ok validate_uint "$good"; done
for bad in "" -1 1.5 "1 " a1 " 1"; do assert_fail validate_uint "$bad"; done
# üst sınırlı
assert_ok   validate_uint 65535 65535
assert_fail validate_uint 65536 65535
assert_ok   validate_uint 0 100

# ─── validate_country ───
for good in TR US DE GB; do assert_ok validate_country "$good"; done
for bad in "" tr USA T1 "T R" "T"; do assert_fail validate_country "$bad"; done

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_validators.sh` ; Expected: FAIL — none of the 8 validator functions exist yet, so every `assert_ok` reports "komut başarısız olmamalıydı" (function-not-found returns non-zero).

- [ ] **Step 3: Implement** — Insert into `lib/core.sh` after the `_stat_mode` helper block:
```bash
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
```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_validators.sh`

- [ ] **Step 5: Commit**
```bash
git add lib/core.sh tests/test_validators.sh
git commit -m "$(cat <<'EOF'
feat(core): 8 merkezi girdi doğrulayıcı (predikat, fail-closed çağıranda)

validate_domain/assert_safe_ident/assert_php_version/assert_regex_safe/
validate_username/validate_ip_or_cidr/validate_uint/validate_country.
Tablo-tabanlı iyi/kötü vaka testleri.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 3 — [F3] Strict `key=value` reader (`read_kv_file`) — parse, never source/eval

**Files:** Modify `lib/core.sh` (insert after the validators block from F2). Test: `tests/test_read_kv_file.sh`.
**Interfaces:** Consumes: none. Produces: `read_kv_file <file> <KEY...>` — for each KEY, sets global var KEY to the raw value after the first `=` on the line matching `^KEY=`; missing key leaves var untouched; always `return 0`; NEVER sources/evals. Consumed by F4 wiring (`read_credentials`/`read_meta` rewrite) and downstream T2 tasks.

- [ ] **Step 1: Write the failing test**
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

kvf="${WEB_ROOT}/sample.kv"
cat > "$kvf" <<EOF
DOMAIN=example.com
SAFE_NAME=example_com
DB_PASS=Abc123XYZ
IGNORED=should_not_be_read
SENSITIVE_PATHS=login|admin|wp-login\.php
EOF

# Whitelist anahtarları çıkarılır, IGNORED okunmaz
unset DOMAIN SAFE_NAME DB_PASS SENSITIVE_PATHS IGNORED
read_kv_file "$kvf" DOMAIN SAFE_NAME DB_PASS SENSITIVE_PATHS
assert_eq "${DOMAIN:-}"         "example.com"  "DOMAIN okundu"
assert_eq "${SAFE_NAME:-}"      "example_com"  "SAFE_NAME okundu"
assert_eq "${DB_PASS:-}"        "Abc123XYZ"    "DB_PASS okundu"
# değer '=' veya '|' içerse bile ilk '='ten sonrası verbatim
assert_eq "${SENSITIVE_PATHS:-}" 'login|admin|wp-login\.php' "SENSITIVE_PATHS verbatim"
# whitelist'te olmayan anahtar ortama sızmaz
assert_eq "${IGNORED:-UNSET}"   "UNSET"        "IGNORED set edilmedi"

# Eksik anahtar mevcut değişkene dokunmaz
MISSING_KEY="onceki_deger"
read_kv_file "$kvf" MISSING_KEY
assert_eq "${MISSING_KEY}" "onceki_deger" "eksik anahtar dokunulmadı"

# read_kv_file her zaman 0 döner (eksik dosyada bile)
assert_ok read_kv_file "${WEB_ROOT}/yokboyle.kv" DOMAIN

# ── KRİTİK: komut-subst payload'ı ASLA çalışmaz ──
rm -f "${WEB_ROOT}/pwned"
evil="${WEB_ROOT}/evil.kv"
cat > "$evil" <<EOF
DOMAIN=safe.com
EVIL=\$(touch ${WEB_ROOT}/pwned)
DB_PASS=\`touch ${WEB_ROOT}/pwned2\`
EOF
unset DOMAIN EVIL DB_PASS
read_kv_file "$evil" DOMAIN EVIL DB_PASS
# yan-etki dosyaları OLUŞMAMALI
assert_eq "$(test -e "${WEB_ROOT}/pwned"  && echo VAR || echo YOK)" "YOK" "\$() çalışmadı"
assert_eq "$(test -e "${WEB_ROOT}/pwned2" && echo VAR || echo YOK)" "YOK" "backtick çalışmadı"
# EVIL/DB_PASS değeri ham metin olarak alınır (çalıştırılmaz)
assert_eq "${DOMAIN:-}" "safe.com" "evil dosyadan DOMAIN ham okundu"
assert_contains "${EVIL:-}" 'touch' "EVIL ham metin (çalışmadı)"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_read_kv_file.sh` ; Expected: FAIL — `read_kv_file` undefined; the `assert_ok read_kv_file ...` and value assertions fail. (Side-effect assertions may pass by luck since nothing runs, but the read assertions fail.)

- [ ] **Step 3: Implement** — Insert into `lib/core.sh` after the validators block:
```bash
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
        line="$(grep -E "^${k}=" "$file" 2>/dev/null | head -1)" || true
        [[ -n "$line" ]] || continue
        # İlk '='ten sonrasını ata — komut-substitution YOK (printf -v atama)
        printf -v "$k" '%s' "${line#*=}"
    done
    return 0
}
```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_read_kv_file.sh`

- [ ] **Step 5: Commit**
```bash
git add lib/core.sh tests/test_read_kv_file.sh
git commit -m "$(cat <<'EOF'
feat(core): read_kv_file — katı key=value parse (source/eval YOK)

Yalnız whitelist anahtarları okur, değeri printf -v ile atar; saldırgan-
kontrollü dosyada \$()/backtick payload'ı asla çalışmaz. Yan-etki testi dahil.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 4 — [F4] Wire `read_credentials` / `read_meta` / `write_meta` onto `read_kv_file` (unquoted format)

**Files:** Modify `lib/core.sh`: `read_credentials` (lines 147-154), `read_meta` (lines 208-214), `write_meta` line 226 (`printf '%s=%q\n'` → `printf '%s=%s\n'`). Test: existing `tests/test_meta.sh` MUST still pass (regression); add `tests/test_read_credentials.sh`.
**Interfaces:** Consumes: `read_kv_file` (F3). Produces: `read_credentials <domain>` sets `DOMAIN SAFE_NAME WEB_USER PHP_VERSION DB_NAME DB_USER DB_PASS REDIS_USER REDIS_PASS REDIS_PREFIX`; `read_meta <domain>` sets `RATE_PROFILE SENSITIVE_PATHS`; `write_meta` stores unquoted. Both readers no longer `source`.

- [ ] **Step 1: Write the failing test** — `tests/test_read_credentials.sh`:
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

mkdir -p "${WEB_ROOT}/example.com"
# Gerçek .credentials biçimi: düz KEY=value
cat > "${WEB_ROOT}/example.com/.credentials" <<EOF
DOMAIN=example.com
SAFE_NAME=example_com
WEB_USER=web_example_com
PHP_VERSION=8.3
DB_NAME=db_example_com
DB_USER=usr_example_com
DB_PASS=S3cretPass00
REDIS_USER=redis_example_com
REDIS_PASS=R3disPass00
REDIS_PREFIX=example_com
EOF

unset DOMAIN SAFE_NAME WEB_USER PHP_VERSION DB_NAME DB_USER DB_PASS REDIS_USER REDIS_PASS REDIS_PREFIX
read_credentials example.com
assert_eq "${DOMAIN:-}"       "example.com"      "DOMAIN"
assert_eq "${WEB_USER:-}"     "web_example_com"  "WEB_USER"
assert_eq "${PHP_VERSION:-}"  "8.3"              "PHP_VERSION"
assert_eq "${DB_PASS:-}"      "S3cretPass00"     "DB_PASS"
assert_eq "${REDIS_PREFIX:-}" "example_com"      "REDIS_PREFIX"

# ── source EDİLMEMELİ: dosyaya enjekte edilen komut çalışmaz ──
rm -f "${WEB_ROOT}/pwned3"
printf 'EVIL=$(touch %s/pwned3)\n' "$WEB_ROOT" >> "${WEB_ROOT}/example.com/.credentials"
read_credentials example.com
assert_eq "$(test -e "${WEB_ROOT}/pwned3" && echo VAR || echo YOK)" "YOK" "read_credentials source etmiyor"

# meta yoksa hata vermez
assert_ok read_credentials yokboyle.com

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_read_credentials.sh` ; Expected: FAIL — current `read_credentials` (core.sh:147) still `source`s the file, so the appended `EVIL=$(touch .../pwned3)` line executes and `pwned3` IS created → `read_credentials source etmiyor` assertion fails. Also run `bash tests/test_meta.sh` now (still PASS — `%q` of `admin|backend&x` round-trips through `source`).

- [ ] **Step 3: Implement** — Three edits in `lib/core.sh`.

  Edit A — replace `read_credentials` body (lines 147-154):
```bash
# Credentials dosyasını oku (source DEĞİL — katı parse)
read_credentials() {
    local domain="$1"
    local creds_file="${WEB_ROOT}/${domain}/.credentials"
    read_kv_file "$creds_file" \
        DOMAIN SAFE_NAME WEB_USER PHP_VERSION \
        DB_NAME DB_USER DB_PASS \
        REDIS_USER REDIS_PASS REDIS_PREFIX
}
```

  Edit B — replace `read_meta` body (lines 208-214):
```bash
# Domain meta dosyasını oku (source DEĞİL — katı parse)
read_meta() {
    local meta_file="${WEB_ROOT}/${1}/.srvctl-meta"
    read_kv_file "$meta_file" RATE_PROFILE SENSITIVE_PATHS
}
```

  Edit C — change `write_meta` storage (line 226), unquoted so `read_kv_file` reads back verbatim:
```bash
    printf '%s=%s\n' "$key" "$value" >> "$meta_file"
```

- [ ] **Step 4: Run, verify PASS** — Run BOTH:
  - `bash tests/test_read_credentials.sh` (now PASS — no source, `pwned3` absent)
  - `bash tests/test_meta.sh` (still PASS — unquoted `printf '%s=%s\n'` writes `SENSITIVE_PATHS=admin|backend&x`, `read_kv_file` reads it back verbatim, duplicate count stays 1)

- [ ] **Step 5: Commit**
```bash
git add lib/core.sh tests/test_read_credentials.sh
git commit -m "$(cat <<'EOF'
refactor(core): read_credentials/read_meta source→read_kv_file; write_meta tırnaksız

Saldırgan-kontrollü .credentials/.srvctl-meta artık source edilmiyor (RC2).
write_meta %q yerine düz %s=%s yazıyor; read_kv_file verbatim okuyor.
test_meta.sh round-trip regresyonu korunur.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 5 — [F5] Ownership gate predicate (`assert_root_owned_path`)

**Files:** Modify `lib/core.sh` (insert after `read_kv_file` / before the Rate-Limit section). Test: `tests/test_assert_root_owned.sh`.
**Interfaces:** Consumes: `_stat_owner`, `_stat_mode` (F1), `WEB_ROOT` (load_config). Produces: `assert_root_owned_path <path>` — `return 0` iff `<path>` and every ancestor dir up to and including `${WEB_ROOT}` is root-owned, not a symlink, and not group/other-writable; else `return 1`. PREDICATE — does NOT exit. Consumed by T2 wiring (warn-mode in `read_credentials`/`read_meta` later).

- [ ] **Step 1: Write the failing test** (only the rejection cases are reachable as non-root on macOS — positive root-owned case needs integration/root):
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# macOS dev kutusunda her şey 'whoami' sahipli (root değil) → tüm vakalar reddedilmeli.

# 1) root-olmayan sahipli düz dosya → 1
f="${WEB_ROOT}/example.com/.credentials"
mkdir -p "${WEB_ROOT}/example.com"
: > "$f"
assert_fail assert_root_owned_path "$f"

# 2) symlink hedefi → 1 (symlink kendisi reddedilir)
real="${WEB_ROOT}/example.com/real.cred"; : > "$real"
linkp="${WEB_ROOT}/example.com/link.cred"
ln -s "$real" "$linkp"
assert_fail assert_root_owned_path "$linkp"

# 3) grup/diğer-yazılabilir dosya → 1
ww="${WEB_ROOT}/example.com/ww.cred"; : > "$ww"; chmod 666 "$ww"
assert_fail assert_root_owned_path "$ww"

# 4) grup/diğer-yazılabilir ÜST dizin → 1
mkdir -p "${WEB_ROOT}/wwsite"; chmod 777 "${WEB_ROOT}/wwsite"
wf="${WEB_ROOT}/wwsite/.credentials"; : > "$wf"
assert_fail assert_root_owned_path "$wf"

# 5) var olmayan yol → 1
assert_fail assert_root_owned_path "${WEB_ROOT}/yok/dosya"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_assert_root_owned.sh` ; Expected: FAIL — `assert_root_owned_path` undefined → `assert_fail` runs a missing command which exits non-zero, so `assert_fail` would actually PASS for a missing function. To make this a genuine red, the function must exist but wrong; in practice the first run reports the function-not-found. NOTE for executor: confirm RED by temporarily stubbing `assert_root_owned_path() { return 0; }` at top of test — every `assert_fail` then FAILs. Remove the stub before Step 3. (Documented here so the red phase is real, not vacuous.)

- [ ] **Step 3: Implement** — Insert into `lib/core.sh` after the `read_kv_file` function:
```bash
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
```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_assert_root_owned.sh` (all 5 rejection cases return 1 → `assert_fail` PASS).

- [ ] **Step 5: Commit**
```bash
git add lib/core.sh tests/test_assert_root_owned.sh
git commit -m "$(cat <<'EOF'
feat(core): assert_root_owned_path — sahiplik/symlink/yazılabilirlik kapısı

PREDIKAT: path ve WEB_ROOT'a kadar üst dizinler root-sahipli, symlink-değil,
grup/diğer-yazılamaz mı? macOS'ta erişilebilir tüm RED vakaları test edilir
(pozitif root-sahipli vaka root entegrasyonuna ait).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 6 — [F6] Secure FS creation (`secure_file` / `secure_dir`)

**Files:** Modify `lib/core.sh` (insert after `assert_root_owned_path`). Test: `tests/test_secure_fs.sh`.
**Interfaces:** Consumes: none. Produces: `secure_file <path> [mode]` (default 600), `secure_dir <path> [mode]` (default 700) — create-if-missing under `umask 077`, `chmod`, `chown root:root` (chown guarded for macOS). Consumed by T6 (backup/secret lockdown).

- [ ] **Step 1: Write the failing test** (mode/existence is the testable contract; chown to root is guarded and not asserted on the non-root dev box):
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# secure_file: yoksa oluşturur, varsayılan 600
f="${WEB_ROOT}/secret.cred"
assert_ok secure_file "$f"
assert_eq "$(test -f "$f" && echo VAR || echo YOK)" "VAR" "secure_file oluşturdu"
assert_eq "$(_stat_mode "$f" | tail -c 4)" "600" "secure_file varsayılan mod 600"

# secure_file: özel mod
f2="${WEB_ROOT}/secret2.cred"
secure_file "$f2" 640
assert_eq "$(_stat_mode "$f2" | tail -c 4)" "640" "secure_file özel mod 640"

# secure_file: var olan dosyanın modunu düzeltir
f3="${WEB_ROOT}/loose.cred"; : > "$f3"; chmod 666 "$f3"
secure_file "$f3"
assert_eq "$(_stat_mode "$f3" | tail -c 4)" "600" "secure_file gevşek modu sıkılaştırır"

# secure_dir: yoksa oluşturur, varsayılan 700
d="${WEB_ROOT}/vault"
assert_ok secure_dir "$d"
assert_eq "$(test -d "$d" && echo VAR || echo YOK)" "VAR" "secure_dir oluşturdu"
assert_eq "$(_stat_mode "$d" | tail -c 4)" "700" "secure_dir varsayılan mod 700"

# secure_dir: özel mod + iç içe (mkdir -p)
d2="${WEB_ROOT}/a/b/c"
secure_dir "$d2" 750
assert_eq "$(test -d "$d2" && echo VAR || echo YOK)" "VAR" "secure_dir iç içe oluşturdu"
assert_eq "$(_stat_mode "$d2" | tail -c 4)" "750" "secure_dir özel mod 750"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_secure_fs.sh` ; Expected: FAIL — `secure_file`/`secure_dir` undefined; `assert_ok` reports failure and the file/dir never gets created so mode assertions fail.

- [ ] **Step 3: Implement** — Insert into `lib/core.sh` after `assert_root_owned_path`:
```bash
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
```
Note: `: > "$path"` truncates an existing file — secrets are written AFTER `secure_file` in callers (T6), so creation-then-write is the intended order; the subshell `2>/dev/null || true` tolerates a pre-existing 000-mode file before the `chmod` fixes it. The non-truncation of already-correct files is not required by the contract (ensure-exists + chmod is).

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_secure_fs.sh`

- [ ] **Step 5: Commit**
```bash
git add lib/core.sh tests/test_secure_fs.sh
git commit -m "$(cat <<'EOF'
feat(core): secure_file/secure_dir — umask 077 + chmod + root:root (guard'lı)

Sır/backup yazımları için varsayılan 600/700 oluşturma; chown macOS'ta
guard'lı, mod/varlık test edilir. T6'da kullanılacak.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 7 — [F7] Safe archive extraction (`safe_extract`)

**Files:** Modify `lib/core.sh` (insert after `secure_dir`). Test: `tests/test_safe_extract.sh`.
**Interfaces:** Consumes: none. Produces: `safe_extract <archive> <dest_dir>` — list members first (`tar -tvzf`); if ANY member is absolute (starts with `/`), contains `..`, or is a symlink/hardlink entry, `return 1` WITHOUT extracting; else extract into `dest_dir` and `return 0`. Consumed by T6 (`backup.sh` restore).

- [ ] **Step 1: Write the failing test** (build evil archives with macOS `tar`; verified: absolute member lists with leading `/`, `..` member lists as `../...`, symlink verbose mode-char is `l`, hardlink is `h`):
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

stage="${WEB_ROOT}/stage"; mkdir -p "$stage"

# ── 1) TEMİZ arşiv: düzgün çıkarılır, return 0 ──
mkdir -p "${stage}/clean"; echo "merhaba" > "${stage}/clean/file.txt"
clean_tgz="${WEB_ROOT}/clean.tgz"
tar -czf "$clean_tgz" -C "${stage}/clean" file.txt
dest_ok="${WEB_ROOT}/dest_ok"; mkdir -p "$dest_ok"
assert_ok safe_extract "$clean_tgz" "$dest_ok"
assert_eq "$(cat "${dest_ok}/file.txt" 2>/dev/null)" "merhaba" "temiz arşiv çıkarıldı"

# ── 2) MUTLAK yol üyeli arşiv → red, dest'e yazma yok ──
echo "kotu" > "${WEB_ROOT}/abs_src.txt"
abs_tgz="${WEB_ROOT}/abs.tgz"
tar -cPzf "$abs_tgz" -C / "${WEB_ROOT}/abs_src.txt"   # mutlak üye (-P leading / korur)
# doğrula: listede mutlak üye var
assert_contains "$(tar -tzf "$abs_tgz")" "/" "abs arşivinde mutlak üye var"
dest_abs="${WEB_ROOT}/dest_abs"; mkdir -p "$dest_abs"
assert_fail safe_extract "$abs_tgz" "$dest_abs"
assert_eq "$(find "$dest_abs" -type f | wc -l | tr -d ' ')" "0" "mutlak: dest'e yazılmadı"

# ── 3) ../escape üyeli arşiv → red ──
esc_stage="${WEB_ROOT}/esc"; mkdir -p "$esc_stage"; echo "x" > "${esc_stage}/a"
dotdot_tgz="${WEB_ROOT}/dotdot.tgz"
( cd "$esc_stage" && tar -czf "$dotdot_tgz" "../esc/a" )   # üye yolu '..' içerir
assert_contains "$(tar -tzf "$dotdot_tgz")" ".." "dotdot arşivinde .. üye var"
dest_dd="${WEB_ROOT}/dest_dd"; mkdir -p "$dest_dd"
assert_fail safe_extract "$dotdot_tgz" "$dest_dd"
# escape hedefi (dest dışı) oluşmamalı
assert_eq "$(test -e "${WEB_ROOT}/escape" && echo VAR || echo YOK)" "YOK" "dotdot: dışarı kaçış yok"

# ── 4) symlink üyeli arşiv → red ──
ln_stage="${WEB_ROOT}/lnstage"; mkdir -p "$ln_stage"
echo "data" > "${ln_stage}/real.txt"
ln -s /etc/passwd "${ln_stage}/evil_link"
link_tgz="${WEB_ROOT}/link.tgz"
tar -czf "$link_tgz" -C "$ln_stage" evil_link real.txt
dest_ln="${WEB_ROOT}/dest_ln"; mkdir -p "$dest_ln"
assert_fail safe_extract "$link_tgz" "$dest_ln"
assert_eq "$(find "$dest_ln" -mindepth 1 | wc -l | tr -d ' ')" "0" "symlink: dest'e yazılmadı"

# ── 5) var olmayan arşiv → red ──
assert_fail safe_extract "${WEB_ROOT}/yokboyle.tgz" "$dest_ok"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_safe_extract.sh` ; Expected: FAIL — `safe_extract` undefined; `assert_ok safe_extract (clean)` fails and the clean file is never extracted. (The `assert_fail` cases may vacuously pass; confirm RED via the clean-extract and "temiz arşiv çıkarıldı" assertions.)

- [ ] **Step 3: Implement** — Insert into `lib/core.sh` after `secure_dir`:
```bash
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
```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_safe_extract.sh`

- [ ] **Step 5: Commit**
```bash
git add lib/core.sh tests/test_safe_extract.sh
git commit -m "$(cat <<'EOF'
feat(core): safe_extract — tar-slip/.. /mutlak yol/symlink-hardlink reddi

Çıkarmadan önce üyeleri listeler; tehlikeli üye varsa hiç çıkarmadan 1 döner.
backup.sh restore (T6) bunu kullanacak. macOS tar ile RED+temiz vaka testleri.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 8 — [F8] `render_template` newline/CR rejection

**Files:** Modify `lib/core.sh` `render_template` (lines 114-132; the substitution loop at lines 125-129). Test: `tests/test_render_escaping.sh`.
**Interfaces:** Consumes: `error` (core.sh:27, DOES exit — render-time invariant). Produces: hardened `render_template <file> KEY=value...` that calls `error` (exits) when ANY value contains newline/CR; clean values still substitute. Token charset validation stays in CALLERS via `assert_regex_safe` (F2). Because `error` exits, the test must invoke `render_template` in a SUBSHELL so it doesn't kill the harness.

- [ ] **Step 1: Write the failing test**
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

tpl="${WEB_ROOT}/v.tpl"
printf 'server_name {{DOMAIN}};\nlocation ~ /{{PATHS}} { return 403; }\n' > "$tpl"

# ── Temiz değerler: substitution çalışır, çıktı doğru ──
out="$(render_template "$tpl" DOMAIN=example.com PATHS='login|admin')"
assert_contains "$out" "server_name example.com;" "temiz DOMAIN yerleşti"
assert_contains "$out" "/login|admin {"           "temiz PATHS yerleşti"
assert_not_contains "$out" "{{DOMAIN}}"           "token kalmadı"

# ── newline içeren değer: render_template EXIT eder (error) ──
# error exit ettiği için ALT-KABUKTA çalıştır; non-zero exit beklenir.
bad_nl="$(printf 'evil\ninjected')"
assert_fail bash -c '
  source "'"${REPO_ROOT}"'/lib/core.sh"
  render_template "'"$tpl"'" DOMAIN="evil
injected"
' 
# daha net: değişkenle geçir
assert_fail env BADVAL="$bad_nl" bash -c '
  source "'"${REPO_ROOT}"'/lib/core.sh"
  render_template "'"$tpl"'" DOMAIN="$BADVAL"
'

# ── CR içeren değer de reddedilir ──
bad_cr="$(printf 'evil\rinjected')"
assert_fail env BADVAL="$bad_cr" bash -c '
  source "'"${REPO_ROOT}"'/lib/core.sh"
  render_template "'"$tpl"'" PATHS="$BADVAL"
'

# ── newline reddi çıktı üretmeden olur (dosyaya yazılmaz) ──
out2="$(env BADVAL="$bad_nl" bash -c '
  source "'"${REPO_ROOT}"'/lib/core.sh"
  render_template "'"$tpl"'" DOMAIN="$BADVAL"
' 2>/dev/null)" || true
assert_not_contains "$out2" "injected" "newline değeri çıktıya sızmadı"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_render_escaping.sh` ; Expected: FAIL — current `render_template` (core.sh:114) substitutes ANY value including newline/CR, so the `assert_fail` cases FAIL (render returns 0 and emits the injected text) and `newline değeri çıktıya sızmadı` FAILs.

- [ ] **Step 3: Implement** — Edit the substitution loop in `lib/core.sh` `render_template` (lines 125-129). Replace:
```bash
    for pair in "$@"; do
        local key="${pair%%=*}"
        local value="${pair#*=}"
        content="${content//\{\{${key}\}\}/${value}}"
    done
```
with:
```bash
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
```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_render_escaping.sh`

- [ ] **Step 5: Commit**
```bash
git add lib/core.sh tests/test_render_escaping.sh
git commit -m "$(cat <<'EOF'
feat(core): render_template değerlerinde newline/CR reddi (CRLF enjeksiyon)

Substitution öncesi her değer satırsonu/CR içerirse error (exit) — render-time
değişmezi. Token charset doğrulaması çağıranda (assert_regex_safe). Temiz
değerler eskisi gibi yerleşir.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 9 — [T2.2] Inline source'ları read_kv_file'a çevir (_domain_list, security audit döngüsü)

**Files:**
- Modify `lib/domain.sh:555-561` (`_domain_list` inline `source "${dir}.credentials"`)
- Modify `lib/security.sh:150-155` (`_security_audit` domain döngüsü inline `source "${dir}.credentials"`)
- Test (new): `tests/test_domain_list_parse.sh`

**Interfaces:**
- Consumes: `read_kv_file` (Foundation), `safe_name` (existing).
- Produces: a pure, testable helper `_domain_row <dir>` extracted from `_domain_list` that echoes a `domain|php|user|ssl|chroot` row computed via parse-not-source. `_security_audit`'s loop is integration-tested (needs nginx/php paths) but the inline `source` is replaced with `read_kv_file` + per-iteration var reset.

- [ ] **Step 1: Write the failing test** — `tests/test_domain_list_parse.sh`

This unit-tests an extracted pure helper `_domain_row` (factored out of `_domain_list` so it can run on macOS without nginx/letsencrypt). The test proves a malicious `.credentials` is not sourced and that PHP/user come from the parsed (whitelisted) values, with safe_name fallback.

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

mkdir -p "${WEB_ROOT}/example.com"
SIDE="$(mktemp -u)"
cat > "${WEB_ROOT}/example.com/.credentials" <<CREDS
PHP_VERSION=8.2
WEB_USER=web_example_com
EVIL=\$(touch ${SIDE})
CREDS

# _domain_row "<dir>/" -> "domain|php|user|ssl|chroot"
row="$(_domain_row "${WEB_ROOT}/example.com/")"
assert_eq "$(echo "$row" | cut -d'|' -f1)" "example.com"      "domain alanı"
assert_eq "$(echo "$row" | cut -d'|' -f2)" "8.2"              "php parse edildi"
assert_eq "$(echo "$row" | cut -d'|' -f3)" "web_example_com"  "user parse edildi"
assert_fail test -e "${SIDE}"  "source değil — yan-etki oluşmadı"

# .credentials yoksa: php/user safe_name'den türetilir
mkdir -p "${WEB_ROOT}/Foo.Bar"
row2="$(_domain_row "${WEB_ROOT}/Foo.Bar/")"
assert_eq "$(echo "$row2" | cut -d'|' -f2)" "${DEFAULT_PHP_VERSION}" "php fallback"
assert_eq "$(echo "$row2" | cut -d'|' -f3)" "web_foo_bar"            "user fallback (safe_name)"

# Stale carryover yok: ilk domain PHP_VERSION=8.2 set etti, ikincide sızmamalı
assert_not_contains "$row2" "8.2" "stale carryover yok"

rm -f "${SIDE}"
rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_domain_list_parse.sh` ; Expected: FAIL — `_domain_row` does not exist yet (`command not found`), so every assertion fails.

- [ ] **Step 3: Implement**

**Edit A — extract `_domain_row` and rewrite the loop body in `lib/domain.sh:543-573`.**

Before (`lib/domain.sh:543-573`):
```bash
    local count=0
    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")
        local sname
        sname=$(safe_name "$domain")
        local php_ver="${DEFAULT_PHP_VERSION}"
        local user="web_${sname}"
        local ssl="❌"
        local chroot="❌"

        # Credentials'dan bilgi oku
        if [[ -f "${dir}.credentials" ]]; then
            # shellcheck disable=SC1090
            source "${dir}.credentials"
            php_ver="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
            user="${WEB_USER:-web_${sname}}"
        fi

        # SSL kontrolü
        [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && ssl="✅"

        # Chroot kontrolü
        if [[ -f "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf" ]]; then
            grep -q "chroot" "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf" 2>/dev/null && chroot="✅"
        fi

        printf "  %-30s %-8s %-15s %-6s %-8s\n" "$domain" "$php_ver" "$user" "$ssl" "$chroot"
        count=$((count + 1))
    done
```

After:
```bash
    local count=0
    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local row domain php_ver user ssl chroot
        row=$(_domain_row "$dir")
        IFS='|' read -r domain php_ver user ssl chroot <<< "$row"
        printf "  %-30s %-8s %-15s %-6s %-8s\n" "$domain" "$php_ver" "$user" "$ssl" "$chroot"
        count=$((count + 1))
    done
```

Then add the new pure helper immediately ABOVE `_domain_list` (so it is sourced with the module). Insert before the `_domain_list` definition (around `lib/domain.sh:535`):

```bash
# ───────────────────────────────────────────────────────────────
#  Tek domain dizini için liste satırı üret (saf, parse-not-source)
#  Çıktı: domain|php|user|ssl|chroot
# ───────────────────────────────────────────────────────────────
_domain_row() {
    local dir="$1"
    local domain sname php_ver user ssl chroot
    domain=$(basename "$dir")
    sname=$(safe_name "$domain")
    php_ver="${DEFAULT_PHP_VERSION}"
    user="web_${sname}"
    ssl="❌"
    chroot="❌"

    # Credentials'tan PHP/USER bilgisini parse et (source DEĞİL); her satırda sıfırla
    if [[ -f "${dir}.credentials" ]]; then
        local PHP_VERSION="" WEB_USER=""
        read_kv_file "${dir}.credentials" PHP_VERSION WEB_USER
        # Kimlik: dosyaya güvenme — safe_name'den türet, PHP'yi doğrula
        [[ -n "$PHP_VERSION" ]] && assert_php_version "$PHP_VERSION" && php_ver="$PHP_VERSION"
        user="web_${sname}"
    fi

    # SSL kontrolü
    [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && ssl="✅"

    # Chroot kontrolü
    if [[ -f "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf" ]]; then
        grep -q "chroot" "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf" 2>/dev/null && chroot="✅"
    fi

    printf '%s|%s|%s|%s|%s\n' "$domain" "$php_ver" "$user" "$ssl" "$chroot"
}
```

> Note: `user` is derived as `web_${sname}` (not read from file) per the T2 identity-derivation rule; `WEB_USER` is still parsed (and reset each call) only to demonstrate the whitelist read and avoid stale carryover, but it is intentionally not trusted for the printed identity.

**Edit B — `lib/security.sh:142-159` audit loop: replace inline `source` + reset vars + derive identity.**

Before (`lib/security.sh:142-159`):
```bash
    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")
        local sname
        sname=$(safe_name "$domain")
        local php_ver="${DEFAULT_PHP_VERSION}"

        # Credentials'dan PHP versiyon bilgisini oku
        if [[ -f "${dir}.credentials" ]]; then
            # shellcheck disable=SC1090
            source "${dir}.credentials"
            php_ver="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
        fi

        # Chroot kontrol
        _check "${domain}: chroot aktif" \
            "grep -q 'chroot' /etc/php/${php_ver}/fpm/pool.d/${sname}.conf 2>/dev/null"
```

After:
```bash
    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain sname php_ver PHP_VERSION
        domain=$(basename "$dir")
        sname=$(safe_name "$domain")
        php_ver="${DEFAULT_PHP_VERSION}"

        # Credentials'tan PHP versiyon bilgisini parse et (source DEĞİL); her döngüde sıfırla
        if [[ -f "${dir}.credentials" ]]; then
            PHP_VERSION=""
            read_kv_file "${dir}.credentials" PHP_VERSION
            if [[ -n "$PHP_VERSION" ]] && assert_php_version "$PHP_VERSION"; then
                php_ver="$PHP_VERSION"
            fi
        fi

        # Chroot kontrol
        _check "${domain}: chroot aktif" \
            "grep -q 'chroot' /etc/php/${php_ver}/fpm/pool.d/${sname}.conf 2>/dev/null"
```

(The remainder of the audit loop body — AppArmor, file perms, socket — is unchanged here; the `eval`/`_check` rewrite is Task T2.4.)

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_domain_list_parse.sh` (all PASS). Then `bash tests/run.sh` (no regressions). The `_security_audit` loop change is **integration-only** (requires nginx/php-fpm/AppArmor on an Ubuntu host) — verify by inspection that no `source` remains: `grep -n 'source "\${dir}.credentials"' lib/security.sh lib/domain.sh` must return nothing.

- [ ] **Step 5: Commit**

```bash
git add lib/domain.sh lib/security.sh tests/test_domain_list_parse.sh
git commit -m "$(cat <<'EOF'
guvenlik(T2): _domain_list ve security audit inline source'larini read_kv_file'a cevir

_domain_list'ten saf _domain_row helper'i cikarildi (parse-not-source); kimlik
safe_name'den turetilir, PHP versiyonu assert_php_version'dan gecirilir. security
audit dongusu de inline 'source .credentials' yerine read_kv_file kullanir ve
PHP_VERSION'i her iterasyonda sifirlar (stale carryover yok).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 10 — [T2.3] Identifier'ları .credentials yerine safe_name'den türet (domain.sh + deploy.sh)

**Files:**
- Modify `lib/domain.sh:776-789` (`_domain_clone` src/dst DB), `lib/domain.sh:802-808` (`_domain_clone` mysqldump|mysql), `lib/domain.sh:1013-1016` (`_domain_migrate` db/php)
- Modify `lib/deploy.sh:87-89` (`_deploy_run` php_version/web_user)
- Test (new): `tests/test_identity_derivation.sh`

**Interfaces:**
- Consumes: `safe_name` (existing), `assert_php_version` (Foundation), `read_credentials` (now parse-not-source, from F4).
- Produces: helper `_derive_php <domain> <fallback>` in `lib/core.sh` — echoes a **validated** PHP version: reads `PHP_VERSION` via `read_credentials`, returns it only if `assert_php_version` passes, else echoes the fallback. Used by deploy/clone/migrate so a corrupt `.credentials` cannot inject an arbitrary php path.

- [ ] **Step 1: Write the failing test** — `tests/test_identity_derivation.sh`

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# Bozuk/saldırgan PHP_VERSION içeren .credentials
mkdir -p "${WEB_ROOT}/example.com"
cat > "${WEB_ROOT}/example.com/.credentials" <<CREDS
PHP_VERSION=8.3/../../bin
DB_NAME=evil; DROP DATABASE x
CREDS

# _derive_php: geçersiz versiyon -> fallback'e düşmeli (path/komut enjeksiyonu yok)
assert_eq "$(_derive_php example.com 8.3)" "8.3" "geçersiz PHP_VERSION fallback'e düştü"

# Geçerli versiyon -> aynen döner
mkdir -p "${WEB_ROOT}/ok.com"
cat > "${WEB_ROOT}/ok.com/.credentials" <<CREDS
PHP_VERSION=8.2
CREDS
assert_eq "$(_derive_php ok.com 8.3)" "8.2" "geçerli PHP_VERSION aynen döndü"

# .credentials yok -> fallback
assert_eq "$(_derive_php yok.com 8.1)" "8.1" "credentials yok -> fallback"

# Kimlik türetme: safe_name -> db_/usr_/web_ deterministik
sn="$(safe_name "Foo.Bar")"
assert_eq "$sn"          "foo_bar"      "safe_name"
assert_eq "db_${sn}"     "db_foo_bar"   "db identifier türetildi"
assert_eq "usr_${sn}"    "usr_foo_bar"  "usr identifier türetildi"
assert_eq "web_${sn}"    "web_foo_bar"  "web identifier türetildi"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_identity_derivation.sh` ; Expected: FAIL — `_derive_php` does not exist (`command not found`), so the first three assertions fail.

- [ ] **Step 3: Implement**

**Edit A — add `_derive_php` to `lib/core.sh`** (place after `read_credentials`, around `lib/core.sh:154`):

```bash
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
```

**Edit B — `_domain_clone` DB/php derivation (`lib/domain.sh:776-789`).**

Before:
```bash
    local PHP_VERSION="${DEFAULT_PHP_VERSION}" DB_NAME="db_${src_sname}"
    read_credentials "$src"
    local src_php="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
    local src_db="${DB_NAME:-db_${src_sname}}"

    header "Domain Klonlama: ${src} → ${dst}"

    step "1/4" "Hedef domain oluşturuluyor (tam güvenlik kurulumu)..."
    _domain_add "$dst" "--php=${src_php}"

    local dst_base="${WEB_ROOT}/${dst}"
    local dst_web_user="web_${dst_sname}"
    local dst_db; dst_db=$(grep -E '^DB_NAME=' "${dst_base}/.credentials" 2>/dev/null | cut -d= -f2)
    dst_db="${dst_db:-db_${dst_sname}}"
```

After:
```bash
    # Kimlikleri dosyaya güvenmeden safe_name'den türet; PHP'yi doğrula
    local src_php; src_php=$(_derive_php "$src" "${DEFAULT_PHP_VERSION}")
    local src_db="db_${src_sname}"

    header "Domain Klonlama: ${src} → ${dst}"

    step "1/4" "Hedef domain oluşturuluyor (tam güvenlik kurulumu)..."
    _domain_add "$dst" "--php=${src_php}"

    local dst_base="${WEB_ROOT}/${dst}"
    local dst_web_user="web_${dst_sname}"
    local dst_db="db_${dst_sname}"
```

**Edit C — `_domain_clone` mysqldump|mysql (`lib/domain.sh:802-806`).** Now safe because `src_db`/`dst_db` are derived `^[a-z0-9_]+$` identifiers; no change to the SQL lines themselves is required beyond the derived values above. Confirm by inspection that `lib/domain.sh:803` uses `${src_db}` and `${dst_db}` (it does). No edit needed here — covered by Edit B.

**Edit D — `_domain_migrate` db/php (`lib/domain.sh:1013-1016`).**

Before:
```bash
    local PHP_VERSION="${DEFAULT_PHP_VERSION}" DB_NAME="db_${sname}"
    read_credentials "$domain"
    local db="${DB_NAME:-db_${sname}}"
    local php="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
```

After:
```bash
    # Identifier'ları safe_name'den türet; PHP'yi doğrula (dosyaya güvenme)
    local db="db_${sname}"
    local php; php=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")
```

**Edit E — `_deploy_run` php_version/web_user (`lib/deploy.sh:87-89`).**

Before:
```bash
    read_credentials "$domain"
    local php_version="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
    local web_user="${WEB_USER:-web_${sname}}"
```

After:
```bash
    # Kimlikleri safe_name'den türet; PHP'yi doğrula (web-owned .credentials'a güvenme)
    local php_version; php_version=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")
    local web_user="web_${sname}"
```

> Note on `_deploy_rollback` (`lib/deploy.sh:226-227`): it also does `read_credentials` + `${PHP_VERSION:-...}`. Replace identically for consistency:
> Before:
> ```bash
>     read_credentials "$domain"
>     local php_version="${PHP_VERSION:-${DEFAULT_PHP_VERSION}}"
> ```
> After:
> ```bash
>     local php_version; php_version=$(_derive_php "$domain" "${DEFAULT_PHP_VERSION}")
> ```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_identity_derivation.sh` (all PASS), then `bash tests/run.sh` (no regressions). The deploy/clone/migrate command paths themselves are **integration-only** (need git/mysql/systemd on Ubuntu); verify the edits by inspection and confirm no remaining `DB_NAME`/`WEB_USER` trust from file in these functions: `grep -n 'DB_NAME:-\|WEB_USER:-\|grep -E .\^DB_NAME' lib/domain.sh lib/deploy.sh` should only show the (unchanged) display-only `_domain_info` block.

- [ ] **Step 5: Commit**

```bash
git add lib/core.sh lib/domain.sh lib/deploy.sh tests/test_identity_derivation.sh
git commit -m "$(cat <<'EOF'
guvenlik(T2): db/usr/web identifier'larini safe_name'den turet, PHP'yi dogrula

_derive_php helper'i eklendi: .credentials'taki PHP_VERSION yalnizca
assert_php_version gecerse kullanilir, aksi halde fallback. clone/migrate/deploy
artik DB adi ve web kullaniciyi web-owned .credentials'tan okumak yerine
safe_name'den (db_/usr_/web_) deterministik turetir; bozuk dosya root'a
path/komut enjekte edemez.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 11 — [T2.4] security.sh'ten eval'i kaldır (_check/_warn_check + eval'lı grep)

**Files:**
- Modify `lib/security.sh:31-45` (`_check`/`_warn_check` use `eval "$2"`)
- Modify all `_check`/`_warn_check` call sites in `lib/security.sh` (the second argument changes from a single shell-string to an argv list)
- Modify `lib/security.sh:158-159` (the `_check "...: chroot aktif" "grep -q ... 2>/dev/null"` — the eval'd grep)
- Test (new): `tests/test_security_check.sh`

**Interfaces:**
- Consumes: nothing from earlier T2 tasks (independent), but stacks on the T2.2 loop edit in the same file — apply T2.4 after T2.2 to avoid conflicts.
- Produces: `_check`/`_warn_check` now invoke the test program **directly via `"$@"`** (no `eval`), so call sites pass the predicate as separate argv words instead of one quoted string. This is the safe contract every audit check in the file relies on.

> Because `_check`/`_warn_check` are defined *inside* `_security_audit` (closures over `pass`/`fail`/`warn_count`), unit-testing them requires a thin extraction. We extract the eval-free runner core into a top-level `_security_run_check` that takes a result-callback name plus the command argv, and is unit-testable on macOS.

- [ ] **Step 1: Write the failing test** — `tests/test_security_check.sh`

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/security.sh"

# _security_run_check <on_ok_fn> <on_bad_fn> <cmd...>: cmd'yi eval'siz, dogrudan calistirir.
ok()  { echo "OK:$1"; }
bad() { echo "BAD:$1"; }

# Komut başarılı -> on_ok çağrılır
assert_eq "$(_security_run_check ok bad 'doğru kontrol' true)"  "OK:doğru kontrol"  "başarı -> on_ok"
# Komut başarısız -> on_bad çağrılır
assert_eq "$(_security_run_check ok bad 'yanlış kontrol' false)" "BAD:yanlış kontrol" "başarısızlık -> on_bad"

# KRİTİK: argüman eval EDİLMEMELİ. Bir arg olarak komut-subst payload'ı versek bile
# çalışmamalı; düz argv olarak 'test' programına gider.
SIDE="$(mktemp -u)"
# 'test -e <olmayan>' false döner -> bad; ama hicbir sekilde touch CALISMAMALI
_security_run_check ok bad 'enjeksiyon denemesi' test -e "\$(touch ${SIDE})" >/dev/null 2>&1 || true
assert_fail test -e "${SIDE}"  "argümanlar eval edilmedi (yan-etki yok)"

rm -f "${SIDE}"
rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_security_check.sh` ; Expected: FAIL — `_security_run_check` does not exist yet (`command not found`).

- [ ] **Step 3: Implement**

**Edit A — add top-level eval-free runner `_security_run_check` to `lib/security.sh`** (place above `cmd_security`, around `lib/security.sh:6`):

```bash
# ───────────────────────────────────────────────────────────────
#  Eval'siz kontrol çalıştırıcı (saf, test edilebilir).
#  Kullanım: _security_run_check <on_ok_fn> <on_bad_fn> <label> <cmd...>
#  cmd argv olarak DOĞRUDAN çalıştırılır — asla eval/string-expand edilmez.
# ───────────────────────────────────────────────────────────────
_security_run_check() {
    local on_ok="$1" on_bad="$2" label="$3"
    shift 3
    if "$@" >/dev/null 2>&1; then
        "$on_ok" "$label"
    else
        "$on_bad" "$label"
    fi
}
```

**Edit B — rewrite `_check`/`_warn_check` inside `_security_audit` (`lib/security.sh:31-45`) to delegate without `eval`.**

Before:
```bash
    _check() {
        if eval "$2" > /dev/null 2>&1; then
            _pass "$1"
        else
            _fail "$1"
        fi
    }

    _warn_check() {
        if eval "$2" > /dev/null 2>&1; then
            _pass "$1"
        else
            _warn_result "$1"
        fi
    }
```

After:
```bash
    # Kullanım: _check "<etiket>" <cmd> <arg...>   (eval YOK — argv doğrudan çalışır)
    _check() {
        local label="$1"; shift
        _security_run_check _pass _fail "$label" "$@"
    }

    _warn_check() {
        local label="$1"; shift
        _security_run_check _pass _warn_result "$label" "$@"
    }
```

**Edit C — convert every `_check`/`_warn_check` call site from a single quoted shell-string to argv words.** Each test program is invoked directly; pipelines/negation/globs that previously rode inside the eval'd string must become real subshell command words. Representative conversions (apply to all call sites `lib/security.sh:50-225`):

Simple program (no shell operators) — just unquote into words:
```bash
# Before
_check "Nginx çalışıyor" "systemctl is-active nginx"
# After
_check "Nginx çalışıyor" systemctl is-active nginx
```

```bash
# Before
_check "Kernel hardening aktif" "test -f /etc/sysctl.d/99-srvctl-security.conf"
# After
_check "Kernel hardening aktif" test -f /etc/sysctl.d/99-srvctl-security.conf
```

Pipelines / negation / `grep -r` / command-subst — wrap in `bash -c` with **no interpolation of attacker data** (all arguments here are static literals, so `bash -c '<literal>'` is safe and contains no untrusted input):
```bash
# Before
_check "UFW firewall aktif" "ufw status 2>/dev/null | grep -q 'Status: active'"
# After
_check "UFW firewall aktif" bash -c "ufw status 2>/dev/null | grep -q 'Status: active'"
```

```bash
# Before
_check "SSH varsayılan port değil" "! grep -rq 'Port 22$' /etc/ssh/sshd_config.d/ 2>/dev/null"
# After
_check "SSH varsayılan port değil" bash -c "! grep -rq 'Port 22\$' /etc/ssh/sshd_config.d/ 2>/dev/null"
```

```bash
# Before
_check "ASLR aktif (randomize_va_space=2)" "test \$(sysctl -n kernel.randomize_va_space 2>/dev/null) -eq 2"
# After
_check "ASLR aktif (randomize_va_space=2)" bash -c 'test "$(sysctl -n kernel.randomize_va_space 2>/dev/null)" -eq 2'
```

```bash
# Before
_warn_check "Anonim kullanıcı yok" \
    "! mysql -N -e \"SELECT User FROM mysql.user WHERE User=''\" 2>/dev/null | grep -q '.'"
# After
_warn_check "Anonim kullanıcı yok" bash -c "! mysql -N -e \"SELECT User FROM mysql.user WHERE User=''\" 2>/dev/null | grep -q '.'"
```

> Rule of thumb for the conversion sweep: if the old string contained any of `|`, `!`, `$( )`, `&&`, redirections, or a glob to expand, wrap it as `bash -c '<the exact old string>'` (single-quoted; escape an inner `$` as `\$` only where the old string used `\$`). If it was a plain `program arg arg`, drop the quotes so it becomes argv. The key invariant: **no untrusted/file-derived value is ever passed to `bash -c`** — every argument in this file is a static literal, so this is equivalent in behavior to the old `eval` minus the injection surface.

**Edit D — the chroot check at `lib/security.sh:158-159` (the eval'd grep, inside the loop edited by T2.2).** `php_ver` is now validated by `assert_php_version` (T2.2) and `sname` comes from `safe_name`, so both are safe to interpolate; convert to a direct (eval-free) call:

Before:
```bash
        # Chroot kontrol
        _check "${domain}: chroot aktif" \
            "grep -q 'chroot' /etc/php/${php_ver}/fpm/pool.d/${sname}.conf 2>/dev/null"
```

After:
```bash
        # Chroot kontrol (php_ver assert_php_version'dan geçti, sname safe_name türevi)
        _check "${domain}: chroot aktif" \
            grep -q chroot "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf"
```

And the AppArmor / socket checks in the same loop similarly:
```bash
# Before
        _warn_check "${domain}: AppArmor enforce" \
            "aa-status 2>/dev/null | grep -q 'srvctl-${sname}'"
# After
        _warn_check "${domain}: AppArmor enforce" \
            bash -c "aa-status 2>/dev/null | grep -q 'srvctl-${sname}'"
```
```bash
# Before
        _check "${domain}: FPM socket mevcut" \
            "test -S /run/php/php${php_ver}-fpm-${sname}.sock 2>/dev/null"
# After
        _check "${domain}: FPM socket mevcut" \
            test -S "/run/php/php${php_ver}-fpm-${sname}.sock"
```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_security_check.sh` (all PASS — proves the runner is eval-free), then `bash tests/run.sh` (no regressions). Confirm no `eval` remains in the file: `grep -n 'eval' lib/security.sh` must return nothing. The full audit output is **integration-only** (needs root + nginx/php/mysql/redis/systemd on Ubuntu); verify the call-site sweep by inspection that every `_check`/`_warn_check` now passes argv or `bash -c '<literal>'` and no remaining bare quoted-shell-string second argument exists: `grep -nE '_(check|warn_check) "[^"]*" +"' lib/security.sh` should return nothing.

- [ ] **Step 5: Commit**

```bash
git add lib/security.sh tests/test_security_check.sh
git commit -m "$(cat <<'EOF'
guvenlik(T2): security audit'ten eval'i kaldir (_check/_warn_check + chroot grep)

_security_run_check eval'siz, argv-tabanli calistirici eklendi; _check/_warn_check
artik test programini dogrudan cagirir. Tum cagri yerleri argv ya da statik
literal 'bash -c' formatina cevrildi (dosya-turevli deger asla bash -c'ye
gecmez). Chroot/socket kontrolleri T2'de dogrulanan php_ver/sname ile dogrudan
calistirilir. Dosyada artik hic 'eval' yok.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

**Ordering note for the executor:** Run F4 → T2.2 → T2.3 → T2.4. T2.2 and T2.4 both edit `lib/security.sh` (T2.2 the loop's `source`→`read_kv_file`, T2.4 the loop's `eval`→direct-call), so do T2.2 first; T2.4 Edit D/loop-checks build on the `php_ver` that T2.2 made valid. T2.3 depends on F4's parse-not-source `read_credentials` (via `_derive_php`).

**Files referenced (absolute):** `/Users/bertugfahriozer/Projects/srvctl/lib/core.sh`, `/Users/bertugfahriozer/Projects/srvctl/lib/domain.sh`, `/Users/bertugfahriozer/Projects/srvctl/lib/security.sh`, `/Users/bertugfahriozer/Projects/srvctl/lib/deploy.sh`, `/Users/bertugfahriozer/Projects/srvctl/tests/lib.sh`, `/Users/bertugfahriozer/Projects/srvctl/tests/run.sh`, `/Users/bertugfahriozer/Projects/srvctl/tests/test_meta.sh`.

---

### Task 12 — [T4.1] `validate_domain` gate in `_domain_add` CLI path
**Files:** Modify `lib/domain.sh:168` (after `[[ -z "$domain" ]] && error ...`, before `domain_exists`) / Test `tests/test_domain_validate.sh`
**Interfaces:** Consumes: `validate_domain` (Foundation/core.sh), `error` (core.sh) ; Produces: a hardened `_domain_add` that rejects malformed domains before any FS/DB mutation. Later tasks rely on nothing new here.

The wizard path (`_domain_wizard_collect`) already has an inline regex, but the non-wizard CLI path (`domain add bad/../name`) reaches `domain_exists`/`safe_name` with an unvalidated value. `validate_domain` is a predicate (returns 0/1, no output); the caller pairs it with `error`. We unit-test the gate via a thin standalone helper that exercises the exact predicate the CLI uses, since `_domain_add` itself calls `require_root` and mutating commands that cannot run on macOS.

- [ ] **Step 1: Write the failing test** — `tests/test_domain_validate.sh`
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

# _domain_add CLI yolu, sihirbaz dışı çağrıda validate_domain kapısını uygulamalı.
# Mutasyon komutları (require_root, useradd...) macOS'ta çalışmadığından, kapının
# kendisini ince bir yardımcıyla test ediyoruz: _domain_add_validate_gate <domain>
# -> validate_domain başarısızsa 1 döner (error/exit YOK, predicate gibi davranır).

# İyi domain'ler
assert_ok   _domain_add_validate_gate "example.com"
assert_ok   _domain_add_validate_gate "sub.example.co.uk"

# Kötü domain'ler — path traversal / slash / boş / baştaki nokta
assert_fail _domain_add_validate_gate "bad/../name"
assert_fail _domain_add_validate_gate "a/b"
assert_fail _domain_add_validate_gate ".leadingdot.com"
assert_fail _domain_add_validate_gate "evil;rm -rf"
assert_fail _domain_add_validate_gate ""

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_domain_validate.sh` ; Expected: FAIL — `_domain_add_validate_gate` does not exist yet, so every `assert_ok`/`assert_fail` line reports the function as not found (`assert_ok` lines FAIL because the missing command exits non-zero; the suite ends with a non-zero `Başarısız` count).

- [ ] **Step 3: Implement** — In `lib/domain.sh`, add the thin gate helper just above `_domain_add` (before line 141 `_domain_add() {`), and wire `validate_domain` into the CLI path.

Add the helper (new function, immediately above `_domain_add`):
```bash
# CLI yolu için domain doğrulama kapısı (test edilebilir ince sarmalayıcı).
# validate_domain predikatını birebir uygular; geçersizse 1 döner.
_domain_add_validate_gate() {
    validate_domain "$1"
}
```

Then change the existing `_domain_add` guard at `lib/domain.sh:168`:

Before:
```bash
    [[ -z "$domain" ]] && error "Domain belirtilmedi. Kullanım: srvctl domain add example.com [--php=8.3] [--rate=standard]"
    domain_exists "$domain" && error "Domain zaten mevcut: ${domain}"
```
After:
```bash
    [[ -z "$domain" ]] && error "Domain belirtilmedi. Kullanım: srvctl domain add example.com [--php=8.3] [--rate=standard]"
    _domain_add_validate_gate "$domain" || error "Geçersiz domain adı: ${domain}"
    domain_exists "$domain" && error "Domain zaten mevcut: ${domain}"
```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_domain_validate.sh` (expect all PASS, `Başarısız: 0`).

- [ ] **Step 5: Commit**
```bash
git add lib/domain.sh tests/test_domain_validate.sh
git commit -m "$(cat <<'EOF'
güvenlik: _domain_add CLI yoluna validate_domain kapısı (path traversal reddi)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 13 — [T4.2] `assert_regex_safe` gate on `SENSITIVE_PATHS` in `_domain_write_vhost`
**Files:** Modify `lib/domain.sh:57-75` (`_domain_write_vhost`) / Test `tests/test_domain_sensitive_safe.sh`
**Interfaces:** Consumes: `assert_regex_safe` (Foundation/core.sh), `DEFAULT_SENSITIVE_PATHS` (core.sh:160), `warn` (core.sh), `read_meta` ; Produces: a `_domain_write_vhost` that guarantees only an `assert_regex_safe`-clean value reaches `{{RL_SENSITIVE_PATHS}}` in the rendered nginx config.

A `web_<domain>`-controlled `.srvctl-meta` can carry a malicious `SENSITIVE_PATHS` (e.g. `admin) { deny all; } location ~ /pwn {`) that would break out of the `location ~ ^/(...)` nginx block. `_domain_write_vhost` currently feeds `${SENSITIVE_PATHS}` straight into `render_template`. We validate it with `assert_regex_safe` (a predicate); if invalid, fall back to `DEFAULT_SENSITIVE_PATHS` and `warn`. Test mirrors the existing `tests/test_domain_write_vhost.sh` pattern (`SITES_AVAILABLE` override + `write_meta`).

Note: `read_meta` reformatting (`%q`→unquoted) is a Foundation/T2 change; this task depends only on `read_meta` exposing `SENSITIVE_PATHS` as a variable, which it already does. The malicious value below contains a space and `{`/`}`, all rejected by `assert_regex_safe` regardless of meta storage format.

- [ ] **Step 1: Write the failing test** — `tests/test_domain_sensitive_safe.sh`
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
export SITES_AVAILABLE="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
SRVCTL_TEMPLATES="${REPO_ROOT}/templates"
source "${REPO_ROOT}/lib/domain.sh"

mkdir -p "${WEB_ROOT}/example.com"

# 1) Temiz (assert_regex_safe geçen) meta değeri normal şekilde uygulanır.
write_meta example.com SENSITIVE_PATHS 'admin|backend'
_domain_write_vhost example.com 8.3 relaxed http
conf=$(cat "${SITES_AVAILABLE}/example.com.conf")
assert_contains "$conf" 'location ~ ^/(admin|backend) {' "temiz meta sensitive uygulandı"

# 2) Kötü amaçlı meta (boşluk + süslü parantez içeren nginx kaçışı) RENDER'a ULAŞMAMALI.
#    assert_regex_safe reddedince DEFAULT_SENSITIVE_PATHS'e düşülür.
write_meta example.com SENSITIVE_PATHS 'admin) { deny all; } location ~ /pwn {'
_domain_write_vhost example.com 8.3 relaxed http 2>/dev/null
conf=$(cat "${SITES_AVAILABLE}/example.com.conf")
assert_not_contains "$conf" "deny all"   "kötü amaçlı sensitive render'a ulaşmadı"
assert_not_contains "$conf" "/pwn"       "enjekte edilen location bloğu yok"
assert_contains     "$conf" 'wp-login\.php' "varsayılan hassas yollara düşüldü"
assert_not_contains "$conf" "{{"         "leftover token yok"

rm -rf "$WEB_ROOT" "$SITES_AVAILABLE"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_domain_sensitive_safe.sh` ; Expected: FAIL — the malicious `SENSITIVE_PATHS` currently passes through to the rendered file, so `assert_not_contains "deny all"` and `assert_not_contains "/pwn"` FAIL and `wp-login\.php` is absent (the fallback assertion FAILs too).

- [ ] **Step 3: Implement** — Edit `_domain_write_vhost` in `lib/domain.sh`.

Before (`lib/domain.sh:59-62`):
```bash
    # Hassas yollar: meta override yoksa varsayılan
    local sensitive="${DEFAULT_SENSITIVE_PATHS}"
    read_meta "$domain"
    [[ -n "${SENSITIVE_PATHS:-}" ]] && sensitive="${SENSITIVE_PATHS}"
```
After:
```bash
    # Hassas yollar: meta override yoksa varsayılan.
    # Meta web kullanıcısı tarafından yazılabildiğinden değer GÜVENİLMEZ:
    # nginx token charset'ine uymuyorsa (boşluk, {, }, ; ...) varsayılana düş.
    local sensitive="${DEFAULT_SENSITIVE_PATHS}"
    read_meta "$domain"
    if [[ -n "${SENSITIVE_PATHS:-}" ]]; then
        if assert_regex_safe "${SENSITIVE_PATHS}"; then
            sensitive="${SENSITIVE_PATHS}"
        else
            warn "Geçersiz SENSITIVE_PATHS (${domain}) — varsayılan hassas yollar kullanılıyor"
        fi
    fi
```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_domain_sensitive_safe.sh` (all PASS). Also confirm no regression: `bash tests/test_domain_write_vhost.sh` (`admin|backend` is `assert_regex_safe`-clean so it still applies).

- [ ] **Step 5: Commit**
```bash
git add lib/domain.sh tests/test_domain_sensitive_safe.sh
git commit -m "$(cat <<'EOF'
güvenlik: _domain_write_vhost SENSITIVE_PATHS'i assert_regex_safe ile kapı; geçersizse varsayılana düş

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 14 — [T4.3] IP/country/uint validation in `ip.sh` sinks
**Files:** Modify `lib/ip.sh` — `_ip_ban` (`:38`/`:36`), `_ip_whitelist` add (`:78`), `_ip_blacklist` add (`:113`), `_ip_geoblock` add (`:199`) / Test `tests/test_ip_validate.sh`
**Interfaces:** Consumes: `validate_ip_or_cidr`, `validate_country`, `validate_uint` (Foundation/core.sh), `error` (core.sh) ; Produces: hardened ip handlers; for the unit test, two thin gate helpers — `_ip_value_gate <ip>` and `_ip_geoblock_gate <country>` — that apply the exact predicates the command uses without `require_root`/`ufw`/`sed`.

The blacklist/whitelist/geoblock handlers write attacker-influenceable strings into `sed` patterns, `ufw` argv, and nginx `allow/deny` directives. `_ip_ban`'s duration flows into `sleep`. We validate at entry. The handlers themselves call `ufw`/`sed`/`systemctl` (unavailable on macOS), so the test drives standalone gate helpers that re-run the same predicates.

- [ ] **Step 1: Write the failing test** — `tests/test_ip_validate.sh`
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/ip.sh"

# IP / CIDR kapısı (ban/whitelist/blacklist girişlerinde kullanılır)
assert_ok   _ip_value_gate "1.2.3.4"
assert_ok   _ip_value_gate "10.0.0.0/8"
assert_ok   _ip_value_gate "2001:db8::1"
assert_fail _ip_value_gate "1.2.3.4; rm -rf /"
assert_fail _ip_value_gate "evil\$(id)"
assert_fail _ip_value_gate "999.999.999.999"
assert_fail _ip_value_gate ""

# Süre kapısı (sleep'e akar): uint ya da 'permanent'
assert_ok   _ip_duration_gate "86400"
assert_ok   _ip_duration_gate "permanent"
assert_fail _ip_duration_gate "10; reboot"
assert_fail _ip_duration_gate "abc"

# Ülke kodu kapısı (geoblock)
assert_ok   _ip_geoblock_gate "TR"
assert_ok   _ip_geoblock_gate "cn"     # büyük harfe çevrilip TR/CN gibi doğrulanır
assert_fail _ip_geoblock_gate "TURKEY"
assert_fail _ip_geoblock_gate "T;R"
assert_fail _ip_geoblock_gate ""

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_ip_validate.sh` ; Expected: FAIL — `_ip_value_gate`, `_ip_duration_gate`, `_ip_geoblock_gate` are undefined, so all assertions fail (the suite ends with non-zero `Başarısız`).

- [ ] **Step 3: Implement** — Add three gate helpers at the top of `lib/ip.sh` (immediately after the `cmd_ip()` closing `}` at line 32), then wire the predicates into the four sinks.

Add helpers (after `cmd_ip()`):
```bash
# ─── Test edilebilir doğrulama kapıları (predicate; error/exit YOK) ───
# Komut girişlerinde kullanılan predikatları birebir uygular.
_ip_value_gate()     { validate_ip_or_cidr "$1"; }
_ip_duration_gate()  { [[ "$1" == "permanent" ]] || validate_uint "$1"; }
_ip_geoblock_gate()  { validate_country "$(echo "$1" | tr '[:lower:]' '[:upper:]')"; }
```

`_ip_ban` — change `lib/ip.sh:38` (after the empty check) to validate ip + duration:

Before:
```bash
    [[ -z "$ip" ]] && error "IP belirtilmedi."

    # UFW ile engelle
```
After:
```bash
    [[ -z "$ip" ]] && error "IP belirtilmedi."
    _ip_value_gate "$ip" || error "Geçersiz IP/CIDR: ${ip}"
    _ip_duration_gate "$duration" || error "Geçersiz süre: ${duration} (saniye sayısı veya 'permanent')"

    # UFW ile engelle
```

`_ip_whitelist` add — change `lib/ip.sh:78`:

Before:
```bash
        add)
            [[ -z "$ip" ]] && error "IP belirtilmedi."
            echo "$ip" >> "$whitelist_file"
```
After:
```bash
        add)
            [[ -z "$ip" ]] && error "IP belirtilmedi."
            _ip_value_gate "$ip" || error "Geçersiz IP/CIDR: ${ip}"
            echo "$ip" >> "$whitelist_file"
```

`_ip_blacklist` add — change `lib/ip.sh:113`:

Before:
```bash
        add)
            [[ -z "$ip" ]] && error "IP belirtilmedi."
            echo "$ip" >> "$blacklist_file"
```
After:
```bash
        add)
            [[ -z "$ip" ]] && error "IP belirtilmedi."
            _ip_value_gate "$ip" || error "Geçersiz IP/CIDR: ${ip}"
            echo "$ip" >> "$blacklist_file"
```

`_ip_geoblock` add — change `lib/ip.sh:199-201`:

Before:
```bash
        add)
            [[ -z "$country" ]] && error "Ülke kodu belirtilmedi (ör: CN, RU, KP)"
            country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
            echo "$country" >> "$geoblock_file"
```
After:
```bash
        add)
            [[ -z "$country" ]] && error "Ülke kodu belirtilmedi (ör: CN, RU, KP)"
            country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
            validate_country "$country" || error "Geçersiz ülke kodu: ${country} (2 harfli ISO, ör: CN, RU)"
            echo "$country" >> "$geoblock_file"
```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_ip_validate.sh` (all PASS).

- [ ] **Step 5: Commit**
```bash
git add lib/ip.sh tests/test_ip_validate.sh
git commit -m "$(cat <<'EOF'
güvenlik: ip.sh ban/whitelist/blacklist/geoblock girişlerine IP/süre/ülke doğrulaması

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 15 — [T4.4] `validate_username` in `_user_add`
**Files:** Modify `lib/user.sh:56-57` (`_user_add`) / Test `tests/test_user_validate.sh`
**Interfaces:** Consumes: `validate_username` (Foundation/core.sh), `error` (core.sh) ; Produces: hardened `_user_add`; for the test, thin gate helper `_user_add_validate_gate <username>` applying the exact predicate before `useradd`/`.conf`/`sudoers` creation.

`_user_add` takes a username that becomes a Linux account (`useradd`), a config filename (`${SRVCTL_USERS_DIR}/${username}.conf`), and a `sudoers.d` filename + `${username} ALL=...` rule. An unvalidated username (`../root`, `a b`, `x ALL=(root)`) is a path-traversal / sudoers-injection sink. `validate_username` (`^[a-z_][a-z0-9_-]*$`, ≤32) is checked before any creation. The command calls `require_root`/`useradd`, so the test exercises a standalone gate.

- [ ] **Step 1: Write the failing test** — `tests/test_user_validate.sh`
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/user.sh"

# Geçerli kullanıcı adları
assert_ok   _user_add_validate_gate "deployer"
assert_ok   _user_add_validate_gate "ci_bot-1"
assert_ok   _user_add_validate_gate "_svc"

# Geçersiz: path traversal, boşluk, sudoers enjeksiyonu, büyük harf, baştaki rakam, 32+
assert_fail _user_add_validate_gate "../root"
assert_fail _user_add_validate_gate "a b"
assert_fail _user_add_validate_gate "x ALL=(root)"
assert_fail _user_add_validate_gate "Admin"
assert_fail _user_add_validate_gate "1abc"
assert_fail _user_add_validate_gate ""
assert_fail _user_add_validate_gate "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  # 35 > 32

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_user_validate.sh` ; Expected: FAIL — `_user_add_validate_gate` is undefined, so all lines fail.

- [ ] **Step 3: Implement** — Add the gate helper just above `_user_add` (before line 45 `_user_add() {`), and wire `validate_username` into `_user_add`.

Add helper:
```bash
# Test edilebilir kullanıcı adı doğrulama kapısı (predicate; error/exit YOK).
_user_add_validate_gate() {
    validate_username "$1"
}
```

Change `_user_add` guard (`lib/user.sh:56`):

Before:
```bash
    [[ -z "$username" ]] && error "Kullanıcı adı belirtilmedi."
    [[ "$role" =~ ^(admin|developer|viewer)$ ]] || error "Geçersiz rol: ${role}. (admin|developer|viewer)"
```
After:
```bash
    [[ -z "$username" ]] && error "Kullanıcı adı belirtilmedi."
    _user_add_validate_gate "$username" || error "Geçersiz kullanıcı adı: ${username} (^[a-z_][a-z0-9_-]*$, en fazla 32)"
    [[ "$role" =~ ^(admin|developer|viewer)$ ]] || error "Geçersiz rol: ${role}. (admin|developer|viewer)"
```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_user_validate.sh` (all PASS).

- [ ] **Step 5: Commit**
```bash
git add lib/user.sh tests/test_user_validate.sh
git commit -m "$(cat <<'EOF'
güvenlik: _user_add'a validate_username kapısı (path traversal + sudoers enjeksiyonu reddi)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 16 — [T4.5] `cloudflare.sh` DNS-add JSON via `jq -n --arg`
**Files:** Modify `lib/cloudflare.sh:130-132` (`_cf_dns` add) / Test `tests/test_cf_json.sh`
**Interfaces:** Consumes: `jq` (already required by cloudflare.sh elsewhere) ; Produces: a standalone, testable builder `_cf_dns_add_body <type> <name> <content> <proxied>` that emits well-formed JSON with all string fields escaped (no string interpolation), reused by `_cf_dns`.

The DNS-add body is built by string interpolation: `"{\"type\":\"${type}\",\"name\":\"${name}\",\"content\":\"${content}\",\"proxied\":${proxied}}"`. A `content` containing `"` (e.g. a TXT record value with a quote, or attacker-influenced data) breaks the JSON / injects fields. We extract the body builder into a function that uses `jq -n --arg` for the three string fields and `--argjson` for the boolean, and unit-test it on macOS (jq present). `cmd_cloudflare` calls `require_root`/`_cf_check_token`, so the builder is tested directly.

- [ ] **Step 1: Write the failing test** — `tests/test_cf_json.sh`
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/cloudflare.sh"

# Normal kayıt: alanlar doğru yerleşir, geçerli JSON üretir.
body=$(_cf_dns_add_body "A" "www.example.com" "1.2.3.4" "true")
assert_eq "$(echo "$body" | jq -r '.type')"     "A"               "type alanı"
assert_eq "$(echo "$body" | jq -r '.name')"     "www.example.com" "name alanı"
assert_eq "$(echo "$body" | jq -r '.content')"  "1.2.3.4"         "content alanı"
assert_eq "$(echo "$body" | jq -r '.proxied')"  "true"            "proxied boolean"

# Çift tırnak içeren içerik JSON'u BOZMAMALI (enjeksiyon değil, kaçışlı string).
evil='v=spf1 "include:evil" -all'
body=$(_cf_dns_add_body "TXT" "example.com" "$evil" "false")
assert_ok   bash -c "echo '$body' | jq -e . >/dev/null"   "kötü içerikle bile geçerli JSON"
assert_eq "$(echo "$body" | jq -r '.content')" "$evil"    "content tam ve kaçışlı korundu"
assert_eq "$(echo "$body" | jq -r '.proxied')" "false"    "proxied false (TXT)"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_cf_json.sh` ; Expected: FAIL — `_cf_dns_add_body` does not exist, so all assertions fail.

- [ ] **Step 3: Implement** — Add the builder function above `_cf_dns` (before line 97 `_cf_dns() {`) and use it in the add branch.

Add function:
```bash
# DNS kayıt gövdesini güvenli kur: string alanlar jq -n --arg ile kaçışlanır,
# proxied boolean --argjson ile ham JSON olarak yerleşir. String enterpolasyonu YOK.
_cf_dns_add_body() {
    local type="$1" name="$2" content="$3" proxied="$4"
    jq -n --arg type "$type" --arg name "$name" --arg content "$content" \
        --argjson proxied "$proxied" \
        '{type: $type, name: $name, content: $content, proxied: $proxied}'
}
```

Change `_cf_dns` add branch (`lib/cloudflare.sh:130-132`):

Before:
```bash
            local result
            result=$(_cf_api POST "/zones/${zone_id}/dns_records" \
                "{\"type\":\"${type}\",\"name\":\"${name}\",\"content\":\"${content}\",\"proxied\":${proxied}}")
```
After:
```bash
            local result
            result=$(_cf_api POST "/zones/${zone_id}/dns_records" \
                "$(_cf_dns_add_body "$type" "$name" "$content" "$proxied")")
```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_cf_json.sh` (all PASS; `jq` is `/usr/bin/jq` 1.7 on the dev box).

- [ ] **Step 5: Commit**
```bash
git add lib/cloudflare.sh tests/test_cf_json.sh
git commit -m "$(cat <<'EOF'
güvenlik: cloudflare dns add gövdesini jq -n --arg ile kur (JSON enjeksiyonu reddi)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

### Task 17 — [T4.6] `load_config` validates `SSH_PORT` and `WEB_ROOT`
**Files:** Modify `lib/core.sh:49-61` (`load_config`) / Test `tests/test_load_config_validate.sh`
**Interfaces:** Consumes: `validate_uint` (Foundation/core.sh) ; Produces: a `load_config` that rejects a non-numeric/out-of-range `SSH_PORT` and a non-absolute `WEB_ROOT` from `srvctl.conf`. Note: `load_config` runs at `core.sh` source time and other tests rely on that succeeding with defaults — validation must only `error` on a *present-but-invalid* value, never on the applied defaults.

`SSH_PORT` flows into `sshd_config` (`Port ${SSH_PORT}`), `ufw allow ${SSH_PORT}/tcp`, and fail2ban; `WEB_ROOT` is the base of every per-domain path and a `rm -rf "${WEB_ROOT}/..."` prefix. A malformed `srvctl.conf` (operator-trusted but fat-fingered, or a partially-compromised conf) must fail closed at load. `load_config` is defined in `core.sh` (not `init.sh`, which only *uses* `SSH_PORT`/`WEB_ROOT`). Validation runs **after** defaults are applied, and `validate_uint`/the absolute-path check accept the defaults (`2222`, `/var/www`), so sourcing `core.sh` in every existing test still succeeds.

Test strategy: re-running `load_config` with a bad value set in the environment exercises the validation. Because `error` exits, we drive it in a subshell via `bash -c` so the test process survives (the harness's `assert_fail` runs in the current shell, so we wrap the exiting call in `bash -c` to capture its non-zero exit without killing the suite).

- [ ] **Step 1: Write the failing test** — `tests/test_load_config_validate.sh`
```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# Yardımcı: temiz bir alt-kabukta core.sh'ı kaynak gösterip load_config'i
# verilen env ile yeniden çağırır. error/exit alt-kabukta kalır.
run_load() {
    # $1=SSH_PORT $2=WEB_ROOT
    SSH_PORT="$1" WEB_ROOT="$2" bash -c '
        source "'"${REPO_ROOT}"'/lib/core.sh"   # kaynakta bir kez load_config (defaultlar ok)
        load_config                              # env değerleriyle tekrar doğrula
    ' >/dev/null 2>&1
}

# Geçerli değerler: başarılı
assert_ok   run_load "2222" "/var/www"
assert_ok   run_load "443"  "/srv/web"

# Geçersiz SSH_PORT: sayı değil / aralık dışı
assert_fail run_load "22; reboot" "/var/www"
assert_fail run_load "abc"        "/var/www"
assert_fail run_load "70000"      "/var/www"

# Geçersiz WEB_ROOT: mutlak yol değil
assert_fail run_load "2222" "relative/path"
assert_fail run_load "2222" "../etc"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL** — Run: `bash tests/test_load_config_validate.sh` ; Expected: FAIL — `load_config` does not validate yet, so the `assert_fail` lines FAIL (the bad values are accepted and `run_load` returns 0). The `assert_ok` lines pass.

- [ ] **Step 3: Implement** — Edit `load_config` in `lib/core.sh`.

Before (`lib/core.sh:54-61`):
```bash
    # Varsayılanlar
    DEFAULT_PHP_VERSION="${DEFAULT_PHP_VERSION:-8.3}"
    SSH_PORT="${SSH_PORT:-2222}"
    WEB_ROOT="${WEB_ROOT:-/var/www}"
    BACKUP_DIR="${BACKUP_DIR:-/backups}"
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
    DEPLOYER_USER="${DEPLOYER_USER:-deployer}"
}
```
After:
```bash
    # Varsayılanlar
    DEFAULT_PHP_VERSION="${DEFAULT_PHP_VERSION:-8.3}"
    SSH_PORT="${SSH_PORT:-2222}"
    WEB_ROOT="${WEB_ROOT:-/var/www}"
    BACKUP_DIR="${BACKUP_DIR:-/backups}"
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
    DEPLOYER_USER="${DEPLOYER_USER:-deployer}"

    # Doğrulama (sshd/ufw/fail2ban ve tüm domain yollarının kaynağı — fail-closed).
    # validate_uint Foundation'da tanımlı; tanımlı değilse (kaynak sırası) atla.
    if declare -F validate_uint >/dev/null 2>&1; then
        validate_uint "$SSH_PORT" 65535 || error "Geçersiz SSH_PORT: ${SSH_PORT} (1-65535 arası tam sayı)"
    fi
    [[ "$WEB_ROOT" == /* ]] || error "Geçersiz WEB_ROOT: ${WEB_ROOT} (mutlak yol olmalı)"
}
```

Note for the implementing agent: `validate_uint` is added in the Foundation group earlier in `core.sh` (before `load_config`'s call site at source time), so the `declare -F` guard is belt-and-suspenders for the transition window where this T4 commit could land before Foundation; once Foundation is merged the guard is always true. The `WEB_ROOT` absolute-path check has no external dependency and is always active.

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/test_load_config_validate.sh` (all PASS). Regression: `bash tests/run.sh` — every existing test sources `core.sh` (which runs `load_config` with defaults `2222` / an absolute `WEB_ROOT` from `mktemp -d`), so none break.

- [ ] **Step 5: Commit**
```bash
git add lib/core.sh tests/test_load_config_validate.sh
git commit -m "$(cat <<'EOF'
güvenlik: load_config SSH_PORT (validate_uint) ve WEB_ROOT (mutlak yol) doğrulaması

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

Key source facts the implementing agent must keep in mind (verified against the tree):
- All validators (`validate_domain`, `assert_regex_safe`, `validate_ip_or_cidr`, `validate_country`, `validate_uint`, `validate_username`) and `DEFAULT_SENSITIVE_PATHS` are produced by the Foundation/T2 group; T4 only consumes them. `DEFAULT_SENSITIVE_PATHS` already exists at `lib/core.sh:160`.
- `load_config` lives in `lib/core.sh:49`, **not** `lib/init.sh` (init.sh only references `SSH_PORT`/`WEB_ROOT`). The spec's "init.sh load_config" wording maps to `core.sh`.
- The nginx token is `{{RL_SENSITIVE_PATHS}}` (`templates/nginx/vhost.conf.tpl:77`, `vhost-ssl.conf.tpl:86`), fed by the `RL_SENSITIVE_PATHS=${sensitive}` arg in `_domain_write_vhost` (`lib/domain.sh:74`).
- `jq` is available on the dev box (`/usr/bin/jq`, 1.7.1) so `tests/test_cf_json.sh` runs on macOS.
- `tests/run.sh` auto-discovers `tests/test_*.sh`; no registration step is needed — new test files are picked up automatically.

---

### Task 18 — [T5.1] `_webhook_verify_sig` HMAC doğrulamasını dosya-kapsamlı, root-gerektirmeyen, test edilebilir fonksiyona çıkar

**Files:**
- Modify: `lib/webhook.sh` — yeni dosya-kapsamlı fonksiyon ekle (mevcut `WEBHOOK_LOG="..."` satırı `lib/webhook.sh:13` ile `cmd_webhook()` `lib/webhook.sh:15` arasına). `cmd_webhook` `require_root` çağrısı `lib/webhook.sh:16`'da olduğundan, fonksiyon dosya kapsamında tanımlanır; sadece `source` etmek root tetiklemez.
- Test: `tests/test_webhook_sig.sh` (yeni; `tests/run.sh` `lib/webhook.sh:13`–benzeri otomatik keşif yapar, kayıt gerekmez).

**Interfaces:**
- Consumes: yok (T5 bağımsız başlar; sadece `lib/core.sh` source'lanır ama bu fonksiyon core'a bağımlı değildir).
- Produces: `_webhook_verify_sig <secret> <payload> <header_value>` → header **var ve boş değil ve** `'sha256='+HMAC-SHA256(secret,payload)`'a eşitse `return 0`; aksi halde (eksik/boş header, boş secret, yanlış imza) `return 1`. Sabit-zamanlı karşılaştırma. Çıkış (exit) yapmaz, çıktı üretmez. T5.2 (request handler) ve listener heredoc'u bu sözleşmeyi tüketir.

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/test_webhook_sig.sh << 'EOF'
#!/bin/bash
# T5.1 — _webhook_verify_sig birim testleri (root/socat/nginx gerektirmez)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
# lib/webhook.sh source'lanır: cmd_webhook require_root içerir ama yalnızca
# çağrıldığında çalışır; source sadece fonksiyonları tanımlar (root tetiklenmez).
source "${REPO_ROOT}/lib/webhook.sh"

# Sabit secret + payload; beklenen imzayı openssl ile hesapla
SECRET="testsecret123"
PAYLOAD='{"ref":"refs/heads/main"}'
GOOD_HMAC="$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')"
GOOD_HEADER="sha256=${GOOD_HMAC}"

echo "── _webhook_verify_sig ──"

# Doğru imza → 0
assert_ok   _webhook_verify_sig "$SECRET" "$PAYLOAD" "$GOOD_HEADER"

# Yanlış imza → 1
assert_fail _webhook_verify_sig "$SECRET" "$PAYLOAD" "sha256=deadbeef"

# Eksik/boş header → 1
assert_fail _webhook_verify_sig "$SECRET" "$PAYLOAD" ""

# Boş secret → 1 (secret yoksa fail-closed)
assert_fail _webhook_verify_sig "" "$PAYLOAD" "$GOOD_HEADER"

# 'sha256=' prefix'i olmayan ama doğru ham hash → 1 (prefix zorunlu)
assert_fail _webhook_verify_sig "$SECRET" "$PAYLOAD" "$GOOD_HMAC"

# Doğru imza ama farklı payload → 1
assert_fail _webhook_verify_sig "$SECRET" '{"ref":"refs/heads/dev"}' "$GOOD_HEADER"

rm -rf "$WEB_ROOT"
test_summary
EOF
chmod +x tests/test_webhook_sig.sh
```

- [ ] **Step 2: Run it, verify FAIL**

Run: `bash tests/test_webhook_sig.sh`
Expected: FAIL — `_webhook_verify_sig` henüz tanımlı olmadığı için `assert_ok` satırı "komut başarısız olmamalıydı" verir (komut bulunamaz, exit non-0). Özet `Başarısız: 1` (en az `assert_ok` satırı; `assert_fail` satırları tanımsız komut için zaten non-0 döndüğünden yanlışlıkla PASS verebilir, ama `assert_ok` kesin FAIL'dir). Test dosyası bütünüyle başarısız sayılır.

- [ ] **Step 3: Implement**

`lib/webhook.sh:11`–`lib/webhook.sh:13` mevcut hali:

```bash
WEBHOOK_PORT="${WEBHOOK_PORT:-9443}"
WEBHOOK_PID_FILE="/var/run/srvctl-webhook.pid"
WEBHOOK_LOG="/usr/local/srvctl/logs/webhook.log"
```

Bu bloğun hemen ardına (yani `cmd_webhook() {` `lib/webhook.sh:15`'in önüne) dosya-kapsamlı fonksiyonu ekle:

```bash
WEBHOOK_PORT="${WEBHOOK_PORT:-9443}"
WEBHOOK_PID_FILE="/var/run/srvctl-webhook.pid"
WEBHOOK_LOG="/usr/local/srvctl/logs/webhook.log"
# Listener yalnızca 127.0.0.1'e bağlanır (nginx arkasında); 9443 dışa açılmaz.
WEBHOOK_BIND="${WEBHOOK_BIND:-127.0.0.1}"

# _webhook_verify_sig <secret> <payload> <header_value>
# GitHub X-Hub-Signature-256 doğrulaması (fail-closed).
# 0 döner ANCAK header dolu VE 'sha256='+HMAC-SHA256(secret,payload)'a eşitse.
# Eksik/boş header, boş secret veya yanlış imza → 1. Çıkış/çıktı yapmaz.
_webhook_verify_sig() {
    local secret="$1" payload="$2" header="$3"
    # Secret yoksa veya header boşsa fail-closed
    [[ -z "$secret" ]] && return 1
    [[ -z "$header" ]] && return 1

    local expected
    expected="sha256=$(printf '%s' "$payload" \
        | openssl dgst -sha256 -hmac "$secret" 2>/dev/null \
        | awk '{print $NF}')"
    # Hesaplama başarısız olduysa (boş hash) reddet
    [[ "$expected" == "sha256=" ]] && return 1

    # Sabit-zamanlı karşılaştırma: her iki dizgenin SHA-256'sını al,
    # böylece uzunluk farkı ve byte-byte erken-çıkış sızıntısı olmaz.
    local h_recv h_exp
    h_recv="$(printf '%s' "$header"   | openssl dgst -sha256 | awk '{print $NF}')"
    h_exp="$(printf '%s' "$expected"  | openssl dgst -sha256 | awk '{print $NF}')"
    [[ "$h_recv" == "$h_exp" ]] && return 0
    return 1
}

cmd_webhook() {
```

- [ ] **Step 4: Run, verify PASS**

Run: `bash tests/test_webhook_sig.sh`
Expected: Tüm assert'ler PASS, `Toplam: 6, Başarısız: 0`.

- [ ] **Step 5: Commit**

```bash
git add lib/webhook.sh tests/test_webhook_sig.sh
git commit -m "$(cat <<'MSG'
feat(webhook): _webhook_verify_sig fail-closed HMAC doğrulaması + birim test

X-Hub-Signature-256 doğrulamasını dosya-kapsamlı, root-gerektirmeyen,
test edilebilir fonksiyona çıkardı. Eksik/boş header, boş secret veya
yanlış imza artık 1 döner (fail-closed). Sabit-zamanlı karşılaştırma.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

---

### Task 19 — [T5.2] Request handler'ı fail-closed yap: `WEBHOOK_SECRET` zorunlu + imza başarısızsa 403

**Files:**
- Modify: `lib/webhook.sh` — embedded listener heredoc'u (`cat > /usr/local/srvctl/lib/webhook-listener.sh << 'LISTENER'`, `lib/webhook.sh:114`–`lib/webhook.sh:211`). Düzeltilecek bölge: imza doğrulama bloğu `lib/webhook.sh:156`–`lib/webhook.sh:167` (`handle_request` içinde, `source "$conf"` `lib/webhook.sh:154`'ten sonra).
- Test: `tests/test_webhook_sig.sh` (T5.1) — handler mantığının çekirdeği olan `_webhook_verify_sig` zaten test edilir. Listener heredoc'u `lib/webhook.sh`'i source'lamaz (kendi `core.sh`'ini source'lar), bu yüzden imza fonksiyonu **heredoc içine de** aynen kopyalanır; bu kopyanın T5.1 sözleşmesiyle birebir aynı olduğunu doğrulamak için `tests/test_webhook_listener_sig.sh` (yeni) heredoc'u diske yazıp fonksiyonu oradan source ederek test eder.

**Interfaces:**
- Consumes: `_webhook_verify_sig` (T5.1 sözleşmesi).
- Produces: `handle_request` davranışı — `WEBHOOK_SECRET` boş/tanımsızsa veya imza geçersizse `HTTP/1.1 403 Forbidden`, deploy tetiklenmez. Geçerli imza + doğru branch → 200 + asenkron deploy. Sonraki task (T5.3) bind adresini değiştirir, bu handler'ı tüketmez.

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/test_webhook_listener_sig.sh << 'EOF'
#!/bin/bash
# T5.2 — webhook-listener.sh heredoc'una gömülü imza fonksiyonu, dosya-kapsamlı
# _webhook_verify_sig ile birebir aynı fail-closed davranışı göstermeli.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"

# webhook.sh içindeki listener heredoc'unu diske çıkar (LISTENER ... LISTENER arası).
LISTENER_OUT="${WEB_ROOT}/webhook-listener.sh"
awk '/<< .LISTENER.$/{f=1;next} /^LISTENER$/{f=0} f' \
    "${REPO_ROOT}/lib/webhook.sh" > "$LISTENER_OUT"

# Heredoc gerçek socat/core.sh gerektirmeden _webhook_verify_sig tanımını
# içermeli. Tanımı izole edip source et (socat ana döngüsünü çalıştırmadan).
assert_contains "$(cat "$LISTENER_OUT")" "_webhook_verify_sig()" \
    "listener heredoc'u _webhook_verify_sig tanımını içermeli"

# Fonksiyon tanımını ayıkla ve source et (yan etki yok, sadece tanım)
SIG_FN="${WEB_ROOT}/sig_fn.sh"
awk '/^_webhook_verify_sig\(\) \{/{f=1} f{print} /^\}/{if(f)exit}' \
    "$LISTENER_OUT" > "$SIG_FN"
# shellcheck disable=SC1090
source "$SIG_FN"

SECRET="testsecret123"
PAYLOAD='{"ref":"refs/heads/main"}'
GOOD="sha256=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')"

echo "── listener gömülü imza fonksiyonu ──"
assert_ok   _webhook_verify_sig "$SECRET" "$PAYLOAD" "$GOOD"
assert_fail _webhook_verify_sig "$SECRET" "$PAYLOAD" "sha256=bad"
assert_fail _webhook_verify_sig "$SECRET" "$PAYLOAD" ""
assert_fail _webhook_verify_sig ""       "$PAYLOAD" "$GOOD"

# Handler'ın WEBHOOK_SECRET zorunluluğu: heredoc gövdesi boş-secret
# kontrolünü ve 403 yolunu içermeli (statik assert).
BODY="$(cat "$LISTENER_OUT")"
assert_contains "$BODY" "403 Forbidden" "handler 403 yolu içermeli"
assert_contains "$BODY" '_webhook_verify_sig "${WEBHOOK_SECRET' \
    "handler imza doğrulamasını _webhook_verify_sig ile yapmalı"
assert_not_contains "$BODY" 'if [[ -n "$hub_sig" && -n "${WEBHOOK_SECRET}" ]]' \
    "eski fail-open koşulu (header boşsa atla) kalmamalı"

rm -rf "$WEB_ROOT"
test_summary
EOF
chmod +x tests/test_webhook_listener_sig.sh
```

- [ ] **Step 2: Run it, verify FAIL**

Run: `bash tests/test_webhook_listener_sig.sh`
Expected: FAIL — mevcut heredoc'ta `_webhook_verify_sig()` tanımı yok (`assert_contains` FAIL), eski `if [[ -n "$hub_sig" && -n "${WEBHOOK_SECRET}" ]]` koşulu hâlâ var (`assert_not_contains` FAIL), ve `_webhook_verify_sig` source edilemediğinden `assert_ok` FAIL. Özet `Başarısız >= 3`.

- [ ] **Step 3: Implement**

Embedded listener heredoc'una imza fonksiyonunu ekle. `lib/webhook.sh:119`–`lib/webhook.sh:123` mevcut hali (heredoc başı):

```bash
SRVCTL_ROOT="/usr/local/srvctl"
WEBHOOK_PORT="${WEBHOOK_PORT:-9443}"

source "${SRVCTL_ROOT}/conf/srvctl.conf"
source "${SRVCTL_ROOT}/lib/core.sh"

handle_request() {
```

Şununla değiştir (fonksiyonu `handle_request`'ten önce ekle; listener `webhook.sh`'i source etmediği için kopya zorunlu, T5.1 ile birebir aynı gövde):

```bash
SRVCTL_ROOT="/usr/local/srvctl"
WEBHOOK_PORT="${WEBHOOK_PORT:-9443}"

source "${SRVCTL_ROOT}/conf/srvctl.conf"
source "${SRVCTL_ROOT}/lib/core.sh"

# _webhook_verify_sig <secret> <payload> <header_value>  (T5.1 ile birebir aynı)
# GitHub X-Hub-Signature-256 doğrulaması (fail-closed). lib/webhook.sh source
# edilmediği için kopya zorunlu; sözleşme tests/test_webhook_listener_sig.sh ile kilitli.
_webhook_verify_sig() {
    local secret="$1" payload="$2" header="$3"
    [[ -z "$secret" ]] && return 1
    [[ -z "$header" ]] && return 1
    local expected
    expected="sha256=$(printf '%s' "$payload" \
        | openssl dgst -sha256 -hmac "$secret" 2>/dev/null \
        | awk '{print $NF}')"
    [[ "$expected" == "sha256=" ]] && return 1
    local h_recv h_exp
    h_recv="$(printf '%s' "$header"  | openssl dgst -sha256 | awk '{print $NF}')"
    h_exp="$(printf '%s' "$expected" | openssl dgst -sha256 | awk '{print $NF}')"
    [[ "$h_recv" == "$h_exp" ]] && return 0
    return 1
}

handle_request() {
```

Ardından imza doğrulama bloğunu fail-closed yap. `lib/webhook.sh:153`–`lib/webhook.sh:167` mevcut hali:

```bash
        if [[ -f "$conf" ]]; then
            source "$conf"

            # Signature doğrulama (GitHub)
            local hub_sig
            hub_sig=$(echo -e "$request" | grep -i "X-Hub-Signature-256" | awk '{print $2}' | tr -d '\r')
            if [[ -n "$hub_sig" && -n "${WEBHOOK_SECRET}" ]]; then
                local expected
                expected="sha256=$(echo -n "$body" | openssl dgst -sha256 -hmac "${WEBHOOK_SECRET}" | awk '{print $2}')"
                if [[ "$hub_sig" != "$expected" ]]; then
                    echo -e "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nInvalid signature"
                    log_action "WEBHOOK REJECTED: ${sname} (invalid signature)"
                    return
                fi
            fi
```

Şununla değiştir (secret zorunlu + her zaman doğrula; header eksik/boş veya secret boş → 403):

```bash
        if [[ -f "$conf" ]]; then
            source "$conf"

            # WEBHOOK_SECRET zorunlu — yoksa fail-closed (servis etme)
            if [[ -z "${WEBHOOK_SECRET:-}" ]]; then
                echo -e "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nWebhook secret tanımsız"
                log_action "WEBHOOK REJECTED: ${sname} (secret tanımsız)"
                return
            fi

            # Signature doğrulama (GitHub) — fail-closed: header HER ZAMAN gerekli
            local hub_sig
            hub_sig=$(echo -e "$request" | grep -i "X-Hub-Signature-256" | awk '{print $2}' | tr -d '\r')
            if ! _webhook_verify_sig "${WEBHOOK_SECRET}" "$body" "$hub_sig"; then
                echo -e "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nImza geçersiz"
                log_action "WEBHOOK REJECTED: ${sname} (imza geçersiz/eksik)"
                return
            fi
```

- [ ] **Step 4: Run, verify PASS**

Run: `bash tests/test_webhook_listener_sig.sh && bash tests/test_webhook_sig.sh`
Expected: İki dosya da PASS. Listener testi: `Başarısız: 0` (heredoc'ta `_webhook_verify_sig()` var, `403 Forbidden` var, eski fail-open koşulu yok). T5.1 testi hâlâ `Başarısız: 0`.

- [ ] **Step 5: Commit**

```bash
git add lib/webhook.sh tests/test_webhook_listener_sig.sh
git commit -m "$(cat <<'MSG'
fix(webhook): handler fail-closed — WEBHOOK_SECRET zorunlu + imza eksikse 403

Eski "header boşsa imzayı atla" fail-open mantığı kaldırıldı. Listener artık
WEBHOOK_SECRET tanımsızsa servis etmiyor ve X-Hub-Signature-256 her istekte
_webhook_verify_sig ile doğrulanıyor; eksik/yanlış imza 403 dönüyor.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

---

### Task 20 — [T5.3] Listener'ı `127.0.0.1`'e bağla, setup'ta `WEBHOOK_SECRET` zorunlu kıl, UFW'de 9443'ü dışa açma

**Files:**
- Modify: `lib/webhook.sh`:
  - socat bind satırı `lib/webhook.sh:205` (heredoc içi): `TCP-LISTEN:${WEBHOOK_PORT}` → `TCP-LISTEN:${WEBHOOK_PORT},bind=127.0.0.1`.
  - UFW açma satırı `lib/webhook.sh:215`: `ufw allow ...` kaldır (port artık sadece localhost; nginx reverse-proxy önde).
  - `_webhook_setup` `lib/webhook.sh:38`–`lib/webhook.sh:74`: üretilen `WEBHOOK_SECRET`'in boş olmadığını doğrula (fail-closed) ve config'i `secure_file`/`umask` ile yaz.
  - URL çıktıları `lib/webhook.sh:61`/`lib/webhook.sh:67`: artık localhost arkasında olduğunu yansıt (nginx vhost'a yönlendir notu).
- Test: `tests/test_webhook_bind.sh` (yeni) — heredoc'ta `bind=127.0.0.1` olduğunu ve `ufw allow ...webhook` satırının kalmadığını statik assert eder.

**Interfaces:**
- Consumes: T5.2 handler (değişmez), `secure_file` (`lib/core.sh`, mevcut/eş-zamanlı T6 primitifi; yoksa `umask 077`+`chmod 600` fallback).
- Produces: yok (akış sonu; davranışsal sözleşme: listener yalnızca `127.0.0.1:${WEBHOOK_PORT}` dinler, UFW kuralı yok).

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/test_webhook_bind.sh << 'EOF'
#!/bin/bash
# T5.3 — listener 127.0.0.1'e bağlanmalı, 9443 UFW'de dışa açılmamalı,
# setup boş secret üretmemeli (statik/birim assert'ler; root/socat gerekmez).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"

SRC="$(cat "${REPO_ROOT}/lib/webhook.sh")"

echo "── webhook bind & UFW sertleştirme ──"

# socat TCP-LISTEN 127.0.0.1'e bind olmalı
assert_contains "$SRC" "TCP-LISTEN:\${WEBHOOK_PORT},bind=127.0.0.1" \
    "socat listener 127.0.0.1'e bind olmalı"

# 9443 artık UFW'de dışa açılmamalı (eski 'ufw allow ...webhook' kaldırıldı)
assert_not_contains "$SRC" 'ufw allow "${WEBHOOK_PORT}/tcp"' \
    "webhook portu UFW'de dışa açılmamalı"

# setup secret üretimini doğrulamalı: 'generate_password 32' sonrası boşluk kontrolü
assert_contains "$SRC" "Webhook secret üretilemedi" \
    "setup boş secret'i fail-closed reddetmeli"

rm -rf "$WEB_ROOT"
test_summary
EOF
chmod +x tests/test_webhook_bind.sh
```

- [ ] **Step 2: Run it, verify FAIL**

Run: `bash tests/test_webhook_bind.sh`
Expected: FAIL — mevcut `lib/webhook.sh:205` `bind=127.0.0.1` içermez, `lib/webhook.sh:215` `ufw allow "${WEBHOOK_PORT}/tcp"` hâlâ var, ve "Webhook secret üretilemedi" mesajı yok. Üç assert de FAIL.

- [ ] **Step 3: Implement**

(a) socat bind — `lib/webhook.sh:205` mevcut:

```bash
socat TCP-LISTEN:${WEBHOOK_PORT},reuseaddr,fork SYSTEM:"/usr/local/srvctl/lib/webhook-listener.sh handle"
```

değiştir:

```bash
# Yalnızca localhost'a bind — nginx reverse-proxy önde; port dışa açılmaz.
socat TCP-LISTEN:${WEBHOOK_PORT},bind=127.0.0.1,reuseaddr,fork SYSTEM:"/usr/local/srvctl/lib/webhook-listener.sh handle"
```

(b) UFW satırını kaldır — `lib/webhook.sh:214`–`lib/webhook.sh:215` mevcut:

```bash
    # UFW'de port aç
    ufw allow "${WEBHOOK_PORT}/tcp" comment "srvctl-webhook" > /dev/null 2>&1
```

değiştir:

```bash
    # Port yalnızca 127.0.0.1'e bind; dışa UFW kuralı AÇILMAZ.
    # Dışarıdan erişim nginx reverse-proxy (TLS) üzerinden olmalı.
```

(c) setup'ta secret zorunlu + güvenli yazım — `lib/webhook.sh:43`–`lib/webhook.sh:58` mevcut:

```bash
    local sname
    sname=$(safe_name "$domain")
    local secret
    secret=$(generate_password 32)

    # Webhook config dosyası
    mkdir -p /etc/srvctl/webhooks
    cat > "/etc/srvctl/webhooks/${sname}.conf" << WHCONF
WEBHOOK_DOMAIN=${domain}
WEBHOOK_SECRET=${secret}
WEBHOOK_BRANCH=main
WEBHOOK_AUTO_DEPLOY=true
WEBHOOK_HEALTH_CHECK=true
WEBHOOK_NOTIFY=true
WHCONF
    chmod 600 "/etc/srvctl/webhooks/${sname}.conf"
```

değiştir:

```bash
    local sname
    sname=$(safe_name "$domain")
    local secret
    secret=$(generate_password 32)
    # Fail-closed: boş secret ile webhook yapılandırma (imza doğrulama anlamsız olur)
    [[ -z "$secret" ]] && error "Webhook secret üretilemedi."

    # Webhook config dosyası (umask 077 ile dünya-okunur sızıntısı önlenir)
    mkdir -p /etc/srvctl/webhooks
    chmod 700 /etc/srvctl/webhooks
    local conf="/etc/srvctl/webhooks/${sname}.conf"
    ( umask 077; : > "$conf" )
    cat > "$conf" << WHCONF
WEBHOOK_DOMAIN=${domain}
WEBHOOK_SECRET=${secret}
WEBHOOK_BRANCH=main
WEBHOOK_AUTO_DEPLOY=true
WEBHOOK_HEALTH_CHECK=true
WEBHOOK_NOTIFY=true
WHCONF
    chmod 600 "$conf"
```

(d) URL çıktısı notu — `lib/webhook.sh:60`–`lib/webhook.sh:71` arasındaki `header`/`echo` bloğunda, GitHub URL satırlarına localhost notu ekle. `lib/webhook.sh:61` mevcut:

```bash
    echo "  URL:      https://SUNUCU_IP:${WEBHOOK_PORT}/deploy/${sname}"
```

değiştir (port artık localhost; dış URL nginx vhost path'i üzerinden):

```bash
    echo "  Dahili:   http://127.0.0.1:${WEBHOOK_PORT}/deploy/${sname}"
    echo "  Genel:    https://${domain}/__srvctl_webhook/${sname}  (nginx reverse-proxy ile)"
```

ve `lib/webhook.sh:67` mevcut:

```bash
    echo "    Payload URL:  https://SUNUCU_IP:${WEBHOOK_PORT}/deploy/${sname}"
```

değiştir:

```bash
    echo "    Payload URL:  https://${domain}/__srvctl_webhook/${sname}"
```

- [ ] **Step 4: Run, verify PASS**

Run: `bash tests/test_webhook_bind.sh && bash tests/run.sh`
Expected: `tests/test_webhook_bind.sh` → `Başarısız: 0`. `tests/run.sh` → tüm dosyalar geçer (`TÜM TEST DOSYALARI GEÇTİ`), yeni `test_webhook_sig.sh` / `test_webhook_listener_sig.sh` / `test_webhook_bind.sh` dahil; mevcut `test_meta.sh` vb. etkilenmez (bu task `lib/webhook.sh` dışına dokunmaz).

- [ ] **Step 5: Commit**

```bash
git add lib/webhook.sh tests/test_webhook_bind.sh
git commit -m "$(cat <<'MSG'
fix(webhook): listener'ı 127.0.0.1'e bağla, 9443'ü dışa açma, setup'ta secret zorunlu

socat artık bind=127.0.0.1; UFW'de webhook portu açılmıyor (erişim nginx
reverse-proxy/TLS üzerinden). setup boş secret'i reddediyor ve config'i
umask 077 ile yazıyor. Uzaktan erişilebilir fail-open yüzeyi kapatıldı.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

**Group notes (load-bearing facts for the executor):**
- `lib/webhook.sh:16` `require_root` yalnızca `cmd_webhook` çalıştırıldığında tetiklenir; dosyayı `source` etmek sadece fonksiyon tanımlar — bu yüzden T5.1 testi `lib/webhook.sh`'i güvenle source eder.
- İmza doğrulama mantığı **iki yerde** yaşar: (1) `lib/webhook.sh` dosya kapsamı (T5.1, birim test edilebilir), (2) `lib/webhook.sh:114`–`lib/webhook.sh:211` arasındaki single-quoted `<< 'LISTENER'` heredoc'una yazılan kopya (T5.2). Listener `webhook.sh`'i source etmediği (yalnızca `core.sh`'i source eder, `lib/webhook.sh:123`) için kopya zorunludur; iki kopyanın birebir aynı kaldığını `tests/test_webhook_listener_sig.sh` kilitler.
- Mevcut buggy imza hesaplaması `awk '{print $2}'` kullanıyor (`lib/webhook.sh:161`); yeni fonksiyon `awk '{print $NF}'` kullanır — bazı openssl sürümlerinde çıktı `HMAC-SHA256(stdin)= <hash>` biçiminde olduğundan `$NF` daha sağlamdır ve test bunu `openssl dgst ... | awk '{print $NF}'` ile tutarlı hesaplar.

---

### Task 21 — [T6.1] Secret yazan yollara umask 077 uygula (.credentials, /root/.my.cnf, redis acl)

**Files:**
- Modify: `lib/domain.sh:400-419` (`.credentials` heredoc), `lib/init.sh:406-411` (`/root/.my.cnf`), `lib/init.sh:461-471` (`/etc/redis/users.acl`)
- Test: `tests/test_secret_umask.sh`

**Interfaces:** Consumes: `secure_file` (Foundation) ; Produces: nothing later tasks depend on (call-site hardening only).

**macOS-unit-testable?** PARTIAL. The `.credentials` write is exercisable by extracting the secret-write into a pure helper `_domain_write_credentials` that runs under `umask 077` + `secure_file`; that helper IS macOS-unit-testable (mode contract). The `/root/.my.cnf` and redis-acl edits live inside `_install_mariadb`/`_install_redis` which require a real Ubuntu host (mysql/redis) — those are INTEGRATION-ONLY, but the exact edit is shown and is a trivial `umask`/`secure_file` wrap.

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# domain.sh'i source et — _domain_write_credentials saf yardımcısı için.
# (cmd_domain require_root çağırır ama biz sadece yardımcıyı çağırıyoruz.)
source "${REPO_ROOT}/lib/domain.sh"

# Helper var mı?
assert_ok declare -F _domain_write_credentials

# Bir domain dizini hazırla
dom="ornek.com"
base="${WEB_ROOT}/${dom}"
mkdir -p "$base"

# Sırrı yaz
_domain_write_credentials "$dom" "$base" "web_ornek_com" "8.3" \
    "db_ornek_com" "usr_ornek_com" "SecretDbPass123" \
    "redis_ornek_com" "SecretRedisPass456" "ornek_com:"

# Dosya 0600 olmalı (sahiplik macOS'ta root olamaz, mod test edilir)
mode="$(_stat_mode "${base}/.credentials")"
assert_eq "$mode" "600" ".credentials modu 0600"

# İçerik düz KEY=value, parolalar yazıldı
content="$(cat "${base}/.credentials")"
assert_contains "$content" "DB_PASS=SecretDbPass123" "DB_PASS yazıldı"
assert_contains "$content" "REDIS_PASS=SecretRedisPass456" "REDIS_PASS yazıldı"
assert_contains "$content" "DOMAIN=ornek.com" "DOMAIN yazıldı"
assert_contains "$content" "REDIS_PREFIX=ornek_com:" "REDIS_PREFIX yazıldı"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL**
  Run: `bash tests/test_secret_umask.sh`
  Expected: FAIL — `_domain_write_credentials` tanımlı değil (`declare -F` başarısız) ve dosya hiç yazılmaz.

- [ ] **Step 3: Implement**

3a. Add the pure helper `_domain_write_credentials` to `lib/domain.sh`. Place it just before `_domain_add` (top of the file's function section, after the `cmd_domain` block). It wraps the secret write in `umask 077` + `secure_file`:

```bash
# Per-domain .credentials dosyasını güvenli yaz (umask 077 + 0600 root:root).
# Saf yardımcı: mysql/redis/nginx gerektirmez — macOS'ta unit-test edilebilir.
# Argümanlar: domain base web_user php_ver db_name db_user db_pass redis_user redis_pass redis_prefix
_domain_write_credentials() {
    local domain="$1" base="$2" web_user="$3" php_version="$4"
    local db_name="$5" db_user="$6" db_pass="$7"
    local redis_user="$8" redis_pass="$9" redis_prefix="${10}"
    local creds_file="${base}/.credentials"

    # Sır yazımı boyunca dünya/grup erişimini kapat
    (
        umask 077
        cat > "$creds_file" << CREDS
# ═══════════════════════════════════════════════
#  srvctl credentials — ${domain}
#  Oluşturulma: $(date '+%Y-%m-%d %H:%M:%S')
#  DİKKAT: Bu dosyayı güvenli bir yere yedekleyin!
# ═══════════════════════════════════════════════
DOMAIN=${domain}
SAFE_NAME=$(safe_name "$domain")
WEB_USER=${web_user}
PHP_VERSION=${php_version}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASS=${db_pass}
REDIS_USER=${redis_user}
REDIS_PASS=${redis_pass}
REDIS_PREFIX=${redis_prefix}
CREDS
    )
    # Mod/sahiplik invariantını kesinleştir (chown macOS'ta sessizce geçer)
    secure_file "$creds_file" 600
}
```

3b. Replace the inline `.credentials` block in `_domain_add` (`lib/domain.sh:400-419`).

BEFORE (`lib/domain.sh:400-419`):
```bash
    # ─── Credentials Dosyası ───
    cat > "${base}/.credentials" << CREDS
# ═══════════════════════════════════════════════
#  srvctl credentials — ${domain}
#  Oluşturulma: $(date '+%Y-%m-%d %H:%M:%S')
#  DİKKAT: Bu dosyayı güvenli bir yere yedekleyin!
# ═══════════════════════════════════════════════
DOMAIN=${domain}
SAFE_NAME=${sname}
WEB_USER=${web_user}
PHP_VERSION=${php_version}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASS=${db_pass}
REDIS_USER=${redis_user}
REDIS_PASS=${redis_pass}
REDIS_PREFIX=${sname}:
CREDS
    chmod 600 "${base}/.credentials"
    chown root:root "${base}/.credentials"
```

AFTER:
```bash
    # ─── Credentials Dosyası (umask 077 + 0600 root:root) ───
    _domain_write_credentials "$domain" "$base" "$web_user" "$php_version" \
        "$db_name" "$db_user" "$db_pass" \
        "$redis_user" "$redis_pass" "${sname}:"
```

3c. INTEGRATION-ONLY edit — `/root/.my.cnf` in `_install_mariadb` (`lib/init.sh:406-411`).

BEFORE (`lib/init.sh:406-411`):
```bash
    # Root credentials dosyası
    cat > /root/.my.cnf << MYCNF
[client]
user=root
password=${root_pass}
MYCNF
    chmod 600 /root/.my.cnf
```

AFTER:
```bash
    # Root credentials dosyası (umask 077 + 0600 root:root)
    (
        umask 077
        cat > /root/.my.cnf << MYCNF
[client]
user=root
password=${root_pass}
MYCNF
    )
    secure_file /root/.my.cnf 600
```

3d. INTEGRATION-ONLY edit — redis ACL in `_install_redis` (`lib/init.sh:461-471`). Wrap the ACL heredoc in `umask 077` and tighten the mode from 0640 to 0600 for the secret-bearing `users.acl` (the non-secret `redis.conf` stays 0640). `chown redis:redis` must remain so the daemon can read it.

BEFORE (`lib/init.sh:461-471`):
```bash
    # ACL dosyası
    cat > /etc/redis/users.acl << REDISACL
# srvctl Redis ACL
# Admin kullanıcısı — sadece sunucu yönetimi
user admin on >${redis_admin_pass} ~* &* +@all

# Default kullanıcıyı devre dışı bırak
user default off nopass ~* &* -@all
REDISACL

    chmod 640 /etc/redis/redis.conf /etc/redis/users.acl
    chown redis:redis /etc/redis/redis.conf /etc/redis/users.acl
```

AFTER:
```bash
    # ACL dosyası (umask 077 — parola world-readable olmasın)
    (
        umask 077
        cat > /etc/redis/users.acl << REDISACL
# srvctl Redis ACL
# Admin kullanıcısı — sadece sunucu yönetimi
user admin on >${redis_admin_pass} ~* &* +@all

# Default kullanıcıyı devre dışı bırak
user default off nopass ~* &* -@all
REDISACL
    )
    # redis.conf sır içermez (0640); users.acl parola taşır (0600), sahibi redis daemon
    chmod 640 /etc/redis/redis.conf
    chmod 600 /etc/redis/users.acl
    chown redis:redis /etc/redis/redis.conf /etc/redis/users.acl
```

- [ ] **Step 4: Run, verify PASS**
  Run: `bash tests/test_secret_umask.sh`

- [ ] **Step 5: Commit**
  ```
  git add lib/domain.sh lib/init.sh tests/test_secret_umask.sh
  git commit -m "feat(T6): sır yazımına umask 077 + secure_file (.credentials, .my.cnf, redis acl)

.credentials yazımı _domain_write_credentials saf yardımcısına taşındı;
umask 077 bağlamında yazılıp secure_file ile 0600 root:root kilitleniyor.
/root/.my.cnf ve /etc/redis/users.acl da umask 077 ile yazılıyor, users.acl
modu 0640->0600 daraltıldı (parola world-readable değil).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

---

### Task 22 — [T6.2] /backups ve her artefakt secure_dir/secure_file ile (0700/0600)

**Files:**
- Modify: `lib/backup.sh:30` (per-run dizini), `lib/backup.sh:48` (DB dump), `lib/backup.sh:69` (files tar), `lib/backup.sh:90` (redis.rdb cp), `lib/backup.sh:95` (configs tar), `lib/init.sh:163` (`/backups` oluşturma)
- Test: `tests/test_backup_perms.sh`

**Interfaces:** Consumes: `secure_dir`, `secure_file` (Foundation) ; Produces: pure helper `_backup_secure_artifact <path>` (= `secure_file <path> 600`) reused by later restore work — but trivial, callers may inline.

**macOS-unit-testable?** YES for the per-run directory creation and artifact perm-locking, by extracting `_backup_prepare_dir <backup_path>` (calls `secure_dir <path> 700`) — it needs no mysql/nginx/redis. The actual `mysqldump`/`tar`/`redis-cli` lines are INTEGRATION-ONLY, but the perm-lock call appended after each artifact is shown verbatim. `init.sh:163` is INTEGRATION-ONLY (runs inside `cmd_init`), edit shown.

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export BACKUP_DIR="$(mktemp -d)/backups"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/backup.sh"

# Saf yardımcı var mı?
assert_ok declare -F _backup_prepare_dir

# Per-run dizinini hazırla → 0700 olmalı, BACKUP_DIR kökü de 0700
run_dir="${BACKUP_DIR}/20260630_120000"
_backup_prepare_dir "$run_dir"

assert_ok test -d "$run_dir"
assert_eq "$(_stat_mode "$run_dir")" "700" "per-run dizini 0700"
assert_eq "$(_stat_mode "$BACKUP_DIR")" "700" "BACKUP_DIR kökü 0700"

# İçine bir artefakt koy, kilitleyiciyi çalıştır → 0600
echo "dummy-sql" > "${run_dir}/db_x.sql.gz"
_backup_secure_artifact "${run_dir}/db_x.sql.gz"
assert_eq "$(_stat_mode "${run_dir}/db_x.sql.gz")" "600" "artefakt 0600"

rm -rf "$WEB_ROOT" "$(dirname "$BACKUP_DIR")"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL**
  Run: `bash tests/test_backup_perms.sh`
  Expected: FAIL — `_backup_prepare_dir` / `_backup_secure_artifact` tanımlı değil.

- [ ] **Step 3: Implement**

3a. Add two pure helpers near the top of `lib/backup.sh`, right after the `cmd_backup` block (before `_backup_run`):

```bash
# Yedek kök + per-run dizinini güvenli oluştur (0700 root:root).
# Saf yardımcı: mysql/nginx gerektirmez.
_backup_prepare_dir() {
    local run_dir="$1"
    secure_dir "$BACKUP_DIR" 700
    secure_dir "$run_dir" 700
}

# Tek bir yedek artefaktını 0600 root:root kilitle.
_backup_secure_artifact() {
    secure_file "$1" 600
}
```

3b. Replace per-run `mkdir` in `_backup_run` (`lib/backup.sh:28-30`).

BEFORE:
```bash
    local backup_path="${BACKUP_DIR}/${today}"

    mkdir -p "${backup_path}"
```

AFTER:
```bash
    local backup_path="${BACKUP_DIR}/${today}"

    # Yedek kökü + per-run dizini 0700 root:root
    _backup_prepare_dir "${backup_path}"
```

3c. Lock the DB dump after writing it (`lib/backup.sh:47-49`).

BEFORE:
```bash
        mysqldump --single-transaction --quick --lock-tables=false \
            "$db" 2>/dev/null | gzip > "${backup_path}/${db}.sql.gz"
        db_count=$((db_count + 1))
```

AFTER:
```bash
        mysqldump --single-transaction --quick --lock-tables=false \
            "$db" 2>/dev/null | gzip > "${backup_path}/${db}.sql.gz"
        _backup_secure_artifact "${backup_path}/${db}.sql.gz"
        db_count=$((db_count + 1))
```

3d. Lock the per-domain files tarball after writing it (`lib/backup.sh:69-77`).

BEFORE:
```bash
        tar czf "${backup_path}/${domain}-files.tar.gz" \
            --exclude='*.log' \
            --exclude='cache/*' \
            --exclude='releases/*' \
            --exclude='sessions/*' \
            --exclude='tmp/*' \
            "${dir}" 2>/dev/null || warn "Dosya yedeklemesinde hata: ${domain}"

        file_count=$((file_count + 1))
```

AFTER (note: `.credentials` exclusion is added in T6.5 — here we only add the perm-lock):
```bash
        tar czf "${backup_path}/${domain}-files.tar.gz" \
            --exclude='*.log' \
            --exclude='cache/*' \
            --exclude='releases/*' \
            --exclude='sessions/*' \
            --exclude='tmp/*' \
            "${dir}" 2>/dev/null || warn "Dosya yedeklemesinde hata: ${domain}"
        _backup_secure_artifact "${backup_path}/${domain}-files.tar.gz"

        file_count=$((file_count + 1))
```

3e. Lock the redis dump after copying it (`lib/backup.sh:90`).

BEFORE:
```bash
    cp /var/lib/redis/dump.rdb "${backup_path}/redis.rdb" 2>/dev/null || true
    success "Redis yedeklendi"
```

AFTER:
```bash
    cp /var/lib/redis/dump.rdb "${backup_path}/redis.rdb" 2>/dev/null || true
    _backup_secure_artifact "${backup_path}/redis.rdb"
    success "Redis yedeklendi"
```

3f. Lock the configs tarball after writing it (`lib/backup.sh:95-104`).

BEFORE:
```bash
    tar czf "${backup_path}/configs.tar.gz" \
        /etc/nginx/sites-available/ \
        /etc/php/ \
        /etc/redis/ \
        /etc/mysql/mariadb.conf.d/ \
        /etc/apparmor.d/srvctl-* \
        /etc/fail2ban/jail.local \
        /usr/local/srvctl/conf/ \
        2>/dev/null || true
    success "Konfigürasyonlar yedeklendi"
```

AFTER:
```bash
    tar czf "${backup_path}/configs.tar.gz" \
        /etc/nginx/sites-available/ \
        /etc/php/ \
        /etc/redis/ \
        /etc/mysql/mariadb.conf.d/ \
        /etc/apparmor.d/srvctl-* \
        /etc/fail2ban/jail.local \
        /usr/local/srvctl/conf/ \
        2>/dev/null || true
    _backup_secure_artifact "${backup_path}/configs.tar.gz"
    success "Konfigürasyonlar yedeklendi"
```

3g. INTEGRATION-ONLY edit — `/backups` creation in `cmd_init` (`lib/init.sh:163`).

BEFORE:
```bash
    # ─── Dizinler ───
    mkdir -p "${WEB_ROOT}" "${BACKUP_DIR}" "${SRVCTL_ROOT}/logs"
```

AFTER:
```bash
    # ─── Dizinler ───
    mkdir -p "${WEB_ROOT}" "${SRVCTL_ROOT}/logs"
    # Yedek dizini sır içerir → 0700 root:root
    secure_dir "${BACKUP_DIR}" 700
```

- [ ] **Step 4: Run, verify PASS**
  Run: `bash tests/test_backup_perms.sh`

- [ ] **Step 5: Commit**
  ```
  git add lib/backup.sh lib/init.sh tests/test_backup_perms.sh
  git commit -m "feat(T6): yedek dizini+artefaktları secure_dir/secure_file ile kilitle (0700/0600)

_backup_prepare_dir ve _backup_secure_artifact saf yardımcıları eklendi.
Per-run dizini ve /backups kökü 0700, DB dump / files tar / redis.rdb /
configs tar artefaktları 0600 root:root. init.sh /backups oluşturma da
secure_dir'e geçti.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

---

### Task 23 — [T6.3] Restore çıkarmasını safe_extract ile değiştir (tar/zip-slip + symlink reddi)

**Files:**
- Modify: `lib/backup.sh:191-199` (restore dosya geri yükleme döngüsü)
- Test: `tests/test_safe_extract_callsite.sh` (call-site reddi; `safe_extract`'in kendisi Foundation `tests/test_safe_extract.sh`'te kapsanır)

**Interfaces:** Consumes: `safe_extract <archive> <dest_dir>` (Foundation) ; Produces: nothing.

**macOS-unit-testable?** YES at the call-site by extracting `_backup_restore_files <tar_gz> <dest>` (a thin wrapper: `safe_extract "$tar_gz" "$dest"`). The full `_backup_restore` requires `confirm`/mysql/systemctl → INTEGRATION-ONLY, but the file-extraction unit is reachable. `safe_extract`'s own slip/symlink rejection is verified in Foundation; here we verify the call-site rejects a malicious archive WITHOUT writing outside dest and returns non-zero.

Note on destination: the old code extracted with `-C /` because per-domain tarballs store the absolute path `${WEB_ROOT}/<domain>/...` as members. `safe_extract` REJECTS absolute members. Therefore the restore must extract relative tarballs into `WEB_ROOT`. Since T6.5 (next task) makes the backup tarball relative-pathed, the restore here extracts into `${WEB_ROOT}` (not `/`). For legacy absolute-path tarballs, `safe_extract` will (correctly) refuse — surface a clear warning telling the operator to use a trusted manual extract.

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/backup.sh"

# Call-site sarmalayıcısı var mı?
assert_ok declare -F _backup_restore_files

work="$(mktemp -d)"
dest="$(mktemp -d)"

# 1) Zararsız, RELATİF arşiv → kabul edilmeli ve dest altına çıkmalı
mkdir -p "${work}/iyi/altdizin"
echo "merhaba" > "${work}/iyi/altdizin/dosya.txt"
( cd "$work" && tar czf "${work}/iyi.tar.gz" iyi )
assert_ok _backup_restore_files "${work}/iyi.tar.gz" "$dest"
assert_ok test -f "${dest}/iyi/altdizin/dosya.txt"

# 2) Path-traversal (../) içeren arşiv → reddedilmeli, hedefin DIŞINA yazılmamalı
canary="${dest}/../kacti.txt"
rm -f "$canary"
mkdir -p "${work}/payload"
echo "kotu" > "${work}/payload/kacti.txt"
# ../kacti.txt üyesi üreten arşiv (GNU/BSD tar uyumlu)
( cd "${work}/payload" && tar czf "${work}/slip.tar.gz" -C "${work}/payload" --transform 's,^,../,' kacti.txt 2>/dev/null \
    || tar czf "${work}/slip.tar.gz" -C "${work}" ../payload/kacti.txt 2>/dev/null )
assert_fail _backup_restore_files "${work}/slip.tar.gz" "$dest"
assert_ok test ! -e "$canary"

rm -rf "$WEB_ROOT" "$work" "$dest"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL**
  Run: `bash tests/test_safe_extract_callsite.sh`
  Expected: FAIL — `_backup_restore_files` tanımlı değil. (`safe_extract` Foundation'da mevcut olmalı; değilse bu test grubu Foundation'dan sonra çalıştırılır.)

- [ ] **Step 3: Implement**

3a. Add the call-site wrapper to `lib/backup.sh`, after `_backup_secure_artifact` (added in T6.2):

```bash
# Restore: tek bir files tarball'ını güvenle çıkar (zip-slip/symlink reddi).
# safe_extract mutlak yol/'..'/symlink üyesi varsa çıkarmadan reddeder.
# Saf yardımcı: mysql/systemctl gerektirmez.
_backup_restore_files() {
    local tar_gz="$1" dest="$2"
    safe_extract "$tar_gz" "$dest"
}
```

3b. Replace the file-restore loop in `_backup_restore` (`lib/backup.sh:190-199`).

BEFORE:
```bash
    # Dosya geri yükleme
    for tar_gz in "${backup_path}"/*-files.tar.gz; do
        [[ ! -f "$tar_gz" ]] && continue
        local domain
        domain=$(basename "$tar_gz" -files.tar.gz)
        step "FILES" "Geri yükleniyor: ${domain}"
        tar xzf "$tar_gz" -C / 2>/dev/null && \
            success "Dosyalar geri yüklendi: ${domain}" || \
            warn "Dosya geri yükleme hatası: ${domain}"
    done
```

AFTER:
```bash
    # Dosya geri yükleme (safe_extract — zip-slip/symlink reddi, WEB_ROOT altına)
    for tar_gz in "${backup_path}"/*-files.tar.gz; do
        [[ ! -f "$tar_gz" ]] && continue
        local domain
        domain=$(basename "$tar_gz" -files.tar.gz)
        step "FILES" "Geri yükleniyor: ${domain}"
        if _backup_restore_files "$tar_gz" "${WEB_ROOT}"; then
            success "Dosyalar geri yüklendi: ${domain}"
        else
            warn "Güvenli çıkarma reddedildi (mutlak yol/.. /symlink): ${domain}"
            warn "Eski mutlak yollu yedekler için güvenilir ortamda manuel çıkarın."
        fi
    done
```

- [ ] **Step 4: Run, verify PASS**
  Run: `bash tests/test_safe_extract_callsite.sh`

- [ ] **Step 5: Commit**
  ```
  git add lib/backup.sh tests/test_safe_extract_callsite.sh
  git commit -m "feat(T6): restore çıkarmasını safe_extract ile değiştir (zip-slip/symlink reddi)

_backup_restore_files sarmalayıcısı eklendi; 'tar xzf -C /' kaldırıldı.
Artefaktlar WEB_ROOT altına safe_extract ile çıkarılıyor; mutlak yol, '..'
veya symlink üyesi varsa çıkarmadan reddediliyor. Eski mutlak yollu
yedekler için operatöre uyarı.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

---

### Task 24 — [T6.4] DB/redis parolalarını argv'den çıkar (mysql /root/.my.cnf, redis-cli REDISCLI_AUTH)

**Files:**
- Modify: `lib/domain.sh:350-356` (DB CREATE USER — parola argv'de değil, stdin heredoc), `lib/domain.sh:372-379` (redis-cli ACL LOAD — `REDISCLI_AUTH`), `lib/backup.sh:84-89` (redis BGSAVE — `REDISCLI_AUTH`)
- Test: none new (INTEGRATION-ONLY; doğrulama `ps`/`/proc` ile gerçek host'ta)

**Interfaces:** Consumes: nothing from Foundation ; Produces: nothing.

**macOS-unit-testable?** NO — every edit invokes `mysql` / `redis-cli` against a live service. INTEGRATION-ONLY. Exact edits shown. Rationale: `mysql -e "... IDENTIFIED BY '${db_pass}'"` and `redis-cli --pass "$x"` both place the secret on the process command line, visible to any local user via `ps`/`/proc/<pid>/cmdline`. We move the DB password into a heredoc fed on stdin (root mysql auth comes from `/root/.my.cnf`, written 0600 in T6.1), and the redis password into the `REDISCLI_AUTH` environment variable (read by `redis-cli`, not shown in `ps` argv).

- [ ] **Step 1: Write the failing test** — N/A (integration-only). Validation procedure on a real Ubuntu host:
  ```bash
  # CREATE USER sırasında başka terminalden:
  ps -eo args | grep -i 'IDENTIFIED BY'   # → ÇIKTI OLMAMALI (parola argv'de değil)
  # redis-cli çalışırken:
  ps -eo args | grep -- '--pass'          # → ÇIKTI OLMAMALI
  ```

- [ ] **Step 2: Verify current leak (baseline)** — On host, run the above `ps` greps while the unmodified `domain add` runs; Expected: parola argv'de GÖRÜNÜR (the defect being fixed).

- [ ] **Step 3: Implement**

3a. DB user creation — feed SQL via stdin heredoc so the password never appears in argv (`lib/domain.sh:350-356`). Root auth is taken from `/root/.my.cnf` (no `-u`/`-p` on argv).

BEFORE (`lib/domain.sh:350-356`):
```bash
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
    mysql -e "GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,ALTER,INDEX,DROP,CREATE TEMPORARY TABLES,LOCK TABLES,REFERENCES,TRIGGER ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
    # FILE yetkisini kaldır (dosya sistemi okuma/yazma engellemek için)
    mysql -e "REVOKE ALL PRIVILEGES ON *.* FROM '${db_user}'@'localhost';" 2>/dev/null || true
    mysql -e "GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,ALTER,INDEX,DROP,CREATE TEMPORARY TABLES,LOCK TABLES,REFERENCES,TRIGGER ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
```

AFTER:
```bash
    # Parolayı argv'den uzak tut: SQL stdin heredoc ile beslenir (ps/cmdline'da sır görünmez).
    # Root kimliği /root/.my.cnf'ten gelir (0600 root:root).
    mysql << SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
REVOKE ALL PRIVILEGES ON *.* FROM '${db_user}'@'localhost';
GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,ALTER,INDEX,DROP,CREATE TEMPORARY TABLES,LOCK TABLES,REFERENCES,TRIGGER ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
SQL
```

3b. Redis ACL LOAD — pass admin password via `REDISCLI_AUTH` env instead of `--pass` (`lib/domain.sh:372-379`).

BEFORE (`lib/domain.sh:372-379`):
```bash
    local redis_admin_pass
    redis_admin_pass=$(grep "^REDIS_ADMIN_PASS=" "${SRVCTL_CONF}" 2>/dev/null | cut -d= -f2)
    if [[ -n "$redis_admin_pass" ]]; then
        redis-cli --user admin --pass "$redis_admin_pass" ACL LOAD 2>/dev/null || \
            systemctl restart redis-server
    else
        systemctl restart redis-server
    fi
```

AFTER:
```bash
    local redis_admin_pass
    redis_admin_pass=$(grep "^REDIS_ADMIN_PASS=" "${SRVCTL_CONF}" 2>/dev/null | cut -d= -f2)
    if [[ -n "$redis_admin_pass" ]]; then
        # Parolayı argv'den uzak tut: REDISCLI_AUTH env redis-cli tarafından okunur (ps'te görünmez).
        REDISCLI_AUTH="$redis_admin_pass" redis-cli --user admin --no-auth-warning ACL LOAD 2>/dev/null || \
            systemctl restart redis-server
    else
        systemctl restart redis-server
    fi
```

3c. Redis BGSAVE in backup — same `REDISCLI_AUTH` treatment (`lib/backup.sh:84-89`).

BEFORE (`lib/backup.sh:84-89`):
```bash
    local redis_admin_pass
    redis_admin_pass=$(grep "^REDIS_ADMIN_PASS=" "${SRVCTL_CONF}" 2>/dev/null | cut -d= -f2)
    if [[ -n "$redis_admin_pass" ]]; then
        redis-cli --user admin --pass "$redis_admin_pass" BGSAVE 2>/dev/null || true
        sleep 2
    fi
```

AFTER:
```bash
    local redis_admin_pass
    redis_admin_pass=$(grep "^REDIS_ADMIN_PASS=" "${SRVCTL_CONF}" 2>/dev/null | cut -d= -f2)
    if [[ -n "$redis_admin_pass" ]]; then
        # Parolayı argv'den uzak tut: REDISCLI_AUTH env (ps'te görünmez).
        REDISCLI_AUTH="$redis_admin_pass" redis-cli --user admin --no-auth-warning BGSAVE 2>/dev/null || true
        sleep 2
    fi
```

- [ ] **Step 4: Verify on host** — Re-run the `ps` greps from Step 1 during `domain add` / `backup run`; Expected: no password visible in argv; DB user + redis ACL still created/loaded successfully.

- [ ] **Step 5: Commit**
  ```
  git add lib/domain.sh lib/backup.sh
  git commit -m "feat(T6): DB/redis parolalarını argv'den çıkar (mysql stdin heredoc, REDISCLI_AUTH)

mysql CREATE USER ... IDENTIFIED BY artık stdin heredoc ile besleniyor;
parola ps/cmdline'da görünmüyor (root kimliği /root/.my.cnf'ten).
redis-cli --pass yerine REDISCLI_AUTH env + --no-auth-warning kullanıyor
(domain ACL LOAD ve backup BGSAVE).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

---

### Task 25 — [T6.5] Backup paketinden .credentials hariç tut + relatif yol (slip-safe restore)

**Files:**
- Modify: `lib/backup.sh:59-78` (per-domain files tar — `.credentials`/`.srvctl-meta` exclude + relatif yol), `lib/domain.sh:1024-1026` (migrate paketi — `.credentials` ayrı kopyalanıyor zaten, ama tar'a relatif yol + sır exclude notu)
- Test: `tests/test_backup_excludes_creds.sh`

**Interfaces:** Consumes: `secure_file` (Foundation, indirect via T6.2) ; Produces: nothing.

**macOS-unit-testable?** YES — extract the tar-member-listing into a pure helper `_backup_files_tar <domain> <web_root> <out_tar>` and assert the resulting archive (a) contains `<domain>/public_html/...`, (b) does NOT contain `.credentials` or `.srvctl-meta`, and (c) uses relative member paths (so T6.3 `safe_extract` accepts it). No mysql/nginx needed.

Rationale: per-domain files tarball currently includes `${dir}` (`/var/www/<domain>/`), which sweeps in the root-only `.credentials` (DB/redis passwords) and `.srvctl-meta` — making secrets readable to anyone who can read the backup. Also the absolute path `${dir}` produces absolute tar members that T6.3 `safe_extract` would reject. Fix both: `-C "${WEB_ROOT}"` + relative `${domain}` member, and explicit `--exclude` of the secret/control files.

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/backup.sh"

assert_ok declare -F _backup_files_tar

dom="ornek.com"
base="${WEB_ROOT}/${dom}"
mkdir -p "${base}/public_html"
echo "<?php" > "${base}/public_html/index.php"
echo "DB_PASS=GIZLI" > "${base}/.credentials"
echo "RATE_PROFILE=standard" > "${base}/.srvctl-meta"

out="$(mktemp -d)/files.tar.gz"
_backup_files_tar "$dom" "$WEB_ROOT" "$out"

assert_ok test -f "$out"
members="$(tar -tzf "$out" 2>/dev/null)"

# public_html girmeli, sır/kontrol dosyaları girMEmeli
assert_contains "$members" "${dom}/public_html/index.php" "public_html arşivde"
assert_not_contains "$members" ".credentials" ".credentials arşivde DEĞİL"
assert_not_contains "$members" ".srvctl-meta" ".srvctl-meta arşivde DEĞİL"

# Relatif yol: hiçbir üye '/' ile başlamamalı (safe_extract uyumu)
assert_not_contains "$members" "/${dom}/" "üyeler mutlak yol DEĞİL"
first_char="$(printf '%s\n' "$members" | head -1 | cut -c1)"
assert_eq "$first_char" "$dom" "ilk üye '${dom}' ile başlıyor (relatif)" 2>/dev/null || \
  assert_contains "$(printf '%s\n' "$members" | head -1)" "$dom" "ilk üye relatif (${dom}...)"

rm -rf "$WEB_ROOT" "$(dirname "$out")"
test_summary
```

- [ ] **Step 2: Run it, verify FAIL**
  Run: `bash tests/test_backup_excludes_creds.sh`
  Expected: FAIL — `_backup_files_tar` tanımlı değil.

- [ ] **Step 3: Implement**

3a. Add the pure helper to `lib/backup.sh`, after `_backup_restore_files` (T6.3). It centralizes the exclude list and relative pathing:

```bash
# Per-domain dosya tarball'ı (relatif yol + sır/kontrol dosyalarını hariç tut).
# .credentials/.srvctl-meta sır/kontrol dosyalarıdır; yedek paketine girmemeli
# (paket world-readable olabilir + safe_extract restore'u için relatif yol şart).
# Saf yardımcı: mysql/nginx gerektirmez.
_backup_files_tar() {
    local domain="$1" web_root="$2" out_tar="$3"
    tar czf "$out_tar" -C "$web_root" \
        --exclude='*.log' \
        --exclude="${domain}/cache/*" \
        --exclude="${domain}/releases/*" \
        --exclude="${domain}/sessions/*" \
        --exclude="${domain}/tmp/*" \
        --exclude="${domain}/.credentials" \
        --exclude="${domain}/.srvctl-meta" \
        --exclude="${domain}/.deploy-repo" \
        "$domain"
}
```

3b. Replace the files-backup block in `_backup_run` to use the helper (`lib/backup.sh:59-78`, as left by T6.2). This supersedes the inline `tar czf` from T6.2 step 3d.

BEFORE (after T6.2):
```bash
    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")

        # Hedef domain varsa, sadece onu yedekle
        if [[ -n "$target_domain" && "$domain" != "$target_domain" ]]; then
            continue
        fi

        tar czf "${backup_path}/${domain}-files.tar.gz" \
            --exclude='*.log' \
            --exclude='cache/*' \
            --exclude='releases/*' \
            --exclude='sessions/*' \
            --exclude='tmp/*' \
            "${dir}" 2>/dev/null || warn "Dosya yedeklemesinde hata: ${domain}"
        _backup_secure_artifact "${backup_path}/${domain}-files.tar.gz"

        file_count=$((file_count + 1))
    done
```

AFTER:
```bash
    for dir in "${WEB_ROOT}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")

        # Hedef domain varsa, sadece onu yedekle
        if [[ -n "$target_domain" && "$domain" != "$target_domain" ]]; then
            continue
        fi

        # Relatif yol + .credentials/.srvctl-meta hariç (safe_extract uyumlu, sır sızdırmaz)
        _backup_files_tar "$domain" "${WEB_ROOT}" "${backup_path}/${domain}-files.tar.gz" \
            2>/dev/null || warn "Dosya yedeklemesinde hata: ${domain}"
        _backup_secure_artifact "${backup_path}/${domain}-files.tar.gz"

        file_count=$((file_count + 1))
    done
```

3c. Migrate bundle — make its files tarball relative + secret-excluded too, and add a note explaining `.credentials` is deliberately copied as a SEPARATE 0600 file (already at `lib/domain.sh:1026`) rather than embedded in the world-readable tarball (`lib/domain.sh:1024-1026`).

BEFORE (`lib/domain.sh:1024-1026`):
```bash
    step "1/3" "Dosyalar arşivleniyor..."
    tar czf "${bundle}/files.tar.gz" -C "${WEB_ROOT}" "${domain}" 2>/dev/null
    cp "${base}/.credentials" "${bundle}/credentials" 2>/dev/null || true
```

AFTER:
```bash
    step "1/3" "Dosyalar arşivleniyor..."
    # NOT: .credentials/.srvctl-meta tarball'a girmez (sır sızıntısı); credentials
    # ayrı 0600 dosya olarak taşınır. Relatif yol → karşı uçta safe_extract uyumlu.
    _backup_files_tar "${domain}" "${WEB_ROOT}" "${bundle}/files.tar.gz" 2>/dev/null
    cp "${base}/.credentials" "${bundle}/credentials" 2>/dev/null || true
    secure_file "${bundle}/credentials" 600
```

3d. README note. Append a short note to the backup/restore section of `README.md` documenting that backups intentionally exclude `.credentials`/`.srvctl-meta` (Phase 1: exclude-and-note; encryption deferred), so operators know to re-provision credentials on restore or keep them out-of-band:

```markdown
> **Güvenlik notu (Faz 1):** Yedek paketleri `.credentials` ve `.srvctl-meta`
> dosyalarını **içermez** (parolaların world-readable yedeğe sızmaması için).
> Geri yüklemede DB/Redis parolaları yeniden üretilir veya `.credentials`
> güvenli (band-dışı) bir kopyadan elle yerleştirilir. Yedek şifrelemesi
> ileride eklenecektir.
```

- [ ] **Step 4: Run, verify PASS**
  Run: `bash tests/test_backup_excludes_creds.sh`

- [ ] **Step 5: Commit**
  ```
  git add lib/backup.sh lib/domain.sh README.md tests/test_backup_excludes_creds.sh
  git commit -m "feat(T6): yedek paketinden .credentials/.srvctl-meta hariç tut + relatif yol

_backup_files_tar saf yardımcısı: per-domain tarball relatif yollu (safe_extract
uyumlu) ve .credentials/.srvctl-meta/.deploy-repo hariç. backup run ve domain
migrate bu yardımcıyı kullanıyor; migrate credentials'ı ayrı 0600 dosya olarak
taşıyor. README'ye Faz 1 güvenlik notu (exclude+not, şifreleme ertelendi).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

Notes for the integrating author (file paths absolute):
- Foundation dependency: all five tasks assume `secure_file`, `secure_dir`, and `safe_extract` already exist in `/Users/bertugfahriozer/Projects/srvctl/lib/core.sh` (produced by the Foundation task group) and that `_stat_mode` is available for the perm assertions. Run the T6 tests only after Foundation lands.
- New test files all register automatically via `/Users/bertugfahriozer/Projects/srvctl/tests/run.sh` (`tests/test_*.sh` glob) — no manual wiring needed.
- macOS-unit-testable tasks: **T6.1 (partial — .credentials), T6.2 (dir/artifact perms), T6.3 (call-site), T6.5 (tar excludes)**. Integration-only: **T6.4 (argv leak) and the `/root/.my.cnf` + redis-acl host portions of T6.1, plus `init.sh:163` of T6.2** — exact edits are shown regardless.
- Cross-task ordering: T6.5 step 3b supersedes the inline `tar czf` left by T6.2 step 3d (same block) — apply T6.2 then T6.5 in order; the final `_backup_run` files loop is the T6.5 AFTER version.

---

### Task 26 — [F9] Register new test files in `tests/run.sh` (smoke)

**Files:** No `run.sh` edit needed — `run.sh` auto-discovers `tests/test_*.sh` (verified: `for tf in tests/test_*.sh`). This task is the full-suite green gate. Test: the whole `tests/` suite.
**Interfaces:** Consumes: F1-F8 outputs + existing tests. Produces: confirmation the suite (old + new) is green on macOS.

- [ ] **Step 1: Write the failing test** — N/A (no new test); the gate is the aggregate run. If any earlier task regressed an existing test (e.g. `test_meta.sh` after the unquoted write_meta change), this surfaces it.

- [ ] **Step 2: Run it, verify FAIL** — Run before all F1-F8 implementations are merged: `bash tests/run.sh` ; Expected: non-zero (new test_*.sh fail until their functions land). After F1-F8 it must be green.

- [ ] **Step 3: Implement** — No code. If `tests/run.sh` did NOT auto-discover (it does), the edit would be adding each file; not required here. Verify discovery:
```bash
grep -n 'for tf in tests/test_' tests/run.sh
```

- [ ] **Step 4: Run, verify PASS** — Run: `bash tests/run.sh` ; Expected last line: `TÜM TEST DOSYALARI GEÇTİ` and exit 0. This confirms F4's regression promise (`test_meta.sh` still green with unquoted storage) and all F1-F8 new tests pass together.

- [ ] **Step 5: Commit** — N/A unless `run.sh` needed editing. If nothing changed, skip; otherwise:
```bash
git add tests/run.sh
git commit -m "$(cat <<'EOF'
chore(tests): core.sh primitif testlerini suite'e dahil et (oto-keşif doğrulandı)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

---

## Self-Review (spec kapsama)

Spec (`docs/superpowers/specs/2026-06-30-srvctl-security-hardening-phase1-design.md`) gereksinimleri → task eşlemesi:

- **§4.1 read_kv_file** → Task 3 (F3). **§4.2 assert_root_owned_path** → Task 5 (F5). **§4.3 validator'lar** → Task 2 (F2). **§4.4 secure_file/dir** → Task 6 (F6). **§4.5 safe_extract** → Task 7 (F7). **§4.6 render_template newline** → Task 8 (F8). **Portable stat** → Task 1 (F1).
- **§5 T2** (source→parse + kimlik + eval-kaldır) → Task 4 (F4: reader rewrite), Task 9-11 (T2.2-2.4).
- **§5 T4** (validate_domain, regex-safe, ip/user/cloudflare/load_config) → Task 12-17.
- **§5 T5** (webhook fail-closed) → Task 18-20.
- **§5 T6** (umask/secure perms, safe_extract restore, secret-off-argv, .credentials hariç) → Task 21-25.
- **§7 test stratejisi** → her task kendi `tests/test_*.sh`'ini getirir; Task 26 (F9) tüm-suite kapısı.
- **§6 geri uyumluluk** → Task 4 mevcut `tests/test_meta.sh` round-trip'ini regresyon kapısı olarak korur (tırnaksız format + verbatim okuma).

**Kapsam dışı (bilinçli, Faz 2):** T1 base-dir sahiplik modeli + `srvctl security harden-fs` migrasyon, T3 deploy artefakt priv-drop, T7 MAC/cgroups + fail-closed audit + install.sh template'leri. `assert_root_owned_path` Faz 1'de warn-modunda tüketilir (Task 4/F4 notu); Faz 2 (T1) base'i root'a aldıktan sonra fail-closed'a yükseltilir.

**Tutarlılık:** Tüm fonksiyon adları kilitli sözleşmeyle bire bir; T2.1 (F4 ile birebir kopya) çıkarıldı; F9 run.sh oto-keşfini doğru tespit edip tüm-suite kapısı olarak konumlandı; placeholder taraması temiz.
