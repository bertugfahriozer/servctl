# srvctl Faz 2 / T7b+T7c — Fail-Closed Audit + install/modsec — Tasarım

> **Tarih:** 2026-07-01
> **Bağlam:** Faz 2'nin son parçası. T1 (sahiplik), T3 (deploy priv-drop), T7a (per-domain FPM unit) tasarlandı + macOS alt-kümeleri uygulandı. Bu doküman T7b (fail-closed audit) + T7c (install.sh template'leri + modsec daraltma) — birleşik, çünkü T7c küçüktür. Bu, T7'yi ve tüm Faz 2 tasarımını tamamlar.
> **Çalışma modu:** Tasarım + plan; **macOS-test edilebilir alt-küme** (audit parser'ları + install.sh/modsec edit'leri) uygulanır, **[HOST]** (gerçek aa-status/proc/systemctl enforcement) Ubuntu'ya ertelenir.
> **Önkoşul okuma (uygulayan ajan):** `superpowers:writing-plans`; macOS-test edilebilir kısımlarda `superpowers:test-driven-development`.

## 1. Amaç ve kök-neden (RC4 — yanlış güvence)

`srvctl security audit` katmanları **varlık-kontrolüyle** "aktif" raporluyor; bu, inert AppArmor/cgroups için **yanlış güvence** verdi (Faz 1 bulgusu):
- `${domain}: AppArmor enforce` → `aa-status 2>/dev/null | grep -q 'srvctl-${sname}'` ([security.sh, per-domain döngü ~28]) — yalnız profil **adının** aa-status'ta görünüp görünmediği; FPM PID'inin gerçekten enforce olup olmadığı DEĞİL. Üstelik `_warn_check` (WARN, FAIL değil).
- `${domain}: chroot aktif` → `grep -q chroot /etc/php/<ver>/fpm/pool.d/<sname>.conf` — config'de string var mı; **T7a sonrası bu yol yanlış** (config artık `/etc/srvctl/fpm/<sname>.conf`).
- seccomp / cgroups slice enforcement kontrolleri **yok**.

T7a katmanları gerçek yaptı (per-domain FPM unit + `AppArmorProfile=`/`Slice=`). T7b audit'i **enforcement-kontrolüne** çevirir. T7c install ve modsec'i tamamlar.

## 2. Kapsam

| İçeride | Dışarıda |
|---|---|
| Audit enforcement parser'ları (AppArmor/seccomp/cgroups) | Faz 2 tamamlandı — sonraki spec yok |
| Per-domain enforcement wiring (MainPID → aa-status/proc/ControlGroup) | — |
| `_warn_check` → `_check` (FAIL) yükseltme | — |
| install.sh `cgroups seccomp` template kopyası | — |
| modsec /admin XSS blanket-disable daraltma | — |

## 3. T7b: enforcement kontrolleri

### 3.1 Saf parser'lar (security.sh — [macOS-TDD])
Fixture metni alıp 0/1 dönen PREDİKATlar (çıktı YOK, exit YOK):
- `_audit_aa_enforced <aa_status_metni> <profil>` → `aa-status` çıktısında `<profil>`'ün **"enforce mode"** bölümünde listelendiği (complain/unconfined değil) → 0. Yaklaşım: enforce bölümünün satırlarını tarayıp profil adını ara (basit metin; `aa-status --json` yerine düz metin daha taşınabilir — ama JSON daha sağlam; **düz `aa-status` metni** parse edilir: "X profiles are in enforce mode." sonrası girintili profil listesi).
- `_audit_seccomp_filtered <proc_status_metni>` → `Seccomp:` satırı değeri `2` (SECCOMP_MODE_FILTER) → 0; `0` (disabled) → 1.
- `_audit_in_slice <controlgroup_metni> <slice>` → `systemctl show -p ControlGroup` çıktısı (`ControlGroup=/srvctl.slice/srvctl-<sname>.slice/...`) `<slice>`'ı içeriyor → 0.

### 3.2 Per-domain wiring ([HOST])
Audit domain döngüsünde her domain için:
```
pid=$(systemctl show -p MainPID --value "srvctl-fpm-${sname}.service")
_check "${domain}: AppArmor enforce" _audit_aa_enforced "$(aa-status 2>/dev/null)" "srvctl-${sname}"
_check "${domain}: seccomp filter"   _audit_seccomp_filtered "$(cat /proc/${pid}/status 2>/dev/null)"
_check "${domain}: cgroup slice"     _audit_in_slice "$(systemctl show -p ControlGroup --value srvctl-fpm-${sname}.service)" "srvctl-${sname}.slice"
```
chroot kontrolünü yeni config yoluna güncelle: `grep -q chroot "/etc/srvctl/fpm/${sname}.conf"`.

