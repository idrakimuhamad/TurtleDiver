# Manual Test Checklist

Human verification for the paths automated tests cannot cover (real
`networksetup` mutations, sudo flows, system dialogs, real VPN). Run before a
release.

## 0. Setup

- [ ] `swift test` passes (485 tests green).
- [ ] App builds and launches: Xcode ▶ or
      `xcodebuild -project VPNConnect.xcodeproj -scheme VPNConnect build`.

## 0a. Bundle-identifier rename (2.0.0) — one-time, run before installing 2.0.0

Installing 2.0.0 over 1.5.0 changes the app's identity, so this is the one
section that has to be done **before** the new build is launched (the old plist
is the input).

- [ ] Note what the old build had: `plutil -p
      ~/Library/Preferences/com.idraki.turtle.vpn.plist | grep -c .` (the
      renamed app reads `…/com.xvii.kurakura.vpn.plist` from now on).
- [ ] Quit 1.5.0, install 2.0.0, launch it → the launch log
      (`~/Library/Logs/TurtleDiver/launch.log`) starts with
      `Step 0: Migrating settings from older bundle ids...` and reports a
      non-zero number of settings keys (0 only on a clean install).
- [ ] **The window comes up and the app is usable while the next step is
      pending** — `Step 0b: Migrating credentials …` is logged, but the launch
      does not wait for it. (It used to: the credential copy blocked step 0, and
      one first launch sat there for 10h56m before any window existed.)
- [ ] **macOS asks once per credential whether TurtleDiver may read a Keychain
      item created by the old app identity.** Click *Always Allow*; never
      script this. A cancelled prompt leaves that credential uncopied — the VPN
      pane shows *NOT SET* and you can retype it. Retyping is safe: the copy
      re-checks each item just before writing and will not overwrite a value
      that appeared while the dialog was open.
- [ ] The VPN pane still shows the organization domain, username and profile
      it had before the rename, and the four switches are where you left them
      (settings copied).
- [ ] `plutil -p ~/Library/Preferences/com.xvii.kurakura.vpn.plist | grep -c .`
      is at least as large as the old count (nothing was dropped).
- [ ] Connect once without retyping anything → the connect succeeds, so all
      three credentials were copied to the new service.
