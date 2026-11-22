---
type: analysis
title: '.wslconfig Coverage — documented keys vs. the app'
created: 2026-08-28
tags:
  - wsl
  - docs-audit
  - wslconfig
related:
  - '[[index]]'
  - '[[runtime]]'
  - '[[coverage-sweep]]'
  - '[[verification]]'
  - '[[wslconf-keys]]'
  - '[[cli-flags]]'
  - '[[features]]'
---

# `.wslconfig` — documented vs. app

Diff of the documented global-config surface against what
`lib/screens/settings_screen.dart` renders and what `lib/api/wsl.dart` reads and writes.

- **Documented side:** `microsoftdocs/wsl@8842def (2026-07-30)`, inventoried in
  `.maestro/playbooks/2026-08-28-WSL-Manager-Backlog-Audit/Working/wslconfig-keys.md`.
- **App side:** `lib/screens/settings_screen.dart:1010-1156` (the two Expanders),
  `lib/api/wsl.dart:544-646` (`setConfig` / `readConfig` / `editConfig` / `writeConfig`),
  `lib/components/helpers.dart:451` (`getWslConfigPath`).
- **Verdicts:** `covered` = key present and correctly presented · `outdated` = present
  but the wording or presentation reflects an older doc state · `wrong` = present but
  the app's behaviour contradicts the docs · `missing` = not present at all.

## Headline

**Key coverage is complete. Presentation and the read/write engine are not.**