### 3.3 FAIL yükseltme
AppArmor/seccomp/cgroups/chroot kontrolleri `_warn_check` yerine **`_check`** (FAIL) olur — bir domain gerçekten enforce değilse audit **düşer** (dürüst raporlama; "reklamı yapılan ama çalışmayan" sorununu görünür kılar).

## 4. T7c: install.sh + modsec

### 4.1 install.sh
`mkdir` (satır 65) ve kopya döngüsüne (satır 81) `cgroups seccomp` ekle:
```bash
mkdir -p "${INSTALL_DIR}/templates"/{nginx,php-fpm,apparmor,logrotate,systemd,cgroups,seccomp}
...
for tpl_dir in nginx php-fpm apparmor logrotate systemd cgroups seccomp; do
```
(systemd T7a'da eklendi.) `templates/cgroups` ve `templates/seccomp` repo'da var ama hiç kurulmuyordu (CLAUDE.md notu).

### 4.2 modsec daraltma
`templates/nginx/modsecurity.conf.tpl`'deki:
```
SecRule REQUEST_URI "@beginsWith /admin/" \
    "id:200020,phase:1,t:none,nolog,pass,ctl:ruleRemoveById=941100-941999"
```
**tüm XSS ailesini (941100-941999)** /admin/ için server-geneli kaldırıyor → admin paneli XSS'e açık. Daralt: yalnız bilinen yanlış-pozitif kuralları kaldır (CI4 admin'in zengin-metin/HTML form alanlarında tetiklediği), XSS ailesinin geri kalanı kalsın:
```
# CI4 admin: yalnız bilinen yanlış-pozitif XSS kuralları (zengin-metin alanları);
# XSS ailesinin geri kalanı /admin/ için de AKTİF kalır.
SecRule REQUEST_URI "@beginsWith /admin/" \
    "id:200020,phase:1,t:none,nolog,pass,ctl:ruleRemoveById=941160"
```
(941160 = "NoScript XSS InjectionChecker: HTML Injection" — zengin-metin editörlerde sık yanlış-pozitif. Operatör ihtiyaca göre genişletebilir; varsayılan güvenli tarafta.)

## 5. Test stratejisi

**[macOS-TDD]:**
- `_audit_aa_enforced` / `_audit_seccomp_filtered` / `_audit_in_slice`: fixture metinlerle tablo-tabanlı (enforce/complain, Seccomp 0/2, slice var/yok). security.sh'i source edip parser'ları doğrudan çağır (require_root tetiklenmeden — parser'lar file-scope; cmd_security çağrılmaz).
- install.sh: `bash -n` + `grep -q 'cgroups seccomp'` döngüde.
- modsec: `grep` ile 941160 var, 941100-941999 yok.

**[HOST] (Ubuntu root):**
- Migrate edilmiş domain'de `srvctl security audit` → AppArmor/seccomp/cgroups kontrolleri gerçekten enforce ise PASS; bir domain'i unconfined yap → audit FAIL.
- install sonrası `/usr/local/srvctl/templates/cgroups` ve `/seccomp` mevcut.
- modsec: /admin/'e XSS payload (941160 dışı) → engellenir; 941160 yanlış-pozitif → geçer.

## 6. Etkilenen dosyalar
- `lib/security.sh` — `_audit_aa_enforced`/`_audit_seccomp_filtered`/`_audit_in_slice` (yeni parser'lar); per-domain audit döngüsü (enforcement wiring + FAIL yükseltme + chroot yol düzeltme).
- `install.sh:65,81` — cgroups/seccomp template kopyası.
- `templates/nginx/modsecurity.conf.tpl` — 941xxx daraltma.
- `tests/` — yeni: `test_audit_parsers.sh`.
- `README.md` — audit fail-closed notu (opsiyonel).
- `docs/superpowers/plans/2026-07-01-srvctl-phase2-t7bc-HOST-checklist.md`.

> **Not:** Bu spec T7'yi ve **tüm Faz 2 tasarımını** tamamlar. Kalan tek iş: T1/T3/T7'nin [HOST] kısımlarını bir Ubuntu staging'de uygulamak + 4 host kontrol listesiyle uçtan-uca doğrulamak.
