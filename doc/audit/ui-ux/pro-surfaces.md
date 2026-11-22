---
type: analysis
title: UI/UX Audit -- Pro Surfaces
created: 2026-08-28
tags:
  - ui
  - ux
  - audit
  - phase-07
  - pro
  - licensing
  - ai-workspace
  - mcp
related:
  - '[[index]]'
  - '[[list-and-navigation]]'
  - '[[create-and-install]]'
  - '[[settings-and-tools]]'
  - '[[interaction-and-a11y]]'
  - '[[theme-and-locales]]'
---

# Pro surfaces

The AI Workspace screen (`lib/screens/ai_workspace_screen.dart`), the licence screen
(`lib/screens/license_screen.dart`), the two badge components
(`lib/components/pro_badge.dart`, `lib/components/beta_badge.dart`), the AI chat panel
(`lib/components/ai_chat_panel.dart`), the recommendations panel
(`lib/components/recommendations_panel.dart`), the AI diagnosis helper
(`lib/components/ai_diagnosis.dart`), and the Pro half of the MCP server surface
(`lib/screens/settings_screen.dart:715-830`).

Walked live under the run configuration in [[index]] -- debug build, `en`/light, 1400x860
with a narrow 900x860 pass. **This is the one pass that had to be run twice**: once with
`--dart-define=WSLM_FORCE_PRO=true` for the Pro surfaces and once *without* it, because
"how Pro gating is communicated to a free user" is not observable from the Pro build.
Four launches in total (Pro, Pro + seeded state, free, free + forced list error).
**46 findings (PS-01..PS-46)**, plus a verified-pass list at the end.

Six claims in this pass are **measured rather than reasoned about**:

- Three real tool lifecycles were driven end to end against the host's `ai-workspace`
  distro -- OpenClaw started, its dashboard opened, Open WebUI started through its health
  gate, and **Hermes Agent was installed from scratch (6 minutes) and uninstalled again**
  -- so install progress, `starting`, `running` and the busy states are captured from
  actual runs, not from reading the widget tree.
- Every status badge and disabled-button label was sampled per pixel for contrast.
- The install progress line was pixel-diffed across three captures to show it freezes.
- The "your question was discarded" claim was verified by re-opening the panel and
  reading the input back.
- The recommendations panel's dismiss button was proved to write to
  `shared_preferences.json` while changing nothing on screen.
- `AiService.generateScript()` and `RecommenderService._addAiPoweredRecommendations()`
  were grepped for call sites across all of `lib/` before being called unimplemented.

**Host state was restored and re-verified.** `Hermes Agent` was uninstalled through the
UI back to `Not Installed`; OpenClaw and Open WebUI were both stopped again; and
`shared_preferences.json` was restored from `%TEMP%\wslm-prefs-p07-pro.json`, with
`UseRemoteWSL`, `RemoteWSLTarget`, `DockerImageCount`, `HasServiceError` and
`DismissedRecommendations` confirmed absent and all three `AiWorkspaceStatus_*` keys back
to their pre-audit values (`notInstalled`, `stopped`, `stopped`).

Screenshots referenced by filename only; they live in `.maestro/screenshots/phase-07/`
and are **gitignored**. Severity: **blocker** / **major** / **nit**. Effort: **S** (under
an hour), **M** (half a day), **L** (a day or more).

## Findings

### What the Pro purchase promises

#### PS-01 -- The purchase screen sells two features that no UI in the app reaches

**blocker / L** -- `lib/screens/license_screen.dart:248-255` -- `172-free-license.png`

The Compare Plans table lists six rows and puts a ✓ in the Pro column for five of them.
Two of those five have no user-reachable implementation:

| Row | Backing code | Call sites in `lib/` |
|:---|:---|:---|
| `script-generation-feature` -- "Script Generation *" | `AiService.generateScript()` (`ai_service.dart:207`) | **none** |
| `smart-recommendations-feature` -- "Smart Recommendations *" | `RecommenderService._addAiPoweredRecommendations()` (`recommender_service.dart:85-88`) | called, but the method body is `// For now, this is a placeholder for future implementation` |

`grep -rn "generateScript" lib` returns exactly one line: the declaration. There is no
button, menu item, dialog or shortcut anywhere in the app that invokes it.

The Smart Recommendations row is worse than absent. The non-AI half of the recommender
*does* render -- and renders untranslated i18n keys (PS-33). So the feature the table
marks Pro-only is a no-op, and the free part of the same feature is visibly broken.

This is a one-time paid purchase and this table is the pitch. Fix: either implement the
two features or remove the rows. Do not ship a paid comparison table containing claims
the binary cannot satisfy.

#### PS-02 -- The purchase screen never shows a price

**blocker / S** -- `lib/screens/license_screen.dart:202-243` -- `172-free-license.png`

"Get Pro", "Buy once on the Microsoft Store", "One-time purchase, no subscription",
"No subscription, free updates", a full-width **Get it on the Microsoft Store** button,
and a six-row feature table. Nowhere on the screen, in any string, is there a number.

The user has to leave the app and load a Store page to learn what the one thing this
screen is asking them to do costs. Every other objection the copy anticipates is answered
inline; the first one anybody actually has is not.

#### PS-03 -- Comparison-table verdicts are icon-only, and the "not included" mark is 1.85:1

**major / S** -- `lib/screens/license_screen.dart:258-265` --
`172-free-license.png`, `172b-license-table-zoom.png`

`cell(bool included)` is a bare `Icon`, with no `Semantics` label and no text. A screen
reader reading this table gets six feature names and twelve unlabelled glyphs.

Sampled per pixel out of `172-free-license.png`:

| Glyph | Colour | Background | Ratio |
|:---|:---|:---|---:|
| ✗ "not in Free" (`disabledTextColor`) | `#BCBCBC` | `#FCFCFC` | **1.85:1** |
| ✓ "in Pro" (accent) | `#3E98DE` | `#FCFCFC` | **3.03:1** |

