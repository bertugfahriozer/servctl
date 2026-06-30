#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

stage="${WEB_ROOT}/stage"; mkdir -p "$stage"

# ── 1) TEMİZ arşiv: düzgün çıkarılır, return 0 ──
mkdir -p "${stage}/clean"; echo "merhaba" > "${stage}/clean/file.txt"
clean_tgz="${WEB_ROOT}/clean.tgz"
tar -czf "$clean_tgz" -C "${stage}/clean" file.txt
dest_ok="${WEB_ROOT}/dest_ok"; mkdir -p "$dest_ok"
assert_ok safe_extract "$clean_tgz" "$dest_ok"
assert_eq "$(cat "${dest_ok}/file.txt" 2>/dev/null)" "merhaba" "temiz arşiv çıkarıldı"

# ── 2) MUTLAK yol üyeli arşiv → red, dest'e yazma yok ──
echo "kotu" > "${WEB_ROOT}/abs_src.txt"
abs_tgz="${WEB_ROOT}/abs.tgz"
tar -cPzf "$abs_tgz" -C / "${WEB_ROOT}/abs_src.txt"   # mutlak üye (-P leading / korur)
# doğrula: listede mutlak üye var
assert_contains "$(tar -tzf "$abs_tgz")" "/" "abs arşivinde mutlak üye var"
dest_abs="${WEB_ROOT}/dest_abs"; mkdir -p "$dest_abs"
assert_fail safe_extract "$abs_tgz" "$dest_abs"
assert_eq "$(find "$dest_abs" -type f | wc -l | tr -d ' ')" "0" "mutlak: dest'e yazılmadı"

# ── 3) ../escape üyeli arşiv → red ──
esc_stage="${WEB_ROOT}/esc"; mkdir -p "$esc_stage"; echo "x" > "${esc_stage}/a"
dotdot_tgz="${WEB_ROOT}/dotdot.tgz"
( cd "$esc_stage" && tar -czf "$dotdot_tgz" "../esc/a" )   # üye yolu '..' içerir
assert_contains "$(tar -tzf "$dotdot_tgz")" ".." "dotdot arşivinde .. üye var"
dest_dd="${WEB_ROOT}/dest_dd"; mkdir -p "$dest_dd"
assert_fail safe_extract "$dotdot_tgz" "$dest_dd"
# Hedef klasör boş kaldı (çıkarma başarısız)
assert_eq "$(find "$dest_dd" -type f | wc -l | tr -d ' ')" "0" "dotdot: dışarı kaçış yok"

# ── 4) symlink üyeli arşiv → red ──
ln_stage="${WEB_ROOT}/lnstage"; mkdir -p "$ln_stage"
echo "data" > "${ln_stage}/real.txt"
ln -s /etc/passwd "${ln_stage}/evil_link"
link_tgz="${WEB_ROOT}/link.tgz"
tar -czf "$link_tgz" -C "$ln_stage" evil_link real.txt
dest_ln="${WEB_ROOT}/dest_ln"; mkdir -p "$dest_ln"
assert_fail safe_extract "$link_tgz" "$dest_ln"
assert_eq "$(find "$dest_ln" -mindepth 1 | wc -l | tr -d ' ')" "0" "symlink: dest'e yazılmadı"

# ── 5) hardlink üyeli arşiv → red ──
hl_stage="${WEB_ROOT}/hlstage"; mkdir -p "$hl_stage"
echo "realdata" > "${hl_stage}/real.txt"
ln "${hl_stage}/real.txt" "${hl_stage}/hardlink.txt"
hardlink_tgz="${WEB_ROOT}/hardlink.tgz"
tar -czf "$hardlink_tgz" -C "$hl_stage" real.txt hardlink.txt
# Doğrula: hardlink verbose modda 'h' ile başlar
assert_contains "$(tar -tvzf "$hardlink_tgz")" "hrw" "hardlink arşivinde hardlink üyesi var"
dest_hl="${WEB_ROOT}/dest_hl"; mkdir -p "$dest_hl"
assert_fail safe_extract "$hardlink_tgz" "$dest_hl"
assert_eq "$(find "$dest_hl" -type f | wc -l | tr -d ' ')" "0" "hardlink: dest'e yazılmadı"

# ── 6) var olmayan arşiv → red ──
assert_fail safe_extract "${WEB_ROOT}/yokboyle.tgz" "$dest_ok"

rm -rf "$WEB_ROOT"
test_summary
