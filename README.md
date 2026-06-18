# srvctl — CLI-Only Ultra-Güvenli Sunucu Yönetimi

> Sıfır GUI · Sıfır Docker · Sıfır Panel · 12 Güvenlik Katmanı  
> Ubuntu 22.04 LTS · PHP-FPM · Nginx · MariaDB · Redis

---

## Nedir?

`srvctl` tamamen CLI tabanlı, güvenlik odaklı bir sunucu yönetim aracıdır. Her domain eklendiğinde otomatik olarak **12 güvenlik katmanı** uygulanır:

| # | Katman | Açıklama |
|---|--------|----------|
| 1 | **Linux kullanıcı izolasyonu** | Her domain ayrı sistem kullanıcısı (`web_domain`) |
| 2 | **Dizin izinleri + ACL** | `750` + `setfacl` ile sıkı erişim kontrolü |
| 3 | **chroot jail** | PHP process domain dizininin dışına çıkamaz |
| 4 | **PHP-FPM pool izolasyonu** | Her domain ayrı FPM pool, ayrı socket |
| 5 | **AppArmor profili** | Kernel seviyesinde erişim kısıtlaması (enforce) |
| 6 | **open_basedir** | PHP'nin erişebildiği dizinleri kısıtlar |
| 7 | **disable_functions** | `exec`, `system`, `shell_exec` vb. devre dışı |
| 8 | **MariaDB GRANT izolasyonu** | Her domain sadece kendi DB'sine erişir |
| 9 | **Redis ACL** | Her domain sadece kendi key prefix'ine erişir |
| 10 | **Nginx güvenlik header'ları** | HSTS, CSP, X-Frame-Options, rate limiting |
| 11 | **Fail2Ban** | Brute-force saldırılarını otomatik engeller |
| 12 | **auditd** | Tüm dosya değişikliklerini loglar |

---

## Hızlı Kurulum

```bash
# 1. Dosyaları sunucuya kopyala
scp -r srvctl/ root@server:/tmp/srvctl/

# 2. Sunucuya bağlan
ssh root@server

# 3. Kur
cd /tmp/srvctl
sudo bash install.sh

# 4. Yapılandırmayı düzenle
sudo nano /usr/local/srvctl/conf/srvctl.conf

# 5. Sunucuyu hazırla (tek seferlik)
sudo srvctl init

# 6. İlk domain'i ekle
sudo srvctl domain add example.com --php=8.3
```

---

## Komutlar

### Sunucu Kurulumu

```bash
sudo srvctl init
```

Tek seferlik çalıştırılır. Kernel hardening, SSH güvenlik ayarları, firewall, Nginx, PHP-FPM, MariaDB, Redis, Fail2Ban ve auditd kurar/yapılandırır.

### Domain Yönetimi

```bash
# Yeni domain ekle (12 güvenlik katmanı otomatik)
sudo srvctl domain add example.com
sudo srvctl domain add example.com --php=8.2

# Tüm domain'leri listele
sudo srvctl domain list

# Domain detay bilgisi
sudo srvctl domain info example.com

# Domain kaldır (öncesinde otomatik yedek alır)
sudo srvctl domain remove example.com
```

### Deploy

```bash
# main branch'ten deploy
sudo srvctl deploy example.com

# Belirli branch'ten deploy
sudo srvctl deploy example.com staging
```

İlk deploy'da git repo URL'si sorulur ve kaydedilir. Sonraki deploy'larda otomatik kullanır.

**Zero-downtime deploy** nasıl çalışır:
1. Git clone → yeni release dizini
2. Composer install
3. Shared dosyalar bağlanır (.env, writable/)
4. İzinler ayarlanır
5. **Atomic symlink switch** (anlık geçiş)
6. PHP-FPM reload
7. Son 5 release dışındakiler temizlenir

### Yedekleme

```bash
# Tüm domain'leri yedekle (DB + dosya + Redis + config)
sudo srvctl backup run

# Tek domain yedekle
sudo srvctl backup run example.com

# Yedekleri listele
sudo srvctl backup list

# Geri yükle
sudo srvctl backup restore 20250618_040000
```

Günlük otomatik yedekleme cron ile çalışır (04:00). 30 günden eski yedekler otomatik silinir.

### SSL

```bash
# Tüm sertifikaları yenile
sudo srvctl ssl renew

# Sertifika durumlarını göster
sudo srvctl ssl status
```

SSL yenileme otomatik olarak günde 2 kez çalışır (certbot cron).

### Güvenlik Denetimi

```bash
sudo srvctl security audit
```

Tüm güvenlik katmanlarını kontrol edip **skor/100** verir:
- OS güvenliği (UFW, SSH, hidepid, kernel hardening)
- Servis durumları (Nginx, PHP-FPM, MariaDB, Redis, Fail2Ban, auditd, AppArmor)
- MariaDB güvenliği (localhost, local-infile, root şifre)
- Redis güvenliği (localhost, ACL, tehlikeli komutlar)
- PHP güvenliği (expose_php, display_errors, disable_functions)
- Domain izolasyonu (chroot, AppArmor, dosya izinleri)

### Sunucu Durumu

```bash
sudo srvctl status
```

Tek bakışta: sistem bilgisi, kaynak kullanımı, servis durumları, domain listesi, Fail2Ban istatistikleri, son yedek bilgisi.

---

## Dizin Yapısı

### srvctl kurulum dizini

