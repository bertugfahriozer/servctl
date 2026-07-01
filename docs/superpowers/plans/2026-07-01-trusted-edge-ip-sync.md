# Güvenilir Edge-IP Senkronu (Cloudflare + UptimeRobot) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cloudflare + UptimeRobot IP listelerini otomatik çekip srvctl allowlist'ine (fail2ban `ignoreip`) işleyen, Cloudflare için nginx real-IP restorasyonu kuran ve günlük cron ile tazeleyen `srvctl trusted` modülü.

**Architecture:** Yeni bağımsız `lib/trusted.sh` modülü (`cmd_trusted`), srvctl'in modül-başına-konsept lazy-load desenine uyar. Saf fonksiyonlar (parse/validate/sanity/render/dedup) fixture ile macOS'ta unit-test edilir; fetch/apply/reload HOST'ta çalışır. Fail-safe: fetch/sanity başarısızsa her kaynağın son-iyi listesi korunur.

**Tech Stack:** Bash (pure), curl, nginx `set_real_ip_from`/`real_ip_header`, fail2ban `ignoreip`, hafif bash test harness (`tests/lib.sh`).

## Global Constraints

- Tüm kullanıcı-görünür string ve yorumlar **Türkçe** (proje konvansiyonu).
- Her script `set -euo pipefail` ile başlamaz — modüller core.sh tarafından source'lanır; testler `set -uo pipefail` kullanır (NO `-e`).
- IP doğrulama için **yalnız** core.sh'teki mevcut `validate_ip_or_cidr <deger>` kullanılır (status: 0=geçerli, 1=geçersiz). Yeni validator yazma.
- Config varsayılanları **`load_config` (lib/core.sh) içinde** `${VAR:-default}` deseniyle — böylece mevcut kurulumlar conf düzenlemeden çalışır.
- `error()` ÇIKIŞ yapar; saf/test-edilebilir fonksiyonlarda `error`/`require_root` KULLANMA (yalnız `cmd_trusted` route'unda).
- nginx conf.d dosyaları **wholesale** yeniden üretilir (mevcut `_update_nginx_whitelist` deseni): yaz → `nginx -t && systemctl reload nginx`, reload yalnız `command -v nginx` varsa.
- Fetch fixture-enjekte edilebilir: `SRVCTL_TRUSTED_FIXTURE_DIR` set ise curl yerine oradan okunur (test için).
- Apply hedefleri test için yol-enjekte edilebilir: `FAIL2BAN_JAIL_LOCAL` (varsayılan `/etc/fail2ban/jail.local`), `NGINX_CF_REALIP_CONF` (varsayılan `/etc/nginx/conf.d/srvctl-cloudflare-realip.conf`).
- Sanity min: `cloudflare.conf` ≥ 8 satır, `uptimerobot.conf` ≥ 5 satır.
- Cron saati: `30 2 * * *` (mevcut cron'larla çakışmaz).
- Portability: `sed -i` KULLANMA (macOS/GNU farkı) — `sed 'expr' file > tmp && mv tmp file`.

## Dosya yapısı

| Dosya | Sorumluluk | İşlem |
|-------|-----------|-------|
| `lib/trusted.sh` | Modül: cmd_trusted + tüm _trusted_* fonksiyonları | Create |
| `tests/test_trusted_config.sh` | load_config varsayılan testleri | Create |
| `tests/test_trusted.sh` | Saf fonksiyon + e2e (fixture) + fail-safe testleri | Create |
| `lib/core.sh` | `load_config`'e TRUSTED_* varsayılanları | Modify |
| `conf/srvctl.conf` | Yorumlu TRUSTED_* anahtarları (keşfedilebilirlik) | Modify |
| `bin/srvctl` | Dispatch: `trusted) _load_and_run trusted cmd_trusted` | Modify |
| `lib/init.sh` | `_setup_cron_jobs`'a trusted cron + ilk senkron | Modify |
| `completions/srvctl.bash` | `trusted` komutu + `sync list` alt-komutları | Modify |
| `completions/srvctl.zsh` | Aynı | Modify |
| `README.md` | `srvctl trusted` dokümantasyonu | Modify |

---

## Task 1: Config varsayılanları + conf template

**Files:**
- Modify: `lib/core.sh` (load_config, `DEPLOYER_USER` satırından sonra)
- Modify: `conf/srvctl.conf`
- Test: `tests/test_trusted_config.sh` (Create)

**Interfaces:**
- Produces: `TRUSTED_SYNC_ENABLED`, `TRUSTED_SOURCES`, `TRUSTED_STATE_DIR`, `CLOUDFLARE_IPS_V4_URL`, `CLOUDFLARE_IPS_V6_URL`, `UPTIMEROBOT_IPS_URL` — load_config source'landığında set olur.

- [ ] **Step 1: Testi yaz** — `tests/test_trusted_config.sh`

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

assert_eq "$TRUSTED_SYNC_ENABLED" "true" "TRUSTED_SYNC_ENABLED varsayılan true"
assert_eq "$TRUSTED_STATE_DIR" "/etc/srvctl/trusted" "TRUSTED_STATE_DIR varsayılan"
assert_contains "$TRUSTED_SOURCES" "cloudflare" "TRUSTED_SOURCES cloudflare içerir"
assert_contains "$TRUSTED_SOURCES" "uptimerobot" "TRUSTED_SOURCES uptimerobot içerir"
assert_contains "$CLOUDFLARE_IPS_V4_URL" "cloudflare.com/ips-v4" "CF v4 URL varsayılan"
assert_contains "$CLOUDFLARE_IPS_V6_URL" "cloudflare.com/ips-v6" "CF v6 URL varsayılan"
assert_contains "$UPTIMEROBOT_IPS_URL" "uptimerobot.com" "UptimeRobot URL varsayılan"

test_summary
```

- [ ] **Step 2: Testin başarısız olduğunu gör**

Run: `bash tests/test_trusted_config.sh`
Expected: FAIL — `TRUSTED_SYNC_ENABLED: unbound variable` veya boş değer.

- [ ] **Step 3: load_config'e varsayılanları ekle** — `lib/core.sh`, `DEPLOYER_USER="${DEPLOYER_USER:-deployer}"` satırının hemen ALTINA:

```bash
    # ─── Güvenilir edge-IP senkronu (Cloudflare + UptimeRobot) ───
    TRUSTED_SYNC_ENABLED="${TRUSTED_SYNC_ENABLED:-true}"
    TRUSTED_SOURCES="${TRUSTED_SOURCES:-cloudflare uptimerobot}"
    TRUSTED_STATE_DIR="${TRUSTED_STATE_DIR:-/etc/srvctl/trusted}"
    CLOUDFLARE_IPS_V4_URL="${CLOUDFLARE_IPS_V4_URL:-https://www.cloudflare.com/ips-v4}"
    CLOUDFLARE_IPS_V6_URL="${CLOUDFLARE_IPS_V6_URL:-https://www.cloudflare.com/ips-v6}"
    UPTIMEROBOT_IPS_URL="${UPTIMEROBOT_IPS_URL:-https://uptimerobot.com/inc/files/ips/IPv4andIPv6.txt}"
```

- [ ] **Step 4: conf template'e yorumlu anahtarları ekle** — `conf/srvctl.conf` sonuna:

```bash

# ─── Güvenilir edge-IP senkronu (Cloudflare + UptimeRobot) ───
# Bu IP'ler fail2ban ignoreip'e eklenir (asla banlanmaz); Cloudflare için nginx
# real-IP restorasyonu kurulur. Günlük cron ile tazelenir. Varsayılanlar load_config'te.
# TRUSTED_SYNC_ENABLED=true
# TRUSTED_SOURCES="cloudflare uptimerobot"
# CLOUDFLARE_IPS_V4_URL="https://www.cloudflare.com/ips-v4"
# CLOUDFLARE_IPS_V6_URL="https://www.cloudflare.com/ips-v6"
# UPTIMEROBOT_IPS_URL="https://uptimerobot.com/inc/files/ips/IPv4andIPv6.txt"
```

- [ ] **Step 5: Testin geçtiğini gör**

Run: `bash tests/test_trusted_config.sh`
Expected: PASS — Toplam: 7, Başarısız: 0

- [ ] **Step 6: Commit**

```bash
git add lib/core.sh conf/srvctl.conf tests/test_trusted_config.sh
git commit -m "feat(trusted): TRUSTED_* config varsayılanları + conf template"
```

---

## Task 2: lib/trusted.sh — parse/validate + sanity

**Files:**
- Create: `lib/trusted.sh`
- Test: `tests/test_trusted.sh` (Create)

**Interfaces:**
- Consumes: `validate_ip_or_cidr` (core.sh).
- Produces:
  - `_trusted_parse_validate <file>` → stdout: yalnız geçerli IP/CIDR satırları (yorum/boş/geçersiz ayıklanır). Dosya yoksa boş çıktı, status 0.
  - `_trusted_sane <min> <file>` → status 0 eğer dosyadaki boş-olmayan satır sayısı ≥ min, aksi 1.

- [ ] **Step 1: Testi yaz** — `tests/test_trusted.sh`

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/trusted.sh"

WORK="$(mktemp -d)"

# ── parse_validate: çöp ayıklama ──
cat > "${WORK}/raw" <<'RAW'
173.245.48.0/20
# yorum satırı
103.21.244.0/22

not-an-ip
2400:cb00::/32
999.999.1.1
198.51.100.7
RAW
out="$(_trusted_parse_validate "${WORK}/raw")"
assert_contains "$out" "173.245.48.0/20" "geçerli v4 CIDR geçer"
assert_contains "$out" "198.51.100.7" "geçerli v4 IP geçer"
assert_contains "$out" "2400:cb00::/32" "geçerli v6 CIDR geçer"
assert_not_contains "$out" "not-an-ip" "geçersiz satır ayıklanır"
assert_not_contains "$out" "999.999" "aralık-dışı v4 ayıklanır"
assert_not_contains "$out" "yorum" "yorum ayıklanır"

# ── sane ──
printf 'a\nb\nc\n' > "${WORK}/three"
assert_ok   _trusted_sane 2 "${WORK}/three"
assert_fail _trusted_sane 5 "${WORK}/three"
: > "${WORK}/empty"
assert_fail _trusted_sane 1 "${WORK}/empty"
assert_fail _trusted_sane 1 "${WORK}/yok-dosya"

rm -rf "$WORK"
test_summary
```

- [ ] **Step 2: Testin başarısız olduğunu gör**

Run: `bash tests/test_trusted.sh`
Expected: FAIL — `_trusted_parse_validate: command not found` (henüz modül yok).

- [ ] **Step 3: lib/trusted.sh'i oluştur (bu iki fonksiyonla)**

```bash
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
```

- [ ] **Step 4: Testin geçtiğini gör**

Run: `bash tests/test_trusted.sh`
Expected: PASS — parse ve sane assertion'ları geçer.

- [ ] **Step 5: Commit**

```bash
git add lib/trusted.sh tests/test_trusted.sh
git commit -m "feat(trusted): parse/validate + sanity (saf fonksiyonlar)"
```

---

## Task 3: render_realip + compute_ignoreip

**Files:**
- Modify: `lib/trusted.sh`
- Test: `tests/test_trusted.sh` (genişlet)

**Interfaces:**
- Produces:
  - `_trusted_render_realip <cf_file>` → stdout: `# ...` başlık + her CF satırı için `set_real_ip_from <ip>;` + son satır `real_ip_header CF-Connecting-IP;`. Dosya yoksa yalnız başlık+header.
  - `_trusted_compute_ignoreip <base> <file>...` → stdout: base + verilen dosyalardaki tüm IP'ler, sıra-koruyan dedup, tek satır (boşlukla ayrık).

- [ ] **Step 1: Testi genişlet** — `tests/test_trusted.sh` içinde `rm -rf "$WORK"` satırından ÖNCE ekle:

```bash

# ── render_realip ──
printf '173.245.48.0/20\n2400:cb00::/32\n' > "${WORK}/cf"
r="$(_trusted_render_realip "${WORK}/cf")"
assert_contains "$r" "set_real_ip_from 173.245.48.0/20;" "v4 set_real_ip_from"
assert_contains "$r" "set_real_ip_from 2400:cb00::/32;" "v6 set_real_ip_from"
assert_contains "$r" "real_ip_header CF-Connecting-IP;" "real_ip_header satırı"

# ── compute_ignoreip: dedup + tek satır ──
printf '1.1.1.1\n2.2.2.2\n' > "${WORK}/a"
printf '2.2.2.2\n3.3.3.3\n' > "${WORK}/b"
line="$(_trusted_compute_ignoreip "127.0.0.1/8" "${WORK}/a" "${WORK}/b")"
assert_contains "$line" "127.0.0.1/8" "base var"
assert_contains "$line" "3.3.3.3" "b'den IP var"
assert_eq "$(printf '%s\n' "$line" | grep -o '2\.2\.2\.2' | wc -l | tr -d ' ')" "1" "dedup: 2.2.2.2 bir kez"
assert_eq "$(printf '%s' "$line" | grep -c '')" "1" "tek satır (yeni-satır yok)"
```

- [ ] **Step 2: Testin başarısız olduğunu gör**

Run: `bash tests/test_trusted.sh`
Expected: FAIL — `_trusted_render_realip: command not found`.

- [ ] **Step 3: İki fonksiyonu lib/trusted.sh'e ekle** (`_trusted_sane`'den sonra)

```bash

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
```

- [ ] **Step 4: Testin geçtiğini gör**

Run: `bash tests/test_trusted.sh`
Expected: PASS — tüm parse/sane/render/ignoreip assertion'ları geçer.

- [ ] **Step 5: Commit**

```bash
git add lib/trusted.sh tests/test_trusted.sh
git commit -m "feat(trusted): nginx real-ip render + ignoreip dedup (saf)"
```

---

## Task 4: fetch + apply + sync orchestration + list + cmd_trusted

**Files:**
- Modify: `lib/trusted.sh`
- Test: `tests/test_trusted.sh` (genişlet — e2e + fail-safe + cmd help)

**Interfaces:**
- Consumes: `TRUSTED_SOURCES`, `TRUSTED_STATE_DIR`, `*_URL` (load_config); `SRVCTL_TRUSTED_FIXTURE_DIR`, `FAIL2BAN_JAIL_LOCAL`, `NGINX_CF_REALIP_CONF` (opsiyonel override); `info`/`warn`/`success`/`log_action`/`require_root`/`header` (core.sh).
- Produces:
  - `_trusted_fetch <url> <dest> <fixture_name>` → status 0/1; fixture varsa oradan cat, yoksa curl.
  - `_trusted_apply_ignoreip` → jail.local'deki `ignoreip = ` satırını türetilenle değiştirir (yoksa `[DEFAULT]` bloğu ekler); fail2ban reload (varsa).
  - `_trusted_apply_realip` → CF real-ip conf'unu yazar; nginx reload (varsa).
  - `_trusted_sync` → tüm kaynakları işle (fail-safe) + apply.
  - `_trusted_list` → kaynak-başına sayı + son senkron.
  - `cmd_trusted [sync|list|help]` → route (`sync` → require_root + _trusted_sync).

- [ ] **Step 1: Testi genişlet** — `tests/test_trusted.sh` içinde `rm -rf "$WORK"` satırından ÖNCE ekle:

```bash

# ── fetch (fixture) + sync e2e + fail-safe ──
export TRUSTED_STATE_DIR="${WORK}/state"; mkdir -p "$TRUSTED_STATE_DIR"
export SRVCTL_TRUSTED_FIXTURE_DIR="${WORK}/fix"; mkdir -p "$SRVCTL_TRUSTED_FIXTURE_DIR"
export FAIL2BAN_JAIL_LOCAL="${WORK}/jail.local"
export NGINX_CF_REALIP_CONF="${WORK}/cf-realip.conf"
export TRUSTED_SOURCES="cloudflare uptimerobot"

# CF v4 (8) + v6 (3) → sane(8) geçer; UR (6) → sane(5) geçer
{ for i in $(seq 1 8); do echo "10.0.${i}.0/24"; done; } > "${SRVCTL_TRUSTED_FIXTURE_DIR}/cloudflare-v4"
printf '2400:cb00::/32\n2606:4700::/32\n2803:f800::/32\n' > "${SRVCTL_TRUSTED_FIXTURE_DIR}/cloudflare-v6"
{ for i in $(seq 1 6); do echo "216.144.250.${i}"; done; } > "${SRVCTL_TRUSTED_FIXTURE_DIR}/uptimerobot"
printf '[DEFAULT]\nignoreip = 127.0.0.1/8\n' > "$FAIL2BAN_JAIL_LOCAL"

_trusted_sync >/dev/null 2>&1

assert_ok test -f "${TRUSTED_STATE_DIR}/cloudflare.conf"
assert_ok test -f "${TRUSTED_STATE_DIR}/uptimerobot.conf"
assert_contains "$(cat "$FAIL2BAN_JAIL_LOCAL")" "10.0.1.0/24" "ignoreip CF içerir"
assert_contains "$(cat "$FAIL2BAN_JAIL_LOCAL")" "216.144.250.1" "ignoreip UR içerir"
assert_contains "$(cat "$FAIL2BAN_JAIL_LOCAL")" "127.0.0.1/8" "ignoreip base korunur"
assert_contains "$(cat "$NGINX_CF_REALIP_CONF")" "set_real_ip_from 10.0.1.0/24;" "realip conf CF içerir"
assert_not_contains "$(cat "$NGINX_CF_REALIP_CONF")" "216.144.250" "realip UR İÇERMEZ (proxy değil)"

# fail-safe: CF fixture'ı boşalt → yeni sync mevcut cloudflare.conf'u KORUMALI
cf_before="$(cat "${TRUSTED_STATE_DIR}/cloudflare.conf")"
: > "${SRVCTL_TRUSTED_FIXTURE_DIR}/cloudflare-v4"
: > "${SRVCTL_TRUSTED_FIXTURE_DIR}/cloudflare-v6"
_trusted_sync >/dev/null 2>&1
assert_eq "$(cat "${TRUSTED_STATE_DIR}/cloudflare.conf")" "$cf_before" "fetch boş/sanity-fail → cloudflare.conf korunur"

# cmd_trusted help çalışır (exit 0)
assert_ok cmd_trusted help
```

- [ ] **Step 2: Testin başarısız olduğunu gör**

Run: `bash tests/test_trusted.sh`
Expected: FAIL — `_trusted_sync: command not found`.

- [ ] **Step 3: Fonksiyonları lib/trusted.sh'e ekle** (`_trusted_compute_ignoreip`'ten sonra)

