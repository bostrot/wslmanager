---
type: analysis
title: UI/UX Audit -- Settings, Templates, Mount and Actions
created: 2026-08-28
tags:
  - ui
  - ux
  - audit
  - phase-07
  - settings
  - templates
  - mount
  - snippets
related:
  - '[[index]]'
  - '[[list-and-navigation]]'
  - '[[create-and-install]]'
  - '[[interaction-and-a11y]]'
  - '[[theme-and-locales]]'
  - '[[pro-surfaces]]'
---

# Settings, templates, mount and actions

The app-wide settings screen (`lib/screens/settings_screen.dart`, including everything
Phase 05 added), the per-distro settings dialog (`lib/dialogs/settings_dialog.dart`), the
template screen (`lib/screens/template_screen.dart`), the mount dialog
(`lib/dialogs/mount_dialog.dart`), the snippets/actions screen
(`lib/screens/actions_screen.dart`) and the community snippet list
(`lib/components/qa_list.dart`).

Walked live under the run configuration in [[index]] -- debug build,
`WSLM_FORCE_PRO=true`, `en`/light, 1400x860 with a narrow 900x860 pass, two real distros
and one real template on the host. **62 findings (ST-01..ST-62)**, plus a verified-pass
list at the end.

Five claims in this pass are **measured rather than reasoned about**: the save/discard
behaviour was driven end to end and checked against `%USERPROFILE%\.wslconfig` and
`shared_preferences.json` on disk after each step; an invalid `.wslconfig` was written by
the app and then fed to a real `wsl.exe` distro start to capture what WSL actually says
about it; the disabled-reason and snippet-header text were sampled per pixel for contrast;
the MCP token was regenerated and both values read off the screenshots; and
`SysInfo.getTotalPhysicalMemory()`/`SysInfo.cores.length` were probed directly to explain
why three sliders never render.

The host state was restored afterwards: `.wslconfig` from `%TEMP%\wslconfig-p07-backup`
(re-verified back to 0 bytes), `shared_preferences.json` from
`%TEMP%\wslm-prefs-p07-settings.json`, the `audit-demo` snippet deleted through the UI,
and the MCP server toggled back off.

Screenshots referenced by filename only; they live in `.maestro/screenshots/phase-07/`
and are **gitignored**. Severity: **blocker** / **major** / **nit**. Effort: **S** (under
an hour), **M** (half a day), **L** (a day or more).

## Findings

### The save / discard model

#### ST-01 -- Leaving Settings by any route other than the Save button silently discards every edit

**blocker / M** -- `lib/screens/settings_screen.dart:88-98`, `:251-344` --
`103`, `104`, `105`, `106b`, `107-settings-save-noop.png`

Driven twice in one session, against the file on disk:

| Step | Action | `.wslconfig` afterwards |
|:---|:---|:---|
| 1 | Toggle `SafeMode` on (`106b` shows it reading `true` with an undo arrow), then click **Home** in the nav pane | unchanged -- no `safeMode` line |
| 2 | Re-open Settings | `SafeMode` reads `false (Default) Not set` again (`105`) |
| 3 | Toggle `SafeMode` on again, press **Save** | `safeMode = true` written (`107`) |

The same for app preferences rather than `.wslconfig` keys: typing `codium-audit` into
**Default VS Code Command** and then clicking Home left `flutter.VSCodeCmd` empty in
`shared_preferences.json`, and the field was blank on the next visit (`110`).

There is no unsaved-changes prompt, no Cancel, no Discard, and no dirty marker anywhere on
the screen. A user who edits three things and clicks Home loses all three with no signal.

What makes this a blocker rather than a design choice is that the code believes the
opposite. `dispose()` calls `saveSettings(currentContext!, dispose: true)` specifically so
that closing the screen commits, and it observably does not fire. So the screen has
*neither* contract implemented cleanly: the code intends auto-save, the behaviour is
discard-on-exit, and the UI communicates neither.

Fix: pick one. If Save is load-bearing, add a Cancel next to it and prompt on exit with
unsaved changes. If auto-save is intended, remove the Save button and repair the dispose
path.

#### ST-02 -- Language is the one setting with the opposite persistence rule, and it lies about needing a restart

**major / S** -- `lib/screens/settings_screen.dart:607-613` --
`109-settings-language-open.png`, `110-settings-language-de-selected.png`

`onChanged` calls `prefs.setString('language', curLanguage)` directly. Measured: selecting
**Deutsch** wrote `flutter.language = de` to `shared_preferences.json` immediately -- no
Save pressed -- and it survived navigating away, while every other control on the same
screen was discarded (ST-01).

The screen therefore contains ten controls that need Save and one that ignores it, with
nothing to tell them apart. And because there is no Cancel, a mis-click on this ComboBox
cannot be undone by leaving the screen; it has to be changed back by hand.

The UI stayed entirely in English after the switch (`110` -- the combo reads "Deutsch",
every label around it is still English), which the caption under it does warn about
("Language change will take effect after restart"). That warning is itself a finding: a
`fluent_ui` app can rebuild with a new locale, and asking the user to restart the
application to see a menu change is the kind of thing only the implementation cares about.

#### ST-03 -- Save teleports the user to Home and says nothing about what it wrote

**major / S** -- `lib/screens/settings_screen.dart:341-343` --
`100-settings-after-save.png`

`saveSettings` ends with `router.pushNamed('home')`. Pressing Save on the settings screen
therefore closes the settings screen. There is no toast, no InfoBar, no "Saved" state on
the button -- the screen simply vanishes and the distro list appears (`100`). The user
cannot verify the change took, cannot make a second change without navigating back, and
gets no confirmation that a file was written at all.

#### ST-04 -- "Stop WSL" shuts down every distro on the machine, sits beside Save, and has no confirmation

**major / S** -- `lib/screens/settings_screen.dart:208-224` --
`102b-stopwsl-tooltip-zoom.png`, `81-settings-top.png`

`WSLApi().restart()` is `wsl --shutdown`: it terminates every running distro and kills
every process inside them, including unsaved work in an editor a user has open over
`\\wsl$`. The control is a plain `Button` with the same styling as Save, 10 px to its
left, in the screen's persistent footer.

