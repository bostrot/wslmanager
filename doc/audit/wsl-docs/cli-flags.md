---
type: analysis
title: 'wsl.exe Flags — documented surface vs. the app'
created: 2026-08-28
tags:
  - wsl
  - docs-audit
  - cli
related:
  - '[[index]]'
  - '[[runtime]]'
  - '[[coverage-sweep]]'
  - '[[verification]]'
  - '[[wslconfig-keys]]'
  - '[[wslconf-keys]]'
  - '[[features]]'
---

# `wsl.exe` — documented vs. the app

Diff of every documented (**D**) and `--help`-only (**H**) `wsl.exe` command against every
`wsl.exe` invocation in `lib/`.

- **Documented side:** `microsoftdocs/wsl@8842def (2026-07-30)` plus the local
  `wsl.exe --help`, inventoried in
  `.maestro/playbooks/2026-08-28-WSL-Manager-Backlog-Audit/Working/wsl-exe-flags.md`
  (64 commands + options).
- **App side:** `lib/api/wsl.dart` (`_runWsl` / `_startWsl` / `_buildRemoteArgs`),
  `lib/api/wsl_args.dart` (the two canonical builders), `lib/api/mount_service.dart`,
  `lib/api/ai_workspace/service.dart`.
- **Verdicts** are about the *app*, not the docs: `covered` = the app uses it correctly ·
  `wrong` = the app uses it in a way the docs contradict · `missing` = documented
  capability the app never reaches for · `n/a` = out of scope for a distro manager.

## Headline

**The app uses 13 of the 30 top-level `wsl.exe` verbs.** Everything it needs for the
create / list / export / import / remove / mount lifecycle is present and, since the
`--exec` work recorded in `AGENTS.md`, correctly quoted.

The gaps cluster in three places:

1. **No version awareness at all.** Neither `--version` nor `--status` is invoked anywhere
   in `lib/` (0 hits). The app therefore cannot gate any UI on a WSL version, which is the
   precondition for fixing the version-floor problem in [[wslconfig-keys]] and
   [[wslconf-keys]].
2. **`--manage` is entirely absent** — the whole WSL 2.5+ verb, including `--resize`,
   `--set-sparse`, `--set-default-user` and `--move`. `move()` reimplements `--manage
   --move` as a destructive export → unregister → import.
3. **`--export` is called bare**, so every export and every move writes an uncompressed
   tar; `--format tar.gz|tar.xz|vhd` is never used.

One live defect: `WSLApi.install()` (`wsl.dart:970-973`) shells out to
`wsl --install -d <distribution>`, the exact form `AGENTS.md` records as *not* creating a
distro under that name. It has **no call site** — dead code — but it is a loaded gun.

## Distro-execution arguments

| Flag | Src | App state | Verdict |
|:---|:---|:---|:---|
| `--exec` / `-e` | H | `wsl_args.dart:57` (`kWslExecFlag`), used by `wslExecArgs` / `wslShellArgs` and every in-distro call site | **covered** — and the app is ahead of the docs here; `--exec` is absent from `basic-commands.md` |
| `--distribution` / `-d` | D | `wsl_args.dart:60-64` (`_distroPrefix`), plus `wsl.dart:416/459/512/767/1136` | **covered** |
| `--user` / `-u` | D | `_distroPrefix`; `wsl.dart:393` (`start`, long spelling), and the three stdin-driven shells `:994` (`execCmds`), `:1051` (`runCmds`), `:1118` (`startShell`) | **covered** |
| `--cd` | H (announced in `release-notes.md:34`) | `wsl.dart:390`, `:767-768` | **covered** |
| `--shell-type` | H | not used (mentioned only in a `wsl_args.dart:54` comment) | **missing, low value** — `--exec` already solves the same problem |
| `--` (passthrough) | H | not used for `wsl`; `mount_service.dart:107` and `shell.dart` use it as an **ssh** separator | **n/a** |
| `--system` | D (`disk-space.md:30`) | not used | **missing** — would be the clean way to read VM-wide disk state |
| `--distribution-id` | H | not used | **n/a** — the app keys everything by name |
| `~` (positional) | D | approximated by `--cd ~` (`wsl.dart:767-768`) | **covered** |

## Management verbs

