---
type: analysis
title: UI/UX Audit -- Distro List and Navigation
created: 2026-08-28
tags:
  - ui
  - ux
  - audit
  - phase-07
  - navigation
related:
  - '[[index]]'
  - '[[theme-and-locales]]'
  - '[[interaction-and-a11y]]'
  - '[[pro-surfaces]]'
---

# Distro list and navigation

The home screen: the distro list (`lib/components/list.dart`, `list_item.dart`), the
navigation pane (`lib/nav/panelist.dart`), and the app bar (`lib/nav/root_screen.dart`).
Walked live under the run configuration recorded in [[index]] -- debug build,
`WSLM_FORCE_PRO=true`, `en`/light, 1400x860 and 900x860, two real distros (`Ubuntu`,
`ai-workspace`). 26 findings, plus a short list of things that were checked and are fine.

Screenshots referenced by filename only; they live in `.maestro/screenshots/phase-07/`
and are **gitignored**. Severity: **blocker** / **major** / **nit**. Effort: **S** (under
an hour), **M** (half a day), **L** (a day or more).

## Findings

### LN-01 -- The distro name is truncated at half the row width

**major / S** -- `lib/components/list_item.dart:88-110` -- `18-list-1400x860-long-name.png`,
`19-list-900x860-long-name-narrow.png`

The row header is `Row(spaceBetween, [Expanded(name), SizedBox(8), Flexible(size)])`.
`Expanded` and `Flexible` both default to `flex: 1`, so `Row` splits the free space
**50/50** before either child is laid out. The size string ("1.65 GB", ~55 px) therefore
reserves half the row, and the name -- given a *tight* constraint by `Expanded` -- is
ellipsised at exactly the halfway point no matter how much room is actually free.

Measured at 1400x860: header content spans x=286..1329 (1043 px, minus the 8 px gap =
1035); the name ellipsises at x=803, i.e. 512 px, and the size label does not start until
x=1283. **480 px of empty space sits between the "..." and the text it was truncated
for.** The same 50/50 split reproduces at 900x860 (704 px available, name cut at 347 px).

Fix: drop the `Flexible` (a bare `Text` is already as small as it wants to be), or give
the trailing a much smaller flex.

### LN-02 -- Running and stopped rows do not line up

**major / S** -- `lib/components/list_item.dart:70-87` -- `10-list-1400x860-home.png`,
`11-list-1400x860-row-hover.png`

The leading `Row` holds a Start button always and a Stop button only while the distro is
running; the stopped placeholder is `const Text('')`, which has zero width. So a running
row's title starts ~30 px to the right of a stopped row's, in the same list, in the same
frame -- visible directly in `10-list-1400x860-home.png` ("Ubuntu" at x=291,
"ai-workspace (running)" at x=321).

Worse, it is not static: when a distro starts or stops, the 5-second poll flips the branch
and **the name jumps sideways**. Captured accidentally but exactly between
`10-list-1400x860-home.png` and `11-list-1400x860-row-hover.png`, where `ai-workspace`
stopped on its own between two screenshots taken seconds apart.

Fix: reserve the slot -- render a disabled/invisible Stop button or a fixed-width
`SizedBox` instead of `Text('')`.

### LN-03 -- Opening the AI panel silently collapses every expanded row

**major / S** -- `lib/screens/home_screen.dart:109` --
`15-list-expanded-before-aitoggle.png`, `16-list-expanded-after-aitoggle.png`

`key: (GlobalVariable.infobox = GlobalKey())` builds a **new `GlobalKey` on every
build** of `HomePage`. A changed `GlobalKey` forces Flutter to tear the whole subtree
down and rebuild it from scratch, so every piece of `State` under it -- the
`RecommendationsPanel` and the entire `DistroList` -- is discarded.

Reproduced: expand the `Ubuntu` row, click the AI chat toggle, and the row is collapsed
again (screenshots 15 -> 16, same session, one click apart). The list also re-runs its
`wsl --list` future from the loading state.

Source-derived side effect worth fixing at the same time: `DistroListState`'s
`reloadEvery5Seconds()` (`lib/components/list.dart:53-63`) is an unconditional `for (;;)`
loop with no break and no cancellation. It is `mounted`-guarded so a discarded state stops
calling `setState`, but the loop itself never terminates -- each teardown leaves another
5-second timer chain running for the life of the process. (Stated from the code; the
process-level effect was not measurable through `wsl.exe` process counts, which are too
noisy on this host to support a claim.)