```bash

# Fetch: SRVCTL_TRUSTED_FIXTURE_DIR set ise fixture'dan, yoksa curl. $3=fixture adı.
_trusted_fetch() {
    local url="$1" dest="$2" name="$3"
    if [[ -n "${SRVCTL_TRUSTED_FIXTURE_DIR:-}" ]]; then
        [[ -f "${SRVCTL_TRUSTED_FIXTURE_DIR}/${name}" ]] || return 1
        cat "${SRVCTL_TRUSTED_FIXTURE_DIR}/${name}" > "$dest"
        return 0
    fi
    curl -sf --max-time 20 "$url" -o "$dest" 2>/dev/null
}

# ignoreip'i fail2ban jail.local'e uygula (+ reload, fail2ban varsa).
_trusted_apply_ignoreip() {
    local jail="${FAIL2BAN_JAIL_LOCAL:-/etc/fail2ban/jail.local}"
    local manual="/etc/srvctl/ip-whitelist.conf"
    local line tmp
    line=$(_trusted_compute_ignoreip "127.0.0.1/8" "$manual" \
        "${TRUSTED_STATE_DIR}/cloudflare.conf" "${TRUSTED_STATE_DIR}/uptimerobot.conf")
    [[ -f "$jail" ]] || return 0
    if grep -q '^ignoreip = ' "$jail"; then
        tmp=$(mktemp)
        sed "s|^ignoreip = .*|ignoreip = ${line}|" "$jail" > "$tmp" && mv "$tmp" "$jail"
    else
        printf '\n[DEFAULT]\nignoreip = %s\n' "$line" >> "$jail"
    fi
    command -v fail2ban-client >/dev/null 2>&1 && systemctl reload fail2ban 2>/dev/null || true
}

# Cloudflare real-ip conf'unu yaz (+ nginx reload, nginx varsa).
_trusted_apply_realip() {
    local conf="${NGINX_CF_REALIP_CONF:-/etc/nginx/conf.d/srvctl-cloudflare-realip.conf}"
    _trusted_render_realip "${TRUSTED_STATE_DIR}/cloudflare.conf" > "$conf"
    if command -v nginx >/dev/null 2>&1; then
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    fi
}

# Tüm kaynakları çek → doğrula → sanity → (başarıda) kaydet; sonra uygula. Fail-safe.
_trusted_sync() {
    mkdir -p "$TRUSTED_STATE_DIR"
    local src t1 t2 combined
    for src in $TRUSTED_SOURCES; do
        case "$src" in
            cloudflare)
                t1=$(mktemp); t2=$(mktemp); combined=$(mktemp)
                if _trusted_fetch "$CLOUDFLARE_IPS_V4_URL" "$t1" "cloudflare-v4" \
                   && _trusted_fetch "$CLOUDFLARE_IPS_V6_URL" "$t2" "cloudflare-v6"; then
                    { _trusted_parse_validate "$t1"; _trusted_parse_validate "$t2"; } > "$combined"
                    if _trusted_sane 8 "$combined"; then
                        mv "$combined" "${TRUSTED_STATE_DIR}/cloudflare.conf"
                        info "Cloudflare IP listesi güncellendi ($(grep -c . "${TRUSTED_STATE_DIR}/cloudflare.conf") satır)"
                    else
                        warn "Cloudflare listesi boş/eksik — mevcut liste korunuyor"
                    fi
                else
                    warn "Cloudflare IP fetch başarısız — mevcut liste korunuyor"
                fi
                rm -f "$t1" "$t2" "$combined"
                ;;
            uptimerobot)
                t1=$(mktemp); combined=$(mktemp)
                if _trusted_fetch "$UPTIMEROBOT_IPS_URL" "$t1" "uptimerobot"; then
                    _trusted_parse_validate "$t1" > "$combined"
                    if _trusted_sane 5 "$combined"; then
                        mv "$combined" "${TRUSTED_STATE_DIR}/uptimerobot.conf"
                        info "UptimeRobot IP listesi güncellendi ($(grep -c . "${TRUSTED_STATE_DIR}/uptimerobot.conf") satır)"
                    else
                        warn "UptimeRobot listesi boş/eksik — mevcut liste korunuyor"
                    fi
                else
                    warn "UptimeRobot IP fetch başarısız — mevcut liste korunuyor"
                fi
                rm -f "$t1" "$combined"
                ;;
        esac
    done
    _trusted_apply_ignoreip
    _trusted_apply_realip
    log_action "TRUSTED SYNC" 2>/dev/null || true
    success "Güvenilir IP senkronu tamamlandı"
}

# Yönetilen güvenilir IP'leri ve son senkronu göster.
_trusted_list() {
    local src f
    echo "  Güvenilir IP'ler (${TRUSTED_STATE_DIR})"
    for src in cloudflare uptimerobot; do
        f="${TRUSTED_STATE_DIR}/${src}.conf"
        if [[ -f "$f" ]]; then
            echo "    ${src}: $(grep -c . "$f") IP  (son: $(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?'))"
        else
            echo "    ${src}: (henüz senkron edilmedi)"
        fi
    done
}

cmd_trusted() {
    case "${1:-help}" in
        sync)  require_root; _trusted_sync ;;
        list)  _trusted_list ;;
        help|*)
            echo "  Kullanım: srvctl trusted <sync|list>"
            echo "    sync   Cloudflare + UptimeRobot IP'lerini çek, allowlist'e uygula"
            echo "    list   Yönetilen güvenilir IP'leri ve son senkronu göster"
            ;;
    esac
}
```

