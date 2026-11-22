# Evaluation: moving Pro/AI features into a closed package

Written for bostrot/ai-tasks#13. The question: should the AI features be
protected not only by the Pro gate but also technically, by moving them into
a non-open-source package (for example a Flutter package in a private git
repo) so that nobody can build them from source?

This is an engineering-side evaluation. The legal sections summarise how
GPLv3 and German law are generally understood; they are not legal advice.
Have a lawyer who knows open-source licensing (in Germany: ifrOSS, or any
IT-law firm) read the plan before any licence is changed.

**Short answer: it is legally feasible, technically a medium-sized refactor,
and probably not worth it right now.** The revenue it protects is tiny, the
promises it breaks are public, and the cheap protections (trademark, binary
EULA, licence-key check) are not in place yet. Section 6 has the
recommendation; section 7 has the plan if it goes ahead anyway.

## 1. What is on the table

### The code

Everything a Pro licence unlocks today, plus the licence machinery itself:

| Area | Files | Lines |
|------|-------|------:|
| AI Workspace (VM lifecycle for Hermes, OpenClaw, Open WebUI) | `lib/api/ai_workspace/`, `lib/screens/ai_workspace_screen.dart` | ~2 970 |
| AI chat, diagnosis, Claude sign-in | `lib/api/ai_service.dart`, `lib/api/claude_auth.dart`, `lib/components/ai_chat_panel.dart`, `lib/components/ai_diagnosis.dart` | ~2 400 |
| MCP server and tools, Cloudflare tunnel | `lib/api/mcp/` | ~2 600 |
| Web dashboard | `lib/api/web/` | ~1 070 |
| Sandbox VMs, recommender | `lib/api/sandbox_service.dart`, `lib/api/recommender_service.dart` | ~430 |
| Licence manager and screen | `lib/api/license_manager.dart`, `lib/screens/license_screen.dart` | ~890 |
| **Total** | | **~10 370** |

That is 30% of the 34 946 lines in `lib/`. The gate is a single boolean,
`LicenseManager().isPro`, read at 24 call sites; the Pro code itself is
fully present in the free build and in the public repo.

### How it is coupled to the rest of the app

The Pro files import 37 distinct modules from the free side of the app, most
often `components/helpers.dart` (prefs, shell), `api/vm/vm_platform.dart`
and `api/vm/vm_backend.dart` (running commands in a distro or VM),
`components/notify.dart`, `components/constants.dart` and `nav/router.dart`.
In the other direction, nine free-side files reach into Pro code:
`main.dart` (starts the MCP server and dashboard), `nav/router.dart` and
`nav/root_screen.dart` (routes and nav entries), `screens/settings_screen.dart`
(AI provider, key, MCP and dashboard settings), `api/execution/broker.dart`,
`components/list.dart`, `components/list_item.dart`,
`components/recommendations_panel.dart` and `dialogs/create_dialog.dart`.
The Pro UI also uses 104 translation keys that live in the shared
`lib/i18n/*.json` files.

None of this is a blocker, but it means the split is not "move a folder": it
is an interface-extraction refactor first, then a move.

### Who owns the copyright

This decides the legal question, so it was measured rather than assumed:

- `git blame` over every `.dart` file in `lib/` (excluding the generated
  licence file): 34 926 lines by Eric, 20 by others (14 from the Copilot bot
  working under Eric's direction, 2 each from three human contributors, all
  in `api/wsl.dart` and `screens/settings_screen.dart`).
- `lib/i18n/*.json`: 7 594 lines by Eric, 7 single lines by seven
  translators.
- Every one of the 68 commits that touched the Pro/AI files is Eric's.

So the Pro code is 100% Eric's, and the free code is 99.9% Eric's. There is
no CLA in `CONTRIBUTING.md`, so the 27 outside lines were contributed under
GPLv3 inbound = outbound and Eric does not own them. That exposure is small
enough to remove by rewriting those lines, or to leave as is (see 3.2).

### Dependencies

`lib/oss_licenses.dart` lists 107 packages. 105 are BSD/MIT/Apache. The two
GPLv3 packages, `chunked_downloader` and `plausible_analytics`, are both
Eric's own (`github.com/bostrot/...`), so they can simply be relicensed to
MIT. Nothing in the tree stops a proprietary module being linked in.

### What the app and website currently promise

- `LICENSE`: dual GPLv3 / commercial, copyright Eric Trenkel, German law.
- `README.md`: "a free, open source GUI", "This project is GPL-3.0 licensed".
- `wslmanager-page/src/lib/pricing.js` lists "Full source, GPLv3" as a
  *feature of the free tier*, and `buy.jsx` says "Open source, GPLv3" under
  the Pro price.
