---
type: analysis
title: 'WSL Documentation Audit — runtime verification against the installed WSL'
created: 2026-08-28
tags:
  - wsl
  - docs-audit
  - runtime
related:
  - '[[index]]'
  - '[[wslconfig-keys]]'
  - '[[wslconf-keys]]'
  - '[[cli-flags]]'
  - '[[features]]'
  - '[[verification]]'
  - '[[coverage-sweep]]'
---

# Runtime verification

The first pass of this audit read the docs. The second ([[verification]]) read the code.
This third pass **executed WSL** and observed what it actually does, so the audit's
version floors, "the app should warn about this" claims and section-placement arguments
stop being inferences.

Docs citation for every documented claim below is unchanged:
**`microsoftdocs/wsl@8842def (2026-07-30)`**. Runtime claims cite the probe that produced
them; every probe file is kept at
`.maestro/playbooks/2026-08-28-WSL-Manager-Backlog-Audit/Working/runtime/`.

> [!IMPORTANT]
> Everything here was measured on **one** machine, on **2026-08-28**, against WSL
> **2.6.3.0**. A floor this build satisfies is not evidence that the floor is wrong — only
> that it is met here. See *What was not examined*.

## The machine under test

`wsl --version` (locale de-DE; labels translated, values verbatim):

```
WSL-Version:       2.6.3.0
Kernelversion:     6.6.87.2-1
WSLg-Version:      1.0.71
MSRDC-Version:     1.2.6353
Direct3D-Version:  1.611.1-81528511
DXCore-Version:    10.0.26100.1-240331-1435.ge-release
Windows-Version:   10.0.26200.9168
```

`wsl --status`: default distribution `Ubuntu`, default version `2`.
Distros: `Ubuntu` (default) and `ai-workspace`, both WSL 2, both `Stopped` before and
after this pass.

Host, for the two findings that depend on it: **10 logical processors**,
**8 569 397 248 bytes** (7.98 GiB) of RAM — so `SysInfo.getTotalPhysicalMemory() ~/ 1024
~/ 1024 ~/ 1024` is `7`, and the `memory` slider's `sizeMax` is **8**.

### Method, and the safety envelope

`%UserProfile%\.wslconfig` existed and was **empty** (0 bytes,
`md5 d41d8cd98f00b204e9800998ecf8427e`). It was backed up to
`Working/runtime/wslconfig.orig.bak`, overwritten once per probe, and restored; the final
hash was re-checked and matches. `ai-workspace`'s `/etc/wsl.conf` was backed up in-distro,
appended to for one probe, and moved back; its content and `hostname` were re-verified
afterwards. Nothing else on the machine was modified.

The probe technique that makes this pass cheap: **WSL 2.6.3 reports `.wslconfig` problems
on stderr, with file and line number**, and does so *before* it boots the VM. Setting
`WSL_UTF8=1` makes that output UTF-8 instead of UTF-16LE. Four distinct diagnostics were
observed, and each is a usable oracle:

| Diagnostic (de-DE) | English | Means |
|:---|:---|:---|
| `Unbekannter Schlüssel „<section>.<key>“ in <file>:<line>` | Unknown key | this build does not know that key **in that section** |
| `Ungültiger Schlüsselname in <file>:<line>` | Invalid key name | the line is not parseable as `key = value` |
| `Doppelter Konfigurationsschlüssel '<a>' … (widersprüchlicher Schlüssel: '<b>' …)` | Duplicate config key | two lines resolve to the same key |
| `Ungültige Speicherzeichenfolge "<v>" für .wslconfig Eintrag "<key>"` | Invalid size string | value rejected, key recognised |

A key that produces **no** diagnostic is recognised by the binary. That is a stronger
signal than absence-of-evidence normally is, because every neighbouring misplacement in
the same file *did* produce one.

---

## Part 1 — Version floors versus the installed WSL

Every floor the docs annotate is met by this machine, so **no documented key is
version-gated out here**. That is the useful negative result: it means every
"unrecognised key" finding in Part 2 is about *section placement or spelling*, never about
the build being too old.

