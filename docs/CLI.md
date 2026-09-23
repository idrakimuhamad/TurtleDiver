# `turtlediver`

The command line, for a person at a terminal and for an agent that has one.

The app is the product. This is the same engine with a different front door:
install it with the app, ask it questions, and start or end a tunnel from a
shell. It is aimed at the two callers that cannot click: a person who lives in
a terminal, and an agent that needs to know whether the tunnel is up and which
policy a host resolves to.

## Why a separate binary

Idea 14 in `IDEAS.md` asks for a helper that can start a tunnel from the
command line. The first question is whether it is a *client* of the running app
(a local control socket) or a *standalone* driver of the same engine.

It is standalone. The reasons are in the order they decided it:

1. **It has to work with the app closed.** An agent that asks "is the VPN up?"
   should get an answer, not "the app is not running". A control socket that is
   only open while the app runs cannot answer the question that made the idea
   worth building.
2. **The tunnel already outlives its starter.** `openconnect` is run as root by
   `turtlediver-agent`, and the agent's life is tied to its standard input —
   when whoever started it goes away, end of input ends the tunnel. That is the
   property the CLI leans on, not one it has to invent. See
   `TunnelAgentProtocol.swift`.
3. **The app's connect code is not reachable from a second binary.**
   `VPNManager` and `SettingsManager` are `internal` and import `Cocoa`; a CLI
   module cannot see them. Making them public to reuse them would put the app's
   UI lifecycle in the CLI's dependency graph.

The cost is honest and it is the reason this document exists: the CLI builds the
`openconnect` command line itself, and the two builders can drift. That drift is
the thing to watch in review. `CLI/Kit/OpenConnectInvocation.swift` is the one
place the argv is built, and `Tests/TurtleDiverCLITests` pins it.

## What it does today

| Command | What it answers |
| --- | --- |
| `status` | Is a tunnel up, whose pid, and from which record. |
| `connect` | Start one, and stay in the foreground while it lasts. |
| `disconnect` | End one, idempotently. |
| `rules explain <host>` | Which rule matches, and which policy it resolves to. |
| `profile list` / `profile validate [name]` | What profiles exist, and whether one parses and resolves. |
| `version` | Version and build of the CLI. |

Everything machine-readable takes `--json`, on one line, with a stable shape.
Progress and human notes go to stderr in that mode so `--json` output stays
parseable.

### Exit codes

Agents match on these, so they are part of the interface and do not change to
mean something else.

| Code | Meaning |
| --- | --- |
| 0 | Success. `disconnect` with nothing to do is still success (see below). |
| 1 | Failure. |
| 2 | Usage error. |
| 3 | Not configured — no host, no profile, or the agent is not installed. |
| 4 | Already connected (`connect`). |
| 5 | Reserved for a command that needs a tunnel and there is none. No command uses it today; `disconnect` deliberately does not. |
| 6 | Needs approval: a dialog would be needed and no password can replace it — no terminal and none supplied, or `--sudo-password` on a machine whose `sudo` reaches a dialog first and whose agent command is not exempt from authentication. |
| 7 | A tool is missing (`openconnect`, `stoken`, `vpn-slice`). |
| 8 | The tunnel did not stop. |
| 9 | Timed out. |

`disconnect` is idempotent by design: ending a tunnel that is not there exits 0
and reports `"changed": false`. A caller cannot know whether a tunnel existed
before it ran, and a non-zero code for "already done" would make every caller
write the same "or maybe it was never up" branch.

## `connect` is foreground, and that is the design

`connect` blocks. Ctrl-C ends the tunnel. It does not background itself, and it
does not write a daemon.

This falls straight out of the agent: the tunnel's life is tied to the agent's
standard input, and the CLI is what holds that pipe. If `connect` forked and
returned, the pipe would close and the tunnel would end the instant the command
looked like it had worked. Backgrounding *is* the thing that would break it.

The consequence is real: a phone or another machine cannot drive this over ssh
and expect the tunnel to survive the session. That is a later decision, not an
accident — see "What this does not do".

The other half of that decision is what `disconnect` is for. It is **not** how a
foreground `connect` is ended: that is ended by stopping it — Ctrl-C, or `kill`
on the pid `status --json` reports. The pipe closes, the agent reads end of input
and tears the tunnel down itself, so no orphan `openconnect` is left running as
root and no password is needed. `disconnect` is for the tunnel whose driver is
already gone — the app was closed, the shell was lost, the pid file outlived the
process — and for a caller that wants to be sure nothing is up. It signals
`openconnect` by pid, and it is idempotent either way.

