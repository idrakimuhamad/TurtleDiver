# Manual Test Checklist

Human verification for the paths automated tests cannot cover (real
`networksetup` mutations, sudo flows, system dialogs, real VPN). Run before a
release.

## 0. Setup

- [ ] `swift test` passes (354 tests green).
- [ ] App builds and launches: Xcode ▶ or
      `xcodebuild -project VPNConnect.xcodeproj -scheme VPNConnect build`.

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
      (`plutil -p ~/Library/Preferences/com.idraki.turtle.vpn.plist \
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

## 0c. Settings window (1.4.0)

- [ ] ⌘, opens Settings as a **sidebar-and-detail** window (860×620 content,
      min 800×560): searchable sidebar, pane title + description on the left of
      the detail, no push-navigation.
- [ ] The sidebar groups are Connection (VPN, Profiles) / Proxy Engine
      (Dashboard, Policies, Rules, Routing) / Monitoring (History) /
      Application (Appearance, Advanced); the footer shows the engine dot,
      `v1.4.0` and the active profile.
- [ ] The sidebar can hold its width: drag the divider as far left as it goes
      → it stops at the search field (the placeholder never clips to
      `Search setting:`) and the sidebar never disappears (see
      `docs/SETTINGS_LAYOUT.md`).
- [ ] Open a pane, close the window, reopen → it lands on the *same* pane
      (`plutil -p ~/Library/Preferences/com.idraki.turtle.vpn.plist | grep
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
      field and the pane title stay at the same height on every pane
      (**known issue:** Policies sits 28 pt higher — see
      `docs/SETTINGS_LAYOUT.md`).

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
