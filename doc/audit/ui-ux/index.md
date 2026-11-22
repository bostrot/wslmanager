---
type: analysis
title: UI/UX Click-Through Audit
created: 2026-08-28
updated: 2026-08-28
tags:
  - ui
  - ux
  - audit
  - phase-07
related:
  - '[[list-and-navigation]]'
  - '[[create-and-install]]'
  - '[[settings-and-tools]]'
  - '[[pro-surfaces]]'
  - '[[theme-and-locales]]'
  - '[[interaction-and-a11y]]'
---

# UI/UX click-through audit

Every screen, dialog and meaningful state of WSL Distro Manager, walked by hand in a
running build, screenshotted, and picked apart. This file is the index: the run
configuration that makes the walk reproducible, the master findings table, and the
ordered fix list that Phase 08 works from.

Findings live in the per-area files and are copied into the master table here. Each
finding carries a stable ID (`AREA-nn`) so a fix commit can cite it.

## Run configuration

Everything below was captured against this exact setup. Reproduce it before adding a
finding, or a screenshot will not be comparable with the ones already in the audit.

| | |
|:---|:---|
| Build | `flutter run -d windows --dart-define=WSLM_FORCE_PRO=true` (debug) |
| App version | 1.11.0 (`pubspec.yaml`), branch `beta` |
| Standard window | **1400 x 860** visible px -- above fluent_ui's 1008px open/compact nav threshold |
| Narrow window | **900 x 860** visible px -- deliberately below it, so the compact pane is audited too |
| Locale / theme baseline | `en` / light; other locales and dark are a separate pass ([[theme-and-locales]]) |
| Host | Windows 11 Pro 26200, 1 real distro (`Ubuntu`) + `ai-workspace` |
| Screenshots | `.maestro/screenshots/phase-07/` -- **gitignored, never committed** |

### The four commands

```powershell
$t = ".maestro\tools"
& "$t\prefs.ps1"  -Baseline -StopApp -Backup "$env:TEMP\wslm-prefs.json"
& "$t\launch.ps1" -Mode run -ForcePro -Width 1400 -Height 860 -KillFlutter
& "$t\resize.ps1" -Width 900 -Height 860          # narrow pass
& "$t\shot.ps1"   -Path ".maestro\screenshots\phase-07\<area>-<state>.png"
```

`prefs.ps1` (added by this phase) is the piece that makes the run *reproducible* rather
than merely repeatable. It refuses to touch `shared_preferences.json` while the app is
alive -- the app rewrites the file on exit, so an edit made mid-session is silently
discarded -- and `-Baseline` pins the state that otherwise varies run to run:

| Key | Baseline | Why |
|:---|:---|:---|
| `language` | `en` | The dev machine's saved locale is `de`; an audit that starts in German silently mixes the locale pass into every other pass |
| `themeMode` | `light` | Same reason, for [[theme-and-locales]] |
| `version` | pubspec version | Otherwise `initRoot` takes the version-changed branch |
| `LastChangelogVersion` | pubspec version | Suppresses the changelog dialog, which fetches from GitHub and lands on top of the first screenshot |
| `RatingPromptDone` | `true` | See below -- this one bites specifically *because* of `-ForcePro` |
| `LastMotd` | today | Suppresses the once-a-day motd status bar |
| `MoveOp_Distro`, `MoveOp_BackupPath` | removed | Suppresses the "Recovery Detected" dialog left behind by an interrupted move |

**`WSLM_FORCE_PRO=true` also makes the app look Store-installed.** The flag is read in
`LicenseManager._detectStoreInstall()` (`lib/api/license_manager.dart:70`), so it turns
`isStoreLicensed` -- not just `isPro` -- true. `maybeShowRatingPrompt()`
(`lib/dialogs/rating_dialog.dart:20`) gates on exactly that, and this machine has
`InstancesCreated = 27`, well past the threshold of 3. Result: the first launch of the
audit build opened on a modal rating dialog covering the centre of the window
(`00-baseline-1400x860-home.png`, first take). Pre-setting `RatingPromptDone` is what
removes it. Not a product bug -- a real Store user who has created 27 instances is meant
to see that prompt -- but it does mean **an unprepared `-ForcePro` run is not a clean
baseline.**

Pro reachability was verified rather than assumed: the License screen renders
"Pro Plan -- Bought once in the Microsoft Store" under the audit build
(`01-baseline-1400x860-license-pro-check.png`).

### Traps carried over from Phase 01

- `resize.ps1` uses `MoveWindow`, never `ShowWindow(SW_RESTORE)` -- the app restores its
  saved geometry a moment after the window appears and a restore-based resize loses the
  race, silently snapping back.
- `shot.ps1` captures `DWMWA_EXTENDED_FRAME_BOUNDS`, not `GetWindowRect`, so a "1400x860"
  request produces a 1400x860 PNG with no 7px desktop bleed on each edge.
- Other windows steal the foreground; `focus.ps1` escalates to minimising the thief. Do
  not take a screenshot without letting it run first -- the capture reads real screen
  pixels and bakes in anything overlapping.
- The toolkit scripts must stay pure ASCII (Windows PowerShell 5.1 reads a BOM-less file
  as ANSI, and one em dash then breaks a string dozens of lines away).

### Screenshot naming

`<nn>-<area>-<state>[-<theme|locale|width>].png`, e.g.
`02-baseline-900x860-home-narrow.png`. Findings cite the filename, not a path.

## Findings

All six passes are complete: **214 findings**, every one carrying an area, a
`file:line`, a severity, an effort estimate and either a screenshot or an explicit
`_measured_` / `_source-derived_` marker. Severity is
**blocker** (a user cannot complete the task, or the app looks broken) /
**major** (completable but confusing, wrong or ugly enough to notice) /
**nit** (polish). Effort is a rough implementation estimate for Phase 08.

| Area | Findings | blocker | major | nit | S | M | L |
|:---|---:|---:|---:|---:|---:|---:|---:|
| [[list-and-navigation]] | 26 | 0 | 12 | 14 | 23 | 3 | 0 |
| [[create-and-install]] | 40 | 0 | 23 | 17 | 33 | 7 | 0 |
| [[settings-and-tools]] | 62 | 2 | 25 | 35 | 58 | 4 | 0 |
| [[pro-surfaces]] | 46 | 5 | 25 | 16 | 39 | 6 | 1 |
| [[theme-and-locales]] | 18 | 3 | 9 | 6 | 13 | 5 | 0 |
| [[interaction-and-a11y]] | 22 | 4 | 13 | 5 | 15 | 7 | 0 |
| **Total** | **214** | **14** | **107** | **93** | **181** | **32** | **1** |

