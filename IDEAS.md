# IDEAS

An inbox, not a plan. Anything goes in here — half-formed, contradictory, one
line or ten, measured or guessed. Nothing in this file is a promise, and an idea
that never leaves it is a perfectly good outcome.

When one graduates it moves into `docs/` as a plan or a section (the way
`docs/SURGE_CAPABILITIES_PLAN.md` did), or straight into a commit. Then it moves
to **Picked up** below, with a pointer, so this file does not fill with ghosts
that nobody remembers the state of.

## Adding one

Append a dated line to **Unsorted**. A paragraph is plenty:

    - (2026-09-22) Reconnect on wake rather than waiting out the DPD timeout.

If it needs more room than a paragraph, give it its own heading — the point is
that writing it down costs nothing.

Two house rules, the same ones the rest of the repository keeps:

- **No employer names, no real hosts or addresses, no paths off anyone's
  machine, no credentials.** `RepoPrivacyGuardTests` scans this file exactly
  like every other text file in the tree, and it is right to.
- **Say how you know.** "The connect took 30 s longer" is worth ten times more
  with the measurement behind it than without.

## Unsorted

- (nothing yet)

## Worth a look

Measured first, unexplained second. Each of these came out of real runs rather
than reading the code, so the context is the expensive part — keep it.

### An agent the updater cannot replace

The in-app updater ships a `.dmg`: the app, and never the privileged helper.
The agent at `/usr/local/libexec/turtlediver-agent` is only ever replaced by the
package, so a machine can run a new app with an old agent, and nothing in either
one says so. 2.1.2 worked around it — the app watches its own tunnel instead of
trusting the agent to notice — but the underlying shape is still there.

Ideas, none of them obviously right:

- The app compares the installed agent against itself at launch and says
  something in Setup when they disagree, with a button that runs the installer.
  Needs an agent version or protocol number to compare, which the protocol
  deliberately does not have today.
- Ship the agent inside the app bundle and install it with one elevation on the
  next connect after an update. Fewer moving parts for the user, but it makes a
  single elevation prompt do two jobs, and the agent would then live in two
  places.
- Have the agent answer with a protocol version on its first line, so an old one
  is *detected* rather than guessed at, and the app can refuse it by name.

Constraints to respect, from `docs/ELEVATION.md` and `docs/UPDATES.md`: nothing
is installed while the tunnel is up, nothing is elevated silently, and an update
a user did not ask for is worse than an old helper.

### Liveness without shelling out to `ps`

The app decides "the tunnel is gone" by running `ps` on a pid it recorded, every
3 s while connecting, because an old agent cannot say what happened to its child.
A newer agent does say (`done`, and a reason), so this is really a fallback that
existed before the fix and now only covers old helpers.

A better contract might be the agent talking instead of the app probing: a
heartbeat line, or the app reading the child directly. The rule that must
survive any replacement, and is worth keeping written down: a zombie answers
`kill(pid, 0)` as *alive* while `ps -o comm=` reports `<defunct>`, so liveness is
a question about a **name**, never a signal. That is `docs/ELEVATION.md` § 10.

### A root `sudo` that waits through part of every connect

During the live pass for 2.1.2, a `sudo` process owned by root was visible for
about half a minute during a normal connect and then exited by itself. Nothing
was left behind — not after a disconnect, and not after a failed connect — so it
is not the orphan this codebase has fought twice. But nobody has explained what
it is waiting for.

Worth an hour with the process table and the app's own log side by side. If it is
a prompt waiting on nothing, that is a root process alive for a fraction of every
connect; if it is the elevated setup doing slow work, it is worth a line of
comment saying so.

### Say the tunnel's reason in the window, not just in the log

2.1.2 records the diagnosis (`Failed - Tunnel Ended`) plus the tunnel's own last
`STDERR` line, and both land in the History row and the debug pane. The pill and
any notification still show only the status word. On a failure the question a
person actually has is "why", and the answer is already sitting in the string
the app just parsed.

### Notarization

`publish.sh` refuses to build release artifacts without a Developer ID
certificate, so 2.1.2 went out through `--local` and anyone downloading it needs
right-click ▸ Open. One-time cost: Apple Developer Program enrolment, two
certificates (Application and Installer), one `notarytool store-credentials`.
Steps are in `docs/DISTRIBUTION.md`.

Worth deciding at the same time: whether a non-notarized artifact should be
something `publish.sh` can produce without being asked for it explicitly. It is
a deliberate `--local` today, and the release that carries it says so — but
nothing stops the next person from publishing one by accident.

## Picked up

- (nothing yet)

## Dropped

- (nothing yet) — an idea that leaves gets one line here saying why, so the same
  ground is not re-covered in six months.