```
/usr/local/srvctl/
├── bin/srvctl              ← Ana CLI
├── lib/                    ← Modüller
│   ├── core.sh
│   ├── init.sh
│   ├── domain.sh
│   ├── deploy.sh
│   ├── backup.sh
│   ├── ssl.sh
│   ├── security.sh
│   └── status.sh
├── templates/              ← Şablonlar
│   ├── nginx/
│   ├── php-fpm/
│   ├── apparmor/
│   └── logrotate/
├── conf/srvctl.conf        ← Yapılandırma
└── logs/srvctl.log         ← Operasyon logları
```

### Her domain'in dizin yapısı

```
/var/www/example.com/
├── public_html/            ← Nginx root (CI4 public/ symlink)
├── private/                ← CI4 uygulama kodu
│   ├── app/
│   ├── modules/
│   ├── system/
│   ├── vendor/
│   └── writable/
│       ├── cache/
│       ├── logs/
│       ├── session/
│       └── uploads/
├── shared/                 ← Deploy'lar arası paylaşılan (.env, writable/)
├── releases/               ← Deploy geçmişi (son 5)
├── logs/                   ← Nginx + PHP-FPM logları
├── tmp/                    ← PHP upload temp
├── sessions/               ← PHP session (chroot içi)
├── dev/                    ← chroot cihazları (null, urandom, zero)
├── etc/                    ← chroot DNS/hosts
└── .credentials            ← DB/Redis kimlik bilgileri (root:600)
```

---

## Yapılandırma

`/usr/local/srvctl/conf/srvctl.conf`:

```bash
DEFAULT_PHP_VERSION=8.3     # Varsayılan PHP versiyonu
SSH_PORT=2222               # SSH portu
WEB_ROOT=/var/www           # Web dizini kökü
BACKUP_DIR=/backups         # Yedekleme dizini
BACKUP_RETENTION_DAYS=30    # Yedek saklama süresi (gün)
DEPLOYER_USER=deployer      # Deploy kullanıcısı
```

---

## CI4 (CodeIgniter 4) Entegrasyonu

### İlk Deploy

```bash
# 1. Domain ekle
sudo srvctl domain add ci4ms.example.com --php=8.3

# 2. .env dosyasını hazırla
sudo cp /var/www/ci4ms.example.com/shared/.env.example \
        /var/www/ci4ms.example.com/shared/.env
sudo nano /var/www/ci4ms.example.com/shared/.env
```

### .env Örneği

```ini
CI_ENVIRONMENT = production
app.baseURL = 'https://ci4ms.example.com'

database.default.hostname = 127.0.0.1
database.default.database = db_ci4ms_example_com
database.default.username = usr_ci4ms_example_com
database.default.password = [.credentials dosyasından alın]
database.default.DBDriver = MySQLi
database.default.charset = utf8mb4

# Redis (CI4 Cache)
# Prefix: ci4ms_example_com:
```

### Deploy

```bash
sudo srvctl deploy ci4ms.example.com main
```

---

## Güvenlik Doğrulama Testleri

Domain ekledikten sonra şu testleri yapın:

```bash
# 1. Dosya izolasyonu: Domain A, Domain B'nin dosyasını okuyabilir mi?
sudo -u web_domain_a cat /var/www/domain_b/public_html/index.php
# ✅ Beklenen: Permission denied

# 2. DB izolasyonu: Domain A, Domain B'nin DB'sine erişebilir mi?
mysql -u usr_domain_a -p -e "USE db_domain_b"
# ✅ Beklenen: Access denied

# 3. Redis izolasyonu:
redis-cli --user redis_domain_a --pass PASS SET domain_b:key "hack"
# ✅ Beklenen: NOPERM

# 4. WAF testi:
curl "https://example.com/?id=1' OR 1=1--"
# ✅ Beklenen: 403 veya 444

# 5. AppArmor:
sudo aa-status | grep srvctl
# ✅ Beklenen: Tüm profiller "enforce" modda

# 6. Tam güvenlik denetimi:
sudo srvctl security audit
# ✅ Beklenen: Skor ≥ 90/100
```

---

## Otomatik İşlemler (Cron)

| Zamanlama | İşlem |
|-----------|-------|
| `0 3,15 * * *` | SSL sertifika yenileme |
| `0 4 * * *` | Günlük yedekleme |

---

## Sorun Giderme

### PHP-FPM socket hatası
```bash
systemctl status php8.3-fpm
journalctl -u php8.3-fpm --since "10 min ago"
```

### Nginx 502 Bad Gateway
```bash
# Socket'in varlığını kontrol et
ls -la /run/php/php8.3-fpm-*.sock

# Pool yapılandırmasını kontrol et
php-fpm8.3 -t
```

### chroot içinde dosya bulunamıyor
```bash
# chroot ortamını kontrol et
ls -la /var/www/example.com/dev/
ls -la /var/www/example.com/etc/

# Shared libraries'i güncelle (PHP güncellemesinden sonra)
ldd /usr/sbin/php-fpm8.3
```

### AppArmor hata veriyor
```bash
# Profili test moduna al
sudo aa-complain /etc/apparmor.d/srvctl-example_com

# Logları kontrol et
sudo dmesg | grep DENIED

# Düzelttikten sonra enforce'a geri al
sudo aa-enforce /etc/apparmor.d/srvctl-example_com
```

---

## Lisans

Bu araç özel kullanım için geliştirilmiştir.
