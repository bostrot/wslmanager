---
type: analysis
title: 'Audit Verification — every claimed gap re-checked against the code'
created: 2026-08-28
tags:
  - wsl
  - docs-audit
  - verification
related:
  - '[[index]]'
  - '[[runtime]]'
  - '[[coverage-sweep]]'
  - '[[wslconfig-keys]]'
  - '[[wslconf-keys]]'
  - '[[cli-flags]]'
  - '[[features]]'
---

# Verification pass

The four area files ([[wslconfig-keys]], [[wslconf-keys]], [[cli-flags]], [[features]])
were written by reading the documented side and the app side once each. This file is the
independent second pass over their claims: every key called **missing** was re-grepped,
every exposed key's **widget type** was checked against the value type the docs give it,
and every tooltip was diffed **string against string** with the doc sentence it paraphrases.

Documented side is still `microsoftdocs/wsl@8842def (2026-07-30)`. App side is the working
tree on branch `beta` at the time of writing.

**Outcome:** 3 verdicts corrected, 8 new findings, 0 claims withdrawn. No claimed gap turned
out to be a false positive — but three keys the area files passed as `covered` do not
survive a literal tooltip diff, and one widget-type check surfaced a crash that no
key-level reading would have found.

## Method

| Check | How |
|:---|:---|
| Missing keys | `grep -rn "<key>" lib/` and a case-insensitive `grep -rni "\b<lowercase>\b" lib/` for all 29 `.wslconfig` keys, all 15 `wsl.conf` keys, and the claimed-missing `wsl.exe` verbs |
| Present exactly once | count of `settingsWidget(... title: '<key>' ...)` call sites per key — a key rendered twice would round-trip through `saveSettings` twice |
| Widget type | `settingsWidget`'s `switch (type)` (`settings_screen.dart:1194-1244`) read against each key's documented **Value** column (`path` / `size` / `number` / `boolean` / `string`-enum) |
| Tooltip | each `*info-text` string in `lib/i18n/en.json` compared literally with the Notes cell for that key in `wsl-config.md:225-246` (`[wsl2]`) and `:257-266` (`[experimental]`) |

Nothing was executed. Runtime verification is the next Phase 04 task.

---

## Part 1 — Missing keys re-verified

### `.wslconfig` — the "27 of 27" claim holds

All 27 reference-table keys resolve to **exactly one** `settingsWidget(...)` call site, under
both the camelCase and the all-lowercase spelling. The two `intune.md`-only keys are
genuinely absent.

| Claim in [[wslconfig-keys]] | Re-check | Result |
|:---|:---|:---|
| All 20 `[wsl2]` keys rendered | 20 × 1 call site (`settings_screen.dart:1022`–`:1114`) | **confirmed** |
| All 7 `[experimental]` keys rendered | 7 × 1 call site (`:1126`–`:1150`) | **confirmed** |
| `systemDistro` absent | `grep -rni systemdistro lib/` → 0 | **confirmed** |
| `kernelDebugPort` absent | `grep -rni kerneldebugport lib/` → 0 | **confirmed** |

No key is rendered twice, and no key is rendered under a spelling other than the one
`saveSettings` writes back.

### `wsl.conf` — the four gaps hold

| Key | Re-check | Result |
|:---|:---|:---|
| `[boot] protectBinfmt` | `grep -rni protectbinfmt lib/ assets/ test/` → 0 | **confirmed missing** |
| `[gpu] enabled` | no `[gpu]` section, no `"gpu"` setting literal anywhere | **confirmed missing** |
| `[time] useWindowsTimezone` | `grep -rni usewindowstimezone` → 0 | **confirmed missing** |
| `[user] default` | one write site, `create_dialog.dart:325`; listed in `loadDistroSettings`' `knownKeys` (`settings_dialog.dart:413`); **no** entry in `wslSettings` (`:288-343`) | **confirmed missing** — read into prefs, never rendered |

