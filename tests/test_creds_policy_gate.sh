#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB_ROOT="$(mktemp -d)"
export SRVCTL_STATE_DIR="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

mkdir -p "${WEB_ROOT}/example.com"
cat > "${WEB_ROOT}/example.com/.credentials" <<EOF
DOMAIN=example.com
DB_PASS=Secr3t
EOF

# migrate edilmemiş (marker yok): warn (stderr) + değerler okunur
unset DB_PASS
read_credentials example.com 2>/dev/null
assert_eq "${DB_PASS:-}" "Secr3t" "migrate edilmemiş: değer okunur (warn stderr)"

# hardened marker + root-owned-değil (macOS) → tamper → read_credentials EXIT eder
mkdir -p "${SRVCTL_STATE_DIR}/example.com"; : > "${SRVCTL_STATE_DIR}/example.com/hardened"
assert_fail bash -c "
  export WEB_ROOT='${WEB_ROOT}' SRVCTL_STATE_DIR='${SRVCTL_STATE_DIR}'
  source '${REPO_ROOT}/lib/core.sh'
  read_credentials example.com
"

rm -rf "$WEB_ROOT" "$SRVCTL_STATE_DIR"
test_summary