### Elevation

The agent runs `openconnect` as root, so `sudo` must have a warm timestamp by
the time the agent is launched. By default the CLI gets one the way it always
has, without ever storing an administrator password or requiring one:

* With a terminal, `connect` runs `sudo -v` first. `sudo` prompts on `/dev/tty`
  even though its standard input is `/dev/null`, so the person sees the prompt
  and Touch ID works. Every later `sudo` is a direct child of the CLI, so the
  timestamp belongs to the CLI's process and the `sudo -n` that follows finds
  it warm.
* Without a terminal (an agent, a pipe, a daemon), `connect` runs `sudo -n -v`
  and, if that fails, exits 6. It never guesses a password and it never raises a
  dialog nothing can answer. The caller's remedy is to warm `sudo` itself.

That default is right for a person and wrong for an agent. An agent has no
terminal to prompt on, and it cannot warm `sudo` in a shell of its own either:
sudo keys its timestamp to the *parent process* when there is no terminal
(`docs/ELEVATION.md` §1a), so a warm timestamp in another shell does not
transfer. Such a caller is left with no way in — but it is exactly the caller
that may already hold the password.

`--sudo-password SOURCE` on `connect` and `disconnect` is that door, and the
only one:

| Source | What it is | Who it is for |
| --- | --- | --- |
| `keychain` | the administrator password the app already stores under its own service | an agent that should not handle the password at all — it never enters the agent's context |
| `stdin` | one line on the CLI's **own** standard input | a script, or a person with the password in a variable |

With no `--sudo-password` nothing changes: not one of the rules below applies,
and the two behaviours above are what happens. A source that is *named* and does
not deliver is refused — `keychain` with no stored item and `stdin` with no line
exit 3 and 2 respectively — and never quietly replaced by the other door. A
caller that asked for `stdin` and got a Touch ID dialog hangs; a caller that
asked for the Keychain and got a prompt fails somewhere it cannot see.

A handed-over password also has to be *readable* by this machine's `sudo`, and
not every Mac's is. Where Touch ID for `sudo` is enabled, `/etc/pam.d/sudo`
includes `sudo_local`, whose `auth sufficient pam_tid.so` answers *before* the
module that would read a piped password: the dialog appears first, the pipe is
never read, and the connect waits on the very dialog its caller asked to avoid.
The CLI learns this from the same two world-readable files the app's own
`ElevationPolicy` reads — no question is put to `sudo` — and refuses the option
on such a machine **before it starts anything**:

```console
$ turtlediver connect --sudo-password keychain
pam_tid answers sudo on this Mac, so its own Touch ID or administrator-password
  dialog appears before anything can read a piped password, and --sudo-password
  cannot skip it; nothing was started. Run the same command without the option
  and answer the prompt, or run `turtlediver help` and read Unattended connects
  for the two ways to do this with nobody at the machine.
$ echo $?
6
```

Exit 6 in milliseconds, with nothing read and nothing run. That is the honest
answer for a caller that cannot see a dialog, and the same code a mistyped
source gets. The option is not silently ignored and the dialog route is not
quietly taken in its place: either would leave the caller believing something
happened that did not. On such a Mac an unattended connect needs one of the two
setups in "Unattended connects" below, or a person.

The password is not remembered between commands. `disconnect` needs its own
`--sudo-password` if it needs one at all, and where this machine reads a pipe a
supplied one picks that pipe over the dialog the machine would otherwise prefer,
so a scripted session authenticates the same way at both ends.

`keychain` needs the app to have been given the password once — the stored item
lives in **Settings ▸ Advanced**. A Mac that answers `sudo` with Touch ID may
never have stored one, which is why a missing item is a named failure and not a
silent fallback to a prompt.

#### Unattended connects

A connect with nobody at the machine has to get past two doors, and only one of
them is the password:

1. **`sudo` has to be authenticated** before the agent is launched, because the
   launch is `sudo -n` and its timestamp belongs to this process. With no
   terminal and no readable pipe, nothing can do that.
2. **The two VPN credentials are read from the Keychain**, and the first read of
   each item may raise a consent dialog. See "The VPN credentials, from the
   Keychain" below for what makes those durable.