The eleven exposed keys were counted directly out of `wslSettings`: `boot.systemd`,
`boot.command`, `automount.{enabled,mountFsTab,root,options}`,
`network.{generateHosts,generateResolvConf,hostname}`, `interop.{enabled,appendWindowsPath}`.
Eleven. Matches.

### `wsl.exe` verbs — one grep needs a footnote

| Verb | Raw `grep -rn` hits in `lib/` | What they are | Claim |
|:---|---:|:---|:---|
| `--version` | **1** | `cloudflare_tunnel_service.dart:90` — `cloudflared --version`, not `wsl` | **confirmed missing** |
| `--format` | **2** | `docker_images.dart:744` and a `docker inspect --format` inside an AI-workspace script — neither is `wsl --export --format` | **confirmed missing** |
| `--shell-type` | **1** | a comment in `wsl_args.dart:54` | **confirmed missing** |
| `--status`, `--update`, `--manage`, `--resize`, `--set-sparse`, `--set-default`, `--set-version`, `--set-default-version`, `--import-in-place`, `--system`, `--from-file` | 0 each | — | **confirmed missing** |
| `wsl-distribution.conf` | 0 | — | **confirmed missing** (F-8) |

> Recorded because a future re-grep of `--version` or `--format` returns non-zero and looks
> like it refutes [[cli-flags]] CC-1/CC-3. It does not: the hits belong to `cloudflared` and
> `docker`.

---

## Part 2 — Widget types re-checked against the documented value type

`SettingsType` has exactly three members — `bool`, `text`, `size` (`settings_screen.dart:20`).
There is **no enum/combo type and no path type**, so a documented `string`-enum or `path` key
can only be rendered as free text today.

| Documented value type | Keys | Right widget | What the app renders | Verdict |
|:---|:---|:---|:---|:---|
| `boolean` (13 keys) | `localhostForwarding`, `safeMode`, `guiApplications`, `debugConsole`, `nestedVirtualization`, `dnsProxy`, `firewall`, `dnsTunneling`, `autoProxy`, `sparseVhd`, `bestEffortDnsParsing`, `hostAddressLoopback` (+`[boot] systemd` in the other editor) | toggle | `ToggleSwitch` (`:1206-1215`) | **right widget, wrong initial state** — `checked: text == 'true'`, so unset reads as off; see [[wslconfig-keys]] CC-1 |
| `path` (3 keys) | `kernel`, `swapFile`, `kernelModules` | text + file picker + backslash escaping | `kernelModules` has a `.vhdx` `FilePicker` (`:1029-1039`); `kernel` (`:1022`) and `swapFile` (`:1072`) have none | **2 missing pickers**; and the one picker that exists writes a single-backslash path where the docs require `C:\\…` (`wsl-config.md:250`) |
| `size` (3 keys) | `memory`, `swap`, `defaultVhdSize` | numeric + unit affordance | `memory` → `Slider` with `sizePostfix: 'GB'`; `swap` (`:1070`) and `defaultVhdSize` (`:1114`) → plain `TextBox` | **1 of 3** |
| `number` (3 keys) | `processors`, `maxCrashDumpCount`, `vmIdleTimeout` | numeric input | `processors` → `Slider` (min 1, max `SysInfo.cores.length`); `maxCrashDumpCount` (`:1090`) and `vmIdleTimeout` (`:1086`) → plain `TextBox`, no validation | **1 of 3** |
| `string`-enum (2 keys) | `networkingMode` (5 values), `autoMemoryReclaim` (3 values) | combo box | free-text `TextBox` (`:1098`, `:1126`) | **0 of 2** — confirmed |
| free `string` (5 keys) | `kernelCommandLine`, `dnsTunnelingIpAddress`, `initialAutoProxyTimeout`, `ignoredPorts`, `[network] hostname` | text | `TextBox` | **right** (`initialAutoProxyTimeout` is documented `string` but holds milliseconds) |

