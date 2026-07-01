# Güvenilir Edge-IP Senkronu (Cloudflare + UptimeRobot) — Tasarım

**Tarih:** 2026-07-01
**Durum:** Onaylandı (brainstorming), spec incelemesi bekliyor

## Amaç

Cloudflare ve UptimeRobot'un yayınladığı IP listelerini otomatik alıp srvctl'in
**allowlist**'ine işleyen ve her gün tazeleyen bir mekanizma. İki hedef:

1. **Allowlist:** CF + UptimeRobot IP'leri fail2ban / rate-limit tarafından **asla
   yanlışlıkla banlanmasın**. (Genel erişim 80/443'te açık kalır — origin kilidi DEĞİL.)
2. **Real-IP restorasyonu:** nginx, Cloudflare arkasındayken GERÇEK ziyaretçi IP'sini
   görsün (`CF-Connecting-IP`) — böylece rate-limit/fail2ban/loglar doğru IP üzerinde çalışır.

## Kapsam dışı (YAGNI)

- **Origin kilidi** (80/443'e sadece CF+UR'den izin, gerisini deny). Ayrı, daha büyük iş.
- **UFW allow / nginx `allow` kuralları** — genel erişim açıkken gereksiz.
- Cloudflare API entegrasyonu (o `lib/cloudflare.sh`'te, ayrı konu).

## Mimari

Yeni bağımsız modül **`lib/trusted.sh`** (`cmd_trusted`), srvctl'in modül-başına-konsept
lazy-load desenine uyar. `ip.sh` şişmez. Komut: `srvctl trusted <sync|list>`.

Akış: **fetch → doğrula → sanity → (başarıda) atomik kaydet → uygula (fail2ban ignoreip +
nginx real-ip) → reload.** Günlük cron `srvctl trusted sync` çağırır.

### Bileşen sınırları

| Birim | Sorumluluk | Bağımlılık |
|-------|-----------|-----------|
| `cmd_trusted` | Alt-komut yönlendirme + `require_root` | core.sh |
| `_trusted_sync` | Kaynakları döngüle, fetch+validate+sanity, apply çağır | fetch/parse/apply |
| `_trusted_fetch` | `curl -sf --max-time` ile tek URL indir | curl |
| `_trusted_parse_validate` | Ham metni satır-satır IP/CIDR doğrula, temiz liste üret | core.sh `validate_ip_or_cidr` (satır 141) |
| `_trusted_sane` | Liste boş/çöp/anlamsız-sayıda mı (kaynak-başına min) | — |
| `_trusted_render_realip` | CF listesinden nginx `set_real_ip_from` bloğu üret | — |
| `_trusted_apply_ignoreip` | ignoreip'i türet (base+manuel+trusted), jail.local'e yaz, reload | fail2ban |
| `_trusted_list` | Kaynak-başına sayı + son sync zamanı | — |

## Yapılandırma

`load_config` (core.sh) içinde varsayılanlar — böylece mevcut kurulumlar conf'u
düzenlemeden çalışır; `conf/srvctl.conf`'ta yorumlu olarak keşfedilebilir dururlar.

```
TRUSTED_SYNC_ENABLED=true
TRUSTED_SOURCES="cloudflare uptimerobot"
TRUSTED_STATE_DIR=/etc/srvctl/trusted
CLOUDFLARE_IPS_V4_URL="https://www.cloudflare.com/ips-v4"
CLOUDFLARE_IPS_V6_URL="https://www.cloudflare.com/ips-v6"
UPTIMEROBOT_IPS_URL="https://uptimerobot.com/inc/files/ips/IPv4andIPv6.txt"
```

> **Açık madde:** UptimeRobot URL'i HOST testinde `curl` ile teyit edilecek; kaynak
> formatı (satır-başına IP) beklendiği gibi mi doğrulanacak. URL config'te olduğu için
> gerekirse kod değişmeden düzeltilir.

## Yönetilen durum

`${TRUSTED_STATE_DIR}/` altında kaynak-başına son-iyi (last-good) dosya:
- `cloudflare.conf` — CF v4 + v6 CIDR'leri (birleşik).
- `uptimerobot.conf` — UptimeRobot IP'leri.

Manuel `ip whitelist` girdileri (`/etc/srvctl/ip-whitelist.conf`) AYRI kalır; sync ona
dokunmaz. Bu ayrım, tazeleme sırasında eski CF/UR IP'lerini temizlerken kullanıcının
manuel girdilerini korur.

## Uygulama hedefleri (2)

### 1) fail2ban `ignoreip` (CF + UR)
`ignoreip` satırı her sync'te **tam olarak türetilir**:
```
ignoreip = 127.0.0.1/8 <manuel-whitelist> <cloudflare.conf> <uptimerobot.conf>
```
dedup'lı, tek satır, `jail.local`'e yazılır, `fail2ban reload`. Sonuç: CF+UR asla banlanmaz.

Yan fayda: mevcut "`ip whitelist remove` ignoreip'i temizlemiyor" açığı da kapanır, çünkü
satır artık kaynaklardan tamamen türetiliyor (append-sed yerine).

### 2) nginx real-IP (yalnız Cloudflare)
`/etc/nginx/conf.d/srvctl-cloudflare-realip.conf` her sync'te yeniden üretilir:
```
# srvctl — Cloudflare real IP (otomatik oluşturuldu)
set_real_ip_from <her CF v4/v6 CIDR>;
real_ip_header CF-Connecting-IP;
```
`nginx -t && systemctl reload nginx`. UptimeRobot proxy olmadığı için real-IP almaz.
Vhost template'lerine dokunulmaz (real-ip http-context global conf.d'de yeterli).

## Veri akışı

```
cron / manuel  →  srvctl trusted sync
  her kaynak için:
    _trusted_fetch(url) → ham tmp        (başarısız → last-good koru, uyar, devam)
    _trusted_parse_validate(ham) → temiz  (geçersiz satır ayıklanır)
    _trusted_sane(temiz) ? evet : last-good koru, uyar
    atomik mv → ${STATE_DIR}/<kaynak>.conf
  _trusted_apply_ignoreip()   → jail.local + fail2ban reload
  _trusted_render_realip(cf)  → conf.d + nginx reload
  log_action + (opsiyonel) notify (değişiklik olduysa)
```

## Hata yönetimi / fail-safe

- Her kaynak **bağımsız**: biri fail ederse diğerleri işlenir.
- Fetch başarısız / boş / sanity başarısız → o kaynağın **last-good dosyası korunur**
  (asla silinmez), uyarı loglanır. Geçici ağ hatası allowlist'i bozmaz.
- Sadece başarı + sanity geçince atomik `mv` ile güncelle.
- Sanity min-sayılar (regresyon/boş-yanıt koruması): `cloudflare.conf` ≥ 8 satır,
  `uptimerobot.conf` ≥ 5 satır. (CF ~22 aralık, UR ~50+ IP yayınlar.)
- init'te fetch başarısızsa: uyar + devam (init'i düşürme).

