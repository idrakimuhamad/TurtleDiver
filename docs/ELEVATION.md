# Elevation: how TurtleDiver asks for privilege, and how it stops waiting for it

Two things the app does need root for:

- **openconnect** — creating the TUN device and rewriting routes and DNS.
- **vpn-slice's `/etc/hosts` entries** — added while connected, removed on the
  way out.

Both go through `sudo`, with the administrator password read from the Keychain
and written to the child's **standard input**. The script that runs is a
constant; credentials are never part of an argument list (see the README's
security notes, and `docs/PROXY_ENGINE.md` for the tests that pin it).

The system proxy is a *second*, separate elevation path: `SystemProxyManager`
drives `/usr/sbin/networksetup`, which authenticates through **Authorization
Services**, not PAM. It gets its own section below.

## What went wrong

The connect path warmed `sudo`'s timestamp with `sudo -S -v`, piping the stored
administrator password into it. On a Mac where `/etc/pam.d/sudo_local` enables
`pam_tid`, sudo offers the authentication to **Touch ID first** — the module
answers before sudo ever reads the pipe, the password stays unread, and sudo
sits on a dialog. Nothing in the app was watching for that:

- the 90 s connect timer killed openconnect (there was none) and then
  `proc.terminate()`d the **bash wrapper** (which was not the process holding
  the dialog);
- the blocked `sudo` was reparented to `launchd` and stayed there.

Measured on this machine, before the fix:

- `pgrep -x sudo` → a single root-owned `sudo`, **ppid 1** (reparented),
  elapsed **36:51**, with no `openconnect` process anywhere.
- `kill -TERM` and `kill -9` against that pid were both **denied** — a non-root
  sender may not signal a root-owned process, and the app is a non-root sender.
  That `errno` means "not yours", not "does not exist": the app cannot reap the
  orphan, and nothing here claims otherwise. It later exited on its own.
- The old `/etc/hosts` cleanup ran the same risk from the other direction: it
  piped the password into `sudo -S` and then `waitUntilExit()` with no deadline,
  so a quit could hang too.
- `NetworkSetupRunner.run` had the same shape: a `DispatchSemaphore.wait()` with
  **no timeout** behind `networksetup`, which can raise a GUI authorization
  dialog of its own.

Waiting longer and killing harder cannot fix any of that. Not creating the
orphan can.

## What the app does now

### 1. Decide before launching

`ElevationProbe.live` reads two **world-readable** files — `/etc/pam.d/sudo_local`
and `/etc/pam.d/sudo` — and asks `sudo` nothing at all (the reason is §1a). From
what the PAM stack says it picks one of three strategies:

| Strategy | When | Refresh step | Who supplies the password |
|---|---|---|---|
| `.systemPrompt` | `pam_tid` answers `auth` | `sudo -n -v`; if that is refused, `sudo -v </dev/null` | the **system's own dialog**, which the user sees and answers |
| `.storedPassword` | nothing else can answer | `sudo -n -v`; if that is refused, `printf '%s\n' "$oc_admin" \| sudo -S -v` | the stored password, down the pipe |
| `.neverPrompt` | never chosen by a connect | `sudo -n -v`; a failure writes a marker and exits | nobody — `-n` cannot prompt |

Only `.storedPassword` writes the administrator password anywhere. The app also
only *requires* a stored password in that mode — with Touch ID answering, the
connect no longer asks for a credential it would not use.

`.neverPrompt` is not a connect strategy and `resolve(mode:)` cannot return it.
It is the **silent first attempt** of the elevated-kill path (§6), where the
whole point is that nothing may be asked, and it is why the case still exists
after the fix below removed its last use in a connect.

`.systemPrompt` is announced up front, in the log, before the launch:

    Elevation: Touch ID for sudo is enabled (pam_tid).
    Elevation: the refresh checks sudo non-interactively first; if that is refused, macOS asks for Touch ID or your administrator password, and the connect waits up to 90s for that dialog.

The launch itself never gets `-S`, in any mode. Its stdin carries openconnect's
PIN and account password, and an `-S` that decided it needed a password would
consume the PIN as its own and hand openconnect half a credential.

The CLI in `docs/CLI.md` reaches the same two refresh steps from its own side,
and the same rule holds there: `--sudo-password` runs `sudo -S -v` as a child of
the CLI, never on the agent's pipe, whose standard input carries the tunnel's
credentials. It also inherits this file's reason for existing: where `pam_tid`
answers `auth` ahead of the password module the pipe is never read, so the CLI
refuses a supplied password outright (exit 6, nothing started) instead of
raising the dialog the caller asked to avoid and blaming the password for the
timeout it then waited out.