All **27** keys in the `wsl-config.md` reference tables — 20 `[wsl2]` + 7
`[experimental]` — are rendered by the app. Verified by grepping both the camelCase and
the all-lowercase spelling for every key (`.wslconfig` matching is case-insensitive and
the docs' own example file uses lowercase); every one resolves to exactly one
`settingsWidget(...)` call site in `settings_screen.dart`. There is **no missing-key
finding in this area at all**.

What the diff does produce is:

- **9 keys with an untyped or mis-typed widget** — 2 enums as free text (`networkingMode`,
  `autoMemoryReclaim`), 2 size keys and 2 numeric keys with plain text boxes (`swap`,
  `defaultVhdSize`, `vmIdleTimeout`, `maxCrashDumpCount`), 2 path keys with no file picker
  (`kernel`, `swapFile`), and a `memory` slider that silently snaps to its minimum when the
  existing value is expressed in `MB`.
- **5 documented conditional dependencies** that no part of the UI honours (CC-6).
- **7 boolean toggles** that display the opposite of the documented default when the key is
  absent from the file (CC-1).
- **4 defects in the `.wslconfig` parser/writer** that can corrupt a hand-edited file
  (CC-2 … CC-5).
- **No way to remove a key once it is written** (CC-11) — which is also what blocks the
  tri-state fix CC-1 asks for.
- **A slider that throws on a documented-legal value** (CC-9) — added by the
  [[verification]] pass, and the most severe finding in this file.

## Per-key table — `[wsl2]`

| Key | Documented | App state | Verdict |
|:---|:---|:---|:---|
| `kernel` | path, escaped backslashes required (`wsl-config.md:248`) | `settings_screen.dart:1022` — plain `TextBox`, tooltip `absolutewindowspath-text` | **outdated** — no file picker (`kernelModules` has one), no escaping help |
| `kernelModules` | path to modules VHD | `:1026` — `TextBox` + `.vhdx` `FilePicker` | **wrong** — picker writes a raw single-backslash path; docs require `C:\\…` |
| `memory` | size, default 50% of host RAM | `:1042` — `Slider`, min 1, max host GB + 1, postfix `GB` | **wrong** — an existing `memory=8192MB` value fails `double.tryParse` after `replaceAll('GB','')` and silently snaps the slider to **1** |
| `processors` | number, default = host **logical** CPUs | `:1051` — `Slider`, min 1, max `SysInfo.cores.length` | **outdated** — the tooltip drops "logical", and the slider asserts on a value above the host core count (CC-9). Corrected from `covered` by [[verification]] |
| `localhostForwarding` | boolean, default `true`; **ignored when `networkingMode=mirrored`** (`wsl-config.md:305`) | `:1058` — `ToggleSwitch` | **outdated** — default-`true` shown as off when unset; the mirrored-mode override is not surfaced |
| `kernelCommandLine` | string, space-separated kernel args | `:1062` — `TextBox` | **wrong** — `readConfig` strips **all** spaces from values (`wsl.dart:623`), so `console=ttyS0 nokaslr` reloads as `console=ttyS0nokaslr` and is written back corrupted |
| `safeMode` | boolean, Win 11 + WSL 0.66.2+ | `:1066` — `ToggleSwitch` | **outdated** — `safemodeinfo-text` is truncated mid-sentence and drops the only WSL-version floor stated anywhere in the `[wsl2]` table. Corrected from `covered` by [[verification]] V-4 |
| `swap` | **size**, default 25% of RAM, `0` disables | `:1070` — plain `TextBox` | **outdated** — a size key with no size widget and no unit hint; tooltip does carry the `8GB`/`512MB` examples |
| `swapFile` | path, default `%Temp%\swap.vhdx` | `:1072` — plain `TextBox` | **outdated** — path key with no file picker |
| `guiApplications` | boolean, default `true`, **no Win 11 restriction in the table** | `:1074` — `ToggleSwitch`, tooltip says "Only available for Windows 11" | **wrong** — the ¹ footnote is on `debugConsole`/`nestedVirtualization`/`vmIdleTimeout`/`autoProxy`, never on this key. The tooltip asserts a restriction the docs contradict, so a Windows 10 user skips a key that works. Corrected from `outdated` by [[verification]] V-3 |
| `debugConsole` | boolean, default `false`, Win 11 ¹ | `:1078` — `ToggleSwitch` | **covered** (tooltip `consoleinfo-text` has a stray comma: "Only available ,for Windows 11") |
| `maxCrashDumpCount` | number, default `10` | `:1090` — `TextBox` | **outdated** — numeric key with no numeric input or validation |
| `nestedVirtualization` | boolean, default `true`, Win 11 ¹ | `:1082` — `ToggleSwitch` | **outdated** — default-`true` shown as off when unset |
| `vmIdleTimeout` | number (ms), default `60000`, Win 11 ¹ | `:1086` — `TextBox` | **outdated** — numeric key, no validation, no unit in the label |
| `dnsProxy` | boolean, default `true`, **only applies when `networkingMode = NAT`** | `:1094` — `ToggleSwitch`, tooltip `dnsproxyinfo-text` | **outdated** — the NAT-only condition is documented and absent from the tooltip |
| `networkingMode` | **enum** `none\|nat\|bridged\|mirrored\|virtioproxy`; `bridged` deprecated since WSL 2.4.5 | `:1098` — free-text `TextBox`, placeholder `nat`, tooltip lists all five values | **wrong** — an enum rendered as free text; any typo silently degrades to NAT, and the deprecation of `bridged` is not shown |
| `firewall` | boolean, default `true` (on by default from WSL 2.0.9+) | `:1102` — `ToggleSwitch` | **outdated** — default-`true` shown as off when unset |
| `dnsTunneling` | boolean, default `true`; gates `bestEffortDnsParsing` + `dnsTunnelingIpAddress` | `:1106` — `ToggleSwitch` | **outdated** — default-`true` shown as off; dependants not gated |
| `autoProxy` | boolean, default `true`, Win 11 ¹; gates `initialAutoProxyTimeout` | `:1110` — `ToggleSwitch` | **outdated** — same two problems |
| `defaultVhdSize` | **size**, default 1 TB | `:1114` — plain `TextBox` | **outdated** — size key with no size widget |

## Per-key table — `[experimental]`

| Key | Documented | App state | Verdict |
|:---|:---|:---|:---|
| `autoMemoryReclaim` | **enum** `disabled\|gradual\|dropCache`, default `dropCache` | `settings_screen.dart:1126` — free-text `TextBox`, tooltip lists the three values | **wrong** — enum as free text; an unknown value silently means `dropCache` |
| `sparseVhd` | bool, default `false` | `:1130` — `ToggleSwitch` | **covered** |
| `bestEffortDnsParsing` | bool, default `false`, **requires `dnsTunneling=true`** | `:1134` — `ToggleSwitch` | **outdated** — dependency not gated or stated |
| `dnsTunnelingIpAddress` | IPv4 string, default `10.255.255.254`, **requires `dnsTunneling=true`** | `:1138` — `TextBox`, no placeholder | **outdated** — no default shown, no IPv4 validation, dependency not gated |
| `initialAutoProxyTimeout` | ms string, default `1000`, **requires `autoProxy=true`** | `:1142` — `TextBox` | **outdated** — same three problems |
| `ignoredPorts` | CSV string, **requires `networkingMode=mirrored`** | `:1146` — `TextBox` | **outdated** — dependency not gated; no example (`3000,9000,9090`) |
| `hostAddressLoopback` | bool, default `false`, **requires `networkingMode=mirrored`** | `:1150` — `ToggleSwitch` | **outdated** — dependency not gated |

## Keys documented outside the reference table

| Key | Documented | App state | Verdict |
|:---|:---|:---|:---|
| `systemDistro` | `[wsl2]`, `intune.md:25/56` only — no reference-table row | absent (`grep -rni "systemdistro" lib/` → 0 hits) | **missing, no action** — enterprise/system-distro plumbing, not a settings-screen key |
| `kernelDebugPort` | `[wsl2]`, `intune.md:29/60` only | absent (0 hits) | **missing, no action** — kernel debugging, same reasoning |

## Non-`.wslconfig` controls rendered by the same screen

Added by [[coverage-sweep]]. `settingsWidget` is not used only for config keys: two
`SharedPreferences` settings share the `_settings` map that `readConfig()` populates, and
are kept out of the `.wslconfig` write loop by an exact string match on their names
(`settings_screen.dart:309-310`). They have no documented counterpart, so they carry no
verdict — they are listed here so that "every key this screen renders" is a complete
statement rather than a silence.

| Control | Backing store | App state | Verdict |
|:---|:---|:---|:---|
| `Default Distro Location` | `prefs['DistroPath']` | `settings_screen.dart:372` — `TextBox` + directory picker; the saved value is shown as the *placeholder*, never loaded into the controller | **n/a** — not a WSL config key |
| `General Data Location` | `prefs['DataPath']` | `:393` — same shape | **n/a** — not a WSL config key |

## Cross-cutting findings

These are not per-key gaps; they are properties of the editor and of the `.wslconfig`
read/write engine, and each one affects many keys at once.

### CC-1 — Boolean toggles display `false` for seven keys whose documented default is `true`

`settingsWidget`'s `SettingsType.bool` branch is
`checked: _settings[name]!.text == 'true'` (`settings_screen.dart:1208`). When a key is
absent from `.wslconfig` — the normal case — its controller text is empty, so the switch
renders **off** with an empty label. Affects `localhostForwarding`, `guiApplications`,
`nestedVirtualization`, `dnsProxy`, `firewall`, `dnsTunneling`, `autoProxy`; all seven
default to `true` per `wsl-config.md:225-246`. A user reading the screen concludes the
opposite of the truth for every one of them. Verdict **wrong**; the fix is a tri-state
(unset / on / off) or a "default: on" affordance, not a different initial `checked`.

### CC-2 — `readConfig` strips every space inside a value

`wsl.dart:623` (`value = value.replaceAll(' ', '')`) and the identical remote branch at
`:606`. Any `.wslconfig` value with an internal space is silently mangled on load, and
because `saveSettings` writes back every non-empty key
(`settings_screen.dart:271-286`), the mangled form is persisted the next time the user
presses Save. Concretely hits `kernelCommandLine`, and any `kernel` / `swapFile` path
under `C:\Program Files\…`. Verdict **wrong**.

### CC-3 — `readConfig` and `setConfig` are both section-blind

`readConfig` (`wsl.dart:596-630`) never tracks `[section]` headers — it flattens the whole
file into one `key → value` map. `setConfig` (`:544-592`) checks that `[$parent]` exists
and then runs `replaceAll(RegExp('$escapedKey[ ]*=(.*)'))` **across the entire file**, so a
key is rewritten wherever it appears, not inside the requested section. Three
consequences:

1. A key present under two sections collapses to one value on load.
2. Writing an `[experimental]` key rewrites a same-named key sitting under `[wsl2]`,
   leaving it in the wrong section.
3. `saveSettings` re-emits **every** key it loaded — including keys the app has no widget
   for — into `[wsl2]`, because `experimentalKeys` (`settings_screen.dart:271-279`) is a
   hardcoded list of the seven keys the app knows. A user's hand-added `[experimental]`
   key is relocated into `[wsl2]` on the next Save.

Verdict **wrong**. Contrast `getWSLConf` (`wsl.dart:1824`), which *does* track sections
correctly for `wsl.conf` — the correct parser already exists in the codebase.

> **Escalated by [[runtime]] R-4.** Measured against WSL 2.6.3.0: all seven
> `[experimental]` keys are **rejected** under `[wsl2]` (`wsl: Unbekannter Schlüssel
> „wsl2.autoMemoryReclaim“…`), and `memory` is rejected under `[experimental]`. `wsl.exe`
> still exits `0` and boots with the key **unset**. So consequence 3 above is not a tidiness
> problem: relocating a user's `[experimental]` key into `[wsl2]` silently **turns the
> setting off**, and the only notice is a stderr line the app never reads. Read CC-3 as
> data-affecting.

### CC-4 — Key matching is case-sensitive; `.wslconfig` is not

`setConfig`'s regex is built from the camelCase spelling with no `caseSensitive: false`.
The docs' own example file (`wsl-config.md:280-320`) writes `swapfile=` and
`localhostforwarding=` all-lowercase. Against such a file the app does not find the key,
falls into the "add key value" branch, and **appends a duplicate** under `[wsl2]`.
Verdict **wrong**.

[[verification]] V-5 traced the full path, and the user-visible symptom is worse than
"the setting was ignored":

1. `.wslconfig` contains `swapfile = C:\Temp\swap.vhdx`.
2. `readData` (`settings_screen.dart:78-81`) creates `_settings['swapfile']` — a controller
   with **no widget**, because the widget registers under `swapFile`. The `swapFile` box
   renders **empty**: the screen shows no swap file configured.
3. The user fills that empty box → `_settings['swapFile']`.
4. `saveSettings` iterates both. The lowercase entry rewrites the existing line; the
   camelCase entry matches nothing and takes the add branch.
5. `[wsl2]` now carries **both** `swapfile =` and `swapFile =`.

CC-2 compounds step 2: the value is space-stripped before the user ever sees it, so a path
under `C:\Program Files\…` is already corrupt in the controller.

> **Escalated by [[runtime]] R-8.** WSL 2.6.3.0 detects the duplicate
> (`wsl: Doppelter Konfigurationsschlüssel 'wsl2.SWAPFILE' … widersprüchlicher Schlüssel:
> 'wsl2.swapfile'`) and resolves it to the **first** occurrence — measured with two
> `memory` lines, where the earlier one won. The line the app appends is therefore the
> loser. The user's edit does nothing, on this boot or any later one, and the box keeps
> rendering empty. Not a messy file: a silent no-op edit.

### CC-5 — Comment lines are parsed as keys

`readConfig` accepts any line containing `=`. A commented-out `# memory = 8GB` yields the
key `#memory`, which then round-trips through `saveSettings` → `setConfig`. Verdict
**wrong** (low impact, same fix as CC-3).

[[coverage-sweep]] S-3 adds the **write** side, which is the worse half. Both regexes in
`setConfig` are built as `RegExp('$escapedKey[ ]*=')` with `multiLine: true` and **no line
anchor**, so they match anywhere on a line — including inside a comment. Against a file
containing `#memory=8GB`, writing `memory` finds that "existing key" and substitutes
*inside the comment*: the line stays commented out, WSL still ignores it, and the app
reports the save as done. A user who commented a key out to get the default back and then
set it again from the screen gets a silent no-op with nothing to see. The fix has to anchor
to line start, after stripping `#` lines.

[[runtime]] R-7 establishes what the fix has to accept: WSL 2.6.3.0 treats `#` as the
comment character (`# a hash comment` and `# memory=1GB` both parse clean) and rejects
`;` outright (`wsl: Ungültiger Schlüsselname`). `.wslconfig` is INI-*like*, not INI — strip
`#` lines only, and do not "helpfully" add `;` support.

### CC-6 — Documented dependency graph is not honoured anywhere

Five "Only applicable when…" conditions are stated in `wsl-config.md`:

```
dnsTunneling=true       ──> bestEffortDnsParsing, dnsTunnelingIpAddress
autoProxy=true          ──> initialAutoProxyTimeout
networkingMode=mirrored ──> ignoredPorts, hostAddressLoopback
networkingMode=NAT      ──> dnsProxy
networkingMode=mirrored ──> localhostForwarding is IGNORED
```

No widget in `_buildGlobalConfigSettings` / `_buildExperimentalSettings` is disabled,
greyed, or annotated based on another key's value. Verdict **missing** (behaviour, not a
key).