There is no confirmation dialog, no "this will stop N running distros" count, and no
statement of consequences anywhere. The one place a warning could have lived -- the
tooltip -- contains the string "Stop WSL", i.e. the button's own label (`102b`).

It also navigates away (`Navigator.popAndPushNamed(context, '/')`), which under ST-01
means pressing it discards whatever the user was editing.

### Validation

#### ST-05 -- An invalid value is written to `.wslconfig` unchallenged, and WSL rejects it at every distro start

**blocker / M** -- `lib/screens/settings_screen.dart:355-369`, `:1595-1624` --
`98-settings-invalid-values.png`, `100-settings-after-save.png`

Typed `eight gigabytes` into **Memory** and `999` into **Processors**, pressed Save. The
file on disk afterwards:

```ini
[wsl2]
memory = eight gigabytes
processors = 999
guiApplications = false
networkingMode = mirrored
```

Nothing blocked the save, nothing warned at save time, and the Save button was never
disabled. What WSL then does with it, measured with a real distro start
(`wsl -d Ubuntu --exec /bin/true`, German-locale host):

```
wsl: Ungültige Speicherzeichenfolge "eight gigabytes" für .wslconfig Eintrag
     "wsl2.memory" in "C:\Users\Eric\.wslconfig:2".
wsl: wsl2.processors darf die Anzahl logischer Prozessoren auf dem System nicht
     überschreiten (999 > 10)
```

**with exit code 0.** The distro starts, the two keys are ignored, and the only notice the
user gets is on a stderr stream nothing in the app reads (see ST-07).

The screen already knows both values are wrong -- `parseWslSize` returns null for the
first and the app has a processor ceiling for the second. It just does not act on that
knowledge at the one moment it matters.

#### ST-06 -- The validation message never appears while typing

**major / S** -- `lib/screens/settings_screen.dart:1595-1621` --
`98-settings-invalid-values.png` vs `99-settings-warning-after-rebuild.png`

Reproduced in two consecutive screenshots. `98`: `memory` contains `eight gigabytes`, no
warning anywhere. `99`: after toggling an unrelated switch (`GuiApplications`, 270 px
further down) the line "Not a size WSL understands. Use a plain number of bytes, or add
KB, MB, GB or TB." appears under the field, unchanged input.

The warning is computed inside `build()` from `_settings[name]!.text`, and the `TextBox`
has no `onChanged` and no controller listener, so typing never triggers a rebuild. The
message is real, correct and well written -- it is simply unreachable through the only
interaction that produces the condition it describes. The same applies to
`settinginvalidnumber-text` and `settingoutofrange-text`.

(It *does* render on load, which is how `99`, `103` and `105` show it after the screen was
rebuilt for other reasons -- so this is specifically a live-typing gap, not a dead string.)

#### ST-07 -- The "WSL reported:" panel structurally cannot show a rejected `.wslconfig` key

**major / M** -- `lib/api/wsl_capabilities.dart:157-182`, `:245-260`,
`lib/screens/settings_screen.dart:1232-1241` -- `101-settings-wslwarnings.png`

`WslCapabilities.warnings` is built from the stderr of `wsl --version` and `wsl --status`,
and the file comment states its purpose plainly: wsl.exe reports refused `.wslconfig` keys
on stderr with exit code 0, so the app carries those words through to the user.

It cannot, because neither probe emits them. Measured with the broken config from ST-05
still in place: `wsl --version` exited 0 with **empty stderr**, while a distro *start*
printed all three rejections. `101` is the settings screen at that moment -- version
`2.6.3.0`, two update buttons, and no warnings block at all, over a `.wslconfig` WSL was
refusing three keys from.

Second, smaller problem in the same place: `WslCapabilityService` caches for the app's
lifetime and is only `reset()` by the update button, so even if the right command were
probed, the answer would be the one from startup, before the user's edit.

Fix: probe something that actually parses `.wslconfig` -- the cheapest is a
`wsl --exec /bin/true` against the default distro after a write -- and re-run it after
Save rather than once at launch.

#### ST-08 -- Memory, Processors and Swap silently degrade to plain text boxes

**major / S** -- `lib/screens/settings_screen.dart:1269-1272`, `:1082-1091`, `:1592-1595`
-- `91b-memory-processors-zoom.png`

All three keys are declared as sliders. All three render as text boxes (`91b` at 3x --
`Memory` and `Processors` are bordered `TextBox`es, not slider tracks).

Measured cause, probed directly from a test in this tree:

```
PROBE totalPhysicalMemory=0 cores=1 gb=0
```

`SysInfo.getTotalPhysicalMemory()` returns **0** and `SysInfo.cores.length` returns **1**
on this host (Windows 11 Pro 26200). So `memory` gets `sizeMax = 0 + 1 = 1` against
`sizeMin = 1`, `processors` gets `sizeMax = 1` against `sizeMin = 1`, and `swap` gets
`sizeMax = 0 * 2 = 0`. `hasSlider` (`sizeMax > sizeMin`) is false for all three and
`_numericSetting` falls through to its text-box branch.

wsl.exe on the same machine says the true count is **10** logical processors (ST-05), so
this is `system_info2` failing, not an unusual host.

Three consequences beyond the missing slider: the out-of-range warning
(`settingoutofrange-text`) is unreachable, because it is only produced when `hasSlider` is
true; `parseWslSize` is called with `bareUnitMax: 1`, so a bare `8` typed into `memory` is
read as 8 *bytes* rather than 8 GB; and a machine where `SysInfo` reports a *small*
non-zero value would silently cap the slider below the hardware's real capability.

Fix: fall back to a sane ceiling when `SysInfo` answers 0 or 1 (and prefer a source that
works -- `wsl.exe` itself reports the processor count in the very error message above), and
never derive `bareUnitMax` from a bogus maximum.

### Labels and copy

#### ST-09 -- Twenty-six settings are labelled with their raw `.wslconfig` key name

**major / M** -- `lib/screens/settings_screen.dart:1389-1393` --
`91`, `92`, `93-settings-globalconfig-4.png`

