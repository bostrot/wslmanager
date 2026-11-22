---
type: analysis
title: UI/UX Audit -- Interaction and Accessibility
created: 2026-08-28
tags:
  - ui
  - ux
  - audit
  - phase-07
  - accessibility
  - keyboard
related:
  - '[[index]]'
  - '[[list-and-navigation]]'
  - '[[create-and-install]]'
  - '[[settings-and-tools]]'
  - '[[pro-surfaces]]'
  - '[[theme-and-locales]]'
---

# Interaction and accessibility

The app driven with the keyboard instead of the mouse, then every icon-only control,
every long-running operation and every error string checked for whether it tells the
user anything. Walked live under the run configuration in [[index]]: debug build,
`WSLM_FORCE_PRO=true`, 1400x860, two real distros (`Ubuntu`, `ai-workspace`) plus one
throwaway (`AuditKb`) created and deleted during the pass.

**22 findings (IA-01..IA-22)**, plus a set of verified passes -- including the answer to
the task's headline question, which is *yes, but*.

Screenshots are referenced by filename only; they live in
`.maestro/screenshots/phase-07/` and are **gitignored**. Severity: **blocker** /
**major** / **nit**. Effort: **S** (under an hour), **M** (half a day), **L** (a day or
more).

## How this pass was run

**Focus was read, not guessed.** Tab order cannot be audited from screenshots in an app
whose focus indicator is a one-pixel hairline, and [[list-and-navigation]]'s LN-12
("six Tabs, zero pixels changed") turns out to be measuring a *different* defect than it
names. So this pass attached to the running debug build over the Dart VM Service and read
`FocusManager.instance.primaryFocus` directly after every keystroke.

`Working/focus_probe.dart` (new) connects to the `ws://` URI that `flutter run` prints,
evaluates an expression in the app's own isolate, and prints the result. The expression it
runs by default (`Working/focus_label.txt`) walks up from the focused node to the nearest
`Tooltip` message or `ValueKey` and down to the first `Text` or `Icon`, so a tab stop is
reported as something a human recognises:

```
tab  2 : Focus :: key[test-listitem-start] tip[Start] key[test-distro-list] :: icon[IconData(U+0E768)]
```

Two things about it are worth keeping:

- The VM Service truncates `valueAsString` at 128 characters. The first version of the
  probe silently lost half of every answer; it now re-fetches with `getObject` when
  `valueAsStringIsTruncated` is set.
- `main.dart`'s library scope has `WidgetsBinding` and `RenderBox` but **not**
  `BoxHitTestResult`, so a hit test does not compile there. `--lib=widgets/binding.dart`
  evaluates inside a framework library that imports `rendering`, which is what made IA-02
  measurable rather than assertable.

**The semantics sweep is a count, not an impression.** `Working/a11y_audit.dart` (new)
walks `lib/` with a brace-balanced scanner and reports, for every `IconButton`, every
icon-only `Button`/`FilledButton`/`HyperlinkButton` and every `GestureDetector`, whether
the enclosing 400 characters contain a `Tooltip(` **and** a `MergeSemantics(`. Per
AGENTS.md only the pair gives the control an accessible name: fluent_ui's `Tooltip` cannot
label a `BaseButton`, because `IconButton` opens its own semantics container. Its second
mode (`--messages`) does the same for `Notify.message` call sites. Both outputs are in
`Working/phase-07-task07-semantics.txt` and `-messages.txt`.

**`Working/diffbox.ps1` (new) answers *where*, not *how many*.** `diff.ps1` from the
earlier passes counts changed pixels, and "552 changed pixels" is either a 2px outline
round a button or a smudge -- the count cannot tell them apart. `diffbox.ps1` returns the
bounding box as well, which is what turned IA-05 from an impression into
`(1347,65)-(1380,98) = 34x34`.

**One throwaway distro was created and destroyed by keyboard only.** A 200-byte rootfs
tarball (`etc/os-release` and nothing else) made create-and-delete a seconds-long
operation instead of a multi-gigabyte one, so the whole lifecycle could be driven with
Tab and Enter and then measured. `AuditKb` was created, started, stopped and deleted
entirely from the keyboard; afterwards `wsl --list` was re-checked, the empty GUID
directory WSL leaves behind under `%LOCALAPPDATA%\wsl` was removed, and the tarball
deleted.

