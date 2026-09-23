# IDEAS

An inbox, not a plan. Anything goes in here — half-formed, contradictory, one
line or ten, measured or guessed. Nothing in this file is a promise, and an idea
that never leaves it is a perfectly good outcome.

When one graduates it moves into `docs/` as a section of an operator doc, or
straight into a commit. Then it moves to **Picked up** at the bottom, with a
pointer, so this file does not fill with ghosts that nobody remembers the state
of.

## Adding one

Append a dated line to **Unsorted**:

    - (2026-09-22) Reconnect on wake rather than waiting out the DPD timeout.

If it needs more room than a paragraph, give it a card below — the point is that
writing it down costs nothing.

Three house rules, mostly borrowed from the rest of the repository:

- **No employer names, no real hosts or addresses, no paths off anyone's
  machine, no credentials.** `RepoPrivacyGuardTests` scans this file exactly
  like every other text file in the tree, and it is right to.
- **Say how you know.** "The connect took 30 s longer" is worth ten times more
  with the measurement behind it than without.
- **Say what it would break.** Half the cards below are cheap because something
  else already exists; the other half are expensive because it does not, and the
  difference is the only thing worth recording before someone starts.

## Index

Sizes are guesses, and deliberately pessimistic. "Needs" is what has to be true
or decided before the work is worth starting.

| # | Idea | Size | Needs |
|---|---|---|---|
| 1 | Match the SNI we already read (`extended-matching`) | M | A decision about replying before the name is known |
| 2 | The two missing domain rule types (`DOMAIN-WILDCARD`, `DOMAIN-SET`) | S | — |
| 3 | The remaining small rule types (`SRC-PORT`, `IN-PORT`, `HOSTNAME-TYPE`) | S | — |
| 4 | `IP-ASN`, and the GeoIP database `GEOIP` has been waiting for | M | A bundled database and an update story |
| 5 | The rule parameters we throw away | S | — |
| 6 | `SUBNET` rules: behave differently per network | S | — |
| 7 | Two missing policy groups (`subnet`, `automatic`) | S | `subnet` needs idea 6 |
| 8 | Say the tunnel's reason in the window, not just in the log | S | — |
| 9 | Logical rules: `AND`, `OR`, `NOT` | M | A nesting-safe rule model |
| 10 | `pre-matching`: reject at the DNS and handshake stage | M | A DNS layer worth intercepting |
| 11 | A Surge-profile compatibility report | S | — |
| 12 | DNS beyond the system resolver | L | Deciding whether we want to be a resolver at all |
| 13 | Automation: CLI, HTTP API, URL schemes | M | Somewhere for state to live that is not a window |
| 14 | A CLI a program can drive, not just a person — **picked up**, `docs/CLI.md` | M | The state question in idea 13 |
| 15 | Outbound protocol breadth | L | Somebody who actually needs one of them |
| 16 | Enhanced Mode: capture at the packet layer | XL | A privileged helper, signing, and a decision about what this app is |
| 17 | An agent the updater cannot replace | M | A version story for the helper |
| 18 | Liveness without shelling out to `ps` | S | A protocol version, so an old agent can be refused by name |
| 19 | A root `sudo` that waits through part of every connect | S | An hour with the process table |
| 20 | Notarization | S | An Apple Developer Program enrolment |
| 21 | Route another device's network through the engine | M | Revising the "serves this machine only" anti-goal, and an auth story for a non-loopback listener |

## Small and contained

### 1. Match the SNI we already read

Surge calls this `extended-matching`: a domain rule matches the TLS SNI (and the
HTTP `Host`) even when the client addressed an IP. We already read the SNI —
`HTTPProxyServer` and `SOCKS5Server` both probe the ClientHello and record it in
the request detail — but `RuleMatcher` has zero references to it, so it is
display-only.

**This is not the free win it looks like.** The probe is a *post-decision*
observer: the outcome is resolved and logged before the relay exists, and for
CONNECT the ClientHello only arrives after we have already answered `200`. So
matching on it means holding the client's first bytes before connecting
upstream, and a rule that rejects on the SNI can no longer answer `403 Forbidden`
— the client has been told the tunnel is up and will just see it close. Surge has
the same problem and answers it with fake-IP and pre-matching at the DNS layer
(idea 10, idea 16).

