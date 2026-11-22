---
type: analysis
title: UI/UX Audit -- Theme, Locales and Text Quality
created: 2026-08-28
tags:
  - ui
  - ux
  - audit
  - phase-07
  - i18n
  - theme
related:
  - '[[index]]'
  - '[[list-and-navigation]]'
  - '[[create-and-install]]'
  - '[[settings-and-tools]]'
  - '[[pro-surfaces]]'
  - '[[interaction-and-a11y]]'
---

# Theme, locales and text quality

The same screens twice -- light and dark -- and then nine times over, once per shipped
locale. Walked live under the run configuration recorded in [[index]]: debug build,
`WSLM_FORCE_PRO=true`, 1400x860, two real distros (`Ubuntu`, `ai-workspace`).
**18 findings (TL-01..TL-18)**, plus a set of verified passes.

Screenshots are referenced by filename only; they live in
`.maestro/screenshots/phase-07/` and are **gitignored**. Severity: **blocker** /
**major** / **nit**. Effort: **S** (under an hour), **M** (half a day), **L** (a day or
more).

## How this pass was run

**Theme.** Eight screens were captured in light, the in-app Dark Mode toggle was flipped,
and the same eight were captured again (`201-light-*.png`, `202-dark-*.png`). The pairs
were then compared with a purpose-built helper,
`.maestro/playbooks/.../Working/theme-invariant.ps1`, which answers the *opposite*
question to a normal diff: **which pixels are byte-identical across a full light->dark
flip?** Anything that survives the flip unchanged is painted from a hardcoded colour
rather than from the theme, and is therefore a candidate for "invisible in one of the two
themes". That is what produced TL-01, TL-04 and TL-05 -- not looking at the screenshots.

Contrast numbers were sampled per pixel. `contrast.ps1` from the earlier passes assumes
dark text on a light background (it takes the darkest pixel in the region as the glyph),
which in dark mode reports the card fill against itself -- the first run of it returned
`1.03:1` for a pill whose *text* was fine. `contrast2.ps1` was added for this pass: modal
pixel = background, furthest pixel by luminance = glyph. Every dark-mode number below
comes from that one.

**Locales.** The `language` preference is only read at startup, so each locale needs its
own process. `Working/locale-pass.ps1` loops: `prefs.ps1 -StopApp -Set @{language=...}`,
`launch.ps1`, resolve the window, capture home / create / settings. Nine launches,
27 screenshots (`21-<locale>-<screen>.png`), each verified against the launch log's
`Loaded lib/i18n/<locale>.json` line.

The static half is `Working/i18n_audit.dart`, which reads the nine JSON files and the
Dart sources together. It is what turns "some strings look English" into counts.

## Findings

### Theme

#### TL-01 -- The AI Workspace status pill and dot are invisible in dark mode

**blocker / S** -- `lib/screens/ai_workspace_screen.dart:740-746`, `:723-738` --
`202-dark-aiworkspace.png`, `206-dark-hermes-card-zoom.png`,
`206b-light-hermes-card-zoom.png`

`_statusToColor()` ends `return Colors.grey;` for the `Not Installed` state. fluent_ui's
`Colors.grey` is the literal `#323130`, with no theme branch, and it colours both the
leading dot and the status pill's text; the pill's fill is that same colour at
`alpha: 0.1`, which over a dark card is indistinguishable from the card.

Measured on the Hermes Agent card:

| | glyph | background | ratio |
|:---|:---|:---|:---|
| light | `#323130` | `#E7E7E7` | **10.50:1** |
| dark | `#323130` | `#333333` | **1.03:1** |

The dark card carries the title "Hermes Agent" and nothing else -- no dot, no state. A
user in dark mode cannot tell an uninstalled tool from a stopped one except by reading
which buttons happen to be disabled. `206-dark-hermes-card-zoom.png` is a 2x crop of the
whole card row; the pill is simply not in the image.

Found by pixel-identity rather than by eye: `theme-invariant.ps1` reported rows 269..279
(159 px), 414..424 (140 px) and 582..592 (140 px) unchanged across the theme flip -- one
band per tool card, each one a status dot plus its pill.

#### TL-02 -- The AI chat panel's empty state is invisible in dark mode

**blocker / S** -- `lib/components/ai_chat_panel.dart:143-153` --
`203-dark-aichat.png`, `207-dark-chat-emptystate-zoom.png`