| Documented floor | Requirement | This machine | Met |
|:---|:---|:---|:---|
| File-level `.wslconfig` (`wsl-config.md:213`) | Windows Build 19041+ | 26200 | yes |
| `¹` Only on Windows 11 (`debugConsole`, `nestedVirtualization`, `vmIdleTimeout`, `autoProxy`, `initialAutoProxyTimeout`) | Windows 11 | 10.0.26200 | yes |
| `²` Windows 11 22H2+ (`networkingMode`, `firewall`, `dnsTunneling`, `bestEffortDnsParsing`, `dnsTunnelingIpAddress`, `ignoredPorts`, `hostAddressLoopback`) | 22H2+ | 26200 | yes |
| `safeMode` — Win 11 + **WSL 0.66.2+** (`wsl-config.md:236`) | 0.66.2 | 2.6.3.0 | yes |
| `boot.systemd` — **WSL 0.67.6+** (`systemd.md`) | 0.67.6 | 2.6.3.0 | yes |
| `firewall` on by default from **WSL 2.0.9+** (`networking.md:160`) | 2.0.9 | 2.6.3.0 | yes |
| `networkingMode=nat` VirtioProxy fallback — **WSL 2.3.25+** | 2.3.25 | 2.6.3.0 | yes |
| `networkingMode=bridged` deprecated — **WSL 2.4.5+** | 2.4.5 | 2.6.3.0 | yes |

### R-1 — One gate is hardware, not version, and the docs never mention it

`nestedVirtualization` is documented as defaulting to **`true`**. On this machine every
VM start with the default in place prints:

> `wsl: Geschachtelte Virtualisierung wird auf diesem Computer nicht unterstützt.`
> (*Nested virtualization is not supported on this computer.*)

Setting `nestedVirtualization=false` silences it; the warning is a property of the host
CPU/hypervisor, not of the config. `wsl-config.md` documents no hardware precondition for
the key at all, and the app's `nestedvirtualizationinfo-text` inherits that silence.