| Verb | Src | App state | Verdict |
|:---|:---|:---|:---|
| `--install` (WSL itself) | D | `wsl.dart:363` — `_runWsl(['--install'])` from `installWSL()`, wired to the "wsl --install" button in `install_dialog.dart:29` | **covered** |
| `--install -d <Distro>` | D | `wsl.dart:971` — `WSLApi.install(distribution)` | **wrong** — this is the `-d` ≠ `--name` trap in `AGENTS.md`; `-d` selects which distro to install, it does not name the result. **Dead code**: no caller in `lib/`, `test/` or `integration_test/` |
| `--install <Distro> --name <Name>` | D (`build-custom-distro.md:66`) | `ai_workspace/service.dart:597` — `['--install', 'Ubuntu', '--name', kAiWorkspaceDistro]` | **covered** — the correct form, used by the newer code |
| `--shutdown` | D | `wsl.dart:474` (`shutdown`), `:1169-1170` (`restart`, twice) | **covered** |
| `--shutdown --force` | H | not used | **missing, deliberate** — help text warns of data loss |
| `--terminate` / `-t` | D | `wsl.dart:450` | **covered** |
| `--status` | D | **not used** (0 hits in `lib/`) | **missing** |
| `--version` / `-v` | D | **not used** (0 hits) | **missing, high impact** — see CC-1 |
| `--update` | D | not used | **missing** — no in-app "update WSL"; users are sent to the CLI |
| `--update --web-download` | D | not used | **missing** — the documented workaround when the Store is blocked (`compare-versions.md:102`) |
| `--update --pre-release` | D | not used | **n/a** for now (WSL-container territory) |
| `--set-default-version` | D | not used | **missing** — the app has no WSL 1 / WSL 2 default control |
| `--help` | D | not used programmatically | **n/a** |
| `--debug-shell` | D | not used | **n/a** |
| `--uninstall` | H | not used | **n/a, deliberately** — removes WSL itself; the docs' overloading of the word "uninstall" makes this a good thing to keep out of the UI |
| `--manage` (whole verb, WSL 2.5+) | D | **not used** (0 hits) | **missing, high impact** — see CC-2 |
| `--mount` | D | `mount_service.dart:248` (physical, via `_runAsAdmin`), `:268` (remote), `:313` (VHD) | **covered** |
| `--unmount` | D | `mount_service.dart:350` | **covered** |

### `--mount` options — fully covered

| Option | Src | App state | Verdict |
|:---|:---|:---|:---|
| `--vhd` | D | `mount_service.dart:313` | **covered** |
| `--bare` | D | `:251`, `:270`, `:319` | **covered** |
| `--name` | D (Store WSL only) | `:253-255`, `:274`, `:321` — auto-derived via `_getSafeName` | **covered** |
| `--partition` | D | `:256-258`, `:277`, `:323` | **covered** |
| `--type` / `-t` | D | `:259-261`, `:280`, `:325-333` — allow-listed to `ext4/xfs/btrfs/vfat/ntfs` | **covered** — the allow-list is narrower than the docs (which say "any kernel-native filesystem") but that is a deliberate injection guard, not a gap |
| `--options` / `-o` | D | `:262-264`, `:283`, `:334-336` | **covered** — the docs' "generic options like `ro`/`rw` are not supported" caveat is not surfaced to the user |

## Distro management verbs

| Verb | Src | App state | Verdict |
|:---|:---|:---|:---|
| `--list --quiet` | D | `wsl.dart:1294`; `ai_workspace/service.dart:581` | **covered** |
| `--list --running --quiet` | D | `wsl.dart:1564` | **covered** |
| `--list --verbose` | D | not used | **missing** — the app derives running state from a second `--list --running` call instead of reading state + WSL version from one `-v` call |
| `--list --online` / `-o` | D | not used | **missing, by design** — the app ships its own distro catalogue (`images.json`, `distroRootfsLinks`) |
| `--list --all` | D | not used | **missing, low value** |
| `--export` | D | `wsl.dart:904` — `['--export', distribution, location]`, bare | **covered** for tar |
| `--export --format` | H (+ `faq.yml:188`) | not used | **missing** — no compressed export; see CC-3 |
| `--export --vhd` | D̶ | not used | **n/a** — and correctly so: `basic-commands.md:185` documents it but the shipping binary offers only `--format` |
| `--import` | D | `wsl.dart:1203`, `:1278` | **covered** |
| `--import --vhd` | D | `wsl.dart:1200`, `:1280` — used by `copyVhd()` and by VHD-source creates | **covered** |
| `--import --version` | D | not used | **missing, low value** — imports inherit the machine default |
| `--import-in-place` | D | not used | **missing** — `copyVhd()` (`wsl.dart:840-900`) file-copies `ext4.vhdx` then `--import --vhd`, which copies it a **second** time. `--import-in-place` exists precisely to avoid that |
| `--unregister` | D | `wsl.dart:924` — via `_startWsl` with a 30 s timeout | **covered** |
| `--set-default` / `-s` | D | not used | **missing** — the app cannot set the Windows default distro |
| `--set-version` | D | not used | **missing** — no WSL 1 ↔ WSL 2 conversion |
| `<distro> config --default-user` | D (broken for imported distros) | not used | **covered by omission** — the app correctly avoids it and writes `[user] default` instead (`create_dialog.dart:325`) |
| `wslconfig.exe` / `bash.exe` / `lxrun.exe` | deprecated | not used | **covered** |

