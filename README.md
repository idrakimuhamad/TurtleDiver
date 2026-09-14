# TurtleDiver - macOS VPN Client

A macOS application for managing VPN connections using openconnect, stoken, and vpn-slice. Similar to the [hellsturtle](https://github.com/idrakimuhamad/hellsturtle) project, but for MacOS.

Since 1.3.0, TurtleDiver also ships a **Surge-style local proxy engine**: rule-based routing, policy groups with latency testing, a live dashboard, and one-click system proxy — all working independently of the VPN.

## Features

- **Simple Interface**: Easy-to-use GUI for VPN connection management
- **Token**: Automatic token generation management and form fill up
- **Tunneling Support**: Option to use vpn-slice for selective routing
- **Local Configuration**: Everything stored locally on device no cloud storage or syncing
- **Proxy Engine** (1.3.0): local HTTP + SOCKS5 listeners, Surge-compatible rule
  matching (DOMAIN / IP-CIDR / PROCESS-NAME / …), policy groups
  (select / url-test / fallback / load-balance) with automatic health checks
- **System Proxy** (1.3.0): one-click HTTP/HTTPS/SOCKS system proxy across all
  network services, with snapshot & restore and crash repair
- **Dashboard** (1.3.0): live request table (host, rule, policy, traffic,
  duration), latency badges, select-group overrides
- **Routing** (1.3.0): assign a policy per domain/domain-suffix/IP-CIDR in a
  friendly list (quick-add, inline edit, drag-reorder), plus a **PAC import
  wizard** that converts an existing `FindProxyForURL` script into rules and
  proxy policies
- **Main window** (1.4.0): one window in two states — compact controls by
  default (status, session timer, connect button, the four switches) and a
  **Show Dashboard** link that expands it in place into the live dashboard
  (engine/policy/traffic cards, request table, log). The choice is remembered
  between launches, and the window expands itself when the tunnel comes up or
  when you switch the proxy engine on. The VPN/engine/system-proxy switches sit
  in the main window, so the everyday loop never needs Settings
- **Settings** (1.4.0): a native sidebar-and-detail window — **Connection**
  (VPN, Profiles), **Proxy Engine** (Dashboard, Policies, Rules, Routing),
  **Monitoring** (History) and **Application** (Appearance, Advanced) — with a
  searchable sidebar, a remembered pane, and an **Advanced** pane for engine
  ports, log files, storage locations and resetting the app's settings

## Prerequisites

Before using this application, ensure you have the following tools installed via Homebrew:

```bash
# Install required tools
brew install openconnect
brew install stoken
brew install vpn-slice
```


## Configuration

### Initial Setup

1. Launch the application
2. Go to **TurtleDiver > Settings** (or press ⌘,)
3. Fill in the required VPN configuration:
   - **VPN Host**: Your VPN server hostname
   - **VPN ID**: Your VPN username/ID
   - **VPN Password**: Your VPN password
   - **Passcode**: Your RSA token passcode
   - **Slice URLs**: URLs/IP addresses to route through VPN (one per line)

### Loading Existing Configuration

The app can automatically load settings from your existing config file at `/Users/idraki/Documents/proxy/config.cfg` if it exists.

## Usage

### Connecting

1. Choose connection type:
   - **With tunneling**: Uses vpn-slice to route only specified URLs through VPN
   - **Without tunneling**: Routes all traffic through VPN
2. Click **Connect VPN**
3. You may be prompted for sudo password

### Disconnecting

Click **Disconnect** to terminate the VPN connection.

### Debug Mode

**Debug Output** in the main window reveals the live log in the expanded
dashboard. The Dashboard pane in Settings carries the same engine and
system-proxy switches.

### Main window: compact ↔ expanded (1.4.0)

The window opens **compact** — status, session timer, Connect/Disconnect, and
the four switches (Tunneling, Proxy Engine, Use as System Proxy, Debug Output).
**Show Dashboard ⌄** at the bottom expands the same window in place into the
dashboard: the switch cards, a **Proxy Engine** card (listening addresses), a
**Policy Health** card (latency per policy, **Test All**), a **Traffic** card,
the live **Recent Requests** table and the **Live Log**. **Hide
Dashboard** (or closing the window and re-opening it) collapses it back.

The compact rows are a list, not a form: labels on the left, the switch on a
shared right edge, a hairline between rows. The dashboard's live log is
colour-coded by line (`[SEND]` purple, `[HANDLER]` blue, warnings amber,
errors red) rather than by stream, because openconnect writes ordinary progress
to stderr.

Two details worth knowing:

- **Auto-expand.** The dashboard opens itself when the tunnel reaches
  `Connected`, or when *you* switch the proxy engine on — never on the launch
  auto-start of the engine, so a saved preference can't override the window
  state you left behind. It folds back when the tunnel drops, but only if *it*
  opened it: once you toggle it yourself that choice sticks and is persisted
  (`mainWindowDashboardExpanded`).
- **Resizing.** Only the compact ↔ expanded change (and launch) resizes the
  window; it keeps its top edge and horizontal centre and is clamped to the
  visible screen (`MainWindowLayout`). Manual resizes are never overridden by
  VPN status changes.

### Settings (1.4.0)

**TurtleDiver > Settings** (⌘,) is a sidebar-and-detail window, like the rest of
macOS: pick a pane on the left, the pane itself never pushes another screen, and
the window reopens on the pane you were last in (`settingsPane`). The sidebar is
searchable — typing `log`, `stoken` or `listener` filters it by title,
subtitle and keywords.

| Group | Panes |
| --- | --- |
| Connection | **VPN** (credentials, software token, split tunneling), **Profiles** |
| Proxy Engine | **Dashboard** (engine + system-proxy switches, policy health, requests), **Policies**, **Rules**, **Routing** |
| Monitoring | **History** (past connection attempts, with each attempt's log) |
| Application | **Appearance**, **Advanced** |

Two panes are worth calling out:

- **VPN** is the only pane with an explicit **Save / Revert** (⌘S) bar, pinned to
the bottom of the pane. Everything else applies immediately, but credentials go
to the Keychain and writing a half-typed password on every keystroke would both
be noisy and lose the previous value. The pane also has an **Administrator
password (sudo)** field — that one was previously only settable by hand.
- **Advanced** reports the proxy engine's status and listening addresses, the
log files (`~/Library/Logs/TurtleDiver/vpn.log` — openconnect output per
connection, with credentials redacted to their length; `…/launch.log` — app
startup), the profiles folder, whether each credential is in the Keychain
(presence only, never the value), and the destructive **Reset All Settings**
(profiles on disk are left alone).

Settings uses the same visual language as the dashboard: 10 pt cards,
hairline-separated rows, one shared right edge for controls, monospaced paths
and ports, and a status pill per row.

### Proxy Engine (1.3.0)

Settings → **Dashboard** holds the engine toggle. When enabled, the app listens
on `127.0.0.1:6152` (HTTP) and `127.0.0.1:6153` (SOCKS5) and routes every
request through the active profile's rules. See:

- `docs/PROXY_ENGINE.md` — listeners, routing, request log
- `docs/PROFILES.md` — full profile syntax (`[General]`, `[Proxy]`,
  `[Proxy Group]`, `[Rule]`)
- `docs/SYSTEM_PROXY.md` — system proxy lifecycle and VPN tie-in

The engine is independent of the VPN: it can run with or without a tunnel, and
when split tunneling is active, vpn-slice targets are auto-added as DIRECT
rules so corporate traffic always flows through the tunnel.

### Routing (1.3.0)

Settings → **Routing** is the daily-driver screen: `DOMAIN-SUFFIX example.com →
Proxy A`, `IP-CIDR 1.2.3.0/24 → DIRECT`, and so on. Rules are matched in order,
first match wins, with the active profile's `FINAL` as catch-all. *Import PAC*
in the toolbar pastes or loads a `.pac` file, previews the proxies, groups,
rules and diagnostics it would create, and applies them to the active profile.

### Migrating from the old PAC mode

The PAC-based proxy mode (`Use Proxy`, Settings → *Proxy (PAC)*, a bundled
`python3 http.server` on port 8765) was **removed in 1.3.1** in favour of the
engine. To carry an existing PAC over, use Routing → *Import PAC*: it converts
`shExpMatch` / `dnsDomainIs` / `isInNet` style conditions into
`DOMAIN-SUFFIX` / `DOMAIN` / `IP-CIDR` rules and turns the proxy list into
`[Proxy]` entries behind a `fallback` group. See
`docs/PROXY_ENGINE.md` and §10–11 of `docs/SURGE_CAPABILITIES_PLAN.md`.

If an older build left macOS pointed at the retired PAC server
(`http://127.0.0.1:8765/proxy.pac`), the app turns that PAC off on first launch;
a corporate PAC is left untouched and is temporarily disabled only while the
engine owns the system proxy.

## Development

1. Clone or download this project
2. Open `VPNConnect.xcodeproj` in Xcode
3. Build and run the project

## Architecture

The application consists of several key components:

- **AppDelegate**: Application lifecycle, status-bar menu, window sizing
- **MainView**: Primary SwiftUI UI with connection controls and status display
- **VPNManager**: Core VPN connection logic using Process to execute CLI commands
- **SettingsManager**: Configuration persistence (UserDefaults + Keychain)
- **EngineController**: Owns the proxy engine lifecycle, the active profile and
  the system-proxy intent
- **Profile / ProfileManager**: Surge-compatible `.conf` profiles under
  `~/Library/Application Support/TurtleDiver/Profiles`
- **Engine**: HTTP and SOCKS5 listeners, relay, rule matching
- **System**: `SystemProxyManager` (snapshot/apply/restore) and the vpn-slice
  DIRECT-rule overlay

## Security Notes

- Credentials (VPN password, passcode and the admin/sudo password) live in the
  macOS **Keychain**, never in `UserDefaults`. A launch-time hygiene pass
  migrates anything an older build left in the plist into the Keychain (the
  Keychain value always wins), then deletes the dead credential and PAC-era
  keys — so a plaintext password no longer sits in
  `~/Library/Preferences/com.idraki.turtle.vpn.plist`.
- The application requires sudo privileges for VPN connection and for setting
  the system proxy
- All network traffic is handled through standard macOS networking APIs
- App output does not live in `/tmp` any more: the connection and launch logs
  are `~/Library/Logs/TurtleDiver/{vpn,launch}.log` (owner-only, `0600`) so
  nobody can pre-create a predictable path, and credentials are redacted to
  their length before they are ever written.

### Known issue: a predictable PID file

`VPNManager` still records the openconnect child PID in
`/tmp/turtlediver.pid`, and reads it back to adopt a surviving process after a
restart. `/tmp` is world-writable, so another local user could pre-create that
name (as a file or a symlink) before the app runs — the worst case is a
clobbered user file or a stale PID being probed. It carries no credentials.

The fix is the same one the logs already got — move the file to
`~/Library/Application Support/TurtleDiver/run/openconnect.pid` (`0600`) and
keep reading the old `/tmp` path once as a migration fallback (adoption also
has a `pgrep` tier, so it degrades safely). Left for a session with a real VPN
available, because a wrong change here could leave an orphaned openconnect
running.

### Known issue: credentials in the launch pipeline

`VPNManager` starts openconnect through `/bin/bash -c` and feeds the
credentials through the shell pipeline
(`printf '<pin>\n<password>' | sudo openconnect …`). The credentials are
`printf` arguments, so they are part of that process's command line and any
process running as the same user can read them with `ps` — and they end up in
crash reports. They are **redacted in the app's own logs**
(`~/Library/Logs/TurtleDiver/vpn.log`, owner-only, truncated on each connect)
and never written to `debugOutput`.

Fixing it properly means dropping the shell string: cache the sudo timestamp
with a `Process` whose stdin carries the admin password, then run
`sudo openconnect` directly and write the PIN/password into its stdin from
Swift. That touches the one flow the app cannot afford to break, so it is
deliberately left as a separate change with a real-VPN test.

## Troubleshooting

### Connection Issues

1. Verify all required tools are installed: `brew list openconnect stoken`
2. Check that vpn-slice is installed: `brew list | grep vpn-slice`
3. Ensure your VPN credentials are correct
4. Check debug output for specific error messages

### Token Generation Issues

If stoken fails to generate tokens:
1. Verify your RSA token is properly configured
2. Check that stoken is installed and accessible
3. Ensure your passcode is correct

### Network Issues

If VPN connects but traffic doesn't route properly:
1. Check slice URLs configuration
2. Verify network permissions in System Preferences
3. Review openconnect logs in debug mode

## Development

### Building from Source

1. Open the project in Xcode
2. Select your development team in project settings
3. Build and run (⌘R)

### Code Structure

```
VPNConnect/
├── AppDelegate.swift              # Application delegate, status-bar menu
├── MainView.swift                 # Main SwiftUI screen
├── EngineController.swift         # Engine + system-proxy lifecycle
├── VPNManager.swift               # VPN connection logic
├── SettingsManager.swift          # Settings management
├── SettingsView.swift             # Settings window shell (sidebar + detail)
├── SettingsWindowController.swift  # Settings window (size, deep links)
├── Engine/                        # HTTP + SOCKS5 listeners, proxy engine
├── Profile/                       # Profile model, parser, policy store
├── Rules/                         # Rule matching, PAC conversion, DNS/IP utils
├── System/                        # System proxy, vpn-slice rule generation
├── Views/                         # Dashboard, Routing, Profiles, Rules editors,
│                                  #   Settings panes + design system
├── Assets.xcassets                # App icons and assets
└── Info.plist                     # App configuration
```

### Tests

```bash
swift test          # 350 tests (core engine + app glue)
```

The SwiftPM package compiles the Foundation-only engine sources plus a small
app-glue target, so the engine, rule matching, PAC conversion, profile handling
and system-proxy logic are all covered without needing Xcode.

## License

This project is provided as-is for educational and personal use.

## Support

For issues or questions, please check the troubleshooting section or review the debug output for specific error messages.
