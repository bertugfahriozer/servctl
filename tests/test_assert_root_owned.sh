#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

# macOS dev kutusunda her şey 'whoami' sahipli (root değil) → tüm vakalar reddedilmeli.

# 1) root-olmayan sahipli düz dosya → 1
f="${WEB_ROOT}/example.com/.credentials"
mkdir -p "${WEB_ROOT}/example.com"
: > "$f"
assert_fail assert_root_owned_path "$f"

# 2) symlink hedefi → 1 (symlink kendisi reddedilir)
real="${WEB_ROOT}/example.com/real.cred"; : > "$real"
linkp="${WEB_ROOT}/example.com/link.cred"
ln -s "$real" "$linkp"
assert_fail assert_root_owned_path "$linkp"

# 3) grup/diğer-yazılabilir dosya → 1
# NOT: macOS'ta sahip root değil olduğu için sahip kontrolünde başarısız olur,
#      mod kontrolüne (grp & 2 / oth & 2) ulaşmaz. Mode logic untestable without
#      a root-owned file on macOS.
ww="${WEB_ROOT}/example.com/ww.cred"; : > "$ww"; chmod 666 "$ww"
assert_fail assert_root_owned_path "$ww"

# 4) grup/diğer-yazılabilir ÜST dizin → 1
# NOT: macOS'ta dosya/üst dizinler root-olmayan sahipli olduğu için sahip
#      kontrolünde başarısız olur, mode kontrolüne ulaşmaz. Mode logic kodu
#      root entegrasyonunda test edilir (şu an test dışında).
mkdir -p "${WEB_ROOT}/wwsite"; chmod 777 "${WEB_ROOT}/wwsite"
wf="${WEB_ROOT}/wwsite/.credentials"; : > "$wf"
assert_fail assert_root_owned_path "$wf"

# 5) var olmayan yol → 1
assert_fail assert_root_owned_path "${WEB_ROOT}/yok/dosya"

rm -rf "$WEB_ROOT"
test_summary
