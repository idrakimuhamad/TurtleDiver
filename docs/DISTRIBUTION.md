# Distribution: getting TurtleDiver onto someone else's Mac

Two separate problems:

1. **The app itself** — macOS refuses to open a downloaded app it cannot
   identify. Fixed with a Developer ID signature plus notarization.
2. **Its dependencies** — `openconnect`, `stoken` and `vpn-slice`. Currently
   the README asks the user to `brew install` them; this document plans how
   that becomes part of installing TurtleDiver.

Measured on the development machine (macOS 26, Apple silicon) unless stated.

---

## 1. Why Gatekeeper blocks the current builds

    $ spctl -a -vvv -t open --context context:primary-signature dist/TurtleDiver-1.2.0.dmg
    dist/TurtleDiver-1.2.0.dmg: rejected
    source=no usable signature

    $ pkgutil --check-signature dist/TurtleDiver-1.2.0.pkg
    Status: no signature

Both installers that exist in `dist/` are rejected. The causes, all in the old
`publish.sh`, are fixed now:

| Defect | Consequence | Fixed |
| --- | --- | --- |
| `pkgbuild --root <the.app>` | the payload was the app's **contents** (`./Contents/…`) installed into `/Applications/TurtleDiver.app`, not the bundle | root is a staging directory that *contains* the app, `--install-location /` |
| `productbuild --sign "Sign to Run Locally"` | that string is not an identity, so the call failed; `\|\| productbuild …` then quietly built an **unsigned** package | signing identity is required up front, failures are fatal |
| nothing notarized, nothing stapled | every download is quarantined and blocked | `notarytool submit --wait` + `stapler staple`, both verified |
| `codesign -dv` never checked | a development certificate shipped as a "release" | hardened runtime, Developer ID and team are asserted |
| `cp -R` into the DMG | extended attributes are not reliably preserved | `ditto` |
| no verification of what was built | the payload bug shipped unnoticed | `verify_dmg` mounts the image and `verify_pkg` expands the package |

### What "quarantine" actually is

`com.apple.quarantine` is an extended attribute that the *downloading* app
(Safari, Chrome, Slack, Mail) writes onto the file it saves. It is not present
on a locally built or locally copied app:

    $ xattr -l /Applications/TurtleDiver.app
    com.apple.macl:
    com.apple.provenance:

That is why a build straight out of `build/` launches with no prompt. The gate
opens when the file arrives *from somewhere else*, and macOS then asks the
notary service whether Apple has seen this exact binary.

**The clean fix is notarization, and notarization needs a Developer ID
certificate.**

    $ security find-identity -v -p codesigning
      1) … "Apple Development: <your name> (<CERTIFICATE-ID>)"
      2) … "Apple Development: <you@example.com> (<CERTIFICATE-ID>)"
      2 valid identities found

Only *Apple Development* leaves exist, and they cannot be notarized. (The
keychain does hold `Developer ID Certification Authority`, but that is the
intermediate — an identity needs a leaf with a private key.)

### The three ways to ship without a Developer ID

| Approach | Recipient's experience |
| --- | --- |
| Send the `.dmg` as it is | "cannot be opened because the developer cannot be verified" → right-click ▸ Open (or System Settings ▸ Privacy & Security on macOS 15+), else `xattr -dr com.apple.quarantine /Applications/TurtleDiver.app` |
| `git clone` + `./scripts/…` or `./build.sh` | **no Gatekeeper involvement at all** — `git` does not set the quarantine attribute. Needs Xcode on their Mac. |
| Send the source as a zip | as above, but the zip *is* quarantined; only the app inside matters, and building avoids the issue entirely |

So: for two or three colleagues on the same team, **build-from-source is the
frictionless path today**, and notarization is what makes a download work for
everyone else.

### Turning notarization on (one-time, needs Apple Developer Program)

1. Enrol in the Apple Developer Program (**$99/year**). A free Apple ID cannot
   issue Developer ID certificates.
2. In Xcode ▸ Settings ▸ Accounts ▸ *Manage Certificates* (or
   developer.apple.com ▸ Certificates), create:
   - **Developer ID Application** — signs the app and the disk image
   - **Developer ID Installer** — signs the `.pkg`
