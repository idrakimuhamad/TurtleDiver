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

**Debug Output** in the main window (or Settings → General) reveals the live log
in the expanded dashboard.

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

- VPN credentials are stored in macOS Keychain via UserDefaults
- The application requires sudo privileges for VPN connection
- All network traffic is handled through standard macOS networking APIs

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
├── SettingsView.swift             # Settings window (incl. Routing)
├── Engine/                        # HTTP + SOCKS5 listeners, proxy engine
├── Profile/                       # Profile model, parser, policy store
├── Rules/                         # Rule matching, PAC conversion, DNS/IP utils
├── System/                        # System proxy, vpn-slice rule generation
├── Views/                         # Dashboard, Routing, Profiles, Rules editors
├── Assets.xcassets                # App icons and assets
└── Info.plist                     # App configuration
```

### Tests

```bash
swift test          # 296 tests (core engine + app glue)
```

The SwiftPM package compiles the Foundation-only engine sources plus a small
app-glue target, so the engine, rule matching, PAC conversion, profile handling
and system-proxy logic are all covered without needing Xcode.

## License

This project is provided as-is for educational and personal use.

## Support

For issues or questions, please check the troubleshooting section or review the debug output for specific error messages.
