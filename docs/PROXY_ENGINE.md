# Proxy Engine

The proxy engine turns TurtleDiver into a real local proxy: it listens on
loopback, matches every request against the active profile's rules, resolves
the policy, and relays bytes. It is **independent of the VPN** — it can run
with or without a tunnel.

## Listeners

| Listener | Default | Profile option |
|---|---|---|
| HTTP proxy | `127.0.0.1:6152` | `http-listen` |
| SOCKS5 | `127.0.0.1:6153` | `socks5-listen` |
| HTTP proxy (shared) | `<LAN IPv4>:<HTTP port>` | — (`shareWithDevice`) |

Empty `http-listen` / `socks5-listen` values disable that listener. Ports are
Surge-compatible; do not run Surge and TurtleDiver at the same time.

The shared listener binds the port the running HTTP listener actually uses, on
the LAN address of the Mac's preferred Wi-Fi or Ethernet interface, so it only
appears while sharing is on and the tunnel is connected (see
[Sharing with a device](#sharing-with-a-device)); it is never a profile option
and never replaces the loopback listener.

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
     │     └─ https → refused: TLS upstream not implemented
     ▼
   RelayConnection: bidirectional event-driven pump,
   traffic counters per request
```

Every request (including rejections and failures) lands in the `RequestLog`
ring buffer (last 1000) with host, port, matched rule, policy, byte counts,
duration, and error text — the dashboard renders it. The newest 200
entries also carry a **request detail** (see below), which the dashboard's row
sheet renders.

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

## Sharing with a device

Off by default, behind the **Share with a device** switch on the Dashboard
(`shareWithDevice`). It exists to let one phone or tablet use the tunnel the Mac
already holds without installing a profile, a certificate or an app on the
phone. It binds a second HTTP listener; the loopback listener is unchanged.

- **Lifecycle.** The shared listener is bound only when all three hold: the
  setting is on, the proxy engine is running, and the VPN tunnel is connected.
  It binds the LAN IPv4 of the Mac's preferred Wi-Fi or Ethernet interface — an
  `en*` or `bridge*` address, never a VPN or link-local interface — on the port
  the running HTTP listener actually uses (`6152` by default). It stops when the
  tunnel disconnects, and `NWPathMonitor` rebinds it when the LAN address
  changes; an openconnect reconnect can leave the listener up for a moment.
  SOCKS5 is never shared — phones have no system SOCKS setting — and there is no
  way to enable sharing without the tunnel.
- **What leaves the Mac.** A shared device's traffic follows this Mac's routing
  exactly like the Mac's own traffic. A host the profile's rules send through the
  tunnel reaches the internet over the VPN; everything else — `DIRECT` rules and,
  under split tunneling, the targets `vpn-slice` does not route — leaves through
  the Mac's normal connection. That is the point of the feature: the phone
  reaches VPN-only services and keeps its ordinary internet. It is not a kill
  switch, and it is not the gateway mode in *Out of reach*.
- **Access.** A client is allowed either by its IPv4 being on the allowed list
  (persisted in `UserDefaults` `shareAllowedClients`) or by presenting HTTP Basic
  credentials in `Proxy-Authorization`: username `turtle` and a generated
  16-character password kept in the Keychain (`sharePassword`, cleared by the
  credential reset, with a regenerate button). Anything else is answered
  `407 Proxy Authentication Required` with
  `Proxy-Authenticate: Basic realm="TurtleDiver"`. **Reset All Settings** turns
  sharing off, clears the allowed addresses and deletes the share password.
- **Refusals show up in the UI.** A device that is refused and is not on the
  list is remembered in memory (at most 20 addresses) and offered in the
  dashboard with an **Allow** button — the fast path for Android, whose manual
  proxy screen has no username or password fields, so the first request is
  refused and then allowed from the Mac.
- **PAC for devices that follow rules.** The shared listener also serves a
  generated PAC at `http://<lan-ip>:<port>/<token>/proxy.pac`, where `<token>` is
  the first 24 hex characters of `SHA256("turtlediver-pac:" + sharePassword)`.
  `EngineController.sharePACURL` publishes that URL while sharing is active; it
  rotates when the password is regenerated and disappears when sharing stops or
  the credentials are reset. The PAC URL (origin-form or absolute-form) is
  answered before the `407` gate and is never recorded in the request log, so a
  phone's automatic fetch — and the token in it — leaves no trace in the
  dashboard. Every other path still requires access, and the loopback listener
  never serves a PAC.
- **What the PAC decides.** The document is generated per fetch from the
  engine's current expanded rules and policy selections, so an edit is live on
  the device's next fetch. The tunnel mode is explicit: **full tunnel** (Standard
  VPN, or split tunneling with no usable target) sends every host to the Mac;
  **split tunnel** checks the `vpnSliceURLs` targets first and always sends them
  to the Mac (a single-label target such as `intranet` included, and a valid
  IPv6 target makes IPv6-literal hosts go to the Mac; a malformed
  IPv6-looking value is ignored rather than splitting the tunnel). Otherwise
  the profile's `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD` and IPv4 `IP-CIDR`
  rules are evaluated in order. Rule values are lowercased exactly as
  `RuleMatcher` lowercases them — root dots are **not** stripped, so
  `DOMAIN-KEYWORD,corp.,DIRECT` does not match `evilcorpx.example`. VPN target
  values are lowercased and dot-stripped, which only sends more traffic to the
  Mac. A `DIRECT` policy becomes `DIRECT`, while `PROXY`/`REJECT` become the
  Mac's proxy so the Mac applies its own routing or reject. A `FINAL` in the
  rule list is terminal in the PAC exactly as it is in the matcher.
- **No DNS is performed by the PAC.** A non-literal host that reaches an
  address-bearing split target (an IPv4/IPv6 address or CIDR in
  `vpnSliceURLs`) goes to the Mac, because the phone's resolver may be
  split-horizon: a name the Mac resolves to `10.42.1.2` over VPN DNS can look
  like `203.0.113.5` to the phone. Explicit domain/suffix targets are still
  checked first. In the profile rule list, the first `IP-CIDR`/`IP-CIDR6` rule
  **without** `no-resolve` terminates a hostname: it goes to the Mac when that
  rule or any later rule (through `FINAL`) can be non-DIRECT, and is `DIRECT`
  only when the whole remainder is certainly DIRECT. This mirrors the Mac,
  where that rule resolves the name and caches it, so a later `no-resolve` rule
  can still match. A `no-resolve` rule before any resolving rule is literal-only
  for hostnames. Every IPv6 literal goes to the Mac, including IPv4-mapped
  `::ffff:` addresses, which would otherwise slip past IPv4 rules. The PAC never
  calls `dnsResolve` or `isInNet`.
- **The PAC fails open, never closed.** A rule the PAC cannot evaluate
  (`DEST-PORT`, `SRC-IP`, `URL-REGEX`, `USER-AGENT`, `PROCESS-NAME`,
  `IP-CIDR6`, …) whose policy is not certainly DIRECT terminates the scan:
  every host not matched by an earlier rule goes to the Mac instead of being
  sent DIRECT past a possible proxy or reject. `GEOIP` never matches, but
  without `no-resolve` the Mac still resolves DNS for it and caches the result,
  so it is a resolving point for hostnames exactly like an address rule; an
  unexpanded `RULE-SET` is dropped because it has no rules. Plain hostnames and
  `localhost` get no shortcut: they go through the same rule evaluation as any
  other host. Only rules whose outcome is certainly DIRECT are dropped.
  Policy classification for this is
  side-effect-free: generating the PAC does not advance a load-balance counter,
  consult health, or perturb the engine's own routing. A group is treated as
  DIRECT only when every member is.
  The response is `200` with `Content-Type: application/x-ns-proxy-autoconfig`
  and `Cache-Control: no-store`; `HEAD` returns the same headers without a body,
  and only `PROXY`/`DIRECT` tokens are emitted — Android understands nothing
  else.
  - **Device caveats.** Android has no proxy password field, so a PAC-only
    device still has to be on the allowed-device list or its traffic is refused
    when it reaches the proxy. iOS prompts for credentials on the first `407`
    and is likely to fail closed while the PAC is unreachable, whereas Android
    falls back to `DIRECT`. The PAC itself is plain HTTP: iOS has deprecated
    HTTP PAC URLs but still accepts one, and anyone on the LAN who learns the
    URL can fetch it.
- **The credential is stripped, not forwarded.** `Proxy-Authorization` is
  removed from a forwarded plain-HTTP request on **both** listeners, so the Basic
  value authenticates the device to this engine and never reaches an origin.
  Plain HTTP on the shared listener serves **one request per connection**: a
  later pipelined request on the same connection is dropped, and the client
  retries on a new one. The loopback listener keeps its no-auth behaviour.
- **Rules see the device, not the Mac.** The device's own IPv4 is the client
  address during rule matching, so an `SRC-IP` rule can allow or block it —
  `SRC-IP,192.168.1.30/32,REJECT` refuses that device while the Mac's own
  traffic is untouched.
- **What it records.** A request from a shared device carries the client's IPv4
  in `RequestEntry.client`, rendered as the **Client** row in the request-detail
  sheet. Nothing is persisted to disk — it is the same in-memory detail the other
  rows keep. macOS may ask for **Local Network** permission the first time
  (`NSLocalNetworkUsageDescription` in `Info.plist`).
- **The honest limit.** Only traffic that honours a proxy is routed: games and
  apps that ignore the system proxy do not go through the engine, and nothing in
  the UI can say "this device is only partly routed". Basic auth travels in clear
  on the LAN, so share only on a network you trust.

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

Policy resolution reuses `PolicyStore`, including group behaviors
(select / url-test / fallback / load-balance) and health bookkeeping. The
engine runs group auto-testing only while started (`startAutoTesting` is the
app's choice; the engine constructs its store with auto-testing off by
default for tests).

## VPN split-tunnel overlay

While the tunnel is connected and `useTunneling` is on, the app merges
`VPNRuleGenerator.rules(forTargets: vpnSliceURLs)` — `DIRECT` rules for the
split-tunnel targets — at the front of the profile it hands the engine, so they
shadow any identical rule further down. The merge is **in memory only**: the
profile file, its backups and the Rules editor always show what the user saved,
and disconnecting reloads the plain profile. Older builds saved those rules
into the file; a leftover prefix is stripped whenever the active profile is
loaded or changes (launch, switch, restore, external edit), keeping a backup
first.

Because the overlay is runtime state, `engine.matcher` and the engine's routing
include it while connected; `ProfileManager.activeProfile` and the CLI's
`rules explain` do not.

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
- Connects (DNS + TCP + an upstream proxy handshake) run off the relay queues
  on `ConnectScheduler`: a *bounded concurrent* pool, not a serial queue. A
  connect blocks for its whole timeout, so an unreachable upstream — a
  corporate proxy group with the VPN down is the usual one — used to hold the
  single connect slot and starve every unrelated dial behind it; the engine
  looked dead, not slow. 8 at a time; a hung upstream costs one slot.
  Regression tests: `ConnectSchedulerTests` (a slow dial must not delay the
  dials behind it, and the cap is respected).
- EOF from one side half-closes the other (`shutdown(SHUT_WR)`) so
  FIN-signaled protocols relay cleanly; the relay finishes when the *second*
  side EOFs, or when a write fails.
- A socket that has reached EOF is **permanently readable**, so leaving that
  side's `DispatchSourceRead` armed re-fires it immediately and forever: one
  `read` syscall per iteration, ~100% of one core, for as long as the *other*
  direction stays open. Seen live: an origin answering `Connection: close`
  while the client kept its proxy connection alive pinned the relay queue for
  as long as the client sat there. So `sawEOF` cancels that side's source
  (`stopReading(clientSide:)`) and leaves the fd **open** — an EOF ends one
  direction, not the connection, and the peer that only stopped sending may
  still be receiving. Regression tests: `RelayHalfCloseTests` (a relay sitting
  at EOF must burn < 30% of a core over a 0.4 s idle window; the direction the
  peer did *not* close must still carry bytes; 24 relay lifecycles must not
  leak descriptors).
- Teardown is idempotent: `finish(with:)` cancels both read sources, disarms
  the write sources, closes **both** fds itself, snapshots metrics, and fires
  `onFinished` once. The read sources deliberately have no cancel handler that
  closes anything: a source cancelled at EOF must not take the fd with it.
- `TD_FD_TRACE` is read once into a stored constant, never per event.
  `ProcessInfo.environment` rebuilds the whole environment dictionary on every
  access (~30 µs measured, against ~0 for the constant), and the EOF path used
  to consult it per relay event — the `sample` that diagnosed the spin found
  1940 of 1943 samples inside `_ProcessInfo.environment.getter`, i.e. the loop
  was burning a core of *user* time on the environment rather than on the
  socket. Pinned by a source-scan test in `RelayHalfCloseTests`.

## Request detail capture

`RelayStreamObserver` sees every chunk the relay forwards, in both directions,
and is **observe-only**: it cannot alter, reorder or drop a byte, and its
transport is a single copy it hands to a parser. Nothing is decrypted — the
capture reads what the client already sends in the clear.

| Transport | Request | Response | TLS |
| --- | --- | --- | --- |
| `http://` (absolute-form) | request line + headers | status line + headers | — |
| `CONNECT` tunnel | CONNECT line + headers | encrypted (the sheet says so) | SNI, version, ALPN |
| SOCKS5 | — | — | SNI, version, ALPN |
| `REJECT` | request line + headers | — | — |

- `RequestDetail` owns the caps and the redaction: at most 32 headers per
  message, values truncated at 512 bytes (`…` marks the cut), and only the
  newest `RequestLog.detailCapacity` (200) entries keep a detail — a detail for
  a trimmed or unknown entry id is dropped.
- `HeaderRedaction` withholds `Authorization`, `Proxy-Authorization`, `Cookie`,
  `Set-Cookie`, `X-Api-Key` and anything matching *token / secret / password /
  credential / session / cookie* as `•••• (N chars)`, **at capture time**, so the
  value never enters the process. `RequestLog.revealsSensitiveHeaders` (off by
  default) only affects captures made after it is switched on.
- `HTTPResponseHead.probe` and `TLSClientHello.probe` return
  `incomplete` / `notHTTP` / `notTLS` / `parsed` instead of guessing: an
  `incomplete` result asks the observer to keep buffering (bounded —
  `TLSClientHello.maxBytes` / `HTTPResponseHead.limit`), a `not*` result ends
  the capture for that connection. A SOCKS5 row is an address, so its SNI is
  the only way to learn the hostname at all.

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
policy, bytes) and ring-buffer trimming — 21 integration tests (incl. the relay backpressure regression and four end-to-end capture tests: plain-HTTP head + withheld cookie, CONNECT SNI, SOCKS5 SNI, capture-off) among the 720 core tests.

