# Proxy Engine (Phase 3)

The proxy engine turns TurtleDiver into a real local proxy: it listens on
loopback, matches every request against the active profile's rules, resolves
the policy, and relays bytes. It is **independent of the VPN** — it can run
with or without a tunnel.

## Listeners

| Listener | Default | Profile option |
|---|---|---|
| HTTP proxy | `127.0.0.1:6152` | `http-listen` |
| SOCKS5 | `127.0.0.1:6153` | `socks5-listen` |

Empty `http-listen` / `socks5-listen` values disable that listener. Ports are
Surge-compatible; do not run Surge and TurtleDiver at the same time.

## Request flow

```
client ──▶ listener (HTTP / SOCKS5)
             │ parse (target, headers, addressing)
             ▼
        RuleMatcher.match(MatchContext)     ── rules from the active profile
             │ first match wins (FINAL = catch-all)
             ▼
        PolicyStore.resolve(policyName)     ── proxies / groups / DIRECT / REJECT
             │
     ┌─────┼──────────────┐
     ▼     ▼              ▼
   DIRECT  proxy(x)     REJECT
     │     │              │ immediate close
     │     ├─ http  → upstream CONNECT tunnel
     │     ├─ socks5→ RFC 1928 handshake
     │     └─ https → not supported yet (Phase 4+)
     ▼
   RelayConnection: bidirectional event-driven pump,
   traffic counters per request
```

Every request (including rejections and failures) lands in the `RequestLog`
ring buffer (last 1000) with host, port, matched rule, policy, byte counts,
duration, and error text — the Phase 5 dashboard renders it.

## HTTP listener

- **CONNECT** `host:port` — establishes the outbound leg first, then replies
  `200 Connection established` and relays verbatim (TLS, HTTP/2, anything).
  Failures answer `502 Bad Gateway` with the reason.
- **absolute-form requests** (`GET http://host/path HTTP/1.1`) — forwarded to
  the origin in origin-form with `Connection: close`; hop-by-hop headers
  (`Proxy-Connection`, `Connection`, `Keep-Alive`) are not forwarded.
- **origin-form requests** (`GET /path HTTP/1.1`) — the client is treating us
  as a web server; answered with `400` and a hint.
- Malformed heads get `400`; heads that never complete are closed after 30s.

## SOCKS5 listener (RFC 1928)

- Version 5, **CONNECT only** (BIND/UDP ASSOCIATE → reply 0x07).
- **No-auth** only; a client offering no common method gets 0xFF.
- Addressing: IPv4 (0x01), domain (0x03; resolved by the rule engine's
  resolver only when an IP rule requires it), IPv6 (0x04).
- REJECT → reply 0x02 (not allowed by ruleset). Unreachable destinations →
  0x01 in the reply when detected before the greeting, otherwise the tunnel
  closes (connect-first ordering).
- Upstream failure handling: the relay's finish closure retires the log entry
  and releases the relay exactly once (idempotent teardown).

## Policies

Policy resolution reuses the Phase 1 `PolicyStore`, including group behaviors
(select / url-test / fallback / load-balance) and health bookkeeping. The
engine runs group auto-testing only while started (`startAutoTesting` is the
app's choice; the engine constructs its store with auto-testing off by
default for tests).

## Relay internals

- Two `DispatchSourceRead` sources pump chunks of up to 64 KiB; a single
  serial relay queue orders handlers (no blocked threads per connection).
- Backpressure: short/EAGAIN writes keep data in a per-direction buffer and
  arm a `DispatchSourceWrite`; reads pause above 256 KiB buffered and resume
  below 128 KiB.
- Resuming a paused read source defers its lost-edge probe by one turn on the
  relay queue. The probe exists because data arriving *while a source is
  suspended* produces no new readiness edge on `resume()` (EV_CLEAR), which
  would stall the relay; but `resumeRead` is reachable from inside `flush`,
  which the write handler calls with an exclusive `inout` access to the very
  buffer the probe would append into — probing inline traps Swift's runtime
  exclusivity check and aborts the app (`readFromOutbound()` on
  `com.turtlediver.engine.relay`, seen in the field before 1.4.0).
  Regression test:
  `testRelayResumeProbeSurvivesBackpressureWithoutExclusivityTrap` (crashes the
  test runner with a fatal access conflict if the probe is put back inline).
- EOF from one side half-closes the other (`shutdown(SHUT_WR)`) so
  FIN-signaled protocols relay cleanly; both sides EOF → teardown.
- Teardown is idempotent: `finish(with:)` cancels sources (cancel handlers
  close the fds), snapshots metrics, and fires `onFinished` once.

## Verifying manually

```bash
# with the app running and the engine started:
scripts/proxy-smoke-test.sh            # defaults: 6152 6153

# or directly:
curl -x http://127.0.0.1:6152 http://cp.cloudflare.com/generate_204   # 204
curl -x http://127.0.0.1:6152 https://www.apple.com/                  # tunnel
curl --socks5-hostname 127.0.0.1:6153 http://cp.cloudflare.com/generate_204
```

## Tests

