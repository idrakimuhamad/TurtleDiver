# Settings window geometry (1.4.0)

The Settings window is a `NavigationSplitView` in a `NSWindow` whose content is
860×620 (min 800×560) with `.unifiedCompact` chrome. Two pieces of its geometry
are load-bearing enough to be worth writing down, because both were wrong once
and both are easy to "fix" back into being wrong.

## 1. Sidebar width

The sidebar's width is derived from the search field, not from the longest pane
name — the field is the widest thing in the column that cannot compress.

| piece | pt | why |
|---|---|---|
| `searchFieldContentWidth` | 121 | magnifier + "Search settings" at the field's font, measured on screen |
| `searchFieldTrailingReserve` | 20 | room macOS reserves for the clear button |
| `searchFieldAir` | 11 | so the placeholder does not look jammed against that reserve |
| `fieldInset` × 2 | 20 | the field's own inset inside the column |
| **`minWidth`** | **172** | |

`idealWidth` is 196 (where the window opens) and `maxWidth` is 320. At 144 pt —
what the window used to open at — the placeholder clipped to `Search setting:`.

Two things have to stay true or the width drifts back to 144:

1. `.navigationSplitViewColumnWidth(min:ideal:max:)` must be the **outermost**
   modifier on the sidebar. `.searchable(placement: .sidebar)` rebuilds the
   column's chrome and swallows the preference if it is applied underneath.
2. The footer asks for `SettingsSidebar.footerMinWidth`
   (`minWidth - 2 × footerPadding`), so the column's fitting width cannot pull
   it back under the minimum.

The sidebar cannot be collapsed: `columnVisibility` is bound and forced back to
`.all`, the way System Settings does not let you lose its sidebar. Dragging the
divider shut used to hide it with no obvious way back.

## 2. Titlebar height

The sidebar spans the full height of the window, so **anything that changes the
titlebar's height moves the pane header _and_ the sidebar**, which reads as the
whole window jumping when you switch panes. `SettingsStyle.paneTopPadding`
(18 pt, shared by `SettingsPane` and `SettingsListPane`) and
`SettingsToolbarSpacer` (an invisible 1×30 pt item in the detail column's
toolbar) exist to keep that constant.

Measured with the window at (470, 157) 860×660, sidebar and search-field frames
taken from the accessibility tree (`AXOutline` / `AXTextField`):

| pane | sidebar y | search y | pane header y |
|---|---|---|---|
| VPN, Profiles, Dashboard, Rules, Routing, History, Appearance, Advanced | 243 | 206 | 215 |
| **Policies** | **215** | **178** | **187** |

### Open issue

The Policies pane's chrome is 28 pt shorter — exactly the height of a toolbar
item row — so its pane header and the sidebar sit 28 pt higher, and the
sidebar's search field ends up tucked under the titlebar. It is not caused by
the pane's own toolbar items (removing them changes nothing) and it is not
caused by the spacer's height (30 pt and 60 pt measure identically). The most
likely explanation is that `.unifiedCompact` decides per pane whether the
sidebar's search field shares the title row or gets its own row, and that
decision is not stable across runs: an earlier build of this same window
measured *three* chrome heights (76 / 78 / 86 pt) across the nine panes.

Reproduce with `swift test`'s neighbours: build, open Settings, and compare
`AXOutline label="Sidebar"`'s `y` on Policies and on Routing. If it still
differs, the deterministic fixes to try, in order of preference, are

1. `window.toolbarStyle = .expanded` — AppKit then always gives the toolbar its
   own row, at a constant height, whatever the pane declares;
2. rendering our own search field inside the sidebar column instead of using
   `.searchable(placement: .sidebar)`, which removes the one item that forces a
   second toolbar row.

Both change how the window looks, so neither should be landed blind.
