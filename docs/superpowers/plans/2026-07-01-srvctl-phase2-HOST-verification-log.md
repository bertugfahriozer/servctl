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
