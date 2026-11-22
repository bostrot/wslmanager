---
type: analysis
title: 'Coverage sweep — false negatives in the WSL docs audit'
created: 2026-08-28
tags:
  - wsl
  - docs-audit
  - coverage
related:
  - '[[index]]'
  - '[[wslconfig-keys]]'
  - '[[wslconf-keys]]'
  - '[[cli-flags]]'
  - '[[features]]'
  - '[[verification]]'
  - '[[runtime]]'
---

# Coverage sweep — what the audit missed

[[verification]] re-checked the claims the audit **made**. This file checks the claims it
**did not make**: the two settings editors and `lib/api/wsl.dart` were re-read end to end
and enumerated, and every rendered key and every `wsl.exe` invocation was matched against
an audit row. It is the audit's own false-negative pass, and it is the reason [[index]]'s
ordered list can be called closed.

Method: enumerate from the *source*, not from the audit. Every `settingsWidget(...)` call
site, every `settingSwitch` / `settingText` call site, every `TextEditingController` the
two editors persist, and every `_runWsl` / `_startWsl` / literal-`'wsl'` argument list in
`lib/api/wsl.dart` was listed first, then looked up in the audit tables.

- **App side:** `lib/screens/settings_screen.dart` (1253 lines), `lib/dialogs/settings_dialog.dart`
  (492 lines), `lib/api/wsl.dart` (1857 lines), read in full.
- **Documented side:** unchanged — `microsoftdocs/wsl@8842def (2026-07-30)`.

## Headline

**The key and flag inventories hold. Four things were missing, one of them material.**

Nothing in the audit was found to be wrong about a key that *is* documented. Every
`.wslconfig` key, every `wsl.conf` key and every `wsl.exe` flag the app touches already had
a row and a verdict. What the sweep added is at the edges of those tables — controls the
editors render that are *not* documented keys, and two engine behaviours that no per-key row
would ever surface:

| # | Found | Where it now lives |
|:---|:---|:---|
| S-1 | The distro dialog's **Start user** box shadows the missing `[user] default` — a lookalike control that does not do what a user will read it as | [[wslconf-keys]] *Per-distro launch preferences*, sharpens CC-6 → P05-05 |
| S-2 | **No `.wslconfig` key can ever be removed from the app** — `saveSettings` skips empty values and `setConfig` has no delete path, so P05-04's tri-state is unimplementable as scheduled | [[wslconfig-keys]] CC-11 → P05-02, blocks P05-04 |
| S-3 | `setConfig`'s regexes are **unanchored**, so a commented-out key absorbs the write and the edit is a silent no-op | [[wslconfig-keys]] CC-5, write-side half → P05-02 |
| S-4 | Two settings-screen controls (`Default Distro Location`, `General Data Location`) share the `.wslconfig` namespace and had no row at all | [[wslconfig-keys]] *Non-`.wslconfig` controls*, verdict `n/a` |

And one **false positive** was found and withdrawn, which is the same sweep run backwards:
the "prefs outlive the distro" mechanism [[index]] attached to #313 is **already fixed** in
this tree — `clearDistroPrefs` (`helpers.dart:388`) is called from `WSLApi.remove`
(`wsl.dart:951`) and wipes `StartUser_` / `StartPath_` / `StartCmd_` on unregister. P05-05
is smaller than [[index]] scheduled it.

## Sweep 1 — `settings_screen.dart`, every rendered key

27 `.wslconfig` keys, in file order, each resolved to a row in [[wslconfig-keys]]:

| Section | Keys rendered | Line range | In the audit? |
|:---|:---|:---|:---|
| `_buildGlobalConfigSettings` | `kernel`, `kernelModules`, `memory`, `processors`, `localhostForwarding`, `kernelCommandLine`, `safeMode`, `swap`, `swapFile`, `guiApplications`, `debugConsole`, `nestedVirtualization`, `vmIdleTimeout`, `maxCrashDumpCount`, `dnsProxy`, `networkingMode`, `firewall`, `dnsTunneling`, `autoProxy`, `defaultVhdSize` | `:1021-1116` | **20 / 20**, each with a verdict |
| `_buildExperimentalSettings` | `autoMemoryReclaim`, `sparseVhd`, `bestEffortDnsParsing`, `dnsTunnelingIpAddress`, `initialAutoProxyTimeout`, `ignoredPorts`, `hostAddressLoopback` | `:1125-1152` | **7 / 7**, each with a verdict |

Every per-key line reference in [[wslconfig-keys]]' two tables was re-checked against the
file and is correct. One reference was off by one and is fixed: the unguarded size parse is
`settings_screen.dart:1197`, not `:1196`.

