# Faz 2 — HOST Doğrulama Kaydı (kısmi)

**Tarih:** 2026-07-01
**Ortam:** `srvctl-test@orb` (OrbStack) — Ubuntu **24.04.4** LTS, systemd **255 (running)**, cgroups v2 ✓, passwordless sudo ✓.
**Kısıt:** AppArmor LSM çekirdekte **yok** (`/sys/module/apparmor` boş, securityfs apparmor yok) — OrbStack çekirdeği. Hedef üretim 22.04'tür.

Doğrulama, repo `lib/` host'a (`/tmp/srvctl-src`) tar-over-ssh ile taşınarak, ilgili fonksiyonlar root olarak gerçek dosya sistemi/systemd üzerinde çalıştırılarak yapıldı.

## ✅ Doğrulanan (AppArmor-dışı çekirdek mekanizmalar)

### T1 — RC1 dosya-sahiplik modeli (`_domain_apply_fs_ownership`)
```
base            : root:root 751
public_html     : web_example_com:web_example_com 750
private/writable: web_example_com:web_example_com 770
dev (chroot)    : root:root 755
.credentials    : root:root 600
```
- **RC1 tamper:** web kullanıcısı `.credentials` silemedi (Permission denied), base'de yeni dosya oluşturamadı. ✓
- **Kırılım yok:** web kullanıcısı `private/writable` ve `tmp`'ye yazabildi. ✓
→ Keystone (RC1) gerçek host'ta kanıtlandı.

### T3 — Deploy privilege drop (`runuser`)
- `runuser -u web_example_com -- id -un` → `web_example_com`. ✓
- Hook `runuser -u web_user -- bash hook` ile **web_user olarak** çalıştı (root değil). ✓

### T7a — cgroups `Slice=` (per-domain kaynak izolasyonu)
- `systemd-run --slice=srvctl-example_com.slice --property=MemoryMax=128M` →
  ControlGroup: `/srvctl.slice/srvctl-example_com.slice/...`; `MemoryMax=134217728`;
  cgroup `memory.max=134217728`. ✓
→ Boş-slice (inert cgroups) sorunu, per-domain unit'in `Slice=` direktifiyle çözülüyor — gerçek limit cgroup'a uygulandı.

### T7b — seccomp + audit parser'ları (gerçek veriyle)
- `systemd-run --property=SystemCallFilter=@system-service` → `/proc/<pid>/status` `Seccomp: 2`. ✓
- `_audit_seccomp_filtered` (gerçek `/proc/status`) → OK; `_audit_in_slice` (gerçek `systemctl show ControlGroup`) → OK. ✓
→ Audit enforcement parser'ları yalnız fixture'da değil, gerçek systemd/proc verisinde de doğru.

## ❌ Bu host'ta doğrulanAMAYAN (AppArmor LSM yok)
- **T7a AppArmor attach** (`AppArmorProfile=srvctl-<sname>` unit direktifi) — çekirdekte AppArmor olmadığından unit transition edemez.
- **T7b AppArmor enforcement audit** (`_audit_aa_enforced` + `aa-status` wiring) — `aa-status` çalışmıyor.
- Bunlar **gerçek AppArmor-etkin Ubuntu 22.04** gerektirir.

## ⏸️ Bu oturumda çalıştırılmayan (full stack gerekir)
- Uçtan-uca akış: `srvctl init` (nginx/php-fpm/mariadb/redis + sertleştirme) + `srvctl domain add` + 4 HOST kontrol listesinin tam koşumu. Çekirdek mekanizmalar yukarıda kanıtlandığı için bu, esas olarak **wiring** doğrulaması (provisioning'in `_domain_apply_fs_ownership`'i çağırması, deploy'un runuser kullanması, FPM unit'in başlaması, audit'in parser'ları kullanması). 24.04≠22.04 sürtünmesi beklenebilir.

## Sonuç
AppArmor-dışı **tüm Faz 2 çekirdek mekanizmaları gerçek systemd Linux host'ta doğrulandı.** Kalan: (a) AppArmor parçaları için AppArmor-etkin 22.04 host; (b) full-stack uçtan-uca wiring koşumu.

## Güncelleme — T1 provisioning wiring e2e + install/stack

### T1 provisioning WIRING (domain add) — DOĞRULANDI ✓
`srvctl domain add test.local --php=8.3 --no-ssl` gerçek host'ta (stack kurulu):
- base `root:root 751`, public_html `web_test_local 750`, dev (chroot) `root 755`.
- hardened marker yazıldı: `hardened <tarih> srvctl-1.0.0`.
- web_test_local base'de dosya **oluşturamadı** (Permission denied) → RC1 provisioning düzeyinde kapalı.
- web app `private/writable`'a **yazabildi** (kırılım yok).
→ T1 keystone artık hem fonksiyon hem provisioning-entegrasyonu düzeyinde HOST-doğrulanmış.

