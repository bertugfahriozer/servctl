# srvctl Faz 2 / T1 — Dosya-Sahiplik Modeli + harden-fs Migrasyonu — Tasarım

> **Tarih:** 2026-06-30
> **Bağlam:** Faz 1 güvenlik sertleştirmesi tamamlandı (parse-not-source, merkezi doğrulama, webhook fail-closed, secret/backup kilidi — bkz. `2026-06-30-srvctl-security-hardening-phase1-design.md`). Bu doküman **Faz 2'nin keystone'u T1'i** kapsar. T3 (deploy priv-drop) ve T7 (MAC/cgroups + fail-closed audit) ayrı spec'lerde ele alınacaktır.
> **Çalışma modu:** Bu oturumda **tasarım + uygulama planı** üretilir; **uygulama gerçek bir Ubuntu host'ta** yapılacaktır. T1'in çekirdeği (chown/chmod etkileri, migrasyon sonrası site çalışması, chroot) macOS'ta doğrulanamaz; yalnız saf-bash plan/karar mantığı unit-test edilebilir.
> **Önkoşul okuma (uygulayan ajan):** `superpowers:writing-plans` ile task-task plan üret; uygulamada `superpowers:test-driven-development` (yalnız macOS-test edilebilir kısımlar için).

## 1. Amaç ve kök-neden (RC1)

Faz 1 incelemesi dört kök-neden buldu. RC1 hepsini silahlandıran tek gerçektir:

> **RC1** — `lib/domain.sh:276` `chown -R "${web_user}:${web_user}" "${base}"`: per-domain base dizini `/var/www/<domain>/` web kullanıcısına ait kalır. Unix'te bir dizinin **sahibi**, içindeki herhangi bir girdiyi (dosyanın kendi modu/sahibi ne olursa olsun) silip yeniden oluşturabilir. Bu yüzden web kullanıcısı root'a ait `.credentials`/`.srvctl-meta`/`.deploy-repo`'yu silip arbitrary içerikle yeniden yazabilir.