## Findings

### Keyboard reachability

#### IA-01 -- Tab does nothing until the user clicks something, and every window switch breaks it again

**blocker / M** -- `lib/nav/root_screen.dart:230` -- `301-a11y-tab00.png` ..
`301-a11y-tab20.png`

From a cold launch, **20 Tab presses changed 0 of 1,204,000 pixels** and
`primaryFocus` never left `Root Focus Scope`. That is not "the focus ring is invisible" --
focus is genuinely not moving. The root scope has 23 traversal descendants at that moment,
all reachable; Tab simply does not enter them.

This is a *state*, not a start-up quirk, and it recurs. Measured:

| | `primaryFocus` |
|:---|:---|
| A. after two clicks and two Tabs | `test-listitem-start` / `tip[Start]` |
| B. after `Shell.MinimizeAll()` + restore + refocus | **`Root Focus Scope`** |
| C. three further Tabs | `Root Focus Scope`, `Root Focus Scope`, `Root Focus Scope` |

So alt-tabbing away from the app and back destroys keyboard navigation. There is no
keyboard-only way out: **shift+tab, F6, Down, Right, Enter, Space, Ctrl+Tab, Ctrl+F, Esc
and Home were each tried from the dead state and none moved focus.** (Ctrl+F is the
fluent_ui search shortcut and `root_screen.dart:253` wires `onOpenSearch` to a focus node,
but the pane has no `autoSuggestBox`, so there is nothing to focus.)

The two things that *do* restore traversal are a mouse click on a focusable control and a
**route change** -- navigating to a different page hands focus to the new route's
`_ModalScopeState Focus Scope`, and Tab works from there. Clicking the already-selected
nav item does not count: it is not a route change, and focus stays at the root.

Fix: request focus for the page scope when the shell builds a body and on
`onWindowFocus`, e.g. a `FocusScope` in `paneBodyBuilder` that takes focus if
`primaryFocus` is the root scope. `RootPageState` already implements `WindowListener`
(`root_screen.dart:37`) for geometry, so the hook exists.

#### IA-02 -- An invisible status bar sits on every screen, takes a tab stop and eats mouse clicks

**major / S** -- `lib/components/notify.dart:27`, `lib/nav/root_screen.dart:230` --
`362-a11y-no-status-message.png`

`statusBuilder` always builds the `InfoBar` and hides it with
`AnimatedOpacity(opacity: status != '' ? 1.0 : 0.0)`. `RenderAnimatedOpacity` does not
consult opacity when hit-testing, and a zero-opacity subtree is still focusable.

Measured with **no message showing**, at 1400x860:

| | |
|:---|:---|
| InfoBar rect | `Offset(746.0, 786.0)`, `Size(126.0, 62.0)` |
| its Close button | `Offset(831.0, 801.0)`, `Size(32.0, 32.0)` |
| tab stop | **6 of 21** on home; the capture before and after differs by **0 px** |

And it really does intercept the pointer. Hit test on the running app at 700px wide, where
the bar is centred on x=350:

```
(350, 817) -> RenderDecoratedBox > RenderConstrainedBox > RenderAnimatedOpacity > RenderPadding
(350, 780) -> RenderPointerListener > RenderSemanticsGestureHandler > ... > _RenderScrollSemantics
```

37 pixels apart: inside the invisible bar the topmost target is the bar; outside it, the
page. So there is a permanent ~126x62 dead zone at the bottom centre of every screen, plus
a tab stop that gives a keyboard user no feedback whatsoever. Related but not the same as
CI-24, which is about the bar when it *is* visible.

Fix: wrap the whole thing in `if (status != '') ...`, or use `Visibility`/`Offstage` rather
than `AnimatedOpacity` (or at minimum `IgnorePointer` + `ExcludeFocus` when empty).

#### IA-03 -- The permanently disabled back arrow is a tab stop on every screen

**major / S** -- `lib/nav/root_screen.dart:143-152` -- `301-a11y-tab07.png`

`enabled = widget.shellContext != null && router.canPop()`. Every nav destination is a
`go()` on the shell route, so `canPop()` is always false and the arrow is permanently
disabled and inert -- that part is LN-13. What is new is that it is still in the keyboard
order: **stop 7 of 21 on home and stop 10 of 24 on the create screen**, focused as
`icon[IconData(U+0E72B)]` with no tooltip and no label. A keyboard user lands on a dead
control on every single screen and Enter does nothing.

