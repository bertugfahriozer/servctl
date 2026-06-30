# srvctl Faz 2 / T3 — Deploy Privilege Drop + Symlink Gating — Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy pipeline'ının web-kullanıcısı-kontrollü artefaktlarını root olarak çalıştırmasını durdurmak: hook + composer'ı per-domain web_user olarak (`runuser`) çalıştırmak ve `shared/.env`/`shared/writable` üzerindeki symlink saldırılarını (chown -R /etc yetki-yükseltmesi) reddetmek.

**Architecture:** Yeni `_deploy_assert_safe_shared` predikatı symlink'leri reddeder (saf, macOS-test edilebilir). `_run_hook` ve composer `runuser -u web_user` ile çalışır; deploy akışı yeniden sıralanır (release dizini composer'dan ÖNCE web_user'a chown edilir) böylece root-olmayan adımlar contained kalır.

**Tech Stack:** Bash (pure), mevcut test harness, `runuser` (HOST), `git`/`composer` (HOST). Hedef Ubuntu 22.04 root; geliştirme/test macOS.

## Yürütme ortamları

- **[macOS-TDD]** — saf-bash mantık; `bash tests/run.sh` ile şimdi test edilebilir (Task 1).
- **[macOS-code]** — kod düzenlemesi macOS'ta yapılır + `bash -n` + suite regresyonu; gerçek `ln`/`chown`/`runuser` etkisi [HOST] (Task 2 wiring).
- **[HOST]** — `runuser`/composer/deploy uçtan-uca; yalnız Ubuntu root host'ta doğrulanır (Task 3, 4).

> **NOT (bu oturum):** Kullanıcı talebiyle bu oturumda commit ATILMAZ; aşağıdaki commit adımları planın standart referansıdır. Uygulamada değişiklikler test edilip working-tree'de bırakılır.

## Global Constraints

- Tüm kullanıcıya dönük string'ler ve yorumlar **Türkçe**.
- Her script `set -euo pipefail`; beklenen başarısızlıkta `|| true`.
- `error` ÇIKAR; predikatlar `return 0/1`, asla `exit`. Çağıran: `pred ... || error`/`|| warn`.
- Tests macOS'ta (root yok) `bash tests/run.sh`; harness `tests/lib.sh`: assert_eq/contains/not_contains/ok/fail/test_summary; assert_ok/assert_fail komutu CARİ kabukta çalıştırır → test edilen fonksiyon RETURN etmeli, exit DEĞİL.
- `web_user` = `web_$(safe_name "$domain")` (mevcut türetme); `_deploy_run` zaten `web_user` değişkenini bu şekilde kuruyor.
- Commit mesajları Türkçe, şu satırla biter: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

## Dosya Yapısı

- `lib/deploy.sh` — `_deploy_assert_safe_shared` (yeni predikat); `_run_hook` imza+runuser; `_deploy_run` reorder + composer runuser + symlink kapıları.
- `tests/test_deploy_safe_shared.sh` — predikat testi (yeni).
- `README.md` — deploy güvenlik notu.
- `docs/superpowers/plans/2026-07-01-srvctl-phase2-t3-HOST-checklist.md` — host uçtan-uca.

---

### Task 1: `_deploy_assert_safe_shared` predikatı **[macOS-TDD]**