## init + cron

`_install_*` zincirinde nginx + fail2ban adımlarından SONRA yeni adım:
- `TRUSTED_SYNC_ENABLED` ise: ilk `srvctl trusted sync` (ağ yoksa uyar-devam) + günlük cron:
  ```
  30 2 * * * /usr/local/srvctl/bin/srvctl trusted sync >> /usr/local/srvctl/logs/trusted.log 2>&1
  ```
  Mevcut root-crontab grep-guard deseniyle eklenir. Saat 02:30 boş (SSL 03:15, backup 04:00,
  AIDE 05:30, ClamAV 06:00 ile çakışmaz).

## Test

Saf-bash birim testleri (`tests/test_trusted.sh`), fetch fixture ile enjekte:
`SRVCTL_TRUSTED_FIXTURE_DIR` set ise `_trusted_fetch` curl yerine oradan okur.

| Test | Girdi | Beklenen |
|------|-------|----------|
| parse+validate | CF örnek + çöp satırlar | yalnız geçerli CIDR'ler |
| sane (boş) | boş liste | false |
| sane (kısa) | min-altı | false |
| sane (ok) | yeterli | true |
| render_realip | CF fixture | tam `set_real_ip_from`+`real_ip_header` bloğu |
| ignoreip compute | base+manuel+CF+UR fixture | tek satır, dedup'lı |
| fail-safe | bir iyi + bir boş kaynak | iyi uygulanır, boş kaynak last-good'u korur |

**HOST-only** (macOS/OrbStack'te doğrulanamaz): gerçek curl fetch, fail2ban reload,
nginx reload, cron kaydı, init adımı. fail2ban-apply gerçek VM (Multipass 22.04) ister.

## Dokunulan dosyalar

- **Yeni:** `lib/trusted.sh`, `tests/test_trusted.sh`
- **Değişen:** `bin/srvctl` (dispatch: `trusted) _load_and_run trusted cmd_trusted "${@:2}"`),
  `lib/core.sh` (yalnız load_config varsayılanları; IP doğrulama için mevcut
  `validate_ip_or_cidr` kullanılır),
  `conf/srvctl.conf` (yorumlu yeni anahtarlar), `lib/init.sh` (adım + cron),
  `completions/srvctl.bash`, `completions/srvctl.zsh`, `README.md`
- **Değişmeyen:** vhost template'leri, `install.sh` (lib glob + conf-preserve yeterli;
  varsayılanlar load_config'te olduğu için mevcut kurulumlar da çalışır)

## Başarı ölçütü

- `srvctl trusted sync` CF+UR IP'lerini alıp fail2ban ignoreip'e ve CF real-ip conf'una
  işler; `nginx -t` geçer, fail2ban reload olur.
- Kaynak fetch başarısızken mevcut allowlist bozulmaz.
- Günlük cron kurulu; init default-on.
- Tüm saf-bash testleri geçer (`bash tests/run.sh`).
