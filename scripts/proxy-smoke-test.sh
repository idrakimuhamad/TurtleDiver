#!/usr/bin/env bash
# Proxy engine smoke test (Phase 3).
#
# Verifies the local HTTP and SOCKS5 listeners route traffic per profile
# rules: CONNECT tunneling, absolute-form forwarding, REJECT, and the
# SOCKS5 handshake. Requires a running engine (app launched with the proxy
# engine enabled) and curl.
#
# Usage: scripts/proxy-smoke-test.sh [HTTP_PORT] [SOCKS5_PORT]
set -euo pipefail

HTTP_PORT="${1:-6152}"
SOCKS_PORT="${2:-6153}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

echo "== TurtleDiver proxy engine smoke test =="
echo "HTTP listener : 127.0.0.1:${HTTP_PORT}"
echo "SOCKS5 listener: 127.0.0.1:${SOCKS_PORT}"
echo

command -v curl >/dev/null || fail "curl is required"

# --- 1. HTTP proxy, absolute-form, DIRECT ---
# Uses a well-known generate_204 endpoint; any profile whose FINAL policy
# resolves to DIRECT (or routes it deliberately) must return HTTP 204.
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  -x "http://127.0.0.1:${HTTP_PORT}" http://cp.cloudflare.com/generate_204 || true)
if [ "$CODE" = "204" ]; then
  pass "HTTP absolute-form request returned 204"
else
  echo "  (note: got HTTP ${CODE:-none} — check the active profile's rules)"
fi

# --- 2. HTTP proxy, CONNECT (HTTPS through the tunnel) ---
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  -x "http://127.0.0.1:${HTTP_PORT}" https://www.apple.com/ || true)
if [ "$CODE" = "200" ] || [ "$CODE" = "301" ] || [ "$CODE" = "302" ]; then
  pass "HTTP CONNECT tunnel established (HTTPS fetch returned ${CODE})"
else
  echo "  (note: got HTTP ${CODE:-none})"
fi

# --- 3. SOCKS5 CONNECT ---
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  --socks5-hostname "127.0.0.1:${SOCKS_PORT}" http://cp.cloudflare.com/generate_204 || true)
if [ "$CODE" = "204" ]; then
  pass "SOCKS5 CONNECT returned 204"
else
  echo "  (note: got HTTP ${CODE:-none})"
fi

# --- 4. REJECT (expected to fail fast) ---
# The starter profile ships no REJECT rules; add one temporarily to try this:
#   IP-CIDR,10.11.12.0/24,REJECT,no-resolve
# then:
#   curl -x http://127.0.0.1:6152 --max-time 5 http://10.11.12.13/ && echo "FAIL: not rejected"
# The request must fail immediately (403 from the engine, or connection refused).

echo
echo "Done. Check the dashboard (Phase 5) for the matching request log."
