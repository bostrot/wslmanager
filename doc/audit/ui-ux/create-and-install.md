---
type: analysis
title: UI/UX Audit -- Create and Install Flows
created: 2026-08-28
tags:
  - ui
  - ux
  - audit
  - phase-07
  - create
  - install
related:
  - '[[index]]'
  - '[[list-and-navigation]]'
  - '[[interaction-and-a11y]]'
  - '[[theme-and-locales]]'
  - '[[pro-surfaces]]'
---

# Create and install flows

The dedicated create screen (`lib/screens/create_screen.dart` wrapping the shared
`CreateWidget` in `lib/dialogs/create_dialog.dart`) and the three dialogs that sit
alongside it: `install_dialog.dart`, `copy_dialog.dart`, `qa_dialog.dart` (plus the list
widget the last one drives, `lib/components/qa_list.dart`).

Walked live under the run configuration in [[index]] -- debug build,
`WSLM_FORCE_PRO=true`, `en`/light, 1400x860 with narrow 900x860 and short 900x493 passes,
two real distros on the host. **40 findings (CI-01..CI-40)**, plus a short verified-pass
list at the end.

Two instances were genuinely created and destroyed during this pass (`AuditTest`, a
successful repo install; `AuditFail`, a deliberate `wsl --import` failure), so the
progress, success and error states below are captured from real runs rather than
reasoned about. `AuditTest` was `wsl --unregister`ed afterwards and the pre-audit
`shared_preferences.json` restored from `%TEMP%\wslm-prefs-p07-create.json`.

Screenshots referenced by filename only; they live in `.maestro/screenshots/phase-07/`
and are **gitignored**. Severity: **blocker** / **major** / **nit**. Effort: **S** (under
an hour), **M** (half a day), **L** (a day or more).

## Findings

### Validation and the name field

#### CI-01 -- The error banner keeps showing a failure the user already fixed

**major / S** -- `lib/screens/create_screen.dart:59-61`,
`lib/dialogs/create_dialog.dart:464-481` -- `33-create-duplicate-name.png`,
`35-create-name-with-spaces.png`, `36-create-name-nonascii.png`

`_createError` is only cleared inside `_create()`, i.e. on the *next* press of Create.
Nothing clears it when the field it complains about changes. Reproduced in one session:
press Create on an empty form (banner: "Please enter a name for the new instance"), then
type `Ubuntu` -- the banner still says the name is missing while the field visibly
contains a name, and the inline validator underneath simultaneously says the name already
exists. Two contradictory validation messages, one of them stale, on screen at once.

It persists through everything: typing `My Test Distro`, typing `日本語`, changing the
source type, opening the catalogue. In `44-create-source-switch-stale.png` the banner
still reads "Distro with this name already exists" over a name (`AuditTest`) that does
not exist.

Fix: clear `createError` from the `nameController` listener that `_checkName` already
uses (`create_dialog.dart:406`), not only on submit.

#### CI-02 -- A duplicate name is reported twice, in two different visual languages

**major / S** -- `lib/dialogs/create_dialog.dart:501-509` and `:153-161` --
`34-create-duplicate-submit.png`

The same condition has two independent implementations. `_checkName` renders a bold red
12 px sentence under the field as you type; `createInstance` re-checks on submit and
pushes the identical string into the error InfoBar. Pressing Create with a duplicate name
therefore shows **"Distro with this name already exists" twice at once**, 80 px apart, in
two different styles -- once as a pink InfoBar with an error glyph, once as bare red text.

The inline warning also does not disable Create, so the submit-time check is the only
thing that actually stops it. One of the two should go; the inline one is the better
interaction and should gate the button.

#### CI-03 -- The inline validation message is hardcoded `Colors.red`, not a themed error style

**nit / S** -- `lib/dialogs/create_dialog.dart:504-508` -- `33-create-duplicate-name.png`

`TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold)`. Nothing else
in the form is bold, nothing else is 12 px, and the colour bypasses
`FluentTheme.of(context).resources` so the dark-theme pass ([[theme-and-locales]]) has to
re-check it. The neighbouring failure banner is an `InfoBar` with `InfoBarSeverity.error`
and looks nothing like it.

#### CI-04 -- The name is silently rewritten, and an all-non-ASCII name becomes underscores

**major / S** -- `lib/dialogs/create_dialog.dart:147-149` --
`35-create-name-with-spaces.png`, `36b-create-name-nonascii-zoom.png`

`String name = label.replaceAll(RegExp('[^A-Za-z0-9]'), '_')`. Every character outside
`[A-Za-z0-9]` becomes `_`, and the field says nothing about it -- no hint text, no live
preview of the resulting distro name, no character filter on input.

