# srvctl Faz 2 / T7b+T7c — Fail-Closed Audit + install/modsec — Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `srvctl security audit`'i varlık-kontrolünden gerçek enforcement-kontrolüne çevirmek (AppArmor/seccomp/cgroups parser'ları + FAIL yükseltme); install.sh'a cgroups/seccomp template'lerini eklemek; modsec'in /admin XSS blanket-disable'ını daraltmak.

**Architecture:** Saf parser fonksiyonları (`aa-status`/`/proc/status`/`ControlGroup` metnini alıp 0/1 döner) audit kontrollerini gerçek enforce durumuna bağlar; bunlar fixture'la macOS-test edilebilir. Per-domain wiring (MainPID → komut çıktıları) ve install/modsec runtime [HOST].

**Tech Stack:** Bash (pure), `aa-status`/`/proc`/`systemctl` (HOST), ModSecurity CRS. Hedef Ubuntu 22.04 root; geliştirme/test macOS.

## Yürütme ortamları
- **[macOS-TDD]** — saf parser'lar; `bash tests/run.sh` (Task 1).
- **[macOS-code]** — install.sh/modsec edit'leri (`bash -n`/grep); runtime etki [HOST] (Task 3).
- **[HOST]** — gerçek aa-status/proc/systemctl enforcement (Task 2).

## Global Constraints
- Türkçe string/yorum; her script `set -euo pipefail`; `error` ÇIKAR; predikat `return 0/1`.
- security.sh'in audit yardımcıları (`_check`/`_warn_check`/`_pass`/`_fail`) `_security_audit` fonksiyon KAPSAMINDA tanımlı; yeni parser'lar FILE-SCOPE (source edilince test edilebilir, require_root tetiklenmez).
- `_check "<etiket>" <cmd> <arg...>` → cmd başarısızsa FAIL; `_warn_check` → WARN.
- Commit mesajları Türkçe + `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## Dosya Yapısı
- `lib/security.sh` — `_audit_aa_enforced`/`_audit_seccomp_filtered`/`_audit_in_slice` (yeni, file-scope); per-domain audit döngüsü (wiring + FAIL + chroot yol).
- `install.sh:65,81` — cgroups/seccomp template.
- `templates/nginx/modsecurity.conf.tpl` — 941xxx daraltma.
- `tests/test_audit_parsers.sh` — parser testleri (yeni).
- `docs/superpowers/plans/2026-07-01-srvctl-phase2-t7bc-HOST-checklist.md`.

---

### Task 1: Audit enforcement parser'ları **[macOS-TDD]**

**Files:**
- Modify: `lib/security.sh` (dosya başı, `cmd_security`'den önce file-scope yardımcılar)
- Test: `tests/test_audit_parsers.sh`

**Interfaces:**
- Consumes: hiçbiri.
- Produces (PREDİKAT, 0/1, exit YOK):
  - `_audit_aa_enforced <aa_status_metni> <profil>` → profil "enforce mode" bölümünde mi.
  - `_audit_seccomp_filtered <proc_status_metni>` → `Seccomp:` değeri `2` mi.
  - `_audit_in_slice <controlgroup_metni> <slice>` → ControlGroup `<slice>`'ı içeriyor mu.

- [ ] **Step 1: Başarısız testi yaz** — `tests/test_audit_parsers.sh`:

```bash
#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/security.sh"

AA="apparmor module is loaded.
3 profiles are loaded.
2 profiles are in enforce mode.
   /usr/sbin/php-fpm8.3
   srvctl-example_com
1 profiles are in complain mode.
   srvctl-other_com
0 processes are unconfined"

assert_ok   _audit_aa_enforced "$AA" "srvctl-example_com"   "enforce'da → ok"
assert_fail _audit_aa_enforced "$AA" "srvctl-other_com"     "complain'de → fail"
assert_fail _audit_aa_enforced "$AA" "srvctl-yok_com"       "yok → fail"

assert_ok   _audit_seccomp_filtered "$(printf 'Name:\tphp-fpm8.3\nSeccomp:\t2\n')"  "Seccomp 2 → ok"
assert_fail _audit_seccomp_filtered "$(printf 'Seccomp:\t0\n')"                     "Seccomp 0 → fail"
assert_fail _audit_seccomp_filtered "$(printf 'Name:\tx\n')"                        "Seccomp satırı yok → fail"

assert_ok   _audit_in_slice "/srvctl.slice/srvctl-example_com.slice/srvctl-fpm-example_com.service" "srvctl-example_com.slice" "slice içinde → ok"
assert_fail _audit_in_slice "/system.slice/php8.3-fpm.service" "srvctl-example_com.slice"            "slice değil → fail"