The empty state is the only thing in the panel before the first message: a 48px chat
glyph at `Colors.grey.withValues(alpha: 0.3)` and the hint
"Ask anything about WSL -- configuration, errors, commands" at `alpha: 0.6`. Both are
composited over the dark page, and grey-on-dark-grey at 60% is not text.

Measured: brightest glyph pixel in the hint band is `#2E2D2D` against a `#282828`
background -- **1.07:1**. The icon is the same. [[pro-surfaces]] recorded 3.69:1 for the
light-mode hint, which already fails AA; dark takes it to the floor. The 3x crop
(`207`) is the only reason the text is legible in this audit at all.

Three more things in the same file vanish with it: the header and input-area dividers
(`:101`, `:200`, `Colors.grey` at `alpha: 0.2`), the assistant message bubble fill
(`:260`, `alpha: 0.1`) and the code-block decoration (`:270-273`, `alpha: 0.15`). In dark
mode the panel has no visible boundary against the distro list at all -- see `203`, where
the only clue that a 360px panel is open is that the list got narrower.

Fix for both this and TL-01: `secondaryTextColor(context)` and
`disabledTextColor(context)` already exist in `lib/components/helpers.dart:505-512`, and
their doc comment says precisely why -- *"A hardcoded `Colors.grey` is close to invisible
against the dark theme's background"*. The helper is right; twelve call sites in
`ai_chat_panel.dart`, `ai_workspace_screen.dart`, `home_screen.dart`,
`recommendations_panel.dart` and `license_screen.dart` do not use it.

#### TL-03 -- Under the default `ThemeMode.system`, the app hands black text to a dark UI

**major / S** -- `lib/theme.dart:161-163`, `:37`, `:44` -- _measured by probe, not
screenshotted_

`systemTextColor` is:

```dart
Color get systemTextColor {
  return AppTheme.themeMode == ThemeMode.dark ? Colors.white : Colors.black;
}
```

`AppTheme.themeMode` is a static set from the `themeMode` preference, and
`_loadTheme()` (`:18-27`) maps a missing preference to `ThemeMode.system` -- which is what
every user gets until they touch the toggle. `FluentApp` honours `ThemeMode.system` by
following the platform brightness, so a user on Windows dark gets the dark theme *and*
`Colors.black` from this getter.

Measured with a throwaway probe test (deleted afterwards; `git status` lists no test
file):

```
ThemeMode.system -> text=ff000000  bg.normal=fffaf9f8  bg.darkest=ffe1dfdd
ThemeMode.light  -> text=ff000000  bg.normal=fffaf9f8  bg.darkest=ffe1dfdd
ThemeMode.dark   -> text=ffffffff  bg.normal=ff292827  bg.darkest=ff1b1a19
```

`system` is byte-identical to `light`. Black on the app's dark page background
(`#282828`) is **1.42:1**.

Five call sites take the value: `actions_screen.dart:287` and `:293` (a snippet's name
and its `[version]` in the Snippets list), `init.dart:110` and `:122` (the "new version
available" status-bar message), and `create_dialog.dart:641` (the suggestion box's
"no results" text). None reads `FluentTheme.of(context)`, which would be correct in all
five.

Not reproduced on screen: this machine runs Windows in light mode
(`AppsUseLightTheme = 1`), and the OS theme was deliberately not flipped. The getter's
behaviour is measured; the rendering is inferred from it.

#### TL-04 -- The `stopped` status pill fails AA in *both* themes

**major / S** -- `lib/screens/ai_workspace_screen.dart:743`, `:723-738` --
`201-light-aiworkspace.png`, `202-dark-aiworkspace.png`

Same hardcoded-colour mechanism as TL-01, one shade along: `Colors.orange` (`#F7630C`)
on a 10%-alpha wash of itself.

| | glyph | background | ratio |
|:---|:---|:---|:---|
| light | `#F7630C` | `#FBECE3` | 2.70:1 |
| dark | `#F7630C` | `#47382F` | 3.60:1 |

[[pro-surfaces]] recorded the light number; the dark one is new, and the point of
recording it is that dark does **not** rescue it. Both are under AA's 4.5:1, and
`stopped` is the state two of the three tool cards are in most of the time.