`settingsWidget` builds the label with
`title.replaceFirst(title[0], title[0].toUpperCase())` -- i.e. it upper-cases the first
letter of the identifier and calls it a label. On screen:

> KernelModules · LocalhostForwarding · KernelCommandLine · SafeMode · SwapFile ·
> GuiApplications · DebugConsole · NestedVirtualization · VmIdleTimeout · MaxCrashDumpCount ·
> DnsProxy · NetworkingMode · DnsTunneling · AutoProxy · DefaultVhdSize ·
> AutoMemoryReclaim · SparseVhd · BestEffortDnsParsing · DnsTunnelingIpAddress ·
> InitialAutoProxyTimeout · IgnoredPorts · HostAddressLoopback

Every one of these is a camelCase identifier presented to an end user as a heading, in all
nine locales, and none of them is translatable -- the strings are Dart literals at the call
sites, not i18n keys. The *descriptions* under them are all properly translated, which
makes the contrast sharper: a translated sentence under an untranslated identifier.

The keys do need to be discoverable (a user comparing against Microsoft's documentation
needs the exact spelling), so the fix is a human label plus the key as secondary text --
"Kernel modules  ·  `kernelModules`" -- not a rename.

#### ST-10 -- The disabled-control explanation is the lowest-contrast text on the screen, at 2.51:1

**major / S** -- `lib/screens/settings_screen.dart:1412-1420`, `lib/theme.dart`
(`disabledTextColor`) -- `97-settings-localhostforwarding-disabled.png`

Sampled per pixel out of `97`, over the "Ignored when the networking mode is mirrored."
line and the ordinary description directly above it:

| Line | Darkest text pixel | Background | Ratio |
|:---|:---|:---|---:|
| Disabled reason (italic) | `#9D9D9D` | `#F6F6F6` | **2.51:1** |
| Description above it | `#5E5E5E` | `#F6F6F6` | 6.00:1 |

WCAG AA wants 4.5:1 for body text and 3:1 even for large text. This line is the *only*
thing on screen that explains why the control beneath it is greyed out -- the one sentence
a user needs when a switch will not move -- and it is rendered less legibly than anything
else in the group.

#### ST-11 -- The disabled reason repeats the description word for word

**nit / S** -- `lib/screens/settings_screen.dart:1096-1097`, `lib/i18n/en.json:414` --
`97-settings-localhostforwarding-disabled.png`

`LocalhostForwarding`'s description ends "…Default: on. Ignored when the networking mode
is mirrored." and the disabled line immediately below reads "Ignored when the networking
mode is mirrored." The same sentence, twice, 20 px apart, in two type styles.

#### ST-12 -- The disabled reason names the raw key, not the label it points at

**nit / S** -- `lib/screens/settings_screen.dart:1147-1148`, `:1331-1361` --
`95-settings-mirrored-disables.png`

"Only applies when networkingMode = nat" refers to a control the same screen labels
`NetworkingMode` -- close enough to guess here, but the pattern generalises badly
(`dnsTunneling = true`, `autoProxy = true`, `networkingMode = mirrored`), and under ST-09
the label is a different string from the key in every case where the key gets fixed.

#### ST-13 -- The Global Configuration note tells a GUI user to run a shell command that the screen has a button for

**nit / S** -- `lib/i18n/en.json:117` -- `90-settings-globalconfig-1.png`

> "…Changes take effect after WSL restarts: run wsl --shutdown to shut down the WSL 2 VM
> and then start your distro again."

