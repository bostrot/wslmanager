---
type: analysis
title: 'WSL Feature Surfaces — documented capabilities vs. the app'
created: 2026-08-28
tags:
  - wsl
  - docs-audit
  - features
related:
  - '[[index]]'
  - '[[runtime]]'
  - '[[coverage-sweep]]'
  - '[[verification]]'
  - '[[wslconfig-keys]]'
  - '[[wslconf-keys]]'
  - '[[cli-flags]]'
---

# Feature surfaces — documented vs. the app

Where [[wslconfig-keys]], [[wslconf-keys]] and [[cli-flags]] diff key-by-key and
flag-by-flag, this file diffs **whole capabilities** — the things a user would name when
asked what WSL can do. A feature can be fully "covered" at the key level and still be
missing as a feature, because a key with no explanation, no gating and no verification is
not a usable capability.

- **Documented side:** `microsoftdocs/wsl@8842def (2026-07-30)`.
- **App side:** all of `lib/`.

## Summary

| # | Feature | Documented in | App state | Verdict |
|---|:---|:---|:---|:---|
| F-1 | Mirrored networking | `networking.md:120-200`, `wsl-config.md:242` | key present, unexplained, ungated | **outdated** |
| F-2 | DNS tunnelling | `networking.md:152-160`, `troubleshooting.md:335` | 3 keys present, dependency ungated | **outdated** |
| F-3 | Sparse VHD | `wsl-config.md:264` + `--manage --set-sparse` (H) | half — the `.wslconfig` half only | **missing** (the reclaim half) |
| F-4 | `wsl --manage` (disk resize, move, sparse, default user) | `disk-space.md:48-58` + `--help` | absent | **missing** |
| F-5 | WSL Settings app | **no page exists** — one callout at `wsl-config.md:216` | not mentioned | **missing** — see the caveat |
| F-6 | systemd | `systemd.md`, `wsl-config.md:46-57` | toggle present, no distro-default awareness | **outdated** |
| F-7 | WSL plugins | `wsl-plugins.md` | absent | **missing, low priority** |
| F-8 | Custom distro distribution (`.wsl` files, `wsl-distribution.conf`) | `build-custom-distro.md`, `use-custom-distro.md` | absent | **missing** |
| F-9 | WSL version awareness | `basic-commands.md:113-119`, `systemd.md:30` | absent | **missing, enabling** |
| F-10 | "Changes need a restart" (the 8-second rule) | `wsl-config.md:20-26` | partial | **outdated** |
| F-11 | Disk space management | `disk-space.md` | absent | **missing** |

---

## F-1 — Mirrored networking

**Documented.** `networkingMode=mirrored` (`wsl-config.md:242`, `networking.md:125`) is a
whole networking architecture, not a value: it changes localhost semantics, makes
`localhostForwarding` **ignored** (`wsl-config.md:305`), enables IPv6, and unlocks two
dependent `[experimental]` keys (`ignoredPorts`, `hostAddressLoopback`). Floor: Win 11
22H2. `troubleshooting.md:305` still calls it experimental — a contradiction inside the
same commit.

**App.** One free-text box (`settings_screen.dart:1098`) whose tooltip is the bare value
list `"nat, bridged, mirrored, virtioproxy, or none."` (`en.json:233`). Typing `mirrored`
changes nothing else in the UI: `localhostForwarding` stays enabled and unmarked,
`ignoredPorts` and `hostAddressLoopback` stay editable in the Experimental expander with
no indication that they do nothing in NAT mode, and `dnsProxy` — NAT-only — stays
editable in mirrored mode.

**Verdict: outdated.** The key is covered; the feature is not. Wiring is a combo box plus
four enable/disable rules already enumerated in [[wslconfig-keys]] CC-6.

[[runtime]] R-5 confirms mirrored mode works on the test machine and is worth knowing when
sizing this: `networkingMode=mirrored` moved `eth0` from `172.26.21.255/20` (NAT) to the
host's own LAN address `192.168.3.82/24`. The feature is real, available on a 2.6.x
baseline, and immediately visible to a user — which is what makes the un-wired dependants
above misleading rather than merely incomplete.

## F-2 — DNS tunnelling

