#!/bin/bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRVCTL_RATE_PROFILES="${REPO_ROOT}/conf/rate-profiles.conf"
export WEB_ROOT="$(mktemp -d)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/ip.sh"

# IP / CIDR kapısı (ban/whitelist/blacklist girişlerinde kullanılır)
assert_ok   _ip_value_gate "1.2.3.4"
assert_ok   _ip_value_gate "10.0.0.0/8"
assert_ok   _ip_value_gate "2001:db8::1"
assert_fail _ip_value_gate "1.2.3.4; rm -rf /"
assert_fail _ip_value_gate "evil\$(id)"
assert_fail _ip_value_gate "999.999.999.999"
assert_fail _ip_value_gate ""

# Süre kapısı (sleep'e akar): uint ya da 'permanent'
assert_ok   _ip_duration_gate "86400"
assert_ok   _ip_duration_gate "permanent"
assert_fail _ip_duration_gate "10; reboot"
assert_fail _ip_duration_gate "abc"

# Ülke kodu kapısı (geoblock)
assert_ok   _ip_geoblock_gate "TR"
assert_ok   _ip_geoblock_gate "cn"     # büyük harfe çevrilip TR/CN gibi doğrulanır
assert_fail _ip_geoblock_gate "TURKEY"
assert_fail _ip_geoblock_gate "T;R"
assert_fail _ip_geoblock_gate ""

rm -rf "$WEB_ROOT"
test_summary