### LN-04 -- Nine unlabelled icon buttons, with Delete in the middle of them

**major / M** -- `lib/components/list_item.dart:229-460` --
`12-list-1400x860-row-expanded.png`, `12b-list-actionbar-zoom.png`

Expanding a row reveals nine icon-only buttons, all the same size, weight and colour, in
one undifferentiated strip: save-as-template, open in Explorer, open in VS Code, copy,
rename, disk usage, cleanup, **delete**, settings. Nothing distinguishes the destructive
action -- no red, no separator, no gap, no confirmation cue in the affordance itself. It
sits between the broom (cleanup, which exports/re-imports the whole distro) and the gear
(settings), 32 px from each, both of which a user reaches for routinely.

Delete does open a confirmation dialog, so this is a mis-click-and-recover, not
mis-click-and-lose-data. It is still the wrong shape for a bank of nine identical targets.

Fix: separate the destructive actions (trailing group after a divider, or an overflow
menu), and give delete a red foreground.

### LN-05 -- One icon in the action bar is solid while the other eight are outlines

**nit / S** -- `lib/components/list_item.dart:281` -- `12b-list-actionbar-zoom.png`

`FluentIcons.visual_studio_for_windows` is a filled glyph. At 4x magnification it is
visibly the heaviest mark in the strip -- a black bowtie among eight thin outlines -- so
the eye lands on "Open with VS Code" first, which is not the most important action there.

### LN-06 -- Three of the nine icons do not read as their action

**nit / S** -- `lib/components/list_item.dart:238, 314, 349` -- `12b-list-actionbar-zoom.png`

- `FluentIcons.rename` renders as `=|)` -- an abstract mark with no relationship to
  renaming.
- `FluentIcons.hard_drive_group` renders as a stacked server rack, which reads as
  "servers", not "disk usage".
- `FluentIcons.save_template` (dotted-outline floppy) and `FluentIcons.copy` (two offset
  pages) have near-identical silhouettes at 16 px and sit four positions apart.

Combined with LN-04, the strip is only usable by hovering each button in turn.

### LN-07 -- The expanded row is 85% empty with no explanation

**nit / S** -- `lib/components/list_item.dart:188-228` -- `12-list-1400x860-row-expanded.png`

The expanded content is a `spaceBetween` row: quick actions on the left, the icon bar on
the right. With no snippets configured the left branch renders `const SizedBox()`, so
roughly 950 px of the 1150 px panel is blank. There is no hint that snippets exist, what
they are, or that the Snippets screen in the nav pane is what fills this space.

### LN-08 -- Icon sizes are inconsistent within a single row

**nit / S** -- `lib/components/list_item.dart:62, 78` vs `238, 265, 281, 300, 314, 349, 364, 418, 453`

The header Start/Stop icons use the default size; every action-bar icon is pinned to
`size: 16.0`. Same row, same control type, two sizes.

### LN-09 -- Hovering a row highlights a control 660 px away from the cursor

**nit / S** -- `lib/components/list_item.dart:52` -- `11-list-1400x860-row-hover.png`

The whole `Expander` header is the toggle target, but the only hover feedback is a
background on the chevron at the far right. With the cursor at x=700 the highlight appears
at x=1363. The row gives no indication that clicking it does anything.

### LN-10 -- The BETA badge covers the AI Workspace icon in compact mode

**major / S** -- `lib/nav/panelist.dart:52`, `lib/components/beta_badge.dart` --
`13-list-900x860-home-narrow.png`, `13b-list-compact-betabadge-zoom.png`,
`14b-compact-tooltip-zoom.png`

Below fluent_ui's 1008 px threshold the pane goes icon-only, and the `infoBadge` is
painted directly on top of the 48 px rail. At 6x magnification the yellow "BETA" pill
covers the robot icon's head entirely -- all that remains visible is two legs -- and the
pill itself is clipped left and right by the rail width.

In compact mode the icon is the *only* affordance, so the one nav entry whose icon has to
carry the whole label is the one that has its icon obliterated. The hover tooltip does
still read "AI Workspace" (`14b`), which is the only reason the entry is usable at all.