## Cross-cutting findings

### CC-1 — The app never asks WSL what version it is

> [[runtime]] R-1 and R-2 add two things. R-2: every flag this file marks **H** is present
> in WSL 2.6.3.0's `--help`, so the **H** mark is about incomplete documentation, not about
> preview-gated flags. R-1: version is not always the right gate anyway —
> `nestedVirtualization` is refused by the *host CPU* on the test machine
> (`wsl: Geschachtelte Virtualisierung wird auf diesem Computer nicht unterstützt`), a
> condition `wsl-config.md` never mentions and no version check can detect. WSL emits that
> on stderr; the app discards it.


`--version` and `--status` have zero `wsl` call sites. Consequences that reach well beyond
this file:

> Re-grep footnote, from [[verification]]: `grep -rn -- "--version" lib/` returns **one**
> hit and `--format` returns **two**, so a future reader will think this claim is refuted.
> It is not. The `--version` hit is `cloudflared --version`
> (`cloudflare_tunnel_service.dart:90`); the `--format` hits are
> `docker image ls --format` (`docker_images.dart:744`) and a `docker inspect --format`
> inside an AI-workspace script. None is a `wsl.exe` invocation. `--shell-type`'s single hit
> is a comment in `wsl_args.dart:54`.

- Every version floor recorded in [[wslconfig-keys]] and [[wslconf-keys]] (Win 11 ¹,
  Win 11 22H2 ¹², WSL 0.66.2+, 0.67.6+, 2.0.9+, 2.5+) is unenforceable. The app renders
  `hostAddressLoopback` and `safeMode` identically on a machine that cannot honour either.
- `systemd.md:30` documents the canonical probe: inbox WSL rejects `--version` with
  `Invalid command line option: --version`, Store WSL answers it. The app has no way to
  tell the two apart, so it cannot warn that `--manage`, `--mount --name` or the
  `[experimental]` keys are unavailable.
- The user-visible "which WSL do I have" answer is not shown anywhere in the app.

Verdict **missing**. This is the enabling finding for most of Phase 05's UI gating.

### CC-2 — `--manage` is missing entirely, and `move()` pays for it

`wsl --manage <Distro> <Option>` (WSL 2.5+, `disk-space.md:48-58`) has four options; the
app implements zero of them.

| Option | What it does | What the app does instead |
|:---|:---|:---|
| `--move <Location>` | Moves a distro's storage | `WSLApi.move` (`wsl.dart:1649-1790`) **exports to a tar, unregisters the distro, then re-imports**. It is careful — size floor, recovery marker in prefs, surfaced by the startup recovery dialog — but it is a destructive three-step where a single supported verb exists |
| `--resize <Size>` | Grows the distro's VHD | nothing; the app has no disk-space feature at all (`grep -rni "resize" lib/` → only a window-resize handler) |
| `--set-sparse <bool>` | Makes an **existing** VHD sparse | nothing. The app exposes `[experimental] sparseVhd` (`settings_screen.dart:1130`), which only affects **newly created** VHDs — a different control that users routinely mistake for this one |
| `--set-default-user <Name>` | Sets the distro's default user | nothing; see [[wslconf-keys]] CC-6 |

All four are **H** rows — present in `wsl.exe --help`, absent from the entire docs clone
(`--resize` is the exception; it is documented on `disk-space.md`). Any Phase 05 work here
must be gated on a real `wsl --version` check, which the app cannot currently perform
(CC-1).

Verdict **missing**, high impact — `--move` in particular converts the app's riskiest
operation into a supported one-liner.

