#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export BACKUP_DIR="$(mktemp -d)/backups"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/backup.sh"

# Saf yardımcı var mı?
assert_ok declare -F _backup_prepare_dir

# Per-run dizinini hazırla → 0700 olmalı, BACKUP_DIR kökü de 0700
run_dir="${BACKUP_DIR}/20260630_120000"
_backup_prepare_dir "$run_dir"

assert_ok test -d "$run_dir"
assert_eq "$(_stat_mode "$run_dir")" "700" "per-run dizini 0700"
assert_eq "$(_stat_mode "$BACKUP_DIR")" "700" "BACKUP_DIR kökü 0700"

# İçine bir artefakt koy, kilitleyiciyi çalıştır → 0600
echo "dummy-sql" > "${run_dir}/db_x.sql.gz"
_backup_secure_artifact "${run_dir}/db_x.sql.gz"
assert_eq "$(_stat_mode "${run_dir}/db_x.sql.gz")" "600" "artefakt 0600"

# ── safe_extract entegrasyonu: _backup_restore güvenli tar kullanıyor mu? ──
# Crafted ../ üyeli arşiv safe_extract tarafından reddedilmeli.
dotdot_stage="${WEB_ROOT}/esc_stage"; mkdir -p "$dotdot_stage"; echo "kotu" > "${dotdot_stage}/a"
dotdot_tgz="${run_dir}/evil-files.tar.gz"
( cd "$dotdot_stage" && tar -czf "$dotdot_tgz" "../esc_stage/a" )
dotdot_dest="${WEB_ROOT}/dest_dotdot"; mkdir -p "$dotdot_dest"
assert_fail safe_extract "$dotdot_tgz" "$dotdot_dest"
assert_eq "$(find "$dotdot_dest" -type f | wc -l | tr -d ' ')" "0" "dotdot: hedefe hic yazilmadi"

rm -rf "$WEB_ROOT" "$(dirname "$BACKUP_DIR")"
test_summary