`Tests/TurtleDiverCoreTests/ProxyShareTests.swift` covers the shared listener's
access policy: the allowed-IP list, Basic auth against the Keychain password, the
`407` + `Proxy-Authenticate` refusal an unknown device gets, and
`Proxy-Authorization` being stripped before a request is forwarded.
`Tests/TurtleDiverAppTests/ShareWithDeviceTests.swift` covers the app-side glue
(`EngineController.reconcileSharing`, `ShareState`): the listener is bound only
when the setting is on **and** the engine runs **and** the tunnel is connected,
stopped when the tunnel disconnects, and rebound when the LAN address changes.

`Tests/TurtleDiverCoreTests/RelayHalfCloseTests.swift` (4 tests) drives a real
`RelayConnection` — a client leg on a `socketpair`, an origin leg on a real
loopback listener — and half-closes exactly one direction. Two assertions carry
the weight: this process's own CPU (`getrusage`) over a 0.4 s idle window must
stay under 30% of a core (a relay left spinning burns ~100%; the failure
message says so in percent), and the direction the peer did *not* close must
still carry bytes, with the relay finishing only on the second EOF. A third
counts descriptors (`proc_pidinfo(PROC_PIDLISTFDS)`) across 24 relay
lifecycles. A fourth is a source scan: `RelayConnection.swift` must contain
exactly one `processInfo.environment` lookup and it must be the stored flag.