Worth doing for the routing correctness alone, but it needs a decision about
failure shapes first, not a field in the match context.

### 2. The two missing domain rule types

`DOMAIN-WILDCARD` (a hostname against a wildcard pattern) and `DOMAIN-SET` (a
plain hostname list, one per line, optional leading dot for suffixes). We already
have the hard half of `DOMAIN-SET`: remote lists, ETag-cached bodies, a Rule Sets
pane and an update interval live in `RuleSet.swift` for `RULE-SET`. A domain set
is that machinery with the rule parsing removed and the matching simplified to
suffix lookup.

`DOMAIN-WILDCARD` is the one with a trap: a wildcard implementation that gets
label boundaries wrong is worse than no rule type, since it silently matches more
than it should. The suffix matcher already does boundaries correctly and can be
reused.

### 3. The remaining small rule types

`SRC-PORT`, `IN-PORT`, `HOSTNAME-TYPE` (whether the value was a domain or an IP
literal). All three are cheap — the context already carries the ports and the
listener identity — and all three are low-value: `IN-PORT` only starts to matter
with several listeners, `SRC-PORT` is rarely anyone's intent, and
`HOSTNAME-TYPE` mostly helps people write rules that stop surprising them.

Cheap enough to do in one pass with idea 2, which is the only reason they are
listed separately.

### 4. `IP-ASN`, and the GeoIP database `GEOIP` has been waiting for

`GEOIP` has been in the rule grammar since Phase 2 and has never matched: it
parses, warns *"GEOIP rules are reserved and not matched yet"*, and returns no
match. `IP-ASN` is the same shape with a different database.

Neither is hard to *implement* — the CIDR matcher already does byte-exact prefix
containment. The work is the database: a MaxMind source, a bundled copy, an
update mechanism, a licensing question, and a policy about network access that
this app has so far avoided entirely. Until that is decided, `IP-ASN` should not
be added either, or the same warning gets a companion.

### 5. The rule parameters we throw away

Surge's rule lines accept nine parameters. We parse exactly one, `no-resolve`,
and only in the branch that reads it — an unrecognised parameter is dropped
silently rather than reported. The candidates, cheapest first:

- `dns-failed` on `FINAL` — use the FINAL policy when a lookup fails, instead of
  failing the request. Today a DNS failure aborts the connection.
- `notification-text=` / `notification-interval=` — tell the user when a rule
  fires, throttled. We already have a notification path and it needs no new
  state.
- `update-interval=` on the `RULE-SET` line — we have the interval, but only in
  the `[Rule Set]` section, so Surge's inline form does not mean anything here.
- `always-capture=` — force detail capture for a rule while debugging.

The trap is the silence: an unrecognised parameter is currently dropped without a
diagnostic, so a profile can ask for something we do not do and look accepted.

### 6. `SUBNET` rules: behave differently per network

`SUBNET` matches the network the machine is on — SSID, BSSID, router, type — so a
laptop can route differently at the office than at home. This is probably the
most immediately useful missing rule type for a laptop-shaped app, and it needs
no gateway mode and no packet capture: the information comes from the system.

Cost is mostly knowing which of the fields are reliably available on macOS
without Location permission, which is a real constraint on SSID and worth
settling before designing the rule syntax.

### 7. Two missing policy groups

Surge groups policies six ways; we do four (`select`, `url-test`, `fallback`,
`load-balance`). `subnet` picks by the same network information as idea 6.
`automatic` lets the system decide without a test URL — a cheaper default for
people who do not want to configure a probe.

`subnet` depends on idea 6; `automatic` depends on deciding what it means when
there is nothing to measure.

### 8. Say the tunnel's reason in the window, not just in the log

2.1.2 records a diagnosis (`Failed - Tunnel Ended`) plus the tunnel's own last
`STDERR` line, and both land in the History row and the debug pane. The pill and
any notification still show only the status word. On a failure the question a
person actually has is "why", and the answer is already sitting in the string the
app just parsed.

## Needs a design decision

### 9. Logical rules: `AND`, `OR`, `NOT`

The missing piece I would miss most. `AND,((DOMAIN-SUFFIX,x),(DEST-PORT,443)),REJECT`
cannot be expressed at all today — no rule list, no editor layout, and the
current rule model is a flat struct with one value. Nesting is capped at 10 in
Surge, sub-rules carry their own `no-resolve`, and `FINAL` is not allowed as a
sub-rule.

