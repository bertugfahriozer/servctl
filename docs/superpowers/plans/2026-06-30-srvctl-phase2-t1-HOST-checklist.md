# Faz 2 / T1 — Ubuntu Host Doğrulama Kontrol Listesi

> macOS'ta uygulanan T1 alt-kümesi (Task 1-4, 8) saf-bash mantığı kapsar.
> [HOST] task'ları (5 `_domain_apply_fs_ownership`, 6 `_harden_fs_apply/--revert`,
> 7 provisioning) **gerçek Ubuntu root host'ta** uygulanıp aşağıdaki senaryoyla
> doğrulanmalıdır. Bir staging sunucusunda çalıştırın; production'a uygulamadan
> önce her adımı yeşil görün.

## Ön koşul
- Ubuntu 22.04, root.
- `sudo bash install.sh` (T1 kodu kurulu).
- En az bir test domain'i (`srvctl domain add test.com`).

## 1. Yeni domain doğuştan hardened (Task 7)
```bash
srvctl domain add yeni.com --php=8.3
stat -c '%U %a' /var/www/yeni.com                 # beklenen: root 751
stat -c '%U %a' /var/www/yeni.com/public_html     # beklenen: web_yeni_com 750
stat -c '%U %a' /var/www/yeni.com/private/writable# beklenen: web_yeni_com 770
stat -c '%U %a' /var/www/yeni.com/dev             # beklenen: root 755
stat -c '%U %a' /var/www/yeni.com/.credentials    # beklenen: root 600
cat /usr/local/srvctl/state/yeni.com/hardened     # marker var
```

## 2. Web uygulaması çalışıyor (kırılım yok)
```bash
curl -sk -H "Host: yeni.com" https://127.0.0.1/ -o /dev/null -w '%{http_code}\n'  # 200/302
sudo -u web_yeni_com touch /var/www/yeni.com/private/writable/cache/test  # başarılı (yazabilir)
systemctl status php8.3-fpm | grep -i active     # FPM worker aktif
```

## 3. Tamper engellendi (RC1 kapalı)
```bash
# web kullanıcısı kontrol dosyasını silemez (base root-owned):
sudo -u web_yeni_com rm -f /var/www/yeni.com/.credentials; echo "exit=$?"  # exit!=0, Permission denied
sudo -u web_yeni_com sh -c 'echo x > /var/www/yeni.com/.deploy-repo'; echo "exit=$?"  # exit!=0
```

## 4. Fail-closed kapı (hardened domain'de bozulmuş dosya)
```bash
# root olarak .credentials'ı non-root yap (tamper simülasyonu):
chown web_yeni_com:web_yeni_com /var/www/yeni.com/.credentials
srvctl domain info yeni.com 2>&1 | grep -i "tamper\|reddedildi"  # fail-closed error
# geri al:
chown root:root /var/www/yeni.com/.credentials
```

## 5. Mevcut (eski-model) domain migrasyonu (Task 5, 6)
```bash
# Eski model bir domain (base web-owned) varsayalım: eski.com
srvctl security harden-fs eski.com                # dry-run: plan görünür, dokunmaz
stat -c '%U %a' /var/www/eski.com                 # hâlâ eski (web-owned) — dry-run dokunmadı
srvctl security harden-fs eski.com --apply        # uygula
stat -c '%U %a' /var/www/eski.com                 # root 751
cat /usr/local/srvctl/state/eski.com/hardened     # marker yazıldı
ls /usr/local/srvctl/state/eski.com/fs-before.txt # before-state kaydı var
# idempotent:
srvctl security harden-fs eski.com --apply        # tekrar — hata yok
# site hâlâ çalışıyor mu? (adım 2'yi eski.com için tekrarla)
```

## 6. Revert (güvenlik ağı)
```bash
srvctl security harden-fs eski.com --revert       # kayıttan geri yükle
stat -c '%U %a' /var/www/eski.com                 # eski sahipliğe döndü
ls /usr/local/srvctl/state/eski.com/hardened 2>&1 # marker silindi (No such file)
```

## 7. Toplu migrasyon
```bash
srvctl security harden-fs --all                   # tüm domain'ler dry-run
srvctl security harden-fs --all --apply           # tümünü uygula (dikkat: production'da önce dry-run)
```

## 8. Diğer komutlar regresyon yok
```bash
srvctl deploy yeni.com main                       # deploy çalışır (clone/composer/symlink)
srvctl backup create yeni.com && srvctl backup restore <dosya>  # backup/restore
srvctl domain rate-limit yeni.com strict          # vhost re-render + nginx reload
srvctl domain clone yeni.com kopya.com            # clone
```

## Başarı kriteri
- 1-4: yeni domain'ler root:root 751 base, web app çalışır, tamper engellenir, fail-closed error verir.
- 5-7: eski domain'ler güvenle migrate olur, idempotent, revert çalışır, site bozulmaz.
- 8: deploy/backup/rate-limit/clone regresyon yok.

Hepsi yeşilse T1 production'a hazırdır. Aksi halde ilgili task'ın koduna dön.