Those fake servers (`Tests/TurtleDiverCoreTests/TestServers.swift`) have to be
*joined* on shutdown: a serve loop accepts by descriptor **number**, so closing
the listener while the loop is still inside `poll`/`accept` lets the kernel
recycle that number into an unrelated socket — after which the stale loop
accepts a connection belonging to somebody else, answering it with its own
canned 204 (or closing it, which reads as an intermittently *empty* reply, or
as a 200 where a 204 was expected). Every fake now runs on a `TestListenerLoop`
whose `stop()` sets the stop flag, wakes a parked accept with a throwaway
connection, `shutdown()`s live clients so a blocked handler returns, waits for
the loop to leave the accept path, and only then closes the listener.
`Tests/TurtleDiverCoreTests/TestHarnessLifecycleTests.swift` (4 tests) pins that:
`stop()` must have joined the loop before it returns, a stopped server must not
accept on a recycled descriptor, and joining must not degenerate into a hang
when a handler is parked on a quiet client.

`Tests/TurtleDiverCoreTests/TLSClientHelloTests.swift` (11 tests) parses
hand-built ClientHellos — SNI, ALPN, `supported_versions` with GREASE ignored,
a handshake split across records, truncation → `incomplete`, a non-TLS stream →
`notTLS`, and an oversized record that gives up at the cap instead of buffering
without bound.

