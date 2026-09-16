# Screenshots

Captures of the running app, kept small and few. They are documentation: a
pane's *shape* is easier to check against a picture than against a paragraph.

| file | what it shows |
|---|---|
| `setup-pane.png` | Settings ▸ Setup on a machine with every tool installed — four rows, resolved paths, version pills from each tool's own `--version`, `ALL INSTALLED`, and the install card |

## What does *not* belong here

The window is normally full of the user's own network: the VPN host, the
corporate proxy addresses, the request hosts in the Recent Requests table, and
`/Users/<name>` in every revealed path. Those captures are useful while
verifying a change but they are not repository content — this repo has a public
remote, and git history is not a thing you can take back. Crop to the pane that
is being documented, and if the pane itself carries those values, do not commit
the capture at all: describe the check in
[`docs/MANUAL_TEST_CHECKLIST.md`](../docs/MANUAL_TEST_CHECKLIST.md) instead,
which is what that file is for.

Recapture with the app frontmost:

```sh
screencapture -x -o /tmp/shot.png                 # full screen
sips -c <h> <w> --cropOffset <y> <x> /tmp/shot.png --out screenshots/<name>.png
```

The window's own frame comes from an Accessibility dump or from
`CGWindowListCopyWindowInfo`; the display is 1800×1169 pt at scale 2, so pixel
coordinates are exactly twice the pt ones. Note that `screencapture -l <window
id>` is unreliable on macOS 26 — crop a full-screen capture instead.