**Not previously listed anywhere** — two further `settingsWidget` call sites, `:372` and
`:393`, which write into the *same* `_settings` map that `readConfig()` populates and are
excluded from the `.wslconfig` write loop by an exact string match on their names
(`:309-310`). They are `SharedPreferences` settings, not config keys, so they carry no
docs verdict — but a reader auditing "every key this screen renders" will find them, and
silence about them reads as an oversight. Now recorded in [[wslconfig-keys]] with verdict
`n/a`.

The screen's remaining controls are app preferences with no WSL-documented counterpart
(`Editor`, `Terminal`, `VSCodeCmd`, `UseRemoteWSL`, `RemoteWSLTarget`, `language`,
`showDocker`, `DockerMirror`, `DockerRepoLink`, `SyncIP`, `SyncPassword`, `RepoLink`, the
three BYOK fields, the MCP block). They are out of scope for a docs diff and are listed
here only so that "out of scope" is a decision on the record rather than an omission.

### What the enumeration itself turned up

Reading the screen end to end — rather than key by key — is what produced S-2 and S-3,
because both live in the loop *around* the widgets rather than in any widget:

**S-2, no delete path.** `saveSettings` (`:308-317`) iterates `_settings` and calls
`setConfig` only `if (value.text.isNotEmpty)`. `setConfig` (`wsl.dart:544-592`) has three
branches — replace, insert, create section — and no fourth. So clearing a text box in the
UI leaves the key in `.wslconfig` at its old value, and there is no path in the app that
removes a key at all. This is not cosmetic: the whole documented default system is
"absent key = default", so a user who wants a documented default back cannot get one
without the **Edit .wslconfig directly** button. It also blocks P05-04 — a tri-state
"unset / on / off" toggle has nowhere to write "unset". Recorded as [[wslconfig-keys]]
CC-11.

**S-3, unanchored regexes.** Both the existence test and the substitution in `setConfig`
are built as `RegExp('$escapedKey[ ]*=')` with no line anchor and `multiLine: true`. A
file containing `#memory=8GB` therefore matches for key `memory`, and the replacement
rewrites *inside the comment* — the line stays a comment, so the user's edit is a silent
no-op that the screen then displays as saved. [[wslconfig-keys]] CC-5 covered only the
read side of the comment problem (`readConfig` yielding the key `#memory`); the write side
is added there now.

## Sweep 2 — `settings_dialog.dart`, every rendered key

11 `wsl.conf` keys, in file order, each resolved to a row in [[wslconf-keys]]:

| Section | Keys rendered | Line | In the audit? |
|:---|:---|:---|:---|
| `[boot]` | `systemd`, `command` | `:301-302` | ✔ both |
| `[automount]` | `enabled`, `mountFsTab`, `root`, `options` | `:312-315` | ✔ all four |
| `[network]` | `generateHosts`, `generateResolvConf`, `hostname` | `:325-327` | ✔ all three |
| `[interop]` | `enabled`, `appendWindowsPath` | `:337-338` | ✔ both |

**11 / 11 with a verdict**, and every line reference in [[wslconf-keys]]' table is exact.
The four documented keys the dialog does *not* render (`[user] default`,
`[boot] protectBinfmt`, `[gpu] enabled`, `[time] useWindowsTimezone`) were re-grepped and
are still absent. The audit's count is right.

> The playbook brief's orientation paragraph lists only five `wsl.conf` keys for this
> dialog (`boot.systemd` and the four `automount` keys). That was stale — `[network]` and
> `[interop]` are both there. [[wslconf-keys]] enumerated from the source rather than from
> the brief and got 11, which this sweep confirms.

**Not previously listed anywhere** — the dialog also renders three per-distro *launch*
preferences above the `wsl.conf` expanders (`:112-140`): start command, start directory,
start user. Now recorded in [[wslconf-keys]] with verdicts, because one of them is S-1.

## Sweep 3 — `wsl.dart`, every `wsl.exe` invocation

**27 invocation sites**, covering 15 distinct flags and verbs. Every one resolves to a row
in [[cli-flags]]. No flag reaches `wsl.exe` from this file that the audit does not list.