`Tests/TurtleDiverCoreTests/RequestDetailTests.swift` (20 tests) covers the
redaction table, the header-count and value-length caps, `merged(with:)`
(a later leg must fill gaps without clearing what is already known), the
response-head probe, the detail ring (only the newest 200 kept, unknown ids
dropped, `capturesDetails = false` refuses everything), and the two settings
defaults.

`VPNConnect/Engine/DisplayFormat.swift` holds the engine→UI display helpers as
Foundation-only types so their edge cases are unit-testable
(`Tests/TurtleDiverCoreTests/DisplayFormatTests.swift`, 29 tests): request time
/ byte / size / duration formatting (`0 KB`, never a negative duration, two
decimals once a request finishes), the row subtitle's detail summary and the
detail sheet's sections/rows/copyable text (including "a withheld value is never
rendered"), and `DebugLogParser`, which splits the raw
`VPNManager.debugOutput` into the last 400 `[timestamp] [tag] body` lines and
classifies severity **from the content** (`[SEND]`, *error*, *warning*) rather
than by stream — openconnect writes ordinary progress to stderr, so colouring
by stream would paint the whole log amber. The colour mapping itself lives in
the view (`MainView.logTagColor`/`logBodyColor`).

`Tests/TurtleDiverAppTests/EngineTogglePersistenceTests.swift` (13 tests) covers
the app-side glue: it compiles `EngineController`/`SettingsManager`/`VPNManager`
into a `TurtleDiverAppGlue` target and asserts that the Dashboard/menu engine
toggle persists `useProxyEngine`, that a fresh controller auto-starts from it,
and that starting the engine publishes the policy list immediately (the
Policy Health card used to come up empty until the first reload). It also pins
profile isolation (building a controller never initialises
`ProfileManager.shared`), that the vpn-slice overlay is handed to the engine
without touching the file or backups and precedes an earlier matching rule,
that a persisted overlay is stripped on launch/switch/restore (and left alone
when it is not an exact prefix or tunneling is off), and that a late rule-set
load for the previous profile cannot overwrite the new one.
`Tests/TurtleDiverAppTests/SecretHygieneTests.swift` (10 tests) covers the
launch-time cleanup of `UserDefaults`: a credential left in the plist by an
older build is moved into the Keychain *before* its key is dropped, an existing
Keychain entry always wins over the stale copy, blank values are not stored, no
credential is ever written back to disk, live keys (`activeProfileName`,
`appTheme`, `systemProxyEnabled`, `VPNConnectConnectionHistory`, …) are left
alone, and the pass is idempotent (and self-heals if a dead key reappears).
`Tests/TurtleDiverAppTests/SystemProxyIntentTests.swift` (11 tests) covers the
system-proxy toggle: enabling it writes `system-proxy = true` into the active
profile, and — the regression it was written for — a later profile rewrite (of
the kind the old VPN overlay used to perform) no longer turns the system proxy
back off. It also pins the behaviour
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

