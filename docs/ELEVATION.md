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
| `networksetup` (system proxy) | 60 s + 2 s grace | terminate, then SIGKILL, then `authorizationTimedOut` |
| `/etc/hosts` cleanup on quit | 5 s | report and let the next connect retry |

## Non-goals

These are deliberate and should not be "fixed" later:

- **The app never modifies `/etc/pam.d/sudo_local`** (or any PAM file). It only
  reads them. Enabling or disabling Touch ID for sudo is the user's decision,
  made with their own editor or their vendor's instructions. See
  `docs/DISTRIBUTION.md`.
- **The app never kills a root-owned `openconnect`.** That process restores
  routes and DNS on its way out; killing it is how a machine loses its network.
- **The app cannot reap a pre-existing root-owned orphan**, and no message or
  document says it can. It prevents orphans (process groups) and reports
  leftovers (the sweep).
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