#### TL-05 -- The amber BETA pill fails in light and passes in dark -- the inverse of everything else

**major / S** -- `lib/components/beta_badge.dart:10`, `:20-31`;
`lib/nav/panelist.dart:107`, `:115` -- `208-light-beta-pill-zoom.png`,
`209-dark-beta-pill-zoom.png`

`BetaBadge` paints `#FFBF00` text on `#FFBF00` at `alpha: 0.18`. Over white that wash
lands at `#F8ECCA`, which is nearly the text colour; over `#282828` it lands at `#4F4321`,
which is not.

| | glyph | background | ratio |
|:---|:---|:---|:---|
| light | `#FFBF00` | `#F8ECCA` | **1.40:1** |
| dark | `#FFBF00` | `#4F4321` | 5.89:1 |

This is worth stating explicitly because it is the one defect in this pass that a
dark-only review would pass and a light-only review would fail -- and every other
finding here is the other way round. [[pro-surfaces]] measured 1.37:1 for the same pill
in a slightly different spot; the refinement is that the number is **light-mode-only**,
so "make the badge darker" would break the theme that currently works.

The pill exists twice. `panelist.dart:107` and `:115` hardcode the literal `0xFFFFBF00`
again to build a second, visually identical badge for the nav pane's `infoBadge`, instead
of using `BetaBadge.color` -- which is public and declared for exactly this.

#### TL-06 -- The AI Assistant FAB is 1.02:1 against the page in dark

**major / S** -- `lib/screens/home_screen.dart:163-176` -- `202-dark-home.png`,
`201-light-home.png`

The closed-state FAB is a 48px circle filled with `Colors.grey.withValues(alpha: 0.12)`,
bordered `Colors.white.withValues(alpha: 0.1)`. Sampled at the same four points in both
themes:

| | fill | page | ratio |
|:---|:---|:---|:---|
| light | `#DEDEDE` | `#F6F6F6` | 1.25:1 |
| dark | `#292929` | `#282828` | **1.02:1** |

[[pro-surfaces]] recorded 1.29:1 for the light case and called it the AI Assistant's only
entry point. In dark the fill is one step off the page colour; the only thing that makes
the control findable is its `#3F3F3F` border ring, at 1.40:1. The *icon* inside is fine
in both themes (14.55:1 dark, 15.61:1 light) -- it is the affordance that disappears, not
the glyph.

#### TL-07 -- `systemBackgroundColor` is 30 lines of theme code nothing consumes

**nit / S** -- `lib/theme.dart:36-42`, `:132-159` -- _source-derived_

`AccentColor _backgroundColor = systemBackgroundColor;` plus a getter, a setter that
calls `notifyListeners()`, and a 28-line getter that builds two seven-shade `AccentColor`
maps. `grep -rn "backgroundColor" lib/` returns no reader outside `theme.dart` itself.

It carries TL-03's bug too (the `AppTheme.themeMode == ThemeMode.dark` branch, evaluated
once in a field initialiser), so it is dead code that would be wrong if it were revived.
Deleting it is smaller than fixing it.

#### TL-08 -- Card, panel and border greys are written eleven different ways

**nit / M** -- `ai_chat_panel.dart` (8 sites), `home_screen.dart:133`, `:165`,
`recommendations_panel.dart:29`, `license_screen.dart:277`, `:286` -- _source-derived_

`Colors.grey.withValues(alpha: ...)` appears with alphas 0.1, 0.12, 0.15, 0.2, 0.3 and
0.6 across five files -- dividers, card borders, bubble fills and text, each picking its
own number. There is no shared constant, so "make the greys theme-aware" is currently a
thirteen-site edit rather than a one-line one. Two of those sites are TL-01 and TL-02's
root cause; the rest are merely inconsistent.

`recommendations_panel.dart:26-27` shows the shape the fix wants: it *does* branch on
`FluentTheme.of(context).brightness.isDark` for its fill -- and then borders that
correctly-themed fill with a hardcoded `Colors.grey` (`:29`).

### Locales

#### TL-09 -- The Mount Disk dialog is entirely English in six of the eight non-English locales

**blocker / M** -- `lib/i18n/{es,hu,ja,pt,tr,zh_TW}.json` --
`22-zh_TW-mount-dialog.png`