rm -rf "$WEB_ROOT"
test_summary
```

- [ ] **Step 2: Çalıştır, FAIL gör** — Run: `bash tests/test_audit_parsers.sh` — FAIL (parser'lar tanımsız).

- [ ] **Step 3: Uygula** — `lib/security.sh`'a dosya başına (ilk fonksiyondan önce) ekle:

```bash
# ─── Audit enforcement parser'ları (saf; fixture ile test edilebilir) ───
# aa-status metninde <profil> "enforce mode" bölümünde listeli mi? (0=evet)
_audit_aa_enforced() {
    local text="$1" profile="$2"
    awk -v p="$profile" '
        /enforce mode\.$/ { sec=1; next }
        / mode\.$/        { sec=0 }
        /processes are/   { sec=0 }
        sec==1 { l=$0; gsub(/^[ \t]+|[ \t]+$/,"",l); if (l==p) f=1 }
        END { exit(f?0:1) }
    ' <<< "$text"
}

# /proc/<pid>/status metninde Seccomp == 2 (filter mode) mı? (0=evet)
_audit_seccomp_filtered() {
    local val
    val=$(grep -E '^Seccomp:' <<< "$1" | awk '{print $2}')
    [[ "$val" == "2" ]]
}

# ControlGroup metni <slice>'ı içeriyor mu? (0=evet)
_audit_in_slice() {
    [[ "$1" == *"$2"* ]]
}
```

- [ ] **Step 4: Çalıştır, PASS gör** — Run: `bash tests/test_audit_parsers.sh`; `bash tests/run.sh`.

- [ ] **Step 5: Commit**
```bash
git add lib/security.sh tests/test_audit_parsers.sh
git commit -m "$(cat <<'EOF'
feat(T7b): audit enforcement parser'ları (aa-status/seccomp/slice — saf, test edilebilir)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Per-domain audit wiring + FAIL yükseltme + chroot yol **[HOST]**

**Files:**
- Modify: `lib/security.sh` (per-domain audit döngüsü — `${domain}: chroot/AppArmor` kontrolleri)
- Test: yok (aa-status/systemctl HOST); macOS: `bash -n` + suite yeşil.

**Interfaces:** Consumes: `_audit_aa_enforced`/`_audit_seccomp_filtered`/`_audit_in_slice` (Task 1), `safe_name`.

- [ ] **Step 1: Uygula** — per-domain döngüde, mevcut:
```bash
        _check "${domain}: chroot aktif" \
            grep -q chroot "/etc/php/${php_ver}/fpm/pool.d/${sname}.conf"
        ...
        _warn_check "${domain}: AppArmor enforce" \
            bash -c "aa-status 2>/dev/null | grep -q 'srvctl-${sname}'"
```
şununla DEĞİŞTİR:
```bash
        # chroot: yeni FPM config yolu (T7a)
        _check "${domain}: chroot aktif" \
            grep -q chroot "/etc/srvctl/fpm/${sname}.conf"

        local _fpm_pid
        _fpm_pid=$(systemctl show -p MainPID --value "srvctl-fpm-${sname}.service" 2>/dev/null)
        # AppArmor: FPM unit gerçekten enforce mü (isim varlığı değil) — FAIL
        _check "${domain}: AppArmor enforce" \
            _audit_aa_enforced "$(aa-status 2>/dev/null)" "srvctl-${sname}"
        # seccomp: FPM master PID filter modunda mı — FAIL
        _check "${domain}: seccomp filter" \
            _audit_seccomp_filtered "$(cat "/proc/${_fpm_pid}/status" 2>/dev/null)"
        # cgroups: FPM unit kendi slice'ında mı — FAIL
        _check "${domain}: cgroup slice" \
            _audit_in_slice "$(systemctl show -p ControlGroup --value "srvctl-fpm-${sname}.service" 2>/dev/null)" "srvctl-${sname}.slice"
```

- [ ] **Step 2: macOS kontrol** — Run: `bash -n lib/security.sh`; `bash tests/run.sh` yeşil (audit döngüsü testlerde çalıştırılmıyor; parser'lar Task 1'de test edildi).

