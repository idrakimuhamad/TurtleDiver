# Updates: how TurtleDiver finds a newer release, and how it installs one

The feature has two halves, and they answer two different questions:

- **the check** — "is there a newer release?" One GET when the app starts
  (opt-out), and `Check Now` in **Settings ▸ Updates**.
- **the install** — "get it". Only ever after a click, and only ever from
  `github.com/idrakimuhamad/TurtleDiver`.

Nothing is downloaded on its own, nothing is installed while the VPN tunnel is
up, and nothing is ever elevated to install. Those three are decisions, not
accidents, and each has a section below.

## The feed

`UpdateFeed.latestReleaseURLString` is
`https://api.github.com/repos/idrakimuhamad/TurtleDiver/releases/latest`. It
sends no credentials and nothing about the machine — it is one unauthenticated
GET, and it is the same URL a browser would use.

What that endpoint returns is a *release*, and what this app needs from it:

| field | used as |
| --- | --- |
| `tag_name` | the version, with the leading `v` stripped (`v2.1.0` → `2.1.0`) |
| `html_url` | the **Open Release Page** target |
| `assets[].name`, `browser_download_url`, `size`, `digest` | the disk image, its size, and GitHub's own SHA-256 of it |
| `draft`, `prerelease` | a draft is never offered; so is a prerelease |

A tag that is not a dotted-decimal version is a **stated refusal**, never a
guess at "newer": every release must bump `MARKETING_VERSION` in
`VPNConnect.xcodeproj`, which `publish.sh` already checks against the built
app. The installer is expected beside its checksum, named for the version:

    TurtleDiver-<version>.dmg
    TurtleDiver-<version>.sha256

`releases/latest` never returns a prerelease, so an opt-in prerelease channel
would need the release *list* and its own filtering. That is not this release.

## The gates

A download is accepted only if all of these hold. Each is a separate refusal
with its own sentence, so a failure says *which* check failed:

1. **Provenance** — both assets came from `https:` (a redirect to plain http is
   refused too), and they are named exactly as the version being installed
   names them.
2. **Size** — the file is not the empty file a failed request leaves behind, it
   is inside `UpdateArtifactLimit.installerBytes` (256 MB), and its byte count
   is the one the release published.
3. **Digest** — its SHA-256 equals the digest in the `.sha256` asset **and**
   GitHub's own `digest` for the same asset. Both must exist and both must
   agree; a release publishing neither is refused rather than trusted.
4. **Signature** — `codesign --verify --deep --strict` passes, and the
   `TeamIdentifier` is `AppIdentity.updateTeamIdentifier`.
5. **Identity** — `CFBundleIdentifier` is `com.xvii.kurakura.vpn`, the version
   *inside* the image is the version the tag claimed, and it is newer than what
   is running.

Gate 4 is the trust anchor, and it is worth being explicit about why it is a
team id rather than Gatekeeper's verdict. This project holds no Developer ID
certificate and notarizes nothing, so `spctl` refuses every release it could
ever publish — the app cannot use it as a test. What *can* be insisted on is
that the application inside the image was signed by the same team that signs the
running app. `AppIdentity.updateTeamIdentifier` names that team, and it has to
keep matching `DEVELOPMENT_TEAM` in the Xcode project.

The digest is computed with **CryptoKit's SHA-256**, deliberately unlike the
FNV-1a hash used for rule-set cache filenames: a cache name only has to avoid a
collision, while this hash is the thing standing between a corrupted download
and `/Applications`.

## Installing

Where the app can write both the directory it sits in **and the bundle
itself**, it replaces itself: the disk image is mounted read-only at a private
0700 mount point, the app inside is copied out with `ditto` —
`FileManager.copyItem` can drop extended attributes and resource forks, and a
signature covers those, so the copy would fail its own verification — the
**copy** is verified again where it now sits, and only then is it swapped in
with `replaceItemAt`.

Where either write is missing, it does **not** elevate. It points the Finder at
the verified image and the user finishes the job. A self-updater that quietly
asks for an administrator password to replace itself is a self-updater that can
be talked into replacing anything.

