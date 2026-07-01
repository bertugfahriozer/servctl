#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"

assert_eq "$TRUSTED_SYNC_ENABLED" "true" "TRUSTED_SYNC_ENABLED varsayılan true"
assert_eq "$TRUSTED_STATE_DIR" "/etc/srvctl/trusted" "TRUSTED_STATE_DIR varsayılan"
assert_contains "$TRUSTED_SOURCES" "cloudflare" "TRUSTED_SOURCES cloudflare içerir"
assert_contains "$TRUSTED_SOURCES" "uptimerobot" "TRUSTED_SOURCES uptimerobot içerir"
assert_contains "$CLOUDFLARE_IPS_V4_URL" "cloudflare.com/ips-v4" "CF v4 URL varsayılan"
assert_contains "$CLOUDFLARE_IPS_V6_URL" "cloudflare.com/ips-v6" "CF v6 URL varsayılan"
assert_contains "$UPTIMEROBOT_IPS_URL" "uptimerobot.com" "UptimeRobot URL varsayılan"

test_summary