The real cost is not parsing: it is that `RuleMatcher` becomes recursive, the
first-match contract has to stay provably intact, and `RulesEditorView` needs a
shape for a tree where it currently assumes a row.

### 10. `pre-matching`: reject at the DNS and handshake stage

Surge evaluates `REJECT`-policy rules tagged `pre-matching` before the connection
exists — at the DNS query and the TCP handshake — so unwanted traffic is dropped
at the cheapest possible moment. We have a resolver of our own
(`SystemDNSResolver` with a positive/negative TTL cache), which is the part that
would need intercepting.

Without fake-IP or a packet layer (idea 16), the DNS half is available and the
handshake half mostly is not: we only see a connection once an application has
chosen to send it through our proxy port. So this is worth doing for the DNS
half, and worth *knowing* that the rest waits for idea 16.

### 11. A Surge-profile compatibility report

A real Surge profile loads today, and that is the problem. Unknown sections
(`[MITM]`, `[Script]`, `[Host]`) produce "contents ignored" warnings; an unknown
rule type or a `GEOIP` line produces a line-numbered diagnostic; a proxy whose
type is not `http`, `https` or `socks5` is rejected by name. Every one of those
is a *routing* difference, and each looks like something a person scrolls past.

The idea: make importing a foreign profile a first-class action that ends in a
report — "these 412 lines do what you think, these 6 do not, here is what each
one would have done" — instead of a diagnostics list nobody reads. It is the
cheapest honest answer to "can I use my Surge profile", and it also gives ideas
2–7 and 15 a place to announce themselves as they land.

### 12. DNS beyond the system resolver

We call `getaddrinfo` and cache. Surge offers upstream and encrypted DNS
(DoH/DoH3/DoQ/DoT), local `[Host]` mapping, and fake-IP. The consequences of not
having it are concrete: `[Host]` mappings in an imported profile are dropped,
there is no way to answer a name locally, IP-based rules always need a real
lookup, and nothing can be blocked at the DNS stage (idea 10).

This is a large piece of work with a real risk of being worse than the system
resolver for ordinary use. It is also the prerequisite for the interesting half
of ideas 10 and 16, which is the argument for doing it or for closing the door
deliberately.

### 13. Automation: CLI, HTTP API, URL schemes

Surge has `surge-cli`, an HTTP API and URL schemes. We have none of the three
(no `CFBundleURLTypes` in `Info.plist`, no CLI in `scripts/` beyond a manual
smoke test). The useful subset for this app is small: switch profile, switch a
`select` group's choice, connect/disconnect, ask for status.

The design question is where state lives, since the engine and the policy store
currently live in the app process and a CLI would be talking to something that
may not be running. A URL scheme that a shell can open is the smallest honest
step, and it is worth doing before an API that needs a port and a trust story. The CLI's concrete shape, and the case for it
being the first of the three, is card 14.

### 14. A CLI a program can drive, not just a person

The concrete form of idea 13, and the piece most likely to be used by something
that is not a person at all: `turtlediver status --json`, `connect`,
`disconnect`, `profile use <name>`, `policy set <group> <member>`,
`rules explain <host>`, `requests --json`.