- [ ] **Step 4: Testin geçtiğini gör**

Run: `bash tests/test_trusted.sh`
Expected: PASS — e2e, fail-safe, cmd help assertion'ları geçer.

- [ ] **Step 5: Tüm suite'i çalıştır**

Run: `bash tests/run.sh`
Expected: `TÜM TEST DOSYALARI GEÇTİ`

- [ ] **Step 6: Commit**

```bash
git add lib/trusted.sh tests/test_trusted.sh
git commit -m "feat(trusted): fetch + apply (ignoreip/realip) + sync + list + cmd"
```

---

## Task 5: bin/srvctl dispatch + completions

**Files:**
- Modify: `bin/srvctl` (dispatch case)
- Modify: `completions/srvctl.bash`
- Modify: `completions/srvctl.zsh`

**Interfaces:**
- Consumes: `cmd_trusted` (Task 4).

- [ ] **Step 1: Dispatch satırını ekle** — `bin/srvctl`, `ip)` satırından sonra:

```bash
    trusted)    _load_and_run trusted cmd_trusted "${@:2}" ;;
```

- [ ] **Step 2: bin/srvctl syntax kontrolü**

Run: `bash -n bin/srvctl`
Expected: çıktı yok (OK).

- [ ] **Step 3: completions/srvctl.bash — komut listesine `trusted` ekle**

