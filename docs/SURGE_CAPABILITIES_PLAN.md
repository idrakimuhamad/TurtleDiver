# TurtleDiver — Surge-Like Capabilities Plan

**Status:** ✅ **All phases complete (0–7)** · **Shipped in 1.3.0** · **Created:** 2026-09-11

## 1. Goal

Evolve TurtleDiver from a "VPN client with a PAC file" into a lightweight
Surge-style network toolbox for macOS, **without breaking the core function**:
automatic openconnect VPN connection (stoken TOTP + vpn-slice).

Surge (https://nssurge.com/) core capabilities we will adopt:

| Surge capability | In scope | Notes |
|---|---|---|
| Local proxy listener (HTTP/SOCKS5) | ✅ Phase 3 | Pure Swift via Network.framework |
| Rule system (DOMAIN-SUFFIX, IP-CIDR, …, FINAL) | ✅ Phase 2 | Surge-compatible rule syntax |
| Policy system (proxies + policy groups) | ✅ Phase 1 | select / url-test / fallback / load-balance |
| Surge-style INI profile (`[Proxy]`, `[Proxy Group]`, `[Rule]`) | ✅ Phase 0 | Text-file profile, human editable |
| System proxy configuration & restore | ✅ Phase 4 | Replaces current PAC-only path |
| Dashboard (requests, traffic, latency tests) | ✅ Phase 5 | SwiftUI |
| Menu bar quick controls (profile/policy switching) | ✅ Phase 6 | Extends MenuBarManager |
| Auto-connect VPN stays the primary flow | ✅ Always | Proxy engine integrates with it |
| MITM / certificate management | ❌ | Out of scope |
| TUN "Enhanced Mode" (full device takeover) | ❌ (future) | Requires privileged helper / NEDivert; see §9 |
| DNS hijacking / fake-IP | ❌ (future) | Depends on TUN mode |

## 2. Current State (what we build on)

```
VPNConnect/
├── VPNManager.swift        # openconnect via `sudo` bash pipeline, stoken TOTP,
│                           # vpn-slice split tunneling, PID polling, auto-reconnect
├── ProxyManager.swift      # PAC file mgmt + python3 http.server :8765 +
│                           # `networksetup -setautoproxyurl` (Wi-Fi only)
├── SettingsManager.swift   # UserDefaults + Keychain; ProxyConfiguration (PAC-based)
├── MainView.swift          # status UI, proxy toggle + picker
├── SettingsView.swift      # Configuration / Appearance / Proxy(PAC) / History
├── AppDelegate.swift       # window mgmt, MenuBarManager (status item)
└── KeychainHelper.swift    # Keychain storage for secrets
```

Key limitations today:
1. PAC decides routing per-URL *inside apps that honor PAC* — no central rule
   engine, no IP/PROCESS-NAME rules, no logging of what matched.
2. PAC is served from a `python3 -m http.server` child process — fragile.
3. Only Wi-Fi service is configured; no HTTP/HTTPS/SOCKS system proxy support.
4. Proxy config is a flat list of PAC blobs; no proxy *servers* (only PACs), no
   groups, no health checking.

## 3. Target Architecture

```
┌──────────────────────────── TurtleDiver.app ────────────────────────────┐
│                                                                          │
│  MainView / Dashboard / Settings UI (SwiftUI)                            │
│        │                                                                 │
│  ┌──────▼─────────────┐   ┌──────────────────┐   ┌────────────────────┐  │
│  │ ProfileManager      │   │ RuleEngine        │   │ PolicyStore        │  │
│  │ (INI profiles in    │──▶│ parse + match     │──▶│ proxies & groups   │  │
│  │  Application        │   │ requests          │   │ (select/url-test/  │  │
│  │  Support/TurtleDiver)│  └──────────────────┘   │  fallback/lb)      │  │
│  └─────────────────────┘                          └─────────┬──────────┘  │
│        │                                                    │            │
│  ┌──────▼──────────────────────────────────────────────────────▼─────────┐│
│  │ ProxyEngine (Network.framework)                                        ││
│  │  • HTTP proxy listener :6152   • SOCKS5 listener :6153                 ││
│  │  • Relay: client ──▶ [rule match] ──▶ DIRECT / proxy / REJECT          ││
│  │  • Latency tester (HTTP HEAD via each policy)                          ││
│  └──────┬────────────────────────────────────────────────────────────────┘│
│         │ sets/patches system proxy (networksetup), PAC generation fallback│
│  ┌──────▼───────────┐        ┌──────────────────────────────────────────┐ │
│  │ SystemProxyManager│        │ VPNManager (unchanged core)              │ │
│  │ (evolves Proxy-  │        │  auto-connect, stoken, vpn-slice          │ │
│  │  Manager)        │        │  + VPN subnet rules auto-generated        │ │
│  └──────────────────┘        └──────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────┘
```

New files (target layout):

```
VPNConnect/
├── Engine/
│   ├── ProxyEngine.swift        # lifecycle: start/stop listeners, reload profile
│   ├── HTTPProxyServer.swift    # HTTP CONNECT + absolute-URI proxying
│   ├── SOCKS5Server.swift       # RFC 1928 SOCKS5 (no auth), TCP ASSOCIATE
│   ├── RelayConnection.swift    # bidirectional pump + traffic accounting
│   └── LatencyTester.swift      # url-test/fallback group health checks
├── Rules/
│   ├── Rule.swift               # model + Surge-compatible types
│   ├── RuleParser.swift         # "DOMAIN-SUFFIX,apple.com,DIRECT" → Rule
│   └── RuleMatcher.swift        # ordered matching incl. IP resolution cache
├── Policy/
│   ├── Policy.swift             # ProxyPolicy (http/https/socks5) + built-ins
│   ├── PolicyGroup.swift        # select / url-test / fallback / load-balance
│   └── PolicyResolver.swift     # rule → final policy (group recursion guard)
├── Profile/
│   ├── Profile.swift            # Surge-style INI model + Codable disk format
│   ├── ProfileParser.swift      # INI ⇄ model (Surge-compatible syntax)
│   └── ProfileManager.swift     # storage, active profile, migration from PACs
├── System/
│   └── SystemProxyManager.swift # HTTP/HTTPS/SOCKS via networksetup (all services)
└── Views/
    ├── DashboardView.swift      # live requests, matched rule/policy, traffic
    ├── ProfilesView.swift       # profile list/editor (text + forms)
    ├── RulesEditorView.swift    # ordered rule list w/ drag & drop
    └── PolicyViews.swift        # policy/group editors, latency test UI
```

## 4. Phase Plan

### Phase 0 — Profile model & storage (foundation) ✅ DONE
**Deliverable:** Surge-compatible profile read/write, active profile concept,
automatic migration of existing PAC configurations.

**Shipped (62 XCTests green, app target builds):**
- `VPNConnect/Profile/Profile.swift` — model (`Profile`, `ProxyDefinition`,
  `ProxyGroup`, `ProfileRule`, `GeneralSettings`) + structural `validate()`
  (unique names, reference resolution, group cycle detection, FINAL rules).
- `VPNConnect/Profile/ProfileParser.swift` — Surge-compatible INI parser with
  non-fatal `ProfileDiagnostic`s (line-numbered warnings/errors), quoted-value
  and inline-comment support, per-type value shape checks.
- `VPNConnect/Profile/ProfileSerializer.swift` — serializer with round-trip
  fidelity guarantee (model equality modulo UUIDs).
- `VPNConnect/Profile/ProfileManager.swift` — disk CRUD in
  `~/Library/Application Support/TurtleDiver/Profiles/`, active-profile
  persistence, external-edit file watching (0.3s debounce), one-time legacy
  PAC migration.
- `Tests/TurtleDiverCoreTests/` — 62 tests across parser/serializer/validation/
  manager. Run via `swift test` (Package.swift harness compiles the same
  Foundation-only sources; the app target needs Xcode).
- Docs: `docs/PROFILES.md` (full syntax reference).

- `Profile` sections: `[General]`, `[Proxy]`, `[Proxy Group]`, `[Rule]`.
- Disk: `~/Library/Application Support/TurtleDiver/Profiles/<name>.conf`
  (plain INI text so users can hand-edit, exactly like Surge confs).
- `[General]`: `http-listen`, `socks5-listen`, `loglevel`, `test-url`,
  `test-timeout`, `system-proxy` toggle, `bypass-system`, `bypass-tun` style
  `skip-proxy` list.
- `[Proxy]` line grammar (Surge-compatible):
  `Name = http|https|socks5, <host>, <port>, [username=…, password=…, tls=true, skip-cert-verify=true]`
- `[Proxy Group]` grammar:
  `Name = select|url-test|fallback|load-balance, PolicyA, PolicyB, … [, url=…, interval=600]`
- `[Rule]` grammar (first match wins, ordered):
  `TYPE,value,policy[,no-resolve]` with types:
  `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `IP-CIDR`, `IP-CIDR6`,
  `GEOIP`(future), `USER-AGENT`, `URL-REGEX`, `PROCESS-NAME`, `DEST-PORT`,
  `SRC-IP`, `PROTOCOL`, `FINAL`.
- Built-in policies: `DIRECT`, `REJECT`, `REJECT-TINYGIF`(later).
- Migration: on first launch, each existing `ProxyConfiguration` (PAC) becomes a
  profile named after it; its PAC is kept as-is for the legacy path. New default
  profile `Main.conf` is created with sensible starter rules:
  `FINAL,DIRECT`.
- Acceptance: round-trip parse/serialize tests; existing behavior unchanged.

### Phase 1 — Policy system ✅ DONE
**Deliverable:** proxies as first-class policies + groups with health checks.

**Shipped (92 XCTests green total, app target builds):**
- `VPNConnect/Profile/TCPClient.swift` — POSIX TCP client (non-blocking connect
  with poll + SO_ERROR, typed sockaddr value handling — getaddrinfo results
  copied into Swift values before `freeaddrinfo`, no pointer lifetime bugs).
- `VPNConnect/Profile/LatencyTester.swift` — `LatencyMeasuring` protocol + real
  prober: DIRECT (full HTTP RTT), HTTP proxy (absolute-form request), HTTPS
  proxy (TCP reachability), SOCKS5 (full RFC 1928/1929 handshake incl.
  user/pass auth).
- `VPNConnect/Profile/PolicyStore.swift` — thread-safe policy resolution
  (`resolve(name) → direct/proxy/reject`), all four group behaviors (select
  with persisted choice / url-test lowest-latency / fallback first-healthy /
  load-balance round-robin over healthy), per-policy health bookkeeping (last
  result, best latency), profile hot-swap preserving state, interval
  auto-testing timer, defensive cycle detection.
- Tests: PolicyStore behaviors via deterministic fake measurer (20 tests) and
  real end-to-end probes against loopback fake HTTP/SOCKS5(+auth) servers
  (10 tests).
- Note: `Package.swift` compiles the same files the app target builds; tests
  run via `swift test`.

- `PolicyStore` publishes `policies: [Policy]` (proxies, groups, DIRECT/REJECT).
- `PolicyGroup` behaviors:
  - `select` — user-chosen, persisted per group id.
  - `url-test` — periodic `HEAD <test-url>` through each candidate; picks lowest
    latency (concurrency-limited, 600s default interval).
  - `fallback` — first candidate that passes the test, in listed order.
  - `load-balance` — round-robin across healthy candidates.
- Latency results surfaced to UI and menu bar.
- Acceptance: group resolution returns a concrete endpoint; cycles in group
  references are detected and rejected at parse time.

### Phase 2 — Rule engine ✅ DONE
**Deliverable:** ordered, Surge-compatible matching used by the proxy engine.

**Shipped (157 XCTests green total, app target builds):**
- `VPNConnect/Rules/IPAddress.swift` — strict IPv4 parser (rejects octal,
  leading zeros, out-of-range octets), RFC 4291 IPv6 parser (full,
  `::`-compressed, IPv4-mapped tail, zone-ID stripped), IPv4-mapped addresses
  normalized to IPv4 for matching, `CIDRBlock` with byte-exact prefix
  containment for both families (partial-byte prefixes included).
- `VPNConnect/Rules/DNSResolver.swift` — `DNSResolving` protocol +
  `SystemDNSResolver` (getaddrinfo, AF_UNSPEC, values copied before
  `freeaddrinfo`) + `CachingDNSResolver` (positive TTL 60s / negative TTL 10s,
  expiry-based eviction with a 512-entry ceiling, `clearCache()` on profile
  reload).
- `VPNConnect/Rules/ProcessPeerResolver.swift` — best-effort PROCESS-NAME
  support: `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` reads the accepted socket's
  peer endpoint, `proc_listallpids` + per-fd scans find the process owning the
  connection (foreign endpoint match, no DNS involved), `proc_pidpath` yields
  the executable. Every failure path returns nil; short-TTL cache wrapper
  included.
- `VPNConnect/Rules/RuleMatcher.swift` — ordered first-match-wins evaluation
  with hot-swappable rule list: DOMAIN / DOMAIN-SUFFIX (label boundaries,
  case-insensitive) / DOMAIN-KEYWORD; IP-CIDR / IP-CIDR6 with lazy DNS
  (resolved at most once per connection, shared across subsequent IP rules;
  literal and pre-resolved hosts skip DNS); `no-resolve` skips DNS-requiring
  rules without failing them; USER-AGENT / URL-REGEX (ICU regex, HTTP metadata
  only); PROCESS-NAME (last path component, case-insensitive); DEST-PORT
  (port/range/list); SRC-IP; PROTOCOL (well-known-port heuristic until
  listeners expose the negotiated protocol); GEOIP reserved (never matches
  yet); FINAL terminates, default policy DIRECT when absent.
- Wired into both build paths: `Package.swift` gains a `TurtleDiverRules`
  target (depends on `TurtleDiverCore`) and the Xcode app target compiles the
  new `Rules/` group.
- Tests: 65 new tests (IPAddress 24, DNSResolver 7, RuleMatcher 34) covering
  every rule type, precedence, `no-resolve`, DNS-once sharing, resolution
  failure fallback, mapped-address interop, malformed-value hardening, and
  profile hot-swap.

- `RuleMatcher.match(context:) → MatchOutcome (rule, policy, performedDNS)`.
- Domain matching: exact / suffix / keyword (case-insensitive).
- IP rules: resolve host (with TTL cache) when needed unless `no-resolve`;
  match against CIDR sets (uniform 16-byte representation, IPv4+IPv6).
- `PROCESS-NAME`: resolve local peer PID via `libproc` on the listener socket
  (best-effort; documented limitation).
- `USER-AGENT`/`URL-REGEX`: available in HTTP path; SOCKS5 sees host only.
- Acceptance: unit tests for each rule type incl. precedence + `no-resolve`.

### Phase 3 — Proxy engine (local listeners) ✅ DONE
**Deliverable:** TurtleDiver becomes a real local proxy that routes by rules.

**Shipped (173 XCTests green total, app target builds):**
- `VPNConnect/Engine/ProxyEngine.swift` — lifecycle owner (start/stop/reload),
  `RequestLog` ring buffer (last 1000 requests with host/rule/policy/bytes/
duration/transport/error), `RelayRegistry` (live-relay ownership + shared
  relay queue), `parseListen` (`host:port`, IPv6 `[::1]:port`), POSIX listener
  factory (SO_REUSEADDR, non-blocking, SO_NOSIGPIPE).
- `VPNConnect/Engine/HTTPProxyServer.swift` — full request-head parser
  (keep-alive safe framing, header folding), CONNECT tunneling, absolute-form
  and origin-form forwarding (re-targeted at the origin, Host header
  preserved), per-request decision wiring through `RuleMatcher` +
  `PolicyStore` (auth groups resolved per request so `select` overrides apply
  live), 400 on garbage, 405 on non-CONNECT when only CONNECT is allowed.
- `VPNConnect/Engine/SOCKS5Server.swift` — RFC 1928 handshake (method
  negotiation → no-auth, CONNECT only; IPv4 / IPv6 / domain request forms),
  proper 5xx replies on every failure path.
- `VPNConnect/Engine/RelayConnection.swift` — event-driven bidirectional pump
  (DispatchSource read/write, write-drain backpressure, half-close aware),
  outbound connectors for DIRECT / HTTP-CONNECT / HTTPS-CONNECT / SOCKS5
  upstreams (incl. Basic auth), traffic counters, initial-bytes flush kick
  for pre-CONNECT client payloads, one-shot decision callback.
- REJECT policy closes immediately; a user-visible marker row lands in the
  request log.
- Wired into both build paths (`TurtleDiverEngine` SPM target + app target).
- Tests: 16 integration tests — CONNECT/absolute-form/origin-form through the
  real listeners, upstream redirect via a fake HTTP CONNECT proxy, SOCKS5
  handshake + domain form, REJECT, request-log bookkeeping, lifecycle
  restart/port-rebind. Plus loopback fakes in `TestServers.swift`.
- Manual check: `scripts/proxy-smoke-test.sh` (curl through both listeners);
  operator docs in `docs/PROXY_ENGINE.md`.

### Phase 4 — System proxy integration ✅ DONE
**Deliverable:** one-click system proxy, replacing the fragile PAC python server.

**Shipped (200 XCTests green total, app target builds):**
- `VPNConnect/System/SystemProxyManager.swift` — configures HTTP/HTTPS/SOCKS
  system proxy on **all enabled network services** (from
  `networksetup -listallnetworkservices`, `*`-disabled services skipped) with
  the profile's `skip-proxy` list as bypass domains. Snapshot-first lifecycle:
  current per-service state is captured and persisted before anything is
  modified; enable is idempotent (a second enable cannot overwrite the
  original snapshot); disable clears all services then re-asserts the
  snapshotted state (host/port/auth/on-off) on services that had proxies;
  stale snapshots from a crashed session are detected and repaired on the
  next launch. Injectable `NetworkSetupRunning` runner makes the whole flow
  unit-testable without touching real settings.
- `VPNConnect/System/VPNRuleGenerator.swift` — converts vpn-slice split-tunnel
  targets (`10.0.0.0/8`, bare IPs v4/v6, `*.corp.com`, `vpn.corp.com`) into
  Surge DIRECT rules with strict validation (numeric-TLD rejection so bad IP
  literals never become hostnames), de-dup, and a merge that replaces the
  previous generation without displacing user rules.
- `VPNConnect/EngineController.swift` — `@MainActor` app glue: auto-starts the
  engine at launch when `SettingsManager.useProxyEngine` is on, hot-reloads on
  profile changes, applies/clears the VPN DIRECT-rule overlay on
  connect/disconnect (re-applying over external profile edits), enables/
  disables the system proxy per profile flag, and restores on quit via
  `applicationWillTerminate`.
- `SettingsManager.useProxyEngine` master toggle (persisted; independent of
  the legacy PAC `useProxy`).
- Tests: 27 new (SystemProxyManager 8 via scripted fake runner + temp-dir
  snapshots; VPNRuleGenerator 19 incl. parser round-trip).
- Docs: `docs/SYSTEM_PROXY.md`; `docs/PROFILES.md` documents the
  system-proxy/skip-proxy lifecycle.

### Phase 4 — System proxy integration (original acceptance notes)
**Deliverable:** one-click system proxy, replacing the fragile PAC python server.

- `SystemProxyManager` (evolves `ProxyManager`):
  - Sets per-service HTTP/HTTPS/SOCKS system proxy to the local listeners via
    `networksetup` for **all enabled network services** (not just Wi-Fi).
  - `skip-proxy` (bypass) list applied as exclusions.
  - Graceful restore of previous proxy settings on disable/quit (snapshot &
    restore, as done today for auto-proxy).
  - Legacy "PAC mode" retained as a fallback option (kept for environments that
    only support PAC), but the default becomes direct listeners.
- Integration with VPN (unchanged core, new tie-in):
  - On `VPNManager.connect()` success, engine already runs; add auto-generated
    rules when split tunneling is active: vpn-slice subnets/hosts → `IP-CIDR …,DIRECT`
    (traffic to corp goes through the tunnel, not a proxy).
  - Proxy engine is **independent of VPN**: it starts on app launch when enabled,
    so it works without a VPN too (Surge-like behavior).

### Phase 5 — UI: Dashboard, Profiles, Rules, Policies ✅ DONE
**Deliverable:** manage everything from the app, Surge-style.

**Shipped (200 XCTests green total, app target builds):**
- `VPNConnect/Views/DashboardView.swift` — engine on/off toggle, system-proxy
  toggle, listening ports, error surface, per-policy latency badges
  (success/fail/timeout/not-probed), one-tap override pickers for `select`
  groups (persisted via PolicyStore), live request table (host:port, transport,
  matched rule type, policy, ↑↓ bytes, duration/error) with Pause (freezes the
  snapshot at pause start) and Clear.
- `VPNConnect/Views/ProfilesView.swift` — profile list with active badge and
  per-profile stats (proxies/groups/rules), create/duplicate/activate/delete,
  open-in-external-editor (NSWorkspace), reload.
- `VPNConnect/Views/RulesEditorView.swift` — ordered rule editor for the
  active profile: drag to reorder (FINAL clamped last), per-type value fields
  with placeholders, inline policy picker, `no-resolve` checkbox for IP-type
  rules, search filter, add/remove, live validation banner from
  `Profile.validate()`; every edit persists via `saveAndActivate` (engine
  hot-swaps; external-edit watcher still works).
- `VPNConnect/Views/PolicyViews.swift` — proxy CRUD (type/host/port/TLS,
  secrets to Keychain, profile keeps no secret text), group editor (type,
  ordered members with add/remove/reorder, test URL + interval for auto
  groups), Test All toolbar action.
- Routing: `SettingsRoute.dashboard/profiles/rules/policies` + Network section
  entries; `MainView` gains an animated ENGINE ON chip with listening ports
  under the status block.
- Plumbing: `ProfileModelBridge` (Combine bridge over ProfileManager's change
  hook so controller + views can all observe), `EngineController` now
  publishes `requests: [RequestEntry]` and `policySummaries: [PolicySummary]`
  (onChange hooks installed once, survive engine restarts).

### Phase 5 — UI: Dashboard, Profiles, Rules, Policies (original acceptance notes)
**Deliverable:** manage everything from the app, Surge-style.

- **Dashboard** (new window/tab): live request table (host, rule, policy, ↑↓
  bytes, duration), pause/clear, per-policy latency badges, engine on/off.
- **Profiles**: list/create/duplicate/delete; open in external editor button;
  "reload" picks up file changes (file watcher).
- **Rules editor**: ordered list, drag to reorder, type picker with per-type
  value fields, inline policy picker, search/filter, import/export `.conf`.
- **Policies**: proxy CRUD (host/port/creds → Keychain for secrets), group
  editor (type, members, url/interval), "Test Now" button.
- Main window: engine status chip (On/Off + listening ports) next to VPN
  status; one-tap policy-group override for `select` groups.
- Settings routes added: `profiles`, `dashboard`, `rules`, `policies`
  (extends `SettingsRoute`).

### Phase 6 — Menu bar & polish ✅ DONE
**Deliverable:** Surge-like quick controls in the status item menu.

**Shipped (200 XCTests green total, app target builds):**
- `MenuBarManager` is now `@MainActor` and binds to VPN status, engine state,
  and policy health. Menu contents: status row, Connect/Disconnect VPN
  (state-correct), Enable/Disable Proxy Engine + listening-ports row,
  **Profile** submenu (checkmark on active), **Policy Groups** submenu per
  `select` group (checkmark on persisted choice), **Test Latency Now**,
  **Open Dashboard…** (deep-links Settings → Dashboard via a new
  `SettingsView(initialRoute:)` + `SettingsWindowController.pendingRoute`),
  Settings…, Quit.
- Status-bar icon: engine-listening variant (`MenuBarIconEngine` asset, with
  graceful fallback) + tint changes per VPN state.
- Version bumped to **1.3.0 (build 4)** in both build configurations.

### Phase 6 — Menu bar & polish (original acceptance notes)
**Deliverable:** Surge-like quick controls in the status item menu.

- Menu: engine toggle, profile submenu, per-group policy submenu (select
  groups), latency test now, open dashboard, VPN connect/disconnect (existing).
- Icons: distinct states for engine off/listening/rejecting.
- App icon/version bump to 1.3.0; update `publish.sh` notes if needed.

### Phase 7 — Hardening & docs ✅ DONE
- Concurrency audit: `xcodebuild` shows **no Swift-6-mode warnings** in any
  Phase 2–7 source (System/, Rules/, Engine/, Views/, EngineController,
  MenuBarManager); the only remaining warnings are pre-existing in
  `VPNManager.swift` (documented as out of scope here).
- Crash/quit restore paths: covered by `SystemProxyManagerTests` (stale
  snapshot repair across manager instances) and
  `docs/MANUAL_TEST_CHECKLIST.md` §4 (force-quit + relaunch procedure).
- README refreshed for 1.3.0 (proxy engine, system proxy, dashboard, docs
  index); `docs/PROFILES.md` has the full syntax reference incl.
  system-proxy/skip-proxy semantics.
- Unit tests shipped across phases: profile parser/serializer/validation (62),
  policy store + real handshakes (30), rule engine + IP/CIDR + DNS (65),
  proxy engine integration (16), system proxy + VPN rule generation (27) =
  **200 automated tests**, plus the human checklist for sudo/system-dialog
  paths.

### Phase 7 — Hardening & docs (original acceptance notes)

## 5. What stays untouched (main function preserved)

- `VPNManager` connection pipeline (sudo/openconnect/stoken/vpn-slice, PID
  polling, reconnect-timeout, graceful teardown) — only gains optional
  auto-generated DIRECT rules for VPN subnets.
- Connection history, debug panel, theme, Keychain storage.
- The app continues to work exactly as today if the proxy engine is disabled
  (default off until the user enables it).

## 6. Milestone ordering & rough sizing

| Phase | Depends on | Est. size |
|---|---|---|
| 0 Profile model/storage | — | M |
| 1 Policy system | 0 | M |
| 2 Rule engine | 0 | M |
| 3 Proxy engine | 1, 2 | L |
| 4 System proxy | 3 | S |
| 5 UI | 0–4 | L |
| 6 Menu bar | 5 | S |
| 7 Hardening/docs | all | M |

Each phase ships independently usable; Phases 0–2 can be merged early since
they're inert without the engine.

## 7. Risks & mitigations

1. **System proxy ≠ full traffic capture.** Only apps honoring system proxy
   settings are routed (browsers, most CLI tools via env vars). True
   device-level capture needs TUN mode — explicitly out of scope for 1.3.0
   (§9). Mitigation: keep PAC fallback + document limits.
2. **sudo/networksetup changes require admin password** — already collected
   today via Keychain (`adminPassword`); reuse it, no new privilege model.
3. **Port conflicts** on 6152/6153 — configurable, detect-and-skip with UI
   warning (Surge uses the same ports; avoid running both simultaneously).
4. **PROCESS-NAME resolution limits** — best-effort; documented.
5. **Swift 6 concurrency** — Network.framework handlers are off-main; route all
   state mutation through `@MainActor` publishers, buffers via `@unchecked
   Sendable` wrappers (pattern already established in `ProxyManager`).
6. **Keychain for proxy credentials** — extend `KeychainHelper` accounts rather
   than storing secrets in profile text; profile keeps only a reference.

## 8. Out of scope / future

- TUN "Enhanced Mode" via a NetworkExtension packet-tunnel provider (would also
  enable DNS control, fake-IP, GeoIP at IP layer). Requires helper signing and
  entitlements; propose as 1.4.0 investigation.
- MITM/decryption, scripting, HTTP rewrite.
- GeoIP/MaxMind database integration (rule type reserved now).

## 9. Decision log

- **Local listeners over PAC-only**: matches Surge's model, enables IP/PROCESS
  rules and logging that PAC cannot do. PAC retained as legacy fallback.
- **Surge-compatible INI syntax**: users can copy patterns from the Surge
  ecosystem; parser is ours, so we can extend safely.
- **Engine runs independently from VPN**: Surge-like; VPN auto-connect remains
  the app's headline feature and simply coexists.
- **Ports 6152/6153** chosen to mirror Surge Mac defaults for familiarity.

## 10. Addendum — PAC import + Routing screen

Chosen as the **incremental path**: the new engine and the legacy PAC path
coexist, and migration is offered rather than forced.

- **`PACRuleConverter`** (`VPNConnect/Rules/PACRuleConverter.swift`) parses a
  `FindProxyForURL` script with a dependency-free scanner (no JavaScriptCore)
  and emits rule-based routing:
  - `shExpMatch(host, "*.x")` → `DOMAIN-SUFFIX x`; exact host → `DOMAIN`;
    URL patterns have scheme/path/port stripped; a mid-string wildcard is
    approximated as `DOMAIN-KEYWORD` and noted.
  - `dnsDomainIs` / `localHostOrDomainIs` → `DOMAIN-SUFFIX`.
  - `host == "x"` → `DOMAIN`.
  - `isInNet(host|dnsResolve(host), ip, mask)` → `IP-CIDR` / `IP-CIDR6`
    (non-contiguous masks are skipped with a diagnostic).
  - Top-level `||` expands into multiple rules; `&&`, negation,
    `isPlainHostName`, and unknown functions are skipped and surfaced as
    diagnostics rather than silently dropped.
  - Return values map to policies: `DIRECT` → built-in; `PROXY`/`HTTP` →
    `http`, `HTTPS` → `https`, `SOCKS*` → `socks5`. Multi-upstream returns
    (e.g. `"PROXY a:1; DIRECT"`) become a generated `fallback` group. Existing
    proxies are matched by server/port/type and reused, not duplicated.
  - `PACRuleConverter.apply(_:to:)` folds a result into a profile: rules are
    inserted before `FINAL`, new policies appended, `FINAL` retargeted to the
    PAC's default branch. Applying twice is a no-op (idempotent).
- **Routing screen** (`VPNConnect/Views/RoutingView.swift`, sidebar →
  *Routing*) is a friendly, PAC-like assignment UI separate from the raw Rules
  editor. Quick-add a `Domain` / `Domain Suffix` / `Domain Keyword` /
  `IPv4 CIDR` / `IPv6 CIDR` and pick its policy in one row; edit policy inline;
  drag to reorder (first match wins); filter by value or policy. Non-routing
  rules and the `FINAL` position are preserved; advanced types stay in Rules.
- **Import PAC wizard** (`RoutingView` toolbar) pastes or loads a `.pac`,
  previews the generated proxies, groups, rules and diagnostics, then applies
  to the active profile; the engine hot-reloads.

The legacy PAC path (`ProxyManager`, Settings → Proxy (PAC), `useProxy`) was
**left intact** while import was proven in the field; it has since been removed
(§11).

## 11. Legacy PAC path removed

The rule-based path is now the only proxy path: the PAC import wizard plus the
Routing screen cover everything the old PAC feature did, with rules that can be
read, reordered and debugged. Removed in 1.3.1:

| Removed | Why it could go |
|---|---|
| `VPNConnect/ProxyManager.swift` (`python3 -m http.server` on :8765, PAC generation, `sudo` shell-out) | The engine serves requests itself; a child `http.server` was the fragile part |
| `SettingsManager.ProxyConfiguration`, `proxyConfigurations`, `useProxy`, `selectedProxyID`, `selectedProxy`, `add/update/deleteProxyConfiguration` | One profile per config is what the engine consumes |
| Settings → *Proxy (PAC)* + `ProxySettingsView` / `ProxyEditorView` (and the JavaScriptCore syntax check) | Replaced by Settings → *Routing* → *Import PAC* (`PACRuleConverter`, Foundation-only) |
| "Use Proxy" toggle + proxy badge in the main window, and the window-height term in `AppDelegate` | The engine + system proxy is the single switch now |
| `ProfileManager.migrateFromLegacyPAC` (PAC blob → profile *comments*) | Cosmetic only; `PACRuleConverter` produces real rules instead |
| `SendableDataBuffer` / `ProcessError` | Relocated into `VPNManager.swift`, which still uses them |

Kept on purpose:

- `PACRuleConverter` + the Routing import wizard — the migration tool.
- `SystemProxyManager`'s PAC snapshot/restore — a *corporate* PAC still shadows
  the engine, so it must be captured and handed back.
- The one-time `clearLegacyPAC()` retirement (see `docs/PROXY_ENGINE.md`), since
  an old build could leave macOS pointing at the now-dead :8765 server.