### CC-7 — The "restart WSL" requirement is stated once, in a note the user must scroll past

`globalconfigurationinfo-text` (`en.json:117`) does carry the `wsl --shutdown` sentence,
and there is a **Stop WSL** button (`settings_screen.dart:168-185`, `stopwsl-text`) that
calls `WSLApi().restart()` — which runs `wsl --shutdown` twice (`wsl.dart:1169-1170`).
There is also an **Edit .wslconfig directly** button (`:152-163`). So the app is
**covered** here — better
than most. Two blemishes: the English string contains a stray comma
("Build 19041 and ,later"), and pressing **Save** does not offer to restart even though
*no* `.wslconfig` key takes effect without one. See [[features]].

[[runtime]] R-11 measured it: with the VM running, a rewritten `.wslconfig` had **no**
effect on the next `wsl` invocation and produced **no** warning; only `wsl --shutdown`
applied it. The app's string is a faithful paraphrase of `wsl-config.md:213`, hedge
included — but the hedge is the doc's, and it is wrong. Phase 05 should say "changes take
effect after WSL restarts", not "you may need to".

### CC-8 — Orphaned i18n key

`unusedmemoryinfo-text` (`en.json:125`) describes `pageReporting`, a key that no longer
exists in the docs and is not rendered by the app (0 Dart references). Dead string in all
nine locale files. Verdict **outdated**, trivial cleanup.