**And it is the one finding in this audit with a report of real data loss behind it.**
[#280](https://github.com/bostrot/wslmanager/issues/280): "I clicked **move**
expecting to choose a new path… when I came back after 30 min I found the app closed,
opening my usual work instance I found it deleted." The export → unregister → import
sequence is exactly the window that report fell into, and the reporter's own request — warn
before actions that can lose data — is the cheap interim fix if the native verb has to wait.
Sized as P05-15 in [[index]].

### CC-3 — Every export is an uncompressed tar

`WSLApi.export` (`wsl.dart:903-916`) passes no format flag. The binary supports
`--format tar|tar.gz|tar.xz|vhd` (`faq.yml:188`, `wsl.exe --help`), none of which is
documented on `basic-commands.md`. Two effects: user-facing backups and templates are
several times larger than they need to be, and `move()`'s intermediate `export.ext4`
(`wsl.dart:1719`) is an uncompressed tar with a misleading extension. Verdict **missing**.

### CC-4 — Two remaining hand-built `wsl` argument paths

`wsl_args.dart` centralises in-distro invocations, but two call sites still assemble
`wsl` arguments as a **string**:

- `mount_service.dart:248-292` builds `String args = '--mount $diskPath'` and appends
  ` --name "$name"` etc. before handing it to `_runAsAdmin('wsl', args)` — an elevation
  path, so the string is re-parsed by the shell that elevates it. The parallel
  remote branch immediately below (`:267-289`) builds the same command as a proper
  `List<String>`; the two implementations are duplicated line for line.
- `mount_service.dart:313` pre-quotes the path (`'"$windowsPath"'`) inside a list
  argument, so the quotes are passed to `wsl.exe` **literally** as part of the path.

Neither is a docs discrepancy, so neither carries a verdict here — recorded because
`cli-flags` is where a reader will look for them, and because `AGENTS.md`'s
"never build `wsl` arguments by hand" rule is the reason they stand out.

### CC-5 — `install()` is dead code carrying a documented trap

`WSLApi.install` (`wsl.dart:970-973`) runs `wsl --install -d <distribution>`. Per
`AGENTS.md` and the `--install` option table, `-d` does not register a distro under that
name. It is unreachable today (no caller anywhere), so the correct action is deletion
rather than a fix. Verdict **wrong**.

## Completeness of the app side

[[coverage-sweep]] enumerated `lib/api/wsl.dart` end to end — **27 `wsl.exe` invocation
sites, 15 distinct flags and verbs** — and matched every one against a row above. **No flag
reaches `wsl.exe` from that file that this file does not list**, so the "13 of 30 verbs"
headline is a floor as well as a ceiling. The site-by-site table is in [[coverage-sweep]]
*Sweep 3*.

Two things the sweep changed here, both citations rather than verdicts: `--user` in
`execCmds` is `wsl.dart:994`, not `:1017`, and its two sibling spawns (`runCmds`,
`startShell`) were uncited. `move()` (`:1649-1790`) issues no `wsl.exe` call of its own —
it composes `export()`, `remove()` and `import()`, which is precisely what makes it the
destructive sequence CC-2 and #280 describe.

`mount_service.dart`'s and `ai_workspace/service.dart`'s cited lines were spot-checked and
are exact. One uncited invocation there — `service.dart:538-539`, a
`-d <distro> -u root sleep infinity` keepalive — uses no flag not already covered.

## What was not examined

- **No `wsl.exe` command was executed for this diff.** The **H** rows are inherited from
  the working inventory's single `wsl.exe --help` run on 2026-08-28 (de-DE output); this
  file re-uses them without re-verifying. `wsl --version` was deliberately **not** run —
  the Phase 04 runtime-verification task owns it, and CC-1 above is the reason it matters.
- **Whether the app's `--mount` calls succeed** was not tested; the mount dialog was not
  exercised.
- **Launcher executables** (`ubuntu.exe`, `debian.exe`, …) were not swept — the app does
  not use them, and they are distro-vendor surface, not `wsl.exe`.
- **`usbipd`, `wslc`, `docker` flags** appearing in the docs were classified as
  not-`wsl.exe` in the working inventory and are not re-examined here.
- **The SSH remote path.** Every verb above also runs through `_buildRemoteArgs`
  (`wsl.dart:234-296`), which does not quote its arguments — `AGENTS.md` records this as a
  known gap. No remote invocation was tested, and this audit makes no claim that a flag
  working locally works remotely.
