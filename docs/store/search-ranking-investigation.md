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

**What Partner Center adds (§2b, read 2026-11-19).**

- **Going free worked for conversion, not for discovery.** Installs rose
  14-fold (11 → 154 a week) and page-view-to-install conversion rose from
  0.3 % to 8.2 %. Page views, however, stayed where they were in the paid
  summer (about 1.5–1.9 K a week). That is a third of the Dec–Apr level, so
  the Store is showing the page less, not more.
- **Ratings have stopped.** The app has 121 lifetime ratings (average 4.60).
  Since 2026-09-13, about 1,300 installs produced exactly **two** ratings,
  averaging 2.5. The in-app prompt added on 2026-08-27 produces practically
  nothing.
- **China is the biggest market**: 37 % of installs in the last month, ahead
  of the US (17 %) and Germany (13 %). zh-CN runs the oldest, shortest listing
  and has English keywords.
- **Keywords exist but are wasted.** en-US has `wsl, manager, gui, linux,
  wsl2, docker, virtual disk compact`. de-DE and zh-CN carry the same English
  set with `github` in place of the last one. The other nine listing languages
  have **no keywords at all**.

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
- **Search terms (keywords):** hidden from customers and absent from the PDP
  payload; nothing in the repos records them. They are read from Partner
  Center below.

### The listing in Partner Center (live submission 83, read-only view)

Partner Center shows 12 listing languages: zh-CN, zh-TW, en-AU, en-GB, en-US,
de-DE, hu-HU, ja-JP, pt-BR, pt-PT, es-ES and tr-TR. There is **no ko-KR
listing** even though the MSIX declares ko-KR, so Korea gets the English
fallback. The product name is `WSL Manager` in every language.

| Language | Keywords (as set) | Short description | Description | Release notes |
|---|---|---|---|---|
| en-US | `wsl`, `manager`, `gui`, `linux`, `wsl2`, `docker`, `virtual disk compact` | 2026 pitch ("does what the free ones don't") | 2,157 chars, current | "WSL Manager 2.0 …" |
| de-DE | `wsl`, `manager`, `gui`, `linux`, `wsl2`, `docker`, `github` (English) | **old** ("die ultimative Windows Store App") | 1,511 chars, **old**, emoji | "WSL Manager 2.0 …" (German) |
| zh-CN | same English set as de-DE | **old** ("终极的Windows Store应用程序 😍") | **528 chars, old** | "WSL Manager 2.0 …" (Chinese) |
| zh-TW, ja-JP, es-ES, pt-BR, pt-PT, tr-TR, hu-HU | **none** | 2026 pitch, translated | current, translated | "WSL Manager 2.0 …" |
| en-GB, en-AU | **none** | 2026 pitch | current | "WSL Manager 2.0 …" |

All 12 have 11 feature bullets. Other fields:

- **Copyright:** "©2023 Copyright Eric Trenkel" (en-US, de-DE and zh-CN only).
- **Developed by:** "Bostrot (Eric Trenkel)".
- **en-US voice title:** "Windows-Subsystem-for-Linux Graphical Interface".
  The other languages have no voice title.
- **Release notes in every language** still describe 2.0, while the shipped
  version is 2.6.
- **Screenshots:** the public PDP counts in the table above (8 for en-US, 4 for
  de-DE and zh-CN, 1 elsewhere). The read-only view did not expose its own
  count.

## 2b. Partner Center analytics (52 weeks to 2026-11-17)

These are Store-only numbers: GitHub, winget and Scoop installs are not in
them. Partner Center flagged "data disruptions on Channel and Conversions"
while this was read, so treat the last two weeks with care.

### Acquisitions: paid vs free

| Period | Weeks | Page views / week | Installs / week | Conversion (installs / page views) |
|---|---|---|---|---|
| Paid, 2025-11-17 → 2026-04-27 | 24 | ≈ 5,000 (peak 8,302 in the week of 2026-03-09) | ≈ 15 | 0.3 % |
| Paid, 2026-05-25 → 2026-08-31 | 15 | ≈ 1,500 | ≈ 5 | 0.3 % |
| **Free, 2026-09-14 → 2026-11-02** | 8 | **1,885** | **154** | **8.2 %** |
| Free, week of 2026-11-09 | 1 | 10,939 | 166 | 1.5 % |

- **12-month totals:** 1,885 installs. The last month alone had 20 K page views,
  610 installs, 3.0 % conversion and a 99.2 % install success rate.
- **During the paid period**, 20–37 people a week clicked Buy and then
  aborted ("user-initiated aborts"). After the flip that fell to 0–6.