(Putting the badge in `infoBadge` rather than inside the title is correct and deliberate
-- see the comment at `panelist.dart:50-51` and the `PaneItem.title` note in `AGENTS.md`.
The bug is the badge's placement/size in compact mode, not the choice of slot.)

### LN-11 -- Snippets and Templates are indistinguishable at 16 px

**nit / S** -- `lib/nav/panelist.dart:26, 37` -- `13b-list-compact-betabadge-zoom.png`

`FluentIcons.file_code` and `FluentIcons.file_template` are both a page outline
distinguished only by a small interior mark. Adjacent in the pane, and in compact mode
there is no label to fall back on.

### LN-12 -- No visible keyboard focus indicator anywhere on the home screen

**major / M** -- `lib/components/list_item.dart`, `lib/nav/root_screen.dart:222-236` --
`17-list-tab-1.png` ... `17-list-tab-6.png`

Six consecutive Tab presses on the home screen produced **zero changed pixels** outside
the "(running)" label region (measured by pixel diff against the baseline capture: 202
identical diff pixels for every one of the six, all inside the x=288..460, y=130..144 box
where `ai-workspace`'s running suffix had changed).

The keystrokes are being delivered -- the same helper on the create screen produces a
visible focus ring on the first Tab (diff box x=246..882, y=160..294) and a second on the
next. So the home screen genuinely renders no focus affordance on the nav pane, the row
headers, the Start/Stop buttons, or the action bar.

A keyboard-only user cannot tell what is selected. Follows up in
[[interaction-and-a11y]].

> **Corrected by [[interaction-and-a11y]] (IA-01, IA-05, IA-07).** The observation is
> right and the diagnosis is not. Reading `FocusManager.instance.primaryFocus` over the
> VM Service during the same key sequence shows that **focus was not moving at all** --
> it sat on the `Root Focus Scope` for all six presses (and for twenty, when repeated),
> because Tab is inert until a click or a route change puts focus in the page scope. Once
> traversal is running, home *does* paint a focus ring: 268 changed pixels for a row and
> 552 for a button. The real defects are the dead keyboard (IA-01, blocker), the ring
> landing on the chevron 1,100px from the row it belongs to (IA-05), and the ring being
> one pixel thick (IA-07). Phase 08 should fix those rather than adding an indicator that
> already exists.

### LN-13 -- The back button is permanently disabled, inert, and looks enabled in dark mode

**major / S** -- `lib/nav/root_screen.dart:144-181` -- `22b-nav-backbutton-zoom.png`,
`24-nav-backbutton-clicked.png`, `26b-back-dark.png`

`enabled: widget.shellContext != null && router.canPop()` never evaluates true in
practice. Checked on `/` and on `/templates` (a route reached via `pushNamed`): the arrow
is greyed in both. Clicking it on `/templates` produced a **0-pixel** difference against
the pre-click screenshot -- it does nothing at all.

In dark mode it is worse: the `NavigationPaneTheme` override at `root_screen.dart:157-165`
resolves the disabled colour through `ButtonThemeData.buttonColor`, which on a dark
background is near-white. `26b-back-dark.png` shows the arrow rendered at the same
brightness as the app title -- a permanently dead control that reads as the most
prominent affordance in the app bar.

Also worth flagging to whoever fixes this: `RootPage.build` calls `setState()` *from
inside `build`* (`root_screen.dart:136-138`) as part of the same back-button logic.

Fix: either make it work or remove it, and stop overriding the disabled colour.

### LN-14 -- "Dark Mode" is a hardcoded English string

**major / S** -- `lib/nav/root_screen.dart:212` -- `25-nav-dark-mode.png`

`content: const Text('Dark Mode')`. It is the only always-visible label in the app bar and
it is untranslated in all nine locales, in violation of the project's own "do not hardcode
user-facing strings" rule. Follows up in [[theme-and-locales]].

### LN-15 -- Nav pane label capitalisation drifts

**nit / S** -- `lib/i18n/en.json` -- `10-list-1400x860-home.png`

Title Case: "Add an Instance", "Mount Disk". Sentence case: "Distro packages", "Sponsor
this project", "About this app", "Upgrade to Pro". Windows/Fluent convention is sentence
case throughout; the two Title Case entries are the outliers and sit next to each other in
the pane.

### LN-16 -- Two nav entries open modals but look like destinations

**nit / S** -- `lib/nav/panelist.dart:82-90, 148-156` -- `23-nav-mountdisk-action.png`

"Mount Disk" and "About this app" are `PaneItem`s whose `onTap` opens a dialog rather than
navigating. They are pixel-identical to the seven real destinations, and clicking one
correctly leaves the selection where it was -- so the user clicks a nav item, the
selection stays on Templates, and a modal appears over everything.

fluent_ui has `PaneItemAction` for exactly this, and the codebase already knows about it:
`_calculateSelectedIndex` (`root_screen.dart:121-129`) filters `PaneItemAction` out of the
numbering, and Sponsor/Documentation already use the `LinkPaneItemAction` subclass.

### LN-17 -- The list error state dumps a raw exception in untranslated English

**major / S** -- `lib/components/list.dart:129-163` -- `21-list-remote-error.png`

Forced by pointing `RemoteWSLTarget` at an unreachable host. The screen renders:

> Remote WSL connection failed (audit@127.0.0.1).
> **Exception: Host key verification failed.**
> [ Retry ] [ Diagnose with AI ]

Three problems in three lines:

1. `Exception: ` is Dart's `Exception.toString()` type prefix leaking verbatim into the
   UI, complete with the bare colon.
2. `'Remote WSL connection failed (...)'`, `'Failed to load WSL distros.'` and `'Retry'`
   are hardcoded English literals (`list.dart:137, 138, 154`) -- no `.i18n()`.
3. The error is styled as plain body text. fluent_ui's `InfoBar` exists for this.

### LN-18 -- The error state offers no remedy and no way out

**major / M** -- `lib/components/list.dart:128-163` -- `21-list-remote-error.png`

"Host key verification failed" has one specific fix (accept/refresh the host key), and the
UI offers none of it. "Retry" re-runs the identical command and will fail identically
forever. Nothing links to Settings, where the `UseRemoteWSL` toggle that caused this
lives, so the error takes over the entire home screen with no route back to local WSL --
the user has to know to open the nav pane and hunt for the setting.

### LN-19 -- "Diagnose with AI" is offered to free users, then refuses

**nit / S** -- `lib/components/list.dart:157`, `lib/components/ai_diagnosis.dart:13-17` --
`21-list-remote-error.png`

`AiDiagnoseButton` renders unconditionally. A free user hits an error, sees the one button
that looks like it might explain it, clicks, and gets an upsell toast
(`upgrade-prompt-error`). Attaching a Pro nag to a failure state is the least sympathetic
moment to do it. Either gate the button on `isPro` or say up front what it needs.
Cross-listed to [[pro-surfaces]].

### LN-20 -- Loading is top-anchored, results are centred, so the screen jumps

**nit / S** -- `lib/components/list.dart:166-183` -- `20-list-remote-loading.png`,
`21-list-remote-error.png`

The data and error branches return `Expanded`, so their content is centred in the list
area. The loading branch returns a bare `Padding` + `Center`, which has no height to
centre within -- the spinner renders at y=90 and the error that replaces it appears at
y=420. Content moves 330 px when the load resolves.

The same branch also carries a hardcoded English string ("Connecting to remote WSL host
...") and offers no cancel; with no `ConnectTimeout` in `getSshClientOptions`
(`lib/api/shell.dart:6-27`) an unreachable host holds this spinner for the OS default TCP
timeout with no way to abort.

### LN-21 -- Empty state: the CTA and the AI chat button occupy the same corner

**major / S** -- `lib/components/list.dart:91-107` vs `lib/screens/home_screen.dart:146-149`
-- *source-derived, not screenshotted*

The zero-distro CTA is `Positioned(right: 20, bottom: 20)` inside a `Stack` that fills the
list area; the Pro AI chat FAB is `Positioned(right: 16, bottom: 16, child: 48x48)` inside
a `Stack` that fills the home body. Both `Stack`s are flush with the bottom-right of the
same rectangle (`DistroList` returns the `Expanded` that ends the body `Column`), so the
FAB covers a ~44x28 px region of the CTA's lower-right corner -- including the point a
user clicks after reading "no instances found".

Marked source-derived deliberately: the empty state cannot be reached on this host without
deleting the real distros, and `HomePage` constructs its own `WSLApi()` with no injection
seam, so it cannot be faked in a widget test either. The geometry is unambiguous; the
screenshot is not available. Recorded in the "not examined" list in [[index]].

### LN-22 -- The empty-state copy describes two unrelated states and gives no next step

**major / S** -- `lib/i18n/en.json` (`noinstancesfound-text`), `lib/components/list.dart:89`

> "No instances found or there is a migration in progress"

Written from the code's point of view, not the user's. It presents an ordinary first-run
state and a rare mid-move state as one sentence; "migration" is not a word the UI uses
anywhere else; and it tells a brand-new user nothing about what to do. This is the first
screen anyone sees after installing.

### LN-23 -- A truncated distro name cannot be read in full

**nit / S** -- `lib/components/list_item.dart:92-100` -- `19-list-900x860-long-name-narrow.png`

Ellipsising is correct (see "Verified" below), but there is no `Tooltip` on the header
text, so with two similarly-prefixed names the only way to tell rows apart is to open the
Rename dialog. Especially sharp given LN-01 cuts names at half width.

### LN-24 -- The AI chat button is nearly invisible in both themes

**nit / S** -- `lib/screens/home_screen.dart:163-171` -- `10-list-1400x860-home.png`,
`26-list-1400x860-home-dark.png`

Inactive fill is `Colors.grey.withValues(alpha: 0.12)` with a `Colors.white` @ 0.1 border
-- two hardcoded colours, neither theme-aware. On the light background it is a faint grey
disc; on the dark background it is a slightly-less-dark disc with an invisible border. It
is the sole entry point to a headline Pro feature. The panel divider at
`home_screen.dart:133` is a hardcoded `Colors.grey` too. Cross-listed to
[[theme-and-locales]] and [[pro-surfaces]].

### LN-25 -- The size column is unlabelled and unexplained

**nit / S** -- `lib/components/list.dart:120`, `lib/components/helpers.dart:435-449` --
`10-list-1400x860-home.png`

Each row ends in a bare "1.65 GB". No column header, no tooltip, nothing saying it is the
`ext4.vhdx` file's size on disk (the high-water mark, not the space in use -- the very
distinction `AGENTS.md` records as a recurring support question). `getInstanceSize` also
returns `''` on any failure, so the number silently disappears rather than saying why.

### LN-26 -- Start stays enabled, and still says "Start", on a running distro

**nit / S** -- `lib/components/list_item.dart:56-69` -- `10-list-1400x860-home.png`

A running distro shows Start and Stop side by side, both enabled, Start still tooltipped
"Start". Pressing it opens another terminal window -- a reasonable thing to want, but not
what the label promises, and there is no other affordance for "open a shell here".

## Verified -- checked and fine

Recorded so the audit does not read as a list of everything that was looked at.

- **The 5-second poll does not flicker.** Thirteen captures one second apart with no
  interaction: **0 changed pixels** in the list region (x=230..1390, y=50..200) across all
  twelve intervals. The layout movement in LN-02 happens only when the running set
  actually changes, not on every poll.
- **Long names ellipsise cleanly.** A 97-character display name renders as
  `Ubuntu-24.04-LTS-development-environment-with-a-really-long-descriptive-nam...` at both
  widths -- no overflow stripe, no wrap, no clipped glyph (`18`, `19`). The complaint is
  LN-01's premature cut, not the truncation mechanics.
- **Every `PaneItem.title` is a literal `Text`.** All twelve entries in `panelist.dart`
  satisfy the invariant fluent_ui silently requires; labels render in open mode (`10`) and
  the tooltip carries the label in compact mode (`14b`). The "NEW" badge on the free-tier
  License entry and the BETA badge both use `infoBadge`, not a composite title.
- **Nav selection tracks the route.** `_calculateSelectedIndex` matched `/templates`
  correctly (`22`), and every route in `router.dart` has a corresponding `PaneItem` key,
  so the `index == -1 ? 0` fallback (which would silently highlight Home) is not reachable
  today. It stays a latent trap for anyone adding a route without a pane key.
- **Opening a modal from the pane leaves the selection alone** (`23`) -- correct
  behaviour, even though the entry should be a `PaneItemAction` (LN-16).
- **The theme toggle applies instantly** with no restart and no flash of the old theme
  (`25`, `26`).
- **No framework errors.** The full `flutter run` log for the click-through contains no
  exceptions, no `RenderFlex overflowed`, and no `setState() called during build`
  assertion -- despite LN-13's note.

## Not examined in this pass

- **The zero-distro empty state, live.** Reaching it means deleting the host's real
  distros; `HomePage` builds its own `WSLApi()` with no injection seam, so it cannot be
  substituted in a widget test either. LN-21 and LN-22 are recorded from source.
- **Docker container rows** (`showDocker` preference) -- no Docker containers on this
  host.
- **The `wslNotInstalled` branch** (`list.dart:113-115`, renders `InstallDialog`) -- WSL is
  installed here.
- **The quick-actions dropdown with snippets configured** -- none are configured, so only
  the empty branch (LN-07) was seen.
- **The remote WSL happy path** -- needs a second Windows host; see [[index]].