Ten of the twelve cells are the ✗. The mark that carries the whole argument for upgrading
is the least visible thing in the table, and at 14px it is under even the 3:1 threshold
for non-text UI. The ✓ lands exactly on 3:1 with nothing to spare.

Fix: give each cell a `Semantics(label: ...)`, and use a real foreground colour for the
✗ rather than the disabled-text colour -- "this plan does not include it" is information,
not a disabled control.

#### PS-04 -- The Pro user's licence screen is a header, one card, and 600px of nothing

**major / S** -- `lib/screens/license_screen.dart:74-81` -- `144-license-pro.png`

`_buildComparisonTable()` lives inside `_buildStoreSection()`, and `_buildStoreSection()`
is only built in the `else` branch. So the feature list -- the only place in the app that
enumerates what Pro is -- is shown exclusively to people who have not bought it. The
person who paid gets "Pro Plan / Bought once in the Microsoft Store. All Pro features are
unlocked, updates included." and 600px of empty page.

The header subtitle is also still `store-buy-info-text`: "One-time purchase, no
subscription. Open source forever." -- a sales line, shown to someone who has already
bought.

Fix: render the comparison table for both plans (the Pro column simply becomes a
checklist of what is active), and swap the header subtitle for something addressed to an
owner.

#### PS-05 -- No restore-purchase path and no support link if entitlement detection fails

**major / M** -- `lib/api/license_manager.dart:62-84`, `license_screen.dart:74-81` --
source-derived

`isPro` is `_storeLicensed`, and `_storeLicensed` is the return of a single
`GetCurrentPackageFullName` probe. There is no key, no account, no server, and -- by
design -- nothing to re-check. That is a defensible architecture, but it leaves the UI
with no answer for the case where the probe is wrong: a customer who bought the app and
is shown the Free Plan card has, on that screen, exactly one control, and it is
**Buy**. No "I already bought this", no "check again", no support or contact link, and no
diagnostic text saying what was detected.

`_loadStatus()` does call `LicenseManager().init()` on entry, so the check *is* redone --
but silently, with no affordance and no way to see the result.

Not screenshotted: producing a false negative means running a packaged MSIX build, which
is out of scope for this click-through (see [[index]]).

#### PS-06 -- The nav item says "Upgrade to Pro"; the page it opens is titled "License"

**nit / S** -- `lib/nav/panelist.dart:96-101`, `license_screen.dart:120` --
`171-free-home.png`, `172-free-license.png`

The footer entry swaps its label on licence state, but the screen's own `titleLarge` is
always `license-text`. A free user clicks "Upgrade to Pro" and lands on a page headed
"License". Fix: switch the heading with the same condition, or title the page for the
task rather than the object.

#### PS-07 -- The store button is the app's only `canLaunchUrl`-gated launch

**nit / S** -- `lib/screens/license_screen.dart:40-45` -- verified passing on this host

`_openStorePage()` wraps `launchUrl` in `if (await canLaunchUrl(uri))`, so if the gate
returns false the button silently does nothing -- no toast, no fallback, no log. This is
precisely the failure the codebase has already diagnosed and worked around everywhere
else; `ai_workspace_screen.dart:542-545` spells it out:

> No canLaunchUrl gate: on Windows it reports false for perfectly launchable http URLs,
> which is what made a healthy dashboard look unreachable. Every other launch site in
> this app calls launchUrl directly for the same reason.

**Measured, and it passed here**: clicking the button spawned a new `msedge` process
within the second and opened the Store product page (the browser window that appeared is
titled "WSL Manager – Herunterladen und Installieren unter Windows | Microsoft Store").
So this is a latent risk on other machines, not a live break -- recorded as a nit for
consistency rather than as a defect. Secondary note: the URL is the `https://` web page,
not `ms-windows-store://pdp/?productid=9NWS9K95NMJB`, so the purchase takes an extra hop
through the browser.

### How gating is communicated

#### PS-08 -- The three components built to communicate Pro gating are dead code

**major / S** -- `lib/components/pro_badge.dart:6-174` -- source-derived

`ProBadge`, `ProFeatureWrapper` and `UpgradePrompt` are 174 lines whose entire purpose is
to mark and explain gated surfaces consistently. `grep -rn "ProBadge\|ProFeatureWrapper\|
UpgradePrompt" lib` returns matches only inside `pro_badge.dart` itself.

Every real gate therefore invented its own treatment:

| Gate | Treatment |
|:---|:---|
| AI Workspace page | full-page paywall with its own icon, copy and button (`ai_workspace_screen.dart:359-408`) |
| BYOK settings | `InfoBar` + three `enabled: false` `TextBox`es (`settings_screen.dart:647-707`) |
| MCP settings | `InfoBar` + an *enabled-looking* toggle that navigates away (PS-11) |
| AI chat panel | no notice at all; the panel is simply not reachable (PS-24) |
| AI diagnosis | a toast, after the fact (`ai_diagnosis.dart:13-16`) |
| Nav footer | amber "NEW" `infoBadge` (PS-09) |

Six gates, six different vocabularies. Fix: either adopt the three existing components or
delete them -- but pick one gate vocabulary either way.

#### PS-09 -- Amber means two different things, and both badges are 1.35:1

**major / S** -- `lib/components/beta_badge.dart:7-30`, `lib/nav/panelist.dart:102-124` --
`171-free-home.png`, `171b-free-navfooter-zoom.png`

`#FFBF00` on a 20 %-alpha wash of `#FFBF00` is the app's most-repeated badge treatment:
BETA appears in the nav pane, beside the AI Workspace title, in the AI chat header and
twice in Settings; NEW appears on the licence footer entry. Sampled per pixel:

| Badge | Text | Background | Ratio |
|:---|:---|:---|---:|
| `NEW` (nav footer, free user) | `#FFBF00` | `#F5E8C2` | **1.35:1** |
| `BETA` (nav pane) | `#FFBF00` | `#F5E9C7` | **1.37:1** |