- [ ] **Step 3: Commit**
```bash
git add lib/security.sh
git commit -m "$(cat <<'EOF'
feat(T7b): per-domain audit gerçek enforcement (AppArmor/seccomp/cgroup, FAIL) + chroot yol

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4 [HOST]: Ubuntu doğrulama** — migrate edilmiş domain'de `srvctl security audit` → AppArmor/seccomp/cgroup kontrolleri PASS (gerçekten enforce); bir domain'i `aa-complain` yap → ilgili kontrol **FAIL** (skor düşer).

---

### Task 3: install.sh cgroups/seccomp + modsec daraltma **[macOS-code]**

**Files:**
- Modify: `install.sh:65,81`; `templates/nginx/modsecurity.conf.tpl`
- Test: yok (runtime HOST); macOS: `bash -n install.sh` + grep doğrulama.

**Interfaces:** yok.

- [ ] **Step 1: install.sh** — `mkdir` satırını (`:65`) ve döngüyü (`:81`):
```bash
mkdir -p "${INSTALL_DIR}/templates"/{nginx,php-fpm,apparmor,logrotate,systemd}
...
for tpl_dir in nginx php-fpm apparmor logrotate systemd; do
```
şununla DEĞİŞTİR (cgroups + seccomp ekle):
```bash
mkdir -p "${INSTALL_DIR}/templates"/{nginx,php-fpm,apparmor,logrotate,systemd,cgroups,seccomp}
...
for tpl_dir in nginx php-fpm apparmor logrotate systemd cgroups seccomp; do
```

- [ ] **Step 2: modsec daraltma** — `templates/nginx/modsecurity.conf.tpl`'deki:
```
SecRule REQUEST_URI "@beginsWith /admin/" \
    "id:200020,phase:1,t:none,nolog,pass,ctl:ruleRemoveById=941100-941999"
```
şununla DEĞİŞTİR (tüm 941xxx yerine yalnız 941160):
```
# CI4 admin: yalnız bilinen yanlış-pozitif XSS kuralı (941160 — zengin-metin
# alanlarında HTML-injection checker). XSS ailesinin geri kalanı /admin/ için de AKTİF.
SecRule REQUEST_URI "@beginsWith /admin/" \
    "id:200020,phase:1,t:none,nolog,pass,ctl:ruleRemoveById=941160"
```

- [ ] **Step 3: Doğrula (macOS)** — Run:
```bash
bash -n install.sh && echo OK
grep -q 'logrotate systemd cgroups seccomp' install.sh && echo "install loop OK"
grep -q 'ruleRemoveById=941160"' templates/nginx/modsecurity.conf.tpl && echo "modsec OK"
grep -q '941100-941999' templates/nginx/modsecurity.conf.tpl && echo "ESKI KALDI (hata)" || echo "blanket kaldırıldı"
bash tests/run.sh | tail -1
```
Beklenen: OK, install loop OK, modsec OK, blanket kaldırıldı, TÜM TEST DOSYALARI GEÇTİ.

- [ ] **Step 4: Commit**
```bash
git add install.sh templates/nginx/modsecurity.conf.tpl
git commit -m "$(cat <<'EOF'
güvenlik(T7c): install.sh cgroups/seccomp template + modsec /admin XSS daraltma (941160)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: README + host kontrol listesi **[docs]**

**Files:**
- Modify: `README.md` (audit fail-closed notu)
- Create: `docs/superpowers/plans/2026-07-01-srvctl-phase2-t7bc-HOST-checklist.md`

**Interfaces:** yok.

- [ ] **Step 1: README** — Güvenlik/audit bölümüne not: "`security audit` artık AppArmor/seccomp/cgroups'u gerçek enforce durumuyla kontrol eder (varlık değil); bir domain enforce değilse audit FAIL verir. modsec /admin XSS koruması yalnız 941160 hariç aktiftir."

- [ ] **Step 2: Host kontrol listesi** — `docs/superpowers/plans/2026-07-01-srvctl-phase2-t7bc-HOST-checklist.md`: (1) migrate domain'de `security audit` AppArmor/seccomp/cgroup PASS; (2) `aa-complain srvctl-<sname>` → audit FAIL; (3) `/usr/local/srvctl/templates/cgroups` + `/seccomp` kuruldu; (4) /admin'e XSS payload (941160 dışı) engellenir, 941160 yanlış-pozitif geçer.

- [ ] **Step 3: macOS kontrol** — `bash tests/run.sh` yeşil.

- [ ] **Step 4: Commit**
```bash
git add README.md docs/superpowers/plans/2026-07-01-srvctl-phase2-t7bc-HOST-checklist.md
git commit -m "$(cat <<'EOF'
docs(T7b/c): fail-closed audit README notu + host kontrol listesi

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review (spec kapsama)

Spec (`2026-07-01-srvctl-phase2-t7bc-audit-modsec-design.md`) → task:
- **§3.1 parser'lar** → Task 1. **§3.2 wiring + §3.3 FAIL + chroot yol** → Task 2. **§4.1 install** → Task 3. **§4.2 modsec** → Task 3. **§5 test** → Task 1 macOS-TDD; Task 2 [HOST]; Task 3 macOS-grep; Task 4 host-checklist.
- **İsim tutarlılığı:** `_audit_aa_enforced`/`_audit_seccomp_filtered`/`_audit_in_slice` — Task 1 tanımlar, Task 2 kullanır; birebir.
- **macOS/HOST:** Task 1 + Task 3 macOS-doğrulanabilir; Task 2 HOST. Doğru işaretli.
- **Kapsam:** T7b + T7c; Faz 2 tasarımını tamamlar.