| Site | Invocation | [[cli-flags]] row |
|:---|:---|:---|
| `:363` | `--install` | `--install` (WSL itself) |
| `:390-417` | `-d`, `--cd`, `--user`, split `startCmd`, `;/bin/sh` | `--distribution`, `--cd`, `--user` |
| `:450` | `--terminate <distro>` | `--terminate` |
| `:459-460` | `-d <distro> <editor> .bashrc` | `--distribution` |
| `:474` | `--shutdown` | `--shutdown` |
| `:482-483` | `wslShellArgs(…, shell: 'sh')` → `-d … --exec sh -c …` | `--exec` |
| `:512-513` | `-d <distro> <codeCmd>` | `--distribution` |
| `:767-768` | `-d <distro> --cd ~` | `--cd`, `~` (positional) |
| `:904` | `--export <distro> <location>` | `--export` |
| `:924` | `--unregister <distro>` | `--unregister` |
| `:971` | `--install -d <distro>` | `--install -d` — **wrong**, dead code (CC-5) |
| `:994`, `:1051`, `:1118` | `-d <distro> -u <user>` — the three stdin-driven shells (`execCmds`, `runCmds`, `startShell`) | `--user` |
| `:1023-1027`, `:1070-1076` | `wslExecArgs(…)` | `--exec` |
| `:1101-1102`, `:1158-1159` | `wslShellArgs(…)` | `--exec` |
| `:1136-1139` | `-d <distro> <passwd cmd>` | `--distribution` |
| `:1169-1170` | `--shutdown` ×2 | `--shutdown` |
| `:1199-1204` | `--import [--vhd]` | `--import`, `--import --vhd` |
| `:1283` | `--import [--vhd]` | `--import`, `--import --vhd` |
| `:1294` | `--list --quiet` | `--list --quiet` |
| `:1564` | `--list --running --quiet` | `--list --running --quiet` |
| `:1848` | `wslExecArgs(…, ['whoami'])` | `--exec` |

`move()` (`:1649-1790`) issues no `wsl.exe` call of its own — it composes `export()`,
`remove()` and `import()`, which is exactly what makes it the destructive sequence
[[cli-flags]] CC-2 and #280 describe.

Two line references in [[cli-flags]] were stale and are corrected: `--user` in `execCmds`
is `:994`, not `:1017`, and the sibling spawns in `runCmds` (`:1051`) and `startShell`
(`:1118`) were uncited. Both are citation fixes, not verdict changes.

Outside this file, `mount_service.dart`'s `--mount` / `--unmount` line references
(`:248-264`, `:268-283`, `:313-336`, `:350`) and `ai_workspace/service.dart`'s
`--list --quiet` (`:581`) and `--install … --name` (`:596-597`) were spot-checked and are
all exact. One uncited invocation there — `service.dart:538-539`, a
`-d <distro> -u root sleep infinity` keepalive — uses no flag the audit does not already
cover.

## Sweep 4 — the reverse direction, one false positive

A false-negative sweep that only ever adds findings is not a sweep. [[index]]'s
classification pass attached a mechanism to
[#313](https://github.com/bostrot/wslmanager/issues/313) — "the prefs outlive the
distro, so a recreated distro of the same name inherits a deleted user" — and made it part
of P05-05's scope. That mechanism is **already fixed** in this tree:

```
helpers.dart:369  distroPrefKeyPrefixes  = [Path_, StartPath_, StartUser_, StartCmd_, …]
helpers.dart:388  clearDistroPrefs(name) = remove every '<prefix><name>'
wsl.dart:951      await clearDistroPrefs(distribution)   // in WSLApi.remove, after --unregister
```

The `wsl.conf` prefs (`'<distro>-<section>-<key>'`) are not in that prefix list, but
`loadDistroSettings` clears its 12 `knownKeys` on every dialog open
(`settings_dialog.dart:399-418`), so they cannot render stale either. **P05-05 is the
missing `[user] default` editor and nothing more** — the lifecycle half is done. [[index]]
now says so.

## What was not examined

- **The app was still never launched.** This sweep is a third source read, not a run. The
  same limit [[wslconfig-keys]] and [[verification]] state applies here, and CC-9's crash
  reproduction is still the first step of P05-01.
- **Only the two editors and `wsl.dart` were swept end to end.** `create_dialog.dart`,
  `list_item.dart`, `docker_images.dart` and `copy_dialog.dart` also read and write the
  per-distro prefs enumerated above; they were grepped for the specific keys, not read in
  full, so a fourth surface that writes `wsl.conf` or `.wslconfig` outside `WSLApi` would
  not have been caught. `grep -rn "setConfig\|setSetting" lib/` returns only the call sites
  already cited, which is evidence but not proof.
- **The remote-WSL branches** were read for S-2 and S-3 (they carry both defects
  identically, at `wsl.dart:546-566` and `:597-614`) but no remote round-trip was
  exercised — unchanged from [[wslconfig-keys]]' own limit.
- **No new documented surface was inventoried.** This sweep re-checks the app side against
  the existing inventories; it does not re-read `microsoftdocs/wsl@8842def` for keys the
  first pass may have missed. A missed *documented* key would still be invisible to the
  audit, and the only cheap defence is [[runtime]]'s unknown-key probe.
- **S-2 and S-3 were not executed.** Both are read from the `setConfig` source and the
  `saveSettings` loop at the cited lines. They are strong — the delete path is absent
  rather than broken, and the missing anchor is visible in the regex literal — but neither
  was reproduced against a real `.wslconfig`. P05-02's tests should cover both.
