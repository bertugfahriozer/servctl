# srvctl Faz 2 / T7a — Per-Domain FPM Master Unit (AppArmor + cgroups attach) — Tasarım

> **Tarih:** 2026-07-01
> **Bağlam:** Faz 2'nin dördüncü parçası. T1 (sahiplik) + T3 (deploy priv-drop) tasarlandı + macOS alt-kümeleri uygulandı. Bu doküman T7'nin mimari çekirdeği **T7a**'yı kapsar; T7b (fail-closed audit) ve T7c (install.sh template'leri + modsec daraltma) ayrı spec'lerde.
> **Çalışma modu:** Tasarım + plan; **küçük macOS-test edilebilir alt-küme** (template render mantığı) uygulanır, **[HOST]** (gerçek systemd unit, AppArmor enforce, cgroups) Ubuntu'ya ertelenir.
> **Önkoşul okuma (uygulayan ajan):** `superpowers:writing-plans`; macOS-test edilebilir kısımlarda `superpowers:test-driven-development`.

## 1. Amaç ve kök-neden (RC4 — inert MAC/cgroups)

Faz 1 incelemesi "reklamı yapılan ama çalışmayan" iki katman buldu:

- **AppArmor inert:** profil `srvctl-<sname>` standalone *named* profile'dır; `templates/php-fpm/pool.conf.tpl`'de `apparmor_hat` yok ve profil php-fpm binary'sine path-attach edilmemiş. Tek paylaşılan `php<ver>-fpm.service` worker'ları **unconfined** çalışır. `domain.sh:442-446` hataları `|| true` ile yutup koşulsuz "enforce modda" yazar (yanlış güvence).
- **cgroups inert:** per-domain `srvctl-<sname>.slice` oluşturulur ama hiçbir process içine konmaz (FPM service'te `Slice=` yok). Tek paylaşılan FPM tüm domain'lere hizmet eder → `MemoryMax`/`TasksMax` hiçbir domain'i kısıtlamaz.

**Kök-neden:** Tek paylaşılan FPM master, per-domain MAC/cgroups attach'ını imkânsız kılar. **T7a, her domain'e kendi FPM master systemd unit'ini verir;** systemd'nin `AppArmorProfile=` ve `Slice=` direktifleri attach'ı zarifçe çözer.

## 2. Kapsam

| İçeride (T7a) | Dışarıda |
|---|---|
| `srvctl-fpm-<sname>.service` per-domain unit | T7b: fail-closed audit (bu unit'leri doğrular) — ayrı spec |
| `fpm-master.conf.tpl` (global + pool) | T7c: install.sh cgroups/seccomp template'leri + modsec daraltma |
| systemd `AppArmorProfile=` + `Slice=` attach | seccomp drop-in (mevcut `_apply_seccomp_hardening` korunur) |
| provisioning/php-switch/remove entegrasyonu | |
| `srvctl security harden-fpm` migrasyonu | |

## 3. Yeni FPM modeli

**Mevcut:** `pool.conf.tpl` → `/etc/php/<ver>/fpm/pool.d/<sname>.conf`; paylaşılan `php<ver>-fpm.service` çalıştırır. Socket `/run/php/php<ver>-fpm-<sname>.sock`.

**Yeni:** Her domain kendi FPM master'ı:
- **`/etc/srvctl/fpm/<sname>.conf`** — yeni `templates/php-fpm/fpm-master.conf.tpl`'den render. İçerik: `[global]` (pid `/run/srvctl/fpm-<sname>.pid`, error_log, daemonize=no) + **mevcut `pool.conf.tpl` pool bölümü** (chroot, user=web_user, listen socket, pm, php_admin_value...). pool.conf.tpl içeriği değişmez; yalnızca bir `[global]` başlığıyla sarılır.
- **`srvctl-fpm-<sname>.service`** — `templates/systemd/srvctl-fpm.service.tpl`'den per-domain render:
  ```ini
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
  [Install]
  WantedBy=multi-user.target
  ```
- **Socket `/run/php/php<ver>-fpm-<sname>.sock` değişmez** → nginx `fastcgi_pass` **dokunulmaz** (vhost template'leri değişmez).
- Paylaşılan `php<ver>-fpm.service` kurulu kalır; srvctl domain'leri artık oraya pool yazmaz (kendi unit'lerini kullanır).

PHP sürümü unit'in `ExecStart`'ına gömülü olduğundan unit **per-domain üretilir** (template değil, render edilmiş dosya).

## 4. AppArmor & cgroups attach

- **AppArmor:** Profil yine `apparmor_parser -r` ile yüklenir; `AppArmorProfile=srvctl-<sname>` systemd direktifi unit process'lerini exec'te bu profile'a geçirir. `profile.tpl`'e küçük eklemeler: FPM master'ın okuduğu/yazdığı yollar — `/etc/srvctl/fpm/<sname>.conf` (r), `/run/srvctl/fpm-<sname>.pid` (rw), socket (zaten rw). `flags=(attach_disconnected)` korunur.
- **cgroups:** `Slice=srvctl-<sname>.slice`; `srvctl.slice` parent zaten `init.sh:_setup_cgroups`'ta var. `_apply_cgroups_slice`/`_domain_resources` `MemoryMax`/`TasksMax`'i slice drop-in'ine yazar (artık unit slice'a ait olduğundan etkili).
- **Fail-open mesaj kaldırılır:** `domain.sh:442-446`'daki `aa-enforce ... || true` + koşulsuz "enforce modda" yerine: profil yükle → unit start → `systemctl is-active srvctl-fpm-<sname>` ve `aa-status | grep enforce` gerçek kontrol; başarısızsa `warn`/`error` (yanlış güvence yok). (Tam fail-closed audit T7b'de.)

