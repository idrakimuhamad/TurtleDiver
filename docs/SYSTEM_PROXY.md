# System Proxy Integration

This points the **macOS system proxy** at the local engine, which is how traffic
reaches TurtleDiver without a PAC file or a per-app setting. The legacy PAC
feature (the `python3 -m http.server` on port 8765, the `Use Proxy` toggle and
Settings → *Proxy (PAC)*) has been removed. A *corporate* PAC is still captured
and handed back untouched, because CFNetwork prefers a PAC over explicit proxies
and one must survive us.

## How it works

```
SystemProxyManager.enable()
  1. Snapshot  – for every enabled network service, capture the current
                 -getwebproxy / -getsecurewebproxy / -getsocksfirewallproxy
                 state. Only services that already had a proxy configured are
                 remembered (the rest are simply cleared on disable).
  2. Persist   – the snapshot is written to
                 ~/Library/Application Support/TurtleDiver/proxy-snapshot.json
                 so a crash or force-quit can be repaired at next launch.
  3. Configure – on EVERY enabled network service (not just Wi-Fi):
                   -setwebproxy          127.0.0.1 <HTTP port>
                   -setsecurewebproxy    127.0.0.1 <HTTP port>
                   -setsocksfirewallproxy 127.0.0.1 <SOCKS port>
                   -setproxybypassdomains <skip-proxy list from the profile>

SystemProxyManager.disable()
  1. Clear     – all three proxies off on every enabled service.
  2. Restore   – services that had proxies before get their original
                 host/port/auth/enabled state re-asserted.
  3. Remove    – the persisted snapshot is deleted.
```

## Safety properties

- **Snapshot-first**: if capturing the current settings fails, enable()
  aborts before touching anything — the system is never configured without a
  recorded way back.
- **Idempotent enable**: calling enable() twice does not overwrite the
  original snapshot with the engine's own settings.
- **Crash repair**: if the app dies between enable and disable, the next
  launch detects the leftover snapshot (`hasStaleSnapshot`) and offers
  `restoreFromSnapshot()`, which `EngineController` runs automatically.
- **Quit restore**: `applicationWillTerminate` calls
  `EngineController.shutdown()` → `disableSystemProxy()` first, before any
  other teardown.
- **Disabled services untouched**: `*`-prefixed services from
  `networksetup -listallnetworkservices` are skipped.

## Admin password

All `networksetup` set-commands go through the same admin-password path the
VPN connection already uses (`SettingsManager.shared.adminPassword`, stored in
the Keychain). No new privilege model is introduced.

`networksetup` does **not** use PAM: for a set-command it asks the system for
authorization through Authorization Services, which can raise a GUI dialog of
its own. The password still travels on the child's standard input (never in
argv), and the wait is now **bounded** — 60 s, then `SIGTERM`, a 2 s grace, then
`SIGKILL`, reported as `SystemProxyError.authorizationTimedOut`. Before that it
was a `DispatchSemaphore.wait()` with no deadline at all, on a path a click can
reach. See `docs/ELEVATION.md`.

## VPN tie-in

`EngineController` observes `VPNManager.status`:

- On **connected** (with tunneling enabled): vpn-slice targets are converted
  into DIRECT rules (`VPNRuleGenerator`) and overlaid at the **top** of the
  active profile's rule list, so corporate traffic bypasses proxy upstreams
  and flows through the tunnel. Accepted target shapes:

  | vpn-slice target     | Generated rule                     |
  |----------------------|------------------------------------|
  | `10.0.0.0/8`         | `IP-CIDR,10.0.0.0/8,DIRECT`        |
  | `10.20.30.40`        | `IP-CIDR,10.20.30.40/32,DIRECT`    |
  | `fd00::/8`           | `IP-CIDR6,fd00::/8,DIRECT`         |
  | `fd00::1`            | `IP-CIDR6,fd00::1/128,DIRECT`      |
  | `*.corp.example.com` | `DOMAIN-SUFFIX,corp.example.com,DIRECT` |
  | `vpn.corp.com`       | `DOMAIN,vpn.corp.com,DIRECT`       |

- On **disconnected**: the overlay is removed exactly (only the rules from the
  previous generation pass are deleted; user rules are never displaced).
- On **external profile edits while connected**: the overlay is re-applied on
  top of the fresh rule list.

The generated rules are recomputed from `SettingsManager.vpnSliceURLs` on
every VPN connect — no profile hand-editing required.

## App wiring

| Piece | File | Role |
|---|---|---|
| `SystemProxyManager` | `VPNConnect/System/SystemProxyManager.swift` | networksetup plumbing, snapshot/restore |
| `VPNRuleGenerator` | `VPNConnect/System/VPNRuleGenerator.swift` | vpn-slice targets → DIRECT rules |
| `EngineController` | `VPNConnect/EngineController.swift` | launch wiring, profile hot-reload, VPN observation, system proxy lifecycle |
| Toggle | `SettingsManager.useProxyEngine` | master switch (persisted), auto-start at launch when on |

`EngineController` is `@MainActor` and exposes `@Published` state
(`engineRunning`, `httpPort`, `socks5Port`, `systemProxyOn`, `lastError`) that
the dashboard binds to.

## Testing

- `SystemProxyManagerTests` — scripted `FakeNetworkSetupRunner` verifies the
  exact networksetup invocations for enable/disable/restore, snapshot
  scoping (only services with pre-existing proxies), enable idempotency,
  stale-snapshot repair across manager instances, and the
  `-get*proxy` output parsers. The snapshot file location is injected
  (temp dir), so tests never touch real system settings.
- `VPNRuleGeneratorTests` — every target shape, dedup, invalid-target
  reporting, merge semantics (top insertion, replacement, idempotency,
  clearing), hostname validation edge cases, and round-trip through the
  profile parser/serializer.
