# Tasarım: İnteraktif `domain add` Sihirbazı + Per-Domain Rate-Limit Profilleri

**Tarih:** 2026-06-18
**Durum:** Onaylandı (uygulama bekliyor)
**Kapsam:** `srvctl` — iki özellik: (1) argümansız `domain add` interaktif sihirbazı, (2) PHP-geneli, framework-agnostik per-domain rate-limit profilleri.

---

## 1. Amaç ve Bağlam

`srvctl`, Ubuntu 22.04 üzerinde root olarak çalışan, CLI tabanlı güvenlik-odaklı sunucu yönetim aracıdır (bkz. [README.md](../../../README.md), [CLAUDE.md](../../../CLAUDE.md)).

Mevcut durumda iki eksik:

- **Rate limiting tüm domain'ler için sabit.** Zone'lar global olarak [lib/init.sh](../../../lib/init.sh) içinde tanımlı (`general 10r/s`, `login 5r/m`, `api 30r/s`, `conn_per_ip`). vhost template'leri (`templates/nginx/vhost.conf.tpl`, `vhost-ssl.conf.tpl`) tüm domain'ler için `limit_req zone=general burst=20` + `limit_conn conn_per_ip 50` değerlerini hardcode eder. `api` zone'u tanımlı ama hiç kullanılmaz. Domain başına kontrol yok.
- **`domain add` yalnızca flag-driven.** Argümansız `srvctl domain add` hata verip çıkar; rehberli bir kurulum akışı yok.

Bu tasarım her ikisini de ekler. Rate-limit/sertleştirme tarafı **ci4ms'e özel değil**, geniş PHP projelerine (CI4, Laravel, Symfony, düz PHP) uyacak şekilde generic kurgulanır.

---

## 2. Rate-Limit Mimarisi (temel karar)

nginx'te `limit_req` için **temel hız (r/s) zone tanımında sabittir**; `location` bloğunda yalnızca `burst` değiştirilebilir. Dolayısıyla farklı hız seviyeleri farklı zone'lar gerektirir.

**Seçilen yaklaşım: sabit "kademe" zone seti + profil hangi zone'u seçeceğini belirler.**

- `init.sh`, nginx.conf'a profil başına birer zone tanımlar; hepsi `$binary_remote_addr` anahtarlı, yani **IP başına global** (tüm `server_name`'ler arasında paylaşılan kova) → brute-force'a karşı en sıkı seçenek.
- Her domain'in vhost'u, kendi profiline uyan zone'u referans eder.
- Zone sayısı **domain sayısından bağımsız sabittir** → bellek güvenli.

### Reddedilen alternatifler

- **Tek zone seti, sadece `burst` değiştir:** base rate domain başına değişemediği için profiller anlamsız olur.
- **Domain başına ayrı zone:** her domain × her IP ayrı kova → saldırgan domain başına ayrı brute-force bütçesi kazanır (**daha az** güvenli) + bellek domain sayısıyla şişer.

---

## 3. Profil Tanımları

Profiller trafik/güvenlik karakterine göre adlandırılır; framework'e bağlı değildir.

| Profil | general req | login/admin req | conn/IP | Hedef kullanım |
|--------|-------------|-----------------|---------|----------------|
| `strict` | 3 r/s, burst 10 | 3 r/dk, burst 3 | 20 | admin-ağırlıklı / düşük trafik / iç araç |
| `standard` *(varsayılan)* | 10 r/s, burst 20 | 5 r/dk, burst 5 | 50 | tipik PHP sitesi (CI4/Laravel/Symfony) |
| `relaxed` | 30 r/s, burst 50 | 10 r/dk, burst 8 | 100 | yüksek trafikli kamuya açık site |
| `api` | 60 r/s, burst 100 | 10 r/dk, burst 8 | 200 | API/JSON ağırlıklı backend |

- Profil tanımları **`conf/rate-profiles.conf`** içinde **veri** olarak durur (kod değil). Yeni profil eklemek için kod değişmez; conf dosyasına satır eklenir.
- Geçersiz/bilinmeyen profil adı → `standard`'a düşülür + `warn` ile uyarılır.
- Her profil; req zone adı, req burst, login zone adı, login burst ve conn limitini taşır.

### `conf/rate-profiles.conf` formatı (öneri)

```
# profil:req_zone:req_burst:login_zone:login_burst:conn_limit
strict:rl_strict:10:login_strict:3:20
standard:rl_standard:20:login_standard:5:50
relaxed:rl_relaxed:50:login_relaxed:8:100
api:rl_api:100:login_relaxed:8:200
```

Zone'ların kendileri (rate değerleriyle) `init.sh` tarafından nginx.conf'a yazılır; bu dosya yalnızca profilin hangi zone'u + burst/conn değerlerini kullanacağını eşler.