## 🐞 Staging'de bulunan PRE-EXISTING srvctl bug'ları (Faz 2 DEĞİL — ayrı iş)
Bunlar Faz 2 değişiklikleri değil; srvctl'in mevcut kodunda, gerçek kurulumda ortaya çıkan hatalar:

1. **Redis ACL yorum satırları — KRİTİK (güvenlik):** `_install_redis` `users.acl`'e `#` yorum satırları yazıyor; redis 7.x bunu reddediyor → `redis-server` HİÇ başlamıyor → "Redis ACL izolasyonu" katmanı gerçek deploy'da kırık. Düzeltme: aclfile'a yalnız `user ...` satırları yaz.
2. **REDIS_ADMIN_PASS conf'a yazılmıyor:** `_install_redis` parolayı `users.acl`'e yazıyor ama `srvctl.conf`'a boş bırakıyor → domain add redis auth başarısız. Düzeltme: parolayı conf'a da yaz (tutarlı).
3. **_install_php 8.2 hardcode:** DEFAULT_PHP_VERSION yerine 8.2 varsayıyor; 24.04'te (8.3) php security config uygulanmıyor. Düzeltme: sürümü config'den al.
4. **php-fpm pool slowlog chroot-öncesi:** pool `slowlog = /logs/php-slow.log` chroot'tan önce çözülüyor → `php-fpm` pool başlatamıyor → domain add step 4'te abort. Düzeltme: slowlog'u chroot-öncesi var olan yola al veya kapat.
5. **install.sh reinstall exit 1:** ilk kurulum OK, reinstall exit 1 (muhtemelen 22.04 OS-versiyon kontrolü 24.04'te) → dosyalar güncellenmiyor.

Not: 1-2 numaralı bug'lar güvenlik-ilgili (Redis ACL izolasyonu çalışmıyor) ve 22.04'te de geçerli olabilir (redis 6/7 aclfile yorum kısıtı). Ayrı bir düzeltme işine değer.

## Çözüm — bug'ların sınıflandırılması + düzeltmeler

Staging e2e "sıfırdan kur" turu, srvctl'in **Ubuntu 24.04'te hiç test edilmediğini** ve bir zincir uyumsuzluk olduğunu ortaya çıkardı. İki sınıf:

### DÜZELTİLDİ — evrensel bug'lar (22.04 dahil her deploy'u etkiler) — commit 90b1da3
- **#1 Redis ACL yorumları (GÜVENLİK):** aclfile'a '#' yazılıyordu → redis başlamıyor → Redis ACL izolasyonu kırık. → yorumlar kaldırıldı.
- **#4 php-fpm slowlog/access.log chroot-relative:** MASTER (chroot dışı) bulamıyor → pool başlamıyor. → gerçek yola alındı.
- **#6 rate-profiles.conf install edilmiyor:** tüm rate profilleri "bilinmeyen". → install.sh kopyalıyor.
Sonuç: bu 3 düzeltmeyle `domain add` step 4 (abort) → step 7 (nginx -t başarılı) ilerledi; base `root:root 751` + hardened marker e2e doğrulandı.

### ERTELENDİ — 24.04-özgü porting (hedef OS 22.04'te olmaz; ayrı "24.04 desteği" işi)
- **#7 mariadb root auth:** _install_mariadb 24.04'te root'u parola-moduna alıp /root/.my.cnf'i boş bırakıyor → root kilitli → domain add step 8 patlıyor.
- **#3 _install_php 8.2:** 24.04'te 8.2 yok → security.ini yazımı uyarı veriyor (8.3 çalışıyor, non-fatal).
- **#5 install.sh reinstall exit 1:** muhtemelen 22.04 OS-versiyon kontrolü.
- **#2** gerçek bug değildi (kod REDIS_ADMIN_PASS'i conf'a doğru yazıyor; boş gözlem partial-run artefaktı).

### Nihai durum
- **T1 keystone (Faz 2): TAM DOĞRULANDI** — fonksiyon + provisioning e2e (`domain add` → base root:root 751 + marker + tamper-engelleme + nginx -t geçer).
- **T3/T7a-cgroups/T7b-seccomp+parser:** gerçek systemd verisiyle doğrulandı.
- **AppArmor (T7a attach + T7b AppArmor audit):** orb'da AppArmor LSM yok → doğrulanamadı; gerçek 22.04 gerekir.
- **Full domain-add tamamlanması:** #7 (mariadb-24.04) blokluyor → srvctl'in 22.04'te (init'in hedefi) veya 24.04-portundan sonra tamamlanmalı.

---

## Oturum 2 (2026-07-01) — 24.04 desteği: kalan bug'lar düzeltildi, full e2e TAMAMLANDI

`feature/ubuntu-24.04-support` dalı. Ertelenen 24.04-porting maddeleri kovalandı; ikisi
**severe/evrensel** çıktı (yalnız 24.04 değil, her deploy'u etkiler). Full `domain add`
e2e artık 24.04'te uçtan uca tamamlanıyor.

### DÜZELTİLDİ — bu oturum (feature/ubuntu-24.04-support)

- **secure_file içeriği truncate ediyordu — SEVERE / EVRENSEL** (commit `fd33613`):
  `secure_file` `: > "$path"` ile mevcut dosyayı **BOŞALTIYORDU**. İçerik-yazımından
  SONRA çağrıldığı 3 yerde sessiz veri kaybı: boş yedek artefaktları, boş migrate
  credentials, ve **/root/.my.cnf boşalması → mariadb root kilidi** (önceki turda #7
  sanılan). `touch` ile değiştirildi (truncate etmez). Regresyon testi eklendi
  (`tests/test_secure_fs.sh`, 12/12 geçer). **Bu, önceki #7'nin gerçek kök-nedeni.**

- **REDIS_ADMIN_PASS conf'a yazılmıyordu — EVRENSEL** (commit `f84a15c`; önceki #2'nin
  gerçek hali — "bug değil" değerlendirmesi YANLIŞTI). İki kök-neden:
  1. **Anchorsuz grep tuzağı:** conf'ta `# REDIS_ADMIN_PASS=` yorum placeholder'ı var.
     `grep -q "REDIS_ADMIN_PASS"` yorumu yakalıyor → sed `^REDIS_ADMIN_PASS=` ile
     eşleşmiyor → no-op → parola conf'a HİÇ yazılmıyor. → `^REDIS_ADMIN_PASS=` anchor'landı.
  2. **Sıra:** parola kaydı `systemctl restart redis-server`'dan SONRAYDI; restart set -e
     altında non-zero dönerse fonksiyon parolayı yazmadan abort ediyordu. → kayıt
     restart'tan ÖNCEYE alındı.
  Etki: her kurulumda redis admin parolası conf'a yazılmıyor → `domain add` step 9
  (redis ACL) WRONGPASS ile patlıyordu.

- **#3 _install_php kurulmayan sürümde abort — 24.04** (commit `a1ed0ba`):
  loop `for ver in 8.2 8.3`; 24.04 default repo'da php8.2 YOK. Kurulmazsa
  `cat > /etc/php/8.2/fpm/conf.d/...` dizin yokluğunda set -e ile init'i patlatır.
  → sürüm dizini yoksa `continue` ile atla.

### FULL E2E — orb / Ubuntu 24.04, tamamı doğrulandı

`srvctl domain add test.local --php=8.3 --no-ssl` → **"✅ Domain başarıyla eklendi"**
(10/10 adım: user, dizinler+T1, chroot, php-fpm pool, nginx vhost+`nginx -t`, ssl-skip,
apparmor-warn, DB `db_test_local`/`usr_test_local`, redis ACL, `.credentials`).

Doğrulanan katmanlar (gerçek hardened domain üstünde):
- **T1 ownership:** base `root:root 751`, `.credentials` `root:root 600`.
- **Hardened marker:** `/usr/local/srvctl/state/test.local/hardened` yazılı; `_domain_is_hardened`=EVET.
- **Fail-closed read gate:** doğru sahiplikte `read_credentials` exit=0; `.credentials`
  non-root'a (web_test_local) chown edilince hardened domainde `read_credentials`
  **exit≠0 (reddedildi)** → tamper kapısı çalışıyor.

### HÂLÂ AÇIK
- **#5 install.sh reinstall exit 1:** net kod bug'ı bulunamadı (tek `exit 1` symlink
  doğrulama fail'inde). Belirsiz — gerçek 24.04'te temiz reinstall ile yeniden test gerek.
- **AppArmor (T7a attach + T7b AppArmor audit):** orb'da LSM yok → gerçek 22.04 gerekir.

Not: orb'da mariadb root kilitli kaldı (disposable test host); tekrar kullanım için mariadb reset gerekir.
