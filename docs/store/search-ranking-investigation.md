# Microsoft Store search ranking for "wsl"

Investigation dated 2026-11-19. Read-only: nothing in Partner Center or on the
live listing was changed.

**Question.** Why does WSL Manager (`9NWS9K95NMJB`) show up only around 10th
when someone searches the Microsoft Store for "wsl", and what would get it
into the top three?

**Short answer.** "WSL" is already the first word of our product name, and
the Store knows that: the app is #1 for "wsl manager" in both markets. For the
bare head term "wsl", though, the Store ranks mostly by popularity. Ubuntu, VS
Code, Windows Terminal, Docker Desktop, Windows App and even the Windows
Calculator rank for "wsl" without the term in their titles. Against that
signal the listing is weak. It was a US$ 9.99 paid app until 2026-09-13, so it
has nine weeks of free install velocity. It has 23 ratings in the US and 12 in
Germany, and some localized listings are stale or thin. The one direct
competitor that beats it, **WSL UI** (Octasoft, released 2026-01-13, free), has
built up 60 US ratings in ten months.

Search terms and wording can win the long-tail queries ("wsl gui", "wsl2",
"linux distro manager"). Only more Store installs and more recent ratings will
move "wsl" itself.

---

## 1. What the Store returns today

Source: the storefront JSON endpoint that the Store app and
`apps.microsoft.com` both call (it is the host
`scripts/check_store_listing.dart` already uses):

```
https://storeedgefd.dsx.mp.microsoft.com/v9.0/pages/searchResults?query=<q>&mediaType=all&market=<DE|US>&locale=<de-DE|en-US>&deviceFamily=Windows.Desktop
https://storeedgefd.dsx.mp.microsoft.com/v9.0/pages/pdp?productId=<id>&market=<m>&locale=<l>&deviceFamily=Windows.Desktop
```

The `de-DE` order was cross-checked against `apps.microsoft.com/search?query=wsl&hl=de-DE&gl=DE`
in a browser: same order (wsl-bridge, Ubuntu, VS Code, Windows Terminal, …), and
no result was labelled as an ad. These are anonymous results. A signed-in Store
client may personalise them.

### WSL Manager's rank per query

| Query | de-DE / DE | en-US / US |
|---|---|---|
| `wsl` | **10** | **25** (page 2) |
| `wsl manager` | 1 | 1 |
| `wsl gui` | 3 | 15 |
| `wsl2` | 8 | not in top 20 |
| `ubuntu` | 9 | not in top 20 |
| `linux` | not in top 20 | not in top 20 |

### "wsl", de-DE / DE (top 12)

| # | App | Publisher | Rating (DE) | Category | Price | Matches "wsl" via |
|---|---|---|---|---|---|---|
| 1 | wsl-bridge | yangholmes | – (0) | Developer tools | 3,09 € | title, short description |
| 2 | Ubuntu | Canonical | 4.3 | Developer tools | free | description ("Windows Subsystem for Linux (WSL)") |
| 3 | Visual Studio Code | Microsoft | 4.6 | Developer tools | free | popularity only |
| 4 | Windows Terminal | Microsoft | 4.3 | Developer tools | free | popularity only |
| 5 | Docker Desktop | Docker | 4.7 | Developer tools | free | description |
| 6 | Windows App | Microsoft | 3.5 | Productivity | free | popularity only |
| 7 | Debian | Debian Project | 4.6 | Developer tools | free | description |
| 8 | WSL UI | Octasoft | 5.0 (5) | Developer tools | free | title |
| 9 | Windows Terminal Preview | Microsoft | 4.8 | Developer tools | free | popularity only |
| **10** | **WSL Manager** | **Bostrot** | **4.6 (12)** | Developer tools › Utilities | free | **title** |
| 11 | WSL Toolbox Beta | FalconNL93 | – (0) | Developer tools | free | title |
| 12 | Windows Scanner | Microsoft | 3.3 | Utilities | free | popularity only |

### "wsl", en-US / US (top 12, plus us)