- [ ] The old items still exist for outside tools:
      `security find-generic-password -s com.idraki.turtle.vpn >/dev/null &&
      echo kept` → `kept` (the user's own reconnect script reads them by name).
      Do **not** print a value (`-w`), only the status.
- [ ] Relaunch → `Step 0b done. credentials: 0` (the copy happens once) and no
      Keychain prompt appears again.
- [ ] Advanced → Storage → *Preferences* shows `com.xvii.kurakura.vpn`.
- [ ] **Reset All…** (after a confirmation) clears the credentials from *both*
      services: `security find-generic-password -s com.idraki.turtle.vpn` →
      `could not be found` — a reset is meant to be a reset.

## 0b. Main window: compact ↔ expanded (1.4.0)

- [ ] Launch → the window opens **compact** (380×520 content): header with the
      app icon + `TurtleDiver` + active-profile pill, status hero with session
      timer when connected, Connect/Disconnect, the four switch rows
      (Tunneling, Proxy Engine, Use as System Proxy, Debug Output) and
      **Show Dashboard ⌄**.
- [ ] Compact rows read as a list: the four switches share one right edge
      (not ragged at each label's end), a hairline separates the rows, and the
      rows fill the window with no dead band at the bottom.
- [ ] Switch the engine ON while compact → the window expands (that is a user
      action). Then relaunch with `useProxyEngine = true`: the engine starts
      **without** expanding the window (a launch auto-start must not override
      the state you left).
- [ ] Click **Show Dashboard** → the *same* window animates to the expanded
      dashboard (940×780) keeping its top edge and horizontal centre: switch
      cards, Proxy Engine / Policy Health / Traffic cards, Recent Requests
      table, Live Log (its default is *this session*, not "today").
- [ ] **Hide Dashboard** returns to compact; the choice survives a relaunch
      (`plutil -p ~/Library/Preferences/com.xvii.kurakura.vpn.plist \
      | grep mainWindowDashboardExpanded`).
- [ ] Open it manually, then connect/disconnect the VPN → the window does NOT
      collapse on disconnect (a manual choice is not auto-corrected).
- [ ] Resize the window by hand, then connect/disconnect → the frame is left
      alone (only compact ↔ expanded and launch resize it).
- [ ] On a small display (or with the window near a screen edge), expanding
      stays on screen (clamped, never below the compact height).
- [ ] Recent Requests: search box, All/Proxied/Direct/Rejected filter, Pause
      freezes the table, Clear empties it, REJECT rows are tinted red.
- [ ] Policy Health: every policy is listed with a coloured dot; **Test All**
      fills the latency pills (green/amber/red) — and is greyed out while the
      engine is off.
- [ ] Traffic card with no bytes yet shows *No bytes transferred yet.* instead
      of two full-width bars that look like traffic.
- [ ] Live Log (debug output on, tunnel connected): `[SEND]` lines are purple,
      `[HANDLER]` blue, stderr lines grey; a line containing *error* is red and
      *warning* amber — colour follows the line, not the stream.

## 0b2. Rule Sets (1.5.0)

- [ ] Settings → **Rule Sets**: add `Ads = <an https URL>` with *Only when I ask*;
      the row appears as `Not downloaded` and **nothing is fetched**.
- [ ] Press its ↻: a progress spinner, then a rule count pill and
      *Updated just now*; `~/Library/Application Support/TurtleDiver/RuleSets/`
      holds `<slug>-<hash>.rules` + `.json`, both mode `0600`
      (`ls -l@`).
- [ ] Point the row at a policy: ⋯ → *Use in rules* → `REJECT` (the submenu
      ticks the policy that is in force; *Not used* un-points it). The profile
      gains `RULE-SET,Ads,REJECT` just above `FINAL`, the row loses its
      `NOT USED` pill, and a host in the list is rejected (through the engine:
      `curl -x http://127.0.0.1:6152 http://x-txtagstore.test/` → *403
      Forbidden*, body `rejected by rule`) while a host above it in `[Rule]`
      still wins (add `DIRECT` for the same host at the top of `[Rule]` → the
      request goes out instead). Re-choosing a policy must **not move the
      rule**: precedence is positional.
- [ ] Delete the downloaded copy (⋯ → *Remove downloaded copy*) → the reference
      matches nothing and the row says `Not downloaded`; the engine keeps
      working, nothing falls back to `REJECT` globally.
- [ ] Retarget a downloaded set (⋯ → *Edit…*, change the URL) → the old body is
      deleted at once (the copy caches under a new name), the row says
      `Not downloaded` until you press ↻, and no stale rules match meanwhile.
- [ ] Break the URL (⋯ → *Edit…* → a host that does not exist, then ↻) → a red
      `ERROR` pill and **one sentence** (*Could not find that host*), never an
      `NSError` dump. A failed refresh of an unchanged URL keeps the copy it
      already had (`RuleSetStoreTests.testFailedRefreshKeepsTheLastGoodCopy`),
      and a URL that is not `https` is refused before any request is made.
- [ ] *Delete Rule Set* (⋯) warns how many `RULE-SET` rules it will take with it
      (0 → *The downloaded list is deleted too.*), then removes the declaration,
      the rule **and both cache files** (`ls -A` on the cache directory).
- [ ] *Refresh automatically* stays **off** across a relaunch (it is opt-in, and
      no set declares an interval until you give it one).

## 0c. Settings window (1.4.0)

- [ ] ⌘, opens Settings as a **sidebar-and-detail** window (860×620 content,
      min 800×560): searchable sidebar, pane title + description on the left of
      the detail, no push-navigation.
- [ ] The sidebar groups are Connection (VPN, Profiles) / Proxy Engine
      (Dashboard, Policies, Rules, Routing, Rule Sets) / Monitoring (History) /
      Application (Appearance, Setup, Advanced); the footer shows the engine dot,
      `v2.0.0` and the active profile.
- [ ] The sidebar can hold its width: drag the divider as far left as it goes
      → it stops at the search field (the placeholder never clips to
      `Search setting:`) and the sidebar never disappears (see
      `docs/SETTINGS_LAYOUT.md`).
- [ ] Open a pane, close the window, reopen → it lands on the *same* pane
      (`plutil -p ~/Library/Preferences/com.xvii.kurakura.vpn.plist | grep
      settingsPane`).
- [ ] Type `log` / `stoken` / `listener` in the sidebar search → the list
      filters by title, subtitle and keywords; clearing restores every pane.
- [ ] Every pane opens at the top: the title is fully visible under the
      toolbar, never clipped by the scroll-edge blur (Advanced was the
      reproducer).
- [ ] **VPN** pane: credentials are pre-filled from the active profile, the
      reveal buttons work, `Administrator password (sudo)` is present, and the
      **Save/Revert** bar is pinned to the bottom of the pane (scroll the pane:
      the bar stays). Editing a field → *Unsaved changes* + enabled buttons;
      ⌘S saves; Revert restores the loaded values and re-disables the buttons.
- [ ] **Advanced** pane: engine status pill and both listeners, the log paths
      (`~/Library/Logs/TurtleDiver/{vpn,launch}.log`) and profiles folder with
      working Reveal/Open buttons, Keychain presence pills (IN KEYCHAIN / NOT
      SET — never a value), and **Reset…** clears settings + credentials after a
      confirmation while leaving the `.conf` files on disk.
- [ ] **History** pane: status pills stay on one line (e.g. `APP EXITED`,
      `DISCONNECTED`) and durations are right-aligned; expanding an attempt
      shows its log.
- [ ] **Profiles** pane: the summary pluralises correctly
      (`2 proxies · 1 group · 35 rules`).
- [ ] Machine values are never grouped or wrapped in `Optional(…)`: the HTTP
      listener reads `127.0.0.1:6152`, request hosts read `host:443`.
- [ ] Deep links from the menu bar (Open Dashboard…) still land on the right
      pane.
- [ ] Switching panes does not move the window chrome: the sidebar's search
      field and the pane title stay at the same height on every pane, including
      **Policies** (its pane used to demand 676 pt of height in a 620 pt
      window, which tucked the search field under the titlebar and pushed the
      footer off the bottom edge — see `docs/SETTINGS_LAYOUT.md` §3). Check all
      nine: the search field must sit just under the titlebar and the pane
      title must be fully visible, on every pane.

## 0d. Setup pane (2.0.0)

The pane that answers "why won't it connect" when a command-line tool is
missing. Advisory by design: it reports, it installs nothing silently, and it
disables nothing.

- [ ] **Settings ▸ Setup** (⌘, → Application → Setup) shows **Required tools**:
      Homebrew, openconnect, stoken, vpn-slice, each with its resolved path, a
      version pill taken from that tool's own `--version` output, and one line
      saying what breaks without it. On a working machine the four read
      `/opt/homebrew/bin/{brew,openconnect,stoken,vpn-slice}` with `7.0.1`,
      `9.21`, `0.93`, `0.16.1` (see `screenshots/setup-pane.png`).
- [ ] The version pill is the *tool's* version, not the first number in the
      output: openconnect's second line is `Using GnuTLS 3.8.13`, and the pill
      must still read `9.21`.
- [ ] The footer under the rows names the search order: `$PATH` first, then
      `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` and
      `~/.local/bin`. A tool installed by MacPorts must be found, and its path
      must show `/opt/local/bin/…` — that is the bug this pane came with.
- [ ] **Install** card: the pill reads `ALL INSTALLED` when nothing is missing
      and **Install Missing** is disabled. With nothing missing, pressing it
      (were it enabled) must start no process — check with `pgrep -fl brew`.
- [ ] **By hand** shows the same `brew install openconnect stoken vpn-slice`
      line as `packaging/README_INSTALL.txt`, with a working copy button.
- [ ] **Check Again** re-resolves without a restart (no spinner left behind,
      no change to the paths when nothing has been installed).
- [ ] The menu bar's **Check Requirements…** item lands on this pane.
- [ ] **Missing-tool path (needs a machine with a tool removed — not run in
      2.0.0's verification):** with `stoken` renamed away, Connect must stop
      before it asks for a token, say `stoken is not installed — see Settings ▸
      Setup`, and record the attempt as `Failed - Missing Tool`, whose History
      pill reads **Missing tool** — not **Token error**. The install button then
      streams Homebrew's output into a **Homebrew output** card.
- [ ] Install output never reaches `~/Library/Logs/TurtleDiver/vpn.log`:
      `grep -i 'openconnect stoken vpn-slice' ~/Library/Logs/TurtleDiver/*.log`
      returns nothing.

## 1. Profile lifecycle

- [ ] First launch creates `Main.conf` under
      `~/Library/Application Support/TurtleDiver/Profiles/`.
- [ ] Settings → Profiles: create, duplicate, activate, delete (active profile
      refuses to delete), Open in External Editor opens the `.conf`.
- [ ] Hand-edit the active `.conf` in an editor → file watcher reloads it
      within ~0.5 s; Rules view reflects the change.

## 2. Engine + rules

- [ ] Main window → **Proxy Engine** ON (or Settings → Dashboard) → the engine
      card shows Running with ports; listeners respond:
      `curl -x http://127.0.0.1:6152 http://cp.cloudflare.com/generate_204 -I`
- [ ] SOCKS5: `curl -x socks5h://127.0.0.1:6153 https://www.apple.com -I`
- [ ] Add `DOMAIN-SUFFIX,example.com,REJECT` above FINAL → curl through the
      proxy to example.com fails immediately; the REJECT row appears in the
      request log with red policy.
- [ ] `no-resolve` on an IP-CIDR rule: request to a bare hostname skips the
      rule (visible via the matched-rule column).
- [ ] Pause freezes the request table; Clear empties it.

## 2b. Request details (2.0.0)

Requires the engine ON and Settings → Dashboard → *Record request details* ON
(the default). Details are **memory only** — they are never written to
`vpn.log`.

- [ ] `curl -x http://127.0.0.1:6152 http://cp.cloudflare.com/generate_204 -I`
      → the row's subtitle shows the response status; **click the row** and the
      sheet opens with **Request** (`GET http://…/generate_204 HTTP/1.1` plus
      `user-agent: curl/…`) and **Response** (`HTTP/1.1 204 No Content`).
- [ ] **Copy All** puts the whole sheet on the clipboard; each section's own
      *Copy* copies just that section.
- [ ] Redaction: repeat with `-H 'Cookie: secret=abc123'` → the header reads
      `•••• (16 chars)`, and the value is nowhere:
      `grep -c abc123 ~/Library/Logs/TurtleDiver/vpn.log` → `0`.
- [ ] Settings → Dashboard → **Show sensitive header values** ON, repeat the
      curl → the cookie now reads `secret=abc123`. Turn it back off: only
      captures made while it was on ever held the value.
- [ ] **Record request details** OFF → new rows still appear (host, rule,
      policy, bytes) but their sheet says *No request head was captured.*
- [ ] Tunnel SNI: `curl -x http://127.0.0.1:6152 https://www.apple.com -I` →
      the **TLS handshake** section names `www.apple.com` with a version and
      `h2`; **Response** explains that it is encrypted. Nothing is decrypted.
- [ ] SOCKS5 SNI: `curl -x socks5h://127.0.0.1:6153 https://www.apple.com -I`
      → the row was `1.2.3.4:443`, and the sheet names the host anyway.
- [ ] A REJECT row opens too: the request line and headers are captured before
      the block, and **Error** reads `rejected`.
- [ ] Bounds: at most 32 header rows per section, values cut at 512 bytes
      (`…`), and once more than 200 newer requests have arrived the oldest rows
      no longer have a detail (the row itself stays).
- [ ] A hung upstream must not take the engine with it. With the VPN **down**
      (so a rule pointing at the corporate `PAC Fallback` group cannot connect),
      `curl -x http://127.0.0.1:6152 https://teams.microsoft.com/ -m 12` hangs on
      its own connect timeout — while a second,
      `curl -x http://127.0.0.1:6152 http://cp.cloudflare.com/generate_204`,
      still answers `204` in milliseconds.
- [ ] Every row opens the sheet wherever it is clicked (time, host, policy or
      size column) — the tooltip hint sits on the table's toolbar, not over the
      rows it would otherwise swallow the click for.

## 3. Policies & groups

- [ ] Policies → Add Proxy (socks5 127.0.0.1 with a local fake, or any real
      server): saved without password text in the `.conf` (password only in
      Keychain).
- [ ] Create a `select` group with 2 members → Dashboard shows the override
      picker; switching persists across app restarts.
- [ ] Create a `url-test` group with the fake proxies → Test All measures and
      badges update; the lowest-latency member is used.
- [ ] `fallback` group: kill the first member's server → traffic moves to the
      second on the next test cycle.

## 4. System proxy (mutates real settings!)

- [ ] Pre-state: note current proxy settings per service
      (`networksetup -getwebproxy "Wi-Fi"` etc.).
- [ ] Dashboard → Use as System Proxy ON (main window switch or Settings →
      Dashboard) → `scutil --proxy` shows HTTP/HTTPS/
      SOCKS 127.0.0.1 with the engine ports; bypass domains match the
      profile's skip-proxy.
- [ ] All enabled services configured (check Ethernet too if present);
      disabled services untouched.
- [ ] Browser honors the proxy (request rows appear for its traffic).
- [ ] Toggle OFF → previous settings restored exactly (compare with the
      pre-state captured above, including pre-existing third-party proxies).
- [ ] Crash repair: enable, then `killall -9 TurtleDiver` (or force-quit) →
      relaunch → previous settings restored automatically (stale snapshot
      repair), no proxy left pointing at the dead engine.

## 5. VPN tie-in

- [ ] Connect VPN with split tunneling (`10.0.0.0/8` + a corp hostname in
      slice URLs) while the engine runs → IP-CIDR/DOMAIN DIRECT rules appear
      at the top of the active profile; disconnect removes exactly them (user
      rules untouched).
- [ ] External profile edit while connected → overlay re-applied on top of
      the fresh rule list.

## 6. Menu bar

- [ ] Status item shows the engine state (icon variant / tint).
- [ ] Menu: Connect/Disconnect VPN (state-correct), Enable/Disable Proxy
      Engine, Profile submenu with checkmark on active, Policy Groups submenu
      per select group with checkmark, Test Latency Now, Open Dashboard…
      (deep-links into Settings → Dashboard), Settings…, Quit.
- [ ] Switching profile from the menu bar updates Rules/Policies views and the
      engine hot-swaps (request log keeps working).

## 7. Quit / teardown

- [ ] Quit with system proxy ON → proxy restored, listeners closed, VPN (if
      connected) disconnects cleanly per the existing flow.
- [ ] Quit with engine running (no system proxy) → listeners closed; next
      launch auto-starts the engine again (toggle persisted).
- [ ] After the quit, `~/Library/Logs/TurtleDiver/lifecycle.log` ends with a
      `launch` / `will-terminate-began` / `will-terminate-ended` triple for this
      run. Then `pkill -TERM TurtleDiver` (which skips the delegate method
      entirely) and check the next launch: the previous run has a `launch` line
      and no quit pair — that absence is the whole point of the file.
- [ ] Quit an instance that adopted **nothing** (no tunnel, no pid file) — the
      triple must still be there. This is the case that silently vanished once:
      with `NSSupportsSuddenTermination` / `NSSupportsAutomaticTermination` back
      to `true`, macOS can end the process instead of asking it. To confirm the
      guarantee is live, `log show --last 2m --predicate 'process ==
      "TurtleDiver"' | grep -i sudden` and look for `Exiting without sudden
      termination` rather than a `appDeath` with no willTerminate.

## 8. Regression — core VPN untouched

- [ ] Connect/disconnect without engine works exactly as before.
- [ ] Connection History, live log, theme, Keychain storage unchanged.
- [ ] **Backpressure regression (1.4.0):** with the engine on, download a large
      file through a slow consumer (e.g. `curl -x http://127.0.0.1:6152
      <big-file> -o /dev/null --limit-rate 200k`) and let it stall/resume a few
      times → the app must not crash (`com.turtlediver.engine.relay`
      exclusivity trap). Covered by
      `testRelayResumeProbeSurvivesBackpressureWithoutExclusivityTrap`.
- [ ] No `Proxy (PAC)` / `Use Proxy` UI remains (removed in 1.3.1): Settings →
      *Routing* → *Import PAC* is the only PAC entry point.
- [ ] A PAC left armed at `http://127.0.0.1:8765/proxy.pac` by an old build is
      turned off on launch (`networksetup -getautoproxyurl <svc>` → `Enabled: No`),
      while a real corporate PAC is left untouched.

## 9. Credential handling (1.5.0) — verified against a real connect

The launch path no longer puts a credential in an argument list. Everything
except the last step below is covered by `OpenConnectLaunchTests` (which runs
both plans against a fake `sudo`/`sed`/`openconnect` trio, so no real sudo,
`/etc/hosts` or network is touched); these steps confirm the real thing.

Verified 2026-09-15 against a real connect to `vpn.rhbgroup.com`: openconnect's
argv held only options (`--force-dpd=10 --reconnect-timeout=604800
--user=<id> --pid-file …/run/openconnect.pid -s …/vpn-slice <host> …`) with no
credential-shaped token, the log recorded `Credential stdin: 43 bytes, 3 lines`
(= 8+1, 12+1, 20+1) and an argv-free `Pipeline:` line, and vpn-slice went on to
resolve its host list.

- [ ] Connect the VPN from the app → the tunnel comes up exactly as before
      (the shell now `read`s the three credentials from stdin, and openconnect
      still gets `PIN\npassword` on its own stdin).
- [ ] `pgrep -x openconnect` → take the PID, then check the command line
      **without printing it**:
      `ps -p <pid> -o command= | tr ' ' '\n' | grep -cE '^(<admin>|<pin>|<password>)'`
      → `0`. (Never `pgrep -f`/`ps` with args on a machine with real
      credentials: the *pre-1.5.0* build printed them.)
- [ ] `ps -p <pid> -o command=` still shows `--force-dpd=10 … vpn.rhbgroup.com`
      → the connection is genuinely openconnect with the usual options.
- [ ] `stat -f %Lp ~/Library/Application\ Support/TurtleDiver/run` → `700`, and
      `/tmp/turtlediver.pid` is gone once a new connection starts. (The pid file
      itself is normally *absent*: openconnect only writes `--pid-file` when it
      daemonises, and this app does not pass `--background`. The app writes the
      file itself when it adopts a surviving openconnect, so it is usually the
      safe *path* that matters here, not a file.)
- [ ] Disconnect → openconnect exits, and the app still adopts/kills a
      surviving tunnel (the PID tier only matches a same-user process, so a
      root openconnect is found by the `pgrep` tier as before).

## 9b. Elevation (2.0.0) — the part unit tests cannot reach

The connect no longer guesses how `sudo` will authenticate: it reads the two
world-readable PAM files and asks `sudo -n -v` whether the timestamp is already
warm, then picks one of three strategies (`docs/ELEVATION.md`). Everything below
except the dialog itself is covered by `ElevationPolicyTests`,
`OpenConnectLaunchTests` and `ElevationWiringTests`.

- [ ] `grep -n pam_tid /etc/pam.d/sudo_local` → `2:auth       sufficient     pam_tid.so`.
      (On a machine without it, the app uses the stored password and none of the
      dialog steps below apply.)
- [ ] `sudo -k` (or wait for sudo to forget), then connect from the app → the
      debug log starts with
      `Elevation: Touch ID for sudo is enabled (pam_tid) and sudo's timestamp is cold.`
      **before** any openconnect output, and macOS shows its own Touch ID /
      password dialog. Answer it → the connect proceeds. **This is the step that
      only a human can run**: the automated suite classifies and times out the
      dialog path, it never answers one.
- [ ] Repeat with the dialog left unanswered → after ~90 s: status
      `Failed - Elevation Blocked (Touch ID)`, the log explains what happened,
      and there is exactly one History entry for the attempt.
- [ ] On a machine **without** Touch ID for sudo, store a deliberately wrong
      administrator password and connect → status `Failed - Admin Password`
      (not a bare `Connection failed (status: 1)`), and the log says the stored
      password was not accepted. Do not test this by editing PAM.
- [ ] During a connect, `cat ~/Library/Application\ Support/TurtleDiver/run/elevation.pgid`
      → a plausible pgid, and `ps -o pid=,pgid=,comm= -g <pgid>` shows the
      wrapper (names only — never `ps` with args).
- [ ] Disconnect, then `ps -o comm= -g <pgid>` → nothing. No `sudo`, no
      `openconnect`, and `pgrep -x sudo` is empty.
- [ ] Relaunch the app → `~/Library/Logs/TurtleDiver/launch.log` has
      `Step 0c: Sweeping stale elevation groups (background)...` and
      `Step 0c done.` followed by the decision. With no leftovers it is
      `nothingToDo`.
- [ ] **Never** observed, and not something to test: the app cannot kill a
      root-owned orphan that a *previous* build created — a non-root sender may
      not signal a root-owned process. The remedy is to leave it or kill it as
      root yourself; it exits on its own.
- [ ] System proxy *toggle* with `networksetup` made slow or a dialog left open
      → the app reports `Timed out changing the system proxy: …` within ~60 s and
      stays responsive. (Simulated in `BoundedNetworkSetupRunnerTests`; the real
      tool's dialog cannot be provoked on demand.)