3. Store the notary credentials once:

       xcrun notarytool store-credentials turtlediver-notary \
           --apple-id you@example.com --team-id KT7QU923S8

   (An app-specific password from appleid.apple.com; it lands in the login
   Keychain, not in the repo.)
4. Build:

       ./publish.sh                 # signs, notarizes, staples, verifies
       ./publish.sh --local         # what we can do today: no Developer ID

`publish.sh` refuses to run in release mode without those two identities and a
usable notary profile, because the alternative — what the old script did — is
publishing something Gatekeeper rejects without saying so.

Nothing about the *app* blocks notarization: it is already signed with the
hardened runtime (`ENABLE_HARDENED_RUNTIME = YES`), uses no restricted
entitlements, and has no provisioning-profile requirement. When the
certificates exist, `./publish.sh` is the whole job.

---

## 2. Dependencies

Three command-line tools, all third-party:

| Tool | What it does | Why it cannot be dropped |
| --- | --- | --- |
| `openconnect` | the VPN protocol | v9.21 via Homebrew; the whole point of the app |
| `stoken` | RSA SecurID software token | the user's TOTP comes from `stoken tokencode` |
| `vpn-slice` | split tunnelling | runs as openconnect's `-s` script to build the routes |

Today `README.md` asks for three separate commands — `brew install
openconnect`, `brew install stoken`, `brew install vpn-slice` — and the app
resolves them from a fixed list (`VPNManager.binaryPath`):
`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`.

### Why bundling them into the app bundle is the wrong answer

Measured:

    openconnect 9.21 → gnutls, nettle, gmp, p11-kit, stoken, gettext, libunistring, …
    vpn-slice 0.16.1 → python@3.13, python@3.14, openssl@3, sqlite, xz, readline, ca-certificates
    full closure: 19 transitive dependencies + the 3 tools, 212 MB on disk
    /opt/homebrew/bin/vpn-slice → #!/opt/homebrew/Cellar/vpn-slice/0.16.1_1/libexec/bin/python

- Every Homebrew dylib is referenced by absolute path and would need
  `install_name_tool` surgery, re-done on every upstream update.
- `vpn-slice` is a Python program: bundling it means embedding an interpreter.
- Licensing: openconnect is **LGPL-2.1-only**, stoken **LGPL-2.1-or-later**,
  gnutls **LGPL-2.1-or-later AND GPL-3.0-only**, vpn-slice **GPL-3.0-or-later**.
  Redistributing them inside the app bundle carries relinking and source-offer
  obligations, plus a re-signing step for each. Homebrew's bottles already
  satisfy that, upstream, for free.
- Hardened-runtime library validation would have to be weakened for those
  dylibs, which is exactly the entitlement reviewers and users distrust.

Verdict: **do not bundle.** Everything below delegates to Homebrew.

### Option C — an in-app Setup assistant **(shipped in 2.0.0)**

A new Settings pane, **Setup** (Application group), listing one row per tool:

    Homebrew        ✓ 7.0.1                     /opt/homebrew/bin/brew
    openconnect     ✓ 9.21                      /opt/homebrew/bin/openconnect
    stoken          ✓ 0.93                      /opt/homebrew/bin/stoken
    vpn-slice       ✓ 0.16.1                    /opt/homebrew/bin/vpn-slice
    ────────────────────────────────────────────────────────────────────
    [ Install Missing ]   [ Copy command ]   [ Check Again ]

What it does today (the plan below differed in three places, noted inline):

- **Detection** — a pure `ToolRequirement` table (name, `--version` argument,
  why it is needed, and the `brew` formula), resolved through PATH *and* the
  known prefixes, so a MacPorts user (`/opt/local/bin`) or a `~/.local/bin`
  install is recognised instead of being told "not installed". This also fixed
  a real defect: `binaryPath` could not see those installs. There is no minimum
  version check — the plan had one, and it is not worth failing a connect over
  a version Homebrew will refuse to install anyway.