#### IA-04 -- Three interactive controls are `GestureDetector`s and cannot be reached or activated by keyboard at all

**major / S** -- `lib/screens/home_screen.dart:152`, `lib/components/pro_badge.dart:108`,
`lib/components/recommendations_panel.dart:92` -- `300-a11y-home-baseline.png`

`GestureDetector` has no focus node, no `Shortcuts`/`Actions` binding and no semantics
action. None of the three appears anywhere in the measured 21-stop home cycle or the
24-stop create cycle:

| Control | Where | What a keyboard user loses |
|:---|:---|:---|
| AI Assistant FAB | `home_screen.dart:152` | The **only** entry point to the AI chat panel |
| "Upgrade" link in the Pro badge | `pro_badge.dart:108` | The upsell's only call to action |
| "Go to Templates" / "Go to Settings" | `recommendations_panel.dart:92` | The recommendation's action |

The FAB is the serious one: it is already the app's least visible control
([[pro-surfaces]] measured it at **1.29:1**), and it turns out to also be unreachable
without a mouse. All three are one-line fixes -- `Button`/`IconButton`/`HyperlinkButton`
instead of `GestureDetector` -- and the last two look like hyperlinks (underlined, accent
coloured) while `HyperlinkButton` exists and is used elsewhere.

#### IA-05 -- Tab order runs content -> app bar -> nav pane, the reverse of reading order, and the row stop lights a control 1,100px away

**major / M** -- `lib/nav/root_screen.dart:222` -- `320-a11y-focusring-t01.png`,
`322-a11y-rowfocus-chevron-zoom.png`

The measured home cycle, with two distros:

| # | Stop | # | Stop |
|:---|:---|:---|:---|
| 1 | Ubuntu row (expander) | 12 | Templates |
| 2 | Ubuntu **Start** | 13 | AI Workspace |
| 3 | ai-workspace row | 14 | Add an Instance |
| 4 | ai-workspace **Start** | 15 | Distro packages |
| 5 | ai-workspace **Stop** | 16 | Mount Disk |
| 6 | *invisible status-bar Close* (IA-02) | 17 | License |
| 7 | *disabled back arrow* (IA-03) | 18 | Sponsor this project |
| 8 | Report a bug | 19 | Settings |
| 9 | Dark Mode | 20 | Documentation |
| 10 | Home | 21 | About this app |
| 11 | Snippets | | *wraps to 1* |

Two problems. The nav pane is the first thing on screen and the **last** thing in the tab
order, after the content and the app bar. And stop 1 -- "the row" -- is the `Expander`'s
header, whose focus ring is drawn around the **chevron at x=1347**, 1,100px to the right of
the distro name it belongs to. Measured: focusing the row changes 268 px, all of them in a
34x34 box at `(1347,65)-(1380,98)`. The ring then jumps back to the left edge for stop 2,
right again for stop 3. This is the focus twin of LN-09, which found the same thing for
hover.

#### IA-06 -- Two focus rings are lit at once on a distro row

**major / S** -- `lib/components/list_item.dart:51`, `:55` --
`340-a11y-kb-auditkb-start-focused.png`, `342-a11y-doublering-before.png`

The Start and Stop buttons live in the `Expander`'s `leading:` slot, i.e. *inside* the
expander header's own `HoverButton`. With `primaryFocus` confirmed to be
`test-listitem-start`, the chevron's ring stays drawn as well: the crop shows a ring round
the play icon at the left edge **and** a ring round the chevron at the right edge of the
same row. A keyboard user cannot tell which one Enter will hit -- and the two do very
different things (start the distro vs expand the row).

#### IA-07 -- The focus indicator is a one-pixel hairline

**nit / S** -- fluent_ui `FocusBorder` default -- `354-a11y-dialog-delete-focused.png`,
`356-a11y-dialog-buttons-deletefocus-zoom.png`

Where a ring is drawn at all it is legible but very thin. Sampled across the left edge of
the focused Delete button in the confirmation dialog:

```
focused:   #F3F3F3  #D9D9D9  #9D9D9D  #494949  #E7B3B8  #CE0F1F   <- one dark pixel + 2px anti-aliasing
unfocused: #F3F3F3  #F3F3F3  #F3F3F3  #F3F3F3  #E7B3B8  #CE0F1F
```

`#494949` on `#F3F3F3` is **8.12:1**, so contrast is not the problem -- thickness is.
WCAG 2.2's Focus Appearance (2.4.13) asks for at least the area of a 2px perimeter. A whole
button's ring is 552 changed pixels; a row's is 268. Worth setting a wider `FocusThemeData`
once, app-wide, rather than per control.

#### IA-08 -- The delete confirmation puts the destructive button first in the tab order

**major / S** -- `lib/dialogs/base_dialog.dart:60-80` --
`352-a11y-kb-delete-dialog.png`

Opening the dialog leaves focus on the scope, not on a button. The first Tab lands on
**Delete**; the second on Cancel; the cycle is those two and nothing else. So the natural
keyboard reflex on a modal -- Tab, Enter -- destroys the distro. The convention on a
destructive confirmation is the opposite: focus the safe action, and make the destructive
one deliberate. (Esc *does* cancel -- see the verified passes.)

### Accessible names

#### IA-09 -- 22 of the app's 38 tap targets have no accessible name

**blocker / M** -- tree-wide -- `Working/phase-07-task07-semantics.txt`

Counted, not sampled. Every `IconButton`, every icon-only fluent button and every
`GestureDetector` in `lib/`, checked for the `MergeSemantics(Tooltip(...))` pair AGENTS.md
requires:

```
total tap targets scanned:              38
with both Tooltip and MergeSemantics:   16
without an accessible name:             22
```

The 16 that are right are all in three files -- `list_item.dart` (11/11), and
`create_dialog.dart`, `root_screen.dart`, `actions_screen.dart`. The 22 that are not:

| File | Count | Detail |
|:---|:---|:---|
| `settings_screen.dart` | 11 | `:421 :442 :471 :499 :783 :809 :817 :823 :911 :1298 :1501` -- **zero `MergeSemantics` in the whole file** |
| `mount_dialog.dart` | 1 | `:428` -- icon-only `Button`, no tooltip |
| `template_screen.dart` | 1 | `:182` -- **Delete**, no tooltip |
| `ai_chat_panel.dart` | 1 | `:124` -- clear history, no tooltip (PS-35) |
| `recommendations_panel.dart` | 1 | `:110` -- dismiss, no tooltip |
| `create_dialog.dart` | 1 | `:654` -- rootfs file picker, no tooltip |
| `settings_dialog.dart` | 1 | `:538` -- has `Tooltip`, no `MergeSemantics` |
| `package_screen.dart` | 1 | `:510` -- has `Tooltip`, no `MergeSemantics` |
| `ai_workspace_screen.dart` | 1 | `:583` -- has `Tooltip`, no `MergeSemantics` |
| `GestureDetector`s | 3 | IA-04 -- not labelled *and* not focusable |

Two of the `settings_screen` entries are a trap for a quick fix: `:471` and `:499` sit
inside a `Tooltip`, but that tooltip wraps the **`TextBox`** and its message is the field
description ("Default editor", "Default terminal"). A screen reader would announce the
folder-picker button with the text field's description. They need their own label, not a
`MergeSemantics` round the existing pair.

ST-18 already flagged the four MCP buttons; this finding is the tree-wide count and the
other eighteen.

#### IA-10 -- The app contains no `Semantics` label at all

**major / M** -- tree-wide

`grep -rn "Semantics(" lib` returns 18 hits and **every one of them is
`MergeSemantics`**. There is not a single `Semantics(label: ...)` in the codebase. That
makes the `MergeSemantics(Tooltip(...))` pattern the app's only source of accessible
names, which is why IA-09's 22 uncovered controls are announced as bare buttons -- and why
[[pro-surfaces]]' PS-03 (the licence table's ✓/✗ glyphs) has no name to fall back on
either. Anything that is an icon and *not* a button -- status dots, the ✓/✗ column, the
BETA/NEW pills -- is invisible to assistive tech by construction.

#### IA-11 -- Seven icon-only buttons have no tooltip at all, so they are unlabelled for sighted users too