The **Stop WSL** button 400 px below does exactly that. The note is a paragraph of
Microsoft documentation pasted into a GUI, including a build number ("Windows Build 19041
and later") and a command line, when what the user needs is "Restart WSL to apply" next to
the button that restarts WSL.

#### ST-14 -- Every button on the screen has a tooltip that repeats its own visible label

**nit / S** -- `lib/screens/settings_screen.dart:192-241` --
`102b-stopwsl-tooltip-zoom.png`

Captured by hovering **Stop WSL** for 1.6 s: a tooltip appears reading "Stop WSL" (`102b`).
The same pattern wraps **Save**, **Edit .wslconfig directly**, the Docker toggle, the sync
fields and the editor/terminal/vscode boxes -- `Tooltip(message: 'x'.i18n(), child: … Text('x'.i18n()))`.

A tooltip that restates the label is pure noise for a sighted user and adds nothing for a
screen reader either. The two controls that genuinely need one -- Stop WSL (ST-04) and the
MCP icon buttons (ST-18) -- have no useful tooltip and none at all respectively.

#### ST-15 -- "true (Default)" and "Not set — using the default" say the same thing twice, side by side

**nit / S** -- `lib/screens/settings_screen.dart:1491-1518` --
`93-settings-globalconfig-4.png`

Every unset boolean renders as a switch labelled `true (Default)` followed by the grey text
`Not set — using the default`. Two statements of one fact, in two type styles, on one line,
repeated for twelve keys down the page. One of them is enough; the switch content is the
better place for it.

### Controls

#### ST-16 -- An enumeration can never be put back to "not set"

**major / S** -- `lib/screens/settings_screen.dart:1527-1566` vs `:1496-1511` --
`94-settings-networkingmode-open.png`, `95-settings-mirrored-disables.png`

Boolean keys get a real third state: an undo button that empties the controller, which the
save engine turns into a line *removed* from the file. `_enumerationBox` has neither -- no
"not set" item in the list and no undo button beside it. Once `networkingMode` is set to
`mirrored`, the only way back to WSL's default is the **Edit .wslconfig directly** escape
hatch.

Measured in passing: picking `mirrored` is also what wrote `networkingMode = mirrored` into
the file in ST-05, from a single click, on a key the user had never touched.

#### ST-17 -- The enumeration flyout covers the control it belongs to and does not mark the current value

**nit / S** -- `lib/screens/settings_screen.dart:1544-1555` --
`94-settings-networkingmode-open.png`

The list opens over the ComboBox itself plus the two settings below it (`Firewall`,
`DnsTunneling`), so the field you are editing is hidden while you edit it -- the same shape
as CI-25 on the create screen. Nothing in the list indicates which value is currently
selected; the highlight in `94` is on `none` because that is the item under the cursor.

#### ST-18 -- Four unlabelled icon buttons on the MCP rows, with no tooltip and no accessible name

**major / S** -- `lib/screens/settings_screen.dart:783-787`, `:809-828` --
`86-settings-mcp-on.png`, `87-settings-mcp-token-visible-crop.png`

Copy-endpoint, reveal-token, copy-token and regenerate-token are bare `IconButton`s. None
is wrapped in a `Tooltip`, and none is wrapped in `MergeSemantics`, which per AGENTS.md is
what a `fluent_ui` `IconButton` needs before a tooltip can name it at all. Two of the four
are the same copy glyph on two different rows, and the fourth is a refresh circle that in
fact destroys a credential (ST-19).

#### ST-19 -- Regenerating the MCP access token takes one click, with no confirmation and no notice that clients break

**major / S** -- `lib/screens/settings_screen.dart:823-828` --
`87-settings-mcp-token-visible-crop.png`, `88-settings-mcp-token-regenerated-crop.png`

Measured, by clicking the refresh icon once:

| Before | After |
|:---|:---|
| `dWc9-Axyonz9d1ffo4QcEqvTFGM_8Lsn` | `1oj80i0T3TVSxvQ0Ek0HGwpdI3sshZQN` |

`onPressed: () => setState(() => _mcpService.regenerateToken())`. No dialog, no undo, no
toast, and nothing anywhere saying that every MCP client already configured with the old
token -- Claude Desktop, an agent, a script -- stops working the instant it is pressed. The
button sits 4 px from a copy button, on a row whose other three controls are harmless.

#### ST-20 -- The public-internet warning is shown even when nothing is exposed, contradicting the hint two lines above it

**major / S** -- `lib/screens/settings_screen.dart:834-840` --
`86-settings-mcp-on.png`

The warning InfoBar is inside `if (_mcpEnabled && isPro)`, not inside a tunnel check, so it
renders the moment the local server is enabled. `86` shows the resulting contradiction in
one screenful:

> **Enable WSL MCP server** — "…Only reachable from this machine, and only with the token below."
> ⚠ "This exposes your MCP server (and everything it can do — including running commands) to the public internet at a temporary URL."
> **Expose via Cloudflare Tunnel** — *off*

The text is good; it just belongs to the toggle beneath it. Warning about a risk the user
has not taken is how users learn to skim warnings.

#### ST-21 -- Copy buttons give no feedback

**nit / S** -- `lib/screens/settings_screen.dart:783-787`, `:817-821`, `:911-915`

`Clipboard.setData(...)` with no `Notify.message`, no icon state change, nothing. Pressing
copy is indistinguishable from missing the button.

#### ST-22 -- The tunnel error is a raw `e.toString()` in hardcoded red

**nit / S** -- `lib/screens/settings_screen.dart:864-865`, `:886-893`

`_tunnelError = e.toString()` rendered as `TextStyle(color: Colors.red, fontSize: 12)`.
Same class of defect as LN-17 and CI-03: an exception string shown to the user, in a colour
that bypasses the theme so the dark pass has to re-check it. Not screenshotted -- starting
a Cloudflare tunnel publishes this machine to the internet, so the failure path was
deliberately not triggered (see "not examined" in [[index]]).

#### ST-23 -- Sync Settings: no explanation, a password example in a masked field, and a setting that is not a sync setting

**nit / S** -- `lib/screens/settings_screen.dart:1004-1053`, `lib/i18n/en.json` --
`89-settings-sync.png`

Three problems in one 200 px group:

* Every other group added by Phase 05 opens with an italic explanatory paragraph (BYOK,
  MCP, Global Configuration). Sync has none, and nothing on the screen says what "sync"
  syncs, between what, or over which port.
* **Sync Password** is `obscureText: true` with the placeholder `SecretPassword123`. A
  masked field showing readable text reads as a stored value until you click it, and the
  suggestion itself is a weak-password example.
* **Extra repo for Distros** is the download source for new distro images. It has nothing
  to do with sync; it belongs next to the Docker repository fields one group up.

#### ST-24 -- "Remote SSH target" stays fully enabled while remote WSL is switched off

**nit / S** -- `lib/screens/settings_screen.dart:556-569` --
`82-settings-general.png`

The toggle above it gates whether any of it is used, and `saveSettings` will even flip the
toggle back off on dispose if the target does not validate -- but the field itself is never
disabled, so an inert text box invites input it will not act on. Compare the `.wslconfig`
section three groups down, which disables dependent controls and (badly, ST-10) says why.

#### ST-25 -- Path settings show their effective value as a grey placeholder, so "set" and "unset" look identical

**nit / S** -- `lib/screens/settings_screen.dart:436-437`, `:458-460` --
`82-settings-general.png`

**Default Distro Location** and **General Data Location** both display
`C:\Users\Eric\AppData\Roaming` in placeholder grey. That is the *fallback*, rendered
exactly the way an empty field renders. Nothing distinguishes "you have not chosen a path,
here is where it will go" from "your chosen path happens to be this", and the controller is
genuinely empty, so the folder-picker button is the only way to find out.

#### ST-26 -- Saving writes a Docker repository default the user never chose

**nit / S** -- `lib/screens/settings_screen.dart:282-287` --
`83-settings-docker.png`

`if (_dockerrepoController.text.isNotEmpty) … else prefs.setString("DockerRepoLink", "https://registry-1.docker.io")`.
Opening Settings once and pressing Save materialises a stored value for a key the user
never touched -- visible in `83`, where **Docker Repository** shows dark (real) text while
**Docker Mirror** right above it shows grey (placeholder) text for the same kind of
setting. `RepoLink` has the same branch; the other seven fields correctly `remove()` on
empty.

### The per-distro settings dialog

#### ST-27 -- Opening the dialog boots the distro

**major / S** -- `lib/dialogs/settings_dialog.dart:666-690`, `:89-106` --
`113-distro-settings-dialog.png` → `114-distro-settings-loaded.png`

`113` was taken with `Ubuntu` stopped. `114`, four seconds later, shows the same row
reading **`Ubuntu (running)`** -- opening a settings dialog started a virtual machine.

`loadDistroSettings` runs `getWSLConf`, which reads `/etc/wsl.conf` over `wsl.exe`, and
`getInstanceData` adds five more in-distro commands. Nothing warns that inspecting settings
has a side effect, and nothing offers to read the file without starting the distro. For a
user who deliberately keeps distros stopped, the Settings gear is a hidden Start button.

#### ST-28 -- Cancel does not cancel

**major / S** -- `lib/dialogs/settings_dialog.dart:69-83` vs `:576-583`, `:628-644` --
`114-distro-settings-loaded.png`, `117-distro-settings-time-expanded.png`

The dialog's **Save** button persists exactly three values (`StartPath_`, `StartCmd_`,
`StartUser_`). Every other control in it -- all fourteen `wsl.conf` keys, the toggles and
the debounced text boxes -- writes to the distro's `/etc/wsl.conf` the moment it changes or
loses focus.