`Tests/TurtleDiverAppTests/SettingsCatalogTests.swift` (13 tests) and
`Tests/TurtleDiverAppTests/VPNConfigurationDraftTests.swift` (25 tests) cover
the 1.4.0 Settings window without a window: the pane catalogue
(`SettingsCatalog` — one item per route, stable group order, terse
titles/keywords, every SF Symbol resolvable, case- and diacritic-insensitive
search, unknown stored values falling back to the default pane), the persisted
pane choice, the VPN pane's dirty detection (`VPNConfigurationDraft` — a
credential's whitespace is significant, a cosmetic vpn-slice list difference is
not), and the pure display helpers that keep machine values out of
`LocalizedStringKey` (`SettingsDisplay.listener(host:port:)` never renders
`Optional(…)`, `abbreviateHome(_:home:)` is boundary-safe, `profileSummary`
pluralises, `connectionStatus(_:)` shortens stored statuses so a pill cannot
wrap mid-word). Total: **688 tests** (537 core + 151 app).

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
`Use Proxy` toggle and Settings → *Proxy (PAC)*) is gone. Two pieces of that retirement need explaining:

- `scrubLegacyPACFromSnapshot()` runs synchronously in
  `EngineController.init` (no subprocesses) so a persisted snapshot can never
  re-arm the dead `127.0.0.1:8765` server, and `restoreService` additionally
  refuses to re-enable a PAC under `legacyPACURLPrefix`.