`commands="init domain deploy backup ssl security status monitor notify cloudflare ip user plugin webhook changelog version help"` satırını şununla değiştir:

```bash
    commands="init domain deploy backup ssl security status monitor notify cloudflare ip trusted user plugin webhook changelog version help"
```

Ve `ip)` case bloğundan sonra (mevcut `ip_cmds` bloğunun kapanışının ardından) ekle:

```bash
        trusted)
            local trusted_cmds="sync list"
            if [[ $COMP_CWORD -eq 2 ]]; then
                COMPREPLY=($(compgen -W "$trusted_cmds" -- "$cur"))
            fi
            ;;
```

- [ ] **Step 4: completions/srvctl.zsh — aynı eklemeyi zsh formatında yap**

`srvctl.zsh`'te komut listesine `trusted` ekle ve alt-komut tanımına (mevcut `ip` girdisinin yanına) şunu ekle:

```zsh
        trusted)
            compadd sync list
            ;;
```

(Not: zsh dosyasındaki mevcut `ip`/`backup` girdilerinin tam biçimini örnek al; yapı onlarla birebir aynı olmalı.)

- [ ] **Step 5: Manuel doğrula (dispatch bütünlüğü)**

Run: `grep -n "trusted)" bin/srvctl completions/srvctl.bash completions/srvctl.zsh`
Expected: üç dosyada da `trusted)` satırı görünür.