So a user who flips `[boot] systemd`, changes their mind and presses **Cancel** has already
changed their distro. The button says the opposite of what happened, and the dialog gives
no other signal that half its controls are live.

#### ST-29 -- Four irreversible actions are styled exactly like the collapsible sections above them

**major / S** -- `lib/dialogs/settings_dialog.dart:466-482`, `:172-307` --
`116-distro-settings-bottom.png`

`116` shows seven stacked full-width rows, each with a label on the left and a glyph on the
right:

| Row | What it is |
|:---|:---|
| Interop | Expander (chevron) |
| GPU | Expander (chevron) |
| Time | Expander (chevron) |
| **Terminate distro** | **Button — kills the distro** |
| **Start/Stop serving on network** | **Button — starts a network server** |
| **Download/Override from network** | **Button — overwrites the distro from a remote host** |
| **Move** | **Button — export/unregister/import, the operation issue #280 is about** |

They are the same height, the same width, the same border and the same background. The only
difference is the glyph, at 16 px, on the right. Three of the four cannot be undone and one
of them unregisters the distro on WSL below 2.5.

#### ST-30 -- The sync buttons' tooltips do not match their labels

**nit / S** -- `lib/dialogs/settings_dialog.dart:175-176`, `:208-209` --
`116-distro-settings-bottom.png`

Caught by accident while hovering: the button labelled **Start/Stop serving on network**
shows the tooltip **"Upload"**, and **Download/Override from network** shows
**"Download"**. Neither tooltip explains anything the label does not, and the first
actively renames the action. (It also renders overlapping the row above it, visible in
`116`.)

#### ST-31 -- "Start/Stop serving on network" never says which of the two it will do

**nit / S** -- `lib/dialogs/settings_dialog.dart:108-115`, `:187-199`

One button for two opposite actions, with a label that names both and a state that is
invisible. `isSyncing` is a *parameter* of `settingsColumn`, re-supplied from
`_SettingsDialogContentState.isSyncing` (always `false`) on every rebuild and never
persisted, and the `onPressed` never calls `setState`, so nothing on screen ever changes
and re-opening the dialog always offers "start" regardless of whether a server is running.

#### ST-32 -- A twenty-control form in a 500x500 box

**nit / S** -- `lib/dialogs/settings_dialog.dart:60-61` --
`114`, `115`, `116-distro-settings-bottom.png`

`BoxConstraints(maxHeight: 500.0, maxWidth: 500.0)` leaves roughly 340 px of scrollable
content between the title and the button bar, on a 1400x860 window with 900 px of empty
desktop around the dialog. Three fields are visible at a time; reaching **Move** takes ten
wheel notches. Nothing in the dialog is width-constrained by its content -- the six
`wsl.conf` Expanders would benefit from more of both dimensions.

#### ST-33 -- The dialog is titled "Settings", with no distro name

**nit / S** -- `lib/dialogs/settings_dialog.dart:48`, `:62` --
`114-distro-settings-loaded.png`

Identical to the nav item for the app-wide settings screen, so the same word names two
different destinations, and the dialog that edits exactly one distro never says which one.
Everything else in the app that acts on a distro puts the name in the title
(`Copy 'test-4'`, `Delete instance …`).

#### ST-34 -- The same "unset" concept has two different visual languages in two screens

**nit / S** -- `lib/dialogs/settings_dialog.dart:528-531` vs
`lib/screens/settings_screen.dart:1491-1518` -- `117-distro-settings-time-expanded.png`

| | `.wslconfig` screen | `wsl.conf` dialog |
|:---|:---|:---|
| Switch label | `true (Default)` | none |
| Unset marker | grey caption "Not set — using the default" | **accent-blue** caption, same text |
| Undo affordance | icon button, tooltip "Not set — using the default" | icon button, tooltip "Default" |
| Layout | switch, then label to its right | switch left, label + description stacked right |

The accent-blue variant is the worse of the two: it looks exactly like a hyperlink
(`117`), and clicking it does nothing. The two undo buttons do the same job with opposite
tooltips.

#### ST-35 -- The user section labels itself twice and hosts an orphaned parenthetical

**nit / S** -- `lib/dialogs/settings_dialog.dart:157-164` --
`118-distro-settings-userfield.png`

Reading down: **Start user** / its description / a text box / "(empty the fields for
default or if your WSL version does not support it)" / **User** / "(Optional) WSL default
user to use" / a second description / a text box.

The parenthetical sits between two unrelated groups and refers to neither unambiguously.
`User` is a bare `Text` and the field below it renders its own translated label, so the
setting is labelled twice with two different strings, at two different indents (`479 px`
vs `487 px` in `118`).

#### ST-36 -- The loading state is an unlabelled spinner with both buttons live

**nit / S** -- `lib/dialogs/settings_dialog.dart:722-730` --
`113-distro-settings-dialog.png`

Four-plus seconds of bare `ProgressRing` in an otherwise empty dialog, with no caption
saying what is being read (`wsl.conf`, over a distro that is being started for the purpose
-- ST-27) and no cancel. **Cancel** and **Save** are both enabled throughout.

