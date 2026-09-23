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
| 6 | Needs approval: a dialog would be needed and no password can replace it — no terminal and none supplied, or `--sudo-password stdin` on a machine whose `sudo` reaches a dialog before it would read the pipe. |
| 7 | A tool is missing (`openconnect`, `stoken`, `vpn-slice`, or `turtlediver-askpass` where the askpass route needs it). |
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

A handed-over password has to reach this machine's `sudo`, and there is more than
one door it can use. The machine picks, not the CLI, and the two doors are the
two answers the app's own `ElevationPolicy` already reads out of the PAM stack.

Where `/etc/pam.d/sudo` does **not** reach `pam_tid`, `sudo -S` reads the pipe and
the source works as described above: one `sudo -S -v` child, the password written
to its standard input and let go.

Where Touch ID for `sudo` *is* enabled, `/etc/pam.d/sudo` includes `sudo_local`
and its `auth sufficient pam_tid.so` answers before the module that would read a
pipe — `sudo -S` raises its own dialog with the pipe still full. But `pam_tid`
also stands that dialog **down in askpass mode**: its own strings say so
(`askpass-enabled`, `sudo askpass mode, not showing UI`), and it was measured on
a Mac with the stock stack. Askpass is a door this tool can open by itself, so on
such a machine `--sudo-password keychain` goes through `sudo -A` and the helper
"Unattended connects" describes: `sudo` starts `turtlediver-askpass`, which reads
the item and prints it, and no dialog appears at all. `ElevationRoute.delivery`
is where that decision lives, and it is a decision about *delivery*, not about
which password the caller named.

Two combinations still cannot be delivered, and both are refused before anything
is started rather than left to fail in a way the caller cannot see:

* **`--sudo-password stdin` on a `pam_tid` machine — exit 6.** Askpass is the
  only door there, and askpass runs a *program*: there is no helper that prints a
  pipe, so this source cannot deliver, and it is not quietly replaced by the
  dialog it was chosen to avoid. The message names the source that does work:

  ```console
  $ read -rs pw; printf '%s\n' "$pw" | turtlediver connect --sudo-password stdin
  pam_tid answers sudo on this Mac, so a password piped to standard input is never
    read; nothing was started. --sudo-password keychain is the source that works
    here — sudo's askpass helper prints the stored password — or run the same
    command without the option and answer the prompt.
  $ echo $?
  6
  ```

* **`--sudo-password keychain` with the helper not installed — exit 7.**
  `missingTool`, naming the path that was looked for. This is the one thing the
  keychain source needs and the one thing installing this tool provides:

  ```console
  $ turtlediver connect --sudo-password keychain
  pam_tid answers sudo on this Mac, so a password can only arrive through sudo's
    askpass helper, which is not installed at /usr/local/bin/turtlediver-askpass;
    nothing was started. Install the command line tool that carries it (the .pkg
    installs both), or run the same command without the option and answer the
    prompt.
  $ echo $?
  7
  ```

Both answers come back in milliseconds, with nothing read and nothing run.
Neither is the option silently ignored, and neither door is quietly taken in
place of the one the caller named: either would leave the caller believing
something happened that did not.

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

**Past the first door, with the password handed over: sudo's askpass helper.**
This is the route that needs no change to the machine at all — only the helper,
which is this same binary installed a second time under a second name:

```
/usr/local/bin/turtlediver          the CLI
/usr/local/bin/turtlediver-askpass  the same binary, as sudo -A runs it
```

`publish.sh` installs both names (one binary, two links), and at the launch the
CLI sets `SUDO_ASKPASS=/usr/local/bin/turtlediver-askpass` in that child's
environment and runs `sudo -A -v`. `sudo` starts the helper **as this user** and
reads the password from the helper's standard output. The helper itself is
recognised by the name it was invoked under — `argv[0]`, which the kernel keeps
even when the path is a link — and by nothing else: not an argument, not an
environment variable. Which program is handed the administrator password is not
a choice a caller gets to make, and no environment variable can redirect it.

The helper takes no arguments, ignores any it is given (`sudo` passes its prompt
as one), and does exactly one thing: print the stored administrator password on
standard output, followed by a newline, and nothing else. That output *is* the
password `sudo` reads, so a progress line or a JSON document there would become
part of the password. Its failures go to standard error with a nonzero status,
which `sudo` turns into its own sentence and a failed authentication.

Why the helper is this binary rather than a shell script or `/usr/bin/security`:

* The Keychain item's access control is granted per *program*. A dedicated
  helper makes that grant a named, revocable thing — **Keychain Access** ▸ the
  item ▸ **Access Control** — instead of "whatever ran a script".
* `/usr/bin/security` is a general-purpose dispenser: anything that can run as
  this user can call it and ask for the item. This program prints the
  administrator password for exactly one reason and does nothing else.

```sh
nohup turtlediver connect --sudo-password keychain </dev/null >~/turtlediver.log 2>&1 &
sleep 20; turtlediver status --json | jq -r .connected
```

```console
$ turtlediver connect --sudo-password keychain
sudo: authenticating through sudo's askpass helper (turtlediver-askpass), which
  prints the stored administrator password; pam_tid stands its own dialog down in
  askpass mode, so there is no Touch ID prompt and nothing to type. macOS may ask
  once, the first time that helper reads the item.
connected: openconnect pid 51043 — press Ctrl-C to end the tunnel
```

That first run with nobody watching works only if the Keychain consents have
already been answered — including the one for the administrator password, which
the *helper* raises, not the CLI, and which is why the note says it before the
wait. Run it once in a terminal and click **Always Allow** on each item; a
later run needs nobody. (On a development build there is no stable signature to
grant, so each rebuild asks again: install it, or accept the prompts.)

The exposure is stated rather than papered over: with that grant in place,
**any process running as this user that can exec the helper can obtain the
administrator password.** That is the same exposure as `--sudo-password
keychain` where a pipe is read, and smaller than the sudoers rule below, which
hands out passwordless root to any local process. The option stays opt-in: a
caller that never passes `--sudo-password` is not affected by any of this, and
the helper is never run on its own initiative.

**Past the first door without storing anything: exempt the agent command.** A
documented operator escape hatch, not the product answer — it is a
passwordless-root primitive, and the CLI neither installs it nor recommends it.
Write `/etc/sudoers.d/turtlediver` (with `sudo visudo -f`, which refuses to save
a broken file):

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
"unattended" means. Scope the rule to one user (`Defaults:someone!…`) or drop
the file to undo it.

**Past the first door, the worst trade: take Touch ID out of `sudo`
machine-wide.** Comment the line out of `/etc/pam.d/sudo_local`, the file macOS
provides for local edits, and keep `--sudo-password` as the connect's credential:

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
3. **Into one short-lived child, never a long-lived one.** On a machine that
   reads a pipe, the refresh is `sudo -S -v` run as a *direct child of the CLI*,
   and the password is written to that child's pipe and let go. On a machine
   whose `pam_tid` answers first, the password never enters this process at all:
   `sudo -A` starts the helper, the helper reads the item and prints it, and the
   only thing the CLI contributes is the helper's **path** in `SUDO_ASKPASS`.
   The agent's own launch stays `sudo -n` either way, unchanged: the agent's
   standard input carries the tunnel's two credential lines, and an `-S` there
   would eat the PIN as its own password — the trap `OpenConnectLaunch`
   documents at length.
4. **Never printed.** Not in `--json`, not in a note, not in `details`, not in a
   Keychain-read announcement. The announcement says which door was used, and on
   the askpass route the CLI cannot print the password even by mistake, because
   it never holds it. The one place in the program that writes a password
   anywhere is `AskpassHelper.run`, whose standard output `sudo` reads *as* the
   password.

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
is macOS's rule, not this tool's.

A third item, the administrator password, is the one most routes never touch: not
a `connect` without `--sudo-password`, and not a machine that exempts the agent
command, where a password that was handed over is deliberately not read. On the
askpass route it is read — but not by this process, and the dialog belongs to the
*helper*. macOS names the program rather than the link it was invoked through, so
that dialog reads `turtlediver`, not `turtlediver-askpass`:

> `turtlediver` wants to use your confidential information stored in
> `com.xvii.kurakura.vpn` in your keychain.

**Always Allow** is the click to make either way. The grant is recorded against
the helper, and **Keychain Access** ▸ the item ▸ **Access Control** is where to
see it, or take it back.

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
* **No bound on a Keychain read.** `--timeout` covers the wait for the tunnel to
  come up, and nothing else. A credential read — or, on the askpass route, the
  helper's read of the administrator password — waits at a consent dialog until
  somebody answers it, and a caller with nobody at the machine should have the
  grants in place first (see Unattended connects) rather than find this out by
  watching a `connect` sit there.

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