`mount_dialog.dart` renders 40 i18n keys. Counted per locale, how many of those 40 hold a
value byte-identical to `en.json`:

| locale | English strings in the mount dialog |
|:---|:---|
| de | 2 / 40 |
| zh_CN | 1 / 40 |
| es | **37 / 40** |
| hu | **36 / 40** |
| ja | **36 / 40** |
| pt | **36 / 40** |
| zh_TW | **35 / 40** |
| tr | **35 / 40** |

`22-zh_TW-mount-dialog.png` is what that looks like: a modal in a Traditional Chinese app
whose title is "Mount Disk", whose three tabs are "Physical Disk / VHD Image / Unmount",
whose four field labels and five placeholders are English, and whose only translated
string is the Cancel button, 取消 -- sitting directly beside a primary button that says
"Mount".

German and Simplified Chinese have it translated, so this is not "the feature was never
localised" -- it is that six files were filled in from English and never revisited.
See TL-10 for why nothing caught it.

#### TL-10 -- The translation gate is a key-presence check, and the rule that would catch TL-09 already exists

**major / S** -- `scripts/check_translations.dart`, `test/locales_test.dart:244-261` --
_measured_

`dart run scripts/check_translations.dart` **exits 0** on the tree as it stands. It
diffs each locale's key *set* against `en.json` and reports keys that are absent; a key
whose value is the English sentence is present, so it passes. `AGENTS.md` lists it as the
first step of the CI build and the gate before every release.

The rule that would catch it is already written, twenty lines away:

```dart
test('are translated, not copied from English', () {
  ...
  for (final key in auditKeys) {
    // Short labels can legitimately be identical -- "GPU" is "GPU" everywhere.
    if ((english[key] as String).length <= 20) continue;
    expect(translated[key], isNot(english[key]), ...);
```

It is scoped to `auditKeys` -- the ~60 keys a previous documentation audit added.
Applying the identical `length > 20` rule to the whole 542-key set fails on **131
locale-key pairs across 22 distinct keys**; 21 of the 22 are mount-dialog strings and the
22nd is `plan-store` ("Pro (Microsoft Store)"). Per locale: de 1, zh_CN 0, ja 21,
zh_TW 21, es 22, hu 22, pt 22, tr 22.

That is a one-line change to an existing test -- swap `auditKeys` for `english.keys` --
which turns TL-09 into a build failure and keeps it fixed.

#### TL-11 -- Turkish calls a WSL instance an "örnek", which reads as "sample"

**major / M** -- `lib/i18n/tr.json` -- `21-tr-home.png`

Fifteen lines of `tr.json` contain "örnek". **Ten of them translate "instance"**: the nav
entry `addinstance-text` = "Bir Örnek Ekle", `createnewinstance-text` = "Yeni bir örnek
oluştur", `noinstancesfound-text`, `copyinstance-text`, `errorentername-text`,
`creatinginstance-text`, `createdinstance-text`, `createdinstancenouser-text`,
`cleanupbody-text`, `saveastemplatebody-text`.

The other **five use the same word correctly, to mean "sample"**:
`writeoobescript-text` = "Örnek betiği yaz" (write the *sample* script),
`writeoobescriptinfo-text`, `writingoobescript-text`, `wroteoobescript-text`, and
`automountoptionsinfo-text` ("Örnek: metadata,uid=1000...").

So a Turkish user reads "Add a Sample" in the nav pane (`21-tr-home.png`) and
"Write sample script" in the package screen, and the two mean different things. This is
the signature of machine translation: "instance" was translated in its
programming-language sense with no term list to say otherwise. It needs a real term
decision ("dağıtım örneği", or just "dağıtım") applied across all ten.

#### TL-12 -- German's nav pane has two English entries beside ten German ones

**major / S** -- `lib/i18n/de.json` (`homepage-text`, and see TL-09) --
`21-de-home.png`

`homepage-text` in `de.json` is the string `"Home"` -- verbatim English, where the
German Windows convention is "Startseite". Directly below it "Mount Disk" is English for
the reason in TL-09. The other ten entries are German, so the two stand out
(`21-de-home.png`): *Home, Codeausschnitte, Vorlagen, AI Workspace, Eine Instanz
hinzufügen, Distributionspakete, Mount Disk, Lizenz, ...*