Two things this pass adds to the widget picture, both below as findings: the `size`/`number`
`Slider` branch is **unsafe for documented-legal values** (V-1), and the combo box the enum
keys need is **already used three times elsewhere in the app** (V-2).

---

## Part 3 — Tooltip diff, string against doc sentence

Every `.wslconfig` tooltip in `lib/i18n/en.json` against the Notes cell it paraphrases.
"Verbatim" means the app string is character-identical to the doc sentence.

### `[wsl2]`

| Key | i18n key | Diff against `wsl-config.md:225-246` | Verdict |
|:---|:---|:---|:---|
| `kernel` | `absolutewindowspath-text` | verbatim; omits the escaped-backslash rule stated at `:250` | **outdated** (incomplete) |
| `kernelModules` | `kernelmodulesinfo-text` | verbatim | **covered** |
| `memory` | `memoryinfo-text` | verbatim; omits default (50% of host RAM) and the unit rule at `:252` | **outdated** (incomplete) |
| `processors` | `processorinfo-text` | doc says "How many **logical** processors"; app drops *logical* | **outdated** |
| `localhostForwarding` | `wildcardinfo-text` | verbatim; omits "ignored when `networkingMode=mirrored`" (`:305`) | **outdated** (incomplete) |
| `kernelCommandLine` | `kernelcmdinfo-text` | verbatim | **covered** |
| `safeMode` | `safemodeinfo-text` | **truncated mid-sentence.** Doc: "…disables many features **and is intended to be used to recover distributions that are in bad states. Only available for Windows 11 and WSL version 0.66.2+.**" App stops at "many features." | **outdated** — was `covered`; see V-4 |
| `swap` | `swapinfo-text` | verbatim **plus** the app's own `(e.g. 8GB, 512MB)` unit examples — better than the doc | **covered** |
| `swapFile` | `vhdinfo-text` | verbatim; omits default `%Temp%\swap.vhdx` | **covered** |
| `guiApplications` | `guiinfo-text` | verbatim **plus an invented sentence**: "Only available for Windows 11." The doc puts **no** ¹ footnote on this key | **wrong** — was `outdated`; see V-3 |
| `debugConsole` | `consoleinfo-text` | verbatim + correct Win 11 claim (¹); contains the typo "Only available **,for** Windows 11" | **covered** (typo) |
| `maxCrashDumpCount` | `maxcrashdumpcountinfo-text` | accurate condensation; omits default `10` | **covered** |
| `nestedVirtualization` | `nestedvirtinfo-text` | verbatim + correct ¹; omits default `true` | **covered** |
| `vmIdleTimeout` | `vmidleinfo-text` | verbatim + correct ¹; omits default `60000` | **covered** |
| `dnsProxy` | `dnsproxyinfo-text` | drops **"Only applicable to `networkingMode = NAT`"** and drops what `false` does ("mirror DNS servers from Windows to Linux") | **outdated** |
| `networkingMode` | `networkingmodeinfo-text` | bare value list. Omits: default `NAT`, `bridged` **deprecated since 2.4.5**, unknown-value → NAT, VirtioProxy fallback since 2.3.25 | **outdated** |
| `firewall` | `firewallinfo-text` | fair condensation; omits Hyper-V-traffic rules and default `true` | **covered** |
| `dnsTunneling` | `dnstunnelinginfo-text` | verbatim — the doc's own sentence is this bare | **covered** |
| `autoProxy` | `autoproxyinfo-text` | verbatim | **covered** |
| `defaultVhdSize` | `defaultvhdsizeinfo-text` | reads as "size new VHDs are created at". The doc frames it as a **cap**: "Can be used to limit the maximum size that a distribution file system is allowed to take up." Default `1099511627776` (1 TB) not given | **outdated** |

### `[experimental]`

