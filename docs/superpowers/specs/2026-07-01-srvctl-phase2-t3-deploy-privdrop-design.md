# srvctl Faz 2 / T3 — Deploy Artefakt Gating + Privilege Drop — Tasarım

> **Tarih:** 2026-07-01
> **Bağlam:** Faz 2'nin üçüncü parçası. T1 (dosya-sahiplik modeli) tasarlandı + macOS alt-kümesi uygulandı; T7 (MAC/cgroups) ayrı spec'te. Bu doküman T3'ü kapsar.
> **Çalışma modu:** Tasarım + uygulama planı üretilir; **macOS-test edilebilir alt-küme** (`_deploy_assert_safe_shared` predikatı) uygulanır, **[HOST]** kısımları (runuser priv-drop, deploy reorder, uçtan-uca) gerçek Ubuntu'ya ertelenir.
> **Önkoşul okuma (uygulayan ajan):** `superpowers:writing-plans`; macOS-test edilebilir kısımlarda `superpowers:test-driven-development`.

## 1. Amaç ve kök-neden (RC2-exec + RC3-symlink)

Deploy pipeline'ı (`lib/deploy.sh:_deploy_run`) **root** olarak çalışır ve web-kullanıcısı-kontrollü artefaktları en tehlikeli şekilde tüketir:

- **`_run_hook`** ([deploy.sh:39-46](../../../lib/deploy.sh)): `bash "$hook_file"` ile `shared/hooks/{pre,post}-deploy.sh`'i **root** çalıştırır. T1 sonrası `shared/` web_user'a aittir → web kullanıcısı hook yazıp root-RCE elde eder.
- **composer** ([deploy.sh:146-149](../../../lib/deploy.sh)): root olarak, web-kontrollü `composer.json` üzerinde çalışır → `post-install-cmd`/plugin'ler root çalışır.
- **`shared/.env` symlink** ([deploy.sh:161-162](../../../lib/deploy.sh)) ve **`shared/writable` `chown -R`** ([deploy.sh:178-183](../../../lib/deploy.sh)): web kullanıcısı `shared/writable`'ı `/etc`'ye symlink yaparsa, root'un `chown -R web_user "${shared}/writable"` çağrısı symlink'i izleyip `/etc`'yi web_user'a chown eder → **yetki yükseltme**.

T3 **ayrıcalığı düşürür** (hook + composer per-domain web_user olarak çalışır) ve **symlink saldırılarını reddeder**.

## 2. Kapsam

| İçeride (T3) | Dışarıda |
|---|---|
| Hook çalıştırma → web_user (`runuser`) | `.deploy-repo` bütünlüğü + repo_url allowlist (Faz 1 + T1'de hazır) |
| Composer → web_user (release erken chown + `runuser`) | T7: MAC/cgroups + fail-closed audit (ayrı spec) |
| `shared/.env` + `shared/writable` symlink reddi | |

## 3. Privilege drop (hook + composer)

**Strateji — release'i erken chown et, sonra root-olmayan adımları web_user olarak çalıştır.** Mevcut akış composer'ı (adım 2) `chown` (adım 5)'ten ÖNCE çalıştırıyor; yani composer anında `release_dir` root-sahipli (git clone root). T3 chown'u clone'dan hemen sonraya çeker; ardından composer + hook'lar web_user olarak çalışır.

Yeni akış:
```
1. git clone (root)                  → release_dir root-owned
   chown -R web_user release_dir     → ERKEN (eskiden adım 5'teydi)
2. composer (web_user):  runuser -u "$web_user" -- sh -c 'cd "$rel" && composer install --no-dev ...'
3. pre-deploy hook (web_user):  _run_hook ... web_user → runuser -u "$web_user" -- bash "$hook"
4. shared bağla (symlink-kontrollü; §4)
5. (kalan izin ince-ayarı; release zaten web_user)
6. atomic switch (root)
7. health + post-deploy hook (web_user)
```

`_run_hook` imzası `web_user` alacak şekilde genişler: `_run_hook <hook_file> <release> <domain> <web_user>`; gövdesi `runuser -u "$web_user" -- bash "$hook_file"` (env: `RELEASE_DIR`/`DOMAIN` korunur). `web_user` `_deploy_run` içinde zaten `web_${sname}` olarak türetiliyor.

Meşru composer script'leri **korunur** (web_user'da çalışır; CI4/Laravel kırılmaz) ama artık root değil → lifecycle-script RCE root'a ulaşamaz.