- **Page views fell by about two thirds from late May 2026, on both the Store
  and Bing at once,** and did not come back when the app went free. There was
  no release between v1.11.0 (2026-04-03) and v2.0.0 (2026-09-06), so loss of
  freshness is one candidate. The frequent releases since September have not
  restored the old level, though, so it is not the whole story.
- **The week of 2026-11-09:** page views from inside the Store jumped to 10.6 K
  but Store-sourced installs stayed at about 80. That looks like low-intent
  exposure (a placement or collection), or it is the reporting disruption.
  It did not translate into installs.

### Where page views and installs come from (free period, weekly averages)

| Source | Page views / week | Installs / week | Conversion |
|---|---|---|---|
| Microsoft Store on Windows (search and browse inside the Store app) | 1,792 (95 %) | 88.5 (58 %) | 4.9 % |
| External web URL (website, README, GitHub links) | 67 | 60.2 (39 %) | **90 %** |
| Custom campaign | ≈ 12 | ≈ 4 | – |
| Bing web search | ≈ 4 (≈ 50/week until May) | ≈ 1 | – |
| Microsoft Store web, Windows Start, App restore | 0 | 0 | – |

Partner Center splits page views by **source type only**. It does not report
which Store search terms led to the page, so the share that came from
searching "wsl" specifically cannot be measured.

### Markets (installs)

| Market | Last 12 months | Last month (2026-10-20 → 11-17) |
|---|---|---|
| China | 591 (31 %) | 224 (37 %) |
| United States | 386 (20 %) | 102 (17 %) |
| Germany | 219 (12 %) | 80 (13 %) |
| Brazil | 63 (3 %) | – |
| United Kingdom | 48 (3 %) | 14 (2 %) |
| France | 44 (2 %) | 13 (2 %) |
| Russia | – | 11 (2 %) |
| India | 37 (2 %) | 10 (2 %) |

Per-market page views and conversion were not read; the market filter would
need one pass per country.

### Ratings and reviews

- **Lifetime:** 121 ratings, average **4.60**. By star: 5★ 101 (83 %), 4★ 9,
  3★ 2, 2★ 0, 1★ 9. 84 are original and 37 revised.
- **Over time:** 1–4 ratings a week through 2022–2023, then down to roughly
  one a month through 2024. In the year before going free there were 4 (in
  February, March, June and October 2025). Nothing from 2025-10-20 until the
  week of 2026-09-14, which brought **2 ratings at an average of 2.5**.
  Nothing since.
- **Newest written reviews**, paraphrased and anonymised:
  - "Started installing AI stuff that has nothing to do with WSL management,
    uninstalled." (1 star)
  - "The AI assistant installs without confirmation; it should be an option;
    otherwise a great app."
  - "Not intuitive, not nice to look at." (Chinese)
  - "Crashes when creating an instance, with no error shown."
  - "Blank screen and image search failures until the cache folder was
    deleted."
  - Older ones: "Best WSL tool", "Best software for managing WSL distros in a
    GUI — why is it not on the first page of the Windows Store?"
  - Every one of the critical reviews has a developer reply.
- **Partner Center's AI review summary:** "does not have enough reviews to
  generate a review summary".

### Usage and health (opt-in telemetry, last 30 days)

- **Devices:** 257 monthly active, of which 185 are new that month. 13 daily
  active (DAD/MAD 5.2 %).
- **Sessions:** 658 sessions, averaging 1.7 minutes.
- **Health:** a handful of crashes, hangs and memory failures in 30 days.
  Nothing systemic.

Most users open the app a few times and leave. A prompt that needs **three
created instances and a later launch** rarely meets anyone.

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

## 4. Root causes, ranked again with the Partner Center data

Earlier (public data only) the order was: 1 popularity and volume, 2 the
rating prompt, 3 stale de-DE/zh-CN listings, 4 en-US wording, 5 keywords. The
verdicts below are based on §2b.

1. **Low discovery, which the Store controls through popularity signals —
   CONFIRMED, and narrowed.** Going free fixed conversion (0.3 % → 8.2 %) but
   did not bring discovery back. In-Store page views have been about a third
   of the winter level since late May 2026, and they did not rise with the
   14-fold jump in installs. 95 % of page views and 58 % of installs come from
   inside the Store app. That surface is where the "wsl" rank is decided, and
   it is the one that shrank.