The [ordered fix list](#ordered-fix-list) below regroups all 214 by root cause into 20
work items -- that, not this table, is what Phase 08 works from.

| ID | Finding | Area | Where | Severity | Effort | Screenshot |
|:---|:---|:---|:---|:---|:---|:---|
| LN-01 | Distro name ellipsised at half the row width; ~480px sits empty beside it (`Expanded` + `Flexible` both flex 1 split 50/50) | [[list-and-navigation]] | `list_item.dart:88` | major | S | `18-list-1400x860-long-name.png` |
| LN-02 | Running and stopped rows misalign by ~30px; name jumps sideways when a distro starts/stops | [[list-and-navigation]] | `list_item.dart:70` | major | S | `10-list-1400x860-home.png` |
| LN-03 | Toggling the AI panel collapses every expanded row and restarts the list -- a new `GlobalKey` per build | [[list-and-navigation]] | `home_screen.dart:109` | major | S | `15`/`16-list-expanded-*-aitoggle.png` |
| LN-04 | Nine identical unlabelled icon buttons, Delete between Cleanup and Settings, no destructive styling | [[list-and-navigation]] | `list_item.dart:229` | major | M | `12b-list-actionbar-zoom.png` |
| LN-05 | `visual_studio_for_windows` is a solid glyph among eight outlines | [[list-and-navigation]] | `list_item.dart:281` | nit | S | `12b-list-actionbar-zoom.png` |
| LN-06 | Rename / disk-usage icons unreadable; save-template and copy near-identical | [[list-and-navigation]] | `list_item.dart:238` | nit | S | `12b-list-actionbar-zoom.png` |
| LN-07 | Expanded row ~85% empty with no hint that snippets fill it | [[list-and-navigation]] | `list_item.dart:188` | nit | S | `12-list-1400x860-row-expanded.png` |
| LN-08 | Header icons default size, action-bar icons pinned to 16px, same row | [[list-and-navigation]] | `list_item.dart:62` | nit | S | `12-list-1400x860-row-expanded.png` |
| LN-09 | Hovering a row highlights only the chevron 660px away | [[list-and-navigation]] | `list_item.dart:52` | nit | S | `11-list-1400x860-row-hover.png` |
| LN-10 | BETA badge paints over the AI Workspace icon in compact mode, hiding the only affordance | [[list-and-navigation]] | `panelist.dart:52` | major | S | `13b-list-compact-betabadge-zoom.png` |
| LN-11 | Snippets and Templates icons indistinguishable at 16px | [[list-and-navigation]] | `panelist.dart:26` | nit | S | `13b-list-compact-betabadge-zoom.png` |
| LN-12 | No visible keyboard focus indicator anywhere on home -- six Tabs, zero pixels changed (**re-diagnosed by IA-01: focus was not moving; a ring does exist**) | [[list-and-navigation]] | `root_screen.dart:222` | major | M | `17-list-tab-1..6.png` |
| LN-13 | Back button permanently disabled and inert; renders near-white (enabled-looking) in dark | [[list-and-navigation]] | `root_screen.dart:144` | major | S | `26b-back-dark.png` |
| LN-14 | "Dark Mode" toggle label hardcoded English in all nine locales | [[list-and-navigation]] | `root_screen.dart:212` | major | S | `25-nav-dark-mode.png` |
| LN-15 | Nav labels mix Title Case and sentence case | [[list-and-navigation]] | `en.json` | nit | S | `10-list-1400x860-home.png` |
| LN-16 | Mount Disk / About open modals but look like destinations -- should be `PaneItemAction` | [[list-and-navigation]] | `panelist.dart:82` | nit | S | `23-nav-mountdisk-action.png` |
| LN-17 | List error dumps `Exception: ...` verbatim; three hardcoded English strings | [[list-and-navigation]] | `list.dart:129` | major | S | `21-list-remote-error.png` |
| LN-18 | Error state offers no remedy and no route back to local WSL; Retry repeats the same failure | [[list-and-navigation]] | `list.dart:128` | major | M | `21-list-remote-error.png` |
| LN-19 | "Diagnose with AI" shown to free users, then answers with an upsell toast | [[list-and-navigation]] | `ai_diagnosis.dart:13` | nit | S | `21-list-remote-error.png` |
| LN-20 | Loading top-anchored vs centred results: content jumps 330px; hardcoded string; no cancel | [[list-and-navigation]] | `list.dart:166` | nit | S | `20-list-remote-loading.png` |
| LN-21 | Empty-state CTA and the AI chat button collide in the bottom-right corner | [[list-and-navigation]] | `list.dart:91` | major | S | _source-derived_ |
| LN-22 | Empty-state copy merges two unrelated states and gives no next step | [[list-and-navigation]] | `en.json` | major | S | _source-derived_ |
| LN-23 | Truncated distro names have no tooltip and no way to read them in full | [[list-and-navigation]] | `list_item.dart:92` | nit | S | `19-list-900x860-long-name-narrow.png` |
| LN-24 | AI chat button nearly invisible in both themes; hardcoded `Colors.grey` / `Colors.white` | [[list-and-navigation]] | `home_screen.dart:163` | nit | S | `26-list-1400x860-home-dark.png` |
| LN-25 | Size column unlabelled; silently blanks on failure; never says it is VHDX-on-disk | [[list-and-navigation]] | `list.dart:120` | nit | S | `10-list-1400x860-home.png` |
| LN-26 | Start stays enabled and still says "Start" on a running distro | [[list-and-navigation]] | `list_item.dart:56` | nit | S | `10-list-1400x860-home.png` |
| CI-01 | Error banner keeps showing a failure the user already fixed; two contradictory messages at once | [[create-and-install]] | `create_screen.dart:61` | major | S | `33-create-duplicate-name.png` |
| CI-02 | Duplicate name reported twice simultaneously, in two different visual styles | [[create-and-install]] | `create_dialog.dart:501` | major | S | `34-create-duplicate-submit.png` |
| CI-03 | Inline validation message is hardcoded `Colors.red`, bold 12px, unlike every other error | [[create-and-install]] | `create_dialog.dart:507` | nit | S | `33-create-duplicate-name.png` |
| CI-04 | Name silently rewritten (`[^A-Za-z0-9]` -> `_`); an all-non-ASCII name becomes `___` | [[create-and-install]] | `create_dialog.dart:149` | major | S | `36b-create-name-nonascii-zoom.png` |
| CI-05 | Create and Copy sanitise names by different rules; Copy skips the duplicate check | [[create-and-install]] | `copy_dialog.dart:71` | major | M | _source-derived_ |
| CI-06 | Name field has no label -- placeholder only -- while the field below it gets an `InfoLabel` | [[create-and-install]] | `create_dialog.dart:488` | nit | S | `31-create-1400x860-default.png` |
| CI-07 | Name field shows a clear (X) button when the field is empty | [[create-and-install]] | `create_dialog.dart:492` | nit | S | `31-create-1400x860-default.png` |
| CI-08 | Changing Source Type keeps the old value: a catalogue pick sits in "Path to RootFS Archive" | [[create-and-install]] | `create_dialog.dart:425` | major | S | `44-create-source-switch-stale.png` |
| CI-09 | One static tooltip for a field that means six different things; it covers the Source Type box | [[create-and-install]] | `create_dialog.dart:558` | nit | S | `70-create-wrong-tooltip-localdocker.png` |
| CI-10 | "No results" panel repurposed as a fake suggestion row; three hardcoded English strings | [[create-and-install]] | `create_dialog.dart:601` | major | S | `69-create-docker-image.png` |
| CI-11 | `snapshot.hasError` branch is literally empty; no loading state; future refetched per build | [[create-and-install]] | `create_dialog.dart:586` | nit | S | _source-derived_ |
| CI-12 | "Create default user" + empty username silently creates no user and reports success | [[create-and-install]] | `create_dialog.dart:337` | major | S | `41-create-user-toggle.png` |
| CI-13 | Password step opens an external console with no warning and is not awaited | [[create-and-install]] | `wsl.dart:1255` | major | M | _source-derived_ |
| CI-14 | Cancel disabled for the whole install while the nav pane stays live; no way to abort | [[create-and-install]] | `create_screen.dart:127` | major | M | `48-create-progress.png` |
| CI-15 | Create button collapses to a 38px spinner square; the action row jumps sideways | [[create-and-install]] | `create_screen.dart:117` | nit | S | `48-create-progress.png` |
| CI-16 | Progress is a text percentage in a corner toast and stalls at "Downloading 100%" through import | [[create-and-install]] | `create_dialog.dart:119` | major | M | `52-create-after.png` |
| CI-17 | After a failure the "Creating instance..." spinner keeps running indefinitely | [[create-and-install]] | `create_dialog.dart:166` | major | S | `57-create-error-stuck-spinner.png` |
| CI-18 | Status messages never expire and follow the user across screens for minutes | [[create-and-install]] | `root_screen.dart:83` | major | S | `68-qa-download-invisible-selection.png` |
| CI-19 | Every status message renders `InfoBarSeverity.info`; "ERROR:" gets a blue info icon | [[create-and-install]] | `notify.dart:66` | major | S | `63b-copy-empty-name-toast.png` |
| CI-20 | Messages carry severity in shouting capitals ("DONE:", "ERROR:", "WARNING:") | [[create-and-install]] | `en.json:30` | nit | S | `53-create-importing.png` |
| CI-21 | Two near-identical strings for one condition (`entername-text` / `errorentername-text`) | [[create-and-install]] | `en.json:31` | nit | S | _source-derived_ |
| CI-22 | Raw WSL stderr shown verbatim with its error code -- and in the Windows locale, not the app's | [[create-and-install]] | `create_dialog.dart:291` | major | M | `56-create-error-state.png` |
| CI-23 | Only remedy offered is "Diagnose with AI"; with no key it answers with a go-to-Settings toast | [[create-and-install]] | `ai_diagnosis.dart:20` | major | M | `58-create-ai-diagnose.png` |
| CI-24 | On a short window the never-expiring status bar covers the Create/Cancel buttons | [[create-and-install]] | `notify.dart:23` | major | S | `60-create-900x400-short.png` |
| CI-25 | Source-type popup covers the page title, the Name field and the source field | [[create-and-install]] | `create_dialog.dart:518` | nit | S | `71-create-sourcetype-covers-form.png` |
| CI-26 | Six source types are developer jargon, ungrouped, with no description line | [[create-and-install]] | `en.json:307` | nit | M | `42-create-sourcetype-open.png` |
| CI-27 | Turnkey warning is a five-line italic paragraph containing `fake_systemd` and a shell pipeline | [[create-and-install]] | `en.json:48` | major | S | `72-create-turnkey-warning.png` |
| CI-28 | `createDialog()` is dead code and carries the opposite button order to the screen replacing it | [[create-and-install]] | `create_dialog.dart:31` | nit | S | _source-derived_ |
| CI-29 | Copy dialog's primary action is a plain `Button`, equal-width with Cancel -- no visual primary | [[create-and-install]] | `base_dialog.dart:62` | nit | S | `62-copy-dialog.png` |
| CI-30 | Copy dialog looks pre-filled (placeholder = source name) and pops before it validates | [[create-and-install]] | `base_dialog.dart:64` | major | S | `63b-copy-empty-name-toast.png` |
| CI-31 | Nothing warns that a copy duplicates the whole disk and stops the source distro | [[create-and-install]] | `copy_dialog.dart:63` | nit | S | `62-copy-dialog.png` |
| CI-32 | Community dialog's button order is reversed against every other dialog in the app | [[create-and-install]] | `qa_dialog.dart:151` | major | S | `65-qa-community-dialog.png` |
| CI-33 | Community dialog has no title | [[create-and-install]] | `qa_dialog.dart:133` | nit | S | `65-qa-community-dialog.png` |
| CI-34 | Selecting a snippet drops its text contrast from 17.4:1 to 2.49:1 (measured) | [[create-and-install]] | `qa_list.dart:129` | major | S | `66b-qa-selected-zoom.png` |
| CI-35 | Empty search shows a blank 570px panel; selections hidden by the filter are downloaded anyway | [[create-and-install]] | `qa_list.dart:112` | major | S | `67-qa-no-results.png` |
| CI-36 | Snippet download has no progress and no success message; a failure closes as if it worked | [[create-and-install]] | `qa_dialog.dart:158` | major | S | `68-qa-download-invisible-selection.png` |
| CI-37 | Community dialog is full window height, leaving ~300px of dead space around a stray link | [[create-and-install]] | `qa_dialog.dart:135` | nit | S | `65-qa-community-dialog.png` |
| CI-38 | `wsl --install` is a hyperlink that runs an elevated system change, described as text to copy | [[create-and-install]] | `install_dialog.dart:26` | major | S | _source-derived_ |
| CI-39 | "install it with following command" -- missing article, in all nine locales | [[create-and-install]] | `en.json:74` | nit | S | _source-derived_ |
| CI-40 | Hardcoded 20%-black chip invisible in dark theme; `InstallDialog` is an inline panel, not a dialog | [[create-and-install]] | `install_dialog.dart:22` | nit | S | _source-derived_ |
| ST-01 | Leaving Settings by any route other than Save silently discards every edit; no unsaved-changes prompt | [[settings-and-tools]] | `settings_screen.dart:88` | blocker | M | `104`/`105`/`107-settings-save-noop.png` |
| ST-02 | Language is the one setting that persists without Save, and needs a restart to show | [[settings-and-tools]] | `settings_screen.dart:607` | major | S | `110-settings-language-de-selected.png` |
| ST-03 | Save navigates away to Home and never confirms that anything was written | [[settings-and-tools]] | `settings_screen.dart:341` | major | S | `100-settings-after-save.png` |
| ST-04 | "Stop WSL" shuts down every distro, sits beside Save, no confirmation, tooltip repeats the label | [[settings-and-tools]] | `settings_screen.dart:208` | major | S | `102b-stopwsl-tooltip-zoom.png` |
| ST-05 | An invalid `.wslconfig` value saves unchallenged; WSL then rejects it on stderr with exit code 0 | [[settings-and-tools]] | `settings_screen.dart:355` | blocker | M | `98`/`100-settings-after-save.png` |
| ST-06 | The invalid-value warning never appears while typing -- only after an unrelated rebuild | [[settings-and-tools]] | `settings_screen.dart:1595` | major | S | `98` vs `99-settings-warning-after-rebuild.png` |
| ST-07 | The "WSL reported:" panel reads the stderr of two commands that never mention `.wslconfig` | [[settings-and-tools]] | `wsl_capabilities.dart:157` | major | M | `101-settings-wslwarnings.png` |
| ST-08 | Memory/Processors/Swap sliders never render: `SysInfo` reports 0 bytes and 1 core (measured) | [[settings-and-tools]] | `settings_screen.dart:1269` | major | S | `91b-memory-processors-zoom.png` |
| ST-09 | Twenty-six settings are labelled with the raw camelCase `.wslconfig` key, untranslated | [[settings-and-tools]] | `settings_screen.dart:1389` | major | M | `93-settings-globalconfig-4.png` |
| ST-10 | The disabled-control explanation renders at 2.51:1 contrast (measured); the line above it is 6.00:1 | [[settings-and-tools]] | `settings_screen.dart:1412` | major | S | `97-settings-localhostforwarding-disabled.png` |
| ST-11 | The disabled reason repeats the description verbatim, 20px below it | [[settings-and-tools]] | `en.json:414` | nit | S | `97-settings-localhostforwarding-disabled.png` |
| ST-12 | The disabled reason names the raw key rather than the label it points at | [[settings-and-tools]] | `settings_screen.dart:1147` | nit | S | `95-settings-mirrored-disables.png` |
| ST-13 | Global-config note tells a GUI user to run `wsl --shutdown`; the button for it is 400px below | [[settings-and-tools]] | `en.json:117` | nit | S | `90-settings-globalconfig-1.png` |
| ST-14 | Every footer button's tooltip is a copy of its own visible label | [[settings-and-tools]] | `settings_screen.dart:192` | nit | S | `102b-stopwsl-tooltip-zoom.png` |
| ST-15 | "true (Default)" and "Not set — using the default" state one fact twice, on one row, x12 | [[settings-and-tools]] | `settings_screen.dart:1491` | nit | S | `93-settings-globalconfig-4.png` |
| ST-16 | An enumeration can never be returned to unset -- no "not set" item and no undo, unlike the booleans | [[settings-and-tools]] | `settings_screen.dart:1527` | major | S | `95-settings-mirrored-disables.png` |
| ST-17 | The enumeration flyout covers its own field and the two settings below, and marks no current value | [[settings-and-tools]] | `settings_screen.dart:1544` | nit | S | `94-settings-networkingmode-open.png` |
| ST-18 | Four unlabelled MCP icon buttons: no tooltip, no `MergeSemantics`, two identical copy glyphs | [[settings-and-tools]] | `settings_screen.dart:809` | major | S | `86-settings-mcp-on.png` |
| ST-19 | One click regenerates the MCP token -- no confirm, no toast, no notice that clients break (measured) | [[settings-and-tools]] | `settings_screen.dart:823` | major | S | `87`/`88-settings-mcp-token-*-crop.png` |
| ST-20 | The public-internet warning shows whenever MCP is on, contradicting the hint two lines above it | [[settings-and-tools]] | `settings_screen.dart:834` | major | S | `86-settings-mcp-on.png` |
| ST-21 | Copy buttons give no feedback at all | [[settings-and-tools]] | `settings_screen.dart:783` | nit | S | `86-settings-mcp-on.png` |
| ST-22 | Tunnel error is a raw `e.toString()` in hardcoded `Colors.red` | [[settings-and-tools]] | `settings_screen.dart:889` | nit | S | _source-derived_ |
| ST-23 | Sync group: no explanation, a plaintext example password in a masked field, and a non-sync setting | [[settings-and-tools]] | `settings_screen.dart:1004` | nit | S | `89-settings-sync.png` |
| ST-24 | "Remote SSH target" stays enabled while the toggle that uses it is off | [[settings-and-tools]] | `settings_screen.dart:556` | nit | S | `82-settings-general.png` |
| ST-25 | Path settings show their effective value as a grey placeholder, so set and unset look identical | [[settings-and-tools]] | `settings_screen.dart:436` | nit | S | `82-settings-general.png` |
| ST-26 | Save materialises a Docker repository default the user never chose | [[settings-and-tools]] | `settings_screen.dart:282` | nit | S | `83-settings-docker.png` |
| ST-27 | Opening the per-distro settings dialog boots the distro (measured: stopped then running) | [[settings-and-tools]] | `settings_dialog.dart:666` | major | S | `113` then `114-distro-settings-loaded.png` |
| ST-28 | Cancel does not cancel: every `wsl.conf` key writes to the distro on change, not on Save | [[settings-and-tools]] | `settings_dialog.dart:69` | major | S | `117-distro-settings-time-expanded.png` |
| ST-29 | Four irreversible actions styled identically to the Expander headers directly above them | [[settings-and-tools]] | `settings_dialog.dart:466` | major | S | `116-distro-settings-bottom.png` |
| ST-30 | The sync buttons' tooltips ("Upload"/"Download") do not match their labels | [[settings-and-tools]] | `settings_dialog.dart:175` | nit | S | `116-distro-settings-bottom.png` |
| ST-31 | "Start/Stop serving on network" never shows which state it is in; `isSyncing` is never persisted | [[settings-and-tools]] | `settings_dialog.dart:108` | nit | S | `116-distro-settings-bottom.png` |
| ST-32 | A twenty-control form capped at 500x500, three fields visible at a time | [[settings-and-tools]] | `settings_dialog.dart:60` | nit | S | `114-distro-settings-loaded.png` |
| ST-33 | The dialog is titled "Settings" with no distro name -- same word as the app-wide screen | [[settings-and-tools]] | `settings_dialog.dart:48` | nit | S | `114-distro-settings-loaded.png` |
| ST-34 | The same "unset" concept has two visual languages; the dialog's looks like a hyperlink | [[settings-and-tools]] | `settings_dialog.dart:528` | nit | S | `117-distro-settings-time-expanded.png` |
| ST-35 | The user section labels itself twice and hosts an orphaned parenthetical between two groups | [[settings-and-tools]] | `settings_dialog.dart:157` | nit | S | `118-distro-settings-userfield.png` |
| ST-36 | Loading is an unlabelled spinner for 4s+ with Cancel and Save both enabled | [[settings-and-tools]] | `settings_dialog.dart:722` | nit | S | `113-distro-settings-dialog.png` |
| ST-37 | A template under ~5MB formats to "0 GB" and is silently removed from the list | [[settings-and-tools]] | `template_screen.dart:126` | major | S | _source-derived_ |
| ST-38 | Deleting a template asks "Delete instance ... permanently? / If you delete this Distro..." | [[settings-and-tools]] | `template_screen.dart:185` | major | S | `121-templates-delete-confirm.png` |
| ST-39 | "Create a new instance" opens a dialog titled "Copy", about "the WSL instance" | [[settings-and-tools]] | `template_screen.dart:158` | major | S | `122-templates-create-dialog.png` |
| ST-40 | Template delete is a bare icon 900px from the labelled buttons, no tooltip, no destructive styling | [[settings-and-tools]] | `template_screen.dart:182` | nit | S | `120-templates-expanded.png` |
| ST-41 | No title, no explanation of what a template is, and no way to create one from this screen | [[settings-and-tools]] | `template_screen.dart:86` | nit | S | `119-templates-empty.png` |
| ST-42 | Template sizes render as "0.01 GB" | [[settings-and-tools]] | `templates.dart` | nit | S | `119-templates-empty.png` |
| ST-43 | The new-instance name box looks pre-filled -- the placeholder is the template's own name | [[settings-and-tools]] | `base_dialog.dart:64` | nit | S | `122-templates-create-dialog.png` |
| ST-44 | The disk about to be mounted is identified by a truncated, tooltip-less string | [[settings-and-tools]] | `mount_dialog.dart:334` | major | S | `123-mount-dialog-physical.png` |
| ST-45 | The primary button silently no-ops on an empty required field (measured on Unmount) | [[settings-and-tools]] | `mount_dialog.dart:82` | major | S | `125-mount-unmount-empty-noop.png` |
| ST-46 | Nothing says a physical mount needs elevation and detaches the disk from Windows until it fails | [[settings-and-tools]] | `mount_dialog.dart:232` | major | S | `123-mount-dialog-physical.png` |
| ST-47 | Three radio buttons used as a tab strip; the title stays "Mount Disk" in unmount mode | [[settings-and-tools]] | `mount_dialog.dart:266` | nit | S | `124-mount-dialog-unmount.png` |
| ST-48 | With nothing mounted the picker vanishes instead of saying the list is empty | [[settings-and-tools]] | `mount_dialog.dart:512` | nit | S | `124-mount-dialog-unmount.png` |
| ST-49 | The mount-options placeholder is cut off mid-clause with no tooltip | [[settings-and-tools]] | `en.json` | nit | S | `123-mount-dialog-physical.png` |
| ST-50 | Partition / Filesystem Type labels sit 18px apart vertically | [[settings-and-tools]] | `mount_dialog.dart:374` | nit | S | `126-mount-dialog-vhd.png` |
| ST-51 | The VHD browse button uses a different folder glyph from every other picker, and no tooltip | [[settings-and-tools]] | `mount_dialog.dart:428` | nit | S | `126-mount-dialog-vhd.png` |
| ST-52 | The dialog never says which distro the disk lands in or where it appears | [[settings-and-tools]] | `mount_dialog.dart:315` | nit | S | `123-mount-dialog-physical.png` |
| ST-53 | Snippet Save with an empty name silently does nothing -- the error branch is `// Error` | [[settings-and-tools]] | `actions_screen.dart:234` | major | S | `129-actions-save-empty-noop.png` |
| ST-54 | Deleting a snippet asks "Delete instance ... permanently? / If you delete this Distro..." | [[settings-and-tools]] | `actions_screen.dart:330` | major | S | `133b-actions-delete-confirm-zoom.png` |
| ST-55 | Expanding a one-line snippet opens a 430px panel that is 97% empty | [[settings-and-tools]] | `actions_screen.dart:354` | major | S | `132-actions-expanded.png` |
| ST-56 | One object, four names: Snippets / snippet / "Name of setting" / quick action | [[settings-and-tools]] | `actions_screen.dart:76` | nit | S | `128-actions-editor.png` |
| ST-57 | "(by you)" is hardcoded English and "[v0.0.0]" invented; measured 4.41:1 and 3.96:1, both sub-AA | [[settings-and-tools]] | `actions_screen.dart:270` | nit | S | `132-actions-expanded.png` |
| ST-58 | The code editor has no frame, background or label -- 580px of invisible click target | [[settings-and-tools]] | `actions_screen.dart:415` | nit | S | `128-actions-editor.png` |
| ST-59 | The editor hardcodes `atomOneLightTheme`, so syntax colours ignore the app theme | [[settings-and-tools]] | `actions_screen.dart:451` | nit | S | _source-derived_ |
| ST-60 | Nothing says a snippet is a root bash script in a distro, and it cannot be run from this screen | [[settings-and-tools]] | `actions_screen.dart:373` | nit | S | `127-actions-empty.png` |
| ST-61 | Two "add" affordances in opposite corners; "Add Community snippets" capitalises its middle word | [[settings-and-tools]] | `actions_screen.dart:109` | nit | S | `127-actions-empty.png` |
| ST-62 | "Cancel" is the left button in three dialogs and the right button in the one that deletes things | [[settings-and-tools]] | `base_dialog.dart` | major | S | `121` vs `113`/`123`/`135` |
| PS-01 | Purchase table sells Script Generation and Smart Recommendations; neither has a reachable implementation | [[pro-surfaces]] | `license_screen.dart:248` | blocker | L | `172-free-license.png` |
| PS-02 | The purchase screen never shows a price -- no number anywhere on it | [[pro-surfaces]] | `license_screen.dart:202` | blocker | S | `172-free-license.png` |
| PS-03 | Comparison glyphs are icon-only with no semantics; the "not included" mark measures 1.85:1 | [[pro-surfaces]] | `license_screen.dart:258` | major | S | `172b-license-table-zoom.png` |
| PS-04 | The Pro user never sees the feature list -- it lives in the non-Pro branch only | [[pro-surfaces]] | `license_screen.dart:74` | major | S | `144-license-pro.png` |
| PS-05 | No restore-purchase or support path if MSIX entitlement detection is wrong | [[pro-surfaces]] | `license_manager.dart:62` | major | M | _source-derived_ |
| PS-06 | Nav item says "Upgrade to Pro"; the page it opens is headed "License" | [[pro-surfaces]] | `panelist.dart:96` | nit | S | `172-free-license.png` |
| PS-07 | The store button is the app's only `canLaunchUrl`-gated launch -- the bug the codebase works around elsewhere | [[pro-surfaces]] | `license_screen.dart:40` | nit | S | _verified passing here_ |
| PS-08 | `ProBadge` / `ProFeatureWrapper` / `UpgradePrompt` have no call sites; six gates, six vocabularies | [[pro-surfaces]] | `pro_badge.dart:6` | major | S | _source-derived_ |
| PS-09 | Amber means BETA and NEW; both badges measure 1.35:1 / 1.37:1 | [[pro-surfaces]] | `beta_badge.dart:7` | major | S | `171b-free-navfooter-zoom.png` |
| PS-10 | Compact nav draws the BETA badge on top of the AI Workspace icon and its selection bar | [[pro-surfaces]] | `panelist.dart:52` | major | S | `150b-compact-betabadge-zoom.png` |
| PS-11 | The free MCP toggle looks enabled; clicking it jumps to License and discards unsaved settings | [[pro-surfaces]] | `settings_screen.dart:748` | major | S | `178-free-mcp-toggle-jump.png` |
| PS-12 | Disabled BYOK fields give no per-field reason and their placeholders read as filled-in values | [[pro-surfaces]] | `settings_screen.dart:660` | nit | S | `176-free-settings-byok.png` |
| PS-13 | The paywall drops the BETA badge the same page shows in the Pro build | [[pro-surfaces]] | `ai_workspace_screen.dart:359` | nit | S | `174-free-aiws-paywall.png` |
| PS-14 | The only entry to the AI Assistant is a 48px circle at 1.29:1 against the page | [[pro-surfaces]] | `home_screen.dart:146` | major | S | `140b-pro-aifab-zoom.png` |
| PS-15 | One `isBusy` flag spins the wrong buttons: Start spins Uninstall, dashboard spins Stop+Uninstall, uninstall spins Start | [[pro-surfaces]] | `ai_workspace_screen.dart:630` | blocker | M | `152`/`155`/`169` |
| PS-16 | A tool stuck in "Starting up..." cannot be stopped -- only Uninstall is enabled | [[pro-surfaces]] | `ai_workspace_screen.dart:637` | major | S | `157-aiws-openwebui-start.png` |
| PS-17 | Status bar still read "Starting Open WebUI..." 105s after it was running and through two later stops | [[pro-surfaces]] | `service.dart:1063` | major | S | `158`/`159` |
| PS-18 | A six-minute install has no cancel and its one progress line froze for 2 minutes (0 px changed) | [[pro-surfaces]] | `ai_workspace_screen.dart:600` | major | M | `165`/`166`/`167` |
| PS-19 | The badge read "Not Installed" for the entire six-minute install | [[pro-surfaces]] | `ai_workspace_screen.dart:551` | major | S | `165-aiws-install-progress-60s.png` |
| PS-20 | "stopped" 2.70:1 and "Starting up..." 3.84:1 both fail AA; stopped is the most-shown state | [[pro-surfaces]] | `ai_workspace_screen.dart:723` | major | S | `141c-aiws-badges-zoom.png` |
| PS-21 | Disabled `FilledButton` labels are white on #C6C6C6 -- 1.71:1, and 2 of 3 are always disabled | [[pro-surfaces]] | `ai_workspace_screen.dart:712` | major | S | `141b-aiws-card-zoom.png` |
| PS-22 | "Installed" is a permanently disabled button repeating the status badge on the same row | [[pro-surfaces]] | `ai_workspace_screen.dart:620` | major | S | `141-aiws-initial.png` |
| PS-23 | On a running tool Stop is the primary button and Open Dashboard is not | [[pro-surfaces]] | `ai_workspace_screen.dart:644` | major | S | `154-aiws-start-final.png` |
| PS-24 | The `notInstalled` dot renders #323130 -- darker than running or stopped, reads as a bullet | [[pro-surfaces]] | `ai_workspace_screen.dart:740` | nit | S | `141-aiws-initial.png` |
| PS-25 | Three casing conventions in one badge column: "Not Installed" / "Starting up..." / "running" | [[pro-surfaces]] | `en.json` | nit | S | `141-aiws-initial.png` |
| PS-26 | "Installed: cmd://openclaw" -- hardcoded English exposing an internal URI sentinel | [[pro-surfaces]] | `ai_workspace_screen.dart:562` | nit | S | `141-aiws-initial.png` |
| PS-27 | Uninstall confirms with an accent FilledButton where every other destructive dialog uses red | [[pro-surfaces]] | `ai_workspace_screen.dart:313` | major | S | `143-aiws-uninstall-confirm.png` |
| PS-28 | The uninstall dialog names the tool on a bare line, then the sentence says "this tool" | [[pro-surfaces]] | `ai_workspace_screen.dart:317` | nit | S | `143-aiws-uninstall-confirm.png` |
| PS-29 | Uninstall success toast is built by concatenation ("<name> uninstalled successfully") | [[pro-surfaces]] | `ai_workspace_screen.dart:351` | nit | S | `170-aiws-uninstall-done.png` |
| PS-30 | The Open Dashboard tooltip repeats the button's visible label verbatim | [[pro-surfaces]] | `ai_workspace_screen.dart:659` | nit | S | `156-aiws-dashboard-result.png` |
| PS-31 | Page-level failure is hardcoded English wrapping a raw `Exception.toString()` | [[pro-surfaces]] | `ai_workspace_screen.dart:440` | major | M | _source-derived_ |
| PS-32 | A failed stop shows a red `Error:` line under an unchanged green "running" badge | [[pro-surfaces]] | `service.dart:1090` | nit | S | _source-derived_ |
| PS-33 | Send without an API key navigates to Settings and discards the typed question | [[pro-surfaces]] | `ai_chat_panel.dart:42` | blocker | M | `147`/`148b` |
| PS-34 | The chat panel gives no hint it cannot work until Send is pressed; no cancel, no close | [[pro-surfaces]] | `ai_chat_panel.dart:136` | major | S | `145-aichat-empty.png` |
| PS-35 | Clear-history: 14px icon, no tooltip, no `MergeSemantics`, no confirmation, always enabled | [[pro-surfaces]] | `ai_chat_panel.dart:124` | major | S | `145-aichat-empty.png` |
| PS-36 | Chat empty-state hint measures 3.69:1; five hardcoded `Colors.grey` literals in one file | [[pro-surfaces]] | `ai_chat_panel.dart:142` | major | S | `145b-aichat-empty-zoom.png` |
| PS-37 | The user's chat avatar is `FluentIcons.add` -- a plus sign | [[pro-surfaces]] | `ai_chat_panel.dart:294` | nit | S | _source-derived_ |
| PS-38 | At 900px the fixed 360px panel takes 40% of the window and the hint has 17px of margin | [[pro-surfaces]] | `home_screen.dart:104` | nit | S | `149-aichat-narrow900.png` |
| PS-39 | The chat panel's own Upgrade button is unreachable -- the FAB that opens it is Pro-only | [[pro-surfaces]] | `ai_chat_panel.dart:156` | nit | S | `171-free-home.png` |
| PS-40 | The recommendations panel renders raw i18n keys; all three are missing from all nine locales | [[pro-surfaces]] | `recommender_service.dart:34` | blocker | S | `160b-recommendations-zoom.png` |
| PS-41 | The dismiss X writes `DismissedRecommendations` to prefs and changes nothing on screen | [[pro-surfaces]] | `recommendations_panel.dart:110` | major | S | `161-recommendations-after-dismiss.png` |
| PS-42 | `clearDismissed()` adds to the dismissed list, and the "Go to" link calls it too | [[pro-surfaces]] | `recommender_service.dart:101` | major | S | _source-derived_ |
| PS-43 | "Go to Templates" is three English fragments built by string interpolation | [[pro-surfaces]] | `recommendations_panel.dart:98` | major | S | `160b-recommendations-zoom.png` |
| PS-44 | Dismissing every recommendation leaves an empty bordered box titled "Recommendations" | [[pro-surfaces]] | `recommendations_panel.dart:19` | nit | S | _source-derived_ |
| PS-45 | The dismiss X chases the label instead of the right edge; 11px and 10px text | [[pro-surfaces]] | `recommendations_panel.dart:36` | nit | S | `160b-recommendations-zoom.png` |
| PS-46 | Every toast is `InfoBarSeverity.info` with one decoration -- install-failed looks like install-succeeded | [[pro-surfaces]] | `notify.dart:22` | major | M | `167`/`170`/`147` |
| TL-01 | AI Workspace status pill and dot invisible in dark: hardcoded `Colors.grey` `#323130` on a `#333333` card, **1.03:1** (10.50:1 in light) | [[theme-and-locales]] | `ai_workspace_screen.dart:745` | blocker | S | `206-dark-hermes-card-zoom.png` |
| TL-02 | AI chat empty state invisible in dark: hint text **1.07:1**, icon likewise; panel dividers and bubble fills vanish with it | [[theme-and-locales]] | `ai_chat_panel.dart:143` | blocker | S | `207-dark-chat-emptystate-zoom.png` |
| TL-03 | Under the default `ThemeMode.system`, `systemTextColor` returns black -- five call sites hand black text to a dark UI | [[theme-and-locales]] | `theme.dart:161` | major | S | _probe-measured_ |
| TL-04 | The `stopped` pill fails AA in both themes (2.70:1 light, 3.60:1 dark) -- hardcoded `Colors.orange` | [[theme-and-locales]] | `ai_workspace_screen.dart:743` | major | S | `202-dark-aiworkspace.png` |
| TL-05 | The amber BETA pill fails in *light* (**1.40:1**) and passes in dark (5.89:1); the colour is also duplicated as a raw literal in the nav | [[theme-and-locales]] | `beta_badge.dart:10`, `panelist.dart:107` | major | S | `208`/`209-beta-pill-zoom.png` |
| TL-06 | The AI Assistant FAB is **1.02:1** against the page in dark (1.25:1 light); only its border ring makes it findable | [[theme-and-locales]] | `home_screen.dart:163` | major | S | `202-dark-home.png` |
| TL-07 | `systemBackgroundColor` is 30 lines of theme code nothing consumes, and it carries TL-03's bug | [[theme-and-locales]] | `theme.dart:132` | nit | S | _source-derived_ |
| TL-08 | Card, panel and border greys written with six different alphas across five files; no shared constant | [[theme-and-locales]] | `ai_chat_panel.dart:101` | nit | M | _source-derived_ |
| TL-09 | The Mount Disk dialog is entirely English in six of eight non-English locales -- 35..37 of its 40 keys | [[theme-and-locales]] | `lib/i18n/{es,hu,ja,pt,tr,zh_TW}.json` | blocker | M | `22-zh_TW-mount-dialog.png` |
| TL-10 | The CI translation gate is a key-*presence* check; the rule that catches TL-09 exists but is scoped to 60 keys. Widening it fails on 131 locale-key pairs | [[theme-and-locales]] | `locales_test.dart:244` | major | S | _measured_ |
| TL-11 | Turkish translates "instance" as "örnek" (sample) in 10 strings, colliding with 5 that legitimately mean sample | [[theme-and-locales]] | `lib/i18n/tr.json` | major | M | `21-tr-home.png` |
| TL-12 | German's nav pane shows "Home" and "Mount Disk" in English beside ten German entries | [[theme-and-locales]] | `lib/i18n/de.json` | major | S | `21-de-home.png` |
| TL-13 | "AI Workspace" is English in all nine locales -- the only Latin script in the `ja` and `zh_TW` nav panes | [[theme-and-locales]] | `lib/i18n/*.json` | nit | S | `21-ja-home.png` |
| TL-14 | An all-caps `DONE:` log prefix on four success messages, translated eight different ways (Turkish `TAMAM` = "OK") | [[theme-and-locales]] | `lib/i18n/*.json` | nit | S | _source-derived_ |
| TL-15 | 59 English keys nothing renders, translated nine times each; 19 of them are an unshipped subscription flow | [[theme-and-locales]] | `lib/i18n/en.json` | nit | M | _measured_ |
| TL-16 | The three `recommend-*` keys are missing from all nine locales including `en`, so the panel prints its own keys; no tool can see it | [[theme-and-locales]] | `recommender_service.dart:34` | major | S | _source-derived_ |
| TL-17 | 98 Title Case vs 91 sentence case short labels in `en.json`; the drift is inherited by locales that have no Title Case | [[theme-and-locales]] | `lib/i18n/en.json` | major | M | `201-light-create.png` |
| TL-18 | "(Optional)" written three ways across nine labels -- including both ways on the same field | [[theme-and-locales]] | `lib/i18n/en.json` | nit | S | `201-light-create.png` |
| IA-01 | Tab does nothing until the user clicks: focus parks on the Root Focus Scope at launch and after every window switch, with no keyboard way back | [[interaction-and-a11y]] | `root_screen.dart:230` | blocker | M | `301-a11y-tab00..20.png` |
| IA-02 | An invisible 126x62 status bar on every screen takes a tab stop and swallows mouse clicks | [[interaction-and-a11y]] | `notify.dart:27` | major | S | `362-a11y-no-status-message.png` |
| IA-03 | The permanently disabled back arrow is a tab stop on every screen | [[interaction-and-a11y]] | `root_screen.dart:143` | major | S | `301-a11y-tab07.png` |
| IA-04 | Three `GestureDetector` controls -- including the AI panel's only entry point -- cannot be reached or activated by keyboard | [[interaction-and-a11y]] | `home_screen.dart:152` | major | S | `300-a11y-home-baseline.png` |
| IA-05 | Tab order runs content -> app bar -> nav pane, and the row stop lights the chevron 1,100px from the name | [[interaction-and-a11y]] | `root_screen.dart:222` | major | M | `322-a11y-rowfocus-chevron-zoom.png` |
| IA-06 | Two focus rings lit at once on a distro row: the Start button and the expander chevron | [[interaction-and-a11y]] | `list_item.dart:51` | major | S | `342-a11y-doublering-before.png` |
| IA-07 | The focus indicator is a 1px hairline (8.12:1, but one pixel) -- fails WCAG 2.4.13's 2px perimeter | [[interaction-and-a11y]] | fluent `FocusBorder` | nit | S | `356-a11y-dialog-buttons-deletefocus-zoom.png` |
| IA-08 | The delete confirmation's first Tab lands on **Delete**, not Cancel | [[interaction-and-a11y]] | `base_dialog.dart:60` | major | S | `352-a11y-kb-delete-dialog.png` |
| IA-09 | 22 of 38 tap targets have no accessible name; `settings_screen.dart` has 11 of them and zero `MergeSemantics` | [[interaction-and-a11y]] | `settings_screen.dart:421` | blocker | M | _measured_ |
| IA-10 | Not one `Semantics(label:)` in the codebase -- all 18 `Semantics` hits are `MergeSemantics` | [[interaction-and-a11y]] | tree-wide | major | M | _measured_ |
| IA-11 | Seven icon-only buttons have no tooltip either, so they are unlabelled for sighted users too | [[interaction-and-a11y]] | `template_screen.dart:182` | major | S | `300-a11y-home-baseline.png` |
| IA-12 | Start, stop and delete post no spinner and no message; delete says "DONE" while the row is still listed | [[interaction-and-a11y]] | `list_item.dart:126` | major | M | `346`/`357-a11y-kb-*.png` |
| IA-13 | `WSLApi.start` is `async void`, so the failure catch is unreachable and the "started" toast fires unconditionally | [[interaction-and-a11y]] | `wsl.dart:517` | blocker | S | _source-derived_ |
| IA-14 | The only control on a running operation is a X that hides the progress and leaves it running | [[interaction-and-a11y]] | `notify.dart:63` | major | M | _source-derived_ |
| IA-15 | `statusMsg`'s `severity` parameter is unreachable -- `Notify.message`'s type has no such parameter | [[interaction-and-a11y]] | `root_screen.dart:58` | nit | S | _source-derived_ |
| IA-16 | A failed mount shows a dialog whose entire body is "Exception:" -- wsl.exe wrote the reason to stdout, the app reads stderr | [[interaction-and-a11y]] | `mount_service.dart:338` | blocker | S | `382-a11y-mount-error-raw-exception.png` |
| IA-17 | Five messages interpolate a raw exception; two render "Error: Exception: ..." | [[interaction-and-a11y]] | `docker_images.dart:640` | major | S | _measured_ |
| IA-18 | Sixteen hardcoded English messages, three of them describing the implementation ("Exporting, removing and importing back...") | [[interaction-and-a11y]] | `list_item.dart:385` | major | M | _measured_ |
| IA-19 | The "disk is offline" hint is gated on English Windows text and cannot fire on a localized host | [[interaction-and-a11y]] | `mount_dialog.dart:233` | major | S | _source-derived_ |
| IA-20 | Two strings tell the user to run `wsl --shutdown` / install xterm; one of them sits above a button that does it | [[interaction-and-a11y]] | `en.json:117` | nit | S | _source-derived_ |
| IA-21 | The recommendation link label is built with an if/else on a route string, in hardcoded English | [[interaction-and-a11y]] | `recommendations_panel.dart:98` | nit | S | _source-derived_ |
| IA-22 | The snippet list signals hover by dropping the row to 50% opacity -- less contrast, not more | [[interaction-and-a11y]] | `hoverable.dart:33` | nit | S | _source-derived_ |

## Phase 08 verification captures

Re-captured on **2026-08-30** with the Phase 07 toolkit and baseline
(`prefs.ps1 -Baseline`, `launch.ps1 -Mode run -ForcePro -Width 1400 -Height
860`), in `.maestro/screenshots/phase-08/` — gitignored like the Phase 07 set.
Diffed by eye against the Phase 07 captures named per finding:

| Capture | Confirms, against Phase 07 |
|:---|:---|
| `00-home-1400x860.png` | vs `10-list-1400x860-home.png`: names get the row width (LN-01), running/stopped rows align (LN-02, the reserved stop slot), the size column is text-sized, the running row's first icon is a terminal (LN-26), the AI FAB is accent-filled (TL-06), nav reads sentence case (LN-15) with the `{}` Snippets icon (LN-11) |
| `01-aiworkspace.png` | vs `141-aiws-initial.png`: one primary per card state — the dead "Installed" button is gone (PS-22), "Installed: openclaw" without the `cmd://` sentinel (PS-26), "Not installed"/"Stopped" badges in the AA palette (PS-20, PS-25), the dimmed notInstalled dot (PS-24) |
| `02-license.png` | vs `172-free-license.png`: the Pro build shows the comparison table (PS-04), four rows — Script Generation and Smart Recommendations gone (PS-01), legible not-included marks (PS-03) |
| `04-snippets.png` | vs `127-actions-empty.png`: both add buttons grouped bottom-right (ST-61) |
| `05-templates.png` | vs `119`/`120`: title + explanation (ST-41), `test-4 (10 MB)` — the sub-GB size that used to format to "0.01 GB" or hide the row (ST-37, ST-42) |
| `06-home-dark.png`, `07-aiworkspace-dark.png` | vs `202-dark-aiworkspace.png`: the status pills and dots that measured 1.03:1 are legible in dark (TL-01, TL-04) |
| `08-chat-panel-dark.png` | vs `203-dark-aichat.png`, `145-aichat-empty.png`: the panel is visible in dark with readable empty state (TL-02), says up front it needs a key with an Open Settings action, and has its own close control (PS-34); Clear is disabled over the empty history (PS-35) |

Not re-captured: the flows that need state this host does not have mid-run (a
real create, a failing mount, the non-Pro paywall) — their fixes are covered
by the widget tests named in each work item's section.

## Per-area files

| File | Covers | Status |
|:---|:---|:---|
| [[list-and-navigation]] | distro list, list rows, nav pane, title bar, narrow width | **done** -- 26 findings (LN-01..LN-26) |
| [[create-and-install]] | create screen, install/copy/QA dialogs | **done** -- 40 findings (CI-01..CI-40) |
| [[settings-and-tools]] | app settings, per-distro settings, templates, mount, actions | **done** -- 62 findings (ST-01..ST-62) |
| [[pro-surfaces]] | AI Workspace, license, badges, AI chat, recommendations, MCP | **done** -- 46 findings (PS-01..PS-46) |
| [[theme-and-locales]] | dark/light diff, all nine locales, text quality | **done** -- 18 findings (TL-01..TL-18) |
| [[interaction-and-a11y]] | tab order, tooltips, long operations, error text | **done** -- 22 findings (IA-01..IA-22) |

## Ordered fix list

Input to Phase 08. **All 214 findings appear here exactly once** (verified by
`Working/batch_tally.dart`), grouped into 20 work items and ordered most impactful
first. The grouping is by *root cause and file*, not by audit area, because most
findings are one bug seen from several screens: 22 unnamed tap targets are one
`MergeSemantics` pass, six invisible controls are one theme-token pass, and eleven
"raw exception in the UI" findings are one error-mapping pass. Fixing them one screen
at a time would mean touching `notify.dart`, `theme.dart` and `en.json` twenty times
each.

Each work item is self-contained -- it can be a single commit and a single PR -- and
the `Fix` column is the change to make, not a restatement of the finding. Follow the
ID back to the master table above for the evidence and the screenshot.

### Order and totals

| # | Work item | Findings | Severity | Effort | Main files |
|:---|:---|---:|:---|:---|:---|
| FIX-01 | [Stop discarding what the user typed](#fix-01----stop-discarding-what-the-user-typed) | 7 | 2 blocker, 5 major | 5S 2M | `settings_screen.dart`, `settings_dialog.dart`, `ai_chat_panel.dart` |
| FIX-02 | [Report what actually happened](#fix-02----report-what-actually-happened) | 10 | 1 blocker, 8 major, 1 nit | 9S 1M | `wsl.dart`, `list_item.dart`, `create_dialog.dart`, `service.dart` |
| FIX-03 | [One honest notification surface](#fix-03----one-honest-notification-surface) | 9 | 6 major, 3 nit | 7S 2M | `notify.dart`, `root_screen.dart`, `en.json` |
| FIX-04 | [Long operations: moving progress and a way out](#fix-04----long-operations-moving-progress-and-a-way-out) | 7 | 4 major, 3 nit | 3S 4M | `create_screen.dart`, `create_dialog.dart`, `ai_workspace_screen.dart` |
| FIX-05 | [Error text a user can act on](#fix-05----error-text-a-user-can-act-on) | 12 | 1 blocker, 8 major, 3 nit | 7S 5M | `mount_service.dart`, `list.dart`, `list_item.dart`, `docker_images.dart` |
| FIX-06 | [Keyboard operability](#fix-06----keyboard-operability) | 9 | 1 blocker, 7 major, 1 nit | 6S 3M | `root_screen.dart`, `home_screen.dart`, `base_dialog.dart` |
| FIX-07 | [Accessible names and honest tooltips](#fix-07----accessible-names-and-honest-tooltips) | 10 | 1 blocker, 4 major, 5 nit | 8S 2M | `settings_screen.dart`, `template_screen.dart`, `mount_dialog.dart` |
| FIX-08 | [Destructive actions must look and behave destructive](#fix-08----destructive-actions-must-look-and-behave-destructive) | 12 | 9 major, 3 nit | 11S 1M | `list_item.dart`, `settings_dialog.dart`, `template_screen.dart`, `actions_screen.dart` |
| FIX-09 | [One dialog contract](#fix-09----one-dialog-contract) | 11 | 3 major, 8 nit | 11S | `base_dialog.dart`, `create_dialog.dart`, `qa_dialog.dart` |
| FIX-10 | [Contrast and theme tokens](#fix-10----contrast-and-theme-tokens) | 21 | 2 blocker, 11 major, 8 nit | 20S 1M | `theme.dart`, `ai_workspace_screen.dart`, `ai_chat_panel.dart`, `beta_badge.dart` |
| FIX-11 | [Close the localization holes](#fix-11----close-the-localization-holes) | 13 | 2 blocker, 7 major, 4 nit | 11S 2M | `lib/i18n/*.json`, `locales_test.dart`, `recommender_service.dart` |
| FIX-12 | [Copy, casing and terminology](#fix-12----copy-casing-and-terminology) | 14 | 4 major, 10 nit | 10S 4M | `lib/i18n/en.json`, `settings_screen.dart`, `actions_screen.dart` |
| FIX-13 | [Sell only what exists, gate it once](#fix-13----sell-only-what-exists-gate-it-once) | 13 | 2 blocker, 5 major, 6 nit | 10S 2M 1L | `license_screen.dart`, `pro_badge.dart`, `license_manager.dart` |
| FIX-14 | [AI Workspace card lifecycle](#fix-14----ai-workspace-card-lifecycle) | 4 | 1 blocker, 3 major | 3S 1M | `ai_workspace_screen.dart` |
| FIX-15 | [Settings: validate `.wslconfig`, restore the missing controls](#fix-15----settings-validate-wslconfig-restore-the-missing-controls) | 12 | 1 blocker, 4 major, 7 nit | 11S 1M | `settings_screen.dart` |
| FIX-16 | [The create / install form](#fix-16----the-create--install-form) | 11 | 7 major, 4 nit | 10S 1M | `create_dialog.dart`, `copy_dialog.dart`, `qa_list.dart` |
| FIX-17 | [Home list and navigation layout](#fix-17----home-list-and-navigation-layout) | 15 | 6 major, 9 nit | 15S | `list_item.dart`, `list.dart`, `panelist.dart`, `home_screen.dart` |
| FIX-18 | [Recommendations panel](#fix-18----recommendations-panel) | 4 | 2 major, 2 nit | 4S | `recommendations_panel.dart`, `recommender_service.dart` |
| FIX-19 | [AI chat panel](#fix-19----ai-chat-panel) | 3 | 1 major, 2 nit | 3S | `ai_chat_panel.dart`, `home_screen.dart` |
| FIX-20 | [Templates, snippets, mount and the per-distro dialog](#fix-20----templates-snippets-mount-and-the-per-distro-dialog) | 17 | 3 major, 14 nit | 17S | `template_screen.dart`, `actions_screen.dart`, `mount_dialog.dart`, `settings_dialog.dart` |
| | **Total** | **214** | **14 blocker, 107 major, 93 nit** | **181S 32M 1L** | |

### Progress

Each work item's own table carries a `Fixed in` column once it has been worked;
`--` means still open. Rolling total:

| Work item | Fixed | Open | Landed |
|:---|---:|---:|:---|
| FIX-03 -- One honest notification surface | 9 | 0 | 2026-08-28 |
| FIX-02 -- Report what actually happened | 10 | 0 | 2026-08-30 |
| FIX-01 -- Stop discarding what the user typed | 7 | 0 | 2026-08-28 |
| FIX-05 -- Error text a user can act on | 12 | 0 | 2026-08-28 |
| FIX-06 -- Keyboard operability | 9 | 0 | 2026-08-30 |
| FIX-07 -- Accessible names and honest tooltips | 10 | 0 | 2026-08-30 |
| FIX-04 -- Long operations: moving progress and a way out | 7 | 0 | 2026-08-30 |
| FIX-08 -- Destructive actions must look and behave destructive | 12 | 0 | 2026-08-30 |
| FIX-09 -- One dialog contract | 11 | 0 | 2026-08-30 |
| FIX-10 -- Contrast and theme tokens | 21 | 0 | 2026-08-30 |
| FIX-14 -- AI Workspace card lifecycle | 4 | 0 | 2026-08-30 |
| FIX-11 -- Close the localization holes | 13 | 0 | 2026-08-30 |
| FIX-18 -- Recommendations panel | 4 | 0 | 2026-08-30 |
| FIX-12 -- Copy, casing and terminology | 14 | 0 | 2026-08-30 |
| FIX-13 -- Sell only what exists, gate it once | 13 | 0 | 2026-08-30 |
| FIX-15 -- Settings: validate `.wslconfig`, restore the missing controls | 12 | 0 | 2026-08-30 |
| FIX-16 -- The create / install form | 11 | 0 | 2026-08-30 |
| FIX-17 -- Home list and navigation layout | 15 | 0 | 2026-08-30 |
| FIX-19 -- AI chat panel | 3 | 0 | 2026-08-30 |
| FIX-20 -- Templates, snippets, mount and the per-distro dialog | 17 | 0 | 2026-08-30 |

**All 214 findings are closed.**

**Why this order.** FIX-01 to FIX-05 are the ones where the app is *wrong*, not merely
awkward: work vanishes, a failure is reported as a success, a dialog body is the word
`Exception:`. FIX-06 and FIX-07 are the accessibility floor -- the app is currently not
operable by keyboard at all until the user clicks something, which is the single
worst finding in the audit. FIX-08 and FIX-09 are safety and consistency around
irreversible actions. FIX-10 to FIX-12 are cross-cutting passes that each close a
double-digit number of findings in one file. FIX-13 is the paid surface, which sells
two features that do not exist. FIX-14 onward is per-screen work that no longer blocks
anything else.

**Sequencing.** Four items are groundwork and should land before the ones that depend
on them:

- **FIX-03 before FIX-02 and FIX-05.** Both need a `Notify` layer that can express
  failure. Fixing the messages first means rewriting them again.
- **FIX-06 before re-checking LN-12.** LN-12 ("no focus ring on home") was re-diagnosed
  by IA-01: focus was never moving, so nothing could light up. It may close for free.
- **FIX-10 before FIX-13 / FIX-14 / FIX-17.** All three touch the same hardcoded
  `Colors.grey` / `Colors.orange` literals; do the token pass once.
- **FIX-11 before FIX-12.** No point restyling copy that is about to be re-keyed, and
  TL-10's widened CI gate will fail every string FIX-12 adds if it lands second.

**Findings that close together.** PS-40 and TL-16 are the same three missing i18n keys
from two directions. LN-10 and PS-10 are the same overlapping BETA badge. TL-06, PS-14
and LN-24 are the same invisible FAB in two themes. Six or so hours of the estimate
above is shared, not additive.

### FIX-01 -- Stop discarding what the user typed

Two blockers. The app throws away typed input on a navigation the user did not
understand to be destructive, and in one case navigates *itself*.

**Status: all 7 fixed.** The screen-level piece is a new
`UnsavedChangesGuard` (`lib/components/unsaved_changes.dart`): a dirty screen
registers a guard, and every exit route -- each nav-pane item, the app-bar back
button, the window X, and the two in-screen buttons that used to navigate on
their own -- goes through `navigateGuarded` / `confirmLeave` before the next
screen is built. `SettingsPageState` compares a draft snapshot against the last
saved one rather than asking a dozen controls to remember to set a flag, so the
"Unsaved changes" marker and the Discard button appear from the same source of
truth the prompt uses. The save-on-`dispose()` that was supposed to make leaving
commit -- and observably never fired, which is what made ST-01 a blocker rather
than a design choice -- is gone; the contract is now the Save button plus the
prompt. Regression tests: `test/unsaved_changes_test.dart`,
`test/settings_dialog_test.dart` ("Cancel actually cancels").

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| ST-01 | blocker | Track a dirty flag on the Settings draft and intercept every exit route (nav pane, back, window close) with a Save / Discard / Cancel prompt | `unsaved_changes.dart:14`, `unsaved_changes.dart:45`, `router.dart:22`, `panelist.dart:19`, `root_screen.dart:173`, `root_screen.dart:320`, `settings_screen.dart:137`, `settings_screen.dart:154` |
| PS-33 | blocker | Keep the typed question when Send hits a missing API key; offer the key inline or return to the panel with the text intact | `ai_chat_panel.dart:31`, `ai_chat_panel.dart:73`, `ai_chat_panel.dart:234` |
| ST-02 | major | Route language through the same draft-and-Save path as everything else, and apply it live rather than requiring a restart | `settings_screen.dart:331`, `settings_screen.dart:790`, `main.dart:226`, `en.json:154` |
| ST-03 | major | Save stays on the Settings page and confirms in place; it must not navigate to Home | `settings_screen.dart:531`, `settings_screen.dart:538` |
| ST-27 | major | Read `wsl.conf` without booting the distro, or say up front that opening settings will start it | `settings_dialog.dart:794`, `settings_dialog.dart:816` |
| ST-28 | major | Buffer per-distro `wsl.conf` edits and write them on Save, so Cancel actually cancels | `settings_dialog.dart:508`, `settings_dialog.dart:540`, `settings_dialog.dart:79`, `settings_dialog.dart:89` |
| PS-11 | major | The free MCP toggle must upsell in place; it may not navigate to License and drop unsaved settings on the way | `settings_screen.dart:941` |

Two carried consequences worth recording. **ST-27 is answered by asking, not by
avoiding the boot**: there is no way to read `/etc/wsl.conf` without `wsl.exe`,
so a stopped distro now gets a warning InfoBar and a "Start it and read the
settings" button instead of a silently started virtual machine. And **the
language picker previews without persisting**, which needed
`localeResolutionCallback` to prefer `AppTheme.locale` over the stored
preference -- otherwise the stored value would have overridden the preview on
the very rebuild the preview triggers.

### FIX-02 -- Report what actually happened

An operation that failed must not say it succeeded, and one that succeeded must not
leave a spinner running. `IA-13` is the root of the pattern: an `async void` API whose
`catch` is unreachable.

**Status: complete (10 of 10).** The last five were per-screen work in
`qa_dialog.dart`, `mount_dialog.dart`, `actions_screen.dart` and the AI
Workspace card; three of them were the same defect written out three times --
a primary button whose only response to an empty required field was to do
nothing at all.

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| IA-13 | blocker | Change `WSLApi.start` to return `Future<void>`, await it at the call site, and post the toast *after* it resolves -- `Future.delayed(d, Notify.message(...))` calls the function immediately, so remove the delay too | `wsl.dart:522`, `list_item.dart:187` |
| CI-12 | major | Validate the username when "Create default user" is ticked; never report success for a user that was not created | `create_dialog.dart:184`, `create_screen.dart:74` |
| CI-17 | major | Stop the "Creating instance..." spinner on the failure path | `create_dialog.dart:147` |
| CI-36 | major | Give the snippet download progress and a real failure state; a failed download may not close the dialog as if it worked | `qa_dialog.dart:57`, `qa_list.dart:89`, `qa_list.dart:67` |
| ST-53 | major | Replace the `// Error` no-op branch with a field-level validation message on the snippet name | `actions_screen.dart:239`, `actions_screen.dart:96` |
| ST-45 | major | A primary button may never silently no-op -- validate the required field and say what is missing | `mount_dialog.dart:94`, `mount_dialog.dart:134` |
| IA-12 | major | Show in-flight state for start / stop / delete, and only report DONE once the row is actually gone | `list_item.dart:41`, `list_item.dart:146`, `list_item.dart:473` |
| PS-19 | major | Move the card into an explicit "Installing" state for the duration of the install | `ai_workspace_screen.dart:535`, `ai_workspace_screen.dart:577` |
| PS-17 | major | Clear the status line when the operation it describes finishes -- it still read "Starting Open WebUI..." 105s after the tool was running | `root_screen.dart:82`, `service.dart:1090` |
| PS-32 | nit | A failed stop must leave the badge showing the state the tool is really in, not "running" in green | `service.dart:1193`, `service.dart:1201` |

### FIX-03 -- One honest notification surface

`Notify` is the single most-reused UI component in the app and it cannot express
failure. Everything downstream inherits that.

**Status: all 9 fixed.** `Notify.message` now takes an `InfoBarSeverity`
(re-exported from `notify.dart` so an `api/` file can name one without pulling
in fluent_ui), and `statusBuilder` stopped overriding fluent's per-severity
decoration with one flat colour. Regression tests: `test/notify_test.dart`.

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| CI-19 | major | Derive `InfoBarSeverity` from the message kind; "ERROR:" must not render with a blue info icon | `notify.dart:63`, `root_screen.dart:75` |
| PS-46 | major | Same at the toast layer -- one decoration for every outcome means install-failed looks like install-succeeded | `service.dart:849`, `service.dart:858` |
| CI-18 | major | Give status messages a lifetime and clear them on navigation | `notify.dart:26`, `root_screen.dart:82`, `root_screen.dart:111` |
| CI-24 | major | Lay the status bar out so it cannot cover the Create / Cancel row on a short window | `root_screen.dart:251` |
| IA-02 | major | An empty status bar must take no space, no tab stop and no clicks (currently an invisible 126x62 hit target on every screen) | `notify.dart:51` |
| IA-14 | major | The X on a running operation must cancel it, or not be offered -- hiding the progress while the work continues is worse than no control | `notify.dart:67` |
| CI-20 | nit | Drop the shouting `DONE:` / `ERROR:` / `WARNING:` prefixes now that severity is carried by the InfoBar | `en.json:30`-`79` |
| TL-14 | nit | Remove the eight divergent translations of `DONE:` along with it (Turkish renders it `TAMAM`) | `lib/i18n/*.json` |
| IA-15 | nit | Delete `statusMsg`'s unreachable `severity` parameter, or wire it to the new severity | `notify.dart:14`, `root_screen.dart:75` |

### FIX-04 -- Long operations: moving progress and a way out

Every operation over ~30 seconds in this app is uncancellable, and two of them freeze
their only progress indicator for minutes.

**Status: all 7 fixed.** The root of it is one new file, `lib/api/cancellation.dart`:
a `CancelSignal` that a UI control and the work it stops both hold. Deliberately not
`package:async`'s `CancelableOperation` -- what has to be cancelled here is a *child
process* and a *socket*, reached through a callback the worker registers while it owns
them, and a token is the only shape that survives being handed down four call levels
(screen → `createInstance` → `WSLApi.create` → the downloader) without each of them
returning a different type. It is named `CancelSignal` and not `CancelToken` because
`dio` exports a `CancelToken` of its own into both `wsl.dart` and the AI Workspace
service, and an ambiguous import is not a name worth defending.

Three things are worth recording. **A cancelled download does not throw**:
`ChunkedDownloader.stop()` breaks the read loop, deletes its own `.tmp` and lets
`start()` return *normally*, so the cancel has to be detected rather than caught -- read
as an exception it came out the far end as "the server returned an empty file", the
user's own cancel reported as a server fault. **A killed `wsl --import` can leave the
distro half-registered** -- it lists, it will not start, and its name cannot be reused --
so the cancel path unregisters it; that is also why the import moved off `Process.run`,
which hands back no handle to kill. And **`start` is not a program**: the `passwd`
console was spawned through `cmd /c start`, which hands its child to a new console and
exits at once, so the `await result.exitCode` that was already there awaited nothing.
`start "" /wait` makes it real, and `WSLApi.hasPassword` then asks the distro whether a
password was actually set, because closing that window without typing is silent.

The cheap paths are kept: `create` with no progress sink and no signal still goes
through `_runWsl`, and `CreateProgress.fraction` is null for an import rather than a
number, since an import has no percentage and inventing one is the CI-16 bug in a new
place. 14 new keys landed in all nine locales with real translations. Regression tests:
`test/long_operations_test.dart`.

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| CI-14 | major | Make Cancel work for the whole install; if it genuinely cannot, disable the nav pane too and say why | `create_screen.dart:271` (Cancel stops the install), `:95` (the nav pane, back button and window X now ask, via `UnsavedChangesGuard`), `wsl.dart:1535` (`_runImport` kills and unregisters), `cancellation.dart` |
| CI-16 | major | Report real progress across download *and* import instead of stalling at "Downloading 100%" | `create_screen.dart:186` (bar + phase line on the page), `wsl.dart:1654` (bytes and rate, not just a %), `wsl.dart:1548` (the import phase, with an elapsed clock) |
| PS-18 | major | Add cancel to the AI Workspace install and keep its progress line moving (measured: 2 minutes, 0 px changed) | `ai_workspace_screen.dart:628` (elapsed clock), `:634` (Stop), `ai_workspace/service.dart` (`installElapsed`, `cancelInstall`, cancel wired into `_runStreamed`) |
| CI-13 | major | Warn before spawning the external `passwd` console, and await it | `create_dialog.dart:890` (the form says a terminal will open), `wsl.dart:1367` (`start "" /wait`), `wsl.dart:1786` + `create_dialog.dart:444` (a passwordless account is reported, not silent) |
| LN-20 | nit | Centre the loading state where the results will land so content does not jump 330px; translate the string; offer cancel | `list.dart:207` (`Expanded`, like the other two branches), `:225` (Use local WSL); the string was already translated by FIX-05 |
| CI-15 | nit | Keep the Create button's width when it becomes a spinner | `components/busy_button.dart` (new), used at `create_screen.dart:258`, `create_dialog.dart:101`, `ai_workspace_screen.dart:755` |
| ST-36 | nit | Label the per-distro dialog's 4s+ spinner and disable Save while it runs | `settings_dialog.dart:863` (the spinner says what it is reading), `:100` (Save is disabled until `wsl.conf` has been read; Cancel stays live) |

### FIX-05 -- Error text a user can act on

Eleven findings, one rule: never put a raw exception in front of a user, and never
match on English text.

**Status: all 12 fixed.** The root of the work item is one new file,
`lib/api/wsl_errors.dart`: a `WslFailure` that reads *both* process streams,
pulls the stable `Wsl/…` code out of localized prose, maps it to a translated
sentence and keeps the tool's own words in `details`. `lib/components/error_view.dart`
is the matching surface -- the sentence in the primary position, "Technical
details" folded away underneath. Regression tests: `test/wsl_errors_test.dart`,
`test/error_view_test.dart`, plus the ST-07 case in `test/wsl_capabilities_test.dart`.

Three consequences worth recording. **The two streams are not interchangeable**:
stderr wins the text, because `wsl --import` paints a progress animation on
stdout and showing that instead of the reason is its own bug (already guarded by
`wsl_test.dart`'s "shows stderr on import failure") -- but stdout is read when
stderr is silent, which is the `--mount` case IA-16 is about, and its *code* is
taken whenever stderr carries none. **An unmapped failure gets no invented
sentence**: `explanation` is empty, and a caller with its own lead sentence
("Ubuntu could not be started.") appends the tool's first line rather than a
vague generic one, so nothing is lost on a surface too small for a disclosure.
And **IA-20's xterm half is answered by copying, not by installing**: that
terminal lives on the *host*, so the app cannot elevate to a package manager --
the dialog hands over the command instead of naming three packages and stopping.

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| IA-16 | blocker | `mount_service.dart:338` throws `Exception(result.stderr)`, but `wsl --mount` writes its reason (including the stable `Wsl/ERROR_*` code) to **stdout** -- read both streams, and never build a dialog body from a bare `Exception` | `wsl_errors.dart:79`, `mount_service.dart:288`, `mount_service.dart:339`, `mount_service.dart:354`, `mount_dialog.dart:156`, `mount_dialog.dart:212`, `mount_dialog.dart:242` |
| LN-17 | major | Translate the list-error strings and map the WSL error code to a sentence instead of dumping `Exception: ...` | `list.dart:137`, `list.dart:149`, `list.dart:211` |
| LN-18 | major | Offer a remedy and a route back to local WSL; Retry that repeats the same failure is not a recovery path | `list.dart:156`, `list.dart:176` |
| CI-22 | major | Map the WSL error code to a translated sentence; keep the raw stderr behind a "details" disclosure | `create_dialog.dart:46`, `create_dialog.dart:327`, `create_dialog.dart:514` |
| IA-17 | major | Stop interpolating raw exceptions into the five `docker_images.dart` messages -- two currently read "Error: Exception: ..." | `docker_images.dart:642`, `docker_images.dart:805`, `templates.dart:68`, `sync.dart:121`, `settings_dialog.dart:314`, `ai_workspace_screen.dart:585` |
| IA-18 | major | Move the sixteen hardcoded English messages into `en.json` and drop the implementation detail ("Exporting, removing and importing back...") | `list_item.dart:161`, `list_item.dart:198`, `list_item.dart:428`, `list_item.dart:448`, `list_item.dart:494`, `docker_images.dart:350`, `docker_images.dart:532`, `docker_images.dart:618`, `docker_images.dart:749`, `wsl.dart:508`, `wsl.dart:769`, `wsl.dart:823` |
| PS-31 | major | Translate the AI Workspace page-level failure and stop wrapping `Exception.toString()` | `ai_workspace_screen.dart:447` |
| IA-19 | major | Gate the "disk is offline" hint on the stable error code, not on English Windows text -- it can never fire on a localized host | `wsl_errors.dart:150`, `mount_dialog.dart:244` |
| ST-07 | major | Only surface "WSL reported:" for stderr that actually concerns `.wslconfig` | `wsl_capabilities.dart:151`, `wsl_capabilities.dart:156`, `settings_screen.dart:1457`, `settings_screen.dart:1467` |
| ST-22 | nit | Same treatment for the tunnel error, and use the theme's error colour rather than `Colors.red` | `settings_screen.dart:1059`, `settings_screen.dart:1088` |
| IA-20 | nit | Replace the "run `wsl --shutdown`" and "install xterm" prose with the buttons that do it | `settings_screen.dart:1281`, `wsl.dart:33`, `wsl.dart:844`, `en.json:117` |
| ST-13 | nit | Same string in Settings, 400px above the button that performs it | `settings_screen.dart:1281`, `en.json:117` |

### FIX-06 -- Keyboard operability

IA-01 is the audit's worst single finding: **the app cannot be operated by keyboard at
all until the user first clicks something**, and there is no keyboard route back.

**Status: all 9 fixed.** One new file, `lib/nav/shell_focus.dart`, carries the two
pieces that are not per-widget: `shouldAdoptKeyboardFocus()`, the one-line test for
the dead state IA-01 measured, and `ShellTraversalPolicy`, which sorts the shell's
chrome ahead of the page instead of leaving the navigation pane -- the first thing on
screen -- last in the cycle. `RootPageState` now wraps the whole `NavigationView` in
that group plus a `FocusScope` it owns, and hands the scope focus from a post-frame
callback in `initState` **and** from `onWindowFocus`; the second one is what fixes
the recurrence, since alt-tabbing away and back was enough to kill traversal again.
The check is deliberately conservative -- anything below the root scope, which is
every dialog, every text box and every clicked control, keeps its focus.

Three consequences worth recording. **The back arrow is not built at all when it
cannot pop** rather than being built disabled: that removes the dead tab stop (IA-03)
and the near-white "enabled-looking" disabled rendering (LN-13) together, and takes
the `NavigationPaneTheme` override and a `setState()` *inside* `build()` with it. The
arrow still appears on the pushed routes where `canPop()` is true.

**The chevron's ring is suppressed at the theme, not removed.** The Expander header is
one big `HoverButton` whose `FocusBorder` is drawn around the chevron alone, and whose
`states.isFocused` follows `hasFocus`, so any focused child lit it a second time --
IA-05's "1,100px away" and IA-06's two rings are the same fluent_ui behaviour seen
twice. `list_item.dart` wraps the Expander in a `FocusTheme` with `BorderSide.none`,
re-merges an empty `FocusThemeData` inside `leading:` and `content:` so the buttons
there keep the theme's ring, and draws the row's own ring around the whole card. Which
of the three regions holds focus is tracked by three non-traversable `Focus` watchers,
because "the header is focused" is only knowable as "the row is, and neither the
leading buttons nor the content are".

**IA-07 is a theme change, not 38 widget changes.** `buildAppTheme()` in `theme.dart`
now builds both brightnesses from one function -- the light and dark blocks in
`main.dart` were near-identical copies -- and gives the focus ring a 2px inner stroke
to match its 2px outer one. fluent_ui's default pairs a 2px outer stroke with a 1px
inner one, and the inner stroke is what separates the ring from whatever it is drawn
against; at 1px it read as the hairline the audit sampled.

Regression tests: `test/keyboard_focus_test.dart` (12), including a tab-cycle
assertion for the chrome-before-content order, a resolved-ring-width assertion for the
chevron, and a tree-wide scan that fails if an interactive `GestureDetector` comes
back.

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| IA-01 | blocker | Focus a real control at launch and on window activation instead of parking on the Root Focus Scope | `shell_focus.dart:28`, `root_screen.dart:115`, `root_screen.dart:121`, `root_screen.dart:296`, `root_screen.dart:301` |
| LN-12 | major | Re-verify after IA-01 -- the ring exists, focus was not moving. Likely closes for free; confirm with the Tab-diff capture | closed by IA-01 + IA-07; ring widened in `theme.dart:186` |
| IA-03 | major | Take the permanently disabled back arrow out of the tab order | `root_screen.dart:185` |
| LN-13 | major | Wire the back button or remove it; a disabled control may not render near-white (enabled-looking) in dark | `root_screen.dart:185` |
| IA-04 | major | Replace the three `GestureDetector` controls -- including the AI panel's only entry point -- with focusable, activatable buttons | `home_screen.dart:156`, `pro_badge.dart:111`, `recommendations_panel.dart:94` |
| IA-05 | major | Tab order should reach the nav pane before deep content, and the row stop must land on the row, not on a chevron 1,100px away | `shell_focus.dart:40`, `root_screen.dart:254`, `root_screen.dart:295`, `list_item.dart:82` |
| IA-06 | major | One focus ring lit at a time per distro row | `list_item.dart:65`, `list_item.dart:86`, `list_item.dart:100`, `list_item.dart:174` |
| IA-08 | major | Cancel takes initial focus in the delete confirmation, not Delete | `base_dialog.dart:52`, `base_dialog.dart:79` |
| IA-07 | nit | Widen the focus indicator to a 2px perimeter (WCAG 2.4.13) | `theme.dart:172`, `main.dart:203` |

### FIX-07 -- Accessible names and honest tooltips

The codebase contains **no `Semantics(label:)` at all** and 22 of 38 tap targets have
no accessible name. `list_item.dart` already does it right 11 times out of 11 -- copy
that pattern.

**Landed 2026-08-30.** The pattern is now one widget, `NamedIconButton`
(`lib/components/named_button.dart`), rather than eleven inline repetitions of it. It
exists because a `fluent_ui` `IconButton` opens its own semantics container: a
`Tooltip` wrapped round one is a sibling node, not a name, until `MergeSemantics`
folds the two together. The nineteen controls that were missing one half of that pair
or both went through the wrapper; the `list_item.dart` eleven that already did it by
hand were left alone, since rewriting them would have disturbed the per-region
`FocusTheme` work FIX-06 had just landed there.

**IA-09's trap was real and it was the tooltip, not the missing merge.** The editor
and terminal pickers sat inside a `Tooltip` whose message was the field's own
`InfoLabel` -- "Default editor" -- so merging the pair as written would have named the
*button* after the text box. Both tooltips were ST-14 offenders anyway (they restated
the label directly above them), so removing them fixed the naming and the noise in one
edit. Nine more tooltips on that screen said exactly what the control they wrapped
already said and are gone; the two that had something to add -- Stop WSL, which shuts
down every distro, and Edit .wslconfig, which opens a file in an external editor --
were rewritten to say it.

**IA-10 is three places, not a sweep.** An `Icon` carries no name, so anything that is
an icon and *not* a button was silent by construction: the licence table's check/cross
column, and the BETA and NEW pills, which announced four letters and no meaning. The
status pills were already `Text`. Both badges use `excludeSemantics: true` so the name
replaces the literal glyph rather than trailing it.

Regression tests: `test/accessible_names_test.dart` (5), including a tree-wide source
scan that fails if an icon-only tap target comes back without a name -- the same count
the audit made by hand, now enforced.

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| IA-09 | blocker | `MergeSemantics(Tooltip(...))` on the 22 unnamed tap targets; 11 are in `settings_screen.dart`, which has zero `MergeSemantics` today. Watch the trap at `:471` and `:499` -- those sit inside a `Tooltip` that describes the *TextBox*, not the button | `named_button.dart:15`, `settings_screen.dart:617` `:639` `:667` `:692` `:966` `:993` `:1005` `:1012` `:1104` `:1519` `:1721`, `mount_dialog.dart:448`, `template_screen.dart:183`, `ai_chat_panel.dart:159`, `recommendations_panel.dart:116`, `create_dialog.dart:700`, `settings_dialog.dart:616`, `package_screen.dart:509`, `ai_workspace_screen.dart:592` |
| IA-10 | major | Add `Semantics(label:)` where a visible tooltip is not appropriate | `license_screen.dart:260`, `beta_badge.dart:14`, `panelist.dart:95` |
| IA-11 | major | Tooltip the seven icon-only buttons that have none -- they are unlabelled for sighted users too | `named_button.dart:39` (label is the tooltip), call sites as IA-09 |
| ST-18 | major | Name the four MCP icon buttons and differentiate the two identical copy glyphs | `settings_screen.dart:966` `:993` `:1005` `:1012` |
| ST-44 | major | Give the mount confirmation the full disk identity, with a tooltip on the truncated form | `mount_dialog.dart:342`, `mount_dialog.dart:361` |
| ST-14 | nit | A tooltip that repeats its own label is noise -- make it explain or remove it | `settings_screen.dart:364`, `:400`; nine removed at `:421` `:662` `:687` `:712` `:763` `:1143` `:1181` `:1200` `:1226` |
| PS-30 | nit | Same for the Open Dashboard tooltip | `ai_workspace_screen.dart:669`, `ai_workspace_screen.dart:760` |
| ST-30 | nit | Make the sync buttons' tooltips match their labels | `settings_dialog.dart:236`, `settings_dialog.dart:256` (moved by FIX-08's ST-29) |
| LN-23 | nit | Tooltip the truncated distro name | `list_item.dart:66`, `list_item.dart:162` |
| ST-51 | nit | One folder glyph across all pickers, with a tooltip | `mount_dialog.dart:448` |

### FIX-08 -- Destructive actions must look and behave destructive

Nothing in this app that destroys data is styled differently from anything that does
not, and three destructive actions have no confirmation at all.

**Landed 2026-08-30.** Three of the twelve were one control that ran an
irreversible command on a single click with nothing in between: Stop WSL
(`wsl --shutdown` -- every instance on the machine, every process inside them),
the MCP token refresh, and the chat panel's Clear. All three now go through the
house `dialog()` with a red submit, and the copy says what breaks: which
clients stop working, that unsaved work inside a running instance is lost.
`dialog()` gained a `hostContext` parameter to make that possible --
`GlobalVariable.infobox` is the *home* screen's key, so the settings screen and
the chat panel were resolving it to an element that is not mounted while they
are on screen.

**Three delete confirmations, one string.** `deleteinstancequestion-text` /
`deleteinstancebody-text` were shown over templates and snippets as well as
distros, so deleting a saved archive asked "Delete instance test-4
permanently? / If you delete this Distro you won't be able to recover it"
(ST-38, ST-54). Each object now has its own pair, and a test asserts the distro
strings are reachable from `list_item.dart` alone -- a fourth reuse would fail
it. The template one says the instances already stamped from it survive,
because that is the question the old copy made a user ask.

**Styling was one colour and one layout decision.** `destructiveColor()` in
`helpers.dart` resolves fluent's per-brightness red brush, because the flat
`Colors.red` those dialogs submit with is the light-theme shade and goes muddy
against the dark background. In the distro row, Delete moved out from between
the broom and the gear -- two controls a user reaches for routinely, 32px away
on each side -- to last, behind a vertical separator, in that colour. In the
per-distro dialog the four action buttons were full-width rows with a 16px
glyph on the right, i.e. the exact shape of the three `wsl.conf` Expanders
stacked above them; they are content-sized now, under their own heading, icon
leading the label, with Terminate, Download/Override and Move in the
destructive colour. Terminate moved up out of `wslSettings()` to join them.

**The two dialogs that needed words, not styling.** A physical-disk mount needs
an elevated process and takes the disk away from Windows for the duration; the
only text that said any of it was appended to the *error*, after the attempt
had failed (ST-46). It is an InfoBar on the form now, before the disk is even
picked. And a copy is an export + import of the whole distro that stops the
source first -- 16.63 GB for `ai-workspace` on this host -- which the dialog
now says before the user commits (CI-31).

Regression tests: `test/destructive_actions_test.dart` (14) and one in
`test/ai_workspace_screen_test.dart` (PS-27/PS-28), plus `destructiveColor` in
`test/helpers_test.dart`. 17 new keys in all nine locales; the two
`ai-workspace-uninstall-*` strings were rewritten to take the tool's name.

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| ST-04 | major | Confirm "Stop WSL" (it shuts down every distro), move it away from Save, and write a tooltip that adds information | `settings_screen.dart:40` (`confirmStopWsl`), `:409` (moved to the left group, beside Edit .wslconfig), `:1314` (the second, unconfirmed `restart()`); tooltip rewritten in FIX-07 |
| ST-19 | major | Confirm MCP token regeneration and state that existing clients break | `settings_screen.dart:1050`, message at `:1066` |
| LN-04 | major | Label the row's nine icon buttons, group them, move Delete out of the middle, and style it destructively | `list_item.dart:530` (separator), `:549` (destructive colour, now last); the nine labels were already `MergeSemantics(Tooltip(...))` |
| ST-29 | major | Style the four irreversible per-distro actions as actions, not as the Expander headers above them | `settings_dialog.dart:203` (heading + group), `:505` (`distroActionButton`), terminate moved from `wslSettings()` to `:221` |
| PS-27 | major | Use the red destructive button for uninstall, as every other destructive dialog does | `ai_workspace_screen.dart:329` |
| PS-35 | major | Confirm clear-chat-history, disable it when the history is empty, and give it a label | `ai_chat_panel.dart:163`; the label landed in FIX-07 |
| ST-38 | major | Write template-delete copy instead of reusing the distro string ("Delete instance ... permanently?") | `template_screen.dart:207`, keys `deletetemplatequestion-text` / `deletetemplatebody-text` |
| ST-54 | major | Same for snippet delete | `actions_screen.dart:374`, keys `deletesnippetquestion-text` / `deletesnippetbody-text` |
| ST-46 | major | State that a physical mount needs elevation and detaches the disk from Windows -- before it fails | `mount_dialog.dart:383`, rendered at `:394` and `:410` |
| ST-40 | nit | Move the template delete next to the labelled buttons, give it a tooltip and destructive styling | `template_screen.dart:185` -- it is a labelled button now, so the tooltip it needed as an icon is gone |
| PS-28 | nit | Name the tool inside the uninstall sentence rather than on a bare line above "this tool" | `ai_workspace_screen.dart:326`, `:327` |
| CI-31 | nit | Say that a copy duplicates the whole disk and stops the source distro | `copy_dialog.dart:22`, key `copyinstancewarning-text` |

### FIX-09 -- One dialog contract

Button order, primary styling, titles and sizing differ per dialog; the one that
deletes things is the one with the odd button order.

**Landed 2026-08-30.** The contract is: **primary action filled and first, Cancel
last** -- the order `base_dialog.dart`, the create screen and the AI Workspace
dialogs already used, and the WinUI order. The three dialogs on the other
convention (per-distro settings, mount, community snippets) flipped; the delete
dialog was already right once the rest agreed with it. `dialog()`'s submit button
is a `FilledButton` now, which closes CI-29 for the copy dialog and gives every
`dialog()`-built confirmation the same primary emphasis.

Two behaviours moved into `dialog()` itself rather than being fixed per caller:
a `placeholder` parameter replaced the old behaviour of using the *item* -- the
source's own name -- as the input placeholder, which made an empty box read as
pre-filled with exactly the value a user would accept (CI-30, ST-43); and a
`validateInput` callback runs before the pop, shows its message under the box,
clears on edit, and keeps the dialog open -- so a primary button can no longer
swallow an empty required field on its way out (CI-30, same contract FIX-02
established for the screens).

The dead `createDialog()` -- no call sites, opposite button order, tooltips
repeating their own labels -- is deleted; `CreatePage` is the single
implementation. The source-type control became a `DropDownButton`, whose flyout
opens *below* the control instead of ComboBox's selected-item-anchored popup
that covered the page title and the name field (CI-25); the flyout also groups
the three downloading sources from the three local ones and gives each a
description line, which is FIX-12's CI-26 closed early. The community dialog
got a title and lost its window-height `SizedBox` (CI-33, CI-37); the
per-distro dialog is 640x720 instead of 500x500 and is titled with the distro
name (ST-32, ST-33).

Regression tests: `test/dialog_contract_test.dart` (4). 7 new keys in all nine
locales.

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| ST-62 | major | One button order everywhere, including the delete dialog (Cancel is currently on the opposite side there) | `settings_dialog.dart:98`, `mount_dialog.dart:187`, `:250`, `:364` |
| CI-32 | major | Same for the community snippets dialog | `qa_dialog.dart:177` |
| CI-30 | major | Validate before popping, and stop using the source name as a placeholder -- the field looks pre-filled | `base_dialog.dart:34` (`validateInput`), `:70` (placeholder), `copy_dialog.dart:28` |
| CI-29 | nit | `FilledButton` for the copy dialog's primary action | `base_dialog.dart:101` |
| CI-25 | nit | Keep the source-type flyout off the page title and the fields it belongs to | `create_dialog.dart:605` (`DropDownButton`, flyout opens below) |
| CI-28 | nit | Delete the dead `createDialog()` -- it also carries the opposite button order | deleted; guarded by `dialog_contract_test.dart` |
| CI-33 | nit | Give the community dialog a title | `qa_dialog.dart:110` |
| CI-37 | nit | Size it to its content instead of full window height | `qa_dialog.dart:114` |
| ST-32 | nit | Size the per-distro dialog to its twenty controls instead of a fixed 500x500 | `settings_dialog.dart:86` |
| ST-33 | nit | Title it with the distro name, not the bare word "Settings" | `settings_dialog.dart:53` |
| ST-43 | nit | Stop pre-filling the new-instance name box with the template's own name as a placeholder | `base_dialog.dart:70` |

### FIX-10 -- Contrast and theme tokens

Twenty-one findings, one root cause: hardcoded `Colors.grey` / `Colors.orange` /
`Colors.red` literals spread across eleven files, plus a `systemTextColor` that assumes
light. Introduce the tokens once and most of this collapses.

**Landed 2026-08-30.** Three tokens joined the two that already existed in
`helpers.dart`: `surfaceBorderColor` (dividers, card borders, chip outlines),
`subtleFillColor` (bubbles, chips, washes) and `cardFillColor`, each resolving a
fluent theme resource. Every `Colors.grey.withValues(alpha: ...)` in
`ai_chat_panel.dart`, `home_screen.dart`, `recommendations_panel.dart`,
`license_screen.dart` and `install_dialog.dart` went through them, which is
what closes TL-02's invisible chat panel and TL-08's eleven ways of writing
grey together.

**The status pill got a palette, not a colour.** `_statusColors()` in
`ai_workspace_screen.dart` returns text + tint + dot per status *per
brightness*, with every text/tint pair measured against both page colours
before landing — the shades in the source each clear AA's 4.5:1 (green
7.73/5.67, blue 6.92/4.51, orange 5.46/5.12, red 6.86/5.44). `notInstalled`
uses the theme's own secondary text and a dimmed dot, so the state that means
"nothing here" stops being the most assertive of the four (TL-01, TL-04,
PS-20, PS-24).

**`systemTextColor` and `systemBackgroundColor` are gone.** The getter read
the *preference*, so the default `ThemeMode.system` returned black to a dark
UI (TL-03); its five call sites now resolve `FluentTheme.of(context)` (or
inherit `DefaultTextStyle` — `init.dart`'s update banner became a `Text.rich`
for exactly that). `systemBackgroundColor` had no readers and carried the same
bug; deleted with the `AppTheme` members that held them (TL-07).

**The two amber pills split.** `BetaBadge.foregroundFor(brightness)` darkens
the amber to `#7A5C00` on the light wash (5.66:1; raw amber measured 1.40:1
there while passing in dark — the one light-fails/dark-passes defect in the
audit, TL-05). The nav's NEW upsell badge stopped being a duplicated amber
literal and became accent-blue, so "immature" and "buy this" no longer share a
colour (PS-09). The AI chat FAB is accent-filled in both states instead of a
grey wash that measured 1.02:1 in dark (TL-06, PS-14, LN-24).

Rest of the sweep: the disabled-control explanation renders in secondary
rather than disabled text (ST-10); selecting a community snippet uses fluent's
own selectable tile plus a check mark instead of a 50% accent wash that
dropped the title to 2.49:1 (CI-34); `(by you)` / `[v0.0.0]` are keyed,
real-version-only, and secondary-coloured (ST-57); every inline validation
message shares one style, `destructiveColor` at 12px, no bold (CI-03); the
install panel's chip is `subtleFillColor` (CI-40); and the snippet editor
picks `atomOneDarkTheme` in dark (ST-59). PS-21 (disabled `FilledButton`
labels at 1.71:1) landed with FIX-14's action-row rework: the non-primary
actions are plain `Button`s now, so no disabled control keeps a white
foreground.

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| TL-01 | blocker | The AI Workspace status pill is **1.03:1** in dark (`#323130` on `#333333`) -- replace with a theme resource | `ai_workspace_screen.dart:844` |
| TL-02 | blocker | The chat empty state is **1.07:1** in dark; the dividers and bubble fills vanish with it | `ai_chat_panel.dart` (8 sites, via `helpers.dart:528-537`) |
| TL-03 | major | `systemTextColor` returns black under the default `ThemeMode.system` -- resolve the *effective* brightness at all five call sites | `actions_screen.dart:322`, `create_dialog.dart:712`, `init.dart:103` |
| TL-04 | major | The `stopped` pill fails AA in both themes (2.70:1 / 3.60:1) -- hardcoded `Colors.orange` | `ai_workspace_screen.dart:844` |
| TL-05 | major | The amber BETA pill is **1.40:1** in light; move the colour to a token (it is also duplicated as a raw literal in the nav) | `beta_badge.dart:17`, `panelist.dart` |
| TL-06 | major | The AI Assistant FAB is **1.02:1** in dark -- only its border ring makes it findable | `home_screen.dart:164` |
| PS-14 | major | Same control in light (1.29:1); fix once | `home_screen.dart:164` |
| LN-24 | nit | Same control's hardcoded `Colors.grey` / `Colors.white` | `home_screen.dart:164` |
| PS-09 | major | The BETA/NEW badges measure 1.35:1 / 1.37:1 -- and amber means two different things | `beta_badge.dart:17`, `panelist.dart:108` (NEW is accent now) |
| PS-20 | major | "stopped" (2.70:1) and "Starting up..." (3.84:1) both fail AA; stopped is the most-shown state | `ai_workspace_screen.dart:844` |
| PS-21 | major | Disabled `FilledButton` labels are white on `#C6C6C6` (1.71:1), and two of three are always disabled | with FIX-14: non-primary actions are plain `Button`s |
| PS-36 | major | Chat empty-state hint at 3.69:1; remove the five `Colors.grey` literals in that file | `ai_chat_panel.dart:207`, `:214` |
| ST-10 | major | The disabled-control explanation renders at 2.51:1 while the line above it is 6.00:1 | `settings_screen.dart:1690` |
| CI-34 | major | Selecting a snippet drops its contrast from 17.4:1 to 2.49:1 | `qa_list.dart:190` (`ListTile.selectable` + check mark) |
| TL-08 | nit | One shared set of surface/border greys -- currently six alphas across five files | `helpers.dart:528`, `:532`, `:536` |
| TL-07 | nit | Delete `systemBackgroundColor`: 30 lines nothing consumes, carrying TL-03's bug | deleted, with `AppTheme.backgroundColor` / `.textColor` |
| PS-24 | nit | The `notInstalled` dot is darker than running or stopped and reads as a bullet | `ai_workspace_screen.dart:844` (dimmed `disabledTextColor` dot) |
| ST-57 | nit | "(by you)" and "[v0.0.0]" at 4.41:1 and 3.96:1, both sub-AA | `actions_screen.dart:311`, keys `snippetauthor-text` / `snippetauthoryou-text` |
| CI-03 | nit | Inline validation uses hardcoded `Colors.red` bold 12px, unlike every other error in the app | `create_dialog.dart:585`; same style unified in `mount_dialog.dart`, `qa_dialog.dart`, `actions_screen.dart` |
| CI-40 | nit | The 20%-black chip is invisible in dark theme | `install_dialog.dart:25` |
| ST-59 | nit | The code editor hardcodes `atomOneLightTheme`, so syntax colours ignore the app theme | `actions_screen.dart:513` |

### FIX-11 -- Close the localization holes

Two blockers: one panel renders its own i18n keys, and a whole dialog is untranslated
in six of eight non-English locales. The CI gate that should have caught both only
checks that keys are *present*.

**Landed 2026-08-30.** The Mount Disk dialog's ~39 keys got real translations in
`es`, `hu`, `ja`, `pt`, `tr` and `zh_TW` (TL-09), and the gate that let them ship
English is widened: `locales_test.dart`'s untranslated-value rule now runs over
**every** key longer than 20 characters, not the 60 audit keys it was scoped to,
with a nine-entry `identicalByDesign` allowlist for product names and literal
examples (TL-10). "AI Workspace" is on that list as a deliberate product-name
decision, recorded in the test's own comment (TL-13).

The three `recommend-*` keys — missing from all nine locales including `en`, so
the panel printed its own key names — exist everywhere with real translations
(PS-40, TL-16). The "Go to Templates" link is one `goto-text` key whose
placeholder is the destination's own translated name, instead of three English
fragments glued in Dart (PS-43, IA-21). The remaining hardcoded strings went
through keys: the nav's "Dark Mode" toggle (LN-14), the create form's Docker
"no results" panel (CI-10), the AI Workspace card's "Installed:" line — which
also stops leaking the internal `cmd://` existence-check sentinel (PS-26) — and
the uninstall toast, whose subject was concatenated in Dart and can now move
with the locale's word order (PS-29).

Turkish got a term decision (TL-11): the ten strings using "örnek" for a WSL
*instance* now say "dağıtım", leaving "örnek" to the five strings that
genuinely mean *sample*. German's two English nav entries are translated
(TL-12: "Startseite"; "Mount Disk" was already "Datenträger einbinden").

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| TL-09 | blocker | Translate the 35-37 missing Mount Disk keys in `es`, `hu`, `ja`, `pt`, `tr`, `zh_TW` | all six locale files, ~39 keys each |
| PS-40 | blocker | Add the three `recommend-*` keys -- they are missing from **all nine** locales including `en`, so the panel prints its key names | all nine locale files |
| TL-16 | major | Same three keys, recorded from the locale side; closes with PS-40 | with PS-40 |
| TL-10 | major | Widen `locales_test.dart`'s gate from key-presence to the untranslated-value rule that already exists but is scoped to 60 keys; expect 131 locale-key pairs to fail and fix them | `locales_test.dart:399` (125 pairs measured; all fixed) |
| TL-12 | major | Translate the German nav pane's "Home" and "Mount Disk" | `de.json` (`homepage-text`) |
| PS-43 | major | Build the "Go to Templates" label from one key with a placeholder, not three English fragments | `recommendations_panel.dart:123` |
| CI-10 | major | Key the three hardcoded English strings in the "no results" panel | `create_dialog.dart:698`, `:702`, `:707` |
| TL-11 | major | Fix the Turkish "örnek" collision -- ten strings mean *instance*, five legitimately mean *sample* | `tr.json`, ten keys rewritten to "dağıtım" |
| LN-14 | major | Move the hardcoded "Dark Mode" toggle label into `en.json` | `root_screen.dart:239`, key `darkmode-text` |
| PS-26 | nit | "Installed: cmd://openclaw" -- key it and stop leaking the internal URI sentinel | `ai_workspace_screen.dart:631` |
| PS-29 | nit | Build the uninstall success toast from a key with a placeholder, not concatenation | `ai_workspace_screen.dart:390` |
| IA-21 | nit | Same for the recommendation link built by an if/else on a route string | `recommendations_panel.dart:123` |
| TL-13 | nit | Decide whether "AI Workspace" is a product name; if not, translate it (it is the only Latin script in the `ja` and `zh_TW` nav panes) | decided: product name; pinned in `locales_test.dart`'s allowlist |

### FIX-12 -- Copy, casing and terminology

**Landed 2026-08-30.** The English source settled on **sentence case** for
short labels: ~60 Title Case values rewrote ("Mount Disk" → "Mount disk",
"Select File" → "Select file"), keeping proper nouns (Docker, VHD, DNS, WSLg,
GitHub, TurnKey). The status badge column reads Running / Stopped /
Not installed / Starting up... in every locale that had drifted (PS-25), the
nav pane follows the same convention (LN-15), and "(Optional)" — previously
three spellings, twice on one field — is "(optional)", trailing (TL-18).

**ST-09 turned out to be half-built already**: prose labels for 16 of the 26
`.wslconfig` settings sat unrendered in `en.json` while the screen titled its
controls with the bare camelCase key. `settingsWidget` now resolves
`<key>-text` and shows "Networking mode (networkingMode)" — prose first, the
raw key kept as the annotation a power user greps the file for; the 11
missing labels (memory, processors, swap...) landed in all nine locales. The
disabled reason names that prose label instead of the raw key (ST-12), and
`localhostForwarding`'s description no longer repeats its own disabled reason
word for word (ST-11).

**TL-15's dead keys are gone**: 46 keys nothing renders — 19 of them the
unshipped Stripe-era subscription flow (`plan-monthly`, `open-billing-portal-
text`...), plus orphans like `installed-text` (freed by FIX-14) and
`selectsourcetype-text` (freed by FIX-09) — deleted from all nine locales,
and the five that were pinned in `locales_test.dart`'s audit list unpinned
with them. `entername-text` merged into `errorentername-text` (CI-21).

The two rewrites: the home empty state separates first-run from
move-in-progress — the marker is already in prefs — and tells a new user what
to do next instead of mentioning "a migration" (LN-22); the Turnkey warning is
an `InfoBar` with one sentence instead of five italic lines naming
`fake_systemd` and an `ip a | grep inet` pipeline (CI-27). A snippet is a
snippet everywhere now — the name box said "Name of setting" (ST-56). CI-39's
"with following command" string was replaced wholesale by FIX-16's CI-38
rework of the install panel, landed with this slice.

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| TL-17 | major | Pick sentence case (98 Title Case vs 91 sentence case short labels) and apply it across the locales that inherited the drift | `en.json`, ~60 values |
| LN-22 | major | Rewrite the empty-state copy: split the two unrelated states it merges and give a next step | `list.dart:85`, keys `noinstancesfound-text` / `moveinprogress-text` |
| ST-09 | major | Label the 26 `.wslconfig` settings in prose instead of the raw camelCase key | `settings_screen.dart:1652` (`settingsWidget`), 11 new keys |
| CI-27 | major | Rewrite the turnkey warning -- five italic lines containing `fake_systemd` and a shell pipeline | `create_dialog.dart:797`, keys rewritten |
| TL-15 | nit | Delete the 59 English keys nothing renders (19 of them an unshipped subscription flow), and their nine translations each | 46 deleted from all nine locales (16 of the audit's 61 became ST-09's labels instead) |
| TL-18 | nit | One spelling of "(Optional)" -- currently three, including both on the same field | `en.json`: `(optional)`, trailing |
| PS-25 | nit | One casing convention in the status badge column ("Not Installed" / "Starting up..." / "running") | `en.json` + de, es, hu, pt, tr |
| LN-15 | nit | Nav pane labels to one case convention | `en.json` (`addinstance-text`, `mountdisk-text`) |
| CI-39 | nit | "install it with **the** following command" -- fix in all nine locales | replaced by CI-38's rework (`install_dialog.dart`) |
| CI-21 | nit | Merge `entername-text` and `errorentername-text` | `create_dialog.dart:392`; `entername-text` deleted |
| ST-11 | nit | Stop repeating the description verbatim 20px below itself as the disabled reason | `wildcardinfo-text` rewritten, all nine locales |
| ST-12 | nit | Name the label, not the raw key, in the disabled reason | `settings_screen.dart:1407` `:1606` `:1613` `:1621` `:1628` `:1635` |
| CI-26 | nit | Group the six source types and give each a description line instead of bare developer jargon | closed with FIX-09 (`create_dialog.dart:605`) |
| ST-56 | nit | One name for a snippet -- currently Snippets / snippet / "Name of setting" / quick action | `settingname-text` → "Snippet name", all nine locales |

### FIX-13 -- Sell only what exists, gate it once

The purchase screen sells two features with no reachable implementation and never shows
a price. Separately, there are four gating components of which three have no call sites.

**Landed 2026-08-30.** The comparison table stopped selling what Pro is not:
"Script Generation" does not exist anywhere in the app and "Smart
Recommendations" ships in the free tier, so both rows are gone (PS-01, the S
option). The price is on the screen — US$ 9.99 one-time, with a note that the
Store shows the buyer's own currency (PS-02; the number was read off the live
Store listing for product 9NWS9K95NMJB). Pro users see the feature table too,
in a card under their status (PS-04). Under the free tier's status card sits a
restore row: "Already bought Pro but it shows Free?" with a **Check again**
button that re-runs the entitlement probe *visibly* and reports the result,
and a **Get help** link to the issue tracker (PS-05).

`lib/components/pro_badge.dart` — `ProBadge`, `ProFeatureWrapper` and
`UpgradePrompt`, three gate components with zero call sites — is deleted with
the keys only it used (PS-08). The nav item and the page share a name now:
"Upgrade to Pro" for free users, "License" for Pro (PS-06). The Store button
lost its `canLaunchUrl` gate, which reports false on Windows for launchable
https URLs (PS-07).

**The AI affordance that could not do its job is not shown.** `AiDiagnoseButton`
renders nothing without Pro *and* a configured key — clicking it used to
answer with a go-configure-something-else toast (LN-19, CI-23) — and a
diagnosis that does run opens in a dialog with selectable text instead of a
30-second toast. The BYOK fields carry their lock on the field itself ("API
key — Pro feature") and drop the placeholders that made empty locked boxes
read as filled in (PS-12). The AI Workspace paywall keeps the BETA badge the
Pro build shows on the same page (PS-13), and the chat panel's unreachable
Upgrade button — the FAB that opens the panel is Pro-only — is gone (PS-39).

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| PS-01 | blocker | Remove Script Generation and Smart Recommendations from the purchase table, or ship them (the L in this list) | `license_screen.dart:307` (removed) |
| PS-02 | blocker | Show the price on the purchase screen | `license_screen.dart:281`, key `store-price-text` |
| PS-04 | major | Show the feature list to Pro users too -- it currently lives only in the non-Pro branch | `license_screen.dart:84` |
| PS-05 | major | Add a restore-purchase / support path for a wrong MSIX entitlement result | `license_screen.dart:113` (`_buildRestoreRow`) |
| PS-08 | major | One gate component with one vocabulary; delete `ProBadge` / `ProFeatureWrapper` / `UpgradePrompt` or use them | `pro_badge.dart` deleted |
| PS-03 | major | Give the comparison glyphs text or semantics; the "not included" mark measures 1.85:1 | semantics landed with FIX-07; mark raised to `secondaryTextColor` (`license_screen.dart:327`) |
| CI-23 | major | Offer a non-AI remedy first -- with no key, the only remedy answers with a go-to-Settings toast | `ai_diagnosis.dart:13` (`canDiagnoseWithAi`), diagnosis in a dialog at `:38` |
| LN-19 | nit | Do not show "Diagnose with AI" to users who cannot use it | `ai_diagnosis.dart:70` |
| PS-06 | nit | One name: the nav says "Upgrade to Pro", the page says "License" | `license_screen.dart:176` |
| PS-07 | nit | Drop the `canLaunchUrl` gate on the store button -- the codebase works around that bug everywhere else | `license_screen.dart:41` |
| PS-12 | nit | Per-field reason on the disabled BYOK fields, and placeholders that do not read as filled-in values | `settings_screen.dart:877` `:897` `:916` |
| PS-13 | nit | Keep the BETA badge on the paywall that the Pro build shows on the same page | `ai_workspace_screen.dart:431` |
| PS-39 | nit | Remove the chat panel's unreachable Upgrade button (the FAB that opens it is Pro-only) | `ai_chat_panel.dart:211` (removed) |

### FIX-14 -- AI Workspace card lifecycle

One shared `isBusy` flag drives every button on every card, so the spinner appears on
the wrong control in three of four cases.

**Landed 2026-08-30.** A `_busyAction` map records *which* of the five actions
is in flight per tool; the pressed control spins, the rest merely disable
(PS-15). The row itself became one-primary-per-state: `notInstalled`/`error`
shows Install/Retry (filled), `stopped` shows Start (filled), and a
running/starting tool shows Open Dashboard (filled) with Stop beside it as a
plain button — which is PS-23's hierarchy, deletes the permanently disabled
"Installed" button that repeated the badge on the same row (PS-22), and, since
the non-primary actions are no longer `FilledButton`s, closes FIX-10's PS-21
on the way. Stop stays live while a tool is stuck in "Starting up..." so
Uninstall is not the only way out of a wedged migration (PS-16).

Regression tests: three in `test/ai_workspace_screen_test.dart` (the dead
button, the primary hierarchy, Stop-while-starting).

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| PS-15 | blocker | Per-action busy state: Start currently spins Uninstall, the dashboard spins Stop+Uninstall, and uninstall spins Start | `ai_workspace_screen.dart:53` (`_busyAction`), spin gates at `:715-780` |
| PS-16 | major | Allow Stop on a tool stuck in "Starting up..." -- Uninstall is not an acceptable only option | `ai_workspace_screen.dart:760` |
| PS-22 | major | Remove the permanently disabled "Installed" button that repeats the badge on the same row | `ai_workspace_screen.dart:714` (`if (canInstall)`) |
| PS-23 | major | On a running tool, Open Dashboard is the primary action, not Stop | `ai_workspace_screen.dart:745` |

### FIX-15 -- Settings: validate `.wslconfig`, restore the missing controls

**Landed 2026-08-30.** Save refuses to write a `.wslconfig` value WSL would
reject: the seven numeric/size keys run through the same `parseWslSize` /
`parseWslCount` the widgets use, and an unparseable value keeps the user on
the screen with the setting named — WSL reports a bad value on stderr with
exit code 0 at every distro start, so writing it meant the app could never
learn it was wrong (ST-05). The inline warning appears on the keystroke
instead of on whatever unrelated rebuild came next (ST-06).

**ST-08's missing sliders were bad system probes**, not layout: on this host
`SysInfo` reported 0 bytes of memory and 1 core, which scaled the Memory,
Processors and Swap sliders to nothing. Memory now comes from win32's
`GlobalMemoryStatusEx` (`helpers.dart`, `hostPhysicalMemoryBytes()`) with
SysInfo as the fallback, and the processor ceiling from
`Platform.numberOfProcessors`.

The enumeration control became a below-opening flyout with a leading **Not
set** entry: an enumeration used to be un-clearable once touched, unlike the
booleans (ST-16), and the ComboBox popup anchored on the selected item and
covered its own field (ST-17). The MCP public-internet warning shows only
while the tunnel is actually running instead of contradicting the
"only reachable from this machine" hint two lines above it (ST-20); the three
copy buttons answer with a toast (ST-21); the remote SSH target is disabled
while its toggle is off (ST-24); a chosen path renders as real text with only
the fallback default left as a placeholder (ST-25); Save no longer
materialises repo defaults the user never chose (ST-26); the unset booleans
state their fact once, not twice in two type styles (ST-15); and the Sync
group opens with a sentence saying what sync is, drops the
`SecretPassword123` example from its masked field, and hands the distro-repo
field to the Docker group it belongs with (ST-23).

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| ST-05 | blocker | Validate `.wslconfig` values before writing -- WSL rejects them on stderr with exit code 0, so the app currently reports nothing | `settings_screen.dart:496` (`_numericWslKeys`), save gate at `:527` |
| ST-06 | major | Run the validation on change, not on an unrelated rebuild | `settings_screen.dart:2026` |
| ST-08 | major | Fix or replace `SysInfo` -- it reports 0 bytes and 1 core here, so the Memory / Processors / Swap sliders never render at all | `helpers.dart` (`hostPhysicalMemoryBytes`), `settings_screen.dart:1424`, `:1656` |
| ST-16 | major | Give enumerations a "not set" item so a value can be un-chosen, as the booleans allow | `settings_screen.dart:1945` |
| ST-20 | major | The public-internet warning currently shows whenever MCP is on, contradicting the hint two lines above it | `settings_screen.dart:1160` |
| ST-17 | nit | Position the enumeration flyout so it does not cover its own field, and mark the current value | `settings_screen.dart:1938` (`DropDownButton`) |
| ST-21 | nit | Give the copy buttons feedback | `settings_screen.dart:1073`, `:1114`, `:1240`, key `copied-text` |
| ST-23 | nit | Explain the sync group; remove the plaintext example password from a masked field; move the non-sync setting out | `settings_screen.dart:1352`, `:1383`, `:1332` |
| ST-24 | nit | Disable "Remote SSH target" while the toggle that uses it is off | `settings_screen.dart:842` |
| ST-25 | nit | Distinguish a set path from an unset one -- both currently render as grey placeholder text | `settings_screen.dart:311` (seeded), placeholders trimmed |
| ST-26 | nit | Do not materialise a Docker repository default the user never chose on Save | `settings_screen.dart:553`, `:561` |
| ST-15 | nit | "true (Default)" and "Not set -- using the default" state one fact twice on one row, twelve times over | `settings_screen.dart:1912` |

### FIX-16 -- The create / install form

**Landed 2026-08-30.** One sanitiser now, `sanitizeDistroName()` in
`helpers.dart`: Create replaced `[^A-Za-z0-9]` while Copy replaced
`[^a-zA-Z0-9_-]`, so the same typed name could produce two different distros
(CI-05) — and Copy runs the duplicate check it always skipped, against a list
fetched before its dialog opens. When sanitising would change the typed name,
a live preview says what will actually be created, so an all-non-ASCII name no
longer silently becomes underscores (CI-04).

The failure banner clears on the keystroke that makes it stale (CI-01), and
Create disables while the inline duplicate message is showing, so submitting
cannot add a second copy of the same complaint in a second visual style
(CI-02). Changing the source type clears the source value — a rootfs path is
not a Docker tag (CI-08) — and refetches the suggestions, which live in state
now instead of being a fresh future per build re-running the whole fetch on
every keystroke; a failed load shows the reason with a Retry, and a pending
one a spinner (CI-11). The source field's tooltip says what the chosen source
takes (CI-09), the name field has an `InfoLabel` like the field below it
(CI-06), and its clear X only exists while there is something to clear
(CI-07).

In the community list, a search with no hits says so instead of rendering an
empty scroll area, and a selection the filter hides is dropped — it used to
ride along invisibly on the Download button (CI-35). CI-38 landed earlier
with the FIX-12 slice: the WSL install panel is a real button that names the
elevation prompt, with the command kept beside it for terminal users.

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| CI-04 | major | Show the sanitised name, or reject the input -- silently rewriting `[^A-Za-z0-9]` to `_` turns an all-non-ASCII name into `___` | `create_dialog.dart:658` (`namewillbe-text` preview) |
| CI-05 | major | One sanitiser and one duplicate check shared by Create and Copy; Copy currently skips the duplicate check entirely | `helpers.dart` (`sanitizeDistroName`), `copy_dialog.dart:18` |
| CI-01 | major | Clear the error banner when the input that caused it changes | `create_dialog.dart:503` |
| CI-02 | major | One duplicate-name message, not two simultaneously in two visual styles | `create_screen.dart:44` (`_nameTaken`), Create disabled at `:262` |
| CI-08 | major | Reset the source value when Source Type changes | `create_dialog.dart:475` |
| CI-35 | major | An empty search must say so, and only visibly-selected snippets may be downloaded | `qa_list.dart:156`, `:190` |
| CI-38 | major | Make `wsl --install` a button that states it needs elevation, not a hyperlink described as text to copy | `install_dialog.dart` (with the FIX-12 slice) |
| CI-06 | nit | Give the name field an `InfoLabel`, like the field below it | `create_dialog.dart:623` |
| CI-07 | nit | Hide the clear (X) button when the field is empty | `create_dialog.dart:634` |
| CI-09 | nit | Per-source-type tooltip text, positioned off the Source Type box | `create_dialog.dart:536` (`_sourceTooltip`) |
| CI-11 | nit | Implement the empty `snapshot.hasError` branch, add a loading state, and hoist the future out of `build` | `create_dialog.dart:512`, `:737` |

### FIX-17 -- Home list and navigation layout

**Landed 2026-08-30.** The structural one first: the home `Column`'s key was
`GlobalVariable.infobox = GlobalKey()`, *inline in build*, so every rebuild —
every AI-panel toggle — handed the subtree a brand-new key, tearing down and
recreating the whole list: expanded rows collapsed, the 5s poll restarted, and
its `for(;;)` loop leaked (LN-03). The key is a field now.

In the row header, the size column is sized to its text instead of taking a
flex share — `Expanded` + `Flexible` both at flex 1 split the header 50/50 and
cut the name at half width beside ~480px of nothing (LN-01) — and it carries a
tooltip saying the bare "1.65 GB" is the virtual disk's high-water mark on
Windows, with a dash instead of a silent blank on a failed read (LN-25). The
stop button keeps its footprint invisibly while a distro is stopped, so the
name stops jumping ~30px on every start/stop (LN-02); on a running distro the
first button's tooltip says it opens a terminal instead of promising "Start"
(LN-26); hover lights the same whole-row ring keyboard focus uses, instead of
the chevron 660px from the cursor (LN-09); and the header's play/stop icons
share the action bar's 16px (LN-08).

Icons: the solid VS bowtie — the heaviest mark in a strip of eight outlines —
is `file_code` (LN-05); rename is a pencil, disk usage a usage-share glyph,
and save-as-template an archive box distinct from copy's two pages (LN-06);
the Snippets nav item stops sharing Templates' file silhouette (LN-11). An
expanded row with no snippets says what would fill it (LN-07). Mount Disk and
About are `PaneItemAction`s — modal openers, not destinations that never take
the selection (LN-16). The empty-state CTA sits centered under the sentence
that motivates it instead of sharing its corner with the AI chat FAB (LN-21).
LN-10/PS-10 (the BETA badge painted over the compact-mode icon) landed with
the FIX-10 slice: compact mode gets a corner dot.

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| LN-03 | major | Hoist the `GlobalKey` out of `build` -- a new key per build tears down the list subtree (and leaks `reloadEvery5Seconds`'s `for(;;)` loop) every time the AI panel toggles | `home_screen.dart:33` |
| LN-01 | major | Give the distro name the row width it has; `Expanded` + `Flexible` both at flex 1 split it 50/50 and leave ~480px empty | `list_item.dart:196` |
| LN-02 | major | Reserve the running indicator's space so the name does not jump ~30px when a distro starts or stops | `list_item.dart:146` (`Visibility` maintainSize) |
| LN-10 | major | Keep the BETA badge off the AI Workspace icon in compact mode -- it hides the only affordance | `panelist.dart:50` (with the FIX-10 slice) |
| PS-10 | major | Same overlap, recorded from the Pro pass; closes with LN-10 | with LN-10 |
| LN-21 | major | Separate the empty-state CTA from the AI chat FAB -- they occupy the same corner | `list.dart:92` (CTA centered under the sentence) |
| LN-05 | nit | Replace the one solid glyph among eight outlines | `list_item.dart:395` (`file_code`) |
| LN-06 | nit | Redraw the rename / disk-usage icons and differentiate save-template from copy | `list_item.dart:340` `:421` `:459` (`archive` / `edit` / `pie_single`) |
| LN-08 | nit | One icon size within a row (header default vs action bar pinned to 16px) | `list_item.dart:125`, `:158` |
| LN-09 | nit | Hover the whole row, not the chevron 660px from the cursor | `list_item.dart:91` |
| LN-11 | nit | Differentiate the Snippets and Templates nav icons at 16px | `panelist.dart:25` |
| LN-07 | nit | Say what fills the expanded row when no snippets are configured | `list_item.dart:377`, key `nosnippetshint-text` |
| LN-16 | nit | `PaneItemAction` for Mount Disk and About -- they open modals, not destinations | `panelist.dart:92`, `:171` |
| LN-25 | nit | Label the size column and say it is VHDX-on-disk; do not blank silently on failure | `list_item.dart:201`, keys `sizeondiskhint-text` / `diskusageunavailable-text` |
| LN-26 | nit | Start must not stay enabled, and must not still say "Start", on a running distro | `list_item.dart:113` (tooltip + `command_prompt` icon) |

### FIX-18 -- Recommendations panel

The dismiss control writes to prefs and changes nothing, and the "clear" function adds
to the list it claims to clear.

**Landed 2026-08-30.** The panel is a `StatefulWidget` now, so dismissing a card
takes it off the screen on the click rather than on whatever rebuild happened
next (PS-41). The misnamed `clearDismissed()` — which *adds* to the dismissed
list — is `dismiss()`, and the "Go to" link no longer calls it at all, so acting
on a recommendation stops erasing it (PS-42). Dismissed cards are filtered
before the empty check, so a panel with nothing left to say disappears instead
of standing as an empty bordered box (PS-44); the text column is `Expanded`
so the dismiss X sits at the card's right edge, and the 11px/10px text is
12px/11px (PS-45). Regression tests: `test/recommendations_panel_test.dart` (2).

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| PS-41 | major | Dismiss must remove the card from the panel, not just write `DismissedRecommendations` | `recommendations_panel.dart:146` |
| PS-42 | major | `clearDismissed()` must clear, and the "Go to" link must not dismiss as a side effect | `recommender_service.dart:105` (`dismiss`), `recommendations_panel.dart:121` |
| PS-44 | nit | Hide the panel when every recommendation is dismissed instead of leaving an empty bordered box | `recommendations_panel.dart:33` |
| PS-45 | nit | Pin the dismiss X to the right edge and raise the 11px / 10px text | `recommendations_panel.dart:101` |

### FIX-19 -- AI chat panel

**Landed 2026-08-30.** The panel says up front that it needs an API key — an
InfoBar with an Open Settings action renders before the first keystroke, where
the precondition used to be revealed only by pressing Send (PS-34). The header
gained a close control (the FAB behind the panel used to be the only way out),
and an in-flight request gained a Cancel: a generation counter orphans the
hung request so its late reply is dropped. The user avatar is a person glyph
instead of a plus sign (PS-37), and below 1000px the panel scales with the
window instead of holding 360px — 40% of a narrow window (PS-38).

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| PS-34 | major | Say up front that the panel needs an API key, and give it a close and a cancel | `ai_chat_panel.dart:211` (notice), `:197` (close), `:34` + `:262` (cancel) |
| PS-37 | nit | Use a person glyph for the user avatar, not `FluentIcons.add` | `ai_chat_panel.dart` (`FluentIcons.contact`) |
| PS-38 | nit | Make the 360px panel responsive below ~1000px, where it takes 40% of the window | `home_screen.dart:108` |

### FIX-20 -- Templates, snippets, mount and the per-distro dialog

Pure polish, but it is where a third of the audit's nits live.

**Landed 2026-08-30.** Sizes come from one `formatBytes` — the copy that lived
in `disk_dialog.dart` moved to `helpers.dart` and the template list shares it,
so a 40 MB template reads "40 MB" instead of "0.04 GB" (ST-42), and nothing
under ~5 MB is silently dropped from the list any more: the '0 GB'-means-hide
branch is gone (ST-37). The templates screen has a title and one sentence
saying what a template is and where one comes from, in both the list and the
empty state (ST-41), and its create dialog says "Create a new instance from
the template ..." instead of "Copy ... the WSL instance" (ST-39).

Snippets: the expanded row is sized to its script, capped at 40% of the
window, instead of a half-window panel that was 97% empty for a one-liner
(ST-55); a sentence above the script says a snippet is a bash script run as
root in an instance, and a Run flyout — listing the instances — makes it
usable from this screen (ST-60); the editor is framed, filled and labelled
"Script" instead of 580px of invisible click target (ST-58); and "Add
community snippets" sits beside "Add a snippet" instead of the opposite
corner (ST-61). Hover adds a subtle fill instead of dropping the row to 50%
opacity — the one hover state in the app that made its target harder to read
(IA-22).

Mount: a segmented mode switch replaces the three radio buttons whose third
member was the inverse operation, and the title says Unmount when that is
what the button will do (ST-47); an empty mounted-disk list says "Nothing is
currently mounted" instead of hiding the picker (ST-48); the mount-options
hint is a finished sentence (ST-49); and both forms end with where the disk
actually lands — /mnt/wsl/ in every instance (ST-52). ST-50's label spacing
had already been fixed by the ST-45 rework (bottom-aligned row, 10px gutter).

Per-distro dialog: the serving button says which of start/stop it will do —
`Sync` tracks the served distro statically, like its server — and repaints on
press (ST-31); the "unset" caption is grey like the `.wslconfig` screen's,
not an accent blue that read as a dead hyperlink (ST-34); and the user
section labels itself once, with the parenthetical attached to the fields it
describes (ST-35).

| ID | Sev | Fix | Fixed in |
|:---|:---|:---|:---|
| ST-37 | major | Format sub-GB template sizes properly and never silently drop a template from the list because it formats to "0 GB" | `templates.dart:146`, `template_screen.dart:154` |
| ST-39 | major | Title the new-instance dialog for what it does, not "Copy ... the WSL instance" | `template_screen.dart:192` |
| ST-55 | major | Size the snippet expander to its content instead of a 430px panel that is 97% empty | `actions_screen.dart` (expander content, 40% cap) |
| ST-42 | nit | Same size formatter ("0.01 GB") | `helpers.dart` (`formatBytes`, shared with `disk_dialog.dart`) |
| ST-41 | nit | Give the templates screen a title, an explanation of what a template is, and a way to create one | `template_screen.dart:113`, `:128` |
| ST-47 | nit | Replace the three radio buttons used as a tab strip, and change the title in unmount mode | `mount_dialog.dart` (`_modeButton`, title switch) |
| ST-48 | nit | Say the list is empty rather than making the picker vanish | `mount_dialog.dart` (`nothingmounted-text`) |
| ST-49 | nit | Finish the mount-options placeholder sentence, or tooltip it | `mountoptionshint-text` rewritten, all nine locales |
| ST-50 | nit | Space the Partition / Filesystem Type labels | already spaced by the ST-45 rework (bottom-aligned row, 10px gutter) |
| ST-52 | nit | Say which distro the disk lands in and where it appears | `mount_dialog.dart` (`mountlanding-text`, both forms) |
| ST-58 | nit | Frame and label the code editor -- 580px of invisible click target | `actions_screen.dart` (`Editor.build`) |
| ST-60 | nit | Say that a snippet is a root bash script in a distro, and let it be run from this screen | `actions_screen.dart:44` (`_runSnippetButton`), `snippetrunsasroot-text` |
| ST-61 | nit | One "add" affordance; fix "Add Community snippets" | `actions_screen.dart:196` (grouped); casing fixed with FIX-12 |
| ST-31 | nit | Show which state "Start/Stop serving on network" is in, and persist `isSyncing` | `sync.dart` (`servingDistro`), `settings_dialog.dart:243` |
| ST-34 | nit | One visual language for "unset" -- the dialog's currently looks like a hyperlink | `settings_dialog.dart:665` |
| ST-35 | nit | Remove the duplicated user-section label and the orphaned parenthetical | `settings_dialog.dart:199` |
| IA-22 | nit | Hover must add contrast, not drop the row to 50% opacity | `hoverable.dart` (subtle fill) |

## Not examined

Recorded as the audit runs, so it never implies coverage it does not have. This is the
union of the six per-area "not examined" sections; nothing is listed there that is not
listed here.

- **Remote WSL over SSH** -- needs a second Windows host; not available here. The *failure*
  path was exercised deliberately by pointing `RemoteWSLTarget` at an unreachable host
  (LN-17, LN-18, LN-20); the happy path was not. `copyDialog` branches on `UseRemoteWSL`
  (`copy_dialog.dart:73`, `:101`), so **copy over remote WSL** is unexamined for the same
  reason.
- **The zero-distro home empty state, live** -- reaching it means deleting the host's real
  distros, and `HomePage` constructs its own `WSLApi()` with no injection seam, so it
  cannot be substituted in a widget test either. LN-21 and LN-22 are recorded from source
  and labelled as such.
- **Docker container rows** (`showDocker`) and the `wslNotInstalled` install prompt -- no
  Docker containers on this host, and WSL is installed.
- **The row's quick-actions dropdown with snippets configured** -- none are configured, so
  only the empty branch was seen (LN-07).
- **The WSL-not-installed panel** (`install_dialog.dart`) -- WSL is installed on this host,
  so CI-38..CI-40 are read from source and labelled as such in [[create-and-install]].
- **A real Docker Hub pull, a real local `docker save`, and `Import VHDX`** -- no Docker
  daemon and no spare `.vhdx` here. Those three source types were exercised as far as the
  create *form* goes (CI-08, CI-10, CI-26); no image or disk was actually fetched.
- **The `passwd` console window** that the create flow spawns when a default user is given
  (CI-13) -- deliberately not triggered, so the audit does not leave a passwordless
  account on the host.
- **Windows in dark mode.** This host runs `AppsUseLightTheme = 1` and the OS theme was
  deliberately not flipped, so TL-03 -- the app handing black text to a dark UI under the
  default `ThemeMode.system` -- is measured from the getter by a probe test rather than
  screenshotted. The in-app Dark Mode toggle *was* exercised on eight screens.
- **Dark mode for the dialogs.** The light/dark pass covers the eight top-level screens.
  The distro-settings dialog, the mount dialog, the template and snippet dialogs and the
  *free-user* licence comparison table were not re-walked in dark; their `Colors.grey`
  sites are recorded from source in TL-08.
- **Locales beyond home / create / settings.** The three screens the task names were
  captured in all nine locales; the mount dialog was added in `zh_TW` because TL-09
  needed a picture. Templates, snippets, the AI Workspace and the licence screen were
  seen in English only.
- **Right-to-left languages** -- none are shipped, and nothing in the app opts into
  `Directionality`.
- **Store-packaged build** -- the audit runs an unpackaged debug build with the Pro gate
  forced. Anything whose appearance depends on real MSIX package identity (the Store
  purchase flow, a *false negative* from `GetCurrentPackageFullName`) is out of scope for
  the click-through. The **free-tier experience is covered**, though: [[pro-surfaces]]
  relaunched the same build *without* `WSLM_FORCE_PRO`, which is exactly the unpackaged
  free path, and audited every gate from there.
- **The AI Workspace page-level error state** (PS-31) -- `AiWorkspaceService` builds its
  own `ExecutionRequest`s and never sets `useRemote`, so the unreachable-SSH trick that
  reached the list's error branch does not touch it; the only other route is unregistering
  the host's real 16.6 GB `ai-workspace` distro. Read from source and labelled as such.
- **`AiDiagnoseButton` / `diagnoseWithAi()`** -- it only renders on a distro row already in
  an error state or on a failed create. An attempt to reach it via an unreachable
  `RemoteWSLTarget` was abandoned after the SSH connect had not timed out in 2.5 minutes;
  the resulting loading state is already recorded as LN-18/LN-20. Behaviour read from
  source in [[pro-surfaces]] and not counted as a finding.
- **A real AI chat exchange** -- needs a live OpenAI-compatible key and would send this
  machine's WSL configuration to a third-party endpoint. The markdown rendering of
  assistant replies, the scroll-to-bottom behaviour and the in-flight loading row were
  therefore not observed.
- **Dark mode for the Pro surfaces** -- deliberately deferred to [[theme-and-locales]],
  which owns the light/dark diff. PS-36 lists the hardcoded `Colors.grey` literals that
  pass should start from.
- **The Cloudflare tunnel path in MCP settings** -- enabling it downloads `cloudflared`
  and publishes this machine's MCP server, which can run arbitrary commands in every
  distro, to a public URL. Deliberately not triggered; ST-22 is read from source and
  labelled as such in [[settings-and-tools]].
- **A real disk mount** -- no spare physical disk or `.vhdx`, and `wsl --mount` of a disk
  Windows is using is not something to try on the audit machine. The mount forms, the
  empty-unmount state and the empty-field guard were exercised (ST-44..ST-52); no disk was
  attached. Of the four mount/unmount error-recovery dialogs (`mount_dialog.dart:110-251`),
  **the generic one at `:242` was reached** by [[interaction-and-a11y]] -- a VHD mount
  pointed at a missing path, which is what produced IA-16. The unmount-by-name (`:110-160`)
  and attached-but-not-mounted (`:184-230`) branches still need a genuinely attached disk
  and were not reached.
- **Sync over the network** (`Sync().startServer()`, `download()`) -- needs a second
  machine. ST-23, ST-30 and ST-31 are about the controls, not the transport.
- **`Move`, and `Templates().useTemplate()`** -- the confirmations were opened and
  cancelled (ST-29, ST-39, `122`); neither operation was run, so no distro was
  export/unregister/imported and no instance was created from a template.
- **The zero-template state and the sub-5MB template disappearance** -- one real template
  (`test-4`) exists here; ST-37 is read from source and `notemplates-text` was not reached.
- **Actual screen-reader output.** IA-09's "22 of 38 tap targets have no accessible name"
  and IA-10's "no `Semantics(label:)` anywhere" are counted from the widget tree and from
  the `MergeSemantics(Tooltip(...))` contract AGENTS.md documents. No Narrator or NVDA
  session was run, so the counts are claimed and the exact utterances are not.
- **Windows High Contrast mode, the "Show focus rectangle" setting, and non-100% display
  scaling.** IA-07's one-pixel focus ring was measured in the default theme at
  `devicePixelRatio` 1.0.
- **Stop-by-stop tab order beyond four surfaces.** Home, Add an Instance, Settings and the
  delete confirmation were walked keystroke by keystroke with the VM-Service focus probe;
  Snippets, Templates, Distro packages, AI Workspace, License and About were only checked
  for reachability from the nav pane. IA-02 and IA-03 live in the shell and were confirmed
  on two screens each.
- **Reverse (`Shift+Tab`) traversal order.** Only exercised from IA-01's dead root-scope
  state, where nothing moves. The forward order recorded in IA-05 was not verified to be
  symmetric.
- **Long-running operations on the Docker, remote-WSL and AI Workspace paths.** IA-12 was
  measured on start / stop / delete against a real distro; the Docker messages in IA-18 are
  read from source (no Docker daemon here), and the cancel gaps on the other two paths are
  recorded as CI-14 and PS-18 rather than re-walked.
- **The `loading: true` X pressed mid-operation.** IA-14 is derived from
  `notify.dart:63-67` and `root_screen.dart:231`; no multi-minute operation was started
  purely to click its close button.
- **A failed `AiWorkspaceService.stop()`** (PS-32) -- would mean deliberately breaking a
  tool inside the distro. Read from source; the fix is covered by a unit test that
  forces the failing exit code instead (`ai_workspace_service_test.dart`).
- **The MCP server's Pro half beyond the gate.** The endpoint, token, copy and regenerate
  controls were audited under the Pro build (ST-19..ST-22); [[pro-surfaces]] adds only the
  free-user gate (PS-11). The tunnel stays untriggered for the reason above.
- **Locales at the narrow 900px width.** Below fluent_ui's 1008px threshold the pane is
  icon-only, so the labels that could overflow are not rendered there at all; the narrow
  pass covers the layout itself, not the translated labels in it.
- **The recommendations panel in dark.** Reaching it needs `DockerImageCount` seeded as
  [[pro-surfaces]] did; its border (`recommendations_panel.dart:29`) is in TL-08 from
  source.