German's full "identical to English" list is 23 of 542, and most of it is legitimate --
`Boot`, `Interop`, `GPU`, `Firewall`, `Docker Mirror`, `OK`, `Name`, `Start` are the same
word in German. The ones that are not: `homepage-text` ("Home"), `upgrade-text`
("Upgrade"), `ports-text` ("ports" -- also lower-case, where German capitalises nouns),
`partition-text` ("Partition (Optional)" -- the marker is untranslated even though the
noun happens to match) and `month-text` ("mo").

#### TL-13 -- "AI Workspace" is English in all nine locales, inside otherwise-translated nav panes

**nit / S** -- `lib/i18n/*.json` (`ai-workspace-title`) -- `21-ja-home.png`,
`21-zh_TW-home.png`, `21-hu-home.png`

`ai-workspace-title` is the string "AI Workspace" in every one of the nine files -- one
of only four keys that are identical across all of them (the others being `gpu-text`,
`plan-pro-short` and the `user@192.168.1.20` SSH placeholder, all of which are
legitimately invariant).

In Latin-script locales it merely reads as an untranslated label. In `ja` and `zh_TW` it
is a Latin-script entry sitting between ホーム / スニペット / テンプレート and
インスタンスを追加 -- the only English words in the pane. If it is a product name, that is a
decision worth stating; right now it looks like a key that was forgotten.

#### TL-14 -- An all-caps `DONE:` log prefix, translated eight different ways

**nit / S** -- `lib/i18n/*.json` (`createdinstance-text`, `deletedinstance-text`,
`donecopyinginstance-text`, `renamedinstance-text`) -- _source-derived_

Four English completion messages start with the literal `DONE:` -- "DONE: Created
instance", "DONE: Deleted instance %s", "DONE: Copied %s0 to %s1.", "DONE: Renamed
instance %s0 to %s1". No other success message in the file has a prefix; these read like
build-log output rather than UI copy.

Worse, the prefix was translated rather than dropped, and every locale made a different
call:

| locale | `createdinstance-text` |
|:---|:---|
| de | `FERTIG: Instanz erstellt` |
| es | `HECHO: Instancia creada` |
| hu | `KÉSZ: Példány létrehozva` |
| ja | `完了: インスタンスを作成しました` |
| pt | `CONCLUÍDO: instância criada.` |
| tr | `TAMAM: Örnek oluşturuldu` |
| zh_CN | `完成：实例已创建` |
| zh_TW | `已完成建立安裝實體` |

Turkish `TAMAM` means "OK", not "done". Portuguese is the only one with a trailing full
stop, and the only one that lower-cases the noun. Traditional Chinese dropped the prefix
entirely, which is the right answer -- the other seven should follow it.

#### TL-15 -- 59 English strings, translated nine times each, that nothing renders

**nit / M** -- `lib/i18n/*.json` -- _measured_

59 of `en.json`'s 542 keys do not appear as a string literal anywhere in `lib/`. At nine
locales that is **531 translated strings maintained for code that does not exist**, and
every one of them is a line `check_translations.dart` enforces on every future locale.

The cluster is worth reading rather than just counting. Nineteen of the 59 are a
subscription flow: `plan-monthly`, `plan-yearly`, `monthly-info-text`,
`yearly-info-text`, `yearly-per-month-text`, `subscribe-text`, `subscribe-info-text`,
`trial-badge`, `expires-text`, `manage-subscription-text`, `open-billing-portal-text`,
`activate-license-text`, `deactivate-license-text`, `license-activated`,
`license-deactivated`, `license-invalid`, `license-expired-info`, `license-key-empty`,
`license-key-placeholder`. A whole recurring-billing UI was written, translated into nine
languages, and never shipped -- which is the same story [[pro-surfaces]] tells from the
other end in PS-01, where the licence screen advertises features that have no
implementation.

(The count is deliberately conservative: it asks whether the key name appears in `lib/`
at all, so keys reached through the `.wslconfig` / `wsl.conf` descriptor tables -- which
pass `labelKey`/`infoKey` through a variable -- are counted as live.)

#### TL-16 -- Three recommender strings have no entry in any locale, so the panel prints its own keys

**major / S** -- `lib/api/recommender_service.dart:34`, `:45`, `:56`;
`lib/components/recommendations_panel.dart:87` -- _source-derived; rendering measured in
[[pro-surfaces]]_

