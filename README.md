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
  duration), latency badges, select-group overrides — click a row for the full
  **request details** (see below)
- **Request details** (2.0.0): what each row actually sent — request line and
  headers, the HTTP response status and headers, and, for an encrypted tunnel,
  the TLS ClientHello's server name (SNI), version and ALPN protocol. Credential
  headers are recorded as `•••• (N chars)` until you ask for them
- **Routing** (1.3.0): assign a policy per domain/domain-suffix/IP-CIDR in a
  friendly list (quick-add, inline edit, drag-reorder), plus a **PAC import
  wizard** that converts an existing `FindProxyForURL` script into rules and
  proxy policies
- **Rule Sets** (1.5.0): subscribe to a remote rule list over HTTPS and
  reference it from a rule (`RULE-SET,Ads,REJECT`); the list is downloaded once,
  cached at mode `0600`, spliced in at the reference's position, and shown with
  its source URL, rule count, age and skipped-line count. Refresh is manual
  unless a set declares an `interval`
- **Main window** (1.4.0): one window in two states — compact controls by
  default (status, session timer, connect button, the four switches) and a
  **Show Dashboard** link that expands it in place into the live dashboard
  (engine/policy/traffic cards, request table, log). The choice is remembered
  between launches, and the window expands itself when the tunnel comes up or
  when you switch the proxy engine on. The VPN/engine/system-proxy switches sit
  in the main window, so the everyday loop never needs Settings
