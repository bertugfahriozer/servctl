#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/deploy.sh"

d="$(mktemp -d)"
touch "${d}/regular"
mkdir "${d}/dir"
ln -s /etc "${d}/evil"                     # symlink (mevcut hedef)
ln -s /yok_boyle_bir_yol "${d}/dangling"   # dangling symlink

# normal dosya/dizin → güvenli (0)
assert_ok   _deploy_assert_safe_shared "${d}/regular"
assert_ok   _deploy_assert_safe_shared "${d}/dir"
# symlink → güvensiz (1) — chown -R /etc kaçışını engeller
assert_fail _deploy_assert_safe_shared "${d}/evil"
assert_fail _deploy_assert_safe_shared "${d}/dangling"
# var olmayan → güvensiz (1)
assert_fail _deploy_assert_safe_shared "${d}/yok"
# predikat asla exit etmez (cari kabukta çağrı testi sonrası buraya gelinir)
assert_eq "tamam" "tamam" "predikat exit etmiyor"

rm -rf "$d" "$WEB_ROOT"
test_summary
