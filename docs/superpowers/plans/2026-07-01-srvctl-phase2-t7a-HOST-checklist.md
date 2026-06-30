# Faz 2/T7a — HOST Doğrulama Kontrol Listesi

> Bu belge Task 4/5/6'nın [HOST] adımlarını tek bir e2e akışında özetler.
> Tüm adımlar Ubuntu 22.04 LTS üzerinde **root** olarak çalıştırılır.
> Gerçek ortamda sırayla uygulayın; her adımdan sonra beklenen çıktıyı doğrulayın.

---

## Ön Koşullar

- `srvctl` kurulu (`bash install.sh` çalıştırılmış).
- `systemd`, `apparmor`, `aa-enforce`, `systemctl` mevcut.
- Test domain'i yok veya temiz bir sunucu.

---

## 1. domain add → unit aktif, AppArmor enforce, cgroups slice

```bash
# Domain ekle (per-domain FPM unit otomatik oluşturulur)
srvctl domain add test.example.com --php=8.3

# Systemd unit aktif mi?
systemctl is-active srvctl-fpm-test_example_com.service
# Beklenen: active

# AppArmor enforce modda mı?
aa-status | grep srvctl-fpm-test_example_com
# Beklenen: enforce satırı görünür

# cgroups slice altında mı çalışıyor?
systemctl show srvctl-fpm-test_example_com.service -p ControlGroup
# Beklenen: /srvctl.slice/srvctl-fpm-test_example_com.service
```

---

## 2. AppArmor gerçekten kısıtlıyor (/etc/shadow deny)

```bash
# FPM worker kullanıcısı olarak /etc/shadow okuma denemesi
sudo -u web_test_example_com cat /etc/shadow
# Beklenen: "Permission denied" (AppArmor bloğu)

# audit.log'da deny kaydı görülür
grep 'DENIED' /var/log/audit/audit.log | grep shadow | tail -3
```

---

## 3. MemoryMax stress → OOM-kill

```bash
# FPM unit'in MemoryMax değerini kontrol et
systemctl show srvctl-fpm-test_example_com.service -p MemoryMax
# Beklenen: konfigürasyonda tanımlı değer (örn. 256M)

# Stress testi (PHP üzerinden bellek tüketimi)
# Web kullanıcısı üzerinden memory_limit aşılırsa cgroups OOM-kill devreye girer
# Sistem logunda OOM kaydı:
journalctl -u srvctl-fpm-test_example_com.service | grep -i oom
```

---

## 4. php-switch

```bash
# PHP sürümünü değiştir (8.3 → 8.2)
srvctl domain php-switch test.example.com 8.2

# Yeni unit PHP 8.2 ile aktif mi?
systemctl is-active srvctl-fpm-test_example_com.service
# Beklenen: active

# Socket doğru sürüme mi işaret ediyor?
ls -la /run/php/php8.2-fpm-test_example_com.sock
# Beklenen: socket dosyası mevcut

# Nginx upstream doğru mu?
nginx -T 2>/dev/null | grep test_example_com | grep 8.2
```

---

## 5. domain remove → unit + AppArmor temizlendi

```bash
# Domain sil
srvctl domain remove test.example.com

# Unit artık yok
systemctl status srvctl-fpm-test_example_com.service
# Beklenen: "could not be found" veya "inactive (dead)"

# AppArmor profili kaldırıldı
aa-status | grep test_example_com
# Beklenen: çıktı yok

# Socket temizlendi
ls /run/php/php8.2-fpm-test_example_com.sock 2>&1
# Beklenen: "No such file or directory"
```

---

## 6. harden-fpm migrate (mevcut kurulumlara taşıma)

```bash
# Mevcut domain'i shared-pool'dan per-domain unit'e taşı (dry-run)
srvctl security harden-fpm legacy.example.com

# Çıktıyı incele: oluşturulacak dosyalar, unit ismi, AppArmor profili
# Onayladıktan sonra uygula:
srvctl security harden-fpm legacy.example.com --apply

# Unit aktif mi?
systemctl is-active srvctl-fpm-legacy_example_com.service

# Tüm domainleri taşı
srvctl security harden-fpm --all
```

---

## 7. site + deploy regresyon testi

```bash
# Yeni domain ekle ve deploy test et
srvctl domain add deploy-test.example.com --php=8.3
srvctl deploy deploy-test.example.com main

# HTTP yanıtı 200 mi?
curl -sk -o /dev/null -w "%{http_code}" https://deploy-test.example.com
# Beklenen: 200

# Rollback çalışıyor mu?
srvctl deploy rollback deploy-test.example.com
curl -sk -o /dev/null -w "%{http_code}" https://deploy-test.example.com
# Beklenen: 200

# Health check
srvctl deploy health deploy-test.example.com
# Beklenen: tüm kontroller yeşil

# Temizlik
srvctl domain remove deploy-test.example.com
```

---

## Özet — Beklenen Başarı Kriterleri

| # | Test | Beklenen |
|---|------|----------|
| 1 | domain add → unit aktif | `active` |
| 1 | AppArmor enforce | profil listede |
| 1 | cgroups slice | `/srvctl.slice/...` altında |
| 2 | `/etc/shadow` deny | Permission denied |
| 3 | MemoryMax → OOM | journalctl'de OOM kaydı |
| 4 | php-switch 8.2 | unit aktif, socket doğru |
| 5 | domain remove | unit + AA + socket temizlendi |
| 6 | harden-fpm migrate | unit aktif, paylaşımlı pool devre dışı |
| 7 | deploy + rollback | HTTP 200, regresyon yok |