That refusal has one exception, and it is the CLI's alone: a machine whose
`/etc/sudoers.d` exempts the installed agent from authentication
(`Defaults!/usr/local/libexec/turtlediver-agent !authenticate`) needs no refresh
of any kind. The CLI asks `sudo -n -l <agent>` — policy, not authentication —
skips the refresh when the answer is yes, and never reads a password it would not
use; `docs/CLI.md` §"Unattended connects" has the rule and what it costs. The
app cannot use that trick, which is why this section still governs it: its plan
runs several different `sudo` commands from one generated script, so no single
command can be named to `sudoers` — only the shell, which would exempt
everything.

### 1a. The timestamp the app cannot measure

The first version of this decision had a third input: the app ran `sudo -n -v`
itself, bounded at 3 s, and on a warm answer chose `.neverPrompt` — skipping the
refresh entirely, since the timestamp was, by that measurement, already valid.

It was wrong, and it failed in the worst way: silently, on a connect the app had
just measured as warm.

`sudo` keys its credential timestamp to the **parent process** when there is no
terminal. From `man sudoers` on this machine (sudo 1.9.17p2):

> `timestamp_type` … If no terminal is present, the behavior is the same as
> `ppid`. … Commands run via sudo with a different parent process ID … will be
> authenticated separately.

The app's probe is a child of the app. The connect's `sudo` is a child of the
wrapper shell the plan runs in. Those are different parents, so they are
different timestamp records, and the app's answer never applied to the plan's
`sudo`. On a Mac with `pam_tid` the plan then found a cold timestamp, exited with
its marker, and the connect ended as `Failed - Elevation Expired` — a message
about a timestamp the app had *just* verified as warm.

Measured live, same machine, same tunnel, minutes apart, with only the strategy
differing:

| Connect | Plan | Outcome |
|---|---|---|
| 04:38:49Z | `.warmTimestamp` (the probe said warm) | `Failed - Elevation Expired` |
| 04:55:32Z | `.systemPrompt` | connected |

The fix is to delete the capability rather than the case: `SudoProbe`,
`ElevationSnapshot.timestampWarm` and the `timestampWarm:` parameter of
`resolve` are gone, and warmth is only ever probed **inside the plan**, where the
answer is used.

Two consequences worth knowing:

- The stale `/etc/hosts` cleanup used to run from the app, before the plan, with
the same probe-derived strategy — so on a `pam_tid` machine it always failed,
and the connection log carried `Failed to clean /etc/hosts: sudo: a password is
required` on *successful* connects. It is now a step of the plan itself, which
inherits the refresh above it and therefore runs `sudo` in the context that just
authenticated. There is one cleanup path, and it is that one; the app-side
`cleanupVpnSliceHosts()` and the standalone `hostsCleanupPlan` are gone.
- The `/etc/hosts` bound in §5's table went with it. The plan's own `sudo -n -v`
is bounded by the connect's 90 s, like every other step of the plan.

### 1b. The door `pam_tid` does not close: askpass

§1's table has `.systemPrompt` as the only strategy for a `pam_tid` machine, and
for a long time the note beside it said the same thing two ways: with Touch ID
answering `auth`, nothing else can authenticate `sudo` for an unattended caller —
a piped password is never read, so the way past is a person or a sudoers
exemption. The first half of that is true. The conclusion was wrong.

`pam_tid` closes the **pipe**, not the door. Its own strings say what it does with
the other one:

```console
$ strings /usr/lib/pam/pam_tid.so.2 | grep -i askpass
askpass-enabled
sudo askpass mode, not showing UI
```

`sudo -A` is that mode. Instead of prompting, `sudo` runs the program named by
`SUDO_ASKPASS` **as the invoking user** and reads the password from its standard
output, and `pam_tid` sees askpass mode and stands its dialog down. Measured on
this Mac against a helper that reads the app's own Keychain item:

| Command | Result |
|---|---|
| `SUDO_ASKPASS=<helper> sudo -A -v` | exit 0 in well under a second — no dialog, no Touch ID, no output |
| `SUDO_ASKPASS=<helper-that-prints-nothing> sudo -A -v` | exit 1, `sudo: no password was provided`, and still no dialog |
| `sudo -A -v; sudo -n true` in the same parent | both exit 0 — the timestamp is warm for that parent, exactly as §1a requires |

