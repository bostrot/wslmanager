---
type: analysis
title: 'wsl.conf Coverage — documented keys vs. the app'
created: 2026-08-28
tags:
  - wsl
  - docs-audit
  - wslconf
related:
  - '[[index]]'
  - '[[runtime]]'
  - '[[coverage-sweep]]'
  - '[[verification]]'
  - '[[wslconfig-keys]]'
  - '[[cli-flags]]'
  - '[[features]]'
---

# `wsl.conf` — documented vs. app

Diff of the documented per-distro config surface against the distro settings dialog.

- **Documented side:** `microsoftdocs/wsl@8842def (2026-07-30)`, inventoried in
  `.maestro/playbooks/2026-08-28-WSL-Manager-Backlog-Audit/Working/wslconf-keys.md`.
- **App side:** `lib/dialogs/settings_dialog.dart:288-344` (`wslSettings` — four
  Expanders), `:346-397` (`settingSwitch` / `settingText`), `:399-433`
  (`loadDistroSettings`); `lib/api/wsl.dart:1807-1846` (`setSetting` / `getWSLConf`);
  `assets/scripts/settings.bash` (the in-distro writer);
  `lib/dialogs/create_dialog.dart:325` (the one place `[user] default` is written).

## Headline

**11 of the 15 documented keys are exposed; 4 are missing.** The four gaps are
`[user] default`, `[boot] protectBinfmt`, `[gpu] enabled` and `[time] useWindowsTimezone`
— and `[user] default` is the notable one, because the app *writes* it at distro creation
but gives no way to see or change it afterwards.

The larger problem in this area is not coverage but the writer. `assets/scripts/settings.bash`
is section-blind and `sed`-based, which makes two of the exposed keys actively unsafe to
use: toggling `[interop] enabled` also rewrites `[automount] enabled`, and any value
containing `/` — including `automount.root`'s documented default `/mnt/` — produces a
broken `sed` expression.

## Per-key table

| Section | Key | Documented | App state | Verdict |
|:---|:---|:---|:---|:---|
| `[automount]` | `enabled` | boolean, default `true` | `settings_dialog.dart:312` — `ToggleSwitch` | **wrong** — collides with `[interop] enabled` in the writer (CC-1); default-`true` shown as off (CC-3) |
| `[automount]` | `mountFsTab` | boolean, default `true` | `:313` — `ToggleSwitch` | **outdated** — default-`true` shown as off (CC-3) |
| `[automount]` | `root` | Linux path, default `/mnt/` | `:314` — `TextBox` | **wrong** — every plausible value contains `/`, which breaks the writer's `sed` (CC-2) |
| `[automount]` | `options` | comma-separated DrvFs option string | `:315` — `TextBox` | **outdated** — raw string field for a 7-token composite (`uid`, `gid`, `umask`, `fmask`, `dmask`, `metadata`, `case`); no help text, no note that the masks are inert without `metadata` (`wsl-config.md:88`) |
| `[network]` | `generateHosts` | boolean, default `true` | `:325` — `ToggleSwitch` | **outdated** — CC-3 |
| `[network]` | `generateResolvConf` | boolean, default `true` | `:326` — `ToggleSwitch` | **outdated** — CC-3 |
| `[network]` | `hostname` | string, default = Windows hostname | `:327` — `TextBox` | **covered** |
| `[interop]` | `enabled` | boolean, default `true`, Win 10 1809+ | `:337` — `ToggleSwitch` | **wrong** — collides with `[automount] enabled` (CC-1); CC-3 |
| `[interop]` | `appendWindowsPath` | boolean, default `true`, Win 10 1809+ | `:338` — `ToggleSwitch` | **outdated** — CC-3 |
| `[user]` | `default` | string, floor build 18980. **The only documented way to change the default user of an imported distro** (`basic-commands.md:152`) | **no widget.** Written once at creation (`create_dialog.dart:325`), and listed in `loadDistroSettings`' `knownKeys` (`settings_dialog.dart:413`) so its value *is* read into prefs — and then never rendered | **missing** |
| `[boot]` | `systemd` | boolean, distro-dependent default, WSL 0.67.6+. Prose-only — no row in the `[boot]` reference table | `:301` — `ToggleSwitch` | **covered** — the app ships the key the docs' own table omits |
| `[boot]` | `command` | string, run as root at start | `:302` — `TextBox` | **wrong** — a realistic value (`/usr/sbin/service docker start`) contains `/` and breaks the writer (CC-2) |
| `[boot]` | `protectBinfmt` | boolean, default `true`, Win 11 / Server 2022 | absent (`grep -rn protectBinfmt lib/` → 0 hits) | **missing** — but see the note below before writing a tooltip |
| `[gpu]` | `enabled` | boolean, default `true` | absent (0 hits) | **missing** |
| `[time]` | `useWindowsTimezone` | boolean, default `true` | absent (0 hits) | **missing** |