- **Install** — runs `brew install openconnect stoken vpn-slice` as the *user*
  (Homebrew must never run as root), streaming output into a card that appears
  while it runs. Homebrew itself is **not** bootstrapped and no password is
  ever asked for: when it is absent the pane says so and links to brew.sh.
  Installing Homebrew is a bigger commitment than installing three formulae,
  and it needs root — the app will not take that decision for the user.
- **Never required** — the pane is advisory. It reports; it disables nothing
  and changes no setting. Anyone who manages their own installs can ignore it.
- **Pre-flight on Connect** — if a required tool is missing, Connect stops
  *before* it asks stoken for a code, and says "stoken is not installed — see
  Settings ▸ Setup" (naming every absent tool, and the one line that installs
  them) instead of the misleading "Failed to generate token". The History pane
  records the attempt as **Failed - Missing Tool**, so the pill reads "Missing
  tool" and not "Token error".
- Copy-command remains for anyone who prefers a terminal; the same strings are
  in `README_INSTALL.txt` so the DMG, the `.pkg` and the app agree.

Cost: one settings pane, one `Process` runner (reusing the existing redaction
and logging rules — install output must not reach `vpn.log`), and tests over a
pure resolution table plus an injected runner. No installer scripting, no root,
works for both the DMG and the `.pkg`, and the user sees progress.

### Option B — an optional component in the `.pkg`

`packaging/distribution.xml.tmpl` already has the shape; it would get a second
component:

```xml
<options customize="allow"/>
<choices-outline>
    <line choice="default"><line choice="com.xvii.kurakura.vpn"/></line>
    <line choice="tools"/>
</choices-outline>
<choice id="tools" title="Install command-line tools with Homebrew" selected="true">
    <pkg-ref id="com.xvii.kurakura.tools"/>
</choice>
```

with a scripts-only component whose `postinstall` runs

```sh
consoleUser=$(stat -f%Su /dev/console)
sudo -u "$consoleUser" -H /bin/bash -c 'brew install openconnect stoken vpn-slice'
```

Pros: works with a single double-click, no app required first. Cons: an
Installer window that looks frozen for minutes; a root script driving a
user-owned package manager; silent breakage when the network is down or when
Homebrew was installed at `/usr/local` for Intel. Worth having **as a
convenience for people who install with the `.pkg`** — but only after Option C
exists, because C is where the diagnosis and the error messages live.

### Option D — a Homebrew tap or cask **(do this too, later)**

    brew tap xvii/turtle
    brew install --cask turtlediver      # the notarized DMG
    brew install turtlediver-tools       # depends_on openconnect, stoken, vpn-slice

The tools formula is three lines and lets Homebrew own the dependency graph,
versions and upgrades — better than any script we could write. The cask also
gives "update available" behaviour for free, which the app has no answer for
today. Needs a public repo and a notarized DMG, so it follows the Developer ID
work.

### Option E — vendoring Homebrew bottles into the installer

Download each bottle at publish time and untar into `/opt/homebrew/Cellar`,
creating symlinks by hand. Works offline and needs no Homebrew on the target
machine. Rejected as the primary path: 22 formulae totalling 212 MB, a fake Homebrew
root on machines that never asked for one, no upstream upgrade path, and it
would be us — not Homebrew — redistributing LGPL/GPL binaries.

### Recommendation

1. **Option C — done (2.0.0).** It needed no certificate, no root and no
   installer scripting, it fixed the detection defect, and it turned a README
   line into a guided experience. It is the only option that also helps someone
   who installed by dragging the DMG.
2. **Option D after notarization** — a `turtlediver-tools` formula plus a cask;
   the Setup pane then just says "managed by Homebrew".
3. **Option B only if the `.pkg` becomes the primary download.**
4. **Option E never**, unless an offline/air-gapped installer is ever required.

### Decision points for the maintainer

- **Developer ID / Apple Developer Program**: enrol and create the two
  certificates? Without them nothing downloadable can avoid the Gatekeeper
  prompt; with them `./publish.sh` is finished. Answered: **not enrolling** —
  the prompt stands, and it is documented in §"Installing without the
  Gatekeeper prompt". The notarization paths in `publish.sh` stay correct and
  dormant.