Measured: `My Test Distro` is accepted with no annotation and becomes `My_Test_Distro`;
`日本語` is accepted with no annotation and becomes `___`, which is non-empty and so
passes the `name != ''` guard -- a distro literally called `___` gets registered. Hyphens
go too, so the perfectly reasonable `ubuntu-dev` silently becomes `ubuntu_dev`.

The label the user typed *is* preserved (`prefs.setString('DistroName_$name', label)`,
`:349`), so the list shows the original text while `wsl.exe` knows a different name.
That divergence is invisible until the user runs `wsl -d` themselves.

Fix: show the sanitised name under the field as it is typed ("will be created as
`My_Test_Distro`"), and stop mapping a name that sanitises to nothing but underscores.

#### CI-05 -- Create and Copy sanitise names differently, and Copy skips the duplicate check

**major / M** -- `lib/dialogs/create_dialog.dart:149` vs `lib/dialogs/copy_dialog.dart:71`

Two flows that both name a new distro use two different rules:

| | Create | Copy |
|:---|:---|:---|
| Regex | `[^A-Za-z0-9]` | `[^a-zA-Z0-9_-]` |
| Action | replace with `_` | **delete** |
| `-` allowed | no | yes |
| Duplicate name checked | yes (twice, CI-02) | **no** |
| `DistroName_*` label stored | the typed label | the sanitised name |

So `my distro` becomes `my_distro` through Create and `mydistro` through Copy, and a copy
onto an existing name is not blocked in the UI at all -- it fails later, inside
`api.copy`, and surfaces as whatever `wsl.exe` wrote to stderr.

There should be one shared `sanitiseDistroName()` helper and one duplicate check. Note
`components/helpers.dart` is where the other shared name/path helpers already live
(`distroLabel`, `getInstancePath`) -- extend that rather than adding a third rule.

#### CI-06 -- The name field has no label; only "Source Type" gets one

**nit / S** -- `lib/dialogs/create_dialog.dart:485-499` vs `:516-518` --
`31-create-1400x860-default.png`

`Name` is a `TextBox` placeholder, so it disappears the moment a character is typed. The
control immediately below it is wrapped in an `InfoLabel(label: 'sourcetype-text')` whose
caption stays put. Two adjacent fields, two different labelling conventions, and the
first one is the one that goes blank. The rootfs `AutoSuggestBox` below has the same
problem.

#### CI-07 -- The name field shows a "clear" button when there is nothing to clear

**nit / S** -- `lib/dialogs/create_dialog.dart:492-497` --
`31-create-1400x860-default.png`

The `suffix: IconButton(chrome_close)` is unconditional, so the very first thing on the
empty create screen is an X that does nothing. (The `AutoSuggestBox` underneath gets this
right -- fluent only draws its clear button once the field has text; compare
`43-create-local-rootfs.png` with `44-create-source-switch-stale.png`.)

### Source selection

#### CI-08 -- Changing the source type keeps the previous source's value

**major / S** -- `lib/dialogs/create_dialog.dart:425-431` --
`44-create-source-switch-stale.png`

`_onSourceTypeChanged` only calls `setState`; `widget.autoSuggestBox` is never cleared.
Reproduced: pick `Ubuntu 24.04` from the catalogue under "Download from Repo", switch to
"Local RootFS File", and the field labelled **"Path to RootFS Archive" now contains
"Ubuntu 24.04"** -- a value that is not a path and never was.

Worse, this is not harmless, because the create path is forgiving in a way the UI never
explains: pressing Create in exactly that state started a *repo download* (see
`48-create-progress.png` -- source type "Local RootFS File", value "Ubuntu 24.04",
result: "Downloading 1%"). The source type visibly disagreed with what the app actually
did, and the install succeeded anyway. The user has no way to tell which of the six
source types is really in effect.

Fix: clear `autoSuggestBox` in `_onSourceTypeChanged` (the two toggles already do exactly
this -- `:688` and `:735`).

#### CI-09 -- One static tooltip for a field whose meaning changes six ways

**nit / S** -- `lib/dialogs/create_dialog.dart:556-558` --
`70-create-wrong-tooltip-localdocker.png`, `56-create-error-state.png`

The source field's tooltip is always `pathtorootfshint-text` -- "Either use one of the
pre-defined Distros or a file path to a rootfs" -- even when the source type is "Local
Docker Image" or "Import VHDX", where neither half of that sentence applies. The
placeholder underneath *does* switch per source type (`:590-598`); the tooltip does not.

The tooltip also renders **on top of the Source Type combo box** rather than below the
field it describes, so hovering the source field hides the control that determines what
the source field means.

#### CI-10 -- The "no results" panel is repurposed as an echo, reads like a suggestion, and is hardcoded English

**major / S** -- `lib/dialogs/create_dialog.dart:601-645` --
`69-create-docker-image.png`, `55-create-local-path-noresults.png`

`noResultsFoundBuilder` is doing four different jobs. With source type "Docker Image" and
`ubuntu:24.04` typed, it renders a full-width dropdown row reading **"Docker Image:
ubuntu:24.04"** -- visually identical to the catalogue suggestion rows in
`37-create-catalogue-open.png`, but inert. It is not a suggestion, it is a "we found
nothing, here is what you typed" panel dressed as one.

Three of its strings bypass i18n entirely, in an app with nine locales:

- `'Docker Image: $image:$tag'` (`:623`)
- `'Local Docker: ${widget.autoSuggestBox.text}'` (`:628`)
- `'Check the image name and tag'` (`:619`)

#### CI-11 -- The catalogue's error branch is empty, and there is no loading state

**nit / S** -- `lib/dialogs/create_dialog.dart:577-586`, `lib/api/app.dart:66-91` --
_source-derived_

`} else if (snapshot.hasError) {}` -- a literally empty branch. A failed catalogue fetch
is indistinguishable from an empty catalogue, which renders as "No results found". There
is no spinner while the `FutureBuilder` is waiting either, so a slow network shows the
same thing.

This is a nit rather than a major only because the *repo* source has a safety net:
`App().getDistroLinks()` swallows its own `dio` error and falls back to the bundled
`images.json` asset, so the list in `37-create-catalogue-open.png` survives being
offline. The "Turnkey Linux" source calls `api.getDownloadable()` with no such fallback.

Related, same lines: the future is an inline invoked closure (`future: () async {…}()`),
so a fresh network fetch is issued on **every rebuild** of `_CreateWidgetState` --
including each toggle flip. No visible flicker results (`FutureBuilder.didUpdateWidget`
keeps the previous `data`, verified against `40-create-refetch-transient.png`, which
still shows the full list one frame after a toggle), so this is redundant traffic rather
than a UI defect. Stated from source; not presented as an observed symptom.

#### CI-12 -- "Create default user" with an empty username silently creates no user

**major / S** -- `lib/dialogs/create_dialog.dart:315-347` -- `41-create-user-toggle.png`
-> `53-create-importing.png`

The toggle says "Create default user". Turning it on reveals a text box placeheld
"(Optional) user". Leaving that box empty takes the `else` branch at `:337`, which
creates no user, sets no `wsl.conf` default, and reports the ordinary success message.

Reproduced end to end: toggle on, field left blank, Create pressed, install completed,
result "DONE: Created instance" and a root-only distro. The user asked for a default user
in one control and was told in another that it was optional. Either the field is required
once the toggle is on, or the toggle should not exist and the field alone should drive it.

#### CI-13 -- The password step opens an external console with no warning

**major / M** -- `lib/api/wsl.dart:1249-1275`, `lib/dialogs/create_dialog.dart:324` --
_source-derived_

When a username *is* given, post-install runs `api.exec(name, ['passwd $user'])`, and
`exec` special-cases `passwd` into `shell.start('start', ['wsl','-d',…,'passwd',user])`
-- a detached console window outside the app. Nothing in the create form warns that a
terminal will appear and ask for a password, and `start` returns immediately, so the
create flow reports success while the user is still typing into a window the app does not
own. Closing that window without setting a password leaves the account passwordless,
silently.

Not observed in this pass: the blank-username path (CI-12) short-circuits before it, and
the audit deliberately did not leave a passwordless account behind. Stated from source
and labelled as such.

#### CI-14 -- Cancel is disabled for the whole install, but the nav pane is not

**major / M** -- `lib/screens/create_screen.dart:116-129` -- `48-create-progress.png`,
`51-create-progress-dismissed.png`

While `isCreating` is true, both Create and Cancel are `onPressed: null`. There is no
cancel for the download and no cancel for the import; a multi-GB rootfs commits the user
for as long as it takes.

The nav pane is *not* disabled -- every entry stayed live throughout the install (visible
in `48-create-progress.png`). So the app removes the one labelled escape hatch and leaves
an unlabelled one open, where leaving mid-install abandons the page, keeps the install
running, and reduces all further feedback to the bottom toast. Either wire Cancel to an
abort (`ExecutionBroker.terminate()` already exists for this shape of problem) or leave
it enabled as "leave this page, the install continues".

### Progress and completion

#### CI-15 -- The Create button collapses to a spinner square and the row jumps

**nit / S** -- `lib/screens/create_screen.dart:117-122` -- `48-create-progress.png`

`child: isCreating ? SizedBox.square(dimension: 16, ProgressRing) : Text(…)` shrinks the
button from 64 px to 38 px the instant Create is pressed, dragging the disabled Cancel
button 26 px to the left with it. Standard fix is a fixed-width button with the spinner
*next to* a retained label ("Creating…").

#### CI-16 -- Progress is a text percentage in a corner toast, and it stalls at 100%

**major / M** -- `lib/dialogs/create_dialog.dart:119-129`, `lib/api/wsl.dart` (`create`)
-- `49-create-progress-2-toast.png`, `50-create-progress-3-toast.png`,
`52-create-after.png`, `53-create-importing.png`

The only progress indicator for a multi-minute operation is a one-line status bar at the
bottom of the window reading "Downloading 35%" -> "Downloading 49%" -> "Downloading
100%". No progress bar, no byte count, no transfer rate, no ETA, and it is
bottom-centre-anchored, ~700 px away from the form the user is looking at.

Measured on the real install: the toast reached **"Downloading 100%" and then did not
change for the entire `wsl --import` phase** -- still exactly "Downloading 100%" 20 s
later (`52-create-after.png`), the next state change being the finished list
(`53-create-importing.png`). Extraction and import are the slowest part of a create and
the UI reports them as a finished download.

The `progressFn` callback does receive layer counts for the Docker path
(`Layer 1/N: 42% (12.3 MB)`), so the richer text exists; the rootfs path just does not
use it, and neither path has a bar.

#### CI-17 -- After a failure, the "Creating instance…" spinner keeps running forever

**major / S** -- `lib/dialogs/create_dialog.dart:166` (never cleared on the failure
paths) -- `56-create-error-state.png`, `57-create-error-stuck-spinner.png`

`Notify.message('creatinginstance-text', loading: true)` is posted before the work starts
and is never replaced when `createInstance` returns `false`. Measured against the real
`AuditFail` run: **30+ seconds after the red failure banner appeared, the status bar
still read "Creating instance. This might take a while…" with a live spinner.** The app
tells the user, simultaneously and permanently, that the create failed and that it is
still running.

Every `return false` in `createInstance` (`:159, :227, :238, :257, :272, :297, :361`)
needs to clear the loading status, or the status should be posted with a `duration`.

#### CI-18 -- Status messages never expire and follow the user across the app

**major / S** -- `lib/nav/root_screen.dart:55-93` -- `52-create-after.png` ->
`55-create-local-path-noresults.png`, `68-qa-download-invisible-selection.png`

`statusMsg`'s `duration` is optional and virtually every caller omits it, so
`_messageTimer` is never armed and the bar stays until something else replaces it or the
user clicks the X.

Measured: "DONE: Created instance" was still on screen after navigating to Add an
Instance, changing the source type, typing a path and opening a file picker. Later,
"ERROR: Please enter a name for the new instance." (from the copy dialog) survived six
navigations and was still sitting under the Snippets screen when a snippet was
successfully downloaded (`68-qa-download-invisible-selection.png`) -- an error message
captioning an unrelated success.

The X does not help either: dismissing it mid-download (`51-create-progress-dismissed.png`)
just lets the next progress tick re-open it a fraction of a second later.

`lib/components/ai_diagnosis.dart` shows the intended pattern in the same function --
`upgrade-prompt-error` gets `duration: 5 s` at `:15` while the sibling
`byok-required-text` at `:20` gets none. Give transient messages a duration; keep the
sticky behaviour only for `loading: true`.

#### CI-19 -- Every status message renders as "info", including errors

**major / S** -- `lib/components/notify.dart:66`, `lib/nav/root_screen.dart:58` and
`:230` -- `63b-copy-empty-name-toast.png`, `58-create-ai-diagnose.png`

`statusBuilder` hardcodes `severity: InfoBarSeverity.info`. Measured: the copy dialog's
failure renders as **a blue "i" circle next to the words "ERROR: Please enter a name for
the new instance."** -- the icon actively contradicts the text.

Two pieces of plumbing exist for this and are both dead:

- `statusMsg` accepts `InfoBarSeverity severity = InfoBarSeverity.info` (`:58`) and never
  passes it to `statusBuilder`.
- `statusBuilder`'s `decoration` callback switches on all four severities (`notify.dart:32-47`)
  and returns `AppTheme().backgroundColor.light` for every one of them.
- `leadingIcon` / `statusLeading` is threaded from `Notify.message` through `statusMsg`
  (`:61`, `:73`, `:79`) and then not passed to `statusBuilder` either.

Fix: pass the severity through, delete the no-op switch, and let callers say
`Notify.message(msg, severity: InfoBarSeverity.error)` instead of prefixing "ERROR:".

#### CI-20 -- Messages carry their severity in shouting capitals

**nit / S** -- `lib/i18n/en.json:30, 31, 36, 37` -- `53-create-importing.png`,
`63b-copy-empty-name-toast.png`

`"DONE: Created instance"`, `"DONE: Copied %s0 to %s1."`, `"ERROR: Please enter a name
for the new instance."`, `"WARNING: Created instance but failed to create user"`. This is
developer log formatting in an end-user status bar, and it is only there because CI-19
made the icon useless. The success message also does not name the instance that was just
created, while its copy-flow sibling does.

#### CI-21 -- Two near-identical strings for one condition

**nit / S** -- `lib/i18n/en.json:31` and `:39`

`errorentername-text` = "ERROR: Please enter a name for the new instance." (copy flow)
and `entername-text` = "Please enter a name for the new instance" (create flow). Same
meaning, different capitalisation, different punctuation, nine locales each.

### The error state

#### CI-22 -- Raw WSL stderr is shown verbatim, error code and all -- in the wrong language

**major / M** -- `lib/dialogs/create_dialog.dart:285-298` -- `56-create-error-state.png`,
`59-create-900x860-narrow.png`

Creating `AuditFail` from a non-existent path produced this, verbatim, in the app's error
banner:

> Das System kann den angegebenen Pfad nicht finden.
> Fehlercode: Wsl/ERROR_PATH_NOT_FOUND

The app was running in **English**. `wsl.exe` localises its stderr to the *Windows*
display language, and `createInstance` pipes it straight into the InfoBar, so a
German-Windows user running the app in English (or a French user, or Japanese) gets an
error in a language they did not select. `AGENTS.md` already documents that WSL error
text is localised and that only the `Wsl/…` code suffix is stable -- that is exactly the
hook needed here.

The message also never mentions *which* input was wrong. The user typed a rootfs path;
the app says a path was not found without saying it was that one, and appends a raw
symbol (`Wsl/ERROR_PATH_NOT_FOUND`) with no plain-language gloss.

Fix: match on the `Wsl/…` code and render an own-language sentence naming the offending
field, keeping the raw text available (collapsed "details") for bug reports.

#### CI-23 -- The only offered remedy is "Diagnose with AI", and without a key it just points at Settings

**major / M** -- `lib/dialogs/create_dialog.dart:471-478`,
`lib/components/ai_diagnosis.dart:19-22` -- `56-create-error-state.png`,
`58-create-ai-diagnose.png`

The failure banner's single action is "Diagnose with AI". There is no Retry, no "choose a
file…" shortcut back to the picker, and no focus move to the field that is wrong.

Clicking it with no BYOK key configured (the default; the audit build has Pro forced on
but no key) answers with a bottom toast: *"AI Chat needs your own API key. Add it in
Settings under 'Bring Your Own AI Key'."* -- 700 px from the button that was clicked,
with no link to Settings, and with no duration so it stays until something replaces it
(CI-18). This is the same shape as LN-19 in [[list-and-navigation]]: an AI affordance
offered unconditionally that resolves into a "go configure something else" toast.

Worth fixing at the same time: on the happy path, `diagnoseWithAi` renders the model's
diagnosis as a **30-second toast** (`ai_diagnosis.dart:28`) -- a multi-sentence answer in
a one-line status bar that cannot be scrolled, selected or copied, and then vanishes.

#### CI-24 -- On a short window the status bar covers the Create and Cancel buttons

**major / S** -- `lib/components/notify.dart:22-26` -- `60-create-900x400-short.png`

The status bar is `Align(alignment: bottomCenter)` painted over the page content, and the
create page reserves no bottom padding for it. At 900x493 (the smallest height this
window will take) the bar sits directly on top of both toggles **and the entire
Create/Cancel row**. Combined with CI-18 -- the bar never expires by itself -- a user on a
small display can be left unable to reach the primary action until they notice the small
X.

#### CI-25 -- The source-type popup covers the whole upper form

**nit / S** -- `lib/dialogs/create_dialog.dart:518-551` --
`71-create-sourcetype-covers-form.png`, `42-create-sourcetype-open.png`

fluent's `ComboBox` aligns the selected item over the closed box, so with a
later-in-the-list value selected the popup opens *upward* and covers the page title, the
Name field, the "Source Type" caption and the source field. In
`42-create-sourcetype-open.png` the caption is clipped mid-glyph ("Source Tvpe"). Not the
app's own layout, but it is worth constraining the popup or moving the control so the
name the user just typed is not hidden while they pick a source.

#### CI-26 -- The six source types are developer jargon, ungrouped and unexplained

**nit / M** -- `lib/dialogs/create_dialog.dart:522-547`, `lib/i18n/en.json:307-311` --
`42-create-sourcetype-open.png`

"Download from Repo" (which repo? the app's curated `images.json` catalogue, but nothing
says so), "Turnkey Linux (LXC)", "Local RootFS File", "Docker Image", "Local Docker
Image", "Import VHDX". Six flat entries with no description line, no separator between
the three that fetch something remote and the three that import a local file, and no
indication that four of the six need something the user must already have.

#### CI-27 -- The Turnkey warning is a five-line italic paragraph with shell commands in it

**major / S** -- `lib/dialogs/create_dialog.dart:722-725`, `lib/i18n/en.json:48` --
`72-create-turnkey-warning.png`

Selecting "Turnkey Linux (LXC)" drops this between the location toggle and the Create
button, as plain italic body text with no icon, no border and no colour:

> *Warning: You selected a turnkey container. [Experimental]*
> *Modern WSL supports systemd. This app no longer installs fake_systemd automatically. If
> a selected image/service still needs extra setup, check the image documentation and
> ensure systemd is enabled for that distro in WSL settings.*
> *To access the service, use "ip a | grep inet" to find the IP and then open
> WSL-IP:PORT in your browser.*

It is a changelog entry, a troubleshooting note and a shell tutorial in one string. It
names an internal detail the user has never heard of (`fake_systemd`), tells them to run
`ip a | grep inet`, and asks them to substitute into the placeholder `WSL-IP:PORT`. Five
lines of italic is also the least legible way to present it. Should be an
`InfoBar(severity: warning)` with one sentence; the rest belongs in the documentation.

#### CI-28 -- `createDialog()` is dead code, and it disagrees with the screen that replaced it

**nit / S** -- `lib/dialogs/create_dialog.dart:30-117`

`createDialog()` has no call sites anywhere in `lib/`, `test/` or `integration_test/` --
only the `ValueKey`s it shares with `CreatePage` are still referenced
(`integration_test/helpers.dart:33-36`). It is the old dialog that `CreatePage`
superseded, kept alive in the same file as the widget both of them use.

It matters for consistency, not just tidiness: its action row is `[Cancel, Create]`
(`:67-110`) -- **the reverse of `CreatePage`'s `[Create, Cancel]`** -- and neither of its
buttons is a `FilledButton`, so anyone reading this file for "how does the create flow
lay out its buttons" gets the wrong answer. It also wraps each button in a `Tooltip`
whose message repeats the button's own visible label.

Delete it, or make it the single implementation.

### Copy dialog

#### CI-29 -- The primary action has no visual emphasis, and the buttons are equal-width

**nit / S** -- `lib/dialogs/base_dialog.dart:60-80`, `lib/dialogs/copy_dialog.dart:65` --
`62-copy-dialog.png`

`copyDialog` passes `submitStyle: const ButtonStyle()` -- i.e. nothing -- so Copy and
Cancel render as two identical neutral buttons stretched to the same width across the
dialog footer. The create screen it mirrors uses a blue `FilledButton` for Create
(`create_screen.dart:114`). Same app, same decision, two answers. (Button *order* is
consistent -- primary first -- everywhere except `qa_dialog.dart`; see CI-32.)

#### CI-30 -- The copy dialog looks pre-filled, then closes before it validates

**major / S** -- `lib/dialogs/base_dialog.dart:48-56` and `:62-70`,
`lib/dialogs/copy_dialog.dart:107-109` -- `62-copy-dialog.png`,
`63b-copy-empty-name-toast.png`

`dialog()` uses the *item* as the input's placeholder, so copying `AuditTest` opens a
dialog whose text box appears to already contain `AuditTest`. It does not; the field is
empty.

Pressing Copy in that state does `Navigator.pop(context)` **before** calling `onSubmit`,
so the dialog is gone by the time anything is validated. Measured: the dialog closed and
the failure arrived a second later as a bottom status message -- "ERROR: Please enter a
name for the new instance." with a blue info icon (CI-19) -- with no way back to the
half-filled form. Validation has to happen before the pop, and the placeholder should
suggest a *new* name (e.g. `AuditTest-copy`) rather than echoing the source.

#### CI-31 -- Nothing warns that a copy duplicates the whole disk

**nit / S** -- `lib/dialogs/copy_dialog.dart:62-63`, `lib/i18n/en.json:28`

"Copy the WSL instance 'AuditTest' to a new instance with this name" (no full stop). A
copy is an export + import (or a VHD copy) of the entire distro -- 16.63 GB for
`ai-workspace` on this host -- and it stops the source distro first (`api.stop`, `:79`).
Neither the disk cost, the duration nor the shutdown is mentioned anywhere in the dialog;
the only hint is the "This might take a while..." that appears *after* the user commits.

### Community snippets dialog

#### CI-32 -- Button order is reversed against every other dialog in the app

**major / S** -- `lib/dialogs/qa_dialog.dart:151-175` -- `65-qa-community-dialog.png`

| Surface | Action row |
|:---|:---|
| `create_screen.dart:112-130` | **Create**, Cancel |
| `base_dialog.dart:60-80` (copy, rename, delete, …) | **Submit**, Cancel |
| `qa_dialog.dart:151-175` | Cancel, **Download** |

The community dialog is the sole outlier, so the position that means "cancel" everywhere
else means "commit" here. Neither of its buttons is a `FilledButton`, so there is no
colour cue to catch the swap either.

#### CI-33 -- The community dialog has no title

**nit / S** -- `lib/dialogs/qa_dialog.dart:133-150` -- `65-qa-community-dialog.png`

`ContentDialog` is constructed with `content:` and `actions:` only. The user opens a
modal containing an unlabelled search box, a list of four names, a link and two buttons,
with nothing on screen saying what it is or where the content comes from.

#### CI-34 -- Selecting a snippet drops its text contrast to 2.5:1

**major / S** -- `lib/components/qa_list.dart:127-136` -- `66b-qa-selected-zoom.png`

`tileColor: ButtonState.all(AppTheme().color.withValues(alpha: 0.5))` paints a 50 %
accent fill under a `ListTile` whose title and subtitle colours are left to fluent's
selected/pressed resolution. Measured off `66-qa-selected.png`:

| | Title glyph | Tile background | Contrast |
|:---|:---|:---|:---|
| Unselected (`captainkyds_scripz`) | `#1A1A1A` | `#FFFFFF` | **17.4 : 1** |
| Selected (`apt-upgrade`) | `#838689` | `#BBD9F0` | **2.49 : 1** |

The subtitle goes the same way (`#838689` measured at 559,159). So the act of selecting
an item makes it *seven times harder to read* and puts it well under the 4.5:1 WCAG AA
threshold -- the selected row is the least legible row in the list. Set an explicit
content colour alongside `tileColor`, or express selection with a `Checkbox` and leave
the text alone.

#### CI-35 -- An empty search shows a blank panel, and hidden selections are still downloaded

**major / S** -- `lib/components/qa_list.dart:112-137` -- `67-qa-no-results.png`,
`68-qa-download-invisible-selection.png`

Filtered-out rows return `Container()` while `itemCount` stays at the unfiltered length,
so a search that matches nothing renders a **~570 px tall empty white area** with no "no
results" message, no hint that the search is the reason, and no clear-search button.

`selectedList` is not filtered with the view. Reproduced: select `apt-upgrade`, type
`zzzznotfound` so it vanishes from the list, press Download -- and `apt-upgrade` is
downloaded and added to Snippets (`68-qa-download-invisible-selection.png`). The user
committed to something they could not see and had no way to review or deselect.

Fix: filter the data before building the list, show a no-results state, and either clear
selections that leave the view or surface a persistent "N selected" chip.

#### CI-36 -- Download reports neither progress nor success, and a failure looks like a success

**major / S** -- `lib/dialogs/qa_dialog.dart:158-172`, `lib/components/qa_list.dart:35-57`
-- `68-qa-download-invisible-selection.png`

`download()` fetches one HTTP request per selected snippet with no progress and no
spinner. On success there is no confirmation at all -- the dialog closes and the user is
left to notice a new row. Measured: the only thing in the status bar afterwards was the
*unrelated* "ERROR: Please enter a name for the new instance." left over from the copy
dialog several minutes earlier (CI-18).

On failure it is worse: `download()` catches the error, posts a bare "Error downloading"
toast and returns normally, so `qa_dialog.dart` pops the dialog and runs the success
callback exactly as if it had worked. The list's own load failure is equally thin --
`Center(child: Text('errordownloading-text'))` (`qa_list.dart:141`), the same three words,
with no retry and no mention that it needs a network connection.

Also worth noting: `static List<QuickActionItem> items` (`:22`) is a process-lifetime
cache that is never invalidated, so the list can never be refreshed without restarting
the app.

#### CI-37 -- The dialog is a full screen-height column with ~300 px of dead space

**nit / S** -- `lib/dialogs/qa_dialog.dart:134-135` -- `65-qa-community-dialog.png`

`SizedBox(height: MediaQuery.of(context).size.height)` inside a `ContentDialog` makes the
modal as tall as the window regardless of content. With four snippets available, the gap
between the last item and the footer is roughly 300 px of nothing, and the "Share your
snippets" hyperlink floats in the middle of that void rather than sitting with the
actions.

### WSL-not-installed panel

The three findings below are **source-derived**: reaching this surface requires a host
without WSL, and WSL is installed here. Recorded in the "not examined" list in [[index]]
as well.

#### CI-38 -- A hyperlink that triggers an elevated system change, described as text to copy

**major / S** -- `lib/dialogs/install_dialog.dart:22-36`, `lib/api/wsl.dart:495-514` --
_source-derived_

The body reads "You can install it with following command in the Terminal:", then shows
`wsl --install` in a grey chip, then -- *underneath* -- "Hint: you can click the above
command to install it". So the copy tells the user to go to a Terminal, and a hint below
the control reveals that the control is in fact the primary action.

That action is `WSLApi().installWSL()`, which runs
`Start-Process cmd -ArgumentList "/c wsl --install" -Verb RunAs` detached. There is no
confirmation step before a UAC-elevated, reboot-requiring system change, and because the
process is detached there is no feedback afterwards either -- the panel keeps saying WSL
is not installed. This should be a `FilledButton` with a confirmation, not a hyperlink.

#### CI-39 -- Missing article in the install copy

**nit / S** -- `lib/i18n/en.json:74` -- _source-derived_

"You can install it with following command in the Terminal:" -- "with **the** following
command". Nine locales carry the translated versions of this sentence.

#### CI-40 -- Hardcoded translucent-black chip, and a "Dialog" that is not a dialog

**nit / S** -- `lib/dialogs/install_dialog.dart:22-23`, `lib/components/list.dart:113-115`
-- _source-derived_

`Container(color: Color.fromRGBO(0, 0, 0, 0.2))` behind the command. In light theme that
is a grey code chip; over the dark theme's dark surface a 20 % black wash is close to
invisible, taking the only affordance on the screen with it (flag for the dark pass in
[[theme-and-locales]]). The class is also named `InstallDialog` and returns an `Expanded`
that is rendered inline inside the list's `Column` -- it is a panel, not a dialog, and
the name sends readers looking for a `showDialog` that does not exist.

## Checked and fine

Recorded so the audit does not imply these were skipped.

- **Narrow width.** At 900x860 the whole form, the error banner and the action row fit
  without truncation or overflow -- the `ConstrainedBox(maxWidth: 640)` in
  `create_screen.dart:98` is doing its job (`59-create-900x860-narrow.png`). The *short*
  window is the problem case, not the narrow one (CI-24).
- **Unicode input.** `日本語` reaches the field and renders correctly
  (`36b-create-name-nonascii-zoom.png`); what happens to it afterwards is CI-04, not an
  input bug.
- **The file picker.** `FilePicker.platform.pickFiles` opens, and the chosen path lands in
  the field intact (`46-create-filepicker-rootfs.png`). Two observations that are not
  findings: the native dialog follows the *Windows* display language (German here) and
  cannot be made to follow the app's locale; and the filter is "Files (*.*)" because
  `allowedExtensions: ['*']` (`create_dialog.dart:661-663`) -- offering `tar`, `tar.gz`,
  `tgz` would be a cheap improvement but nothing is broken today.
- **Catalogue contents.** The repo catalogue loaded fully and instantly on reopen
  (`37`/`38-create-catalogue-open.png`); the 19 entries themselves were install-tested in
  Phase 06 and are not re-litigated here.
- **The two toggles.** Both clear their companion controller when switched off
  (`create_dialog.dart:688`, `:735`), and the revealed fields appear and disappear cleanly
  (`41-create-user-toggle.png`, `43-create-local-rootfs.png`). This is the behaviour
  CI-08 says the source-type change is missing.
- **The error banner's long text.** `isLong: true` wraps the two-line German WSL error
  correctly at both widths (`56`, `59`).

## Not examined

- **A real Docker Hub pull and a real local `docker save`** -- no Docker daemon on this
  host. The Docker source types were exercised as far as the form goes (CI-10) but no
  image was fetched.
- **`Import VHDX`** -- no spare `.vhdx` to import. The field's placeholder and picker
  filter were read from source; the flow was not run.
- **The `passwd` console window** (CI-13) -- deliberately not triggered, so as not to leave
  a passwordless account on the host.
- **The WSL-not-installed panel** (CI-38..CI-40) -- WSL is installed here.
- **Copy over remote WSL** -- `copyDialog` branches on `UseRemoteWSL` (`:73`, `:101`) and
  that path needs a second Windows host; see the same entry in [[index]].
