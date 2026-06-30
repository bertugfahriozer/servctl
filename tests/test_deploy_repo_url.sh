#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/deploy.sh"

# ── Geçerli URL'ler kabul edilmeli ──
assert_ok _deploy_validate_repo_url "https://github.com/kullanici/repo.git"
assert_ok _deploy_validate_repo_url "https://gitlab.com/grup/alt/repo.git"
assert_ok _deploy_validate_repo_url "git@github.com:kullanici/repo.git"
assert_ok _deploy_validate_repo_url "ssh://git@host.example.com/repo.git"

# ── RCE / enjeksiyon vektörleri reddedilmeli ──
assert_fail _deploy_validate_repo_url "ext::sh -c 'touch ${WEB_ROOT}/pwned'"  # git remote-helper RCE
assert_fail _deploy_validate_repo_url "ext::sh"                                # :: transport
assert_fail _deploy_validate_repo_url "fd::17/foo"                            # :: transport
assert_fail _deploy_validate_repo_url "file:///etc/passwd"                    # yerel transport
assert_fail _deploy_validate_repo_url "--upload-pack=evil"                    # option-injection
assert_fail _deploy_validate_repo_url "-x"                                    # baştaki tire
assert_fail _deploy_validate_repo_url ""                                      # boş
assert_fail _deploy_validate_repo_url "https://h o.com/r"                     # boşluk
assert_fail _deploy_validate_repo_url "https://host/r;rm -rf /"               # boşluk/;
assert_fail _deploy_validate_repo_url "javascript://x"                        # bilinmeyen şema

# ── ext:: çalışmadığını yan-etkiyle de doğrula (predikat asla exec etmez) ──
rm -f "${WEB_ROOT}/pwned"
_deploy_validate_repo_url "ext::sh -c 'touch ${WEB_ROOT}/pwned'" || true
assert_eq "$(test -e "${WEB_ROOT}/pwned" && echo VAR || echo YOK)" "YOK" "predikat URL'yi exec etmiyor"

rm -rf "$WEB_ROOT"
test_summary