---

## 4. Veri & Dosya Modeli

### 4.1 Parametreli vhost template'leri

`templates/nginx/vhost.conf.tpl` ve `templates/nginx/vhost-ssl.conf.tpl` içindeki hardcoded rate-limit değerleri token'a dönüşür:

| Token | Anlam |
|-------|-------|
| `{{RL_REQ_ZONE}}` | general `limit_req` zone adı |
| `{{RL_REQ_BURST}}` | general burst değeri |
| `{{RL_LOGIN_ZONE}}` | hassas/login `limit_req` zone adı |
| `{{RL_LOGIN_BURST}}` | hassas/login burst değeri |
| `{{RL_CONN}}` | `limit_conn conn_per_ip` değeri |
| `{{RL_SENSITIVE_PATHS}}` | hassas yol regex'i (Bölüm 6) |

`render_template` (mevcut core helper) bu token'ları doldurur.

### 4.2 Per-domain meta dosyası

**Yeni dosya: `/var/www/<domain>/.srvctl-meta`** (root:644, sır içermez).

- Seçilen rate-limit profilini ve domain'e özgü ayarları (örn. hassas yol override'ı) tutar.
- `.credentials` yalnızca sır kalmaya devam eder (root:600). Sır ile sır-olmayan meta ayrılır.
- **Kritik:** SSL alımı, `php-switch`, `clone`, `staging` gibi vhost'u yeniden render eden tüm akışlar profili buradan okur → yeniden render'da profil **kaybolmaz**.
- core.sh'e küçük yardımcılar: `read_meta <domain>` / `write_meta <domain> <key> <value>` (mevcut `read_credentials` desenine benzer).

Örnek içerik:

```
RATE_PROFILE=standard
SENSITIVE_PATHS=login|admin|auth|panel|dashboard|wp-login\.php|wp-admin|user/login
```

### 4.3 `init.sh` zone üretimi

`init.sh`'in rate-limit bloğu, tek `general/login/api` yerine profil-kademe zone setini üretir:

- `limit_req_zone ... zone=rl_strict:10m rate=3r/s;` … (her profil için)
- `limit_req_zone ... zone=login_strict:10m rate=3r/m;` … (her login kademesi için)
- `limit_conn_zone ... zone=conn_per_ip:10m;` (tek conn zone yeterli; conn limiti location'da değişir)
- `limit_req_status 429;` ve `limit_conn_status 429;` (varsayılan 503 yerine doğru semantik)

**Geriye uyum:** eski `general`/`login`/`api` zone adları korunur (veya `rl_standard`/`login_standard`'a alias'lanır) ki güncellenmemiş eski vhost'lar kırılmasın.

---

## 5. `domain rate-limit` Komutu

`bin/srvctl` ve `cmd_domain` dispatch'ine yeni alt-komut:

```
srvctl domain rate-limit <domain> <profil>   # profili değiştir
srvctl domain rate-limit <domain> --show      # mevcut profil + etkin değerler
srvctl domain rate-limit --list               # tüm profilleri ve değerlerini listele
```

**Profil değiştirme akışı:**

1. `require_root`, domain doğrula (`domain_exists`), profil doğrula (geçersizse hata).
2. `.srvctl-meta` içinde `RATE_PROFILE` güncelle.
3. Aktif template'i seç (SSL aktifse `vhost-ssl.conf.tpl`, değilse `vhost.conf.tpl`) ve profil token'larıyla render et.
4. **Atomic güvenlik:** mevcut vhost'u yedekle → yeniyi yaz → `nginx_test`. Test **başarısızsa eski config'e geri dön** (deploy rollback mantığı) ve hata ver; canlıya bozuk config çıkmaz.
5. Başarılıysa `systemctl reload nginx` + `log_action` + changelog kaydı.

`--show` / `--list` salt-okunur; meta ve `rate-profiles.conf`'tan okur.

---

## 6. İnteraktif Sihirbaz (bare `domain add`)

`_domain_add` başına bir dal: hiç pozisyonel domain argümanı yoksa `_domain_add_wizard` çağrılır. **Argümanlı çağrı bire bir eski davranışı korur** (geriye uyumlu; `--php=` vb. aynen çalışır).

Sihirbaz mevcut `confirm`/`read` konvansiyonuyla (Türkçe, `evet/hayır`) sırayla sorar — hepsi varsayılanlı:

1. **Domain adı** (zorunlu, format doğrulaması).
2. **PHP sürümü** (varsayılan `DEFAULT_PHP_VERSION`, `php_version_exists` ile doğrula).
3. **Rate-limit profili** (varsayılan `standard`; Bölüm 3 listesi).
4. **SSL şimdi alınsın mı?** (evet → certbot; hayır → atla).
5. **Hassas yol seti** onayı (varsayılan generic liste — Bölüm 7).
6. **Özet ekran → `confirm`** → ardından mevcut 10 adımlı kurulum **aynen** çalışır.

Sihirbaz yalnızca **girdi toplar**; kurulum mantığı tek noktada kalır (kod tekrarı yok). Toplanan değerler (`domain`, `php_version`, `rate_profile`, `do_ssl`, `sensitive_paths`) mevcut `_domain_add` gövdesine aktarılır; profil `.srvctl-meta`'ya yazılır ve vhost render'ında kullanılır.

---

## 7. Generic PHP Sertleştirme

- **Hassas yol limiti generic'tir** (ci4ms'e özel değil). Varsayılan `{{RL_SENSITIVE_PATHS}}`:
  `login|admin|auth|panel|dashboard|wp-login\.php|wp-admin|user/login`
  (yaygın PHP/CMS giriş yolları). Domain başına `.srvctl-meta`'dan override edilebilir.