**major / S** -- see table in IA-09 -- `86-settings-mcp-on.png`,
`300-a11y-home-baseline.png`

Missing `MergeSemantics` costs a screen reader the name. Missing the `Tooltip` costs
*everyone* the name: hovering tells you nothing. The seven are the five
`open_folder_horizontal` pickers (`settings_screen.dart:421 :442 :1298`,
`create_dialog.dart:654`, `mount_dialog.dart:428`), plus `template_screen.dart:182`
(**Delete**, a destructive action rendered as an unlabelled bin glyph) and
`ai_chat_panel.dart:124`. The MCP row (ST-18) adds four more, including two identical copy
glyphs 60px apart and a one-click token regeneration.

### Long-running operations

#### IA-12 -- Start, stop and delete have no progress affordance whatsoever

**major / M** -- `lib/components/list_item.dart:126-137`, `:139-164`, `:431-441` --
`346-a11y-kb-stop-pressed.png`, `357-a11y-kb-delete-t0700ms.png`

Every other long operation in the app posts `Notify.message(..., loading: true)`
(23 call sites). The three lifecycle operations a user performs most often post nothing.
Measured:

- **Stop**, 1.2 s after activation: the row still reads "ai-workspace (running)", the Stop
  button is still enabled, there is no spinner and no message. The only thing that ever
  updates the row is `reloadEvery5Seconds()`, so the window of "I pressed it and nothing
  happened" is up to five seconds.
- **Delete**, 0.7 s after confirming: a **"DONE: Deleted instance AuditKb"** toast is
  already up *while the deleted row is still in the list*. The list caught up between
  0.7 s and 3.2 s. Success is announced by one mechanism and contradicted by another.

Nothing here needs a new pattern -- `list_item.dart` already imports `Notify`; it just does
not use `loading: true` on these three paths, and none of them refreshes the list.

#### IA-13 -- A failed start is reported as a success, and the code that would report the failure cannot run

**blocker / S** -- `lib/api/wsl.dart:517`, `lib/components/list_item.dart:139-164`

Two independent defects in eleven lines:

```dart
try {
  WSLApi().start(widget.item, ...);                    // (1) not awaited -- and cannot be
  Future.delayed(
      const Duration(milliseconds: 500),
      Notify.message('${widget.item} ${'started-text'.i18n()}.',   // (2) called, not passed
          duration: const Duration(seconds: 3)));
} catch (e) {
  final errorMsg = 'Failed to start ${widget.item}: $e';
  Notify.message(errorMsg);
  diagnoseWithAi(errorMsg);
}
```

1. `WSLApi.start` is declared `void start(...) async` (`wsl.dart:517`) -- a fire-and-forget
   `async void`. It returns nothing to await, so **the `catch` block is unreachable**: no
   start failure can ever produce the "Failed to start" message or the Diagnose-with-AI
   button. The exception surfaces in the zone error handler
   (`logging.dart:66`) and the user sees nothing. `stop()` and `remove()` return
   `Future<String>` and *are* awaited, so their catches work -- `start` is the odd one out.
2. `Future.delayed(d, Notify.message(...))` **calls** `Notify.message` to compute the
   argument. The toast is posted synchronously, before `wsl.exe` has been asked to do
   anything, and `Future.delayed` then waits 500 ms on a `null` computation. The 500 ms is
   a no-op and the success message is unconditional.

Together: pressing Start on a distro that cannot start shows "<name> started." and nothing
else. Fix is `Future<void> start(...)`, `await`, and `() => Notify.message(...)`.

#### IA-14 -- The only control on a running operation is a ✕ that does not cancel it

**major / M** -- `lib/components/notify.dart:63-67` -- _source-derived_

While `loading: true`, the `InfoBar`'s `action` slot is a `ProgressRing` and its
`onClose` is `() => setState(() => status = '')` (`root_screen.dart:231`). So the one
affordance the user is offered during a multi-minute download, import or install is a
close button that **hides the progress and leaves the operation running**. There is no
cancel anywhere in the status-bar path. This is the mechanism behind CI-14 and PS-18
("no cancel"); recording it here because the ✕ is worse than nothing -- it reads as one.

At minimum the ✕ should be suppressed while `loading` is true. Better: give
`Notify.message` an optional `onCancel` and wire it to `ExecutionBroker.terminate()`.