### CC-9 — The size/number slider throws on a documented-legal value

Added by [[verification]] V-1. `fluent_ui` 4.13.0's `Slider` asserts its range in the
**constructor** (`lib/src/controls/inputs/slider.dart:41`,
`assert(value >= min && value <= max)`), and `settings_screen.dart:1197` computes the value
straight from the file with no clamp:

```dart
double size = double.tryParse(_settings[name]!.text.replaceAll(sizePostfix, '')) ?? sizeMin.toDouble();
```

`wsl-config.md:252` states that `size` entries **default to bytes** and the unit is
omissible, so `memory=8589934592` is a valid way to write 8 GB. It parses cleanly to
`8589934592.0` and is handed to a slider whose `max` is `hostGB + 1`. The assert fires and
the whole Settings page throws on build. `processors=64` on a 16-thread host does the same
against `sizeMax: SysInfo.cores.length`, as does any `.wslconfig` authored on a larger
machine.

Asserts are stripped from release builds, so the shipped app instead draws the thumb off the
end of the track rather than crashing — the failure mode differs by build mode, which is how
this stays hidden. Distinct from the `memory=8192MB` case in the table above, where
`double.tryParse` *fails* and the slider silently snaps to `1`; both come from the same
unguarded parse. Verdict **wrong**, and the most severe defect in this editor: it is a crash
produced by a value the documentation instructs users to write.