- **Who may install dependencies?** Option C runs `brew install` from the app
  but always behind an explicit button click, never silently. Answered: the app
  runs it as the user with no password; the by-hand command is shown too.
- **Homebrew bootstrap in-app?** Answered: **no.** The pane says "install
  Homebrew first" and links to brew.sh.

---

## 3. Scripts

    ./build.sh                     # local Release build → build/Build/Products/Release
    ./build.sh --no-clean --install # build, copy to /Applications, relaunch
    ./build.sh --debug --test      # Debug + the SwiftPM suite
    ./publish.sh --local           # signed for this machine; not notarized
    ./publish.sh                   # Developer ID + notarize + staple + verify

`publish.sh` ends by printing `spctl`'s verdict for the app, the disk image and
the package, so a rejected artifact is visible in the build log rather than in
a user's inbox. In `--local` mode those three lines say `rejected` — that is
correct and expected; it is the Developer ID gap, not a build failure.

`dist/` is ignored by git: installers are build outputs, and the two older
1.1.0/1.2.0 sets are being kept on disk but no longer tracked.

---

## 4. A privileged helper instead of `sudo` (deferred)

TurtleDiver elevates twice: openconnect (`sudo`) and `networksetup`
(Authorization Services). Both are described, with their failure modes and
bounds, in **`docs/ELEVATION.md`**. A `SMAppService` helper daemon would remove
the stored administrator password from the picture entirely — and the class of
problem that comes with piping it into a stack that can decide to wait for a
dialog instead.

**It is deferred until a Developer ID exists**, and that is not a preference:

- Apple's `SMAppService.h` (macOS 27 SDK) states that *"Apps that contain
  LaunchDaemons must be notarized."* Notarization requires a Developer ID leaf
  certificate, which requires Apple Developer Program enrolment. This project
  has decided **not** to enrol, so the notarization paths in `publish.sh` stay
  correct and dormant (§1).
- The same header documents `.requiresApproval` as successfully registered and
  awaiting the user in System Settings, and `kSMErrorInvalidSignature` as the
  answer for an improperly signed app.
- A throwaway spike (`/tmp/tdspike`) measured registration on macOS 27: **every**
  item type — including `SMAppService.mainApp`, with a correctly signed helper
  and with a deliberately differently signed one — returned
  `SMAppServiceErrorDomain` **code 1 ("Operation not permitted")** with status
  `.requiresApproval`. Read that as *pending approval*, **not** as *bad
  signature*; a signature check cannot be inferred from it.
- Useful for a later no-Developer-ID route: legacy `/Library/LaunchDaemons`
  plists *"continue to be bootstrapped without explicit approval in System
  Settings"*, so a root-owned helper installed once by an explicit user command
  (or a `.pkg` postinstall) remains viable. The plist must then point at a
  binary under `/Library/PrivilegedHelperTools`, **never** into the app bundle,
  because the logged-in user can replace anything inside their own copy of the
  app while launchd would still run it as root.

Rules agreed in advance, if the helper is ever built:

- **No generic `runCommand`, ever.** Commands are constructed inside the daemon
  from typed fields — a fixed executable list, `/etc/hosts` edits as validated
  IP + hostname entries. No shell, and no client-supplied argv.
- **Validate the caller in-code** (audit token, pid fallback), pinned to
  **Team ID + bundle id** rather than to a certificate, so renewing the
  certificate does not invalidate the daemon.
- **One elevation path per connect**, chosen by an explicit setting and verified
  with a bounded ping before use. Never a silent fallback to `sudo`: that
  re-creates the stall the bounded paths were written to remove.

### Non-goal: the app never edits PAM

TurtleDiver **reads** `/etc/pam.d/sudo_local` and `/etc/pam.d/sudo` to learn
whether Touch ID (`pam_tid`) answers sudo. It **never writes, creates or removes
them** — not to enable Touch ID, not to work around it, not to "repair" a
machine. That is the user's authentication configuration, and an installer or an
app that rewrites it is doing something nobody asked for. The detection exists
so the app can step aside and let the system show its own dialog; the file itself
stays untouched.
