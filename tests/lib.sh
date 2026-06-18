#!/bin/bash
# Hafif bash test assertion kütüphanesi (harici bağımlılık yok)
set -uo pipefail

TESTS_RUN=0
TESTS_FAIL=0

_green() { printf '\033[0;32m%s\033[0m' "$1"; }
_red()   { printf '\033[0;31m%s\033[0m' "$1"; }

assert_eq() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$1" == "$2" ]]; then
        echo "  $(_green PASS) ${3:-}"
    else
        echo "  $(_red FAIL) ${3:-}  (beklenen='$2' alınan='$1')"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

assert_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$1" == *"$2"* ]]; then
        echo "  $(_green PASS) ${3:-}"
    else
        echo "  $(_red FAIL) ${3:-}  ('$2' bulunamadı)"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

assert_not_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$1" != *"$2"* ]]; then
        echo "  $(_green PASS) ${3:-}"
    else
        echo "  $(_red FAIL) ${3:-}  ('$2' bulunmamalıydı)"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

assert_ok() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        echo "  $(_green PASS) komut başarılı: $*"
    else
        echo "  $(_red FAIL) komut başarısız olmamalıydı: $*"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

assert_fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        echo "  $(_red FAIL) komut başarısız olmalıydı: $*"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    else
        echo "  $(_green PASS) komut beklendiği gibi başarısız: $*"
    fi
}

test_summary() {
    echo ""
    echo "  Toplam: ${TESTS_RUN}, Başarısız: ${TESTS_FAIL}"
    [[ "$TESTS_FAIL" -eq 0 ]]
}