#### IA-15 -- `statusMsg` takes a severity it can never receive

**nit / S** -- `lib/nav/root_screen.dart:58`, `lib/components/notify.dart:66`

`statusMsg(..., InfoBarSeverity severity = InfoBarSeverity.info, ...)` declares the
parameter, never reads it, and could not receive it anyway: `Notify.message`'s declared
function type (`notify.dart:6-14`) has no `severity`, so no call site in the app can pass
one. `statusBuilder` then hardcodes `severity: InfoBarSeverity.info` and its
`decoration` callback assigns the *same* colour to all four severity branches.
CI-19 records the symptom (everything renders as info); this is where the fix has to
start -- the function type, not the call sites.

### Error text

#### IA-16 -- A failed mount shows a dialog whose entire message is "Exception:"

**blocker / S** -- `lib/api/mount_service.dart:338`,
`lib/dialogs/mount_dialog.dart:242` -- `382-a11y-mount-error-raw-exception.png`

Reproduced live. Mount Disk -> VHD Image -> `C:\nope\audit-missing.vhdx` -> Mount produces
a modal titled **Error** whose body is, in full:

```
Exception:
```

The mechanism, measured by running the same command directly:

```
> wsl.exe --mount --vhd C:\nope\audit-missing.vhdx
exit=-1
stdout (182 bytes): Das System kann den angegebenen Pfad nicht finden.
                    Fehlercode: Wsl/ERROR_PATH_NOT_FOUND
stderr (0 bytes):
```

`wsl.exe` reports this failure on **stdout**, and `mount_service.dart:338` throws
`Exception(result.stderr.toString().trim())` -- so the app throws an exception with an
empty message, `Exception.toString()` renders the class name and a colon, and
`mount_dialog.dart:242` puts that verbatim in a `SelectableText`. The app *has* the
actionable text, including the stable `Wsl/ERROR_PATH_NOT_FOUND` code, and discards it.

Three throw sites do this (`mount_service.dart:287`, `:338`, `:353`) and three render sites
show the result raw (`mount_dialog.dart:154`, `:210`, `:242`). Note the fix has to read
*both* streams: matching on the `WSL_E_*` / `ERROR_*` code suffix is the approach AGENTS.md
already prescribes, and it is available here.

This is also the first of the four mount error-recovery dialogs to actually be reached --
[[index]] previously listed all four as not examined.

#### IA-17 -- Five messages interpolate a raw exception; two of them say "Exception" twice

**major / S** -- `Working/phase-07-task07-messages.txt`

Of 122 `Notify.message` call sites, five interpolate an exception object directly:

| Where | Message |
|:---|:---|
| `docker_images.dart:640`, `:802` | `'${'error-text'.i18n()}: $e'` -> **"Error: Exception: ..."** |
| `templates.dart:63` | `e.toString()` as the entire message |
| `sync.dart:118` | `'... $distroName: $error'` |
| `settings_dialog.dart:297` | `move-error-text` with `e.toString()` as a parameter |

Plus three that build the string into a variable first, so the sweep does not catch them
but the user still sees them -- `list_item.dart:133`, `:160`, `:438`. And
`ai_workspace_screen.dart:575` renders `'Error: ${state!.errorMessage}'`, where
`errorMessage` is set from `e.toString()` at seven places in
`api/ai_workspace/service.dart`.

The pattern to remove is `'<label>: $e'`: the label is translated, the colon is bare and
the payload is a Dart class name followed by whatever the underlying tool wrote.

#### IA-18 -- Sixteen user-facing messages are hardcoded English, and three of them describe the implementation

**major / M** -- `Working/phase-07-task07-messages.txt`

Thirteen `Notify.message` call sites pass an English sentence as the whole message, and
three more build one into a variable first. The ones that matter most are on the paths a
user hits most:

| Where | Message | Why it is worse than untranslated |
|:---|:---|:---|
| `list_item.dart:133` `:160` `:438` | `'Failed to stop/start/delete <name>: <exception>'` | The three core operations. English + raw exception + bare colon |
| `list_item.dart:385` | `'Cleaning up <name>. Exporting, removing and importing back...'` | Describes the app's internal algorithm to the user |
| `list_item.dart:392` `:397` | `'Cleaning up <name>: <status>'`, `'Successfully cleaned up <name>'` | |
| `docker_images.dart:350` `:485` | `'Not implemented yet: Docker USER is a number.'` | A developer TODO shown as a toast |
| `docker_images.dart:531` | `'Unknown manifest type'` | |
| `docker_images.dart:616` `:767` | `'Extracting layers ...'` | **`extractinglayers-text` already exists** and `create_dialog.dart:127` uses it |
| `docker_images.dart:746` | `'Exporting local Docker image ...'` | |
| `wsl.dart:499` `:501` | `'Triggered WSL install on remote host <x>.'` / `'Failed to trigger ...: <stderr>'` | |
| `wsl.dart:750` | `'Remote .wslconfig editing is not supported via local editor. Change values in Settings and Save.'` | |
| `wsl.dart:794` | `'No supported terminal emulator found. Install one (for example: xterm, gnome-terminal, or kitty).'` | |

`dart run scripts/check_translations.dart` cannot see any of these -- it compares key
sets between locale files and a string that never becomes a key is invisible to it, the
same blind spot TL-10 and TL-16 describe from the other direction.

#### IA-19 -- The "disk is offline" hint is gated on English Windows text, so it never appears on this host

**major / S** -- `lib/dialogs/mount_dialog.dart:233-234`

```dart
if (errorMessage.contains('process cannot access') ||
    errorMessage.contains('being used by another process')) {
  errorMessage += 'diskofflinehint-text'.i18n();
}
```

The hint is the one genuinely useful thing the mount error path can add -- and it is
attached by matching English strings against localized Windows/WSL output. AGENTS.md calls
this out explicitly ("`wsl.exe` error text is localized -- never match stderr on English
substrings"), and `wsl.dart:1599-1601` already does it the careful way, matching both
`'no installed distributions'` and `'keine installierten distributionen'`. On this
German-locale host the branch cannot fire, so a user whose disk is in use gets the raw
error of IA-16 and no hint. `ai_workspace/service.dart:666` (`lower.contains('not found')`)
has the same shape.

#### IA-20 -- Two strings tell the user to run a command the app has a button for

**nit / S** -- `lib/i18n/en.json:117`, `lib/api/wsl.dart:794`

`globalconfigurationinfo-text` ends "...run wsl --shutdown to shut down the WSL 2 VM and
then start your distro again." It is displayed on the Settings screen, roughly 300px above
a **Stop WSL** button that runs exactly `wsl --shutdown` (ST-04). Telling the user to open
a terminal instead of pointing at the control is the definition of a message written for a
developer. `wsl.dart:794` does the same with "Install one (for example: xterm,
gnome-terminal, or kitty)" -- a Linux package suggestion with no indication of how, and no
link. CI-27 found the same shape in the Turnkey warning.

#### IA-21 -- The recommendation link builds its label with an if/else on a route string

**nit / S** -- `lib/components/recommendations_panel.dart:98`

```dart
'Go to ${rec.actionRoute == '/templates' ? 'Templates' : 'Settings'}',
```

Hardcoded English, and the "else" branch silently claims "Settings" for any future route
that is not `/templates`. Together with TL-16 (the three `recommend-*` keys that exist in
no locale file, including `en.json`) the recommendations panel currently renders its own
i18n keys as body text with an untranslated English link underneath.

#### IA-22 -- The snippet list signals hover by making the row harder to read

**nit / S** -- `lib/components/hoverable.dart:33`, `lib/components/qa_list.dart:127`

`Hoverable` wraps each snippet row and, on hover, sets
`Opacity(opacity: isHovering ? 0.5 : 1)`. Every other hover state in the app adds contrast;
this one halves it. On a *selected* row it compounds CI-34, which measured the selected
title at **2.49:1** before the opacity is applied. It is also the only feedback the row
gives -- there is no background change -- so the affordance and the legibility problem are
the same pixel.

## Verified passes

Recorded so a later regression is visible.

- **A keyboard-only user can create, start, stop and delete a distro** -- the task's
  headline question, answered by doing it. `AuditKb` was created from a local rootfs path
  (name typed, source type chosen from the `ComboBox` with Enter/Down/Down/Enter, path
  typed, Create activated with Enter), started, stopped and deleted, with the delete
  confirmation navigated by Tab and Enter. `wsl --list` confirmed each transition.
  **The one caveat is IA-01**: the sequence only begins after a mouse click, and any window
  switch mid-way requires another one. Screenshots `330`..`359`.