Consequence for Phase 05: **a version gate is not sufficient to decide whether to show
this key as available.** There is no documented capability query for it either — the only
signal is this stderr line, which the app currently discards (`[[cli-flags]]` CC-1: the
app never reads WSL's version or status output). Size this as *show the key, surface WSL's
own warning*, not as *gate the key*.

### R-2 — `wsl.exe` 2.6.3 has every flag `cli-flags.md` marks **H**

[[cli-flags]] classifies 12 flags as **H** — present in `wsl.exe --help` but absent from
`microsoftdocs/wsl@8842def`. All 12 are present in this build's `--help`, together with
all 25 documented (**D**) verbs and options that were spot-checked:

`--manage`, `--set-sparse`, `--move`, `--shell-type`, `--distribution-id`, `--uninstall`,
`--import-in-place`, `--set-default-user`, `--vhd`, `--format`, `--no-distribution`,
`--legacy`, `--fixed-vhd`, `--vhd-size`, `--name`, `--location`, `--web-download`,
`--pre-release`, `--system`, `--debug-shell`, `--exec`, `--cd`, `--user`, `--version`,
`--update`, `--mount`, `--unmount`, `--import`, `--export`, `--set-version`,
`--set-default`, `--terminate`, `--list`, `--install`, `--status`, `--shutdown`.

The **H** classification is therefore about the documentation being incomplete, not about
the flags being unstable or preview-gated. Phase 05 can target them without a version
guard on a 2.6.x baseline — but see *What was not examined* on older builds.

---

## Part 2 — Which keys the installed WSL actually honours

### R-3 — All 27 reference-table keys are recognised, and so are the two Intune-only keys

`Working/runtime/probe1.wslconfig` put all 20 `[wsl2]` and all 7 `[experimental]`
reference-table keys in their documented sections with valid values. **Zero diagnostics.**
Observable effects confirmed in the same run: `processors=2` → `nproc` = `2`;
`memory=4GB` → `MemTotal` 3 917 MB; `swap=0` → `Swap: 0`.

`kernelDebugPort` (probe1) and `systemDistro` (probe2) — the two keys
`Working/wslconfig-keys.md` found only in `intune.md`, with no reference-table row — are
**both recognised** under `[wsl2]`. `systemDistro` produced only a path-escaping error, not
an unknown-key error, which is itself a recognition proof. The inventory's "total known
`.wslconfig` keys = 29" holds against the binary.

### R-4 — Sections are enforced, and a misplaced key is silently dead

This is the finding that upgrades [[wslconfig-keys]] **CC-3** from a tidiness complaint to
a data-loss bug. `probe2.wslconfig` put each `[experimental]` key under `[wsl2]` and
`memory` under `[experimental]`:

```
wsl: Unbekannter Schlüssel „wsl2.autoMemoryReclaim“ in …:2
wsl: Unbekannter Schlüssel „wsl2.sparseVhd“ in …:3
wsl: Unbekannter Schlüssel „wsl2.bestEffortDnsParsing“ in …:4
wsl: Unbekannter Schlüssel „wsl2.dnsTunnelingIpAddress“ in …:5
wsl: Unbekannter Schlüssel „wsl2.initialAutoProxyTimeout“ in …:6
wsl: Unbekannter Schlüssel „wsl2.ignoredPorts“ in …:7
wsl: Unbekannter Schlüssel „wsl2.hostAddressLoopback“ in …:8
wsl: Unbekannter Schlüssel „experimental.memory“ in …:16
wsl: Unbekannter Schlüssel „general.foo“ in …:19
```

All seven `[experimental]` keys are rejected under `[wsl2]`; `memory` is rejected under
`[experimental]`; an undocumented `[general]` section is rejected wholesale. `wsl.exe`
exits **0** regardless — the warnings are advisory and the VM boots with the key
**unset**.

[[wslconfig-keys]] CC-3 point 3 says `saveSettings` relocates a user's hand-added
`[experimental]` key into `[wsl2]` because `experimentalKeys`
(`settings_screen.dart:271-279`) is a hardcoded list of seven. Runtime result: that
relocation does not merely tidy the file, it **turns the setting off**, with the only
notice being a stderr line the app never reads. Verdict on CC-3 stands at **wrong**; its
severity should be read as data-affecting.

### R-5 — Correction: `troubleshooting.md`'s `[experimental]` advice is *not* broken

`Working/wslconfig-keys.md` states, of the four keys `troubleshooting.md:305/315/335`
still calls experimental: *"a user following `troubleshooting.md` writes
`[experimental] networkingMode=mirrored`, which the current WSL ignores."*

**That is wrong, and this pass withdraws it.** In the same `probe2` run above,
`[experimental] networkingMode`, `firewall`, `dnsTunneling` and `autoProxy` produced **no
unknown-key diagnostic**, while every other misplaced key in the same file did.
`probe5` then confirmed it behaviourally — `ip -o -4 addr` inside `Ubuntu`, one distro,
three configs, a `wsl --shutdown` between each:

| Config | `eth0` address |
|:---|:---|
| `[wsl2] networkingMode=nat` | `172.26.21.255/20` (NAT) |
| `[wsl2] networkingMode=mirrored` | `192.168.3.82/24` (the host's LAN address — mirrored) |
| `[experimental] networkingMode=mirrored` | `192.168.3.82/24` — **mirrored, identical** |

WSL 2.6.3 accepts those four keys under **either** section. So `troubleshooting.md` is
stale prose, not a trap; the four keys are the *only* ones with dual-section acceptance,
which is exactly what a graduated-out-of-experimental key would look like if the old name
were kept for compatibility.

Two things follow. The docs-contradiction finding in `Working/wslconfig-keys.md` and the
Phase 05 note at [[features]]:79-85 stay — the app is still right to write `[wsl2]`, and a
tooltip line is still worth having — but the justification changes from *"otherwise the
setting is ignored"* to *"otherwise the file disagrees with the reference page"*, which is
a much weaker reason. **Do not size a Phase 05 item on the ignored-setting claim.**

`10.255.255.254/32` on `lo` in all three runs also confirms `dnsTunneling` defaulting to
`true` with the documented default `dnsTunnelingIpAddress`.

### R-6 — Path values: single backslashes are a hard parse error, and the app writes them

`wsl-config.md:248` says `path` values need escaped backslashes. Runtime says it is not a
style preference:

| Written | Result |
|:---|:---|
| `swapFile=C:\Temp\wslswap.vhdx` | `wsl: Ungültiges Escapezeichen: „T“ in …:3` — **line discarded**, key unset |
| `swapFile=C:\\Temp\\wslswap.vhdx` | parsed as `C:\Temp\wslswap.vhdx`; failed only because that directory does not exist |

The app has **no backslash escaping anywhere** — `grep` for it across
`settings_screen.dart` and `wsl.dart` returns nothing — and `setConfig`
(`wsl.dart:544-592`) writes the controller text verbatim. So:

- `kernelModules`' file picker (`settings_screen.dart:1025-1038`) assigns
  `result.files.single.path!` straight into the controller — a real Windows path, single
  backslashes. Every value this picker can produce is a `.wslconfig` line WSL discards.
- `kernel` (`:1021`) and `swapFile` (`:1072`) are plain text boxes with the tooltip
  "absolute Windows path", inviting exactly the same input.

This is a **new finding**, not covered by any existing CC. It compounds
[[wslconfig-keys]] CC-2 (`readConfig` strips every space): a path under
`C:\Program Files\…` is mangled *and* unescaped. Verdict **wrong**; three keys affected;
the fix is one escape on write and one unescape on read.

### R-7 — `#` is the only comment character; `;` is a parse error

[[wslconfig-keys]] **CC-5** says the app parses comment lines as keys. `probe8` establishes
what a correct parser has to accept: `# a hash comment` and `# memory=1GB` both produced
no diagnostic, while `; a semicolon comment` produced
`wsl: Ungültiger Schlüsselname in …:2`. So `.wslconfig` is INI-*like* but not INI —
Phase 05 should strip `#` lines only, and must not "helpfully" support `;`, because WSL
rejects it.

### R-8 — Duplicate keys: WSL detects them, warns, and **first occurrence wins**

`probe8` also settles what happens to the duplicate file [[wslconfig-keys]] CC-4 and
[[verification]] V-5 say the app creates. Given `swapfile=…\a.vhdx` (line 6),
`SWAPFILE=…\b.vhdx` (line 7), `memory=3GB` (line 8), `memory=5GB` (line 9):

```
wsl: Doppelter Konfigurationsschlüssel 'wsl2.SWAPFILE' in …:7 (widersprüchlicher Schlüssel: 'wsl2.swapfile' in …:6)
wsl: Doppelter Konfigurationsschlüssel 'wsl2.memory' in …:9 (widersprüchlicher Schlüssel: 'wsl2.memory' in …:8)
```

and `MemTotal: 2977500 kB` (≈ 3 GB) — the **line-8** value. Case-insensitive matching is
confirmed (`swapfile` and `SWAPFILE` collide), and the conflict resolves to the
**first** occurrence.

That makes V-5's symptom strictly worse than recorded. V-5 traces: a lowercase
`swapfile=` line makes the `swapFile` box render empty; the user fills it; Save appends a
second line. Runtime adds the ending — **the appended line loses**. The user's edit has no
effect at all, on any subsequent boot, and the app will keep showing the box empty. This
is a silent no-op edit, not a messy file. Read CC-4 as *wrong, data-affecting*.

### R-9 — WSL clamps out-of-range numbers; the app asserts on them

[[verification]] V-1 / [[wslconfig-keys]] **CC-9** predicted the `memory` slider throws on
`memory=8589934592`, the documented byte form of 8 GB. This pass verifies the *precondition*
— that the value is one WSL genuinely accepts — and finds the two halves of CC-9 behave
differently:

| Probe value | WSL 2.6.3 | App slider (`sizeMax` on this host) |
|:---|:---|:---|
| `memory=8589934592` | **accepted silently**, `MemTotal` 8 111 836 kB | `8589934592.0` vs `max: 8` → `assert(value <= max)` |
| `processors=64` | **rejected with a clear message** — `wsl2.processors darf die Anzahl logischer Prozessoren auf dem System nicht überschreiten (64 > 10)` — and clamped to 10 | `64.0` vs `max: 10` → same assert |

So for `memory` the app crashes on a value WSL is perfectly happy with; for `processors`
the app crashes on a value WSL survives by warning. In both directions **the app is less
robust than the tool it configures**. CC-9 confirmed; the app reads the *file*, never
WSL's effective value, so the clamp does not save it.

### R-10 — Confirmed: a `MB`-suffixed size silently becomes `1GB`

Already recorded from code at [[wslconfig-keys]]:63 and [[verification]]:210; this pass
supplies the missing half — that WSL really does honour the value the app throws away.
`wsl-config.md:250` documents `MB` and `GB` suffixes, and `memory=6144MB` is honoured —
`MemTotal: 6067928 kB` (≈ 5.8 GiB), confirmed at runtime.

The app's slider computes
`double.tryParse(text.replaceAll(sizePostfix, ''))` with `sizePostfix: 'GB'`
(`settings_screen.dart:1044`, `:1196`). `"6144MB".replaceAll('GB','')` is unchanged,
`tryParse` returns `null`, and the `?? sizeMin.toDouble()` fallback yields **1**. The
screen shows 1 GB; `saveSettings` writes `1GB` back. A user who wrote a legal `6144MB`
loses 5 GB of VM memory the first time they open Settings and press Save — with no crash
and no message.

Distinct from CC-9: same expression, opposite failure mode (silent corruption rather than
an assert), and it is the *more* likely of the two to have happened to a real user,
because `MB` is a natural thing to write. Verdict **wrong**, unchanged; the fix is the same
size-parser CC-9 needs, so they should be one Phase 05 item.

---

## Part 3 — The restart requirement, measured

[[features]] **F-10** and [[wslconfig-keys]] **CC-7** and [[wslconf-keys]] **CC-5** all
turn on the docs' "8 second rule" (`wsl-config.md:20-26`). Both halves now have direct
evidence.

### R-11 — `.wslconfig` changes are ignored until `wsl --shutdown`, with no signal at all

With the VM running under `[experimental] networkingMode=mirrored`, the config was
rewritten to `[wsl2] networkingMode=nat` and a new command run **without** a shutdown:

| Step | `eth0` |
|:---|:---|
| running, mirrored config on disk | `192.168.3.82/24` |
| config replaced with NAT, **no** shutdown, new `wsl -d Ubuntu` invocation | `192.168.3.82/24` — unchanged |
| after `wsl --shutdown`, same invocation | `172.26.21.255/20` — NAT applied |

The stale run printed **no warning**. WSL does not tell the user their edit is pending;
the only way to know is to already know. The docs' "you *may* need to run `wsl --shutdown`"
(`wsl-config.md:213`) understates this — on this build, for this key, it is unconditional.

The app's `globalconfigurationinfo-text` is a faithful paraphrase of that doc sentence,
"may need to" and all, and it is present in **all nine locales** (`en.json:117`,
`de/es/hu/ja/pt/tr:118`, `zh_CN/zh_TW:117`) and rendered at `settings_screen.dart:1017`.
So CC-7's verdict of **covered** is correct against the docs — but the docs are the weak
link, and the app is free to be more definite than its source. Phase 05 should say
*"changes take effect after WSL restarts"*, not *"you may need to"*.

CC-7's second blemish is confirmed and is the cheap win: `WSLApi().shutdown()` already
exists (`wsl.dart:473`) and a **Stop WSL** button already calls `restart()`
(`settings_screen.dart:168-185`). Save does not offer it. Wiring Save → "restart WSL now?"
is a prompt over an existing method.

### R-12 — `wsl.conf` needs only `wsl --terminate <distro>`, and it also gives no signal

Measured on `ai-workspace`, using `network.hostname` — a key the app's own dialog writes
(`settings_dialog.dart:327`):

| Step | `hostname` |
|:---|:---|
| baseline (`/etc/wsl.conf` = `[boot] systemd=true`) | `WINDOWS-VM` |
| `[network] hostname = probehost` appended, distro still running | `WINDOWS-VM` — unchanged |
| after `wsl --terminate ai-workspace` | `probehost` |
| after restoring the file and terminating again | `WINDOWS-VM` |

Confirms two things F-10 and [[wslconf-keys]] CC-5 assert: the write is inert until the
distro stops, and a **per-distro `--terminate` is sufficient** — no full `--shutdown`,
so the fix for the dialog is strictly cheaper than the global screen's. `wsl --terminate`
is already wrapped as `WSLApi().terminate()`-adjacent plumbing in `lib/api/wsl.dart`, and
the dialog knows which distro it is editing.

The gap in CC-5 is confirmed exactly as written: the `wsl.conf` dialog states nothing and
offers no restart affordance, while every one of its keys is subject to this. `boot.systemd`
— the dialog's most prominent toggle — is the one key the docs call out by name for
`wsl.exe --shutdown` (`wsl-config.md:57`, `systemd.md:46`), and it is the one most likely
to be toggled by someone who will then conclude the app is broken.

### R-13 — Docs sweep: where a restart is required, and whether the app says so

| Requirement | Documented at | App tells the user? |
|:---|:---|:---|
| Any `.wslconfig` key | `wsl-config.md:20-26`, `:213` | **yes** — `globalconfigurationinfo-text`, plus a **Stop WSL** button. Weakened by "may need to"; not offered on Save |
| Any `wsl.conf` key | `wsl-config.md:20-26` (general rule) | **no** |
| `boot.systemd` specifically | `wsl-config.md:57`, `systemd.md:46-48` | **no** |
| `automount.options` specifically | `case-sensitivity.md:112` | **no** |
| `initialAutoProxyTimeout` — instance restart if the proxy resolves late | `wsl-config.md:268` | **no** — and the tooltip drops the clause ([[verification]] Part 3) |
| Recovery advice: restart WSL when networking misbehaves | `troubleshooting.md:844`, `:877` | n/a — not a settings surface |

No documented key takes effect without a restart of its scope. There is no per-key
exception to hunt for, which simplifies Phase 05: one message on each editor, one restart
button each, correct scope per file.

---

## Corrections this pass makes to earlier findings

| Where | Was | Now |
|:---|:---|:---|
| `Working/wslconfig-keys.md:132` | "`[experimental] networkingMode=mirrored` … which the current WSL ignores" | **withdrawn** — R-5 shows WSL 2.6.3 honours it in either section |
| [[wslconfig-keys]] CC-3 | section-blindness relocates keys | **escalated** — R-4: a relocated key is rejected by WSL and silently unset |
| [[wslconfig-keys]] CC-4 / [[verification]] V-5 | appends a duplicate key | **escalated** — R-8: the appended line **loses** to the existing one; the user's edit is a no-op |
| [[wslconfig-keys]] CC-7 | "covered, two blemishes" | **stands**, with R-11 evidence that the doc sentence the app copies is itself too weak |
| [[wslconfig-keys]] CC-9 | slider throws on a documented-legal value | **confirmed** — R-9 verifies WSL accepts the crashing value; adds that `processors` crashes on a value WSL only warns about |
| [[features]] F-10 | requirement surfaced for one file of two | **confirmed** — R-11/R-12, with the scope refinement that `wsl.conf` needs only `--terminate` |
| [[cli-flags]] CC-1 / [[features]] F-9 | app never reads WSL's version | **confirmed and sharpened** — R-1: WSL emits capability warnings on stderr that the app discards, and `nestedVirtualization` cannot be gated on version at all |

New findings with no prior entry: **R-6** (unescaped backslashes in path keys — three keys,
one of them from a file picker, recorded as [[wslconfig-keys]] CC-10), **R-7** (`;` comments
are a parse error, folded into CC-5), and **R-1** (hardware gate on `nestedVirtualization`).
R-10 is not new — the `MB` collapse was already recorded from code at
[[wslconfig-keys]]:63; this pass only supplies its runtime half.

---

## What was not examined

- **One machine, one build.** WSL 2.6.3.0 on Windows 10.0.26200 with a de-DE locale. Every
  "recognised" result in Part 2 is a *this-build* result. A key WSL 2.6.3 accepts may not
  exist on a 2.0.x machine, and this pass gives no evidence either way — the version-floor
  table in Part 1 is still sourced from the docs, not measured.
- **The app was not launched.** R-9 and R-10 verify the *inputs* — that WSL accepts
  `memory=8589934592` and honours `memory=6144MB` — and the failure is derived from
  `settings_screen.dart:1196` plus `fluent_ui`'s constructor assert. Nobody has yet seen
  the Settings page throw. That reproduction (debug build, `.wslconfig` with the byte
  form, open Settings) remains the single highest-value thing left to do, and it is now
  the only unverified step in CC-9's chain.
- **The app's writers were not exercised end to end.** R-6 and R-8 predict what
  `setConfig` produces by reading it; no probe was driven *through* the app's Save path.
  A Phase 05 fix should add a test at that layer rather than trusting this inference.
- **`wsl.conf` was probed with one key on one distro.** `network.hostname` on
  `ai-workspace`. The other fourteen `wsl.conf` keys were not individually restart-tested;
  the 8-second rule is documented as file-wide and there is no reason to expect per-key
  variation, but it was not measured.
- **`assets/scripts/settings.bash` was not run.** [[wslconf-keys]] CC-1/CC-2 (the
  section-blind `sed`, the `/` delimiter collision) are still code-read findings. They are
  the natural companion to R-6 and R-8 and deserve the same runtime treatment.
- **Locale.** All diagnostics were captured in German. The message *text* is translated;
  the key names, file paths and line numbers inside them are not, which is what the
  findings rely on. No English-locale run was made to confirm the wording, so do not quote
  these strings as English WSL output.
- **Nothing was measured about remote WSL** (`_useRemoteWsl`). Every probe was local.
