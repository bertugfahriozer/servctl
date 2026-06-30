#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# Yardımcı: temiz bir alt-kabukta core.sh'ı kaynak gösterip load_config'i
# verilen env ile yeniden çağırır. error/exit alt-kabukta kalır.
run_load() {
    # $1=SSH_PORT $2=WEB_ROOT
    SSH_PORT="$1" WEB_ROOT="$2" bash -c '
        source "'"${REPO_ROOT}"'/lib/core.sh"   # kaynakta bir kez load_config (defaultlar ok)
        load_config                              # env değerleriyle tekrar doğrula
    ' >/dev/null 2>&1
}

# Yardımcı: YALNIZCA source eder — ikinci load_config çağrısı YOK.
# Bu, kaynak-zamanı doğrulamasını (load_config ilk çağrısını) test eder.
# Gerçek üretim kodu da core.sh'ı yalnızca bir kez kaynak gösterir.
run_source_only() {
    # $1=SSH_PORT $2=WEB_ROOT
    SSH_PORT="$1" WEB_ROOT="$2" bash -c '
        source "'"${REPO_ROOT}"'/lib/core.sh"   # kaynak-zamanı load_config — tek çağrı
    ' >/dev/null 2>&1
}

# Geçerli değerler: başarılı
assert_ok   run_load "2222" "/var/www"
assert_ok   run_load "443"  "/srv/web"

# Geçersiz SSH_PORT: sayı değil / aralık dışı
assert_fail run_load "22; reboot" "/var/www"
assert_fail run_load "abc"        "/var/www"
assert_fail run_load "70000"      "/var/www"

# Geçersiz WEB_ROOT: mutlak yol değil
assert_fail run_load "2222" "relative/path"
assert_fail run_load "2222" "../etc"

# Kaynak-zamanı doğrulaması: validate_uint, load_config'in ilk çağrısında
# (source anında) tanımlı olmalı — ikinci çağrıya gerek yok.
# Bu test, declare -F guard hatasını (T17 gözden geçirme bulgusu) yakalar.
assert_ok   run_source_only "2222" "/var/www"
assert_fail run_source_only "99999" "/var/www"
assert_fail run_source_only "abc"   "/var/www"

rm -rf "$WEB_ROOT"
test_summary