**Documented.** `dnsTunneling` (default `true`, `[wsl2]`) plus two dependants:
`bestEffortDnsParsing` and `dnsTunnelingIpAddress`, both requiring it. It is the
documented fix for the most-reported WSL networking failure —
`troubleshooting.md:335` ("DNS is not resolving").

**App.** All three keys render (`settings_screen.dart:1106`, `:1134`, `:1138`). The
tooltip for `dnsTunneling` is `"Changes how DNS requests are proxied from WSL to Windows."`
— literally true, useless as guidance, and it does not say the key defaults to on. The two
dependants are not gated. `dnsTunnelingIpAddress` has no placeholder showing the
documented default `10.255.255.254`.

**Verdict: outdated.**

> Note for Phase 05, from the working inventory: `troubleshooting.md` (lines 305/315/335)
> still tells users to put `networkingMode`, `autoProxy` and `dnsTunneling` under
> `[experimental]`, while `wsl-config.md` has them under `[wsl2]`. The app writes them to
> `[wsl2]` (`settings_screen.dart:271-286` — the hardcoded `experimentalKeys` list
> correctly excludes all three), so the app agrees with the reference page.
>
> **Corrected by [[runtime]] R-5.** This note originally justified a tooltip line on the
> grounds that a `[experimental]` spelling would be ignored. It is not: WSL 2.6.3.0 accepts
> those four keys under **either** section, confirmed both by the absence of an unknown-key
> diagnostic and behaviourally. They are the only keys with dual-section acceptance — every
> other misplaced key in the same probe was rejected outright ([[runtime]] R-4). The tooltip
> is still defensible as "your file will not match the docs", but that is a much weaker
> reason. **Do not size a Phase 05 item on the ignored-setting claim.**

## F-3 — Sparse VHD

**Documented, as two distinct controls that are easy to confuse:**

| Control | Scope | Source |
|:---|:---|:---|
| `[experimental] sparseVhd = true` | **newly created** VHDs only | `wsl-config.md:264` |
| `wsl --manage <Distro> --set-sparse <true\|false>` | an **existing** distro's VHD | `wsl.exe --help` (H — undocumented upstream) |

**App.** Only the first (`settings_screen.dart:1130`). Its tooltip — `"When set to true,
any newly created VHD will be set to sparse automatically."` — is accurate and does carry
the "newly created" qualifier, which is better than most.

**Verdict: missing** (the `--set-sparse` half). This is the one users actually want: "my
distro's ext4.vhdx is 80 GB and the distro holds 12 GB." Disk reclamation for existing
distros is not reachable from the app at all.

## F-4 — `wsl --manage`

The whole WSL 2.5+ verb is absent. Detailed in [[cli-flags]] CC-2, with a per-option
table. The headline consequence: `WSLApi.move` (`wsl.dart:1649-1790`) implements
"move a distro" as export → unregister → import, a destructive three-step guarded by a
size floor and a prefs recovery marker, where `wsl --manage <D> --move <Location>` does it
natively.

**Verdict: missing**, largest single feature gap in the audit.

## F-5 — The WSL Settings app

**Caveat first, because the Phase 04 brief assumed otherwise: there is no WSL Settings
page in the docs clone.** Not in `WSL/toc.yml`, not as a file. The entire coverage is one
callout:

> `wsl-config.md:216` — "It is recommended to modify WSL configurations directly in WSL
> Settings…"