### Templates

#### ST-37 -- A template smaller than ~5 MB is silently removed from the list

**major / S** -- `lib/screens/template_screen.dart:126-128`

```dart
if (size == '0 GB') {
  return const SizedBox();
}
```

`getTemplateSize` formats to two decimals in GB, so anything under about 5 MB rounds to
`0 GB` and its row becomes a zero-height box. The template still exists on disk, still
occupies space, and cannot be used, edited or deleted from the UI -- it is simply not
there. There is no message, and the empty-state branch does not fire either (the list is
non-empty), so a user whose only template is small sees a blank screen with no explanation.

#### ST-38 -- Deleting a template asks whether you want to destroy a distro

**major / S** -- `lib/screens/template_screen.dart:185-195`, `lib/i18n/en.json` --
`121-templates-delete-confirm.png`

Verbatim from `121`, over the template `test-4`:

> **Delete instance test-4 permanently?**
> If you delete this Distro you won't be able to recover it. Do you want to delete it?

Two wrong nouns in three lines. Deleting a template deletes an archive file; it does not
touch any WSL instance. A user who created the template *from* a distro of the same name
has every reason to read this as "your distro is about to be unregistered" and cancel.

The same two strings (`deleteinstancequestion-text`, `deleteinstancebody-text`) are reused
for distros, templates and snippets (ST-54) -- three different objects, one message.

#### ST-39 -- "Create a new instance" opens a dialog called "Copy", about "the WSL instance"

**major / S** -- `lib/screens/template_screen.dart:158-168` --
`122-templates-create-dialog.png`

Three verbs for one action: the button says **Create a new instance**, the dialog title
says **Copy 'test-4'**, the submit button says **Copy**. The body says "Copy the WSL
instance 'test-4' to a new instance with this name" -- but `test-4` is a template, not a
WSL instance, and it does not appear in `wsl --list`.

#### ST-40 -- The template delete button is an unlabelled icon 900 px from the two labelled ones

**nit / S** -- `lib/screens/template_screen.dart:182-202` --
`120-templates-expanded.png`

`Create a new instance` and `Edit Template` are labelled buttons at the left edge of the
expander; delete is a bare `IconButton` pushed to the far right by
`MainAxisAlignment.spaceBetween`, with no tooltip, no `MergeSemantics` and no destructive
colour. `actions_screen.dart:323-351` wraps the identical icon in exactly that pair -- so
the app already has the pattern, one file away.

#### ST-41 -- No title, no explanation, and no way to create a template from the template screen

**nit / S** -- `lib/screens/template_screen.dart:86-115` --
`119-templates-empty.png`

The screen opens straight onto a list with no heading and no sentence saying what a
template is (a saved distro image you can stamp new instances from) or where they come
from. The only way to create one is the save icon in a distro row's action bar, on a
different screen, which the empty state (`notemplates-text`) does not mention either.

#### ST-42 -- Sizes render as "0.01 GB"

**nit / S** -- `lib/api/templates.dart` (`getTemplateSize`) --
`119-templates-empty.png`

A ten-megabyte template is shown as `test-4 (0.01 GB)`. Fixed GB with two decimals is the
same choice that produces ST-37; the distro list on Home has the same issue at the other
end of the scale (LN-25).

#### ST-43 -- The new-instance name box looks pre-filled

**nit / S** -- `lib/dialogs/base_dialog.dart` (`dialog()`) --
`122-templates-create-dialog.png`

The box shows `test-4` in placeholder grey -- the template's own name. It is empty. Same
trap as CI-30, and here it is worse, because accepting the "suggested" name is exactly what
a user would expect to do.

### Mount

#### ST-44 -- The disk you are about to mount is identified by a truncated string

**major / S** -- `lib/dialogs/mount_dialog.dart:334-347` --
`123-mount-dialog-physical.png`

The combo reads `QEMU QEMU HARDDISK SCSI Disk Device (…`, ellipsised inside a 300 px box
in a 355 px dialog, with no tooltip and no second line. The truncated part is where the
device id lives, so on a machine with two similar disks there is nothing on screen to tell
them apart -- before an operation that takes a physical disk away from Windows.

#### ST-45 -- The primary button silently does nothing when a required field is empty

**major / S** -- `lib/dialogs/mount_dialog.dart:82-108` --
`124`, `125-mount-unmount-empty-noop.png`

