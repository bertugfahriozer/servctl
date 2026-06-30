# srvctl Güvenlik Sertleştirme — Faz 1 Tasarımı

> **Tarih:** 2026-06-30
> **Yaklaşım:** Katmanlı/Fazlı (A). Bu doküman **yalnızca Faz 1'i** (savunma ağı) kapsar. Faz 2 (yapısal, Ubuntu-host bağımlı) §8'de outline olarak belgelenmiştir ve kendi spec/plan döngüsünde ele alınacaktır.
> **Önkoşul okuma:** Bu tasarımı uygulayan ajan için ÖNERİLEN ALT-BECERİ: `superpowers:writing-plans` ile task-task plan üret; uygulamada `superpowers:test-driven-development`.

## 1. Amaç ve tehdit modeli

`srvctl` root olarak çalışır ve **güvenilir** bir yönetici tarafından işletilir. Tek **güvenilmeyen** aktör, ele geçirilmiş bir per-domain web kullanıcısıdır (`web_<domain>` / PHP-FPM havuzu) — tüm izolasyon mimarisi (ayrı Unix kullanıcı, chroot, AppArmor, FPM havuzu, DB/Redis ACL'leri) tam olarak bu aktörü içermek için vardır. Bir bulgu yalnızca bu aktör (veya kontrol ettiği veri) root'a ya da başka bir domain'e sınır geçtiğinde geçerlidir. CLI bayrakları ve interaktif komut istemleri operatör-kontrollü = güvenilir kabul edilir; ancak `/var/www/<domain>/` altına yazılan dosyalar (sahibi `web_<domain>`) **güvenilmezdir** — root'un oradan sonradan okuduğu her şey saldırgan-etkilenebilirdir.

Faz 1'in hedefi: **tek bir kontrole bel bağlamadan** gerçek istismar zincirlerini (root RCE, SQL/komut enjeksiyonu, uzaktan tetiklenen deploy RCE, secret sızıntısı) kesmek. Faz 1 değişikliklerinin neredeyse tamamı macOS geliştirme makinesinde (root/nginx olmadan) unit-test edilebilir olmalıdır.

## 2. Kök-nedenler (bağlam)

Sistematik tarama, bulguların ~%90'ını açıklayan dört kök-neden buldu:

- **RC1** — `lib/domain.sh:221` `chown -R web_user "${base}"`: per-domain base dizini web kullanıcısına ait kalır; içindeki "root'a ait" kontrol dosyaları (`.credentials`, `.srvctl-meta`, `.deploy-repo`, `shared/hooks/`) silinip yeniden yazılabilir (Unix'te create/delete/rename dizin sahibine bağlıdır, dosya moduna değil). → **Faz 2 (T1) çözer.**
- **RC2** — Root bu saldırgan-kontrollü dosyaları `source` eder / çalıştırır / SQL'e enterpolasyon yapar. → **Faz 1 (T2) etkisizleştirir** (parse-not-source + kimlik türetme), Faz 2 (T1+T3) kökten kapatır.
- **RC3** — Trust-boundary girdileri doğrulama/escape olmadan config/komut sink'lerine akar (`render_template` düz string-değişim). → **Faz 1 (T4) çözer.**
- **RC4** — Reklamı yapılan katmanlar inert/fail-open (AppArmor bağlanmamış, cgroups boş, webhook fail-open, secret'lar world-readable, audit ölü katmanları yeşil gösterir). → Webhook fail-open ve secret sızıntısı **Faz 1 (T5, T6)**; MAC/cgroups/audit **Faz 2 (T7)**.

## 3. Faz 1 kapsamı

| Tema | Açıklama | Kapatır |
|---|---|---|
| **T2** | `source` → katı `key=value` parse + kimlikleri `safe_name`'den türet + `eval` kaldır | core.sh:152/212, domain.sh:558/803/1029, security.sh:32/40/153/159, deploy.sh:89/149 (kısmi) |
| **T4** | Merkezi girdi doğrulama + escape'li render | domain.sh:74/168, ip.sh, user.sh:341, cloudflare.sh:132, init.sh load_config |
| **T5** | Webhook fail-closed (uzaktan erişilebilir → kritik) | webhook.sh:159 |
| **T6** | Secret/backup kilidi (umask, perm, tar-slip, argv'den secret) | backup.sh:48/196, init.sh:163/406, domain.sh:351/375 |

**Faz 1 dışı (Faz 2):** T1 (base-dir sahiplik modeli), T3 (deploy artefakt priv-drop), T7 (MAC/cgroups gerçek yapma + fail-closed audit). Bkz. §8.

## 4. Yeni `core.sh` primitifleri

Tüm temaların üzerine kurulduğu, paylaşılan, saf-Bash, env-yönlendirilebilir yardımcılar. Hepsi macOS'ta unit-test edilebilir olmalı. `stat` çağrıları **portable sarmalayıcı** üzerinden yapılır (`stat -c` GNU / `stat -f` BSD), çünkü kod tabanı zaten `stat -c`'ye bağımlı (`domain.sh:670`, `security.sh:167`).

### 4.1 `read_kv_file <file> <KEY...>`
- Dosyadan **yalnızca** whitelist'lenen anahtarları okur: her `KEY` için `grep -E "^${KEY}="` ile satırı bul, `cut`/parametre-genişletme ile değeri al, ilgili değişkene **güvenli atama** ile yaz. **Asla `source`/`eval` etmez.**
- **Tek genel parser** (onaylandı): hem `.credentials` (düz `KEY=value`) hem `.srvctl-meta` (geçmişte `%q`-quote'lu) tarafından kullanılır. `%q` satırları için değer, atamadan önce kontrollü biçimde çözülür; yeni `.srvctl-meta` yazımı quote'suz olacağından (§6) parser uzun vadede tek-yol çalışır.
- Bilinmeyen/eksik anahtarlar sessizce atlanır (değişken set edilmez); çağıran taraf `${VAR:-}` ile savunur.

### 4.2 `assert_root_owned_path <file>`
- Dosya **ve `${WEB_ROOT}/<domain>` (base) dahil tüm üst dizinleri** root'a ait, symlink değil, grup/diğer-yazılabilir değil mi doğrular. İhlalde `error` (çıkar).
- **Faz 1 rolü:** parse-not-source ile birlikte savunma katmanı; mevcut domain'lerde base hâlâ web-owned olduğundan Faz 1'de bu **uyarı** verir ama parse-not-source RCE'yi zaten kapattığı için akışı bloklamaz (bkz. §6 geri uyumluluk). **Faz 2 (T1)** base'i root'a aldıktan sonra tam sertleşir (fail-closed).

### 4.3 Doğrulayıcılar (hepsi `error` ile fail-closed, çıktı yok)
| Yardımcı | Kural |
|---|---|
| `validate_domain <name>` | `^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$` + `..`/`/`/baştaki nokta reddi + uzunluk ≤253 |
| `assert_safe_ident <val>` | `^[a-zA-Z0-9_]+$` (DB adı/kullanıcı) |
| `assert_php_version <val>` | `^[0-9]+\.[0-9]+$` |
| `assert_regex_safe <val>` | `^[A-Za-z0-9_./|\-]+$`; `{`/`}`/`;`/boşluk/newline yasak (nginx token) |
| `validate_username <val>` | `^[a-z_][a-z0-9_-]*$`, ≤32 |
| `validate_ip_or_cidr <val>` | IPv4/IPv6/CIDR |
| `validate_uint <val>` | `^[0-9]+$` (+ opsiyonel üst sınır) |
| `validate_country <val>` | `^[A-Z]{2}$` |

### 4.4 `secure_file <path> [mode]` / `secure_dir <path> [mode]`
- `umask 077` bağlamında oluştur/var-et + `chmod ${mode:-600/700}` + `chown root:root`. T6'da kullanılır, Faz 2'de yeniden kullanılır.

### 4.5 `safe_extract <archive> <expected_prefix>`
- Arşiv üyelerini çıkarmadan **önce** listeler; `../`, mutlak yol (`/`), veya `expected_prefix` dışına çıkan üye varsa reddeder; symlink üyelerini reddeder. `backup.sh` restore tarafından kullanılır.

### 4.6 `render_template` sertleştirmesi
- Mevcut `core.sh:114` plain `${//}` substitution; her değeri yerleştirmeden önce **newline/CR içeriyorsa reddet** (genel CRLF/config enjeksiyon koruması). Token-bazlı charset doğrulaması çağıran tarafta (`assert_regex_safe`) yapılır.

## 5. Faz 1 değişiklikleri (dosya bazında)

### T2 — source → parse + kimlik türetme
- `core.sh`: `read_credentials` ve `read_meta` gövdelerini `assert_root_owned_path` (uyarı) + `read_kv_file` ile değiştir; okunan değerleri kullanımdan önce uygun doğrulayıcıdan geçir.
- `domain.sh:558` (`_domain_list` inline `source`), `security.sh:153` (audit inline `source`): `read_kv_file` ile değiştir; döngüde değişkenleri sıfırla (stale-carryover yok).
- **Kimlikleri dosyadan okuma yerine `safe_name`'den türet:** `domain.sh:779/788/803/1015`, `deploy.sh:89/149` → `db_${sname}` / `usr_${sname}` / `web_${sname}`. (Dosya bozulsa bile root deterministik güvenli identifier kullanır.)
- `security.sh:32/40`: `_check`/`_warn_check`'ten `eval`'i kaldır; test programlarını doğrudan çağır (`security.sh:159` eval-grep dahil).
- `domain.sh:803/1029/1039`: `mysqldump`/`mysql`/`ssh` çağrılarında identifier'ları türetilmiş değerlerden al; ssh remote komutunu `printf %q` ile escape et.

### T4 — merkezi doğrulama + escape
- `_domain_add` CLI yolu (`domain.sh:168`) ve domain alan tüm komutlar → `validate_domain` (giriş başında).
- `_domain_write_vhost` (`domain.sh:74`): `SENSITIVE_PATHS` → `assert_regex_safe` (substitution öncesi).
- `ip.sh` (blacklist/whitelist/geoblock/fail2ban) → `validate_ip_or_cidr`/`validate_country`/`validate_uint`.
- `user.sh:341` (`_user_add`) → `validate_username` (Linux kullanıcı + `.conf` + sudoers dosyası oluşturmadan önce).
- `cloudflare.sh:132` → API gövdesini string-enterpolasyon yerine `jq -n --arg ...` ile kur.
- `load_config` (init/core) → `SSH_PORT` (`validate_uint`), `WEB_ROOT` (mutlak yol) doğrula.

### T5 — webhook fail-closed
- `webhook.sh:159`: İmza doğrulamasını ayrı, test edilebilir bir fonksiyona çıkar. `WEBHOOK_SECRET` set olduğunda `X-Hub-Signature-256` **hem var hem eşleşir** olmalı; eksik/boş başlık → 403. Sabit-zamanlı karşılaştırma. Setup'ta `WEBHOOK_SECRET` zorunlu. Listener'ı `127.0.0.1`'e bağla (nginx arkasında), 9443'ü UFW'de dışa açma.

### T6 — secret/backup kilidi
- Secret yazan her yola `umask 077` (veya `install -m600 /dev/null` ile oluştur) — `domain.sh` `.credentials`, `init.sh:399-411` `/root/.my.cnf`, redis acl.
- `/backups` ve her artefakt `secure_dir`/`secure_file` ile (0700/0600): `backup.sh:30/48`, `init.sh:163`.
- `backup.sh:196` restore → `safe_extract` (tar/zip-slip + symlink reddi, root olarak).
- Secret'ları argv'den çıkar: root `mysql` için `/root/.my.cnf` veya stdin heredoc; `redis-cli` için `REDISCLI_AUTH` env.
- Backup paketinden `.credentials`'ı hariç tut **veya** backup'ı şifrele (Faz 1: hariç tut + not düş).

## 6. Geri uyumluluk & veri formatı

- `.credentials` zaten düz `KEY=value`; parolalar `openssl rand | tr -d '/+='` → `[A-Za-z0-9]`; kalan değerler `safe_name`'den türetilmiş. `read_kv_file` bunları sorunsuz okur — **mevcut domain'ler etkilenmez.**
- `.srvctl-meta` geçmişte `printf '%s=%q\n'` ile yazılıyor. `SENSITIVE_PATHS` artık katı charset'e doğrulandığı için `write_meta`, değeri **quote'suz + doğrulanmış** yazacak şekilde sadeleştirilir; `read_kv_file` eski `%q` satırlarını da çözebilmeli (geçiş dönemi).
- `assert_root_owned_path` Faz 1'de **uyarı** modunda: mevcut kurulu domain'lerde base hâlâ web-owned olduğu için akışı bloklamaz; parse-not-source RCE'yi zaten kapatır. **Faz 2 (T1)** base'i `root:root` yaptıktan sonra bu kapı fail-closed'a yükseltilir. Faz 1 tek başına gerçek RCE/enjeksiyon zincirlerini keser.

## 7. Test stratejisi (macOS, root/nginx yok)

Mevcut `tests/` bash harness'ı (`tests/lib.sh`, `tests/run.sh`) genişletilir. Yeni test dosyaları:
- `test_validators.sh` — tüm doğrulayıcılar tablo-tabanlı iyi/kötü vakalar.
- `test_read_kv_file.sh` — komut-subst payload'ı (`X=$(touch /tmp/pwned)`), çok-satırlı değer, eksik anahtar, `%q` satırı → yalnızca whitelist anahtar çıkarılır, **hiçbir kod çalışmaz** (yan-etki dosyası oluşmadığını assert et).
- `test_render_escaping.sh` — newline/CR içeren değer reddedilir; `assert_regex_safe` `{`/`;` reddeder.
- `test_safe_extract.sh` — macOS `tar` ile `../` ve absolute üyeli arşiv → çıkarmadan önce red.
- `test_webhook_sig.sh` — imza fonksiyonu: eksik başlık → 403, yanlış imza → 403, doğru → 200.
- `test_assert_root_owned.sh` — geçici ağaçta sahiplik/symlink simülasyonu.
- `test_identity_derivation.sh` — bozuk `.credentials`'a rağmen identifier'ların `safe_name`'den türetildiğini assert et.

**Gerçek Ubuntu host gerektiren (entegrasyon, Faz 2'ye ait):** AppArmor attachment + `aa-status`, cgroups `Slice=` placement, seccomp, per-domain FPM unit, ModSecurity davranışı, `domain add` sonrası uçtan-uca sahiplik.

## 8. Faz 2 outline (ertelendi — ayrı spec/plan)

- **T1 — base-dir sahipliğini geri al (keystone, M):** provisioning sonrası `chown root:root "${base}"; chmod 751`; web kullanıcısını yalnızca ihtiyaç duyduğu leaf subtree'lere (`public_html`, `private/writable`, `tmp`, `sessions`, `logs`, `shared/writable`) chown et. `.credentials`/`.srvctl-meta`/`.deploy-repo`/`shared/hooks` root-owned parent altında. `_domain_clone` (`domain.sh:799`) ve `_deploy_run` (`deploy.sh:149/153`) re-chown'larını base'i tekrar genişletmeyecek şekilde düzelt. **Mevcut domain'ler için `srvctl security harden-fs <domain>` migrasyon komutu.** `assert_root_owned_path` fail-closed'a yükseltilir.
- **T3 — deploy artefakt gating + priv-drop (M):** hooks/repo root-owned konuma taşı veya `assert_root_owned_path` ile gate; hook'ları `runuser -u web_${sname}` ile çalıştır; `repo_url` allowlist + `git clone --` + `GIT_ALLOW_PROTOCOL=https`; composer'ı web kullanıcısı olarak veya `--no-scripts --no-plugins` ile; `shared/.env`/`shared/writable` symlink reddi.
- **T7 — MAC/cgroups gerçek yap + fail-closed audit (L, Ubuntu host):** per-domain FPM master unit (`php-fpm@<sname>.service` + `Slice=srvctl-<sname>.slice`); AppArmor'ı path-based/child profile ile worker'a gerçekten bağla, `init.sh` `systemctl enable --now apparmor`; `|| true` + koşulsuz "enforce modda" yerine gerçek exit-kod kontrolü; audit'i varlık-kontrolünden enforcement-kontrolüne çevir (`aa-status --json`, `systemctl show -p ControlGroup`, `/proc/<pid>/status` Seccomp); `install.sh:65/81`'e `cgroups seccomp` ekle; modsec 941xxx (XSS) `/admin/` devre-dışı bırakmasını daralt.

## 9. Etkilenen dosyalar (özet)

`lib/core.sh` (yardımcı evi), `lib/domain.sh`, `lib/security.sh`, `lib/deploy.sh`, `lib/webhook.sh`, `lib/backup.sh`, `lib/ip.sh`, `lib/user.sh`, `lib/cloudflare.sh`, `lib/init.sh`; `templates/nginx/vhost.conf.tpl` (token doğrulama çağıran tarafta); `tests/*` (yeni test dosyaları + `run.sh` kaydı).
