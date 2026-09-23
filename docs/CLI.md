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
| 6 | Needs approval: a dialog would be needed, there is no terminal, and no password was supplied (`--sudo-password`). |
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

The password is not remembered between commands. `disconnect` needs its own
`--sudo-password` if it needs one at all, and a supplied one also picks the
pipe over the machine's preferred dialog, so a scripted session authenticates
the same way at both ends.

`keychain` needs the app to have been given the password once — the stored item
lives in **Settings ▸ Advanced**. A Mac that answers `sudo` with Touch ID may
never have stored one, which is why a missing item is a named failure and not a
silent fallback to a prompt.

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