At 8px bold that is not low-contrast text, it is a coloured smudge -- an order of
magnitude under AA and below even the 3:1 non-text floor. `beta_badge.dart`'s own comment
says amber was chosen "so it does not read as [ProBadge]", which makes the second half of
the finding worse: the same amber pill now means "this feature is immature" in five
places and "buy this" in one. Fix: darken the foreground (`#7A5C00` on the same wash
clears AA) and give the upsell badge a different shape or colour from the maturity badge.

#### PS-10 -- In compact nav mode the BETA badge is drawn on top of the AI Workspace icon

**major / S** -- `lib/nav/panelist.dart:52` -- `150-aiws-narrow900.png`,
`150b-compact-betabadge-zoom.png`

Below fluent_ui's 1008px threshold the pane collapses to a 48px icon rail and the
`infoBadge` has nowhere to go, so it renders **over** the robot glyph and clips the blue
selection bar to its left. At 5x (`150b`) the item is an amber rectangle with a robot's
legs poking out of the bottom. The only visual identity the page has in compact mode is
destroyed, and it is destroyed on the *selected* item.

Note this is the correct API choice, not a misuse -- the comment above the line explains
that a `Row` in `title` would leave the pane entry with no accessible name. The fix is to
drop the badge in compact mode (or move it to the item's corner), not to move it back
into the title.

#### PS-11 -- The free user's MCP toggle looks enabled, and clicking it teleports the app

**major / S** -- `lib/screens/settings_screen.dart:744-758` --
`177-free-settings-mcp.png`, `178-free-mcp-toggle-jump.png`

Driven live in the free build. The **Enable WSL MCP server** switch renders as a normal,
fully enabled `ToggleSwitch` -- no grey, no lock, nothing to distinguish it from the
dozens of working switches elsewhere in Settings. Clicking it does not move the switch; it
replaces the entire screen with the licence page. No toast, no dialog, no explanation of
what just happened.

Two things make this worse than an ordinary bad gate:

1. It is a **navigation**, and per ST-01 in [[settings-and-tools]] leaving Settings by any
   route other than **Save** silently discards every pending edit. A free user who typed a
   VS Code command, changed the theme and then poked the MCP switch out of curiosity loses
   all of it.
2. The BYOK section 60px above takes the *opposite* approach -- `enabled: isPro` on all
   three fields -- so the same screen gates two adjacent Pro features with two
   contradictory patterns.

Fix: `enabled: false` on the toggle plus the existing `InfoBar`, matching BYOK.

#### PS-12 -- Disabled BYOK fields explain nothing and read as pre-filled

**nit / S** -- `lib/screens/settings_screen.dart:660-707` -- `176-free-settings-byok.png`

The three `TextBox`es are correctly disabled, but nothing on or beside a field says why:
the `InfoBar` carrying the reason sits 90px above the first label and is 380px wide
against full-width inputs, so it reads as a page-level notice rather than as the caption
for those controls. Their placeholders (`https://api.openai.com/v1`, `sk-...`,
`gpt-4o-mini`) still render at near-normal weight, so at a glance the fields look filled
in rather than locked. Compare ST-10 in [[settings-and-tools]], which measured the same
"disabled control with an unreadable reason" pattern elsewhere on this screen.

#### PS-13 -- The paywall drops the BETA badge the same page carries in the Pro build

**nit / S** -- `lib/screens/ai_workspace_screen.dart:359-408` vs `:459-472` --
`174-free-aiws-paywall.png`, `141-aiws-initial.png`

`_buildPaywall()` renders the title with no `BetaBadge` and no `BetaBanner`; the Pro
build's `build()` renders both. The nav item beside the paywall still shows BETA. So the
one moment the app is asking for money is the one moment it stops saying the feature is
beta, while the navigation two inches to the left keeps saying it. Fix: keep the badge on
the paywall.

#### PS-14 -- The only entry to the Pro AI Assistant is a 48px circle at 1.29:1

**major / S** -- `lib/screens/home_screen.dart:146-172` -- `140-pro-home-1400x860.png`,
`140b-pro-aifab-zoom.png`

The floating toggle is `Colors.grey.withValues(alpha: 0.12)` when the panel is closed.
Sampled: fill `#DEDEDE` against a `#F6F6F6` page -- **1.29:1** for the shape itself, well
under the 3:1 required of a non-text UI component. It carries no label, and its `Tooltip`
only fires on hover. For a Pro user this button is the entire discoverability story for
the AI Assistant, and it is the faintest element on the home screen.

### AI Workspace -- the card lifecycle

#### PS-15 -- One busy flag per tool puts spinners on buttons that are doing nothing

**blocker / M** -- `lib/screens/ai_workspace_screen.dart:630`, `:640`, `:650`, `:692` --
`152-aiws-start-busy.png`, `155-aiws-dashboard-clicked.png`, `169-aiws-uninstall-busy.png`

`isBusy` is a single per-tool boolean, and each of the four buttons decides whether *it*
is the busy one by guessing from the tool's current status. The guesses are wrong, and
three different real operations were captured proving it:

| Operation driven | Buttons that showed a progress ring | Screenshot |
|:---|:---|:---|
| **Start** OpenClaw (`stopped`) | Start ✔ *and* **Uninstall** ✘ | `152` |
| **Open Dashboard** on OpenClaw (`running`) | **Stop** ✘, Open Dashboard ✔, **Uninstall** ✘ | `155` |
| **Uninstall** Hermes (`stopped`) | **Start** ✘ *and* Uninstall ✔ | `169` |

In `155` a user who clicked "open the web UI" is looking at a card whose Stop and
Uninstall buttons are both spinning. That does not read as "fetching a URL"; it reads as
"this tool is being stopped and removed". `_handleOpenDashboard` awaits a WSL command with
up to a 40-second budget, so the card sits like that for a long time.

Compounding it, `_buildAction` swaps the label for a 16px `ProgressRing`, so a busy button
**shrinks** -- Start goes from 55px to 40px and every button to its right slides left
mid-operation, and the user loses the only on-card label saying which action is running.

Fix: track the in-flight operation, not just a boolean (`_busyOp[tool] = Op.start`), spin
only that button, and keep its label beside the ring so the button does not resize.

#### PS-16 -- A tool stuck in "Starting up..." cannot be stopped

**major / S** -- `lib/screens/ai_workspace_screen.dart:637-671` --
`157-aiws-openwebui-start.png`

Captured live while Open WebUI was in its health-gate window. In `ToolStatus.starting`:

- **Install** is disabled and reads "Installed"
- **Start** is disabled (`enabled: state?.status == ToolStatus.stopped`)
- **Stop** is disabled (`enabled: state?.status == ToolStatus.running`)
- **Open Dashboard** is rendered but disabled
- **Uninstall** is the only enabled control on the card

The code's own comment puts Open WebUI's migration window at "~2 minutes", and the
`starting` poll (`_kStartingPoll`) re-probes every 10 seconds indefinitely. A container
that never becomes healthy leaves the card in this state forever, and the user's only way
out of it is to **uninstall the tool**. Fix: enable Stop in `starting` -- stopping
something that is coming up is a legitimate and common thing to want.

#### PS-17 -- The status bar keeps saying "Starting..." long after the tool is running, and three operations later

**major / S** -- `lib/api/ai_workspace/service.dart:1063-1067`, `:1085-1105` --
`157`, `158-aiws-starting-poll.png`, `159-aiws-stopped-restored.png`

Measured end to end on one Open WebUI start:

| t | Card | Status bar |
|---:|:---|:---|
| ~30s | blue dot, "Starting up..." | "Starting Open WebUI..." |
| ~105s | **green dot, "running"**, Stop + Open Dashboard enabled | "Starting Open WebUI..." |
| ~4min (after Stop on Open WebUI **and** Stop on OpenClaw) | both orange, "stopped" | **"Starting Open WebUI..."** |

Two causes, both in the service. First, a health-gated start posts
`'ai-workspace-starting-text'` as its *final* message (`:1063-1067`) -- the same string as
the in-flight loading toast, minus the spinner -- and the 10-second poll that later flips
the card to `running` never touches the status bar. Second, `stop()` posts nothing at all
on either path; the comment at `:1091` states this outright ("Stop has no toast of its
own"). So the stale, wrong message outlives three subsequent user actions.

The card and the status bar also use two different phrasings for one state ("Starting
up..." vs "Starting Open WebUI...").

#### PS-18 -- A six-minute install has no cancel, and its one progress signal freezes

**major / M** -- `lib/screens/ai_workspace_screen.dart:600-618`, `:624-631` --
`164-aiws-install-progress-15s.png`, `165`, `165b-install-progress-zoom.png`, `166`, `167`

Hermes Agent was installed for real. It took **six minutes**. The card's only progress
signal is the newest line the installer wrote, repainted once a second. Pixel-diffed over
the same 400x16 region:

| Interval | Pixels changed |
|:---|---:|
| 15s → 60s | 1307 of 6400 |
| **60s → 180s** | **0 of 6400** |

For two full minutes the line read `→ Installing Node.js dependencies (browser tools)...`
and did not move. The card offers nothing else: no elapsed time, no step count, no byte
counter, no percentage. The code comment at `:600-603` says the line exists because
"without this the card is a bare spinner: a stall and steady progress look exactly alike"
-- and with a line that can sit still for a third of the run, they still do.

There is no cancel. During the install, Install is a spinner and Start, Stop and Uninstall
are all disabled, so a hung `curl | bash` inside WSL can only be escaped by killing the
app. Fix: add an elapsed-time counter beside the line (cheap, and a frozen line next to a
ticking clock is unambiguous), and give the install a cancel that kills the WSL child.

#### PS-19 -- The badge contradicts the card for the whole install

**major / S** -- `lib/screens/ai_workspace_screen.dart:551-560` --
`165-aiws-install-progress-60s.png`

Throughout the six-minute install the status pill read **"Not Installed"** and the dot
stayed black, directly above a live spinner and streaming installer output. `isChecking`
gets its own badge substitution (`:556-559`) but `isInstalling` does not, so the one
element on the card whose job is to say what state the tool is in says the wrong thing for
the entire operation. Fix: render an "Installing" badge while `_service.isInstalling(tool)`.

#### PS-20 -- Two of the four status badges fail AA

**major / S** -- `lib/screens/ai_workspace_screen.dart:723-747` --
`141c-aiws-badges-zoom.png`, `154-aiws-start-final.png`, `157`

`_statusBadge` paints the label in the status colour on that same colour at 10 % alpha.
Sampled per pixel from live captures of each state:

| Badge | Text | Background | Ratio | AA (4.5:1) |
|:---|:---|:---|---:|:---|
| `Not Installed` | `#323130` | `#E7E7E7` | 10.50:1 | pass |
| `running` | `#107C10` | `#E4EEE4` | 4.51:1 | pass, barely |
| `Starting up...` | `#0078D4` | `#E2EEF7` | **3.84:1** | **fail** |
| `stopped` | `#F7630C` | `#FBECE3` | **2.70:1** | **fail** |

`stopped` is the badge two of the three cards wear at rest, i.e. the most-shown state in
the feature, at 2.70:1. Fix: keep the tint background and darken the foreground per
status, or drop the tint and use the theme's text colour with a coloured dot.

#### PS-21 -- Disabled button labels are white on grey: 1.71:1

**major / S** -- `lib/screens/ai_workspace_screen.dart:712-724` --
`141b-aiws-card-zoom.png`

`_buildAction` returns a `FilledButton`, and a disabled `FilledButton` in this theme keeps
its white foreground on a `#C6C6C6` fill. Sampled inside the "Start" glyphs at y=316:
alternating `#FFFFFF` and `#C6C6C6` -- **1.71:1**.

At least two of the three action buttons are disabled in every single card state, so most
of the button text on this screen is at 1.71:1 at all times. Fix: disabled buttons should
use a dark disabled foreground, not the enabled white one -- or use `Button` rather than
`FilledButton` for the non-primary actions.

#### PS-22 -- "Installed" is a permanently disabled button that repeats the badge beside it

**major / S** -- `lib/screens/ai_workspace_screen.dart:620-631` -- `141-aiws-initial.png`

Once a tool is installed, the first button in the row becomes a dead control labelled
"Installed" -- a status, rendered as a button, sitting 950px from a status pill that says
the same thing, taking a third of the action row and rendered at the 1.71:1 of PS-21. It
can never be pressed again except in the `error` case, where it correctly becomes "Retry".

Fix: hide the button when `!canInstall` (Retry brings it back), or make the row
Start / Stop / Open Dashboard and move Install into the empty state.

#### PS-23 -- On a running tool, Stop is the primary button and Open Dashboard is not

**major / S** -- `lib/screens/ai_workspace_screen.dart:644-682` --
`154-aiws-start-final.png`

When a tool comes up, **Stop** becomes the only accent-filled button on the card and
**Open Dashboard** renders as a plain outline `Button` beside it. The visual hierarchy
says the main thing to do with a running AI tool is to stop it. Fix: promote Open
Dashboard to the `FilledButton` and demote Stop.

#### PS-24 -- The `notInstalled` dot renders near-black and reads as a bullet

**nit / S** -- `lib/screens/ai_workspace_screen.dart:740-746` -- `141-aiws-initial.png`

`_statusToColor` falls through to `Colors.grey`, which fluent_ui resolves to `#323130`
(sampled at (280,276)). Next to a `subtitle`-weight tool name it is indistinguishable from
a list bullet, and it is *darker* than the running (`#107C10`) and stopped (`#F7630C`)
dots -- so the state that means "nothing here" is the most visually assertive of the four.

#### PS-25 -- Three casing conventions in one badge column

**nit / S** -- `lib/i18n/en.json` (`notinstalled-text`, `startingup-text`, `running-text`,
`stopped-text`) -- `141-aiws-initial.png`

Stacked vertically on one screen: **"Not Installed"** (Title Case), **"Starting up..."**
(Sentence case), **"running"** and **"stopped"** (lowercase). Two of the four also carry
an ellipsis and two do not. Pick one convention -- the same four keys are reused by the
distro list, so the fix lands in more than one place.

#### PS-26 -- The install path line is hardcoded English and leaks an internal URI scheme

**nit / S** -- `lib/screens/ai_workspace_screen.dart:562-570` -- `141-aiws-initial.png`

`'Installed: ${state!.installPath}'` is built by interpolation with no i18n key, and the
values it renders are the service's internal `defaultInstallPath` sentinels:
`cmd://openclaw`, `docker://open-webui`, `cmd://hermes`. Neither scheme exists; they are
markers the service uses to remember how a tool was installed. Shown to a user they read
like broken links. Fix: localise the label and map the sentinel to something meaningful
("Running in Docker" / "Installed in the AI workspace distro"), or drop the line.

#### PS-27 -- The uninstall confirmation breaks the app's own destructive-dialog convention

**major / S** -- `lib/screens/ai_workspace_screen.dart:313-343` --
`143-aiws-uninstall-confirm.png`, `168-aiws-uninstall-confirm-hermes.png`

Every other destructive confirmation in the app goes through `dialogs()`
(`lib/dialogs/base_dialog.dart:60-78`) with a **red** submit button --
see `list_item.dart:248-251`, `:374`, `:427` and `settings_dialog.dart:228`, `:282`. The
AI Workspace uninstall builds its own `ContentDialog` with a plain accent-blue
`FilledButton` in the primary slot, so the one screen where "Uninstall" removes a tool
looks less dangerous than the dialog for saving a template.

#### PS-28 -- The uninstall dialog names the tool on a bare line, then says "this tool"

**nit / S** -- `lib/screens/ai_workspace_screen.dart:317-326` --
`143-aiws-uninstall-confirm.png`

The body is `Text(_toolName(tool))`, an 8px gap, then "Are you sure you want to uninstall
this tool? This action cannot be undone." The name floats above the sentence like a stray
caption. Fix: one sentence -- "Uninstall OpenClaw? ..." -- which also makes the dialog
title's generic "Uninstall Tool" unnecessary.

#### PS-29 -- The uninstall success toast is built by string concatenation

**nit / S** -- `lib/screens/ai_workspace_screen.dart:351` -- `170-aiws-uninstall-done.png`

`Notify.message('${_toolName(tool)} ${'ai-workspace-uninstall-success'.i18n()}')`, where
the key's value is the fragment "uninstalled successfully". Word order is baked into Dart,
so no locale can move the subject. Every neighbouring message already uses a `%s`
placeholder (`ai-workspace-start-failed-text`, `ai-workspace-install-failed-text`); this
one should too.

#### PS-30 -- The Open Dashboard tooltip repeats the button's own label

**nit / S** -- `lib/screens/ai_workspace_screen.dart:659-680` --
`156-aiws-dashboard-result.png`

In `running` the `Tooltip` message is `ai-workspace-open-dashboard-text` and the button's
visible child is `Text('ai-workspace-open-dashboard-text'.i18n())` -- the identical
string, floating above the identical string. The tooltip is genuinely useful in the
`starting` branch (see the verified passes); in `running` it is noise. Fix: only attach
the tooltip when `starting`.

#### PS-31 -- The page-level failure is unlocalised English wrapping a raw exception

**major / M** -- `lib/screens/ai_workspace_screen.dart:432-448` -- source-derived

```dart
Text('Error loading AI Workspace: $_error'),
```

`_error` is `e.toString()` on whatever `ensureDistro()` threw. Best case that is
`Exception: Failed to create the AI workspace distro: <wsl stderr>`; worst case it is a
`SocketException` or a `TimeoutException` with a Dart stack-frame-ish tail. The prefix is
hardcoded English -- the only string on the entire screen that is -- and the whole thing
is one unstyled centred `Text` with no wrapping constraint, above a **Retry** button that
is the only thing on the page.

**Not screenshotted, and labelled as such.** The state needs `ensureDistro()` to fail.
The remote-WSL trick that reached the list's error branch in [[list-and-navigation]] does
not work here: this service builds its own `ExecutionRequest`s and never sets
`useRemote`, so SSH routing does not apply to it, and the only remaining route is
unregistering the host's real 16.6 GB `ai-workspace` distro. Read from source and listed
in [[index]]'s not-examined section.

#### PS-32 -- A failed stop shows a red error line under an unchanged green badge

**nit / S** -- `lib/api/ai_workspace/service.dart:1090-1105`,
`ai_workspace_screen.dart:574-598` -- source-derived

`stop()`'s failure path assigns `errorMessage` directly instead of calling
`_recordActionFailure`, so `status` stays `running` and `errorSticky` stays false. The
card renders `Error: ...` whenever `errorMessage != null` regardless of status, so the
result is a red error line under a green "running" pill -- and because the failure is not
sticky, the next background probe silently erases the message. Not reproduced: forcing a
`stopCommand` failure means breaking the tool inside the distro.

### The AI chat panel

#### PS-33 -- Sending without an API key throws the user to Settings and discards the question

**blocker / M** -- `lib/components/ai_chat_panel.dart:42-46` --
`146-aichat-typed.png`, `147-aichat-send-no-byok.png`, `148b-aichat-after-return-zoom.png`

Driven live in the Pro build with no BYOK key configured. Typed "How do I enable systemd
in Ubuntu?", pressed **Send**:

1. A toast appears: *"AI Chat needs your own API key. Add it in Settings under 'Bring Your
   Own AI Key'."*
2. The app navigates to Settings **on its own** -- so the message instructs the user to do
   the thing the app has already done.
3. Settings opens with all seven accordions **collapsed**, including "Bring Your Own AI
   Key". The message names a section it did not open.
4. Navigating destroys the panel. Returning Home (`148b`) shows the input back at its
   placeholder: **the typed question is gone.**

`_sendMessage` returns before `_inputController.clear()`, so the text is not deliberately
cleared -- it dies with the widget, which is worse: nobody decided to throw it away.

The `!_license.isPro` branch two lines above (`:36-39`) does the same thing with no
message at all, though it is unreachable in practice (PS-36).

Fix: don't navigate. Show the notice inside the panel with an "Open settings" button,
keep the text, and if navigation is kept, expand the target section on arrival.

#### PS-34 -- The panel gives no hint it cannot work until you have already typed

**major / S** -- `lib/components/ai_chat_panel.dart:136-224` -- `145-aichat-empty.png`

With no API key configured the panel is indistinguishable from a working one: the empty
state invites you to "Ask anything about WSL", the input accepts text, and Send enables
itself as soon as you type. The precondition is only revealed by pressing the button --
and the reveal is PS-33.

Nothing in the panel is a cancel for an in-flight request either (`_isLoading` gates the
Send button but there is no abort), and there is no close control: the only way to dismiss
the panel is the FAB behind it.

#### PS-35 -- Clear-history is an unlabelled, unconfirmed, always-enabled 14px icon

**major / S** -- `lib/components/ai_chat_panel.dart:124-130` -- `145-aichat-empty.png`

A bare `IconButton` with `FluentIcons.delete` at 14px in the panel header. No `Tooltip`,
no `MergeSemantics` (so it has no accessible name -- the pattern
[[settings-and-tools]] records as the house fix in ST-18/ST-40), no confirmation, and it
stays enabled when the history is already empty. One mis-click erases a conversation with
no undo.

#### PS-36 -- The empty-state hint is 3.69:1 and the icon is alpha 0.3

**major / S** -- `lib/components/ai_chat_panel.dart:142-155` --
`145-aichat-empty.png`, `145b-aichat-empty-zoom.png`

Both are hardcoded `Colors.grey` with alpha rather than theme colours. Sampled:

| Element | Colour | Background | Ratio |
|:---|:---|:---|---:|
| "Ask anything about WSL -- configuration, errors, commands." (12px) | `#807F7F` | `#F6F6F6` | **3.69:1** |
| Chat ghost icon (48px, alpha 0.3) | -- | -- | decorative |

It is the only content in an otherwise empty 360px column, and it fails AA. `Colors.grey`
with a fixed alpha is also the dark-mode hazard flagged for [[theme-and-locales]] -- the
same literal is used at `:101`, `:145`, `:152`, `:260` and `:270` of this file alone.

#### PS-37 -- The user's avatar is a plus sign

**nit / S** -- `lib/components/ai_chat_panel.dart:294-298` -- source-derived

`FluentIcons.add` in the user-side message bubble avatar, where the assistant gets
`FluentIcons.chat`. A "+" is the app's icon for *Add an Instance*. Fix: `FluentIcons.contact`.

#### PS-38 -- At 900px the fixed panel takes 40% of the window and the hint touches both edges

**nit / S** -- `lib/screens/home_screen.dart:104`, `ai_chat_panel.dart:138-155` --
`149-aichat-narrow900.png`

The panel is a hard-coded 360px (plus a 1px divider) whatever the window is, so at 900px
the distro list is squeezed to 539px while the chat keeps its full width. The empty-state
`Column` has no horizontal padding, so at that width the hint runs from x=1057 to x=1381
inside a panel spanning 1040–1400 -- 17px of margin on each side, and one character more
would clip.

#### PS-39 -- The panel's own upgrade prompt is unreachable

**nit / S** -- `lib/components/ai_chat_panel.dart:156-162` vs
`lib/screens/home_screen.dart:146` -- `171-free-home.png`

The empty state renders an **Upgrade** button `if (!_license.isPro)`. The only way to open
the panel is the FAB, and the FAB is inside `if (isPro)`. Verified in the free build: no
FAB on the home screen at all, so a non-Pro user can never see the panel or the button
inside it. Either the FAB should be shown to everyone (landing on this upgrade state) or
the dead branch should go.

### The recommendations panel

#### PS-40 -- The panel renders raw i18n keys as its user-facing text

**blocker / S** -- `lib/api/recommender_service.dart:34`, `:46`, `:56`;
`lib/i18n/*.json` -- `160-home-recommendations.png`, `160b-recommendations-zoom.png`

Reproduced live by setting `DockerImageCount = 5` and `HasServiceError = true` and
relaunching. The panel appears at the top of the home screen and reads:

> **Recommendations**
> recommend-docker-template
>   *Go to Templates*
> recommend-systemd

`recommend-docker-template`, `recommend-cleanup` and `recommend-systemd` are the three
keys `RecommenderService.analyze()` emits, and they are **absent from all nine locale
files** -- `grep -l` across `lib/i18n/*.json` returns nothing for any of them. The
`localization` package falls back to echoing the key, so the feature the licence screen
sells as "Smart Recommendations" ships showing its own source identifiers to the user, in
every language.

`scripts/check_translations.dart` does not catch this: it compares the other locales
against `en.json`, and these keys are missing from `en.json` too, so the set is
consistently empty and the gate passes. Worth extending that script to check that every
`.i18n()` key literal in `lib/` resolves in `en.json`.

#### PS-41 -- The dismiss button writes to disk and changes nothing on screen

**major / S** -- `lib/components/recommendations_panel.dart:110-115` --
`161-recommendations-after-dismiss.png`

Measured. Clicked the ✕ on "recommend-systemd"; the row did not move, did not fade and did
not disappear -- the only pixel change was the button's own hover fill. Closed the app and
read the prefs file:

```
flutter.DismissedRecommendations   {recommend-systemd}
```

So the dismissal *was* persisted. `RecommendationsPanel` is a `StatelessWidget`, the
`onPressed` calls a `static` method and never calls `setState` on anything, and the filter
that would hide the row (`:54`) only runs on the next build. To the user the button is
simply dead -- and the natural response is to click it again.

#### PS-42 -- `clearDismissed()` is named for the opposite of what it does, and the action link calls it

**major / S** -- `lib/api/recommender_service.dart:101-108`,
`recommendations_panel.dart:94` -- source-derived

```dart
/// Clear all recommendations (after user acts on them)
static void clearDismissed(String key) {
  final dismissed = prefs.getStringList('DismissedRecommendations') ?? [];
  if (!dismissed.contains(key)) { dismissed.add(key); ... }
}
```

It *adds* to the dismissed list. The doc comment describes a third thing again. Both call
sites in the panel use it -- the ✕ (intended) and the "Go to ..." link (`:94`), which
therefore permanently suppresses a recommendation the moment you follow it, before you
have done anything about it. If the user visits Templates and does not create one, the
suggestion never comes back. Rename to `dismiss()`, and decide deliberately whether
following the link should also dismiss.

#### PS-43 -- The "Go to ..." link is English built by string interpolation

**major / S** -- `lib/components/recommendations_panel.dart:98` --
`160b-recommendations-zoom.png`

```dart
'Go to ${rec.actionRoute == '/templates' ? 'Templates' : 'Settings'}'
```

Three untranslatable English fragments in one expression, in a file where every other
string goes through `.i18n()`. It also hardcodes the assumption that any route which is
not `/templates` is Settings.

#### PS-44 -- Dismissing every recommendation leaves an empty titled box

**nit / S** -- `lib/components/recommendations_panel.dart:19` vs `:54` -- source-derived

`if (recommendations.isEmpty) return const SizedBox.shrink();` runs on the *unfiltered*
list; the `isDismissed` filter runs later, per item, returning `SizedBox.shrink()` for
each. So once the user dismisses all of them the panel still renders: border, padding,
lightbulb and the word "Recommendations", containing nothing. Fix: filter first, then
test emptiness.

#### PS-45 -- The dismiss ✕ chases the label instead of sitting at the right edge

**nit / S** -- `lib/components/recommendations_panel.dart:36-115` --
`160b-recommendations-zoom.png`

The row is `Flexible(Column(...))` followed directly by the `IconButton`, with no
`Spacer`, so the ✕ lands immediately after whatever text the item happens to have --
x=409 on one row and x=369 on the next. On a 1140px-wide panel the two dismiss targets are
40px apart horizontally and neither is anywhere near the right edge, while ~700px of the
row sits empty. The item text is 11px and the link 10px, both below the app's smallest
body size elsewhere.

### Cross-cutting

#### PS-46 -- Success, failure and warning toasts are visually identical

**major / M** -- `lib/components/notify.dart:22-68` --
`167-aiws-install-6min.png`, `170-aiws-uninstall-done.png`, `147-aichat-send-no-byok.png`

`statusBuilder` hardcodes `severity: InfoBarSeverity.info` and then overrides
`InfoBarThemeData.decoration` so that all four severity branches return the same
`AppTheme().backgroundColor.light`. There is exactly one toast appearance in the app.

Captured side by side in this pass, all three rendering as the same neutral panel with the
same blue ⓘ:

- "Hermes Agent installed successfully" (`167`)
- "AI Chat needs your own API key. Add it in Settings under 'Bring Your Own AI Key'." (`147`)
- "Starting Open WebUI..." -- stale and wrong (`158`)

This matters more here than elsewhere because the AI Workspace routes its failures
through this channel and nothing else: `ai-workspace-start-failed-text`,
`ai-workspace-install-failed-text` and `ai-workspace-dashboard-failed-text` are all
`Notify.message` calls with no severity. A failed install and a successful one look the
same. App-wide, so it belongs to [[interaction-and-a11y]] as well; recorded here because
this is where it was measured.

## Verified passes

Recorded so a later regression is visible as a regression.

- **The upsell is genuinely restrained.** Across four launches and every screen in the
  free build there was no interstitial, no modal, no timed prompt and no nagging. The
  persistent upsell is one nav footer entry. `_buildPaywall` is a single centred column
  with one button. This is the right instinct and PS-01..PS-07 should be fixed without
  losing it.
- **A non-Pro user costs nothing.** `initState` (`ai_workspace_screen.dart:71-73`) clears
  `_preparingDistro` and `_checkingTools` and skips `_initService()` entirely when not
  Pro, so opening the paywall touches WSL zero times.
- **The free licence screen leads with the pitch and puts the plan card after it**
  (`license_screen.dart:76-81`), and the order visibly reads better than the Pro layout
  it mirrors.
- **The BYOK and MCP explanatory copy is good.** Both say plainly what the feature does,
  what it does not do, and where the cost falls -- "No AI service is hosted or included --
  you pay your provider directly, or point them at a local model", "Runs locally on this
  machine only". Rare, and worth keeping verbatim.
- **Cached tool status renders instantly with no spinner flash.** Because `main.dart:141`
  warms `AiWorkspaceService` at startup and `seedToolStates()` restores from prefs, the
  page opened straight onto final statuses in every capture (`141` and `142`, taken 700ms
  and 6s after navigating, are pixel-identical). The "Checking status..." state is
  effectively unreachable in normal use -- which is the good outcome, not a defect.
- **The `starting` poll works.** Open WebUI went `starting` → `running` on its own between
  `157` and `158` with no user action, exactly as `_syncStartingWatch` intends. (Only the
  status bar failed to follow -- PS-17.)
- **The install survives navigation.** The service owns install progress, not the page;
  `_syncInstallWatch` re-attaches. Not separately screenshotted but confirmed by the card
  still streaming after the six-minute run.
- **A failed install stays retryable.** `canInstall` includes `ToolStatus.error` and the
  button relabels to "Retry" rather than greying out as "Installed" -- the comment at
  `:621-623` shows this was a deliberate fix, and it is the correct behaviour.
- **The `starting` Open Dashboard button explains why it is disabled.** The tooltip swaps
  to `ai-workspace-startingup-hint-text` -- "The tool is still starting up. Its dashboard
  opens once it is ready." -- translated into all nine locales. This is one of the very
  few disabled controls in the app that says why, and it is exactly what ST-10 asks for
  elsewhere.
- **The uninstall confirmation exists at all**, and Cancel really cancels (`143` → clicked
  Cancel → card unchanged). The styling is wrong (PS-27); the gate is right.
- **`PaneItem.title` is a real `Text` on both licence states** (`panelist.dart:99-101`),
  with the badge in `infoBadge` where fluent_ui can still extract the pane label -- the
  invariant [[list-and-navigation]] raises in LN-24. The compact-mode overlap (PS-10) is a
  rendering consequence, not a violation of it.
- **The AI Workspace page reflows cleanly at 900px** (`150`): cards, buttons and badges
  all fit, nothing truncates, nothing overflows.
- **`prefs.ps1` round-tripped the whole pass.** Four prefs mutations and one restore, with
  the file re-verified as valid BOM-less JSON each time and every injected key confirmed
  gone at the end.

## Not examined

- **The AI Workspace page-level error state** (PS-31) -- see the finding; the service
  never sets `ExecutionRequest.useRemote`, so the remote-WSL trick does not reach it and
  the only other route is unregistering the host's real `ai-workspace` distro.
- **A failed `stop()`** (PS-32) -- would mean deliberately breaking a tool inside the
  distro.
- **`AiDiagnoseButton` / `diagnoseWithAi()`** (`ai_diagnosis.dart`) -- it only renders on
  a distro row that is already in an error state (`list.dart:157`) or on a failed create
  (`create_dialog.dart:476`). An attempt to reach it by pointing `RemoteWSLTarget` at an
  unreachable host was made and abandoned: the SSH connect had not timed out after 2.5
  minutes and the resulting loading state is already recorded as LN-18/LN-20 in
  [[list-and-navigation]]. Its behaviour is read from source: free → the
  `upgrade-prompt-error` toast for 5s with no navigation; Pro without a key → the
  `byok-required-text` toast; Pro with a key → a 30-second toast carrying the model's raw
  answer, which is a poor container for a multi-paragraph diagnosis. Not counted as a
  finding since it was not observed.
- **A real AI chat exchange** -- needs a live OpenAI-compatible key and would send this
  machine's WSL configuration to a third-party endpoint. The markdown rendering of
  assistant replies (`ai_chat_panel.dart:263-277`), the scroll-to-bottom behaviour and the
  `_isLoading` indicator were therefore not observed.
- **The Store purchase flow itself** -- the button was clicked and the Store page
  confirmed to open (PS-07); nothing was bought, and the packaged-MSIX experience where
  `isPro` is genuinely true is out of scope for this click-through (see [[index]]).
- **The MCP server's Pro half beyond the gate** -- the endpoint, token, copy and
  regenerate controls were audited in [[settings-and-tools]] (ST-19..ST-22) under the Pro
  build. This pass only adds the free-user gate (PS-11). The Cloudflare tunnel remains
  untriggered for the reason given there.
- **Dark mode for every surface in this pass** -- deliberately deferred to
  [[theme-and-locales]], which owns the light/dark diff. The hardcoded `Colors.grey`
  literals flagged in PS-36 are the specific input that pass should start from.