There are two ways past the first door. Both are machine changes the *user*
installs, once, with the administrator password; the CLI makes neither on its own
and never relaxes `sudo` silently.

**Exempt the agent command, and nothing else** — the one that keeps Touch ID for
sudo everywhere else. Write `/etc/sudoers.d/turtlediver` (with `sudo visudo -f`,
which refuses to save a broken file):

```
Defaults!/usr/local/libexec/turtlediver-agent !authenticate
```

That is the path the app installs the agent at, root-owned, so the rule names the
thing that actually runs rather than a shell. With it in place,
`sudo -n /usr/local/libexec/turtlediver-agent …` runs with no authentication at
all — no dialog, no timestamp, no password — and `connect` needs no
`--sudo-password`:

```sh
nohup turtlediver connect </dev/null >~/turtlediver.log 2>&1 &
```

The CLI asks one question before it decides anything,
`sudo -n -l /usr/local/libexec/turtlediver-agent`, which is a request for policy
and not an attempt to authenticate: `-n` turns "a password would be required"
into a failure instead of a prompt, so the question is safe to ask with nobody
watching. Exit 0 — with the command named in the answer, so a `sudo` that exits 0
for some other reason cannot be read as permission — means the launch will
authenticate nothing, and then:

* the refresh is skipped: there is nothing to warm, so no dialog is raised and no
  terminal is needed;
* a `--sudo-password` the caller offered is **not read**, and the CLI says so. A
  door nobody has to open should not raise a Keychain dialog on the way past;
* the refusal described above does not apply, because it is only true of a launch
  that has to authenticate.

Every other answer is treated as the ordinary case and `sudo` is refreshed as
usual. The conservative direction is deliberate: an unnecessary refresh costs a
prompt, and a skipped refresh costs a failed launch after the caller was told
nothing was needed.

```console
$ turtlediver connect --sudo-password keychain
sudo -n -l: the agent command needs no authentication on this machine, so sudo
  is not refreshed and no prompt or dialog can appear.
nothing to warm: the administrator password that was supplied was not read.
connected: openconnect pid 51043 — press Ctrl-C to end the tunnel
```

The cost is worth stating plainly: with that rule in place, **anything running as
this user can start a root tunnel without authenticating**. That is what
"unattended" means, and it is the same property the app has when it stores the
administrator password. Scope the rule to one user (`Defaults:someone!…`) or drop
the file to undo it.

**Or take Touch ID out of `sudo` machine-wide** — comment the line out of
`/etc/pam.d/sudo_local`, the file macOS provides for local edits, and keep
`--sudo-password` as the connect's credential:

```sh
read -rs pw; printf '%s\n' "$pw" | turtlediver connect --sudo-password stdin
```

This is the strategy the app's own `ElevationPolicy` calls `.storedPassword`, and
the one `docs/ELEVATION.md` describes as the only way to elevate with nobody at
the keyboard. Its cost is the whole machine: Touch ID stops being used for `sudo`
at all, including the app's own connects, until the line comes back.

A sudoers rule for the *app* is not an option, and not an oversight: the app's
plan runs several different `sudo` commands from one generated script (`sudo -v`,
the `/etc/hosts` cleanup, the launch), so no single command can be named — only
`/bin/sh`, which would exempt everything. Unattended connects are a CLI property
because the CLI runs exactly one thing as root.

#### What happens to the password

One value in this tool may never be seen by anyone, so the rules are stated
rather than implied, and tested in `CLISudoPasswordTests`:

1. **Never in `argv`.** Any process of this user can read the argument list of
   any other, and `pgrep -f` and crash reports copy it elsewhere. The option
   takes a *source*, never a password.
2. **Never in the environment.** `ps -E` shows it, and every child inherits it.
3. **Down the child's standard input, once, then dropped.** The refresh is
   `sudo -S -v` run as a *direct child of the CLI*, and the password is written
   to that child's pipe and let go. The agent's own launch stays `sudo -n`,
   unchanged: the agent's standard input carries the tunnel's two credential
   lines, and an `-S` there would eat the PIN as its own password — the trap
   `OpenConnectLaunch` documents at length.
4. **Never printed.** Not in `--json`, not in a note, not in `details`, not in a
   Keychain-read announcement. The announcement says which door was used.