2. **No new ratings — CONFIRMED, and stronger than assumed.** About 1,300
   free installs produced 2 ratings, about 1.5 per 1,000 installs. Both
   arrived in the first week and averaged 2.5. Before that, nothing for 11
   months. The Store weights recent ratings
   ([§3.6](#3-what-microsoft-documents-about-discoverability)), and recent
   ratings are both nearly absent and negative. The in-app prompt is
   effectively dead. The usage data shows why: 185 of 257 monthly devices are
   new, so most people never reach "three created instances, then a later
   launch". When they do, they are sent out of the app to the Store.
3. **The listings in the biggest markets are stale — CONFIRMED, and China
   matters more than Germany.** China is 37 % of installs and has the oldest
   listing: a 528-character emoji description from before 2.0, 4 screenshots,
   and English keywords. Germany (13 %) has the same problem with a longer
   old text. All 12 languages still announce "WSL Manager 2.0" in their
   release notes.
4. **Keywords are wasted or missing — CONFIRMED, though not "unset" as
   guessed.** In en-US, two of the seven slots repeat the title (`wsl`,
   `manager`), one is a third-party brand (`docker`), and one is generic
   (`linux`). de-DE and zh-CN reuse the English set and spend one slot on
   `github`, another brand. Nine languages, together a small share of
   installs, have none.
5. **The en-US wording speaks to people who already use a WSL front end —
   NOT MEASURABLE.** Partner Center does not report which search terms
   reached the page, so this stays a hypothesis backed only by the public
   long-tail ranks in §1. It drops to last place.
6. **New: the AI features cost goodwill.** The two newest critical reviews
   say the AI assistant installed things without asking. That is the most
   recent sentiment the Store weights, and it sits on a listing whose
   description leads with the AI and MCP features.
7. **wsl-bridge at #1 still has no explanation.** It is not something we can
   change.

The product name is still **not** a root cause.

## 5. Recommended actions, ranked again

Impact: high / medium / low on the "wsl" head term. Effort: S (< 1 h),
M (a day), L (more). All are low-risk; none renames the app. Each one has a
target that can be read off the same Partner Center pages afterwards.

| # | Action | Impact | Effort | Measurable target | Evidence |
|---|---|---|---|---|---|
| 1 | **Replace the rating prompt with `RequestRateAndReviewAppAsync` and ask much earlier**: on the second launch, at least 2 days after install, once one action has succeeded (create, start or open a terminal); at most once per version and every 90 days | High | M | **≥ 15 ratings a month** (≈ 2.5 % of ~600 monthly installs) within 6 weeks of release; average of ratings in the last 90 days **≥ 4.5** | §2b ratings, usage; cause 2 |
| 2 | **Rewrite the zh-CN and de-DE listings** (text in §6), set **localized** keywords in both, and use the 8 current screenshots | High in CN, medium in DE | M | China and Germany Store-source conversion within 3 weeks; DE "wsl" rank ≤ 5 by the end of Q1 2027 | §2 Partner Center table; §2b markets; cause 3 |
| 3 | **Replace the keywords in all 12 languages** (§6): drop `wsl`, `manager`, `docker` and `github`; fill the nine empty languages | Medium (long tail), low–medium (head) | S | Rank for "wsl gui" (US ≤ 5) and "wsl2" (US ≤ 10), re-checked with the §1 queries 4 weeks after the change | §2 table; §3.1–3.2; cause 4 |
| 4 | **Push external traffic into the Store**: Store as the first Windows option in the README, the website and GitHub release notes, with a `cid` on every link (`?cid=readme`, `?cid=site`, `?cid=release`); add `winget install 9NWS9K95NMJB`. External visits convert at 90 %, and more Store installs feed the popularity signal that decides "wsl" | Medium–high | S–M | External-URL installs from **60 to ≥ 120 a week**; total Store installs **≥ 250 a week** | §2b sources |
| 5 | **Make the AI features visibly opt-in, and say so in the listing**: one line in every description ("AI features are off until you turn them on"); update the release notes from "2.0" to the current version | Medium (rating quality) | S | No new review that complains about AI installs; 1★ share among ratings in the last 90 days **< 10 %** | §2b reviews; cause 6 |
| 6 | **Find out why page views dropped in late May 2026**: compare the submission history and the keyword and listing edits of April–June 2026 in Partner Center, and keep releasing at least monthly | Unknown, possibly high | S | Store-on-Windows page views back to **≥ 4,000 a week** (the Dec–Apr level was ~5,000) | §2b paid vs free |
| 7 | **Reword the en-US short description and first paragraph** (§6) | Low–medium | S | as #3 | cause 5 |
| 8 | **Keep the listing in git** like pricing: `store/listing/<locale>.json` merged by `publish_store.sh`, with a dry-run diff. That would have stopped zh-CN and de-DE drifting for three years | Enabler | M | – | §2 |
| 9 | **Optional: Microsoft Store Ads on "wsl" in CN, US and DE** after 1–4 are live | Medium, paid | S + budget | Campaign conversion in "Custom campaign performance" | §3.8 |
| 10 | **Do not rename** | – | – | – | §3.3, §3.9 |

To track: Insights → Acquisitions (Last 3 months; view by source type
"Microsoft Store on Windows" and "External web url"; Geographical spread) and
Insights → Reviews (Ratings over time). Re-run the §1 queries the same day.

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

Current keywords (§2): en-US `wsl, manager, gui, linux, wsl2, docker, virtual
disk compact`; de-DE and zh-CN the same English set with `github` last; nine
languages have none. What changes:

- **Drop** `wsl` and `manager`: the title already covers both.
- **Drop** `docker` and `github`: they are other companies' brands and fall
  under policy 10.1.3.
- **Make** `gui`, `linux` and `wsl2` part of longer phrases.
- **Localize** the de-DE and zh-CN sets.
- **Copy** the en-US set into en-GB and en-AU. For the other languages, use
  the en-US set until someone translates it; English technical terms are
  still searched there.

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

zh-CN (China is 37 % of installs). The keywords use Microsoft's own Chinese
name for WSL, 适用于 Linux 的 Windows 子系统, shortened where a keyword
needs it:

| # | zh-CN | meaning |
|---|---|---|
| 1 | WSL 图形界面 | WSL GUI |
| 2 | WSL 管理器 | WSL manager (Chinese users search the Chinese word) |
| 3 | Linux 子系统 | Linux subsystem |
| 4 | WSL2 发行版管理 | WSL2 distro management |
| 5 | Linux 发行版 | Linux distro |
| 6 | WSL 备份 导出 导入 | WSL backup export import |
| 7 | wslconfig 编辑器 | wslconfig editor |

### Short description

en-US (219 chars):

> Manage WSL (Windows Subsystem for Linux) distros from one GUI: install, back up, move them to another drive, shrink their virtual disks, turn any Docker image into a distro and edit .wslconfig. Open source, free to use.

de-DE (260 chars):

> WSL-Distributionen (Windows-Subsystem für Linux) in einer GUI verwalten: installieren, sichern, auf ein anderes Laufwerk verschieben, virtuelle Datenträger verkleinern, Docker-Images als Distribution nutzen und .wslconfig bearbeiten. Open Source und kostenlos.

zh-CN:

> 用一个图形界面管理 WSL（适用于 Linux 的 Windows 子系统）发行版：安装、备份、迁移到其他磁盘、压缩虚拟磁盘以释放空间、把任意 Docker 镜像变成发行版、编辑 .wslconfig。开源，免费使用。

The zh-CN description and features should be a translation of the current
en-US text, the way zh-TW already is. The zh-TW listing can serve as the
starting point, converted to Simplified Chinese and checked by a native
reader. That replaces today's 528-character text from before 2.0.

### Every language: one line on the AI features, and current release notes

Add to the end of the first paragraph of every description (en-US wording):

> The AI features are optional and stay off until you turn them on.

Check that this is true in the shipped build before publishing it: the two
newest critical reviews say otherwise for earlier builds. Then replace the
"WSL Manager 2.0" release notes in all 12 languages with the current
version's.

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

Closed by Partner Center: the current keywords (§2), the acquisition numbers
before and after going free, the sources of page views and installs, the
markets, and the ratings over time (§2b).

Still open:

- **Which search terms led to the page.** Partner Center reports source
  types only ("Microsoft Store on Windows", "External web url", …), not
  queries. The share of installs that came from searching "wsl" cannot be
  measured.
- **Why page views fell by two thirds in late May 2026** on the Store and
  Bing at the same time (action 6).
- **What caused the 10.6 K page-view spike in the week of 2026-11-09**: a
  placement, or the "Channel and Conversions" data disruption Partner Center
  was reporting.
- **Per-market page views and conversion.** Only installs per market were
  read.
- **Screenshot count per language inside Partner Center.** The public PDP
  counts in §2 are used instead.
- **Why wsl-bridge ranks #1** with no ratings.
- **Whether "WSL" alone is a registered Microsoft trademark.**
- **Whether the Windows Store client ranks the same as the anonymous web/API
  results.** The web page matched the API for de-DE.
- **How long re-indexing takes after a listing-only submission.** Microsoft
  does not document it.
- **Rank changes over time.** The ranks are a single snapshot from
  2026-11-19. Re-run the §1 queries after acting.