## 4. Symlink reddi (`shared/.env`, `shared/writable`)

Yeni PREDİKAT (**[macOS-test edilebilir]**):
```
_deploy_assert_safe_shared <path>   # 0=güvenli, 1=güvensiz (symlink); exit YOK
```
Kural: path bir **symlink ise** 1 döner (root'un izleyip jail dışına çıkmasını engeller). Çağıran:
- `ln -sf "${shared}/.env" ...` ÖNCESİ: `_deploy_assert_safe_shared "${shared}/.env" || { warn "shared/.env symlink — atlandı (güvenlik)"; }` (symlink ise .env bağlama).
- `chown -R web_user "${shared}/writable"` ÖNCESİ: `_deploy_assert_safe_shared "${shared}/writable" || error "shared/writable symlink — deploy reddedildi (yetki-yükseltme riski)"`.

(Not: `chown -R` için **error** — bu en tehlikeli yol; `.env` için **skip+warn** yeterli, app .env'siz devam edebilir.)

## 5. Test stratejisi

**[macOS-TDD]:**
- `_deploy_assert_safe_shared`: geçici dizinde symlink oluştur → 1; normal dosya/dizin → 0; var olmayan yol → 1 (yoksa güvenli sayma). Tablo-tabanlı.
- Çağrı-yeri mantığı `lib/deploy.sh`'a girdiğinden, predikatın doğru yerlerde çağrıldığı diff incelemesiyle doğrulanır; gerçek `ln`/`chown` etkisi [HOST].

**[HOST] (Ubuntu root):**
- `runuser -u web_user -- composer/bash hook` gerçekten web_user olarak çalışıyor mu (`id` hook içinde web_user gösterir).
- Deploy uçtan-uca: clone → composer(web) → hook(web) → switch(root) → health.
- Symlink saldırısı: web_user `shared/writable`'ı `/etc`'ye symlink yapar → `srvctl deploy` **reddeder** (`/etc` chown EDİLMEZ); `shared/.env` symlink → atlanır + warn.
- Malicious `composer.json` (`post-install-cmd: rm -rf /`) → web_user olarak çalışır (root değil), root dosyalarına dokunamaz.

## 6. Etkilenen dosyalar

- `lib/deploy.sh` — `_deploy_assert_safe_shared` (yeni, predikat); `_run_hook` imzası + `runuser`; `_deploy_run` reorder (erken chown) + composer `runuser` + symlink kapıları.
- `tests/` — yeni: `test_deploy_safe_shared.sh` (predikat).
- `README.md` — deploy güvenlik notu (hook/composer web_user olarak çalışır; symlink reddi).
- `docs/superpowers/plans/2026-07-01-srvctl-phase2-t3-HOST-checklist.md` — host uçtan-uca doğrulama.

## 7. Faz 2 kalan parça (T3 sonrası, ayrı spec)

- **T7** — MAC/cgroups gerçek yapma: per-domain FPM unit + `Slice=`; AppArmor'ı `apparmor_hat` ile worker'a bağlama + `init.sh` `systemctl enable --now apparmor`; `|| true` yerine gerçek exit-kod; audit'i varlık-kontrolünden enforcement-kontrolüne (`aa-status --json`, ControlGroup, Seccomp); `install.sh`'a `cgroups seccomp` template'leri; modsec 941xxx (XSS) `/admin/` daraltma.