`recommend-docker-template`, `recommend-cleanup` and `recommend-systemd` are absent from
**all nine** locale files, `en.json` included. `recommendations_panel.dart:87` calls
`rec.key.i18n()`, and the localization package's miss behaviour is to return the key, so
the panel renders the literal string `recommend-docker-template` to the user.
[[pro-surfaces]] reproduced two of the three live (PS-40, with `DockerImageCount = 5`);
`recommend-cleanup` is the third and has the same shape.

Recorded here rather than only there because of *why* nothing catches it, which is a
tooling gap rather than a missed string:

- `check_translations.dart` diffs the locales against `en.json`. These keys are missing
  from `en.json` too, so there is nothing to diff.
- A scan for `'literal'.i18n()` call sites finds **zero** missing keys across the whole
  tree -- because this call site passes a variable. Sweeping every key-shaped string
  literal in `lib/` instead is what surfaces them.

The same sweep clears the other candidates it turns up: `pro-required`, `byok-required`,
`byok-request-failed` and `byok-empty-response` (`ai_service.dart:117-201`) look like
i18n keys but are internal exception sentinels, matched with `msg.contains(...)` in
`ai_chat_panel.dart:66-71` and mapped to real keys before display. They are fine.

### Text quality

#### TL-17 -- The English source is split almost exactly in half between Title Case and sentence case

**major / M** -- `lib/i18n/en.json` -- `201-light-create.png`, `21-hu-settings.png`,
`21-es-create.png`

Counting multi-word short labels in `en.json` (34 characters or fewer, no terminal
punctuation, no placeholders) and classifying by whether every non-article word after the
first is capitalised: **98 Title Case, 91 sentence case.** There is no rule, and the
split shows up inside a single screen.

`201-light-create.png` -- the create screen, five labels:

- "Source Type" (Title)
- "Download from Repo" (sentence)
- "Distro name or path to rootfs" (sentence)
- "(Optional) Path where to save the new instance" (sentence)
- "Create default user" (sentence)

The drift is then inherited by the translations, into languages whose conventions do not
have Title Case at all:

- Spanish, same screen (`21-es-create.png`): `sourcetype-text` = "Tipo de **F**uente"
  but `selectsourcetype-text` = "Seleccionar tipo de fuente" -- the same noun phrase,
  capitalised two ways, in the same file. Spanish uses sentence case; the first is an
  English habit carried across. (Separately, "Fuente" is the word for *font* as often as
  for *source*; "Tipo de origen" is the safer term.)
- Hungarian settings (`21-hu-settings.png`): "Általános **B**eállítások", "Docker
  **B**eállítások", "Szinkronizálási **B**eállítások", "Kísérleti **B**eállítások" --
  and then "Globális konfiguráció" in the same accordion, correctly in sentence case.

Fixing English alone is not enough here; the convention has to be decided and then
applied to the nine files, which is why this is M rather than S.

#### TL-18 -- "(Optional)" is written three different ways across nine labels

**nit / S** -- `lib/i18n/en.json` -- `201-light-create.png`,
`22-zh_TW-mount-dialog.png`

Nine English strings carry an optional-ness marker, in three conventions:

| convention | keys |
|:---|:---|
| `(Optional) <label>` -- prefix | `savelocationhint-text`, `optionalusername-text`, `optionaluser-text`, `wsldefaultuser-text` |
| `<label> (Optional)` -- suffix, capitalised | `partition-text`, `filesystemtype-text`, `customname-text`, `mountoptions-text` |
| `<label> (optional)` -- suffix, lower-case | `savelocationplaceholder-text` |

The last two are the *same field* in the create flow: its toggle label reads
"(Optional) Path where to save the new instance" and the text box it reveals is
placeholdered "Save location (optional)". Both are visible in `201-light-create.png` once
the toggle is on.

## Verified -- checked and fine

Recorded so the audit does not read as a list of everything that was looked at, and so a
later regression is visible.

- **No locale blanks the app.** All nine launched, rendered content, and logged
  `Loaded lib/i18n/<locale>.json`. `zh_TW` in particular -- the locale that used to fail
  -- renders its full nav pane, list and settings accordion (`21-zh_TW-home.png`,
  `21-zh_TW-settings.png`, `22-zh_TW-mount-dialog.png`). No tofu boxes in `ja`, `zh_CN` or
  `zh_TW` at any of the three screens.