- [ ] **Step 6: Commit**

```bash
git add bin/srvctl completions/srvctl.bash completions/srvctl.zsh
git commit -m "feat(trusted): bin dispatch + bash/zsh completions"
```

---

## Task 6: init entegrasyonu (cron + ilk senkron) + README

**Files:**
- Modify: `lib/init.sh` (`_setup_cron_jobs`)
- Modify: `README.md`
- Test: `tests/test_trusted.sh` (yapısal grep assertion)

**Interfaces:**
- Consumes: `_trusted_sync` (Task 4), `TRUSTED_SYNC_ENABLED` (Task 1).

- [ ] **Step 1: Yapısal testi ekle** — `tests/test_trusted.sh` içinde `test_summary`'den ÖNCE:

```bash

# init.sh trusted cron + ilk senkronu içeriyor mu (yapısal)
assert_contains "$(cat "${REPO_ROOT}/lib/init.sh")" "srvctl trusted sync" "init.sh trusted cron satırı içerir"
```

- [ ] **Step 2: Testin başarısız olduğunu gör**

Run: `bash tests/test_trusted.sh`
Expected: FAIL — "init.sh trusted cron satırı içerir" assertion'ı FAIL.

- [ ] **Step 3: `_setup_cron_jobs`'a ekle** — `lib/init.sh`, `_setup_cron_jobs()` fonksiyonu içinde, backup cron bloğundan sonra (fonksiyon kapanışından `}` önce):

