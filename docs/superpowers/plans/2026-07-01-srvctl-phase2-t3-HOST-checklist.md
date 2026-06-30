# Faz 2 / T3 — Ubuntu Host Doğrulama Kontrol Listesi

> macOS'ta uygulanan alt-küme: `_deploy_assert_safe_shared` predikatı (Task 1) +
> symlink kapıları wiring (Task 2). [HOST] task'ları (3 hook runuser, 4 composer
> runuser + reorder) **gerçek Ubuntu root host'ta** uygulanıp aşağıdaki senaryoyla
> doğrulanmalıdır.

## Ön koşul
- Ubuntu 22.04, root; `sudo bash install.sh` (T3 kodu kurulu).
- Bir test domain'i + git repo (`srvctl domain add test.com`, `.deploy-repo` ayarlı).

## 1. Hook web_user olarak çalışıyor (Task 3)
```bash
mkdir -p /var/www/test.com/shared/hooks
cat > /var/www/test.com/shared/hooks/pre-deploy.sh <<'H'
#!/bin/bash
id -un > /tmp/hookwho
H
chown web_test_com:web_test_com /var/www/test.com/shared/hooks/pre-deploy.sh
srvctl deploy test.com main
cat /tmp/hookwho          # beklenen: web_test_com  (root DEĞİL)
```

## 2. Composer web_user olarak çalışıyor (Task 4)
```bash
# repo'nun composer.json'ına ekli olsun:
#   "scripts": { "post-install-cmd": "id -un > /tmp/cwho" }
srvctl deploy test.com main
cat /tmp/cwho             # beklenen: web_test_com
# release dizini composer'dan önce web_user'a ait mi:
stat -c '%U' /var/www/test.com/releases/* | tail -1   # web_test_com
```

## 3. Malicious composer script root'a ulaşamaz (Task 4)
```bash
# repo composer.json: "post-install-cmd": "rm -rf /etc/srvctl/test-canary || true; touch /etc/srvctl/test-canary"
touch /etc/srvctl/test-canary   # önce var et
srvctl deploy test.com main
ls /etc/srvctl/test-canary      # HÂLÂ VAR (web_user /etc/srvctl'e dokunamaz)
```

## 4. shared/writable symlink saldırısı reddedilir (Task 2 — wiring macOS'ta hazır)
```bash
rm -rf /var/www/test.com/shared/writable
ln -s /etc /var/www/test.com/shared/writable   # web_user olarak (jail içinde)
srvctl deploy test.com main 2>&1 | grep -i "symlink.*reddedildi"  # deploy REDDEDİLİR
stat -c '%U' /etc                              # root (chown EDİLMEDİ — yetki yükseltme önlendi)
rm -f /var/www/test.com/shared/writable
```

## 5. shared/.env symlink atlanır (Task 2)
```bash
ln -s /etc/shadow /var/www/test.com/shared/.env
srvctl deploy test.com main 2>&1 | grep -i "shared/.env.*symlink.*atlandı"  # warn, atlandı
ls -l /var/www/test.com/releases/*/. env 2>/dev/null  # .env bağlanmadı
rm -f /var/www/test.com/shared/.env
```

## 6. Normal deploy regresyon yok
```bash
# Temiz repo + gerçek composer.json + .env + writable (normal dizin):
srvctl deploy test.com main          # başarılı: clone→composer(web)→hook(web)→switch→health
curl -sk -H "Host: test.com" https://127.0.0.1/ -o /dev/null -w '%{http_code}\n'  # 200/302
srvctl deploy test.com main --dry-run  # dry-run çalışır
srvctl rollback test.com               # rollback çalışır
```

## Başarı kriteri
- 1-2: hook + composer `web_<domain>` olarak çalışır (root değil).
- 3: malicious composer script root dosyalarına dokunamaz.
- 4: shared/writable symlink → deploy reddedilir, `/etc` chown edilmez.
- 5: shared/.env symlink → atlanır + warn.
- 6: normal deploy/dry-run/rollback regresyon yok.

Hepsi yeşilse T3 production'a hazırdır.