So there is a third way for an unattended caller, and unlike the two recipes this
document has always carried, it changes nothing about how the machine
authenticates anything: hand `sudo` a program that prints the stored password and
`sudo` never asks. The CLI does exactly that (`docs/CLI.md`, "Unattended
connects"), with the helper being its own binary under a second installed name:
the Keychain grant then belongs to one named, revocable program rather than to
`/usr/bin/security`, which any process running as this user could call.

Two things stay true and are worth not forgetting:

* the pipe really is dead on such a machine. `sudo -S` raises the module's own
dialog with the pipe still full, so `--sudo-password stdin` is refused there
rather than left to wait — the CLI's own rule that a named source which cannot
deliver is never quietly replaced.
* this is `pam_tid`'s behaviour, not a documented contract of `sudo`, so it is
evidence rather than a guarantee. It was measured on this machine's version; a
cheap probe after a macOS update is `SUDO_ASKPASS=/usr/bin/false sudo -A -v`,
and a dialog appearing means the door has closed again.

**The app uses the same door, with a helper of its own** (§11).
`OpenConnectCommand.launchPlan` takes an optional helper path, and when it is
given — and only where the strategy is one that would otherwise ask — every
privileged step in the plan becomes `sudo -A`, with `SUDO_ASKPASS` exported ahead
of the first one, the timestamp refresh included. The password stays out of the
script, out of argv and out of the pipe: openconnect still receives exactly its
PIN and account password. Where the pipe *is* read the helper is ignored rather
than used, because that mode already names its own door, and one function —
`SudoPasswordDelivery.resolve(strategy:askpassHelper:)` — decides which of the
two a connect is in, so the app and the command line cannot answer differently.
Without a helper the plan is what it always was: a dialog a person answers, and
the status that says so if nobody does.

### 2. Fail loud, and name the cause

The script writes one line to stderr before it exits, and the app matches that
line by **exact trimmed equality** — never `contains`, because three of the four
markers mention `sudo` and openconnect's own output must not be able to pass for
one. Each marker is `turtlediver: elevation ` followed by the reason, and maps to
its own status:

| Marker reason | Status shown |
|---|---|
| `sudo timestamp expired before openconnect could use it` | `Failed - Elevation Expired` |
| `the system Touch ID or password dialog was not answered` | `Failed - Elevation Blocked (Touch ID)` |
| `sudo could not authenticate with the stored administrator password` | `Failed - Admin Password` |
| `the askpass helper did not supply an administrator password` | `Failed - Admin Password` |

The two password failures share a status on purpose: the remedy is the same
sentence, and the log line above it already says which door was tried. Their
details differ, and a test pins that the statuses are otherwise one per reason.

The status reaches the log, the status hero and History, and each carries a
one-line remedy. A 90 s timeout with a system dialog pending is classified the
same way rather than reported as a bare `Connection timeout`.

### 3. Never create the orphan

The privileged body runs in **its own process group**. The wrapper does

    set -m; { set +m; <body>; } & job=$!; set +m; ps -o pgid= -p "$job" … > run/elevation.pgid; wait "$job"

and the group id is recorded in
`~/Library/Application Support/TurtleDiver/run/elevation.pgid`. Teardown — the
timeout, an explicit disconnect, and quitting — signals **that group**, so the
subshell and anything else this user owns goes with it.

`killpg` is honest about its limits: it reaches every member the sender may
signal and silently skips the rest, so a root-owned `sudo`/`openconnect` in the
group survives. That is exactly why the fix is to stop creating the situation.
(Ending a tunnel the group could not reach is a separate path — see §6.)
`killpg(pgid, 0)` answers success while *any* member is still signalable, so a
surviving group is not read as proof that everything in it died, and a group
that is left alive keeps its record (see below). `setsid` does not exist on
macOS and Foundation exposes no way to set a process group from the parent, so
`set -m` plus a backgrounded subshell is the dependency-free route; `set +m` is
placed immediately after `$!` because bash otherwise prints a job-status notice
to stderr — which would have landed in the connect log.

### 4. Sweep at launch, carefully

`ElevationReaper` runs once per launch (Step 0c in `launch.log`), off the main
thread. It reaps the recorded group **only** when the record is not this
process's own group, there is no live PID in the pid file, and no group member
is an `openconnect`. A group that is left alive **keeps its record**, because
the record is the only remaining handle on it. Anything the app cannot reap is
reported rather than pretended away.

### 5. Every wait is bounded

| Wait | Bound | On expiry |
|---|---|---|
| connect stays `.connecting` | 90 s | terminate, classify, report |
| every step of the plan (`sudo -n -v`, the cleanup, the launch) | the 90 s connect bound | terminate, classify, report |
| the recorded group after teardown | 0.5 s | escalate to SIGKILL |
| `ps -o comm= -g` in the sweep | 3 s | treat the group as unknown |
| `ps -o etime=` reading an adopted tunnel's start time | 3 s | no duration: it counts from the adoption |
| `networksetup` (system proxy) | 60 s + 2 s grace | terminate, then SIGKILL, then `authorizationTimedOut` |
| `ps -o user=` reading a pid's owner | 3 s | the owner is unknown, so the user-level path is tried |
| elevated `sudo … kill` | 20 s | terminate the `sudo`, then SIGKILL it, and report the failure |

That last `ps` read is not an elevation wait; it is here because this table is
where the bounds live. It runs on the main thread while a tunnel is being
adopted, so it is bounded like the rest. It also asks for the *elapsed* field
rather than `lstart`, because `lstart` is a formatted date: its day and month
names come from `LC_TIME`, and under `LC_ALL=de_DE.UTF-8` it answers
`Mi. 16 Sep. 19:34:34 2026`, which a fixed-format parser cannot read however it
pins its own locale. The elapsed field is digits, colons and at most one dash.

That read is only half of the duration, though, and for a while the other half
was wrong in a way the bound could not reveal. The reader returned the right
instant — an adopted tunnel's history row carried the tunnel's true start time —
but the duration timer's first statement, inside a
`DispatchQueue.main.async` block one runloop later, overwrote
`connectionStartTime` with `Date()`. So the pill always counted from the
adoption while the history row counted from the process, and the two records
disagreed by however long the tunnel had already been up. The timer now takes
the start instant as a parameter, so each caller states which one it means and
nothing recomputes it; the adopter feeds both the timer and the history row from
one local.

### 6. End a tunnel this user cannot signal

A tunnel the app raised through `sudo` is **root-owned**. Every signal this user
sends it is refused with `EPERM` — for `SIGTERM` and for `SIGKILL` alike — so for
a while Disconnect and the quit both reported a disconnect that had not happened
and left the tunnel up. Three things were wrong, and they compounded:

1. `disconnect()` wrote `status = .disconnected` and a `"Disconnected"` history
   row *unconditionally*, after a signal the kernel had refused. A live tunnel
   was reported as a finished one, on screen and in the record.
2. Neither path had any way to reach a root-owned process, so the report was not
   merely early — it was unachievable.
3. A quit-time comment claimed the launch sweep would reap the group instead.
   It will not: `ElevationSweep.decide` returns `.leaveAlive` for a group that
   still holds an `openconnect`, deliberately. The record is a **handle** on such
   a tunnel, never the thing that ends it.

Ending it needs root, and the app already knows how to get root: the same
`ElevationStrategy` the connect used. `ElevatedTerminator` routes that decision
through the *verifying* terminator, so every call site is fixed at once:

- **Verify first.** A pid is only ever signalled after `OpenConnectProcess`
  says it is an `openconnect` and is still running. A stale or recycled pid in
  the pid file cannot become a root signal.
- **Read the owner before spending the timeout.** `ps -o user=` (bounded) names
  the owning user; a different name means `EPERM` is certain, so the app goes
  straight to the elevated form instead of waiting three seconds to learn
  nothing.
- **`sudo -n` is always tried first.** It never prompts and fails in
  milliseconds when the timestamp is cold — which, on a `pam_tid` machine, is the
  normal case for a `sudo` whose parent is the app (see §1a). The stronger forms
  are only *sent* while the process is still there: `send` stops at the first
  plan that works, so a password or a dialog is never spent on a process that is
  already gone.
- **A group is only signalled as root while `ps -o pid= -g <pgid>` still lists
  the verified `openconnect`.** Pids and groups are recycled, and
  `run/elevation.pgid` may hold a group from a previous run.
- **`mayPrompt` is a parameter with no default**, so every call site has to say
  which path it is. `disconnect()` and the pre-connect cleanup may raise the
  system dialog, because a person is there and asked. `cleanupOnTermination()`
  and `forceTerminate()` may not: a dialog nothing answers is what held a quit
  open and left a blocked `sudo` behind — the original defect in §2.
- **The verdict is the liveness check, never `sudo`'s exit status.** A `sudo`
  that exits 0 having killed nothing is a failure, and a signal that was accepted
  and ignored is a failure too. The outcome has five cases and every `switch`
  handles all five, so `endedWithElevation` cannot be forgotten.
- **A failed disconnect says so.** The status stays `.connected` (`.error` would
  rename the hero button *Reconnect* and invite a second tunnel on top of the one
  that is still running), the history row reads `Failed - Still Connected`, and
  the pid record is kept — it is how a retry finds the process again.

That last point is the one the user saw: "press Disconnect → the tunnel ends" is
the promise, and a report that outruns the effect breaks it. What the app can
guarantee is narrower and honest: **Disconnect ends the tunnel whenever the
signal can be delivered, asks for the privilege when it cannot, and reports
`Still Connected` when even that did not take.**

### 7. A test never adopts the machine's own tunnel

Adoption is not a read. It records the pid in `run/openconnect.pid`, publishes
`.connected` and writes a history row — all of them the *user's* state. Creating
`VPNManager.shared` is what performs it, so any test that reached the manager
adopted whatever `openconnect` happened to be running on the machine: the app
suite wrote the user's real pid file, and the rule-set tests took a different
path depending on whether a tunnel was up.

Two guards, one at each end:

| Guard | Where | What it stops |
|---|---|---|
| `VPNManager.adoptsExistingConnectionsAtLaunch` | `VPNManager.init` | a test host (XCTest's `XCTestConfigurationFilePath`, or XCTest itself loaded) never adopts |
| `TunnelStatusSource` | `EngineController.init` | the controller reads an injected tunnel, so building one never creates the manager |

`LiveTunnelStatus` is the app's wiring, and it touches the manager only when one
of its members is used — so taking the default is not the same as creating the
manager. Test call sites pass `StubTunnelStatus`, and
`TunnelAdoptionHygieneTests` fails if one of them goes back to the default.

### 8. A tunnel is resolved before it is signalled

The pid record is a convenience, not the truth. For a while the teardown read it
as one: `tunnelEnded` started `true` and only a *record* could make it false — so
a tunnel this app had started, with no record on disk because it wrote none until
it adopted something, was reported `Disconnected` while a root-owned
`openconnect` was still running. That is the mirror image of the fabricated
`Connected` state, and just as bad: the app had no handle it trusted, so it said
the work was done.

Three things changed:

- **The record is written when a tunnel starts**, not only when one is adopted.
  The process-list poller and the output sniffer both call the same single writer,
  and only after the pid has been verified to be an `openconnect` (`record`
  itself refuses a pid of 1 or less).
- **The teardown resolves the tunnel instead of trusting the record.** It asks,
  in order: the pid file; **the process group this app recorded when it elevated**
  (`run/elevation.pgid`); and the machine-wide name scan. The order is asserted
  rather than incidental —
  `ExistingConnectionTests.testThisAppsOwnGroupWinsOverTheMachineWideScan` fails
  if the scan is consulted first. The group tier reports no rejections: a group of
  wrapper processes is not evidence of a bad record, and saying so would fill the
  log with noise at every teardown.
- **"No record" is never "no tunnel".** It means "a tunnel this run cannot
  name", and the resolution continues from there.

A group that still holds an `openconnect` is left alone by the launch sweep for
the same reason — the group is a *handle*, and ending what is inside it is the
live teardown's job, not the sweep's. The sweep reaps the group only once nothing
in it is an openconnect.

The live proof is in the history row rather than in the code: with
`run/openconnect.pid` deleted while a root-owned tunnel was up, pressing
**Disconnect** ended the tunnel and the row read
`openconnect (PID: …) ended with elevation`, `network restored`, then
`reaping stale process group …` for the now-empty group.

### 9. A failed connect is not a dead end

The state a failure leaves behind has to be a state a retry can start from.

`MainView` labels its action button **Reconnect** in the `.error` state, and
`AppDelegate`'s menu bar item offered the same — but `connect()` opened with
`guard case .disconnected = status else { return }`. From `.error` that guard
returned **silently**: no log line, no history row, nothing on screen. One failed
connect therefore wedged the app until it was quit and relaunched, and the button
that promised otherwise did nothing at all.

The fix is a single derived rule — `VPNStatus.isConnectable`, true for
`.disconnected` and `.error` — used by `connect()`'s guard and by the menu bar
item, with the window's tappable branch asserting the same set. `.error` is not a
terminal state; a UI affordance backed by a guard mismatch is a defect, not a UX
quirk.

### 10. A tunnel that is gone is a tunnel that ends

The supervisor has to notice its child dying, and the app has to notice even if
the supervisor does not.

`openconnect` can fail before a tunnel exists — a handshake refused, a gateway
unreachable — and exit within seconds. That is the ordinary case, and on the
agent path it used to be silent. The agent's command-reading thread was blocked
in `read()` on the credentials pipe and nothing else watched the child, so the
exit went unseen: the agent and its `sudo` stayed alive supervising a tunnel that
was gone, the app saw no protocol word and no exit, and the only thing that ended
the attempt was the 90-second connect timeout — which then reported
`Failed - Connection timeout`. The cause had been in the tunnel's own output the
whole time. Nothing was reported to the history either, so a failure left a row
that explained nothing.

Three things changed:

- **The agent watches its child.** `TunnelAgentLoop` installs a
  `DispatchSourceProcess` on the pid it has just started — and holds it, because
  an unretained source is cancelled and never fires — so the exit arrives as a
  signal instead of being polled for. The word it writes says which ending it
  was: `stopped N` only for a stop the app asked for, `done` for a tunnel that
  ended by itself. The watch is cancelled before a requested stop, so one ending
  cannot start a second.
- **The tunnel's last line is kept, not only the successes.** The classifier is
  still the only success test, but the line is recorded before it, and only from
  the tunnel's own `STDERR` — the agent's protocol words (`done`) name no cause.
- **The app watches too, and does not depend on the agent's version.** The
  in-app updater ships a `.dmg`: the app, not the privileged agent. An agent an
  older package installed keeps its older behaviour, so the app also checks the
  pid it recorded itself, every few seconds *while still connecting*, and ends a
  tunnel that is no longer there. It checks by name (`isOpenConnect`), never by
  `kill(pid, 0)`: a died tunnel is not always a gone one, and an openconnect
  whose parent has not reaped it is a zombie that answers `kill` as alive while
  `ps -o comm=` reports it as `<defunct>` (measured on this machine). Only a pid
  the attempt *saw alive* counts — an empty or leftover record is not evidence
  that anything died.

Both paths produce the same name, `Failed - Tunnel Ended`, with the tunnel's own
last line behind it, and the attempt is recorded either way.

### 11. Why the askpass helper may live in the bundle, and the agent may not

The app ships an executable of its own — `turtlediver-askpass`, inside
`Contents/Library/HelperTools` — while §10 keeps the tunnel agent out of the
bundle and in `/usr/local/libexec`. The two look alike and are opposites, and
the difference is which user runs them.

- **The agent runs as root.** It is started through `sudo`, so its bytes decide
  what root executes. A payload inside the app bundle sits in a directory the
  logged-in user can write to, which makes "replace a file, get root" a two-step
  operation; the package therefore installs it into a root-owned directory and
  `publish.sh` signs it under its own identifier and asserts that identifier
  afterwards.
- **The helper runs as the logged-in user.** `sudo -A` starts it as the invoking
  user and reads its standard output; it never has privilege of its own. Its
  whole capability is one Keychain item that the user's own account already owns,
  and the grant that lets it read that item is a per-program decision the user
  makes once. There is nothing for it to escalate to.

It has to be *this app's* copy rather than the command line tool's, because the
Keychain grant belongs to the program. A user who installed only the app has no
`/usr/local/bin/turtlediver`, and pointing at the tool's copy would raise a
second consent dialog for a program the user may not even have. Both copies obey
one protocol (`AskpassProgram`, `StoredSecret`), so "one program, two copies"
stays true of the rules even though it is not true of the bytes.

The helper is built by Xcode as a nested target of the project and placed by a
Copy Files phase with `CodeSignOnCopy`, rather than copied in by a script after
the build. That is not a preference: `publish.sh` verifies the finished bundle
with `codesign --verify --deep --strict`, and anything written into a signed
bundle afterwards breaks the seal it is checking. Built this way the helper is
signed by the same identity as the app, on both the local build (`Apple
Development`, ad-hoc team) and a Developer ID release, and the bundle stays
verifiable as a whole.

Two consequences worth stating plainly:

- **The consent dialog is per program, not per app.** A Developer ID release has
  a stable designated requirement (identifier plus team), so a grant the user
  gave once survives app updates. An ad-hoc development build does not: its
  requirement embeds the code hash, so every rebuild is a new program to the
  Keychain and the dialog comes back. That is a property of ad-hoc signing
  (`docs/DISTRIBUTION.md` §3), not of this design.
- **What the helper is approved as, a person can see.** `Keychain Access` names
  the program on the item's Access Control list as `turtlediver-askpass`, and
  `codesign -dv --verbose=4` on it prints the identifier and team — so the grant
  is a named, revocable thing rather than "whatever ran a script".

## Non-goals

These are deliberate and should not be "fixed" later:

- **The app never modifies `/etc/pam.d/sudo_local`** (or any PAM file). It only
  reads them. Enabling or disabling Touch ID for sudo is the user's decision,
  made with their own editor or their vendor's instructions. See
  `docs/DISTRIBUTION.md`.
- **The app never signals a process it has not verified is an `openconnect`**,
  and it never sends *root* a signal the user has not authorised. Ending a tunnel
  that root owns needs root, so the app asks for the same elevation that started
  it: `sudo -n` and a stored password are authorisation already given, and the
  system dialog is asked for at the moment the user presses *Disconnect* (or
  *Connect*). The quit path may use only the two silent forms.
- **The app never kills a root-owned `openconnect` without a graceful attempt
  first.** That process restores routes and DNS on its way out, so `SIGTERM` goes
  first and `SIGKILL` is only the escalation. If neither takes, the tunnel stays
  up and the app says `Failed - Still Connected` rather than reporting a
  disconnect that did not happen.
- **The launch cannot reap a pre-existing root-owned orphan**, and no message or
  document says it can. The sweep reaps only a group the app can signal, and it
  deliberately leaves a group that still holds an `openconnect` alone; ending
  such a tunnel is the *Disconnect* path in §6, not the sweep.
- **No silent fallback between elevation paths.** A chosen path that fails is
  reported as a failure. Falling back would re-create the hang this document is
  about.

## The privileged helper: deferred, not forgotten

A `SMAppService.daemon` helper would remove the stored administrator password
and the orphan problem entirely. It is **deferred until a Developer ID exists**,
because Apple's own SDK contract makes that a hard requirement:

- `ServiceManagement.framework/Headers/SMAppService.h` (macOS 27 SDK) states
  that *"Apps that contain LaunchDaemons must be notarized."* Notarization needs
  a Developer ID leaf certificate, which needs Apple Developer Program
  enrolment. This machine has only Apple Development leaves.
- The header also documents `.requiresApproval` as *"successfully registered,
  but the user needs to take action in System Settings"*, and
  `kSMErrorInvalidSignature` as the answer for an improperly signed app.

A throwaway spike (`/tmp/tdspike`, with the probe app it built) measured the
registration behaviour on macOS 27: every item type — including
`SMAppService.mainApp`, with a correctly signed and with a differently signed
helper — returned `SMAppServiceErrorDomain` **code 1 ("Operation not
permitted")** with status `.requiresApproval`. So EPERM at registration means
"pending approval", **not** "bad signature", and a signature check cannot be
inferred from it.

One useful finding for later: legacy `/Library/LaunchDaemons` plists *"continue
to be bootstrapped without explicit approval in System Settings"*, which makes a
root-owned helper installed once by an explicit user command or a `.pkg`
postinstall a viable no-Developer-ID design.

If the helper is ever built, these rules were agreed in advance and do not
expire:

- **No generic `runCommand`**, ever — not even for a first slice. Commands are
  constructed inside the daemon from typed fields (a fixed executable list;
  `/etc/hosts` edits as validated IP + hostname entries). No shell, and never a
  client-supplied argv.
- **Validate the connecting client's code signature in-code** (audit token, pid
  fallback), pinned to **Team ID + bundle id**, not to a certificate, so a
  renewed certificate does not invalidate the daemon.
- **The helper binary lives root-owned** (`/Library/PrivilegedHelperTools`); a
  plist pointing into the app bundle would let the logged-in user replace a
  binary that launchd runs as root.
- **One path per connect, chosen by an explicit setting**, verified with a
  bounded ping before use.

## Checking a machine by hand

    # is Touch ID answering sudo? (read-only)
    grep -n pam_tid /etc/pam.d/sudo_local

    # is sudo's timestamp warm *for this shell*? (exit 0 = yes, 1 = no)
    # Keyed to the parent process, so this answer does not transfer to another
    # process's sudo — see §1a. The app does not use this as a decision input.
    sudo -n -v; echo $?

    # what the last launch recorded
    cat ~/Library/Application\ Support/TurtleDiver/run/elevation.pgid

    # who is in that group — names only
    ps -o pid=,pgid=,comm= -g <pgid>

    # leftover privileged processes — names only, never argv
    pgrep -x sudo; pgrep -x openconnect

    # the app's own askpass helper, and what it is signed as (§11)
    ls -l /Applications/TurtleDiver.app/Contents/Library/HelperTools/
    codesign -dv --verbose=4 \
      /Applications/TurtleDiver.app/Contents/Library/HelperTools/turtlediver-askpass

Running that helper by hand is not a check worth making: under its installed
name it will try to read the administrator password and the Keychain will ask
for consent — the dialog an unattended connect has to raise, and the one a
person should answer deliberately rather than while debugging something else.
Run it under any *other* name (a copy in `/tmp`) and it refuses with a usage
sentence and `EX_USAGE` (64) instead, which is the part that costs nothing to
verify.

`~/Library/Logs/TurtleDiver/launch.log` shows the sweep (`Step 0c`) and what it
decided. `~/Library/Logs/TurtleDiver/vpn.log` shows the chosen strategy for each
connect.

`~/Library/Logs/TurtleDiver/lifecycle.log` is the one that tells a clean quit
from a skipped one, and it is the only place a quit is recorded at all:
`applicationWillTerminate` is not called for `kill`, `SIGTERM` or a crash. It is
appended to synchronously — `launch.log` writes on a queue, and at quit the
process can be gone before that queue drains — and it holds three events only:
`launch`, `will-terminate-began`, `will-terminate-ended`. So a `launch` with no
matching pair is a run that never cleaned up, and a `began` without an `ended`
is a cleanup that hung or was killed part-way. It is rotated at launch, never at
quit, and its lines are an event, a pid and a timestamp — there is no way to
write anything else into it.

The reason that file is needed at all is that the delegate method the teardown
lives in is *not* guaranteed to run. macOS can end the process without asking:
**sudden termination** kills an app it believes has nothing to lose, and
**automatic termination** kills a hidden, idle one. Both are opt-in, and until
now this app opted into both (`NSSupportsSuddenTermination` and
`NSSupportsAutomaticTermination` in `VPNConnect/Info.plist` were `true`), so a
normal quit could skip restoring the system proxy and leave it pointing at an
engine that died with the process. Measured, with both `true`: one quit logged
`Attempting sudden termination (1st attempt)` and then appDeath with **no**
will-terminate markers, while another quit of the same build ran the delegate
only because a Foundation activity happened to be alive at that moment — the
same `lifecycle.log` got a `launch` line and nothing else. Both keys are now
`false`, and `applicationDidFinishLaunching` additionally calls
`ProcessInfo.processInfo.disableSuddenTermination()`, which is never undone, so
the guarantee is enforced rather than accidental. The observable difference is
in the unified log: a quit now ends with `Termination complete. Exiting without
sudden termination.`

Prefer `pgrep -x` and `ps -o comm=`. Nothing in the current design puts a
credential in a process's argument list, and the habit is how that stays true.

One probe worth knowing about, because it is easy to read too much into:
`kill -0 <pid>` on a **root-owned** process answers `EPERM`, not success, so the
PID-file liveness check cannot see a live openconnect at all. The guard that
actually protects a running tunnel is the `ps -o comm=` member list — and if
that call fails, the failure mode is that the PID file is dropped and the next
connect falls back to the `pgrep -x openconnect` tier. It is not a way to lose a
tunnel: `killpg` still cannot signal a root process.

## What tests do not cover

- **The `.systemPrompt` path itself** — it needs a human to answer a Touch ID or
  password dialog, so the classification, the message and the timeout handling
  are unit-tested, and the live behaviour is *not* exercised. Do not read a green
  suite as proof that the dialog path was driven end to end.
- **The `networksetup` bound against the real tool** — the tests drive an
  injected executable, because they must never touch this machine's network
  settings. The 60 s value is a judgement call, not a measurement.
- **The agent binary that is installed.** The suite runs the agent it has just
  built, from `.build`. A machine keeps whatever the last package installed, and
  the in-app updater does not replace it. This is why the app does not rely on
  the agent for the liveness check in §10.