| Key | i18n key | Diff against `wsl-config.md:257-266` | Verdict |
|:---|:---|:---|:---|
| `autoMemoryReclaim` | `automemoryreclaiminfo-text` | bare value list; omits default `dropCache` and unknown-value → `dropCache` | **outdated** |
| `sparseVhd` | `sparsevhdinfo-text` | verbatim, keeps the crucial "newly created" qualifier | **covered** |
| `bestEffortDnsParsing` | `besteffortdnsparsinginfo-text` | omits **"Only applicable when `wsl2.dnsTunneling` is set to `true`"** | **outdated** |
| `dnsTunnelingIpAddress` | `dnstunnelingipaddressinfo-text` | omits the same precondition and the default `10.255.255.254` | **outdated** |
| `initialAutoProxyTimeout` | `initialautoproxytimeoutinfo-text` | omits the `autoProxy` precondition, the unit (ms), the default `1000`, and "the WSL instance must be restarted to use the retrieved proxy settings" | **outdated** |
| `ignoredPorts` | `ignoredportsinfo-text` | omits the `mirrored` precondition and the CSV format (`3000,9000,9090`) | **outdated** |
| `hostAddressLoopback` | `hostaddressloopbackinfo-text` | omits the `mirrored` precondition and "Only IPv4 addresses assigned to the host are supported" | **outdated** |

### Screen-level help text

`globalconfigurationinfo-text` (`en.json:117`) is a verbatim copy of the doc NOTE at
`wsl-config.md:213` carrying **two English defects**, one of them a copy error against the
source:

- "Build 19041 and **,later**" — stray comma, not in the doc.
- "for these changes to **take affect**" — the doc says **"take effect"**.

It also predates the TIP the docs now place directly beneath that NOTE (`:216`, pointing at
the WSL Settings app) — see V-8.

**Tally: 10 covered, 16 outdated, 1 wrong.** Only 8 of the 27 tooltips are verbatim-complete;
the dominant failure is silent truncation of the doc's conditional clauses, which is exactly
the "only applicable when…" information [[wslconfig-keys]] CC-6 says no widget enforces
either. The condition is absent from both the behaviour and the text.

### The other editor

`settings_dialog.dart`'s `settingSwitch` / `settingText` (`:346-397`) take no tooltip
parameter and call `.i18n()` nowhere. There is nothing to diff: **all 11 `wsl.conf` keys have
zero help text**. [[wslconf-keys]] CC-4 confirmed as written.

---

## New findings

### V-1 — A documented-legal `.wslconfig` value crashes the Settings screen

`fluent_ui`'s `Slider` asserts its own range in the **constructor**:

```dart
// fluent_ui-4.13.0/lib/src/controls/inputs/slider.dart:41
}) : assert(value >= min && value <= max),
```

`settings_screen.dart:1196` computes `value` from the file with no clamp:

```dart
double size = double.tryParse(_settings[name]!.text.replaceAll(sizePostfix, '')) ?? sizeMin.toDouble();
```

`wsl-config.md:252` — *"Entries with the `size` value default to B (bytes), and the unit is
omissible."* So `memory=8589934592` is a **valid** way to ask for 8 GB. The app parses it to
`8589934592.0` and hands it to a slider whose `max` is `hostGB + 1` (33 on a 32 GB machine).
The assert fires and the Settings page throws on build. `processors=64` on a 16-thread host
does the same via `sizeMax: SysInfo.cores.length`, as does any `.wslconfig` written on a
bigger machine and copied to a smaller one.

Asserts are compiled out of release builds, so the shipped app instead renders a thumb
positioned off the track (`_unlerp` > 1.0) — the two failure modes differ by build mode,
which is why this can hide.

This is distinct from the already-recorded `memory=8192MB` case: there `double.tryParse`
*fails* and the slider silently snaps to `1`. Both come from the same unguarded parse.
**Severity: highest single defect in the `.wslconfig` editor** — it is a crash, from a value
the documentation tells users to write. Fix is a clamp plus real unit parsing, not a
different widget.

### V-2 — The combo box the enum keys need already exists in this codebase