**App — correction from [[verification]] V-8: the name is already taken, by this app, for
something else.** `wslsettings-text` = `"WSL Settings"` (`en.json:134`) is the header of the
**per-distro `wsl.conf` editor** (`settings_dialog.dart:291`). So the app ships a screen
called "WSL Settings" that edits `/etc/wsl.conf`, while Windows now ships a Start-menu app
called "WSL Settings" that edits `%UserProfile%\.wslconfig` — the file this app edits on a
*different* screen (`settings_screen.dart`'s Global Configuration expander). Microsoft's
product is not referenced anywhere; the collision is accidental.

Any Phase 05 work here has to rename one of the two first, which cuts both ways: it makes
F-5 cheaper than "integrate with a Microsoft app" implies, and more urgent than its
placement in this table implies — a user told to "open WSL Settings" cannot tell which one
is meant.

**Verdict: missing**, but the *content* of the finding cannot be sourced from the docs
clone. Microsoft now ships a first-party GUI that edits the same `.wslconfig` this app's
Settings screen edits, which raises two questions this audit cannot answer from its
sources:

1. Which keys does WSL Settings expose, and how (widget types, gating)? That is the
   natural benchmark for [[wslconfig-keys]]'s widget-type findings.
2. Does concurrent editing conflict — WSL Settings and this app both writing
   `%UserProfile%\.wslconfig` — given the parser defects in [[wslconfig-keys]] CC-2/CC-3?

Both need the shipping app or the `microsoft/WSL` repo, neither of which was consulted.
**Recorded as an open item, not as a resolved finding.** Do not let Phase 05 cite
`wsl-config.md` for a WSL Settings claim; the page does not exist.

## F-6 — systemd

**Documented.** `[boot] systemd = true`, WSL 0.67.6+, Win 11 / Server 2022; requires
`wsl --shutdown` to take effect (`wsl-config.md:57`); the default is **distro-dependent** —
current Ubuntu ships it on, most others off (`systemd.md:12/24`). It has no row in the
`[boot]` reference table; it exists only in prose.

**App.** A `ToggleSwitch` at `settings_dialog.dart:301`, labelled `"Systemd"` with no
description. Three problems, all inherited from [[wslconf-keys]]: the switch shows **off**
for a distro whose `wsl.conf` has no `[boot]` section even when systemd is on by default;
there is no restart prompt; and the writer defect (CC-1/CC-2) applies.

**Verdict: outdated.** Worth noting the app is *ahead* of the reference table here — it
ships the key Microsoft's own `[boot]` table omits.

## F-7 — WSL plugins

`wsl-plugins.md` documents a plugin API (and `wsl --debug-shell` for inspecting it).
Nothing in `lib/` references plugins. **Verdict: missing, low priority** — this is a
developer-extension surface, not something a distro manager's users ask for.

## F-8 — Custom distro distribution

**Documented.** `build-custom-distro.md` and `use-custom-distro.md` describe a complete
modern packaging path: a `.wsl` file, installed with `wsl --install --from-file <Path>` or
by double-click, whose behaviour is governed by `/etc/wsl-distribution.conf` — sections
`[oobe]` (`command`, `defaultUid`, `defaultName`), `[shortcut]` (`enabled`, `icon`),
`[windowsterminal]` (`enabled`, `profileTemplate`).

**App.** Creates distros from `.tar.gz` rootfs URLs (`distroRootfsLinks`, `images.json`),
Docker images, and `.vhdx`, always via `wsl --import`. No `.wsl` support, no
`--install --from-file`, no `wsl-distribution.conf` reading or writing. Consequences the
docs make explicit: an `--import`-created distro has **no launcher executable**, which is
why `<distro> config --default-user` cannot work for it (`basic-commands.md:152`) — the
root cause of [[wslconf-keys]] CC-6 — and no Start-menu shortcut or Windows Terminal
profile, both of which `wsl-distribution.conf` would provide.

**Verdict: missing.** This is the largest *net-new* surface in the audit and the one that
would most change what the app is: a template/export feature already exists
(`lib/api/templates.dart`, `lib/screens/template_screen.dart`), and exporting a template
as a `.wsl` file with an `[oobe]` block is the natural extension of it.

## F-9 — WSL version awareness

Detailed in [[cli-flags]] CC-1. Neither `wsl --version` nor `wsl --status` is invoked
anywhere in the app, so no version floor from any of the three inventories can be
enforced, and the inbox-vs-Store distinction (`systemd.md:30`) is invisible to the app.

**Verdict: missing, and enabling** — F-1, F-3, F-4 and every version-gated key in
[[wslconfig-keys]] depend on this existing first.

[[runtime]] adds a caveat that changes the shape of this item. R-2: on WSL 2.6.3.0 every
flag [[cli-flags]] marks **H** is present, so a single "is this 2.x?" check unlocks the
whole surface — the gating is coarse, not per-flag. R-1: version is not always the right
question. `nestedVirtualization` is refused by the host CPU regardless of version, and the
only signal is a stderr line WSL prints on every VM start. Reading WSL's **output** is
therefore worth as much as reading its version, and costs the same plumbing.

## F-10 — "Changes need a restart" (the 8-second rule)

**Documented.** `wsl-config.md:20-26`: a distro must be fully stopped for at least 8
seconds before config changes apply. Restated for `.wslconfig` (`:213`), for
`automount.options` (`case-sensitivity.md:112`) and for `boot.systemd` (`:57`). Check with
`wsl --list --running`; force with `wsl --terminate <distro>` or `wsl --shutdown`.

**App — genuinely partial, in both directions.**

| Surface | State |
|:---|:---|
| Global `.wslconfig` screen | **covered** — `globalconfigurationinfo-text` states the requirement, and a **Stop WSL** button (`settings_screen.dart:168-185`) calls `restart()`, which runs `wsl --shutdown` twice (`wsl.dart:1169-1170`). Blemish: Save does not offer the restart, and the English string has a stray comma ("Build 19041 and ,later") |
| Per-distro `wsl.conf` dialog | **missing** — no statement, no `wsl --terminate` button, and each write fires immediately (per keystroke for text fields). See [[wslconf-keys]] CC-5 |

**Verdict: outdated** overall — the requirement is documented for both files and surfaced
for only one.

**Measured** ([[runtime]] R-11, R-12). Both halves reproduce, and both are silent:

| File | Change applied without a restart? | Any warning? | Restart needed |
|:---|:---|:---|:---|
| `.wslconfig` (`networkingMode`) | no — the running VM kept the old value | none | `wsl --shutdown` |
| `wsl.conf` (`network.hostname`) | no — the running distro kept the old hostname | none | `wsl --terminate <distro>` only |

The scope difference is the actionable part: the per-distro dialog needs only
`--terminate`, so its fix is cheaper than the global screen's. R-11 also finds that the
docs' own hedge is wrong — `wsl-config.md:213` says you "may need to" restart, and the app
faithfully copies that, but on this build no `.wslconfig` key applies without one.

## F-11 — Disk space management

`disk-space.md` is a whole documented workflow: check usage from the system distro
(`wsl --system df -h /mnt/wslg/distro`), expand with `wsl --manage <D> --resize <Size>`
(decimals unsupported — `2.5TB` is invalid), cap growth with `[wsl2] defaultVhdSize`.

**App.** Only the third exists (`settings_screen.dart:1114`, plain text box). No usage
display, no resize, no `--system` invocation, no reclaim. `grep -rni "resize" lib/` finds
only a window-resize handler. The app reads `ext4.vhdx` file sizes directly for its
`move()` safety floor (`wsl.dart:1743-1757`), so the plumbing to *display* usage is
half-built already.

**Verdict: missing.** Pairs naturally with F-3's `--set-sparse` — "your VHD is 80 GB, the
distro uses 12 GB, reclaim it" is one feature, not two.

---

## What was not examined

- **Nothing in this file was verified at runtime.** No `wsl --version`, no key written and
  observed, no feature exercised. Every "app state" claim is read from source; every
  "documented" claim is read from the clone.
- **F-5 is deliberately unresolved.** The WSL Settings app was not launched, and neither
  the shipping binary nor the `microsoft/WSL` repo was consulted. Its findings are open
  questions, not conclusions.
- **`microsoft/WSL` release notes** were not read, so the introduction version of every
  **H** flag (`--set-sparse`, `--move`, `--set-default-user`) is unknown beyond
  `--manage`'s documented 2.5+ floor.
- **User complaints and open GitHub issues were not consulted** *when this file was
  written*. The mapping has since been done by the classification task — see [[index]],
  *Evidence — findings mapped to reported issues*, which matches 183 issues against these
  findings and confirms every tier-0 and tier-1 item has at least one report behind it.
  The impact language in this file is still this audit's judgement; the evidence table is
  where the users' own words are.
- **WSL 1 behaviour.** The app targets WSL 2 throughout; documented WSL 1-only behaviour
  (`automount.options case=force`, `--set-version 1`) was noted but not pursued.
- **Feature surfaces outside the brief's list** — GPU compute, USB/IPP passthrough
  (`connect-usb.md`), WSL containers (`wsl-container.md`), enterprise/Intune policy
  (`enterprise.md`, `intune.md`) — were read only far enough to confirm they are out of
  scope for a distro manager. Intune deserves one line: on a managed machine the
  `*UserSettingConfigurable` policy family can lock any `.wslconfig` key to its default
  (`intune.md:41-43`), which would make this app's writes silently ineffective. The app
  has no way to detect that.