```bash

    # ─── Güvenilir edge-IP senkronu (Cloudflare + UptimeRobot) ───
    if [[ "${TRUSTED_SYNC_ENABLED:-true}" == "true" ]]; then
        crontab_content=$(crontab -l 2>/dev/null || true)
        if ! echo "$crontab_content" | grep -q "srvctl trusted sync"; then
            (echo "$crontab_content"; echo "30 2 * * * /usr/local/srvctl/bin/srvctl trusted sync >> /usr/local/srvctl/logs/trusted.log 2>&1") | crontab -
        fi
        # İlk senkron (ağ yoksa uyar-devam; init'i düşürme)
        # shellcheck disable=SC1090
        if source "${SRVCTL_ROOT}/lib/trusted.sh" 2>/dev/null && _trusted_sync >/dev/null 2>&1; then
            success "Güvenilir edge-IP listesi senkronize edildi"
        else
            warn "İlk güvenilir-IP senkronu yapılamadı (ağ?) — cron sonraki turda tazeleyecek"
        fi
    fi
```

- [ ] **Step 4: Testin geçtiğini gör**

Run: `bash tests/test_trusted.sh`
Expected: PASS.

- [ ] **Step 5: init.sh syntax kontrolü**

Run: `bash -n lib/init.sh`
Expected: çıktı yok (OK).