- **Modal dialogs trap focus correctly and Escape cancels.** The delete confirmation's
  traversal is a clean two-stop cycle (Delete, Cancel, Delete, Cancel, ...) with no leakage
  to the page behind. Esc dismissed it and returned focus to the **Delete button that
  opened it** -- exactly right. No dialog in `lib/` overrides `barrierDismissible`, so none
  can be dismissed by a stray click on the barrier either.
- **The expanded row's action bar is the one place the codebase gets semantics right.**
  All nine action buttons plus Start and Stop are `MergeSemantics(Tooltip(IconButton))` --
  11 of 11 in `list_item.dart` -- and all nine are keyboard-reachable in a sensible
  left-to-right order: Save as template, Open with File Explorer, Open with VS Code, Copy,
  Rename, Disk usage, Cleanup, Delete, Settings. This is what makes IA-09 a finding rather
  than a house style.
- **The nav pane paints a real focus ring.** Moving between nav items changes ~1,950 px in
  a 208x84 box covering the whole item -- unmissable, unlike the hairline of IA-07. All
  twelve destinations including the five footer items are reachable.
- **Nothing in the app locks the whole UI.** `grep` for `AbsorbPointer`, `IgnorePointer`,
  `ModalBarrier`, `WillPopScope` and `PopScope` across `lib/` returns **zero** hits. Long
  operations leave the nav pane live (CI-14 treats that as a *problem*, and on the create
  screen it is; as a general property it is the right default).
- **The create form is fully keyboard-drivable, including the parts that usually are not.**
  The `ComboBox` opens on Enter, moves on arrows and commits on Enter; the
  `AutoSuggestBox`'s clear and folder-picker suffix buttons are both tab stops; changing
  the source type to "Local RootFS File" correctly adds the picker to the order.
- **The distro row expander responds to both Enter and Space**, and toggles symmetrically
  (108,569 px changed each way).
- **Keystroke delivery is not the variable.** The same helper that produced 0 movement on
  home produced a clean 24-stop cycle on the create screen in the same session, and the
  VM-Service probe reports focus identity independently of any rendering. Where this pass
  says "Tab does nothing", it means the framework's `primaryFocus` did not change.

## Not examined in this pass

- **Actual screen-reader output.** No Narrator or NVDA session was run. IA-09 and IA-10 are
  measured from the widget tree and from the `MergeSemantics(Tooltip(...))` contract
  AGENTS.md documents, not from what an assistive technology announces. The counts are
  reliable; the exact utterances are not claimed.
- **Windows High Contrast mode and the "Show focus rectangle" accessibility setting.**
  IA-07's numbers are from the default theme at 100% scaling on this host.
- **Non-100% display scaling.** Everything here was measured at `devicePixelRatio` 1.0.
- **The tab order of the Snippets, Templates, Distro packages, AI Workspace, License and
  About screens.** Home, Add an Instance, Settings and the delete confirmation were walked
  stop by stop; the others were only checked for reachability from the nav pane. IA-02 and
  IA-03 are screen-independent (both live in the shell) and were confirmed on two screens
  each.
- **Long-running operations on the Docker, remote-WSL and AI Workspace paths.** IA-12 was
  measured on start/stop/delete against a real distro. The Docker messages in IA-18 are
  read from source -- there is no Docker daemon on this host -- and the install/download
  cancel gaps are already recorded as CI-14 and PS-18.
- **The `loading: true` ✕ pressed mid-operation.** IA-14 is derived from
  `notify.dart:63-67` and `root_screen.dart:231`; no multi-minute operation was started
  purely to click its close button.
- **The two remaining mount error-recovery dialogs** (`mount_dialog.dart:110-160` for
  unmount-by-name and `:184-230` for the attached-but-not-mounted path). Reaching them
  needs a disk that is genuinely attached; only the generic error dialog at `:242` was
  reached (IA-16).
- **`Shift+Tab` as a traversal order.** Reverse traversal was only tested from the dead
  root-scope state (where it does nothing, IA-01). The forward order in IA-05 was not
  verified to be symmetric.
