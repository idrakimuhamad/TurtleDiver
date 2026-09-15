# Settings window geometry (1.4.0)

The Settings window is a `NavigationSplitView` in a `NSWindow` whose content is
860×620 (min 800×560) with `.unifiedCompact` chrome. Three pieces of its
geometry are load-bearing enough to be worth writing down, because all three
were wrong once and all three are easy to "fix" back into being wrong.

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

**The spacer must have its background switched off.** macOS 26 gives every
toolbar item a glass capsule background by default, and a 1×30 pt capsule draws
as a pair of hairlines standing in the titlebar — it looks like a rendering
glitch and it is easy to misread as something the window is drawing around the
item rather than the item itself. The documented way out is
`sharedBackgroundVisibility(.hidden)` on the `ToolbarItem`
(`@available(macOS 26.0, *)`, hence the branch in `detailPane`; on macOS 14/15
there is no capsule and the item is invisible as written). The item still
contributes its height, so the floor is unchanged.

Measured after that change, with the window at (470, 157) 860×660 — sidebar rows
`AXOutline` and pane headers from the accessibility tree, all ten panes,
`SettingsToolbarSpacer` present and unbordered:

| | sidebar `VPN` row y | pane header y |
|---|---|---|
| every pane (VPN, Profiles, Dashboard, Policies, Rules, Routing, Rule Sets, History, Appearance, Advanced) | 294 | 215 |

294 is also what the *previous* build measured, so hiding the capsule changed
the appearance and nothing else.

The two facts that made this hard to diagnose, in case it comes up again:
the mark follows the item when you move it (it *is* the item's background, not
a decoration around it), and it is new on macOS 26 only (the capsule is).

Measured with the window at (470, 157) 860×660, sidebar and search-field frames
taken from the accessibility tree (`AXOutline` / `AXTextField`):

| pane | sidebar y | search y | pane header y |
|---|---|---|---|
| VPN, Profiles, Dashboard, Rules, Routing, History, Appearance, Advanced | 243 | 206 | 215 |
| **Policies** | **215** | **178** | **187** |

(Those Policies numbers were measured before the fix in §3; the nine panes now
measure the first row.)

## 3. The Policies pane's minimum height

The Policies pane used to be the odd one out: its pane header and the whole
sidebar sat **28 pt higher** than on the other eight panes, the sidebar's search
field was tucked under the titlebar, and the footer's second line fell past the
bottom edge.

### What it looked like

The window frame stays 860×660 whatever the pane; what changed was the split
view inside it (measured from the accessibility tree):

| pane | window | `AXSplitGroup` | overhang per side |
|---|---|---|---|
| the other eight | 860×660 | 860×620, flush with the content area | 0 |
| **Policies** | 860×660 | **860×676**, centred | **28** |

676 was a hard minimum, not a proportion — resizing the window did not move it,
it only grew once the window was tall enough to fit it:

| window size | content area | Policies split group | overhang per side | other panes' split group |
|---|---|---|---|---|
| 860×600 | 560 | **676** | 58 | 560 |
| 860×660 | 620 | **676** | 28 | 620 |
| 860×700 | 660 | **676** | 8 | 660 |
| 860×803 | 763 | 763 (fits, so it stretches) | 0 | 763 |

Because the minimum is bigger than the container, `.frame(minWidth: 780,
minHeight: 560)` centres it instead of clipping it from one edge — which is why
the overhang was split evenly top and bottom, and why the search field ended up
*drawn behind* the toolbar rather than cut off at a clean edge.

### The cause

Not the pane's content. Replacing `PoliciesView()` with a two-word
`List { Text(…) }` reproduced 676 exactly, and the other eight panes stayed at
620 — so the trigger is in the **shared pane header**, and it fires for
whichever pane is on screen during the window's first layout pass (in practice
the persisted one, which is why Policies looked like it was at fault: it was
the pane selected when the window was created).

`SettingsPaneHeader`'s subtitle carried
`.fixedSize(horizontal: false, vertical: true)`. The window's very first layout
pass proposes a degenerate width, and that modifier answers a degenerate width
by unfolding the sentence to one line per word instead of truncating it. The
pane then reported that height as its minimum, the split view was laid out at
676, and the *list* then reported the height it was handed as *its* minimum —
so 676 survived every later pass, including the ones at the correct width.

### The fix

The subtitle is now `.lineLimit(2)` with no vertical `fixedSize`: it can still
wrap to two lines on a narrow window, but it can never inflate the pane's
minimum height, so no minimum can be locked in the first place. Verified by the
test above: with **Policies** persisted, a fresh launch and the Settings window
opened for the first time, `AXSplitGroup` is 860×620 at the content top, and all
nine panes now measure identically (the sidebar's `AXOutline y` and the search
field's `AXTextField y` match on every pane).

Re-verify after touching `SettingsPaneHeader` or the pane shell: pick a pane,
quit, relaunch, open Settings, and check that `AXSplitGroup`'s `y` is 40 pt
below the window's `y` and its height is the window's minus 40 — on the pane you
left selected, and then on all nine.