- [ ] **Step 6: README'yi güncelle** — `README.md`'de komut referansı bölümüne (ip/cloudflare civarı) ekle:

```markdown
### Güvenilir edge-IP senkronu (`srvctl trusted`)

Cloudflare ve UptimeRobot'un yayınladığı IP'leri otomatik allowlist'e ekler:
fail2ban `ignoreip` (bu IP'ler asla banlanmaz) + Cloudflare için nginx real-IP
restorasyonu (`set_real_ip_from` + `CF-Connecting-IP`). `srvctl init` günlük
cron kurar (`30 2 * * *`, default açık). Fetch başarısızsa son-iyi liste korunur.

| Komut | Açıklama |
|-------|----------|
| `srvctl trusted sync` | IP'leri şimdi çek + uygula |
| `srvctl trusted list` | Yönetilen IP'leri ve son senkronu göster |

Yapılandırma (conf/srvctl.conf, varsayılanlar load_config'te):
`TRUSTED_SYNC_ENABLED`, `TRUSTED_SOURCES`, `CLOUDFLARE_IPS_V4_URL`,
`CLOUDFLARE_IPS_V6_URL`, `UPTIMEROBOT_IPS_URL`.
```

- [ ] **Step 7: Tüm suite + commit**

```bash
bash tests/run.sh   # TÜM TEST DOSYALARI GEÇTİ
git add lib/init.sh README.md tests/test_trusted.sh
git commit -m "feat(trusted): init cron + ilk senkron entegrasyonu + README"
```