- `lib/api/license_manager.dart` header: "Neither path is protection. The
  repo is open source; both are a nudge."

The current business model is explicitly a support/convenience model: pay
for the Store build or a key, and the source is open regardless. A private
package reverses that promise, and the reversal has to be announced to the
people who already paid under the old one.

## 2. What "can't just compile it" actually buys

Threat model, honestly stated:

| Who | Today | With a private package |
|-----|-------|------------------------|
| Regular user | Installs the release build, sees the paywall, buys or not | Same |
| Developer who clones and runs `flutter run` | Gets Pro for free: debug builds run as Pro by design, and `isPro` is one line away in a release build | Gets the free build with a stub; AI screens show the paywall or are absent |
| Someone patching the release binary | Can flip the gate in the AOT snapshot with effort (Blutter/reFlutter style tooling) | Identical: the Pro code is still compiled into the shipped binary and still gated by the same boolean |
| Someone redistributing a "Pro unlocked" build | Legal under GPLv3 today if they publish source | Illegal, and there is a clear takedown basis |

The private package closes exactly one hole: the person willing to install
Flutter, clone a repo and build a desktop app to avoid a one-time USD 19.99
purchase. That population is small, mostly would not have paid anyway, and is
the same population that files bug reports and PRs. It does nothing against
binary patching, which is the route anyone who is actually motivated would
take.

The one real gain is the last row: today, a fork that sets `isPro = true`
and ships binaries plus source is entirely GPL-compliant, and there is no
legal handle against it except the name. With a closed module (or, more
cheaply, a trademark) there is.

## 3. Legal evaluation

### 3.1 Can Eric do it at all?

Yes. The GPL binds licensees, not the copyright holder. Eric can license the
same code under GPLv3 to the public and under any other terms to himself or
to buyers; that is what the existing dual licence already does. Splitting
off a proprietary module is the same right exercised differently.

### 3.2 The combined binary problem

Flutter compiles all Dart code into one AOT snapshot. A "private package" is
a source-tree convenience; in the shipped app the Pro code and the GPL code
are statically linked into one executable. Under GPLv3 that is one "work
based on the Program", and distributing it requires that the whole be
licensed under the GPL, unless every GPL copyright holder in it agrees
otherwise.

Every GPL copyright holder is, in practice, Eric: 27 outside lines, all
trivial (a few `if` guards and translation strings). Options, in order of
cleanliness:

1. Rewrite the 20 Dart lines in `api/wsl.dart` and `settings_screen.dart` and
   the 7 translation strings, so the tree is 100% Eric's. An afternoon.
2. Ask the seven or so people for a relicensing email. Standard practice
   (Aseprite did exactly this in 2016 when it left GPLv2).
3. Argue the lines are below the threshold of originality. Probably true
   under German law for an `if` guard, less obviously so for a translated
   sentence. Not worth relying on when option 1 is that cheap.

Going forward, contributions must come in under a CLA or, at minimum, a
Developer Certificate of Origin plus a clear "contributions are licensed to
Bostrot under MIT / with relicensing permission" line in `CONTRIBUTING.md`.
Without that, the first substantive outside PR after the split reintroduces
the problem.

### 3.3 What licence do the shipped binaries carry?

Once a closed module is inside, the shipped `.exe` / `.app` is no longer
"GPLv3". It becomes a proprietary binary that contains GPLv3 components. That
needs:

- a **GPLv3 §7 additional permission** on the open code, granted by Eric,
  allowing combination with "the WSL Manager Pro components distributed by
  Bostrot". Otherwise the open code's own licence forbids the combination for
  anyone who is not Eric, which includes the winget and Store distribution
  chain and anyone mirroring the installer;
- a short **binary EULA** for the release builds (the commercial licence
  text in `LICENSE` is close to this already, but it is scoped to
  companies over USD 1M);
- the Store, winget and GitHub release metadata changed from "GPL-3.0" to
  "Proprietary, includes GPL-3.0 components, source at ...";
- the GPL's source offer still honoured for the open part (a tag per release
  in the public repo is enough).

### 3.4 German and EU specifics

- German courts enforce the GPL as a contract term (the Welte / gpl-violations
  line of cases). That cuts both ways: the split is enforceable if done
  properly, and a sloppy split (shipping the combined binary without the §7
  permission and without owning all the code) is a real, litigable
  violation, not a theoretical one.
- Under §31 UrhG a contributor's grant is limited to the licence they gave,
  so the relicensing consent in 3.2 is genuinely needed, not a formality.