**The cheap half is genuinely cheap.** The profile parser, rule matcher and
policy resolver are Foundation-only and already build as SwiftPM libraries
(`TurtleDiverCore`, `TurtleDiverRules`), and a second executable target has
precedent — `TurtleDiverAgent` is one. So `rules explain` ("which rule would
match this host, and which policy does it resolve to?"), `profile validate` and
the tool doctor are pure functions over a profile file: no daemon, no privilege,
no network, no window. They are also the questions an agent gets wrong most
often when left to infer routing from a config file, and our answers are
deterministic.

**The expensive half is state.** Connect and disconnect have to reach a running
process, and that state lives in the app today: an XPC or unix-socket channel to
the running app, or the CLI driving the privileged agent directly (it is already
a root-owned binary with a line protocol). A third option — the CLI growing its
own engine — is worth refusing early, because two engines would both own the
system-proxy snapshot and fight over restoring it.

**Two traps, both already paid for once.**

- **Elevation.** Connecting needs a privilege decision (the agent path, or Touch
  ID / a sudo wrapper). A CLI may be run with nobody at the keyboard — over SSH,
  or in a loop — so it must be able to say "a human has to approve this" as a
  distinct, documented exit code rather than as a timeout. A program can act on
  an exit code; it cannot act on a dialog.
- **The orphan.** A CLI killed mid-connect (agent timeout, Ctrl-C, `kill -9`)
  must not leave a root `openconnect` and its `sudo` behind. That is precisely
  the 2.1.1 failure this release fixed, so the CLI needs the same ownership rule
  the app now has: the tunnel's life is tied to the CLI's, and a tunnel that
  disappears is an *ending*, not something to wait out on a clock.

For agents specifically: `disconnect` should be idempotent and report whether it
changed anything, `status --json` should carry the same diagnosis strings the
History rows carry so a caller can react to a reason instead of parsing prose,
and every read-only command should need no privilege at all. What must **not** be
exposed: profile credentials live in the Keychain, so `profile show` prints the
reference and never the secret — and `requests --json` is a list of the user's
hosts, which is exactly the data the privacy guard exists to keep out of the
repository, so it should never default to writing a file.

Depends on: idea 13 for where state lives, and idea 18 for anything that drives
the helper.

**Picked up.** Shipped as the `turtlediver` command: `docs/CLI.md` is the
contract, `CLI/` is the code and `Tests/TurtleDiverCLITests` is what pins it.
Both traps were answered rather than avoided — the orphan by the agent's own
rule that a closed standard input ends the tunnel (so `connect` is foreground
and blocking), and elevation by `sudo`'s own prompt plus exit code 6 when there
is no terminal. The state question in idea 13 turned out to need no channel to
the app at all: a pid file and the agent's line protocol were already enough, so
the CLI works with the app closed. Elevation got its own two answers later:
`--sudo-password keychain|stdin` for a caller with no terminal, never quietly
replaced by another door; and, for a connect with nobody at the machine, a
sudoers exemption naming the installed agent — detected with `sudo -n -l`, after
which the refresh and the password read are both skipped. The `pam_tid` refusal
that first shipped with the option was **wrong** and has been retired: `pam_tid`
closes the pipe, not the door, and stands its own dialog down in askpass mode, so
the same `keychain` source is delivered through `sudo -A` and
`/usr/local/bin/turtlediver-askpass` — the CLI binary under a second name, so the
Keychain grant belongs to one revocable program instead of `/usr/bin/security`.
Only `stdin` is still refused there (exit 6, pointing at the keychain source),
and a missing helper is exit 7 naming its path. The route was then walked for
real on a machine whose `pam_tid` answers first: a `connect --sudo-password
keychain` with nobody at the keyboard reached a live tunnel and printed its one
JSON document, and `disconnect --sudo-password keychain` took it down through the
same helper, both exit 0.

(2026-09-23) The app got the same door on its own terms: it builds a helper into
its own bundle (a nested Xcode target, so the signature survives — §11 of
`docs/ELEVATION.md`), and Settings ▸ VPN gains **Unattended elevation ▸
Prepare…**, which runs that helper once so macOS asks about it while the user is
looking, then records its designated requirement. A connect uses it only while
that record still matches the helper in the bundle, so an ad-hoc rebuild asks to
be prepared again instead of hanging on a dialog nobody expected. The two copies
obey one protocol (`AskpassProgram`, `StoredSecret`); the CLI's stays
`/usr/local/bin/turtlediver-askpass`, because the Keychain grant belongs to the
program and a user who installed only the app has no CLI copy to point at.
What has **not** been picked up
from this card: `profile use`, `policy set` and `requests --json` are absent,
because they are writes and the CLI is deliberately read-only apart from the
tunnel.

### 15. Outbound protocol breadth

We speak HTTP and SOCKS5 upstream. `https` is accepted as a proxy type by the
profile parser and then refuses at relay time (`tlsUpstreamUnsupported`), so it is
declared but not spoken — a small fix of its own, worth folding in before any of
the below. Surge adds Shadowsocks, Snell, VMess,
Trojan, TUIC, Hysteria 2, AnyTLS, SSH, WireGuard and Tailscale. Each one is a
project in itself (framing, crypto, replay protection, a test story that does not
depend on a live server), and the app's own purpose — an `openconnect` VPN with a
rule engine in front of it — means the realistic demand is near zero. Listed so
that the answer to "why not X" is written down rather than rediscovered.

## Shape of the product

### 16. Enhanced Mode: capture at the packet layer

Surge's virtual interface takes over traffic; ours is a system proxy, so only
applications that honour the system proxy are routed at all. This is the largest
gap on this list and the reason the cards above keep pointing forward to it:
fake-IP, DNS-stage rejection, per-process accuracy for apps that ignore proxies,
and honest `SUBNET`/`DEVICE-NAME` behaviour all sit behind this.

It is also a different product shape: a NetworkExtension or a privileged helper,
signing and entitlements, and a much larger blast radius than a proxy port. It
has been proposed before and never decided, which is not a state worth staying
in: worth its own written decision either way, because a great deal of "why not
parity" resolves to this one card.

### 21. Route another device's network through the engine

A phone, tablet or second laptop points at this machine and its traffic leaves
through the tunnel the Mac already holds. The use case that made me write it
down: a phone uses the VPN the Mac is connected to, without a profile, a
certificate or a password ever being installed on the phone. The phone does not
know a VPN exists; it just reaches the internet through a host that does.

**The cheap half is genuinely cheap, and for the same reason idea 14 is.** The
engine already is what the phone needs: an HTTP listener on `127.0.0.1:6152` and
a SOCKS5 listener on `127.0.0.1:6153` with the whole rule engine behind them. Bind
the same listeners on one LAN address, print that address and the port in the
window, and a device on the same network can set a manual proxy and be routed.
No new protocol, no packet layer, no DHCP. iOS honours a Wi-Fi HTTP proxy for
anything using `NSURLSession`; Android does the same per network.

**What that costs, in the order it bites:**

- **Auth.** A loopback listener trusts every caller because only this machine can
  reach it. A LAN listener has to not. SOCKS5 already has a username/password
  method in the grammar and the listener is hand-written, but the HTTP listener
  has no proxy-auth path at all, and credentials need somewhere to live that is
  not the profile file.
- **It serves traffic, not just routes it.** The request detail the app keeps
  (host, SNI, ALPN, sizes) suddenly describes a second device's browsing. That is
  the data `RepoPrivacyGuardTests` exists to keep out of the tree, and it is now
  the host's job to decide who can read it in the window.
- **Local Network permission.** macOS asks before an app binds or is reachable on
  the LAN; a first-run prompt at connect time is a worse place for it than Setup.
- **Partial coverage, and it will be read as full.** A manual proxy routes what
  honours the proxy. Games and some apps do not, and nothing in the UI today can
  say "this device is only partly routed" without inventing per-client state.

**The expensive half is the honest version of the same thing.** Full routing for
one device means the Mac forwarding packets for it — IP forwarding, NAT, and the
same elevated helper territory as idea 16 — or a tunnel the device joins (a
WireGuard/"connect to my Mac" endpoint), which is a different product with a key
management story. Both are the packet layer again. Worth refusing early: an
iOS/Android app for this, since the entire point is that nothing gets installed
on the phone.

**It collides with a written anti-goal, and that is the real first step.**
"Gateway mode, DHCP, Surge Ponte, built-in servers ... This app serves the machine
it runs on" is in *Out of reach* below. This card is a deliberate proposal to
narrow that line — one device, a proxy, an explicit switch — rather than to move
it, but the anti-goal has to be amended in the same commit or the next person
will correctly read this idea as closed.

Depends on: a decision about the anti-goal, then the auth and Local Network
questions. The binding itself is small.

## Out of reach, and why

Not ideas — anti-goals, recorded so nobody re-proposes them expecting a surprise.

- **MITM, URL/header/body rewrite, capture and replay.** Decrypting other
  people's traffic is a different product with a different threat model. This app
  is used against a VPN whose whole point is that the traffic is private. The
  request detail we do keep (host, SNI, ALPN, TLS version, sizes, timing) is the
  deliberate limit.
- **Scripting.** Surge embeds JavaScript for rules, rewrites, DNS and cron. Our
  rule of thumb has been to stay dependency-free — the PAC importer was built
  without JavaScriptCore on purpose — and a script engine is also a permanent
  security surface in a process holding credentials.
- **Gateway mode, DHCP, Surge Ponte, built-in servers.** These serve other
  devices on the network. This app serves the machine it runs on. (Idea 21 asks
  to narrow this to "one device, over a proxy we already run" — the difference is
  deliberate and not yet decided.)
- **`DEVICE-NAME`, `MAC-ADDRESS`, `CELLULAR-RADIO`, `CELLULAR-CARRIER` rules.**
  The first two describe a client that is not this machine (gateway mode); the
  last two do not exist on macOS.

## Found while shipping 2.1.2

Measured first, unexplained second. Each of these came out of real runs rather
than reading the code, so the context is the expensive part — keep it.

### 17. An agent the updater cannot replace

The in-app updater ships a `.dmg`: the app, and never the privileged helper. The
agent at `/usr/local/libexec/turtlediver-agent` is only ever replaced by the
package, so a machine can run a new app with an old agent, and nothing in either
one says so. 2.1.2 worked around it — the app watches its own tunnel instead of
trusting the agent to notice — but the underlying shape is still there.

Ideas, none of them obviously right:

- The app compares the installed agent against itself at launch and says
  something in Setup when they disagree, with a button that runs the installer.
  Needs an agent version or protocol number to compare, which the protocol
  deliberately does not have today (see idea 18).
- Ship the agent inside the app bundle and install it with one elevation on the
  next connect after an update. Fewer moving parts for the user, but it makes a
  single elevation prompt do two jobs, and the agent would then live in two
  places.
- Have the agent answer with a protocol version on its first line, so an old one
  is *detected* rather than guessed at, and the app can refuse it by name.

Constraints to respect, from `docs/ELEVATION.md` and `docs/UPDATES.md`: nothing
is installed while the tunnel is up, nothing is elevated silently, and an update
a user did not ask for is worse than an old helper.

### 18. Liveness without shelling out to `ps`

The app decides "the tunnel is gone" by running `ps` on a pid it recorded, every
3 s while connecting, because an old agent cannot say what happened to its child.
A newer agent does say (`done`, and a reason), so this is really a fallback that
existed before the fix and now only covers old helpers.

A better contract might be the agent talking instead of the app probing: a
heartbeat line, or the app reading the child directly. The rule that must survive
any replacement, and is worth keeping written down: a zombie answers
`kill(pid, 0)` as *alive* while `ps -o comm=` reports `<defunct>`, so liveness is
a question about a **name**, never a signal. That is `docs/ELEVATION.md` § 10.

### 19. A root `sudo` that waits through part of every connect

During the live pass for 2.1.2, a `sudo` process owned by root was visible for
about half a minute during a normal connect and then exited by itself. Nothing
was left behind — not after a disconnect, and not after a failed connect — so it
is not the orphan this codebase has fought twice. But nobody has explained what
it is waiting for.

Worth an hour with the process table and the app's own log side by side. If it is
a prompt waiting on nothing, that is a root process alive for a fraction of every
connect; if it is the elevated setup doing slow work, it is worth a line of
comment saying so.

### 20. Notarization

`publish.sh` refuses to build release artifacts without a Developer ID
certificate, so 2.1.2 went out through `--local` and anyone downloading it needs
right-click ▸ Open. One-time cost: Apple Developer Program enrolment, two
certificates (Application and Installer), one `notarytool store-credentials`.
Steps are in `docs/DISTRIBUTION.md`.

Worth deciding at the same time: whether a non-notarized artifact should be
something `publish.sh` can produce without being asked for it explicitly. It is a
deliberate `--local` today, and the release that carries it says so — but
nothing stops the next person from publishing one by accident.

## Unsorted

- (nothing yet)

## Picked up

- **14. A CLI a program can drive, not just a person** — the `turtlediver`
  command, installed by the installer package alongside the app.
  `docs/CLI.md` is the contract; `CLI/Kit` is the logic and
  `Tests/TurtleDiverCLITests` is what pins it. Delivered: `status`, `rules
  explain`, `profile list`/`validate`, `version`, and a foreground `connect` /
  idempotent `disconnect`. Not delivered, and deliberately: the write commands
  (`profile use`, `policy set`) and `requests --json` (a list of the user's
  hosts). The reasoning that changed between the card and the commit is in the
  card, above.

## Dropped

- (nothing yet) — an idea that leaves gets one line here saying why, so the same
  ground is not re-covered in six months.