## 5. Entegrasyon: provisioning / php-switch / remove / migrasyon

- **`_domain_add`** (domain.sh): pool yazma + paylaşılan reload yerine → `fpm-master.conf.tpl` render `/etc/srvctl/fpm/<sname>.conf`, `srvctl-fpm.service.tpl` render `/etc/systemd/system/srvctl-fpm-<sname>.service`, `systemctl daemon-reload && enable --now srvctl-fpm-<sname>`.
- **`_domain_php_switch`** (domain.sh:884): pool sed yerine → unit'i yeni PHP sürümüyle yeniden render + `daemon-reload` + `restart srvctl-fpm-<sname>`; chroot lib kopyalama korunur.
- **`_domain_remove`**: `systemctl disable --now srvctl-fpm-<sname>`; unit + `/etc/srvctl/fpm/<sname>.conf` sil.
- **Migrasyon (mevcut domain'ler):** `srvctl security harden-fpm <domain>|--all [--apply]` (harden-fs deseni; dry-run varsayılan): shared-pool'dan per-domain unit'e taşı (config render + unit oluştur + enable), eski `/etc/php/<ver>/fpm/pool.d/<sname>.conf`'u kaldır + paylaşılan FPM reload. `--apply` öncesi mevcut durumu kaydet.

## 6. Test stratejisi

**[macOS-TDD] (küçük):**
- `fpm-master.conf.tpl` render: `render_template` ile token'lar (DOMAIN/SAFE_NAME/PHP_VERSION/WEB_USER...) doğru yerleşir, `[global]` + pool birleşir, leftover `{{` yok (mevcut `test_vhost_render.sh` deseni).
- `srvctl-fpm.service.tpl` render: `Slice=srvctl-<sname>.slice`, `AppArmorProfile=srvctl-<sname>`, `ExecStart` doğru php sürümü.
- `harden-fpm` dry-run plan çıktısı (hangi unit/config oluşturulacak, hangi eski pool kaldırılacak).

**[HOST] (Ubuntu root):**
- `domain add` → `systemctl is-active srvctl-fpm-<sname>` aktif; site açılır.
- `aa-status` FPM PID'ini `srvctl-<sname>` **enforce** gösterir (artık unconfined değil); deny edilen bir yola erişim (`/etc/shadow`) **engellenir**.
- `systemctl show -p ControlGroup srvctl-fpm-<sname>` → `srvctl-<sname>.slice` altında; `MemoryMax` uygulanır (stress testi OOM-kill).
- `php-switch` unit'i yeni sürümle yeniden başlatır; `remove` unit'i temizler.
- `harden-fpm --apply` mevcut domain'i migrate eder; site bozulmaz; eski pool kaldırılır.

## 7. Faz 2 kalan parçalar (T7a sonrası, ayrı spec)

- **T7b** — fail-closed audit: `_security_audit`'i varlık-kontrolünden enforcement-kontrolüne çevir — `aa-status --json` FPM PID'leri enforce mı, `systemctl show -p ControlGroup` srvctl.slice altında mı, `/proc/<pid>/status` Seccomp alanı; bu kontrolleri `_warn_check`'ten `_check`'e (FAIL) yükselt. (Parser mantığı macOS-test edilebilir.)
- **T7c** — `install.sh:81` template kopya döngüsüne `cgroups seccomp systemd` ekle (şu an yalnız `nginx php-fpm apparmor logrotate`); `templates/nginx/modsecurity.conf.tpl:48` CRS 941xxx (XSS) `/admin/` server-geneli devre-dışı bırakmasını daralt.