- Advertising law (UWG) and the EU Digital Content Directive (§327 ff. BGB):
  people who bought Pro while the buy page said "Open source, GPLv3" and
  "Free updates, forever" bought that product. Keep giving those buyers
  updates, keep the source of what they bought available, and change the
  marketing copy *before* the first closed release ships, not after. A
  changelog entry and a note on the licence screen is the cheap, honest way
  to do this.
- Microsoft Store policy has sat uneasily with paid GPL apps before: a
  June 2022 policy briefly banned charging for open-source software in the
  Store and was withdrawn a month later. Selling a proprietary binary that
  contains GPL components is the more conventional shape for the Store, so
  a split removes that exposure rather than adding to it.

### 3.5 Trademark

The strongest and cheapest lever against a "WSL Manager Pro Unlocked" fork
is not the code, it is the name. "WSL Manager" is not registered. A DE or EU
word mark costs from about 300 euros (DPMA) and turns any confusingly named fork into
a straightforward takedown regardless of what licence the code is under.
This should happen whether or not the code is split.

## 4. Technical evaluation

### 4.1 The mechanism that works

Dart has no runtime plugin loading and no `dlopen` for Dart code, so
"private package" means "private at source level, compiled in at build
time". The pattern that keeps the public repo buildable is:

1. Define a small interface in the public repo, e.g. `lib/pro/pro_api.dart`:
   an abstract `ProFeatures` with the entry points the free side needs
   (route builders for the AI screens, the settings section, the startup
   hooks for MCP and the dashboard, the diagnosis hook on the distro list).
2. Ship a **stub implementation** in the public repo, e.g. a path package
   `packages/wslmanager_pro_stub/`, that renders the paywall and returns
   no-ops. This is what every fork, every PR build and every contributor
   compiles against.
3. Keep the real implementation in a private repo, `wslmanager_pro`, as a
   Dart package with the same package name and API.
4. Select it at build time with `pubspec_overrides.yaml`, which pub reads
   automatically (Dart 2.17+) and which this repo would need to add to
   `.gitignore`, pointing the dependency at
   `git@github.com:bostrot/wslmanager_pro.git` with a pinned ref. Release
   CI writes that file from a template and uses a deploy key held as a
   repository secret.

The licence manager should stay on the open side: the free build needs to
know it is not Pro, and keeping the key validation open is what lets
contributors test the paywall. Only what the gate *unlocks* moves.

### 4.2 What it costs

- **Refactor**: introduce the interface, route all nine free-side call
  sites through it, and move ~10 000 lines and 104 translation keys.
  Estimate: one to two weeks of
  focused work, plus a beta cycle, because this touches `main.dart`, the
  router and the settings screen. The 24 test files that touch Pro code
  move to the private repo; the public repo keeps interface and stub tests.
- **Two repos forever**: every AI change becomes two PRs when it touches the
  interface. Translations for Pro strings either move to the private repo
  (community translators can no longer see them) or stay public (which
  leaks feature names and strings, harmless but odd).
- **CI**: `test.yml` runs on PRs from forks, where secrets are unavailable.
  Those builds use the stub, which is fine, but it means the public test
  suite no longer exercises AI features at all. `releaser.yml` and
  `macos.yml` need the deploy key and the overrides step; a broken key
  silently produces a stub build, so the release job must assert the real
  package resolved.
- **Local dev**: `flutter run` from a fresh clone gives the stub. Eric's own
  machines need the overrides file; agents working from the task runner need
  read access to the private repo or they cannot touch AI features.
- **Debug-Pro convenience** (`_debugPro`) is lost for anyone without the
  private repo, which is exactly the contributors it was meant to help.
- **Obfuscation**: pass `--obfuscate --split-debug-info` on release builds
  regardless; it is free and raises the binary-patching bar a little.

### 4.3 Alternatives that are cheaper

| Option | Stops self-compile | Stops binary patch | Legal handle vs. forks | Cost |
|--------|:-:|:-:|:-:|------|
| A. Status quo | no | no | none | 0 |
| B. Trademark + binary EULA + keep GPL | no | no | yes (name) | days |
| C. Open core in one repo: `lib/pro/` under a proprietary licence, source visible (Bitwarden, GitLab EE model) | no (but building it is infringement) | no | yes | days + CLA |
| D. Private package (this issue) | yes | no | yes | weeks + ongoing |
| E. Separate proprietary helper process (AI backend as its own signed binary talking to the GPL app over a local socket) | yes for the backend | no | yes, cleanest GPL separation | weeks; AI UI stays open; two binaries to sign and notarise |
| F. Server-side value (licence-checked cloud endpoints) | yes | yes | yes | contradicts the "no backend, BYOK" pitch |