| # | App | Publisher | Rating (US) | Category | Price |
|---|---|---|---|---|---|
| 1 | wsl-bridge | yangholmes | – (0) | Developer tools | $2.99 |
| 2 | Ubuntu | Canonical | 4.4 | Developer tools | free |
| 3 | Docker Desktop | Docker | 4.2 | Developer tools | free |
| 4 | Winch WSL (Arch) | Vineel Sai | 4.6 (74) | Developer tools | free |
| 5 | Windows Terminal | Microsoft | 4.2 | Developer tools | free |
| 6 | Kali Linux | Kali Linux | 3.9 | Security | free |
| 7 | Debian | Debian Project | 4.5 | Developer tools | free |
| 8 | WSL UI | Octasoft | 4.7 (60) | Developer tools | free |
| 9 | Windows Terminal Preview | Microsoft | 4.8 | Developer tools | free |
| 10 | Windows App | Microsoft | 3.8 | Productivity | free |
| 11 | Rufus | Akeo | 4.7 | Utilities | free |
| 12 | Visual Studio Code | Microsoft | 3.1 | Developer tools | free |
| … | WSL Toolbox Beta (#14), WSL Tray Monitor (#16), Linux Manager (#22) | | | | |
| **25** | **WSL Manager** | **Bostrot** | **4.3 (23)** | Developer tools | free |

Results in the API carry no review count. The counts above come from each
product's PDP payload (`RatingCount`), and they are **per market**.

### Direct competitors (title contains "WSL" or describes a WSL manager)

| App | Released | US rating | DE rating | Listing languages | Screenshots | Desc. length | "WSL" in text |
|---|---|---|---|---|---|---|---|
| **WSL Manager** | 2021-09-21 | 4.3 (23) | 4.6 (12) | 13 (see §2) | en-US 8, de-DE 4 | 2157 | 18 (en) |
| WSL UI | 2026-01-13 | 4.7 (60) | 5.0 (5) | 1 (English) | 10 | 3475 | 26 |
| Winch WSL | 2023-01-23 | 4.6 (74) | 4.9 (10) | 1 | 2 | 236 | 3 |
| WSL Toolbox Beta | 2022-12-09 | 3.6 (14) | 0 | 1 | 3 | 239 | 4 |
| WSL Tray Monitor | 2022-06-15 | 4.9 (14) | 0 | 1 | 4 | 412 | 0 |
| wsl-bridge | 2026-03-23 | 0 | 0 | 1 | 5 | 512 | 2 |
| Linux Manager | 2024-03-27 | 0 | 0 | 1 | 3 | 1767 | 5 |

What this table shows:

- **Text alone does not decide it.** wsl-bridge, WSL Toolbox and WSL Manager
  all have "WSL" as the first title token. WSL UI ranks above us in both markets
  with an English-only listing. It does lead us on ratings (60 vs 23 US), on
  "Windows Subsystem for Linux" in its description, and on 25 uses of
  "distribution".
- **Popularity does decide most of the page.** Seven of the DE top ten have no
  "WSL" in their title.
- **wsl-bridge at #1 is an outlier.** It is a paid app with zero ratings. Two
  explanations fit, and neither can be checked from outside. Its hidden search
  terms may lean entirely on "wsl", or the Store may boost recently released
  apps. It is not a labelled ad.

## 2. Our listing as it is published

Pulled from the PDP endpoint per market/locale (`Language` = which listing the
Store served):

| Market / locale | Served listing | Rating (count) | Screenshots | Short description starts |
|---|---|---|---|---|
| US en-US | en-us | 4.3 (23) | 8 | "The WSL front end that does what the free ones don't…" |
| DE de-DE | de-de | 4.6 (12) | **4** | "Der „WSL Manager" – die ultimative Windows Store App…" |
| AT/CH de-* | de-de | 0 | 4 | same German text |
| GB en-GB, AU en-AU | en-gb / en-au | 0 | **1** | English new text |
| ES, BR, PT, JP, TW, TR, HU | own locale | BR 4.0 (5), rest 0 | **1** | new text, translated |
| CN zh-CN | zh-cn | 4.7 (13) | 4 | **old** text ("终极的Windows Store应用程序 😍") |
| KR ko-KR, FR fr-FR | neutral (English) | 0 | 8 | English fallback, no ko/fr listing |

- **Product name:** `WSL Manager`, the same as `msix_config.display_name` in
  `pubspec.yaml`.
- **Category:** Developer tools › Utilities. That is the right category, and
  every competitor uses it too.
- **Last update:** 2026-11-17. Freshness is fine.
- **Price:** free since 2026-09-13 (`storeFreeFromUtc`, `store/pricing.json`).
  Before that it was US$ 9.99 / Tier1102.
- **en-US text:** the rewritten 2026 pitch, with 11 feature bullets. It never
  says "Windows Subsystem for Linux". "GUI" and "Linux" appear once each.
  "Every WSL front end can start and stop a distro. This one manages them" and
  "does what the free ones don't" read oddly now that the listing itself is
  free.
- **de-DE text is the old one.** It is the 2023-era marketing copy with
  emoji ("die ultimative Windows Store App 😍", "laden Sie … aus dem Windows
  Store herunter! 🚀"). It lists features from before 2.0 and misses moving
  distros, compacting, remote WSL, templates and the MCP server. It has half
  the screenshots. zh-CN has the same problem.
- **Search terms (keywords): unknown.** They are hidden from customers and
  are not in the PDP payload. Nothing in the repos records them. They live
  only in Partner Center, or in the submission JSON under
  `listings.<lang>.baseListing.keywords`. **Check them before acting on §5.**

### Where the listing text lives and how it is submitted

- **Product name:** reserved names in Partner Center. The installed name comes
  from the package manifest (`pubspec.yaml` → `msix_config.display_name: WSL
  Manager`).
- **Description, short description, features, screenshots, keywords:** only in
  Partner Center. Nothing in `bostrot/wslmanager`, `wslmanager-page`,
  `wslmanager-wiki` or `wslmanager-scripts` holds them.
- **Submission:** `.github/workflows/publish-store.yml` → `scripts/publish_store.sh`
  clones the last submission through the legacy submission API, replaces the
  package (and pricing from `store/pricing.json`), and PUTs it back. Listings
  ride along untouched in the clone, so a release never changes listing text.
- **Verification:** `dart run scripts/check_store_listing.dart [--market DE
  --locale de-DE]` reads back what customers see.

### Ratings prompt: already implemented, but not with the Store's API

`lib/dialogs/rating_dialog.dart` (added 2026-08-27) shows an app-drawn
`ContentDialog`:

- Store installs only (`LicenseManager().isStorePackaged`).
- After 3 created instances (`InstancesCreated`, counted in `create_dialog.dart`).
- Shown on a later start (`nav/init.dart`).
- "Later" re-asks after 5 more instances. "Now" opens
  `ms-windows-store://review?ProductId=9NWS9K95NMJB`, which takes the user out
  of the app into the Store.

It does **not** call `StoreContext.RequestRateAndReviewAppAsync`. That call
shows the Store's own rating sheet inside the app. `windows/runner/store_channel.cpp`
already holds a `StoreContext` for `getAcquisition`, so the native call is a
small addition (sketch in §6).

## 3. What Microsoft documents about discoverability

Microsoft publishes no ranking formula for Store search. These are the
documented points:

1. **Keywords (formerly "search terms")**: "up to 7 keywords with a maximum
   of 40 characters each, and can use no more than 21 separate words across all
   keywords … think about the words that customers might use when searching for
   apps like yours, **especially if they're not part of your app's name**."
   ([MSIX: add additional information](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/add-additional-information);
   the [MSI/EXE FAQ](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msi/add-additional-information)
   adds that they are "used by the Microsoft Store's internal search engine to
   improve discoverability" and says to avoid others' brand names and "free"/"best".)
   The legacy [submission API reference](https://learn.microsoft.com/en-us/windows/uwp/monetize/manage-app-submissions)
   still says "Up to 7 search terms … 30 characters". **Keep every term ≤ 30
   characters** so the API path and the portal both accept it.
2. **Store policy 10.1.3**: search terms must "not exceed seven unique terms
   or phrases. Be relevant to your product. Not include pricing terms. **Not use
   other product titles unless those products are also published by you**."
   ([Store Policies 7.20](https://learn.microsoft.com/en-us/windows/apps/publish/store-policies))
3. **Store policy 10.1.1**: "Your product title or name must be unique and
   **must not contain marketing or descriptive text, including extraneous use of
   keywords**." Same page.
4. **Description**: "Use keywords naturally to improve discoverability in
   Store search results … Localize descriptions for all supported languages."
   Keep the short description under 270 characters; only the first 270 show in
   some views.
   ([Add and edit Store listing info](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/add-and-edit-store-listing-info))
5. **Product name per language**: the listing name is chosen per language
   from reserved names, and Microsoft recommends it match the package's name.
   Same page.
6. **Ratings**: "Ratings and reviews influence a product's discoverability,
   potentially boosting its downloads". The displayed score "has an affinity
   towards the product's recent ratings", and it "takes into account the
   customer's market and device type". Reviews (text) themselves "don't directly
   impact the rating score or the visibility".
   ([Ratings, reviews, and responses](https://learn.microsoft.com/en-us/partner-center/ratings-and-reviews),
   [Ratings and reviews insights](https://learn.microsoft.com/en-us/partner-center/insights/ratings-and-reviews))
7. **In-app rating request**: `RequestRateAndReviewAppAsync` in
   `Windows.Services.Store`, called on the UI thread. Microsoft's sample
   re-prompts no more often than every three months and only across version
   changes.
   ([Request ratings and reviews for your app](https://learn.microsoft.com/en-us/windows/uwp/monetize/request-ratings-and-reviews))
8. **Paid placement exists**: Microsoft Store Ads appear "within search
   results and the Apps and Gaming tabs".
   ([Microsoft Advertising: Microsoft Store Ads](https://Advertising.Microsoft.com/en-us/solutions/ad-products/microsoft-store-ads),
   [About Microsoft Store Ads](https://help.ads.microsoft.com/apex/index/3/en/60158))
9. **Trademarks**: Microsoft's
   [Trademark and Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks)
   say not to put Microsoft brand assets in the name of a product or app
   without a license. Factual statements of compatibility are allowed if they
   don't imply endorsement. The
   [Windows trademark guidelines (Feb 2026)](https://cdn-dynmedia-1.microsoft.com/is/content/microsoftcorp/microsoft/mscle/documents/presentations/Windows_Trademark_Guidelines_2026.pdf)
   cover the Windows name and logo the same way.

Install velocity, click-through and engagement are not documented as ranking
inputs for Store search. The results in §1, where Calculator, Teams and
Windows App rank for "wsl", only make sense if popularity is a heavy input.
Treat that as an inference, not documentation.

## 4. Root causes, most likely first

1. **Too little Store install volume and too few recent ratings for a head
   term ranked mostly by popularity.** The app was paid until 2026-09-13, so
   most Windows users installed it from GitHub, winget (the Inno installer,
   `Bostrot.WSLManager`) or Scoop. None of those count toward the Store. The
   Store has 23 US and 12 DE ratings after five years. WSL UI got 60 US
   ratings in ten months by being free in the Store from day one.
2. **The rating prompt converts poorly and fires late.** It leaves the app for
   the Store's review page instead of showing the native in-app sheet. It
   waits for three *created* instances, which many users never reach because
   they create one or two distros. It only runs on Store installs, which are
   the small group per cause 1.
3. **The localized listings are stale or thin, which is the DE-specific
   cause.** The German listing (also served in AT and CH) is the old emoji copy
   with 4 screenshots and pre-2.0 features. en-GB, en-AU, es, pt, ja, zh-TW, tr
   and hu have a single screenshot each. Thin listings convert worse from the
   results page, and conversion is a plausible popularity input.
4. **The en-US text targets people who already use a WSL front end, not
   people searching.** It never says "Windows Subsystem for Linux", "GUI" only
   once, "Linux" once, and it opens with a comparison ("does what the free ones
   don't") that no longer fits a free listing. That is why "wsl gui" is #15 and
   "wsl2" is outside the top 20 in the US while WSL UI is #1 for both. This
   affects long-tail queries more than "wsl".
5. **The keywords are probably unset or wasted on "wsl", which the title
   already covers.** This is unverified; check Partner Center.
6. **wsl-bridge holds #1 for reasons we cannot see.** It does not explain our
   rank, but it takes one of the top three slots for "wsl".

The product name is **not** a root cause. "WSL Manager" already starts with
the query term, and the Store matches it (#1 for "wsl manager").

## 5. Recommended actions, ranked

Impact: high / medium / low on the "wsl" head term. Effort: S (< 1 h),
M (a day), L (more). All are low-risk; none renames the app.

| # | Action | Impact | Effort | Evidence |
|---|---|---|---|---|
| 1 | **Switch the rating prompt to `RequestRateAndReviewAppAsync` and ask earlier** (after the first successful create or the second launch, at least 3 days in, at most once per version and 90 days; keep "never") | High (ratings count, recency) | M | §2 prompt, §3.6, §3.7, cause 2 |
| 2 | **Send Windows installs to the Store first**: put Store first in README, the website and release notes ("Free on the Microsoft Store"); add `winget install 9NWS9K95NMJB` (msstore source) next to the community manifest; give Store links a `cid` for acquisition tracking | High (install velocity) | S–M | cause 1, Store going free on 2026-09-13 |
| 3 | **Rewrite the de-DE listing and add the 8 screenshots to every locale** (text in §6), and refresh zh-CN the same way | Medium–high (DE) | M | §2 table, cause 3 |
| 4 | **Set the 7 keywords per locale** (§6), using terms not already in the name | Medium (long tail), low–medium (head) | S | §3.1–3.2, cause 5 |
| 5 | **Reword the en-US short description and first paragraph** to say "Windows Subsystem for Linux", "GUI" and "distro manager" up front (§6) | Medium (long tail) | S | §1 "wsl gui"/"wsl2" ranks, §3.4, cause 4 |
| 6 | **Reply to every Store review in Partner Center**, especially the low ones in the US (4.3 vs 4.6 in DE) | Low–medium | S, ongoing | §3.6 |
| 7 | **Keep the listing in git** like pricing: `store/listing/<locale>.json` merged into `listings.<locale>.baseListing` by `publish_store.sh`, with a dry-run diff. That stops locales drifting again | Enabler | M | §2 "where it lives" |
| 8 | **Optional: a small Microsoft Store Ads campaign on "wsl" in DE and US** for a few weeks after 1–5. It is the only guaranteed top slot, and the installs it brings feed the organic signal | Medium, paid | S + budget | §3.8 |
| 9 | **Do not rename** (see below) | – | – | §3.3, §3.9 |

What not to do: anything that inflates ratings. Incentivised reviews violate
Store policy and the developer code of conduct
([request ratings page](https://learn.microsoft.com/en-us/windows/uwp/monetize/request-ratings-and-reviews)).

### On renaming

The name could be "WSL Manager – GUI for Windows Subsystem for Linux" or
"WSL Manager: Linux Distro Manager". **Don't rename.**

- Policy 10.1.1 forbids descriptive text and "extraneous use of keywords" in
  the product name. A keyword-stuffed title invites a certification rejection.
- Adding "Windows Subsystem for Linux" or "Windows" to the name puts a
  Microsoft mark in a product name, which the trademark guidelines reserve for
  licensees. Describing compatibility in the *description* is fine.
- "WSL Manager" already leads with the query term, is #1 for "wsl manager",
  matches the package name and the brand everywhere else, and has five years
  of ratings attached to it.
- Whether "WSL" on its own is a registered Microsoft mark was **not verified**.
  Many Store apps carry it in their names (WSL UI, Alpine WSL, Winch WSL, WSL
  Toolbox), and ours has since 2021. That is precedent, not permission.

## 6. Proposed listing text

### Keywords

All terms are ≤ 30 characters, 7 terms, ≤ 21 words. None repeats "wsl"
alone, since the title covers it. No pricing words and no third-party brand
names.

| # | en-US | chars | de-DE | chars |
|---|---|---|---|---|
| 1 | WSL GUI | 7 | WSL GUI | 7 |
| 2 | Windows Subsystem for Linux ¹ | 27 | WSL Verwaltung | 14 |
| 3 | WSL2 distro manager | 19 | Linux Distribution verwalten | 28 |
| 4 | Linux distro manager | 20 | WSL2 Distro Manager | 19 |
| 5 | WSL backup export import | 24 | WSL Backup Export Import | 24 |
| 6 | rootfs import | 13 | Linux unter Windows | 19 |
| 7 | wslconfig editor | 16 | wslconfig Editor | 16 |
| | **words: 20** | | **words: 19** | |

¹ Policy 10.1.3 says search terms may not use "other product titles".
Microsoft publishes a Store product titled *Windows Subsystem for Linux*
(`9P9TQF7MRM4R`), so this term is a certification risk. If it gets flagged,
use `Linux subsystem manager` instead. The full phrase stays safe in the
description.

Avoid "Ubuntu", "Debian", "Kali" and "Docker" as keywords: they are other
publishers' product titles. They can stay in the description where they are
factual.

### Short description

en-US (219 chars):

> Manage WSL (Windows Subsystem for Linux) distros from one GUI: install, back up, move them to another drive, shrink their virtual disks, turn any Docker image into a distro and edit .wslconfig. Open source, free to use.

de-DE (260 chars):

> WSL-Distributionen (Windows-Subsystem für Linux) in einer GUI verwalten: installieren, sichern, auf ein anderes Laufwerk verschieben, virtuelle Datenträger verkleinern, Docker-Images als Distribution nutzen und .wslconfig bearbeiten. Open Source und kostenlos.

### en-US description (first paragraph only; the rest of today's text stays)

> WSL Manager is a free, open-source GUI for the Windows Subsystem for Linux (WSL and WSL2). Install, start, copy, rename, back up and delete your Linux distros, move them to another drive, and compact their virtual disks to get back the space WSL never returns.

Then continue with "MANAGE YOUR DISTROS …" as published. Change "nine
languages" to the real count: the app ships 10 UI languages (`lib/i18n/`).
The Store lists 13 because the MSIX declares regional variants.

### de-DE description (full replacement)

> WSL Manager ist eine kostenlose Open-Source-Oberfläche für das Windows-Subsystem für Linux (WSL und WSL2). Installieren, starten, kopieren, umbenennen, sichern und löschen Sie Ihre Linux-Distributionen, verschieben Sie sie auf ein anderes Laufwerk und verkleinern Sie ihre virtuellen Datenträger, um den Speicherplatz zurückzuholen, den WSL von sich aus nie freigibt.
>
> DISTRIBUTIONEN VERWALTEN
>
> Aus dem eingebauten Katalog installieren oder ein eigenes rootfs importieren. Instanzen kopieren, umbenennen, verschieben, sichern und löschen. Virtuelle Datenträger komprimieren. Funktioniert mit Ubuntu, Debian, Alpine, Kali Linux, openSUSE, SLES und allem anderen, was WSL akzeptiert.
>
> SCHNELLER STARTEN
>
> Jedes Docker-Image als Distribution verwenden – Docker selbst ist nicht nötig.
> Eine eingerichtete Distribution als Vorlage speichern und daraus frische Kopien erstellen.
> Einrichtungsbefehle als Snippets speichern und auf jeder Instanz ausführen.
> Eigene rootfs-Quellen hinzufügen.
>
> KONFIGURIEREN OHNE DATEIEN VON HAND ZU BEARBEITEN
>
> systemd, automount, Standardbenutzer, Startbefehl und Startpfad je Distribution.
> Arbeitsspeicher, Prozessoren, Swap, Netzwerkmodus, Firewall und DNS in der .wslconfig.
> Physische Datenträger oder VHDs in WSL einbinden, mit Auswahl von Partition und Dateisystem.
>
> SO ARBEITEN, WIE SIE ES GEWOHNT SIND
>
> Windows Terminal, VS Code oder den Explorer direkt in einer Distribution öffnen.
> WSL auf einem anderen Windows-PC per SSH verwalten.
> Eine Distribution zwischen zwei Rechnern im Netzwerk synchronisieren.
> Helles und dunkles Design, 10 Sprachen.
>
> PRO
>
> Ein optionaler Einmalkauf – kein Abo – schaltet frei:
>
> MCP-Server: WSL für Claude Desktop und andere MCP-Clients freigeben. Agenten können Distributionen auflisten, Befehle ausführen und echte interaktive Terminal-Sitzungen steuern.
>
> AI Workspace: Hermes Agent, OpenClaw, Open WebUI und OpenCode in einer eigenen, isolierten WSL-Distribution installieren und betreiben – nichts landet in den Distributionen, mit denen Sie arbeiten.
>
> KI-Assistent: Hilfe bei der Konfiguration, Skripterstellung und Fehlerdiagnose – mit Ihrem eigenen OpenAI-kompatiblen API-Schlüssel. Es wird kein KI-Dienst betrieben oder mitgeliefert und es gibt kein Kontingent.
>
> OPEN SOURCE
>
> GPL-lizenziert. Quellcode, Issue-Tracker und Dokumentation:
> github.com/bostrot/wsl2-distro-manager

The en-US Pro paragraph names only Hermes Agent, OpenClaw and Open WebUI.
OpenCode was added later, so add it there as well.

### de-DE features (the Store allows up to 20 bullets; keep 11, the same set as en-US)

> - Distributionen zwischen Laufwerken verschieben und ihre Datenträger verkleinern
> - Jedes Docker-Image als Distribution nutzen – ohne Docker
> - Instanzen installieren, kopieren, umbenennen, sichern und löschen
> - Eine eingerichtete Distribution als wiederverwendbare Vorlage speichern
> - Gespeicherte Befehls-Snippets auf Ihren Instanzen ausführen
> - Windows Terminal, VS Code oder Explorer in einer Distribution öffnen
> - .wslconfig und Einstellungen je Distribution per GUI bearbeiten
> - Physische Datenträger und VHDs in WSL einbinden
> - WSL auf einem entfernten Windows-PC per SSH verwalten
> - Pro: MCP-Server, AI Workspace, KI-Assistent
> - Open Source, GPL-lizenziert

### Screenshots

Use the same 8 en-US screenshots in every locale that has 1 or 4 today. Use
German-UI captures for de-DE if they are cheap to take: the app ships
`de.json`, and a German screenshot is what a DE visitor expects.

### Sketch: native rating sheet (not implemented here)

`windows/runner/store_channel.cpp` handles only `getAcquisition`. Add a second
method alongside it:

```cpp
// HandleMethodCall: "requestRateAndReview" next to "getAcquisition".
// Must run on the UI thread; RequestRateAndReviewAppAsync needs the window
// for a Win32 (desktop bridge) app, same IInitializeWithWindow dance as the
// purchase flow.
StoreContext context = StoreContext::GetDefault();
context.as<IInitializeWithWindow>()->Initialize(window_);
auto result = co_await context.RequestRateAndReviewAppAsync();
// result.Status(): Succeeded / CanceledByUser / NetworkError / Error
// result.UpdatedExistingRatingOrReview()
```

On the Dart side, `maybeShowRatingPrompt()` would call that method instead of
drawing its own `ContentDialog` and launching `storeReviewUrl`. It keeps
`storeReviewUrl` as the fallback when the call reports `Error`. It records
`RatingPromptDone` only on `Succeeded`. It records "asked at version X" on
`CanceledByUser`, so it asks once per version and at most every 90 days, as
Microsoft's sample does. The trigger moves from "3 instances created" to
something most users reach. One option is the second app start at least 3
days after the first, with at least one successful action (create, start or
terminal open). The Store sheet already has its own decline, so the app's
"never" button goes away.

## 7. Not verified

- **Current keywords in Partner Center.** I had no Partner Center access by
  design. Read them there or from the submission JSON before changing them.
- **Install and acquisition numbers and search click-through.** Partner Center
  → Acquisitions would confirm or refute cause 1 (Store acquisitions before
  and after 2026-09-13).
- **Why wsl-bridge ranks #1** with no ratings.
- **Whether "WSL" alone is a registered Microsoft trademark.**
- **Whether the Windows Store client ranks the same as the anonymous web/API
  results.** The web page matched the API for de-DE. The Store client may
  personalise its results.
- **Whether keyword changes take effect without a new package.** Listing-only
  submissions are allowed. How long re-indexing takes is not documented.
- **Rank changes over time.** This is a single snapshot taken 2026-11-19.
  Re-run the queries in §1 a few weeks after acting to measure the effect.
