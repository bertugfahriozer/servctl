# Faz 2 / T7b+T7c — Ubuntu Host Doğrulama Kontrol Listesi

> macOS'ta uygulanan alt-küme: audit parser'ları (Task 1) + install.sh/modsec
> edit'leri (Task 3). [HOST] Task 2 (per-domain enforcement wiring) gerçek Ubuntu
> root host'ta uygulanıp aşağıdaki senaryoyla doğrulanmalıdır. **Önkoşul:** T7a
> per-domain FPM unit'leri (HOST) çalışır durumda olmalı.

## 1. Audit gerçek enforcement raporluyor (Task 2)
```bash
# Migrate edilmiş, enforce çalışan bir domain:
srvctl security audit | grep -E 'AppArmor enforce|seccomp filter|cgroup slice'
# beklenen: ilgili domain satırları ✓ (PASS)
```

## 2. Audit FAIL veriyor (dürüst raporlama)
```bash
sname=example_com
aa-complain /etc/apparmor.d/srvctl-${sname}    # profili enforce'dan çıkar
systemctl restart srvctl-fpm-${sname}
srvctl security audit | grep "AppArmor enforce"  # beklenen: ✗ FAIL (skor düşer)
# geri al:
aa-enforce /etc/apparmor.d/srvctl-${sname}; systemctl restart srvctl-fpm-${sname}
srvctl security audit | grep "AppArmor enforce"  # tekrar ✓
```

## 3. seccomp + cgroup kontrolleri
```bash
pid=$(systemctl show -p MainPID --value srvctl-fpm-example_com.service)
grep Seccomp /proc/${pid}/status                 # Seccomp: 2 (filter) bekleniyor → audit PASS
systemctl show -p ControlGroup --value srvctl-fpm-example_com.service  # srvctl-example_com.slice altında → audit PASS
```

## 4. install.sh cgroups/seccomp template'leri kuruldu (Task 3)
```bash
ls /usr/local/srvctl/templates/cgroups/   # boş değil (repo'daki template'ler kopyalandı)
ls /usr/local/srvctl/templates/seccomp/   # boş değil
```

## 5. modsec /admin XSS daraltma (Task 3)
```bash
# /admin/'e 941160-DIŞI bir XSS payload → ENGELLENİR (403):
curl -sk -H "Host: example.com" "https://127.0.0.1/admin/x?q=<script>alert(1)</script>" -o /dev/null -w '%{http_code}\n'
# beklenen: 403 (XSS ailesi /admin için hâlâ aktif)
# 941160 yanlış-pozitifi (zengin-metin HTML) → GEÇER (admin formu bozulmaz)
```

## Başarı kriteri
- 1-3: audit AppArmor/seccomp/cgroups'u gerçek enforce ile kontrol eder; enforce değilse FAIL.
- 4: cgroups/seccomp template'leri install ediliyor.
- 5: /admin XSS koruması büyük ölçüde aktif (yalnız 941160 hariç).

Hepsi yeşilse T7b+T7c — ve tüm Faz 2 tasarımı — production'a hazırdır (T1/T3/T7a HOST adımları da tamamlanmış olmalı; 4 host kontrol listesine bakın).