Both writes, because `replaceItemAt` needs both, and the bundle's write bit is
the one that is easy to miss. It refuses a bundle that is not itself writable
with "You don't have permission to save the file “TurtleDiver” in the folder
“Applications”" even when the directory would have allowed the rename —
measured on a fixture, where the same `0555` bundle fails under
`replaceItemAt` and succeeds under `renamex_np(RENAME_SWAP)`. That distinction
is exactly the common case: a `.pkg` install is `root:wheel 0755` inside a
`/Applications` that is `root:admin` `drwxrwxr-x`, so the *directory* is
writable by an administrator and the *bundle* is not. Asking only about the
directory (which is what this check did until a fixture caught it) let that install past the
gate, and the swap then failed with a permission error where the reveal path
was the answer.

The swap is deliberately not used even though it would work: exchanging the two
entries leaves the old bundle at the staging path, and a bundle the user could
not write is a bundle the user cannot delete either ("“Old” couldn't be removed
because you don't have permission to access it"), so it would leave a hidden
`root`-owned directory in `/Applications` that only an administrator could
remove. Refusing up front is the honest trade.

On either path the mount is detached (twice, `-force` on the second try) and the
mount point removed, including when a gate refuses.

Where the files go:

- downloads: `~/Library/Application Support/TurtleDiver/Updates/`, created 0700
- mount points: a private 0700 directory in the system temporary directory

A refused file is deleted before the refusal is returned: a half-verified
installer left on disk is a file something else could be talked into using.

## Restarting

The app cannot relaunch itself — the process that has to be gone before the new
bundle runs is the one that would be doing the launching. So **Restart Now**
starts a small detached `/bin/sh` that polls `kill -0 <pid>` (bounded: 60 s of
0.1 s checks) and then runs `open -a <bundle>`, and then quits **through the
ordinary quit path**. The system proxy, the engine and the tunnel are torn down
exactly as on any other quit; the update does not get a faster exit.

The pid and the bundle path are passed as *arguments*, never interpolated into
the script text. A path is a path, and a substitution that can put a quote into
a shell script is a substitution that can run a command.

If the waiter cannot start, the app does not quit. An app that quits with
nothing arranged to reopen it leaves the user on an empty desktop, which is
worse than leaving them on the build they already have.

## While the VPN is connected

Installing means quitting, and quitting ends the tunnel — so a connected app
refuses to install, and says so. The button in that state reads **Disconnect and
Update…**, and the second click, **Disconnect and Install**, is the one that
disconnects and then installs. Two clicks, because the second one ends a
connection the user may have started for a reason.

## What it will not do

- **It will not download on its own.** The check runs at launch; the download
  runs on a click.
- **It will not install while the tunnel is up.**
- **It will not elevate to install itself.**
- **It will not run anything it downloaded.** The image is mounted read-only and
  one `.app` is copied out of it; an image holding two applications is refused
  rather than guessed at.
- **It will not accept a release it cannot verify.** No published checksum, no
  agreement between the two digests, a signature from another team, a different
  bundle identifier, or a version that is not newer — all refusals, each with
  its own sentence.

## Verifying it by hand

`docs/MANUAL_TEST_CHECKLIST.md` § 0e walks the check and § 0f the install. The
short version: a build older than the newest release is the only way to see an
offer at all, and `MARKETING_VERSION` is what the app compares — so a `2.1.0`
build can only ever read `UP TO DATE` while the newest release is `v2.1.0`. To
see the offer itself, build a copy that claims an older version (the
scratch-build recipe in § 0f); the feed, the gates and the install have also
been exercised against the real published release.

## The tests

- `Tests/TurtleDiverCoreTests/UpdateFeedTests.swift` — the release feed, and
  deciding what a release means.
- `Tests/TurtleDiverCoreTests/UpdateArtifactTests.swift` — the download and
  gates 1–3, with a stubbed transport.
- `Tests/TurtleDiverCoreTests/UpdateBundleTests.swift` — gates 4–5 and the
  install, with `hdiutil`, `codesign` and `ditto` scripted and the file-system
  work real.
- `Tests/TurtleDiverCoreTests/UpdateRelaunchTests.swift` — the shape of the
  relaunch command.
- `Tests/TurtleDiverAppTests/UpdateModelTests.swift` — the two questions the
  pane asks, and that a connected app refuses.
- `Tests/TurtleDiverAppTests/UpdateWiringTests.swift` — that the launch check is
  gated and off the main actor, that the install never runs on it, and that the
  pane offers nothing it cannot do.