- **`test/locales_test.dart` still guards the invariant, and passes.** 17 tests, all
  green, including the four that pin the supported-locale list against the shipped files
  in both directions and the placeholder-count check. TL-10 is about widening one of
  them, not about a broken one.
- **`dart run scripts/check_translations.dart` exits 0.** True, and TL-10 is why that is
  not reassuring.
- **No locale truncates or overflows a label at 1400x860.** Home, create and settings were
  checked in all nine. The nav pane's fixed 216px column holds Hungarian
  "Disztribúciócsomagok", Japanese "ディストリビューションパッケージ" and Turkish "Dağıtım
  paketleri" without an ellipsis; the settings accordion holds Hungarian
  "Szinkronizálási Beállítások" and the create screen holds Spanish "Nombre de la
  Distribución o ruta al rootfs". The longest expansions in the corpus are German
  (`addquickaction-text` at 2.38x English, `syncsettings-text` at 2.31x) and both fit.
- **Four of the eight screens are fully theme-driven.** Zero pixels out of 938,184 in the
  content area survive the light->dark flip unchanged on `home`, `templates`, `create` or
  `packages`. `snippets` has 42 -- the accent-blue `{ }` strokes of its empty-state glyph,
  which are *meant* to be theme-independent, since the accent colour is. `settings` has 29,
  at rows 205..209 and 261..265: the two amber BETA pills of TL-05 and nothing else.
  Only `aiworkspace` (452) and `license` (338) have more, and both are accounted for --
  TL-01 and TL-05 for the first, the accent-coloured crown glyph and "Pro Plan" heading
  for the second.
- **The theme toggle needs no restart and shows no flash of the old theme**, and every
  screen re-renders correctly on the next navigation ([[list-and-navigation]] recorded
  the same for the toggle itself).
- **The dark settings screen is legible.** Group headers, control labels, the description
  line under each control and the seven-group accordion all read correctly at
  `204-dark-settings-general.png`; the description text is theme-derived
  (`typography.caption`), not a hardcoded grey.
- **The dark list row and its action bar are legible** (`204-dark-row-expanded.png`) --
  the nine action icons render white on the dark row. [[list-and-navigation]]'s LN-04..
  LN-06 complaints about them are about iconography, and are theme-independent.
- **The licence screen's Pro card adapts.** Its fill and border are accent-tinted from
  `FluentTheme.of(context).accentColor`, and every theme-invariant pixel on the screen is
  accent-coloured by design: the crown glyph in the header badge (rows 105..120, 43 px)
  and the crown plus the "Pro Plan" heading in the card (rows 199..215, 295 px). No grey.
- **Placeholder counts are consistent.** No locale drops or invents a `%s`; the existing
  test covers this and passes.

## Not examined in this pass

- **The OS-dark rendering of TL-03.** This host runs Windows in light mode
  (`AppsUseLightTheme = 1`), and the OS theme was deliberately not flipped. The getter's
  return value under `ThemeMode.system` is measured; the resulting black-on-dark text is
  inferred from it and labelled as such.
- **Dark mode for the dialogs and the free-tier licence table.** The eight screens
  captured in both themes are the top-level ones. The distro-settings dialog, the mount
  dialog, the template/snippet dialogs and the free-user licence comparison table
  (`license_screen.dart:277`, `:286`, which use `Colors.grey` and whose ✗ marker
  [[pro-surfaces]] measured at 1.85:1 in light) were not re-walked in dark. The two
  `Colors.grey` sites are recorded in TL-08 from source.
- **The recommendations panel in dark.** Reaching it needs `DockerImageCount` seeded, as
  [[pro-surfaces]] did; its border (`recommendations_panel.dart:29`) is in TL-08 from
  source.
- **Locales at the narrow 900px width.** The pane is icon-only below fluent_ui's 1008px
  threshold, so the labels that could overflow are not rendered there at all; the narrow
  pass in [[index]] covers the layout itself.
- **Screens other than home / create / settings, per locale.** The task named those
  three; the mount dialog was added because TL-09 needed a picture. Templates, snippets,
  the AI Workspace and the licence screen were captured in English only.
- **Right-to-left languages.** None are shipped, and nothing in the app opts into
  `Directionality`; adding one would be a separate piece of work.