Faz 1, bu dosyaların **tüketimini** sertleştirdi (artık `source` edilmiyor, identifier'lar `safe_name`'den türetiliyor, php_version doğrulanıyor, repo_url allowlist'leniyor). **T1, kök-nedeni yapısal olarak kapatır:** base dizinini `root:root` yaparak dosyaların **değiştirilmesini** engeller ve `assert_root_owned_path`'i fail-closed kapıya çevirir.

**İlke — minimal kırılım:** Yalnız base dizininin kendisi + chroot sistem dizinleri sahiplik değiştirir. Web uygulamasının yazdığı dizinler (`public_html`, `private`, `private/writable`, `tmp`, `sessions`, `logs`) **web_user'a ait kalır** → hiçbir yazma erişimi kaybedilmez.

## 2. Kapsam

| İçeride (T1) | Dışarıda (ayrı spec) |
|---|---|
| base + chroot sistem dizinleri `root:root`; leaf'ler web_user | T3: deploy hook execution gating + priv-drop + symlink reddi |
| Kontrol dosyalarının (base'de) tamper-proof olması | T7: AppArmor attach, cgroups Slice, fail-closed audit, install.sh |
| `assert_root_owned_path` fail-closed + "hardened" marker | (T3'te) shared/hooks execution; releases/ sahiplik modeli |
| `srvctl security harden-fs` migrasyon komutu (dry-run/apply/revert/--all) | |
| `_domain_add` provisioning'i yeni modele geçirme | |

Not: `.deploy-repo` **dosya bütünlüğü** T1 ile gelir (base root-owned → silinemez). Hook **çalıştırma** gating'i T3'e aittir.

## 3. Yeni sahiplik modeli

Mevcut provisioning ([domain.sh:266-288](../../../lib/domain.sh)) tüm base'i (chroot sistem dizinleri dahil) web_user'a chown ediyor. Yeni model:

| Yol | Sahip | Mod | Gerekçe |
|---|---|---|---|
| `base` (`/var/www/<d>/`) | **root:root** | **751** | web_user = "other" → yalnız traverse (x); base'de write/unlink YOK → kontrol dosyaları korunur |
| `public_html` | web_user:web_user | 750 (+www-data ACL rx) | web app web root'u; kırılım yok |
| `private`, `private/writable/*` | web_user:web_user | 750 / 770 | uygulama kodu + yazılabilir |
| `logs`, `tmp`, `sessions`, `releases`, `shared` | web_user:web_user | 750 / 770 | mevcut davranış |
| chroot sistem: `dev`, `etc`, `lib`, `lib64`, `usr` | **root:root** | 755 | chroot-escape sertleştirme; web_user lib/loader değiştiremez |
| `.credentials` | root:root | 600 | base root-owned → tamper-proof |
| `.srvctl-meta` | root:root | 644 | aynı |
| `.deploy-repo` | root:root | 600 | aynı |
| `/usr/local/srvctl/state/<d>/` | root:root | 700 | hardened-marker + fs-before kayıtları (web-erişimi yok) |

**`751` seçimi:** `rwxr-x--x` — owner(root) rwx, group(root) r-x, other(web_user) `--x`. web_user base'i listeleyemez/yazamaz ama bildiği alt-yollara traverse edebilir; chroot için yeterli (kernel base'e o+x ile girer). Alternatif `root:web_user 750` (web_user grup, r-x) — listeleme verir ama write vermez; 751 daha az ayrıcalıklı olduğu için tercih.

**Ortak helper:** Tüm sahiplik/izin mantığı `_domain_apply_fs_ownership <base> <web_user>` fonksiyonunda toplanır; `_domain_add` (yeni domain'ler doğuştan hardened) ve `harden-fs` (mevcutlar) **aynı** helper'ı çağırır (DRY). Helper ayrıca **plan modunda** (`SRVCTL_FS_PLAN_ONLY=1`) hiçbir şey uygulamadan yapılacak değişikliklerin listesini stdout'a yazabilir (dry-run + unit-test için).

## 4. assert_root_owned_path fail-closed + migrasyon ordering

**Sorun:** fail-closed kapı şimdi açılırsa, henüz migrate edilmemiş eski domain'ler (base hâlâ web-owned) **her okumada hata verir** → kırılır.

**Çözüm — per-domain "hardened" marker:** root-only `/usr/local/srvctl/state/<d>/hardened` dosyası, bir domain'in yeni modele geçtiğini işaretler.

`assert_root_owned_path` saf predikat kalır (Faz 1'deki gibi: root-owned zincir → 0, değilse 1). **Politika çağıranda:**
- `read_credentials` / `read_meta` / `.deploy-repo` okuması, bir `_require_owned_or_warn <domain> <file>` sarmalayıcısı çağırır:
  - **hardened marker VAR** ve `assert_root_owned_path` başarısız → **`error`** (gerçek tamper; fail-closed).
  - **hardened marker YOK** (migrate edilmemiş) → **`warn "Domain hardened değil — srvctl security harden-fs ${domain} çalıştırın"`** + devam (Faz 1 davranışı korunur).
  - başarılı → sessiz devam.

Böylece kodu enable etmek eski domain'leri kırmaz; her domain `harden-fs --apply` ile tek tek fail-closed korumaya geçer.

## 5. `srvctl security harden-fs` komutu

`cmd_security` içinde yeni alt-komut. Kullanım:

```
srvctl security harden-fs <domain>            # dry-run (varsayılan): planı göster, dokunma
srvctl security harden-fs <domain> --apply    # uygula (before-state kaydet, sonra chown/chmod, marker yaz)
srvctl security harden-fs --all [--apply]     # tüm domain'ler
srvctl security harden-fs <domain> --revert   # kayıtlı before-state'ten geri yükle
```

**Dry-run (varsayılan):** `_domain_apply_fs_ownership` plan modunda çağrılır; "şu yol → şu sahip/mod (mevcut: …)" satırları yazılır. Hiçbir şey değişmez. Çıkış 0.

**--apply akışı:**
1. `domain_exists` doğrula.
2. `secure_dir /usr/local/srvctl/state/<d> 700`.
3. Mevcut sahiplik/izinleri kaydet: base + tüm doğrudan çocukları için `_stat_owner`/`_stat_mode` → `state/<d>/fs-before.txt` (revert için).
4. `_domain_apply_fs_ownership <base> <web_user>` (gerçek chown/chmod).
5. `secure_file state/<d>/hardened 600` (marker; içerik: tarih + sürüm).
6. `nginx -t` sağlık kontrolü (uyarı amaçlı; başarısızsa operatöre bildir, otomatik revert ÖNERME — sahiplik nginx'i bozmaz ama operatör görsün).
7. Özet + "siteyi doğrula" notu.

**Idempotent:** marker varsa ve base zaten root-owned → "zaten hardened" + no-op (yine de plan farkı varsa uygula).

**--revert:** `state/<d>/fs-before.txt`'ten satır satır okuyup `chown`/`chmod` geri uygula; marker'ı sil. Güvenlik ağı.

**--all:** `list_all_domains` üzerinde döngü; her biri için dry-run veya apply. Bir domain hata verirse diğerlerini kesme (`|| warn`).

## 6. Provisioning güncellemesi (yeni domain'ler)

`_domain_add`'in mevcut chown/chmod bloğu ([domain.sh:276-288](../../../lib/domain.sh)) `_domain_apply_fs_ownership <base> <web_user>` çağrısıyla değiştirilir; ardından `state/<d>/hardened` marker yazılır. Böylece **yeni domain'ler doğuştan hardened** ve fail-closed kapı onlarda hemen aktif olur. `.credentials`/`.srvctl-meta` yazımı zaten root:root (Faz 1).

## 7. Test stratejisi

**macOS-unit-testable (saf-bash mantık):**
- `_domain_apply_fs_ownership` **plan modu** (`SRVCTL_FS_PLAN_ONLY=1`): geçici ağaca karşı, hangi yol → hangi hedef sahip/mod listesini üretmeli (tablo-tabanlı assert). Gerçek chown gerektirmez.
- `harden-fs <domain>` (apply'siz) dry-run çıktısı: beklenen plan satırlarını içermeli.
- "hardened" marker + `_require_owned_or_warn` karar mantığı: (marker var/yok) × (root-owned/değil) → error/warn/ok matrisi. `_stat_owner`/`assert_root_owned_path` stub'lanarak veya geçici-ağaç ile test edilir.
- fs-before kayıt/revert biçimi: kaydedilen satırların parse edilip geri uygulanabilir olması (gerçek chown olmadan, kayıt formatı round-trip testi).

**Entegrasyon (Ubuntu root host — uygulama aşaması):**
- Gerçek `chown`/`chmod`; migrasyon sonrası: web app yazabiliyor mu (writable/cache/logs/sessions/uploads), `public_html` serve ediliyor mu, chroot çalışıyor mu, FPM worker başlıyor mu.
- Tamper denemesi: hardened domain'de web_user `.credentials`'ı silmeyi denesin → **başarısız** (base root-owned). `assert_root_owned_path` fail-closed → tampered durumda `error`.
- `harden-fs --all` çok domain'de; `--revert` geri yükleme; idempotency (iki kez apply).

## 8. Etkilenen dosyalar

- `lib/domain.sh` — `_domain_apply_fs_ownership` helper (yeni); `_domain_add` provisioning bloğu (276-288) bu helper'a + marker yazımına geçer.
- `lib/security.sh` — `cmd_security` içine `harden-fs` alt-komutu + `_security_harden_fs` (dry-run/apply/revert/--all).
- `lib/core.sh` — `_require_owned_or_warn <domain> <file>` politika sarmalayıcısı (marker + assert_root_owned_path); `read_credentials`/`read_meta` bunu çağırır; `secure_dir`/`secure_file` (Faz 1) yeniden kullanılır.
- `lib/deploy.sh` — `.deploy-repo` okuması `_require_owned_or_warn` ile kapılanır (hook execution gating T3'te).
- `tests/` — yeni: `test_fs_ownership_plan.sh`, `test_harden_fs_dryrun.sh`, `test_owned_marker_policy.sh`, `test_fs_before_revert.sh`.
- `completions/`, `README.md` — `harden-fs` komutu (uygulama aşamasında).

## 9. Faz 2 kalan parçalar (T1 sonrası, ayrı spec)

- **T3** — deploy artefakt gating: `shared/hooks/` root-owned + `runuser` ile web-user olarak çalıştırma; composer `--no-scripts`/priv-drop; `shared/.env`/`shared/writable` symlink reddi. (`.deploy-repo` bütünlüğü + repo_url allowlist Faz 1/T1'de hazır.)
- **T7** — MAC/cgroups gerçek yapma: per-domain FPM unit + `Slice=`; AppArmor'ı `apparmor_hat` ile worker'a bağlama + `init.sh` `systemctl enable --now apparmor`; `|| true` yerine gerçek exit-kod; audit'i varlık-kontrolünden enforcement-kontrolüne (`aa-status --json`, ControlGroup, Seccomp); `install.sh`'a `cgroups seccomp` template'leri; modsec 941xxx (XSS) `/admin/` daraltma.