---

## HOST doğrulama (macOS/OrbStack'te yapılamaz — Multipass/UTM 22.04 veya 24.04)

Bu adımlar gerçek sunucuda elle doğrulanır (plan tamamlandıktan sonra):

- [ ] `curl -sf https://www.cloudflare.com/ips-v4` gerçek CF listesini döndürüyor; `srvctl trusted sync` çalışıp `/etc/srvctl/trusted/cloudflare.conf` + `uptimerobot.conf` üretiyor.
- [ ] **UptimeRobot URL teyidi:** `curl -sf "$UPTIMEROBOT_IPS_URL"` beklenen formatta (satır-başına IP) veri veriyor; vermezse conf'taki URL güncellenir.
- [ ] `/etc/fail2ban/jail.local` `ignoreip` satırı CF+UR IP'lerini içeriyor; `fail2ban-client get sshd ignoreip` (veya reload sonrası) yansıyor.
- [ ] `/etc/nginx/conf.d/srvctl-cloudflare-realip.conf` üretildi; `nginx -t` geçiyor; reload sonrası CF arkasından gelen istekte `$remote_addr` gerçek ziyaretçi IP'si.
- [ ] `crontab -l` `30 2 * * * ... srvctl trusted sync` satırını içeriyor.
- [ ] Ağ kesikken `srvctl trusted sync` mevcut listeleri BOZMUYOR (fail-safe).

---

## Self-Review

**Spec coverage:** Amaç (allowlist+real-ip) → Task 4 (ignoreip+realip apply). Kaynaklar/config → Task 1. Yönetilen durum ayrımı → Task 4 (ayrı state dosyaları, manuel whitelist'e dokunmaz). Fetch+fail-safe → Task 4 (sane-fail/fetch-fail → preserve). init+cron → Task 6. Test matrisi → Task 2/3/4. Kapsam-dışı (UFW/nginx-allow/origin-kilidi) → hiçbir task eklemiyor. ✔ Tüm spec bölümleri karşılandı.

**Placeholder tarama:** Tüm adımlar tam kod içeriyor; TBD/TODO yok. UptimeRobot URL "açık madde" HOST doğrulama adımı olarak somutlaştırıldı (config'te değiştirilebilir). ✔

**Type/isim tutarlılığı:** `_trusted_parse_validate`, `_trusted_sane <min> <file>`, `_trusted_render_realip`, `_trusted_compute_ignoreip <base> <files...>`, `_trusted_fetch <url> <dest> <name>`, `_trusted_apply_ignoreip`, `_trusted_apply_realip`, `_trusted_sync`, `_trusted_list`, `cmd_trusted` — tüm task'larda birebir aynı. State dosyaları `cloudflare.conf`/`uptimerobot.conf` her yerde tutarlı. Override env değişkenleri (`FAIL2BAN_JAIL_LOCAL`, `NGINX_CF_REALIP_CONF`, `SRVCTL_TRUSTED_FIXTURE_DIR`) apply ve test'te tutarlı. ✔