- `clearLegacyPAC()` does the `networksetup` sweep (turning off an armed legacy
  PAC, leaving other PACs alone) once, on a background queue, guarded by the
  `legacyPACCleaned` default. `EngineController.awaitLegacyPACCleanup()` awaits
  it, which is how the app tests assert it stays off the main thread.

## Remote rule sets

`[Rule Set]` declarations (`VPNConnect/Profile/RuleSet.swift`, model/parse) plus
`VPNConnect/Rules/RuleSetStore.swift` (transport, cache, staleness) let a rule
reference a downloaded list:

```
[Rule Set]
Ads = https://example.com/ads.conf, interval=86400
[Rule]
RULE-SET,Ads,REJECT
```

- `RuleMatcher.expand(_:ruleSets:declared:)` splices a cached list in at the
  position of the reference; the reference's policy wins and each expanded rule
  is stamped with its set name (`ProfileRule.ruleSet`) for provenance.
- A reference to a set with no cached copy expands to **nothing**, and the set is
  reported in `RuleMatcher.unresolvedRuleSetNames` — a missing list never
  silently becomes a catch-all.
- `RuleSetStore.refresh(_:)` is HTTPS-only, sends conditional requests
  (`If-None-Match` / `If-Modified-Since`), enforces an 8 MB body cap, UTF-8, and
  `RuleSetParser.maxRules = 100_000`, and keeps the last good copy on any
  failure. The body is written before the sidecar, so a crash cannot leave an
  entry that promises rules which are not there; both files are mode `0600`.
- The cache file name is `<slug>-<FNV-1a-64(url)>.rules`; the sidecar stores the
  URL, so a changed URL can never serve the old list.
- `EngineController.reloadRuleSets(refreshStale:)` reads the cache off the main
  thread, reloads the matcher, rebuilds the pane's summaries and — only when
  `ruleSetAutoRefresh` is on (default **off**) — refreshes sets that declare an
  interval.
- The reference is created from the row's ⋯ → *Use in rules* menu
  (`Profile.setRuleSetReference(named:policy:)`): it replaces an existing rule
  **in place** (moving it to just-above-`FINAL` would silently change which
  rules outrank it), keeps at most one per set, and reports a no-op so the pane
  can skip the write. A set with no reference — or none in force — shows a
  `NOT USED` pill, because a downloaded list that nothing references does
  nothing at all.
- Failures reach the UI as one sentence (`RuleSetStoreError.describe(_:)`). A
  `URLError` arrives as a bridged `NSError`, so interpolating it prints the
  whole `UserInfo` dictionary into the row; the interesting codes get their own
  sentence and the rest fall back to the code.
- `EngineController.removeRuleSetCache(for:)` takes the set itself rather than a
  name. A caller that has just deleted the declaration has already dropped it
  from the profile, so a lookup would find nothing and leave the downloaded body
  — and its sidecar — behind. Retargeting (⋯ → *Edit…*) drops the **pre-edit**
  set's copy for the same reason: the old body caches under the old URL's name.

Covered by `RuleSetTests` (44), `RuleSetStoreTests` (20) and
`RuleSetControllerTests` (7).

## PAC → rules import

`VPNConnect/Rules/PACRuleConverter.swift` converts a legacy PAC
(`FindProxyForURL`) script into the same rule/policy model this engine
consumes, so PACs can be migrated to the rule-based path. It is a pure,
Foundation-only parser (no JavaScriptCore) in the `TurtleDiverRules` module.
The mapping is the table at the top of the converter: `shExpMatch`,
`dnsDomainIs`, `localHostOrDomainIs` and exact-host tests become `DOMAIN` or
`DOMAIN-SUFFIX`, `isInNet` becomes `IP-CIDR`/`IP-CIDR6`, and a multi-upstream
return (`"PROXY a; DIRECT"`) becomes a generated `fallback` group. Its limits
are stated there too: `||` alternatives expand, a wildcard in the middle of a
host is approximated as `DOMAIN-KEYWORD`, and conditions it cannot translate
(`&&`, negation, `isPlainHostName`, unknown functions) are reported as
diagnostics and skipped rather than dropping the import. The
Routing screen (`docs` → *Routing*) provides the import wizard and a
friendly domain/IP → policy assignment UI. Covered by
`Tests/TurtleDiverCoreTests/PACRuleConverterTests.swift` (34 tests).