### `[automount] options` sub-values

The docs treat these as tokens inside the single `options` string, not as keys. The app
matches that shape, so there is no per-key gap — only the missing guidance recorded above.

| Option | Documented default | App state | Verdict |
|:---|:---|:---|:---|
| `uid`, `gid` | distro default user/group (`1000`) | inside the free-text `options` box | **outdated** — no decomposed editor |
| `umask` (`022`), `fmask` (`000`), `dmask` (`000`) | OR'd, **inert without `metadata`** | same | **outdated** — the `metadata` precondition is documented and unstated |
| `metadata` | absent = disabled | same | **outdated** |
| `case` | `off` \| `dir` \| `force`; `force` is **WSL 1 only** and needs a registry key (`case-sensitivity.md:110`) | same | **outdated** |

> Upstream caveat for whoever writes the tooltip: `protectBinfmt`'s documented
> description ("Prevents WSL from generating systemd units when systemd is enabled") is
> **inverted** — it describes the `false` behaviour, not the `true` default. Do not
> paraphrase it. Recorded as an upstream defect in the working inventory.

## Per-distro launch preferences rendered by the same dialog

Added by [[coverage-sweep]] S-1. Above the four `wsl.conf` Expanders, the dialog renders
three `SharedPreferences` values (`settings_dialog.dart:112-140`, saved at `:69-71`). They
are not `wsl.conf` keys and have no documented counterpart, so they take no docs verdict —
but one of them is the reason CC-6 below is worse than "a missing widget".

| Control | Pref | What it actually does | Note |
|:---|:---|:---|:---|
| Start command | `StartCmd_<distro>` | appended to `wsl -d <distro> …` when the app launches a terminal (`list_item.dart:148` → `wsl.dart:395-406`) | **n/a** — and it is the one call site that deliberately keeps `wsl.exe`'s default-shell re-parse |
| Start directory | `StartPath_<distro>` | becomes `--cd <path>` on that same launch (`wsl.dart:390`) | **n/a** |
| Start user | `StartUser_<distro>` | becomes `--user <name>` on that same launch (`wsl.dart:393`) | **n/a** — but see below |

**Start user is a lookalike for `[user] default`, and it is labelled like one.** Its
tooltip is `wsldefaultuser-text` (`settings_dialog.dart:137`) — the app's *own* "default
user" string — it sits directly above the `wsl.conf` section it is not part of, and a user
hunting for the setting CC-6 says is missing will find this box first and stop looking.
What it does is narrower in three ways that the dialog never states:

1. It only applies to launches **from this app**. Typing `wsl` in a terminal, or any other
   WSL client, still lands as the distro's real default user — which is exactly the
   symptom reported in [#268](https://github.com/bostrot/wslmanager/issues/268).
2. It is per-machine `SharedPreferences`, so it does not travel with an exported distro.
3. It cannot be discovered by anything except this dialog; nothing writes it into the
   distro.

So CC-6's verdict is unchanged (`[user] default` is **missing**), but its user impact is
higher than a plain absence: the gap is *covered over* by a control that looks like the
answer. P05-05 should place the real `[user] default` editor next to this box and say what
each one does, not merely add a widget somewhere in the dialog.

## Cross-cutting findings

### CC-1 — The `wsl.conf` writer is section-blind, and two sections share the key name `enabled`

`assets/scripts/settings.bash` is templated by string replacement in
`WSLApi.setSetting` (`wsl.dart:1807-1820`): `PARENT`, `KEY` and `VALUE` are substituted,
then the script runs

```bash
test="KEY[ ]*="
if [[ $currentWSL == *"[PARENT]"* ]]; then
    if [[ $currentWSL =~ $test ]]; then
        sed -i 's/KEY[ ]*=[ ]*.*/KEY = VALUE/g' /etc/wsl.conf
```

Both the `[[ =~ ]]` existence test and the `sed` substitution search the **whole file**.
`[automount] enabled` and `[interop] enabled` are both exposed by the dialog
(`settings_dialog.dart:312` and `:337`) and both documented as `enabled`. In any
`wsl.conf` that has both sections, toggling either one rewrites **both** lines to the
same value. `g` on the `sed` guarantees it. Verdict **wrong**, high severity: it silently
changes a setting the user did not touch, and the dialog then shows the stale value until
reopened.

The correct parser is already in the codebase — `WSLApi.getWSLConf` (`wsl.dart:1824-1846`)
tracks `[section]` headers properly on the *read* path. Only the write path is broken.

**Reported twice.** [#185](https://github.com/bostrot/wslmanager/issues/185)
(closed): a hostname set from the app never reaches `/etc/wsl.conf`, and the reporter's own
workaround — `echo -e "[network]\nhostname=guitest" >> /etc/wsl.conf` — is this script's
third branch, the only one that is not `sed`.
[#309](https://github.com/bostrot/wslmanager/issues/309) (**open**): setting a
default user at creation lost `[boot] systemd=true`. That call site was since routed through
`setSetting` (`create_dialog.dart:324`, commit `4913741`, 2026-06-16) — the issue is still
open, and the section-blind writer beneath it is unchanged.

### CC-2 — `sed` delimiter collision on any value containing `/`

`VALUE` is substituted verbatim into `s/KEY[ ]*=[ ]*.*/KEY = VALUE/g`. A value with a
forward slash closes the substitution early:

```
automount.root = /mnt/   →   sed -i 's/root[ ]*=[ ]*.*/root = /mnt//g'   →  sed: unknown option to `s'
```

This hits `[automount] root` (whose documented default `/mnt/` is itself a failing value),
`[boot] command` (`/usr/sbin/service docker start`), and any `[automount] options` value
carrying a path. The "add key" branch has the same flaw
(`sed -i 's/\[PARENT\]/\[PARENT\]\nKEY = VALUE/g'`). Only the third branch — `echo -e … >>`
for a section that does not yet exist — is safe. Verdict **wrong**.

Note the failure is silent from the UI's perspective: `setSetting` returns `true`
unconditionally (`wsl.dart:1820`) and `execCmds` is called with `showOutput: false`, so a
`sed` error never reaches the user. The value is still written to `SharedPreferences`
(`settings_dialog.dart:388`), so the dialog shows the change as applied when it was not.

### CC-3 — Toggles default to `false` for six keys documented as `true`

`settingSwitch` reads `prefs.getBool('$item-$parent-$setting') ?? false`
(`settings_dialog.dart:353`). `loadDistroSettings` only populates prefs for keys that are
physically present in `/etc/wsl.conf` (`:421-431`) — and a fresh distro's `wsl.conf` is
usually absent or near-empty. So `automount.enabled`, `automount.mountFsTab`,
`network.generateHosts`, `network.generateResolvConf`, `interop.enabled` and
`interop.appendWindowsPath` all render **off** while their documented default is **on**,
and `boot.systemd` renders off for distros (current Ubuntu) that ship it on. Same defect
class as [[wslconfig-keys]] CC-1. Verdict **wrong**.

### CC-4 — No labels, no tooltips, no i18n in the whole dialog

`settingSwitch` / `settingText` render `setting.uppercaseFirst()` as the label —
`"MountFsTab"`, `"AppendWindowsPath"`, `"ProtectBinfmt"` — with **no** description and no
`.i18n()` call anywhere in either helper (`settings_dialog.dart:346-397`). Only the four
Expander headers are localised (`boot-text`, `automount-text`, `network-text`,
`interop-text`). Contrast the global `.wslconfig` screen, where every key carries a
localised tooltip. Verdict **missing**; it is the single largest i18n gap this audit
found, and it is what makes the section-blindness in CC-1 undiscoverable to a user.

### CC-5 — Every write is applied immediately, with no "restart required" signal

`settingSwitch.onChanged` and `settingText.onChanged` both call `WSLApi().setSetting(...)`
on every keystroke / toggle (`:358`, `:390`). Two problems. First, `settingText` fires one
full in-distro script execution **per character typed**. Second, no `wsl.conf` key takes
effect until the distro fully stops — the docs' "8 second rule" (`wsl-config.md:20-26`),
restated for `automount.options` (`case-sensitivity.md:112`) and for `boot.systemd`
(`wsl-config.md:57`). The dialog never says so and offers no `wsl --terminate` button,
unlike the global screen's **Stop WSL**. Verdict **missing**.

[[runtime]] R-12 measured it on `ai-workspace` using `network.hostname` — a key this dialog
writes (`settings_dialog.dart:327`). With the distro running the appended value had no
effect and produced no warning; `wsl --terminate ai-workspace` applied it. Two useful
refinements for Phase 05: a **per-distro `--terminate` is sufficient** (no global
`--shutdown`, so this fix is cheaper than the one the global screen needs), and the dialog
already knows which distro it is editing. `boot.systemd` — the dialog's most prominent
toggle — is the one key the docs name explicitly for this (`wsl-config.md:57`,
`systemd.md:46`).

### CC-6 — `[user] default` is written but not editable

`create_dialog.dart:325` calls `setSetting(name, 'user', 'default', user)` when a distro
is created with a user, and `loadDistroSettings` clears and reloads `user-default`
(`settings_dialog.dart:413`) — so the value is read into prefs on every dialog open and
then dropped on the floor, because `wslSettings` has no `[user]` Expander. For a manager
whose distros are created by `wsl --import`, this is the *only* documented mechanism that
works: `<distro> config --default-user` is documented as non-functional for imported
distros (`basic-commands.md:152`). Verdict **missing**, high user impact. See also
[[cli-flags]] on `wsl --manage --set-default-user`, and the **Start user** row in
*Per-distro launch preferences* above — [[coverage-sweep]] S-1 found that the dialog
already shows a box tooltipped `wsldefaultuser-text` that only sets `--user` on app-launched
terminals, which is what a user looking for this setting will find instead.

The classification pass found three reports of this one finding, which makes it the
best-evidenced gap in the audit after the move:
[#268](https://github.com/bostrot/wslmanager/issues/268) (**open**) — typing `wsl`
lands in root at `/mnt/c/Users/…` after creating a distro here;
[#313](https://github.com/bostrot/wslmanager/issues/313) (**open**) — a deleted
distro's user is still applied to a new distro of the same name, because the prefs outlive
it; [#192](https://github.com/bostrot/wslmanager/issues/192) — default user lost
after shrink/cleanup. Sized as P05-05 in [[index]].

### CC-7 — Free-text values reach a **root** shell unescaped

Added by [[verification]] V-6. `setSetting` (`wsl.dart:1807-1820`) templates
`assets/scripts/settings.bash` by plain string replacement — `replaceAll('VALUE', value)` —
and `execCmds` spawns the result with `['-d', distribution, '-u', 'root']` (`wsl.dart:995`),
feeding it line by line over stdin.

CC-2 above records the benign half: a `/` in the value breaks the `sed` delimiter. The other
half is that the same substitution also lands inside `echo -e "[PARENT]\nKEY = VALUE"` in the
third branch, where a `"`, a `` ` `` or a `$(…)` is **arbitrary command execution as root**
inside the distro — from a settings text box, with `showOutput: false` and `setSetting`
returning `true` regardless of what happened.

The four fields that reach it are `boot.command`, `automount.root`, `automount.options` and
`network.hostname` (`settings_dialog.dart:302`, `:314`, `:315`, `:327`). Not remotely
triggerable — the operator types the value — so this is a robustness finding, not a
vulnerability report. It matters because it constrains the fix: Phase 05's rewrite of this
writer must **escape** the value, not merely pick a different `sed` delimiter.

## Out of scope but recorded

`/etc/wsl-distribution.conf` — sections `[oobe]`, `[shortcut]`, `[windowsterminal]`
(`build-custom-distro.md:41-71`) — is a **different file** governing first-run
registration of a custom distro tarball. It is not `wsl.conf` and is not a gap in this
area; it belongs to the custom-distro finding in [[features]].

## What was not examined

- **The three launch preferences were traced, not exercised.** `StartUser_` /
  `StartPath_` / `StartCmd_` were followed from the dialog to `list_item.dart:141-149` and
  into `WSLApi.start`, by reading; no distro was launched from the app to confirm the
  `--user` it ends up passing.
- **No `/etc/wsl.conf` was read from a real distro**, and no setting was toggled and
  observed. CC-1 and CC-2 are derived from the shell script and the call sites; they are
  strong but not executed. The Phase 04 runtime-verification task should confirm both
  with a scratch distro before Phase 05 rewrites the writer.
- **`execCmds`' stdin-driven delivery** of `settings.bash` (`wsl.dart:986-1090`) was read
  only far enough to establish that failures are swallowed. Whether the script's `[[ ]]`
  constructs survive that path under a non-bash default shell was not tested.
- **Historical keys** `[automount] crossDistro` and `[filesystem] umask` were not probed
  against a live WSL; they are inferred dead from documentation silence alone.
- **Whether `boot.systemd` actually takes effect** through this writer on a distro that
  has no `[boot]` section was not verified.
- **Whether `wsl.conf` key matching is case-insensitive** is stated nowhere in the docs
  clone, and it decides whether an open risk is a real defect: `getWSLConf`
  (`wsl.dart:1824-1846`) keys its map on the spelling **as written in the file**, and
  `loadDistroSettings` stores prefs under `'$item-$section-$key'`, while the widgets read
  `'$item-automount-mountFsTab'`. A distro whose `wsl.conf` says `mountfstab = true`
  populates a pref no widget reads and the toggle renders off. [[verification]] V-7 records
  this as an unverified precondition; one scratch distro settles it.