[[wslconfig-keys]] and F-1 both call for `networkingMode` and `autoMemoryReclaim` to become
combo boxes. `SettingsType` has no such member — but `ComboBox` is already used three times:
`create_dialog.dart:522` (`ComboBox<CreateSourceType>`), `mount_dialog.dart:334`
(`ComboBox<PhysicalDisk>`) and `:515` (`ComboBox<String>`). Adding
`SettingsType.enumeration` to `settings_screen.dart:20` reuses an established pattern rather
than introducing one. Recorded so the classification task sizes those two findings as **S**,
not **M**.

### V-3 — `guiApplications`' tooltip invents a Windows 11 restriction

`guiinfo-text` ends "Only available for Windows 11." `wsl-config.md:233` carries **no**
footnote on `guiApplications`; the ¹ marker sits on `debugConsole`, `nestedVirtualization`,
`vmIdleTimeout` and `autoProxy`. A Windows 10 user reading this concludes WSLg is
unavailable to them and does not enable a key that works. Reclassified `outdated` → **wrong**
in [[wslconfig-keys]]: the app states something the documentation contradicts, which is the
definition of that verdict in [[index]].

### V-4 — `safeMode`'s tooltip is truncated, dropping the only version floor in the `[wsl2]` table

`safemodeinfo-text` stops at "which disables many features." The doc sentence continues
"…and is intended to be used to recover distributions that are in bad states. **Only
available for Windows 11 and WSL version 0.66.2+.**" That trailing clause is the *only*
inline WSL-version floor in the whole `[wsl2]` reference table, and the app is the one place
that drops it. Reclassified `covered` → **outdated**. Pairs with [[cli-flags]] CC-1: the app
could not enforce the floor even if the tooltip stated it.

### V-5 — Case-sensitivity produces a duplicate-key file; exact reproduction

[[wslconfig-keys]] CC-4 claims the app appends a duplicate against a lowercase file. Traced
end to end, the mechanism is narrower and more surprising than "it does not find the key":

1. `.wslconfig` contains `swapfile = C:\Temp\swap.vhdx`.
2. `readData` (`settings_screen.dart:78-81`) creates `_settings['swapfile']` — a controller
   with **no widget**, because the widget is registered under `swapFile`. The `swapFile` box
   renders **empty**, so the screen shows no swap file configured.
3. The user types a path into that empty box → `_settings['swapFile']`.
4. `saveSettings` (`:308-317`) iterates both entries. `setConfig('wsl2','swapfile',…)` matches
   the existing line and rewrites it. `setConfig('wsl2','swapFile',…)`'s regex is
   case-sensitive (`wsl.dart:577`), finds nothing, and takes the **add** branch.
5. The file now carries **both** `swapfile =` and `swapFile =` under `[wsl2]`.

So the user-visible symptom is not "my setting was ignored" but "the screen showed my swap
file as unset, and now there are two of them." Same root cause, materially worse than
recorded. Compounded by CC-2: step 2 also strips the spaces out of
`C:\Program Files\…` before the user ever sees it.

### V-6 — `wsl.conf` text values are interpolated unescaped into a **root** shell script

`setSetting` (`wsl.dart:1807-1820`) templates `assets/scripts/settings.bash` by plain string
replacement — `replaceAll('VALUE', value)` — and `execCmds` runs the result with
`['-d', distribution, '-u', 'root']` (`wsl.dart:995`). The four free-text `wsl.conf` fields
(`boot.command`, `automount.root`, `automount.options`, `network.hostname`) therefore land
verbatim inside both a single-quoted `sed` expression and a double-quoted `echo -e`, in a
root shell, fed line by line over stdin.

[[wslconf-keys]] CC-2 already records the *benign* half of this — a `/` in the value breaks
the `sed` delimiter. The other half is that a `"` or `$(…)` in the `echo -e` branch is
arbitrary command execution as root inside the distro, from a settings text box, with output
suppressed (`showOutput: false`) and `setSetting` returning `true` regardless. Not remotely
triggerable — the operator types the value — but it means the Phase 05 rewrite of this writer
must escape, not merely re-delimit. Recorded in [[wslconf-keys]] as CC-7.