`--sudo-password stdin` is safe precisely because this CLI reads nothing else
from its own standard input (`isatty` is the only thing it ever asks of it):

```sh
read -rs pw; printf '%s\n' "$pw" | turtlediver connect --sudo-password stdin
```

For an agent, prefer `keychain`: the password stays where macOS already guards
it, behind the app's own item, and never passes through the agent's hands.

## The VPN credentials, from the Keychain

The VPN account password and passcode *are* read from the Keychain, under the
app's own service, and the first read may prompt:

> `turtlediver` wants to use your confidential information stored in
> `com.xvii.kurakura.vpn` in your keychain.

This is macOS's own gate, and it is the correct place for it: the alternative is
a second copy of the password on disk. Clicking **Always Allow** makes it
once-per-binary.

There are two of these on a `connect` — the account password, and the passcode
half of the PIN — because the app keeps them in two items. One dialog per item
is macOS's rule, not this tool's; `--sudo-password` would have been a third, and
on a machine where it is refused it is now never read at all.

The prompt returning on *every* run is usually the binary rather than the item. A
`swift build` product is ad-hoc signed, and its identifier is derived from the
`cdhash`, so the CLI is a different program to the Keychain after every rebuild
and no **Always Allow** can ever stick:

```console
$ codesign -dvv .build/debug/turtlediver 2>&1 | grep -E 'Identifier|Signature'
Identifier=turtlediver-<hash of this build>
Signature=adhoc
```

The binary `publish.sh` installs is signed with a stable identifier and the app's
team, so there one **Always Allow** covers every later run — which is also what
makes the tool usable from an agent, which has nobody to click it.

## What it reads, and what it will not write

The CLI reads, and does not write:

* `~/Library/Application Support/TurtleDiver/Profiles/*.conf` — profiles.
* `~/Library/Application Support/TurtleDiver/RuleSets/` — cached rule sets.
* `~/Library/Application Support/TurtleDiver/run/openconnect.pid` — the tunnel.
* `~/Library/Preferences/com.xvii.kurakura.vpn.plist` — host, account, whether
  tunnelling is on, and the slice URLs.

It deliberately does not use `ProfileManager`, even though it is public: that
initialiser *writes* a default profile to disk when the active name is missing,
and a read command that creates files is a bug waiting to be reported. The CLI
reads the directory itself.

Settings are not written. `turtlediver connect` uses the host and account the app
already has; it does not have its own configuration and does not edit the app's.
A second configuration format is the thing that makes two front doors into two
products.

## What this does not do

* **No background mode.** See above.
* **No administrator password storage.** The CLI never stores one and never
  requires one. `--sudo-password` can *hand* it one for a single run, and the
  value is dropped after the one `sudo -S -v` that spends it. See Elevation.
* **No control socket to the running app.** It answers questions itself, from
  the same files, so it works when the app is closed.
* **No `--json` on the connect *stream*.** `--json` prints one line when the
  tunnel is up; the tunnel's own output goes to stderr. A stream of JSON events
  is a bigger interface than anyone has asked for yet.

## Installing it

`publish.sh` builds the `turtlediver` product (target `TurtleDiverCLI`) with
the agent, signs it with the same identity, and stages it at
`/usr/local/bin/turtlediver` in the installer package. `verify_pkg` refuses a
package that does not carry it — or carries one that will not run — the same way
it refuses one that does not carry the agent: the command is part of what
"installed" means. The disk image does not carry it, the same as the agent.

`/usr/local/bin` is the standard place for a package to put a command, and it is
on the default `PATH` of both `zsh` and `bash`. A CLI whose first instruction is
"add this directory to your `PATH`" is a CLI most people will not use.

## Checking it by hand

```sh
turtlediver version
turtlediver status --json
turtlediver rules explain github.com
turtlediver profile validate
turtlediver connect          # Ctrl-C to end the tunnel

# An agent: no terminal, no dialog, the password from the app's own item.
turtlediver connect --sudo-password keychain

# A script holding the password in a variable.
read -rs pw; printf '%s\n' "$pw" | turtlediver connect --sudo-password stdin
```

`rules explain` uses the cached rule sets; a set that has never been downloaded
is reported as unresolved rather than silently matching nothing. Downloading
rule sets is the app's job, and a CLI that reaches the network to answer a
question is a surprise.