**Files:**
- Modify: `lib/deploy.sh` (`_deploy_validate_repo_url`'den sonra, dosya başı yardımcı bölgesi)
- Test: `tests/test_deploy_safe_shared.sh`

**Interfaces:**
- Consumes: hiçbiri.
- Produces: `_deploy_assert_safe_shared <path>` PREDİKAT — symlink ise (dangling dahil) 1; var olmayan yol 1; normal dosya/dizin 0. exit YOK. Task 2 çağırır.

- [ ] **Step 1: Başarısız testi yaz** — `tests/test_deploy_safe_shared.sh`:

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/deploy.sh"

d="$(mktemp -d)"
touch "${d}/regular"
mkdir "${d}/dir"
ln -s /etc "${d}/evil"            # symlink (mevcut hedef)
ln -s /yok_boyle_bir_yol "${d}/dangling"  # dangling symlink

# normal dosya/dizin → güvenli (0)
assert_ok   _deploy_assert_safe_shared "${d}/regular"
assert_ok   _deploy_assert_safe_shared "${d}/dir"
# symlink → güvensiz (1)
assert_fail _deploy_assert_safe_shared "${d}/evil"
assert_fail _deploy_assert_safe_shared "${d}/dangling"
# var olmayan → güvensiz (1)
assert_fail _deploy_assert_safe_shared "${d}/yok"

rm -rf "$d" "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Çalıştır, FAIL gör** — Run: `bash tests/test_deploy_safe_shared.sh` — Beklenen: FAIL (`_deploy_assert_safe_shared` tanımsız → assert_ok'lar düşer).

- [ ] **Step 3: Uygula** — `lib/deploy.sh`'ta `_deploy_validate_repo_url` tanımının ALTINA ekle:

```bash
# shared/ artefaktı root operasyonu (ln/chown -R) için güvenli mi?
# PREDİKAT: 0=güvenli, 1=güvensiz. Symlink (dangling dahil) reddedilir —
# yoksa web_user 'shared/writable'ı /etc'ye symlink yapıp 'chown -R' ile
# /etc'yi ele geçirebilir (yetki yükseltme). Var olmayan yol da güvensiz sayılır.
_deploy_assert_safe_shared() {
    local path="$1"
    [[ -L "$path" ]] && return 1
    [[ -e "$path" ]] || return 1
    return 0
}
```

- [ ] **Step 4: Çalıştır, PASS gör** — Run: `bash tests/test_deploy_safe_shared.sh`; ayrıca `bash tests/run.sh` (regresyon yok).

- [ ] **Step 5: Commit** *(bu oturumda atlanır — bkz. NOT)*
```bash
git add lib/deploy.sh tests/test_deploy_safe_shared.sh
git commit -m "$(cat <<'EOF'
feat(T3): _deploy_assert_safe_shared — shared/ symlink reddi predikatı

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: shared/.env + shared/writable symlink kapıları **[macOS-code / HOST-behavior]**

**Files:**
- Modify: `lib/deploy.sh:161-183` (`_deploy_run` "Shared dosyalar" + "İzinler" blokları)
- Test: yok (gerçek ln/chown [HOST]); macOS: `bash -n` + suite yeşil + Task 1 predikatı zaten test edildi.

**Interfaces:**
- Consumes: `_deploy_assert_safe_shared` (Task 1).
- Produces: yok.

- [ ] **Step 1: Uygula** — `lib/deploy.sh`'ta şu bloğu:

```bash
    if [[ -f "${shared_dir}/.env" ]]; then
        ln -sf "${shared_dir}/.env" "${release_dir}/.env"
        success ".env bağlandı"
    else
        warn ".env bulunamadı: ${shared_dir}/.env"
    fi
```

şununla DEĞİŞTİR (`.env` symlink ise atla + warn):

```bash
    if [[ -e "${shared_dir}/.env" ]] && _deploy_assert_safe_shared "${shared_dir}/.env"; then
        ln -sf "${shared_dir}/.env" "${release_dir}/.env"
        success ".env bağlandı"
    elif [[ -L "${shared_dir}/.env" ]]; then
        warn "shared/.env bir symlink — güvenlik nedeniyle atlandı"
    else
        warn ".env bulunamadı: ${shared_dir}/.env"
    fi
```

Ardından `shared/writable` chown bloğunu:

```bash
    if [[ -d "${shared_dir}/writable" ]]; then
        chmod -R 770 "${shared_dir}/writable"
        chown -R "${web_user}:${web_user}" "${shared_dir}/writable"
    fi
```

şununla DEĞİŞTİR (`chown -R` ÖNCESİ symlink reddi — error):

```bash
    if [[ -d "${shared_dir}/writable" ]]; then
        _deploy_assert_safe_shared "${shared_dir}/writable" \
            || error "shared/writable bir symlink — deploy reddedildi (chown -R yetki-yükseltme riski)"
        chmod -R 770 "${shared_dir}/writable"
        chown -R "${web_user}:${web_user}" "${shared_dir}/writable"
    fi
```

Ayrıca "Shared dosyalar" bloğundaki `shared/writable` symlink kurma kısmında ([deploy.sh:167-174]) `ln -sf "${shared_dir}/writable" ...` öncesinde de symlink-güvenli olduğunu doğrula: blok başına `_deploy_assert_safe_shared "${shared_dir}/writable" || error "shared/writable symlink — deploy reddedildi"` ekle (yalnız `[[ -d ]]` dalında).

- [ ] **Step 2: macOS kontrol** — Run: `bash -n lib/deploy.sh`; `bash tests/run.sh` — Beklenen: sözdizimi OK, suite yeşil (deploy akışı testlerde çalıştırılmıyor, regresyon yok).

- [ ] **Step 3: Commit** *(bu oturumda atlanır)*
```bash
git add lib/deploy.sh
git commit -m "$(cat <<'EOF'
güvenlik(T3): shared/.env + shared/writable symlink kapıları (chown -R escape reddi)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4 [HOST]: Ubuntu doğrulama** — web_user `shared/writable`'ı `/etc`'ye symlink yapar → `srvctl deploy` `chown` ÖNCESİ reddeder (`/etc` chown EDİLMEZ); `shared/.env` symlink → atlanır + warn.

---

### Task 3: `_run_hook` privilege drop (runuser) **[HOST]**

**Files:**
- Modify: `lib/deploy.sh:39-46` (`_run_hook`); çağrı yerleri `:156`, `:214`
- Test: yok (runuser HOST); macOS: `bash -n` + suite yeşil.

**Interfaces:**
- Consumes: hiçbiri.
- Produces: `_run_hook <hook_file> <release> <domain> <web_user>` — hook'u `runuser -u "$web_user" -- bash "$hook_file"` ile web_user olarak çalıştırır.

- [ ] **Step 1: Uygula** — `_run_hook`'u:

```bash
_run_hook() {
    local hook_file="$1" release="$2" domain="$3"
    if [[ -f "$hook_file" ]]; then
        info "Hook çalıştırılıyor: $(basename "$hook_file")"
        RELEASE_DIR="$release" DOMAIN="$domain" bash "$hook_file" \
            || warn "Hook hata döndürdü: $(basename "$hook_file")"
    fi
}
```

şununla DEĞİŞTİR (web_user olarak çalıştır):

```bash
_run_hook() {
    local hook_file="$1" release="$2" domain="$3" web_user="$4"
    if [[ -f "$hook_file" ]]; then
        info "Hook çalıştırılıyor (kullanıcı: ${web_user}): $(basename "$hook_file")"
        runuser -u "$web_user" -- env RELEASE_DIR="$release" DOMAIN="$domain" bash "$hook_file" \
            || warn "Hook hata döndürdü: $(basename "$hook_file")"
    fi
}
```

İki çağrı yerini güncelle — `:156` ve `:214`:
```bash
    _run_hook "${shared_dir}/hooks/pre-deploy.sh" "${release_dir}" "${domain}" "${web_user}"
```
```bash
    _run_hook "${shared_dir}/hooks/post-deploy.sh" "${release_dir}" "${domain}" "${web_user}"
```

- [ ] **Step 2: macOS kontrol** — Run: `bash -n lib/deploy.sh`; `bash tests/run.sh` yeşil.

- [ ] **Step 3: Commit** *(bu oturumda atlanır)*
```bash
git add lib/deploy.sh
git commit -m "$(cat <<'EOF'
güvenlik(T3): deploy hook'larını web_user olarak çalıştır (runuser, root-RCE reddi)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4 [HOST]: Ubuntu doğrulama** — `shared/hooks/pre-deploy.sh` içine `id -un > /tmp/hookwho` koy → deploy sonrası `cat /tmp/hookwho` = `web_<domain>` (root DEĞİL).

---

### Task 4: Deploy reorder + composer privilege drop **[HOST]**

**Files:**
- Modify: `lib/deploy.sh` (`_deploy_run`: clone sonrası erken chown; composer bloğu `:146-152`; izin bloğu `:177-184` sadeleşir)
- Test: yok (composer/chown HOST); macOS: `bash -n` + suite yeşil.

**Interfaces:**
- Consumes: hiçbiri. Produces: yok.

- [ ] **Step 1: Uygula** — Clone bloğundan ([deploy.sh:137-142]) HEMEN SONRA, composer'dan ÖNCE release dizinini web_user'a chown et:

```bash
    success "Clone tamamlandı"

    # Privilege drop için release'i erken web_user'a chown et (composer+hook web_user olarak çalışacak)
    chown -R "${web_user}:${web_user}" "${release_dir}"
```

Composer bloğunu ([deploy.sh:146-149]):

```bash
    if [[ -f "${release_dir}/composer.json" ]] && command -v composer &>/dev/null; then
        ( cd "${release_dir}" && composer install --no-dev --optimize-autoloader --no-interaction --quiet 2>/dev/null ) \
            && success "Composer paketleri yüklendi" \
            || warn "Composer install hatası"
    else
```

şununla DEĞİŞTİR (web_user olarak):

```bash
    if [[ -f "${release_dir}/composer.json" ]] && command -v composer &>/dev/null; then
        runuser -u "${web_user}" -- sh -c "cd '${release_dir}' && composer install --no-dev --optimize-autoloader --no-interaction --quiet" 2>/dev/null \
            && success "Composer paketleri yüklendi (kullanıcı: ${web_user})" \
            || warn "Composer install hatası"
    else
```

İzin bloğundan ([deploy.sh:177-179]) `chown -R "${web_user}..." "${release_dir}"` satırını KALDIR (artık clone sonrası yapılıyor); `chmod -R 750 "${release_dir}"` KALIR. (shared/writable chown'u Task 2'de symlink-kapılı haliyle KALIR.)

- [ ] **Step 2: macOS kontrol** — Run: `bash -n lib/deploy.sh`; `bash tests/run.sh` yeşil.

- [ ] **Step 3: Commit** *(bu oturumda atlanır)*
```bash
git add lib/deploy.sh
git commit -m "$(cat <<'EOF'
güvenlik(T3): composer'ı web_user olarak çalıştır + release'i erken chown (priv-drop)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4 [HOST]: Ubuntu doğrulama** — `composer.json`'a `"scripts": {"post-install-cmd": "id -un > /tmp/cwho"}` koy → deploy sonrası `cat /tmp/cwho` = `web_<domain>`; malicious `post-install-cmd: "rm -rf /etc/srvctl"` web_user olarak çalışır → `/etc/srvctl`'e dokunamaz.

---

### Task 5: README + host kontrol listesi **[docs]**

**Files:**
- Modify: `README.md` (deploy güvenlik notu)
- Create: `docs/superpowers/plans/2026-07-01-srvctl-phase2-t3-HOST-checklist.md`

**Interfaces:** Consumes/Produces: yok.

- [ ] **Step 1: README** — Deploy bölümüne not: "Deploy hook'ları ve composer per-domain web kullanıcısı olarak çalışır (root değil); `shared/.env`/`shared/writable` symlink ise reddedilir."

- [ ] **Step 2: Host kontrol listesi** — Task 2/3/4 [HOST] doğrulamalarını tek e2e senaryoda topla: (1) deploy çalışır; (2) hook+composer `id` = web_user; (3) symlink saldırısı (`shared/writable`→`/etc`) reddedilir, `/etc` chown edilmez; (4) malicious composer script root dosyalarına dokunamaz; (5) sağlık kontrolü + rollback hâlâ çalışır.

- [ ] **Step 3: macOS kontrol** — `bash tests/run.sh` yeşil; `bash -n` README değil ama completions değişmedi.

- [ ] **Step 4: Commit** *(bu oturumda atlanır)*
```bash
git add README.md docs/superpowers/plans/2026-07-01-srvctl-phase2-t3-HOST-checklist.md
git commit -m "$(cat <<'EOF'
docs(T3): deploy priv-drop README notu + host e2e kontrol listesi

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review (spec kapsama)

Spec (`2026-07-01-srvctl-phase2-t3-deploy-privdrop-design.md`) → task:
- **§3 privilege drop** → Task 3 (hook runuser) + Task 4 (composer runuser + reorder). **§4 symlink reddi** → Task 1 (predikat) + Task 2 (wiring). **§5 test** → Task 1 macOS-TDD; Task 2-4 [HOST] doğrulama + Task 5 e2e. **§6 dosyalar** → tüm task'lar.
- **İsim tutarlılığı:** `_deploy_assert_safe_shared`, `_run_hook(<...> web_user)`, `web_user=web_$(safe_name)` — task'lar arası birebir.
- **macOS/HOST ayrımı:** yalnız Task 1 tam macOS-TDD; Task 2 macOS-code (regresyon) + HOST-behavior; Task 3-4 HOST. Doğru işaretli.
- **Kapsam:** yalnız T3; T7 spec §7'de ayrı.