### V-7 — `wsl.conf` prefs keys inherit the file's spelling, not the widget's

`getWSLConf` (`wsl.dart:1824-1846`) keys its map on the section and key **as written in
`/etc/wsl.conf`**, and `loadDistroSettings` (`settings_dialog.dart:418-431`) writes prefs
under `'$item-$section-$key'`. The widgets read `'$item-automount-mountFsTab'`. A distro whose
`wsl.conf` says `mountfstab = true` (or `MountFsTab`) populates a pref no widget reads, and
the toggle renders off. Same shape as V-5 but on the other editor. Whether `wsl.conf` key
matching is itself case-insensitive is **not** stated anywhere in the docs clone, so this is
recorded as an unverified-precondition risk rather than a confirmed defect — the runtime task
can settle it with one scratch distro.

### V-8 — "WSL Settings" is already taken, by this app, for something else

F-5 records that Microsoft ships a first-party **WSL Settings** GUI and that the app never
mentions it. It does — under that exact name, for a different thing. `wslsettings-text` =
`"WSL Settings"` (`en.json:134`) is the header of the **per-distro `wsl.conf` editor**
(`settings_dialog.dart:291`). So the app has a screen called "WSL Settings" that edits
`/etc/wsl.conf`, while Windows now has a Start-menu app called "WSL Settings" that edits
`%UserProfile%\.wslconfig` — the file this app edits on a *different* screen. Any Phase 05
work on F-5 has to rename one of them first, which makes F-5 cheaper than "integrate with a
Microsoft app" implies and more urgent than "low priority" implies.

---

## Corrections applied to the sibling files

| File | Change |
|:---|:---|
| [[wslconfig-keys]] | `safeMode` `covered` → `outdated` (V-4) · `guiApplications` `outdated` → `wrong` (V-3) · `processors` `covered` → `outdated` (tooltip drops "logical") · CC-4 expanded with the V-5 reproduction · new **CC-9** for the V-1 slider crash |
| [[wslconf-keys]] | new **CC-7** for the V-6 root-shell interpolation · V-7 added to "what was not examined" as an open precondition |
| [[cli-flags]] | CC-1's "0 hits" restated as "1 hit, `cloudflared`" so the claim survives a re-grep |
| [[features]] | F-5 amended with the V-8 name collision |
| [[index]] | area table gains a verification column; status table updated |

No source file was modified. This is a research phase; [[index]]'s ordered implementation
list — produced by the classification task, not this one — remains the only input to Phase 05.

## What was not examined

- **Still nothing at runtime.** V-1's assert was established from the `fluent_ui` 4.13.0
  source and the parse expression, not by loading a `.wslconfig` with a byte-valued `memory`
  and opening the screen. It should be the first thing the runtime task tries — it is a
  one-line file edit and an app launch.
- **Only `en.json` was diffed.** The other eight locales were not compared against the
  English strings, so a translation may carry a *different* error from the one recorded here.
  The i18n task at the end of Phase 04 should re-check the three corrected strings
  (`guiinfo-text`, `safemodeinfo-text`, `processorinfo-text`) in all nine files.
- **The `wsl.conf` writer's `[[ =~ ]]` behaviour under a non-bash default shell** — CC-1's
  collision is derived from the script text, not observed. Unchanged from the previous pass.
- **`--mount` option coverage, the remote/SSH branches, and the AI-workspace call sites** were
  not re-verified; [[cli-flags]]' claims about them stand on the first pass alone.
- **No GitHub issue or user report was consulted** *by this pass*. Severity language here
  ("highest single defect") is this pass's judgement from the code. The classification task
  has since done the mapping — [[index]], *Evidence — findings mapped to reported issues* —
  and it supports V-1: [#300](https://github.com/bostrot/wslmanager/issues/300)
  reports the app exiting the moment Settings is clicked, with no repro attached. That is a
  *plausible* match for V-1, not a confirmed one.