- **Engellenen dizin regex'i** geniş framework'leri kapsayacak şekilde genişler. Mevcut CI4 listesine (`app|system|vendor|modules|writable|private|tests|node_modules|\.composer`) ek olarak Laravel/Symfony dizinleri: `storage|bootstrap|config|database|routes|resources|var` ve `\.env\..*`. docroot zaten `public_html` olduğundan bu **defense-in-depth**'tir.
- **HTTP durumları:** `limit_req_status 429` / `limit_conn_status 429` (varsayılan 503 yerine; doğru semantik, bot'lara daha az sızıntı).

---

## 8. Güvenlik Gerekçesi & Doğrulama

**Güvenlik gerekçesi:**

- Per-IP global zone'lar → bir saldırgan IP'si tüm domain'lerde **aynı** brute-force bütçesine tabi (domain başına ayrı kovadan daha sıkı).
- Re-render'da **`nginx -t` geçmezse otomatik geri dönüş** → bozuk config canlıya çıkmaz, kesinti olmaz.
- Bellek sınırlı: zone sayısı domain sayısıyla artmaz.

**`security audit` eklemesi:** [lib/security.sh](../../../lib/security.sh) zaten nginx.conf'ta `limit_req_zone` varlığını kontrol ediyor. Buna ek küçük kontrol: her **aktif domain'in** vhost'unda `limit_req` direktifi mevcut mu (profil gerçekten uygulanmış mı).

**Doğrulama senaryoları:**

- `srvctl domain rate-limit example.com strict` sonrası hızlı ardışık `curl` istekleri → `429` döner.
- `srvctl domain rate-limit example.com --show` doğru profil ve etkin değerleri basar.
- `srvctl domain rate-limit --list` profilleri listeler.
- Argümansız `srvctl domain add` → sihirbaz tam akışı kurar; oluşan vhost'ta seçilen profil token'ları doğru.
- Argümanlı `srvctl domain add example.com --php=8.3` davranışı **değişmemiş** (regresyon kontrolü).
- Geçersiz profil adı → `standard`'a düşer + uyarı.
- Bozuk template (bilinçli) → re-render eski config'e döner, nginx ayakta kalır.

---

## 9. Kapsam Dışı (YAGNI)

- Çok-framework "application type" matrisi (ci4/laravel/static seçimi).
- docroot subdir seçimi (mevcut `public_html` + front-controller deseni korunur).
- Dinamik/kullanıcı-tanımlı profil **oluşturma komutu** — `rate-profiles.conf` elle düzenlenebilir, yeterli.

---

## 10. Etkilenen Dosyalar (özet)

| Dosya | Değişiklik |
|-------|-----------|
| `lib/domain.sh` | `rate-limit` alt-komutu + dispatch; `_domain_add_wizard`; `_domain_add` profil/meta entegrasyonu; engellenen-dizin regex genişlemesi |
| `lib/init.sh` | kademe zone seti üretimi; `limit_req_status/limit_conn_status`; eski zone alias'ları |
| `lib/core.sh` | `read_meta` / `write_meta` yardımcıları |
| `lib/security.sh` | aktif domain vhost'larında `limit_req` varlık kontrolü |
| `templates/nginx/vhost.conf.tpl` | rate-limit token'ları |
| `templates/nginx/vhost-ssl.conf.tpl` | rate-limit token'ları |
| `conf/rate-profiles.conf` | **yeni** — profil tanımları (veri) |
| `bin/srvctl` | (gerekirse) help metni; `domain` dispatch zaten alt-komutu içeride çözüyor |
| `completions/srvctl.bash`, `completions/srvctl.zsh` | `rate-limit` alt-komutu + profil adları |
| `install.sh` | `conf/rate-profiles.conf` kopyalama (conf koruma mantığına uygun) |
| `README.md` | yeni komut ve profil dokümantasyonu |