[[runtime]] R-9 verifies the precondition against WSL 2.6.3.0 and sharpens both halves:
`memory=8589934592` is **accepted silently** (`MemTotal` 8 111 836 kB), so the app crashes on
a value WSL is entirely happy with; `processors=64` on this 10-thread host is **rejected by
WSL with a clear message and clamped**, so the app crashes on a value WSL survives by
warning. The app reads the file, never WSL's effective value, so the clamp does not save it.
R-10 confirms the `MB` half too: `memory=6144MB` really is honoured (`MemTotal` 6 067 928 kB)
— the 5 GB the slider throws away is 5 GB the user actually had.

One candidate report, from the classification pass ([[index]], *Evidence*):
[#300](https://github.com/bostrot/wslmanager/issues/300) — "点击设置闪退", the app
exits the moment Settings is clicked, on v1.10.0. No `.wslconfig`, no environment, no repro
was attached, so this is a **plausible** match for CC-9 and not a confirmed one. Sized as
P05-01, whose first step is the reproduction that would settle it.

### CC-10 — Path values are written with single backslashes, and WSL discards the line

Added by [[runtime]] R-6. `wsl-config.md:248` requires `path` values to use **escaped**
backslashes. That is enforced, not stylistic — measured on WSL 2.6.3.0:

| Written | Result |
|:---|:---|
| `swapFile=C:\Temp\wslswap.vhdx` | `wsl: Ungültiges Escapezeichen: „T“` — **line discarded**, key unset |
| `swapFile=C:\\Temp\\wslswap.vhdx` | parsed as `C:\Temp\wslswap.vhdx` |

The app escapes nothing anywhere (`grep` across `settings_screen.dart` and `wsl.dart`
returns no escaping), and `setConfig` (`wsl.dart:544-592`) writes controller text verbatim.
Three keys are affected, and the worst is the one with the nicest UI: `kernelModules`'
file picker (`settings_screen.dart:1025-1038`) assigns `result.files.single.path!` straight
into the controller, so **every value that picker can produce** is a line WSL throws away.
`kernel` (`:1021`) and `swapFile` (`:1072`) are free-text boxes whose tooltip asks for an
absolute Windows path, inviting the same input.

Compounds CC-2: a path under `C:\Program Files\…` is space-stripped *and* unescaped.
Verdict **wrong**. The fix is one escape on write and one unescape on read, in the same
place CC-2 and CC-4 are fixed.

### CC-11 — A key can be added and changed, but never removed

Added by [[coverage-sweep]] S-2. `saveSettings` writes a key only when its controller is
non-empty (`settings_screen.dart:311`), and `setConfig` (`wsl.dart:544-592`) has exactly
three branches — replace the value, insert the key under an existing section, append the
section — and no fourth. Clearing a text box therefore does nothing: the key stays in
`.wslconfig` at its previous value, and the screen redraws that value on the next open.

The whole documented default system is *"absent key = documented default"*
(`wsl-config.md:225-246`), so this is the app declining to express the most ordinary thing
a user wants from a settings screen — put it back the way it was. The only escape is the
**Edit .wslconfig directly** button, i.e. a text editor.

It also **blocks P05-04**. CC-1's prescribed fix is a tri-state toggle (unset / on / off),
and "unset" has nowhere to be written for as long as `setConfig` cannot remove a line.
Verdict **wrong**; the fix belongs with the engine rewrite (P05-02), not with the toggle
work that depends on it.

## What was not examined

- **CC-11 and CC-5's write half were not executed.** Both are read from the `setConfig`
  source and the `saveSettings` loop at the cited lines — the delete path is *absent*
  rather than broken, and the missing anchor is visible in the regex literal — but neither
  was reproduced against a real `.wslconfig`. P05-02's tests should cover both.
- **Runtime behaviour** was not examined *when this file was written*. It has since been
  measured — see [[runtime]], which supersedes this file wherever the two disagree, and
  whose *Corrections* table lists every finding here that it changed. The version floors
  quoted above are still the docs' annotations, not measurements; [[runtime]] Part 1 only
  establishes that this machine meets all of them.
- **The app was still never launched.** CC-9's crash is derived from `fluent_ui`'s
  constructor assert and the parse expression; [[runtime]] R-9 confirms WSL accepts the
  triggering value but did not open the Settings page.
- **The remote-WSL branches** of `setConfig`/`readConfig` (`wsl.dart:546-566`, `:597-614`)
  were read and carry the *same* CC-2/CC-3/CC-4 defects, but the SSH round-trip
  (`_readRemoteWslConfigText` / `_writeRemoteWslConfigText`) was not itself audited.
- **`writeConfig`** (`wsl.dart:534-541`) hard-codes a `[wsl2]` header and overwrites the
  whole file. It has no call site in `lib/` and was not analysed further.
- **Widget rendering** was read from source, not observed running. Slider bounds,
  toggle labels and the `memory` parse failure are inferred from the code path, not from
  a screenshot.