`Tests/TurtleDiverCoreTests/ProxyEngineIntegrationTests.swift` covers, against
in-process fake servers: CONNECT round-trips, absolute-form → origin-form
rewriting, traffic through an upstream CONNECT proxy (and upstream 403 →
502), SOCKS5 greeting/CONNECT/domain addressing/reject/command-and-method
errors, 400 hardening, dead-destination 502, request-log accuracy (rule,
policy, bytes) and ring-buffer trimming — 17 integration tests (incl. the relay backpressure regression) among the 273 core tests.

`VPNConnect/Engine/DisplayFormat.swift` holds the engine→UI display helpers as
Foundation-only types so their edge cases are unit-testable
(`Tests/TurtleDiverCoreTests/DisplayFormatTests.swift`, 20 tests): request time
/ byte / size / duration formatting (`0 KB`, never a negative duration, two
decimals once a request finishes), and `DebugLogParser`, which splits the raw
`VPNManager.debugOutput` into the last 400 `[timestamp] [tag] body` lines and
classifies severity **from the content** (`[SEND]`, *error*, *warning*) rather
than by stream — openconnect writes ordinary progress to stderr, so colouring
by stream would paint the whole log amber. The colour mapping itself lives in
the view (`MainView.logTagColor`/`logBodyColor`).

`Tests/TurtleDiverAppTests/EngineTogglePersistenceTests.swift` (5 tests) covers
the app-side glue: it compiles `EngineController`/`SettingsManager`/`VPNManager`
into a `TurtleDiverAppGlue` target and asserts that the Dashboard/menu engine
toggle persists `useProxyEngine`, that a fresh controller auto-starts from it,
and that starting the engine publishes the policy list immediately (the
Policy Health card used to come up empty until the first reload).
`Tests/TurtleDiverAppTests/SystemProxyIntentTests.swift` (10 tests) covers the
system-proxy toggle: enabling it writes `system-proxy = true` into the active
profile, and — the regression it was written for — a later profile rewrite
(connecting the VPN injects the vpn-slice DIRECT rules and saves) no longer
turns the system proxy back off (296 tests total). It also pins the behaviour
of stopping the app: `stopEngine()` / `shutdown()` still point macOS away from
the listener they are about to close, but they leave the stored intent alone,
so the next launch re-arms the proxy from the profile instead of asking the
user to flip the toggle again. Two more tests keep the toggle responsive:
every `networksetup` call must run off the main thread, and a flip that lands
while a change is still in flight is queued (last request wins) rather than
dropped. The controller is driven against a throwaway profile directory,
`UserDefaults` suite and recording `networksetup` runner (which also records
`Thread.isMainThread`), so the suite never touches the user's profiles or
system proxy.

### System-proxy ownership vs. a legacy PAC

The active profile is the single source of truth for the system-proxy intent
(`[General] system-proxy`), so `EngineController.setSystemProxyEnabled(_:)`
persists the toggle into it; `startEngine()` re-applies it on launch. Previously
the toggle only flipped in-memory state, so the profile change that accompanies
a VPN connect silently reverted it.

Intent and live state are deliberately separate: turning the proxy off because
the *engine* is going away (`stopEngine()`, `shutdown()`, i.e. app termination)
never rewrites the profile — otherwise every quit erased the user's choice.
Only an explicit toggle-off stores `system-proxy = false`.

Applying or clearing the system proxy spawns a dozen-plus `networksetup`
subprocesses (one per network service × setting, plus the pre-enable snapshot),
which used to run inline on the main thread and froze the UI for seconds.
`setSystemProxyEnabled(_:)` is now async and performs all of that work on a
background queue (`systemProxyBusy` drives a spinner and disables the toggle),
and the status-bar menu exposes the same switch as a checkable item so it can be
reached without opening the Dashboard.

Because CFNetwork prefers a PAC over explicit proxies, `SystemProxyManager`
also captures `-getautoproxyurl` in its snapshot, emits
`-setautoproxystate <service> off` while the engine owns the proxy, and restores
the PAC on `disable()` — a corporate PAC must survive us.

The legacy PAC *feature* itself (the `python3 -m http.server` on port 8765, the
`Use Proxy` toggle and Settings → *Proxy (PAC)*) is gone; see §11 of
`SURGE_CAPABILITIES_PLAN.md`. Two pieces of that retirement need explaining:

- `scrubLegacyPACFromSnapshot()` runs synchronously in
  `EngineController.init` (no subprocesses) so a persisted snapshot can never
  re-arm the dead `127.0.0.1:8765` server, and `restoreService` additionally
  refuses to re-enable a PAC under `legacyPACURLPrefix`.
- `clearLegacyPAC()` does the `networksetup` sweep (turning off an armed legacy
  PAC, leaving other PACs alone) once, on a background queue, guarded by the
  `legacyPACCleaned` default. `EngineController.awaitLegacyPACCleanup()` awaits
  it, which is how the app tests assert it stays off the main thread.

## PAC → rules import

`VPNConnect/Rules/PACRuleConverter.swift` converts a legacy PAC
(`FindProxyForURL`) script into the same rule/policy model this engine
consumes, so PACs can be migrated to the rule-based path. It is a pure,
Foundation-only parser (no JavaScriptCore) in the `TurtleDiverRules` module;
see §10 of `SURGE_CAPABILITIES_PLAN.md` for the mapping and limits. The
Routing screen (`docs` → *Routing*) provides the import wizard and a
friendly domain/IP → policy assignment UI. Covered by
`Tests/TurtleDiverCoreTests/PACRuleConverterTests.swift` (34 tests).