- **Renamed app** (2.0.0): the bundle identifier is now
  `com.xvii.kurakura.vpn` (it was `com.idraki.turtle.vpn`). Preferences and
  Keychain items are carried over on first launch — see
  [Renaming the app](#renaming-the-app-200)
- **Settings** (1.4.0): a native sidebar-and-detail window — **Connection**
  (VPN, Profiles), **Proxy Engine** (Dashboard, Policies, Rules, Routing,
  Rule Sets),
  **Monitoring** (History) and **Application** (Appearance, Advanced) — with a
  searchable sidebar, a remembered pane, and an **Advanced** pane for engine
  ports, log files, storage locations and resetting the app's settings

## Installing

Download `TurtleDiver-<version>.dmg` from the releases page, open it, and drag
**TurtleDiver** onto the **Applications** shortcut. A `.pkg` is also built for
managed installs.

**The current release builds are signed but not notarized**, so a downloaded
copy is quarantined by macOS and the first launch refuses to open it. Either
right-click the app ▸ **Open**, or if macOS offers no override that way (macOS
15 and later hide it), allow it in **System Settings ▸ Privacy & Security**; the
blunt alternative is to clear the attribute:

```bash
xattr -dr com.apple.quarantine /Applications/TurtleDiver.app
```

A copy built on your own Mac — or installed from `./build.sh --install` — has no
quarantine attribute and launches directly. See
[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) for why, and for what it takes to
make downloads open without that prompt (a Developer ID certificate and
notarization).

## Prerequisites

The app drives three command-line tools, which must be installed via Homebrew:

```bash
# Install required tools
brew install openconnect
brew install stoken
brew install vpn-slice
```

They are looked up on `$PATH` first and then in `/opt/homebrew/bin`,
`/usr/local/bin`, `/opt/local/bin`, `~/.local/bin`, `/usr/bin` and `/bin` — the
prefixes Homebrew and MacPorts use, whether or not the app inherited them. The
**Setup** pane (⌘, → Application → Setup, or the menu bar's *Check
Requirements…*) lists each tool with the path it resolved and the version it
reports, and installs the missing ones with one click — `brew install` run as
you, with no password. It is advisory: nothing is disabled when a tool is
absent. A Connect that cannot start says which tool is missing and points at
that pane. Bundling the tools into the app is not viable (they and their 19
Homebrew dependencies come to 212 MB, and they are LGPL-2.1 / GPL-3.0, so
redistributing our own copies would add relinking and source-offer obligations
on top of the re-signing work).

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
| Proxy Engine | **Dashboard** (engine + system-proxy switches, policy health, requests), **Policies**, **Rules**, **Routing**, **Rule Sets** |
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
- `docs/ELEVATION.md` — how the app asks for privilege, and every deadline it
  waits on
- `docs/SETTINGS_LAYOUT.md` — why the sidebar is 172 pt wide, and the titlebar
  height contract

The engine is independent of the VPN: it can run with or without a tunnel, and
when split tunneling is active, vpn-slice targets are auto-added as DIRECT
rules so corporate traffic always flows through the tunnel. Outbound connects
run on a bounded concurrent pool, so an unreachable upstream (a corporate proxy
while off-VPN) costs one slot and its own timeout — never the whole engine.

### Request details (2.0.0)

Click any row in the dashboard's request table (Settings → **Dashboard**) to
open a sheet with what was sent and what came back:

- **General** — the row itself: host, port, rule, policy, size, duration, the
  address the relay actually connected to, and any capture note.
- **Request** — the request line and the request headers. For `http://` this is
  the whole head; for `CONNECT` it is the CONNECT line plus its own headers.
- **Response** — status line and response headers, captured on the plain-HTTP
  leg. A tunnel's response stays encrypted, and the sheet says so rather than
  showing an empty box.
- **TLS handshake** — the server name (SNI), version and ALPN protocol read
  from the client's ClientHello. The ClientHello is cleartext by design, so this
  is where a `CONNECT 1.2.3.4:443` (or a SOCKS5 row, which only ever had an
  address) learns the hostname it was really for.

Nothing is decrypted and no certificate is inspected: TLS 1.3 encrypts the
certificate message, so there is no chain to show. Each section has a
**Copy** button, and **Copy All** puts the whole sheet on the clipboard.

Sensitive header values — `Authorization`, `Cookie`, `Set-Cookie`,
`Proxy-Authorization`, `X-Api-Key` and anything whose name looks like a
token, secret or password — are replaced with `•••• (N chars)` **at capture
time**, so the value is never held in memory at all. Settings → Dashboard →
**Show sensitive header values** opts out of that redaction for new captures
(useful when a session cookie is what you are debugging). Capture itself can be
turned off with **Record request details**; both switches are off-safe for
existing installs (capture defaults on, reveal defaults off).

Details are bounded — at most 32 headers per message, values truncated at 512
bytes, and only the newest 200 rows keep a detail — and they live in memory
only. They never reach `vpn.log`, which a source-scan test enforces.

### Routing (1.3.0)

Settings → **Routing** is the daily-driver screen: `DOMAIN-SUFFIX example.com →
Proxy A`, `IP-CIDR 1.2.3.0/24 → DIRECT`, and so on. Rules are matched in order,
first match wins, with the active profile's `FINAL` as catch-all. *Import PAC*
in the toolbar pastes or loads a `.pac` file, previews the proxies, groups,
rules and diagnostics it would create, and applies them to the active profile.

### Renaming the app (2.0.0)

The bundle identifier is `com.xvii.kurakura.vpn` — it names both the
preferences domain and the Keychain service, so the first launch after the
rename has to bring the old data across. `AppDelegate` does that before
anything reads the settings (step 0 of the launch log):

- **Preferences** are copied from the old `UserDefaults` domains
  (`com.idraki.turtle.vpn`, `com.turtlediver`) with
  `persistentDomain(forName:)`; a key that already exists under the new
  identifier is never overwritten, and the global domain is never copied in.
- **Credentials** are copied from the old Keychain services the first time a
  current-service item is missing. The legacy items are left in place, because
  scripts that read them by name (e.g. a personal reconnect helper) still work.
  Because those items were created by the *old* app identity, macOS asks once
  per credential whether the renamed app may read them — click **Always Allow**
  and they are copied forward; after that the prompts stop.

`AppIdentity` holds the identifiers, and `AppIdentityTests` fails if they drift
from `PRODUCT_BUNDLE_IDENTIFIER` in the Xcode project — the two must agree or
the app would read its own secrets from a name the system does not accept.

### Rule Sets (1.5.0)

Settings → **Rule Sets** subscribes to a remote rule list — the Surge-style
`RULE-SET` feature, without the feed-reader baggage:

```ini
[Rule Set]
Ads = https://example.com/ads.conf, interval=86400

[Rule]
RULE-SET,Ads,REJECT
```

The pane adds, edits and removes those declarations, and owns the one button
that touches the network. A downloaded list is spliced into the rule list *at
the position of the reference*, so a `DOMAIN` rule written above
`RULE-SET,Ads,…` still wins, and the policy comes from the reference (never
from the list). Each row shows its source URL, rule count, age and how many
lines were skipped as unparseable.

Supply chain rules, because a remote list decides where traffic goes:

- **https only** — an `http://` or `file://` URL is refused, and no request
  leaves the machine.
- **8 MB cap**, UTF-8 only, `maxRules = 100_000`; `FINAL` and nested `RULE-SET`
  lines are skipped, not honoured.
- **Never executed** — the body is parsed as text, exactly like a local profile.
- **Refresh is opt-in** (`ruleSetAutoRefresh`, off by default): only sets that
  declare an `interval` are fetched on their own, and only on launch. Every
  download is otherwise your idea.
- **A failed refresh keeps the last good copy**, and a `RULE-SET` reference with
  no cached list stays **inert** — it does not silently fall back to its policy.
- Cache files live in `~/Library/Application Support/TurtleDiver/RuleSets/` at
  mode `0600`, named after the URL hash; changing the URL invalidates the cache.

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
- **Engine**: HTTP and SOCKS5 listeners, relay, rule matching, and the
  observe-only capture behind the request-detail sheet (`RequestDetail`,
  `TLSClientHello`, `RelayStreamObserver`)
- **RuleSetStore**: remote `[Rule Set]` download/cache (HTTPS only, 8 MB cap,
  keeps the last good copy, `0600` files)
- **System**: `SystemProxyManager` (snapshot/apply/restore) and the vpn-slice
  DIRECT-rule overlay

## Security Notes

- Credentials (VPN password, passcode and the admin/sudo password) live in the
  macOS **Keychain**, never in `UserDefaults`. A launch-time hygiene pass
  migrates anything an older build left in the plist into the Keychain (the
  Keychain value always wins), then deletes the dead credential and PAC-era
  keys — so a plaintext password no longer sits in the preferences file
  (`~/Library/Preferences/com.xvii.kurakura.vpn.plist`).
- The application requires sudo privileges for VPN connection and for setting
  the system proxy. It never *changes* how sudo authenticates: if Touch ID is
  enabled for sudo, macOS shows its own dialog and the app waits for you — see
  **`docs/ELEVATION.md`** for the full picture, including why the app reads but
  never writes `/etc/pam.d/sudo_local`.
- All network traffic is handled through standard macOS networking APIs
- App output does not live in `/tmp` any more: the connection and launch logs
  are `~/Library/Logs/TurtleDiver/{vpn,launch}.log` (owner-only, `0600`) so
  nobody can pre-create a predictable path, and credentials are redacted to
  their length before they are ever written.
- Credentials never reach a command line. `VPNManager` used to build
  `echo <admin-password> | sudo … && printf '<pin>\n<password>' | sudo
  openconnect …` and hand it to `bash -c`, which put all three secrets in that
  process's argv — readable with `ps`/`pgrep -f` by any process running as the
  same user, and copied into crash reports. The script that runs now is a
  constant: it `read`s the credentials from its standard input into unexported
  shell variables, so no credential material is ever part of an argument list.
  openconnect still receives exactly the same standard input the `printf`
  pipeline used to give it. See `OpenConnectLaunch.swift`; the flow is covered
  end-to-end by `OpenConnectLaunchTests` against a fake `sudo`/`openconnect`
  pair, and the file is created `0600`.
- Request details hold headers, and headers hold cookies. They are kept in the
  requests table's memory only, redacted at capture time by default, and the
  capture path is forbidden from touching the log at all (enforced by
  `testTheRequestCapturePathNeverReferencesTheDebugLog`). Turning on
  **Show sensitive header values** changes what the *next* captures keep — it
  cannot resurrect a value the app already refused to store.

### Elevation: Touch ID, dialogs, and orphans

`sudo` used to be handed the administrator password through a pipe while it was
warming its timestamp. On a Mac where `/etc/pam.d/sudo_local` enables `pam_tid`,
sudo offers Touch ID first, never reads the pipe, and waits on a dialog the app
was not watching for — so the connect stalled until its 90 s timeout, which then
killed the wrapper rather than the process holding the dialog.

The connect now decides **before** launching: it reads the two world-readable
PAM files and asks `sudo -n -v` whether the timestamp is already valid, then
either uses `sudo -n` (no dialog), hands over to macOS's own Touch ID dialog
(the log says so, up front), or falls back to the stored password. Only that
last path writes the password anywhere. The privileged body also runs in its own
process group, recorded in `…/TurtleDiver/run/elevation.pgid`, so teardown
signals the whole group instead of leaving something behind, and a launch-time
sweep cleans up a previous run's leftovers — the group that run recorded, and
nothing else. `networksetup` — the other elevation path — got the same
treatment: it had no deadline at all.

What the app cannot do is kill a root-owned process it did not start; a non-root
sender may not signal one. The fix is that it no longer creates them. An orphan
from a build older than this mechanism left no record for the sweep to read, so
removing one of those needs a root user — or a reboot.

### Fixed: a predictable PID file

`VPNManager` used to tell openconnect to record its PID in
`/tmp/turtlediver.pid`, and read it back to adopt a surviving process after a
restart. `/tmp` is world-writable, so another local user could pre-create that
name — as a plain file, or as a symlink pointing at a file of theirs, which the
app would then delete or openconnect (running as root) would write through.

It is now
`~/Library/Application Support/TurtleDiver/run/openconnect.pid`, in a directory
created `0700`. The old `/tmp` path is never read or written; a stale one is
deleted before each connection starts. A surviving openconnect is adopted through
the existing `pgrep` tier instead — which is the tier that does the work anyway,
because these files are written by a root process, so the `kill(pid, 0)` liveness
probe answers `EPERM` and no PID tier can be trusted to adopt it.

## Troubleshooting

### Connection Issues

1. Open **Settings ▸ Setup** (⌘, → Application → Setup, or the menu bar's
   *Check Requirements…*): every tool should show a green version pill and a
   path. Anything missing gets an amber badge and an **Install Missing** button;
   the same `brew install …` line is shown for copying.
2. Ensure your VPN credentials are correct
3. Check debug output for specific error messages
4. If **History** says *Failed - Elevation Blocked (Touch ID)*, macOS asked for
   Touch ID or your administrator password and nothing answered it. Connect
   again with the app in front so the dialog is visible; `docs/ELEVATION.md`
   explains when the app uses `sudo -n` instead, and when it falls back to the
   stored password.

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

Or from a terminal:

```bash
./build.sh                      # Release build of the app
./build.sh --install            # …and copy it to /Applications, then relaunch
./build.sh --debug --test       # Debug build + the SwiftPM test suite
./publish.sh --local            # .dmg + .pkg signed for this machine
./publish.sh                    # signed with Developer ID, notarized, stapled
```

`publish.sh` refuses to build a release artifact without a Developer ID
certificate and a notary profile, because the failure mode of guessing is an
installer that Gatekeeper silently rejects. `./publish.sh --help` lists the
options; output lands in `dist/` (git-ignored).

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
├── System/                        # System proxy, elevation policy, vpn-slice
│                                  #   rule generation, tool resolution
├── Views/                         # Dashboard, Routing, Profiles, Rules editors,
│                                  #   Settings panes + design system
├── Assets.xcassets                # App icons and assets
└── Info.plist                     # App configuration
```

### Tests

```bash
swift test          # 549 tests (core engine + app glue)
```

The SwiftPM package compiles the Foundation-only engine sources plus a small
app-glue target, so the engine, rule matching, PAC conversion, profile handling
and system-proxy logic are all covered without needing Xcode.

## License

This project is provided as-is for educational and personal use.

## Support

For issues or questions, please check the troubleshooting section or review the debug output for specific error messages.
