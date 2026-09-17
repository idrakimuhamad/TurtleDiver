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
and `/etc/pam.d/sudo` — and asks `sudo -n -v` (bounded, 3 s) whether the
timestamp is already warm. From those two facts it picks one of three
strategies:

| Strategy | When | Refresh step | Who supplies the password |
|---|---|---|---|
| `.warmTimestamp` | timestamp already valid | `sudo -n -v`; a failure writes a marker and exits | nobody — `-n` cannot prompt |
| `.systemPrompt` | `pam_tid` answers `auth` | `sudo -v </dev/null` | the **system's own dialog**, which the user sees and answers |
| `.storedPassword` | nothing else can answer | `printf '%s\n' "$oc_admin" \| sudo -S -v` | the stored password, down the pipe |

Only `.storedPassword` writes the administrator password anywhere. The app also
only *requires* a stored password in that mode — with Touch ID answering, the
connect no longer asks for a credential it would not use.

`.systemPrompt` is announced up front, in the log, before the launch:

    Elevation: Touch ID for sudo is enabled (pam_tid) and sudo's timestamp is cold.
    Elevation: macOS will ask for Touch ID or your administrator password; the connect waits up to 90s for that dialog.

The launch itself never gets `-S`, in any mode. Its stdin carries openconnect's
PIN and account password, and an `-S` that decided it needed a password would
consume the PIN as its own and hand openconnect half a credential.

### 2. Fail loud, and name the cause

The script writes one line to stderr before it exits, and the app matches that
line by **exact trimmed equality** — never `contains`, because two of the three
markers mention `sudo` and openconnect's own output must not be able to pass for
one. Each marker is `turtlediver: elevation ` followed by the reason, and maps to
its own status:

| Marker reason | Status shown |
|---|---|
| `sudo timestamp expired before openconnect could use it` | `Failed - Elevation Expired` |
| `the system Touch ID or password dialog was not answered` | `Failed - Elevation Blocked (Touch ID)` |
| `sudo could not authenticate with the stored administrator password` | `Failed - Admin Password` |

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
| `sudo -n -v` probe | 3 s | treat the timestamp as cold |
| the recorded group after teardown | 0.5 s | escalate to SIGKILL |
| `ps -o comm= -g` in the sweep | 3 s | treat the group as unknown |
| `ps -o etime=` reading an adopted tunnel's start time | 3 s | no duration: it counts from the adoption |
| `networksetup` (system proxy) | 60 s + 2 s grace | terminate, then SIGKILL, then `authorizationTimedOut` |
| `ps -o user=` reading a pid's owner | 3 s | the owner is unknown, so the user-level path is tried |
| elevated `sudo … kill` | 20 s | terminate the `sudo`, then SIGKILL it, and report the failure |
| `/etc/hosts` cleanup on quit | 5 s | report and let the next connect retry |

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
- **`sudo -n` is always tried first.** It never prompts, fails in milliseconds
  when the timestamp is cold, and a just-connected tunnel has a warm one. The
  stronger forms are only *sent* while the process is still there: `send` stops
  at the first plan that works, so a password or a dialog is never spent on a
  process that is already gone.
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

    # is sudo's timestamp warm? (exit 0 = yes, 1 = no)
    sudo -n -v; echo $?

    # what the last launch recorded
    cat ~/Library/Application\ Support/TurtleDiver/run/elevation.pgid

    # who is in that group — names only
    ps -o pid=,pgid=,comm= -g <pgid>

    # leftover privileged processes — names only, never argv
    pgrep -x sudo; pgrep -x openconnect

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