Option E is worth noting because it is the only one the FSF's own guidance
treats as clearly two programs rather than one combined work, which removes
the §7 permission and the contributor question entirely. But the thing the
issue wants to hide is largely UI (the workspace screen, the chat panel),
which would stay open under E.

## 5. Case studies

- **Aseprite** (2016): left GPLv2 for a source-available EULA. Owned the
  copyright after asking contributors. Source still public; building it
  yourself is allowed for personal use, redistributing binaries is not. The
  project kept growing and kept its community. Closest precedent to WSL
  Manager's situation, and it did *not* need a private repo.
- **Bitwarden**: GPL/AGPL app with a `bitwarden_license/` folder under a
  proprietary licence in the same public repo. Code visible, build gated
  by a licence file. Works because of a CLA from day one.
- **GitLab EE / Sourcegraph**: enterprise code in the public repo under a
  separate licence, with a CLA. Sourcegraph took its main repo private in
  2024 after years of that model, citing the overhead of keeping the open
  and enterprise halves apart, which is the cost this document warns about.
- **HashiCorp / Redis / Elastic**: licence changes on previously-open code
  produced forks and lasting goodwill damage far larger than the revenue
  protected. Different scale, same mechanism: the community reads a
  relicense as a broken promise.

## 6. Recommendation

Do not build the private package now. Do the cheap things that give most of
the legal benefit and none of the maintenance cost:

1. **Register the "WSL Manager" word mark** (DPMA or EUIPO).
2. **Add a CLA or DCO** to `CONTRIBUTING.md` so the door to any future split
   stays open. Rewrite the 27 outside lines while at it, or collect consent.
3. **Relicense `chunked_downloader` and `plausible_analytics` to MIT.** They
   are Eric's, and GPL dependencies would complicate any later move.
4. **Ship release builds with `--obfuscate`.**
5. **Put a binary EULA on the release builds** that covers the Pro gate
   ("do not circumvent the licence check, do not redistribute unlocked
   builds"), keeping GPLv3 for the source. This is the Aseprite shape: it
   turns "Pro unlocked" forks into infringement without changing what
   contributors see.
6. Revisit the split only if there is evidence of actual revenue loss to
   self-compiled builds (support tickets from people running unlocked forks,
   an unlocked fork gaining users). Today there is no such evidence.

The reasoning, in one paragraph: the gate protects a USD 19.99 one-time
purchase. The only people a private package stops are Flutter developers
willing to build the app from source, who are the same people who send
patches and who would not have paid. It does not stop binary patching. It
costs a two-week refactor, a permanent two-repo workflow, a public CI that no
longer tests AI, and a public reversal of "Full source, GPLv3", which is
currently a listed feature on the buy page. The legal upside (a takedown
basis against unlocked forks) is available for a few hundred euros through a
trademark and a binary EULA instead.

## 7. If it goes ahead anyway

Order of operations, each step shippable on its own:

1. Legal groundwork: trademark filed, CLA/DCO in place, outside lines
   rewritten or consented, two own packages relicensed, §7 additional
   permission drafted, binary EULA drafted, lawyer review.
2. Marketing and docs: change `pricing.js` and `buy.jsx` (drop "Full source,
   GPLv3" from the free tier, say "core is GPLv3, Pro features are
   proprietary"), the README licence section, the Store and winget listings,
   the licence screen. Announce it in the changelog one release *before* the
   first closed build.
3. Refactor in the open repo, still fully GPL: extract `ProFeatures`, route
   `main.dart`, `router.dart`, `root_screen.dart`, `settings_screen.dart` and
   the other five call sites through it, add the stub package, make the
   integration tests pass against both the stub and the real code. This is
   the step with real engineering risk and it is worth doing as its own PR.
4. Move the implementation into `wslmanager_pro`, add
   `pubspec_overrides.yaml` handling and a deploy key to `releaser.yml` and
   `macos.yml`, with an assertion that the real package resolved.
5. Ship, with the changelog entry, and keep providing the promised free
   updates to existing Pro buyers.

## 8. Things checked and found not to matter

- No third-party GPL/LGPL/MPL dependency other than Eric's own two.
- No `git:` or private pub sources in `pubspec.yaml` today; adding one is
  supported by pub without tooling changes.
- The task runner and CI already build both platforms from a clean checkout
  with no secrets, which is the property the stub package preserves.
- The Store identity check and the key validation stay open-source under
  every option above; hiding them would gain nothing, since the gate they
  set is the thing an attacker patches, not the check.
