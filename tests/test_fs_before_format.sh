#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/domain.sh"

base="${WEB_ROOT}/example.com"
mkdir -p "${base}/public_html" "${base}/private/writable"
echo "x" > "${base}/.credentials"
rec="$(mktemp)"
_fs_record_before "$base" "$rec"

me="$(whoami)"
assert_contains "$(cat "$rec")" "${base} ${me} "                "base satırı (sahip+mod)"
assert_contains "$(cat "$rec")" "${base}/public_html ${me} "    "public_html satırı"
assert_contains "$(cat "$rec")" "${base}/.credentials ${me} "   "credentials satırı"
# her satır 3 alan (path owner mode)
bad="$(awk 'NF!=3{c++} END{print c+0}' "$rec")"
assert_eq "$bad" "0" "tüm satırlar 3 alan"

rm -f "$rec"; rm -rf "$WEB_ROOT"
test_summary