Measured: with the Unmount tab selected and the path box empty, pressing **Unmount**
produced no error, no field highlight, no message and no change (`124` and `125` are
pixel-identical apart from the button's hover state). `_execute` opens with
`if (_unmountPathController.text.isEmpty) return;` -- inside a `try` that has already set
`_loading = true`, so the user gets a flash of a progress bar and nothing else.

The physical-disk (`_selectedDisk == null`) and VHD (`_vhdPathController.text.isEmpty`)
branches have the same guard. The button should be disabled, or it should say what is
missing.

#### ST-46 -- Nothing says a physical-disk mount needs elevation and takes the disk away from Windows

**major / S** -- `lib/dialogs/mount_dialog.dart:232-251` --
`123-mount-dialog-physical.png`

`wsl --mount \\.\PHYSICALDRIVE0` requires an elevated process and detaches the disk from
Windows for the duration. The form says none of this. The one string that covers part of it
-- `diskofflinehint-text` -- is appended to the *error message* after the operation has
already failed with "process cannot access", and only if the failure text matches an
English substring. The `usbdetected` InfoBar is the only pre-flight warning and only fires
for USB devices.

#### ST-47 -- Three radio buttons used as a tab strip, with the title stuck on "Mount Disk"

**nit / S** -- `lib/dialogs/mount_dialog.dart:26`, `:266-287`, `:306-310` --
`123`, `124-mount-dialog-unmount.png`

The source comment calls them tabs (`int _selectedTab = 0; // 0: Physical, 1: VHD, 2: Unmount`);
`fluent_ui` has `TabView` and a segmented control for this. As radios they read as "pick
one of three kinds of thing", which is wrong for a group whose third member is the *inverse
operation*. The dialog title stays **Mount Disk** while the primary button says
**Unmount** (`124`).

#### ST-48 -- With nothing mounted, the unmount picker disappears instead of saying so

**nit / S** -- `lib/dialogs/mount_dialog.dart:512-538` --
`124-mount-dialog-unmount.png`

`if (_mountedDisks.isNotEmpty)` hides the whole "Select mounted disk" group, leaving a free
text box and the sentence "Enter the exact path used when mounting." The app knows the list
is empty; it could say "Nothing is currently mounted." Instead it asks the user to recall a
path from memory and gives no way to tell an empty list from a missing feature.

#### ST-49 -- The mount-options placeholder is cut off mid-sentence

**nit / S** -- `lib/i18n/en.json` (`mountoptionshint-text`) --
`123-mount-dialog-physical.png`

Rendered: `e.g. data=ordered (Generic options like ro/rw are` — the string is longer than
the box and there is no tooltip, so the advice ends mid-clause.

#### ST-50 -- The Partition / Filesystem Type labels sit at different heights

**nit / S** -- `lib/dialogs/mount_dialog.dart:374-399`, `:462-487` --
`123`, `126-mount-dialog-vhd.png`

"Filesystem Type (Optional)" wraps to two lines in the 165 px column while "Partition
(Optional)" stays on one. `crossAxisAlignment: CrossAxisAlignment.end` keeps the *boxes*
aligned -- which is the deliberate fix the code comments describe -- at the cost of a
ragged label row, with one label 18 px lower than its neighbour.

#### ST-51 -- The VHD browse button is a different glyph from every other file picker in the app

**nit / S** -- `lib/dialogs/mount_dialog.dart:428-429` --
`126-mount-dialog-vhd.png`

`FluentIcons.folder_open` here; `FluentIcons.open_folder_horizontal` for all seven pickers
on the settings screen. It is also a `Button` rather than a suffix `IconButton`, so it sits
outside the field instead of inside it, and it has no tooltip.

#### ST-52 -- The dialog never says which distro the disk lands in, or where

**nit / S** -- `lib/dialogs/mount_dialog.dart:315-411`

`wsl --mount` attaches to the WSL 2 VM and surfaces under `/mnt/wsl/<name>` for every
distro; the "Custom Name (Optional)" field is what sets `<name>`. None of that is on
screen. After a successful mount the user is told "Disk mounted" and left to find it.

### Snippets (actions screen)

#### ST-53 -- Save with an empty name silently does nothing

**major / S** -- `lib/screens/actions_screen.dart:234-236` --
`128`, `129-actions-save-empty-noop.png`

```dart
} else {
  // Error
}
```

Measured: pressing **Save** on an untouched editor left the screen exactly as it was, with
no message and no field highlight (`128` and `129` are identical). The comment marks the
spot where the error handling was meant to go. Same defect as ST-45 in the mount dialog, in
a different file.

#### ST-54 -- Deleting a snippet asks whether you want to destroy a distro

**major / S** -- `lib/screens/actions_screen.dart:330-342` --
`133b-actions-delete-confirm-zoom.png`

Verbatim, over a shell snippet:

> **Delete instance audit-demo permanently?**
> If you delete this Distro you won't be able to recover it. Do you want to delete it?

Third reuse of the same pair of strings, after distros and templates (ST-38). Deleting a
snippet removes two entries from `SharedPreferences`.

#### ST-55 -- Expanding a one-line snippet opens a 430 px panel that is 97% empty

**major / S** -- `lib/screens/actions_screen.dart:354-368` --
`132-actions-expanded.png`

`SizedBox(height: MediaQuery.of(context).size.height * 0.5)` -- the content pane is half the
window regardless of the script's length. `132` is a one-line snippet: 17 px of text and
413 px of nothing, and only one snippet can be on screen at a time as a result.

#### ST-56 -- One object, four names

**nit / S** -- `lib/i18n/en.json` (`settingname-text`), `lib/screens/actions_screen.dart:76`
-- `128-actions-editor.png`

The nav item says **Snippets**, the button says **Add a snippet**, the field placeholder
says **Name of setting**, and the code calls them quick actions throughout
(`quickSettingsTitles`, `QuickActionItem`, `addquickaction-text`). "Setting" is the worst of
the four: this screen is not settings, and the app has two other screens that are.

#### ST-57 -- "(by you)" is hardcoded English and "[v0.0.0]" is invented, both below AA contrast

**nit / S** -- `lib/screens/actions_screen.dart:270-303` --
`131-actions-list-populated.png`, `132-actions-expanded.png`

A snippet the user just wrote renders as `audit-demo [v0.0.0] (by you)`. The version is
fabricated (`quickActions[i].version.isNotEmpty ? … : '0.0.0'`) for something that has no
versioning, and `'you'` is a Dart string literal -- untranslated in all nine locales, unlike
every other user-facing word on the screen.

Sampled per pixel out of `132`:

| Span | Colour | Ratio on `#FCFCFC` |
|:---|:---|---:|
| `(by you)` | `#0078D4` (accent) | **4.41:1** |
| `[v0.0.0]` | `#7E7E7E` (text at 50% alpha) | **3.96:1** |

Both are 13 px body text, so both are under the 4.5:1 AA threshold. The accent colour also
makes "(by you)" look like a link to an author profile that does not exist.

#### ST-58 -- The code editor has no frame, no background and no label

**nit / S** -- `lib/screens/actions_screen.dart:415-457` --
`128-actions-editor.png`

The `CodeEditor` sits directly on the page background with no border, no fill and no
heading -- the only indication that it is an editable region is a `1` in the gutter and the
grey hint `# Your code here`. Its declared height is 68% of the window, so roughly 580 px of
the screen is a click target that does not look like one. The name box directly above it
*is* framed, which makes the editor read as decoration.

#### ST-59 -- The editor is pinned to a light syntax theme

**nit / S** -- `lib/screens/actions_screen.dart:451-455`

`theme: atomOneLightTheme`, unconditionally. In dark mode the highlighted tokens keep their
light-background colours. Flagged here rather than in [[theme-and-locales]] because the
cause is a literal in this file; the dark pass should confirm how bad it looks.

#### ST-60 -- Nothing says what a snippet is, and you cannot run one from the snippets screen

**nit / S** -- `lib/screens/actions_screen.dart:373-409` --
`127-actions-empty.png`, `132-actions-expanded.png`

The empty state says "Add a snippet and you will see it here." -- true, and the only thing
on screen. Nowhere does the app say that a snippet is a bash script executed **inside a
distro, as root**, which is the one fact a user needs before pasting one in from the
community list. The expanded view has an edit button and a delete button and no run button;
running is only reachable from a distro row's dropdown on Home (LN-07).

#### ST-61 -- Two "add" affordances in opposite corners, one of them mid-sentence capitalised

**nit / S** -- `lib/screens/actions_screen.dart:109-149`, `:192-254` --
`127-actions-empty.png`

**Add Community snippets** is centred at the top of the content area; **Add a snippet** is
pinned to the bottom-right. They do closely related things and share no visual grouping,
alignment or wording pattern -- and the first capitalises its middle word only.

### Cross-cutting

#### ST-62 -- "Cancel" is on the left in some dialogs and on the right in others

**major / S** -- `lib/dialogs/base_dialog.dart` vs the `ContentDialog`s in this pass --
`113`, `121`, `123`, `135`

Measured across four dialogs opened in this session:

| Dialog | Left button | Right button |
|:---|:---|:---|
| Per-distro settings (`113`) | Cancel | Save |
| Mount disk (`123`) | Cancel | **Mount** (filled) |
| Community snippets (`135`) | Cancel | Download |
| Template delete (`121`) | **Delete** (filled red) | Cancel |

Every dialog built directly as a `ContentDialog` puts Cancel first; every confirmation
built through `base_dialog.dart`'s `dialog()` helper puts the action first. So the button
in the left-hand slot is "the safe one" three times out of four and "permanently delete
this" the fourth time — and the fourth is the only one where getting it wrong costs
something. Related: CI-32 records the same class of inconsistency from the create flow.

## Verified passes

Recorded so the audit does not read as uniformly negative, and so a later change that
breaks one of these is visibly a regression.

* **The seven-group accordion works.** All seven Expanders are collapsed on entry
  (`81`), so the screen opens as a seven-line menu rather than the 1600-line wall the
  `.wslconfig` keys would otherwise make. Expanding one does not collapse the others, and
  scroll position survives expansion.
* **Conditional dependencies update live and correctly.** Selecting `networkingMode =
  mirrored` immediately disabled `DnsProxy` and `LocalhostForwarding` and enabled
  `IgnoredPorts`/`HostAddressLoopback`, from the *unsaved* edit (`95`, `97`) -- the
  dependency graph reads the pending value, not the file. Only the legibility of the
  explanation is at fault (ST-10).
* **Unset booleans render as their documented default, not as off.** Twelve keys checked
  against `kWslConfigBoolDefaults`; `GuiApplications`, `NestedVirtualization`, `DnsProxy`,
  `Firewall`, `DnsTunneling`, `AutoProxy` and `LocalhostForwarding` all correctly show
  `true (Default)` on a machine with an empty `.wslconfig` (`93`).
* **The narrow pass is clean.** At 900x860 the settings screen reflows without truncation,
  overflow or clipping (`111`); no label wraps badly and the footer buttons stay on one row.
* **The `.wslconfig` writer really is a diff.** After the ST-05 experiment the file
  contained exactly the four keys that had been touched, in one `[wsl2]` section, with no
  other key materialised -- the behaviour P05-02 was built for.
* **The enumeration keeps unknown values.** `networkingMode` retained `mirrored` across a
  close/re-open without the ComboBox asserting or rewriting it (`101`).
* **The language list is right.** Nine entries, each in its own script and native spelling,
  with the current one marked (`109`) -- no raw locale codes, no duplicate `zh`.
* **`MergeSemantics` is used where it should be.** `actions_screen.dart:307` and `:323`
  wrap the edit and delete icon buttons in `MergeSemantics(Tooltip(IconButton))`, which is
  the pattern AGENTS.md prescribes. It is the only place in this pass that does it -- which
  is what makes ST-18 and ST-40 findings rather than a global convention.

## Not examined

* **The Cloudflare tunnel path** (`mcp-tunnel-toggle-text`, `_tunnelStarting`,
  `_tunnelError`, the public URL row). Enabling it downloads `cloudflared` and publishes
  this machine's MCP server -- which can run arbitrary commands in every distro -- to a
  public URL. Deliberately not triggered. ST-22 is read from source and labelled as such.
* **A real mount.** No spare physical disk or `.vhdx` here, and `wsl --mount` of a disk
  Windows is using is not something to try on the machine the audit runs on. The forms,
  the empty-unmount state and the empty-field guard were exercised (ST-44..ST-52); no disk
  was attached.
* **The mount error dialogs** (`unmountfailed-msg`, `mountfailed-msg`, the "detach" and
  "select file" recovery paths, `mount_dialog.dart:110-251`). Reaching them needs a real
  failed mount.
* **Sync over the network** (`Sync().startServer()`, `download()`). Needs a second machine;
  ST-23, ST-30 and ST-31 are about the controls, not the transport.
* **`Move`** (`settings_dialog.dart:256-304`). The confirmation copy and the
  native-vs-legacy warning were read from source; the operation itself unregisters and
  re-imports a distro on WSL below 2.5 and was not run.
* **`Templates().useTemplate()`** -- the create-from-template dialog was opened and
  cancelled (`122`); no instance was created from a template.
* **The zero-template and many-template states.** One real template (`test-4`) exists here.
  ST-37 (the `0 GB` disappearance) is read from source; the `notemplates-text` empty state
  was not reached.
* **The community snippet list itself** (`qa_list.dart`). Walked in this pass only far
  enough to confirm the Snippets screen opens the same dialog as the create screen
  (`135`); its contents are audited in [[create-and-install]] as CI-32..CI-37 and are not
  re-filed here.
