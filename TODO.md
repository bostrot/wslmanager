# TODO

Working list for WSL Distro Manager. Longer background lives in the audit
reports under `doc/audit/` and the playbook under
`.maestro/playbooks/2026-08-28-WSL-Manager-Backlog-Audit/`.

---

## Release readiness review (2026-09-04)

Verified on this machine against `beta` (`b2b957a`), Flutter 3.41.6 — the
same pin CI uses. Tracked as `bostrot/ai-tasks#9`.

**Measured**
- `flutter test`: 1016 passed, ~10 skipped. `check_translations`: exit 0.
- `flutter analyze`: **exit 1, 111 issues** (1 warning in `lib/`
  `wsl.dart:2084` dead null-aware, 4 warnings in `test/`, 106 infos —
  mostly `deprecated_member_use`, `strict_top_level_inference`,
  `use_super_parameters`). `macos.yml` runs `flutter analyze` as a gate, so
  the macOS CI build fails as things stand; `releaser.yml` does not run it.
- `pubspec.yaml` is still `1.11.0`, which is the last tag. `releaser.yml`
  checks whether that release exists and skips release creation when it does
  — nothing ships until the version is bumped.
- `beta` has **53 commits not on `origin/beta`**. PR #318 (`beta` → `main`)
  is `CONFLICTING`: GitHub `main` gained PR #316 (Korean translation:
  `lib/i18n/ko.json`, `constants.dart`, `navbar.dart`) that the local `main`
  does not have, and `beta` deleted `navbar.dart`. Expect to drop the
  `navbar.dart` side, keep `ko.json`, and make `check_translations` pass with
  a tenth locale.
- `releaser.yml` still runs `gh workflow run publish-scoop.yml`; that
  workflow was deleted (`6aa2271`). The failure is masked because
  `publish-store` runs last in the same step — remove the line.
- Live endpoints: licence validate answers correctly; the checkout lookup
  answers `pending`; **`https://wslmanager.com/buy` is 404** while
  `macBuyUrl` in `constants.dart` points at it; the CDN `images.json` still
  answers 200 with an empty body; `motd.json` fine.
- macOS build: ad-hoc signed, **not notarized** (`macos.yml` says so) —
  Gatekeeper will refuse the DMG on first open for every buyer.
  `MACOSX_DEPLOYMENT_TARGET` is 10.15 although Virtualization.framework
  needs macOS 11+ (12+ for macOS guests) and `vmctl` is built arm64-only;
  set the target so Finder refuses cleanly on an unsupported Mac.
- Windows does **not** register the `wslmanager://` scheme (no
  `protocol_activation` in `msix_config`, nothing in `installer/setup.iss`),
  so the "Activate in WSL Manager" button on `/buy/success` is a no-op on a
  Windows GitHub build; the key can still be pasted.
- The in-app "What's new" dialog shows the GitHub release body, and the
  releaser creates releases with `--notes "This is an automated release."`
  plus generated notes — write real notes before tagging.
- Website (`wslmanager-page`, GitLab Pages): the pricing/buy work is
  **uncommitted**; `npm run lint` and `npm run build` pass with it in place;
  `IS_TEST_MODE = true` and both plan links are `buy.stripe.com/test_…`.
- `wslmanager-scripts`: one unpushed local commit (`7fe6017`) and the remote
  `main` has moved on (`535ff1b`, plus a 2025 PR merge) — pull/rebase before
  pushing.

**Ship blockers, in order**
1. ~~Get `flutter analyze` to exit 0 (fix or explicitly allow the infos) so
   `macos.yml` passes.~~ Done 2026-09-06 (`bostrot/ai-tasks#33`): the
   Analyze step runs `flutter analyze --no-fatal-infos` (warnings and
   errors stay fatal; 98 style-only infos remain), and the job moved from
   the deprecated `macos-14` runner (Xcode 15.4, cannot read vmctl's
   Swift 6 manifest) to `macos-26` (Xcode 26.6, the local toolchain).
   Every step — analyze, tests, sharing tests, vmctl tests,
   `build_macos.sh`, dmg/zip packaging — was run locally on that
   toolchain before the change. The infos themselves are still open.
2. Bump the version (1.12.0) and write release notes: the audit's 214
   fixes, MCP server, AI workspace/sandbox/task queue, snippets sharing,
   macOS VMs (beta), licence keys.
3. Push `beta`, resolve the #316 conflict, merge PR #318; that is what makes
   `releaser.yml` tag and publish.
4. Drop the `publish-scoop.yml` trigger from `releaser.yml`.
5. ~~macOS distribution: Developer ID certificate as `CODESIGN_IDENTITY`,
   `notarytool submit … --wait` + `stapler` in `macos.yml`, add a macOS
   section under "Install" in the README.~~ Done 2026-09-06: the 2.0.0 dmg
   and zip on the release are Developer ID signed, notarized and stapled
   (`scripts/sign_macos_release.sh`, run by hand), the README has the
   Homebrew tap (`bostrot/homebrew-tap`, cask `wsl-manager`), and
   `macos.yml` signs in CI once the five secrets it documents are set.
   Still open: raise `MACOSX_DEPLOYMENT_TARGET` from 10.15, and set those
   secrets so the next release does not need the manual run.
6. Website: commit the buy page, flip `IS_TEST_MODE`/links to the live Stripe
   payment links, deploy so `/buy` exists before any macOS binary is public.
   That also unblocks `bostrot/ai-tasks#7` and `#8`.
7. Tick **Enable Device Flow** on the "WSL Manager" OAuth app
   (github.com/settings/developers, `bostrot/ai-tasks#6`). The client id
   is bundled in the app now, but GitHub still answered
   `device_flow_disabled` on 2026-09-04, so sharing fails at sign-in until
   the box is ticked. The `WSLMANAGER_GITHUB_CLIENT_ID` variable is
   optional (override only).
8. Push `images.json` to the CDN (empty since 2026-08-31, see "Now").
9. Store: Submission 71 draft, keywords, "What's new" (upstream #307 reports
   1.11.0 never reached the Store).

**Should do before or right after, not blocking**
- Register `wslmanager://` on Windows (MSIX `protocol_activation` + Inno
  registry keys) or word `/buy/success` per platform. The Dart side is
  already host-agnostic — `LicenseScreen` listens on every platform — so
  only the runner and installer registration is missing; until it lands,
  Windows buyers paste the key into the activation box.
- `wslmanager.com/buy` must price the Windows licence at US$ 14.99 (the Mac
  one stays 19.99). The app links to it with `?platform=windows`.
- `AGENTS.md` still says "no license keys, no validation backend".
- Upstream issues worth a look before tagging: #317 (window size / dark
  mode not remembered), #309 (default user overwrites `systemd=true`), #311
  / #312 (create dialog), #303 (compact does not check drive space — likely
  closed by `freeSpaceBytes` in `wsl.dart:2107`, verify and close).
- Decide Templates removal vs merge (see "Decisions open").

---

## Next — hardening the AI features before release (planned 2026-09-01)

Ordered by risk-to-users, not effort. Verified against the code, not guessed.

### 1. Make Cancel actually cancel the agent run (highest value) — done
`CancelSignal` is threaded through `runAgentOn` and both provider loops
(`ai_service.dart`). Kept for the record.

Cancel today only bumps `_requestGeneration`, so the UI drops the reply — but
the agent loop in `ai_service.dart` keeps running: tools keep executing on the
real machine and requests keep billing the user's key, now for up to 100
steps. Thread a `CancelSignal` (exists in `api/cancellation.dart`) through
`runAgentOn` → both provider loops → `_executeTool`, checked before each
iteration and each tool call. The task runner's auto-continue must honour it
too.

### 2. Cap the context the agent sends per turn — done
`_maxHistoryMessages = 30` / `_maxHistoryChars = 30000` in `ai_service.dart`.

`_historyMessages()` serialises the **whole** transcript into every request —
the old `take(10)` cap was lost when tool-use landed. A long-lived chat (they
persist now) grows every request without bound. Keep the last ~30 user/
assistant turns (chars-capped), and within one run cap the accumulated
tool-result messages the same way `_maxToolResultChars` caps one result.

### 3. Live run telemetry + a hard stop
With 100 steps × 6 auto-continue rounds possible, the panel should show
"step 12 — 34k tokens" style progress during a run and offer one button that
stops run *and* auto-continue. Falls out of #1 almost for free.

### 4. Sandbox creation: progress, disk check, cancel — done
`sandbox_service.dart` uses `onReceiveProgress` and `freeSpaceBytes()`.

- `dio.download` has `onReceiveProgress`; the "downloading" stage should show
  a percentage (the image is ~700 MB).
- Check `freeSpaceBytes()` (exists in wsl.dart, unused here) before starting
  and refuse below ~3 GB — this machine hit **0 bytes free** on 2026-08-31
  and the failure mode was a hung Dart compiler, not a clean error.
- A `CancelSignal` for the download; delete the partial file.

### 5. Sandbox honesty: document the network caveat
The sandbox isolates the *tools* (host/other-distro access is impossible by
construction), but the distro itself has normal outbound network. Say so in
the sandbox InfoBar and README — "isolated" must not overpromise. True
network lockdown (wsl.conf / firewall) is a research item, not a quick fix.

### 6. Chat polish (cheap, high-touch)
- Copy button on assistant code blocks.
- Sandbox picker: let "Add custom Ubuntu distro" offer the whole catalog, not
  just Ubuntu (the plumbing already takes any rootfs URL).
- Guard the dock when its sandbox is deleted mid-session (show the assistant
  instead of a dead transcript).
- Streaming responses (SSE) — biggest UX win, biggest effort; both provider
  APIs support it. Do last.

### 7. Release train (mostly manual, blocks everything shipping)
- Bump version, write real "What's new" (the audit closed 214 findings; then
  MCP/AI/sandbox landed) — the Store text still describes an old release.
- Submit the draft (Submission 71) after the keywords question.
- The old local `return true;` Pro grant is gone; debug builds run as Pro
  via `_debugPro`, which is `kDebugMode`-gated and off under tests.
- The standing manual item below (CDN push) gates the catalogue freshness.

---

## Now

### Push `images.json` to the CDN — the one manual step left from the audit
The repo copy of `images.json` is **not** the runtime source in release: the
app fetches `https://n8n.aachen.dev/webhook/cdn/images.json` first and falls
back to the bundled asset only when that request fails. Measured 2026-08-31:
the endpoint currently answers **HTTP 200 with an empty body**, so release
users are living on their installer's bundled copy anyway — one more reason
the upload matters. The exact payload and steps:
`.maestro/playbooks/2026-08-28-WSL-Manager-Backlog-Audit/Working/cdn-upload.md`.

Debug builds now skip the CDN entirely and read the repo's own `images.json`
(`App.preferBundledCatalogue`, on under `kDebugMode`, off under
`flutter test`), so a catalogue edit is testable in `flutter run` before the
push — verified live 2026-08-31 in a `WSLM_FORCE_PRO` debug run: the create
screen's suggestion list served the repo's 19 entries (Ubuntu 26.04 first).

### Wire remote WSL onto `RemoteShell` (optional cleanup)
The `RemoteShell` class exists but is not instantiated in production —
`wsl.dart` decides local-vs-remote itself and builds `ssh … wsl …` inline, and
`mount_service.dart` calls `shell.run` directly rather than the broker.
`doc/remote-execution-architecture.md` has been corrected to say so (2026-08),
so nothing is *wrong* now; routing those call sites through `RemoteShell` +
the broker would be a consistency cleanup, not a fix. Needs a real remote host
to verify.

### Hermes install tail noise (upstream)
`uv sync --locked` errors on a stale `uv.lock` — non-fatal, but it dominates
any failure tail shown on the card.

### Integration tests cannot run on this host
`flutter test integration_test/` builds the app and then fails with "Unable to
start the app on the device" / "The log reader stopped unexpectedly" — an
environment problem, not a code one, reproduced identically across every
Phase 08 slice. Worth retrying after the next Flutter upgrade; until then the
e2e suite is only exercised in CI or on another machine.

---

## Store

### Keywords will not save in Partner Center
Seven controlled trials; the field silently reverts with no error and no
failed request. Ruled out: the 21-word cap, the "Windows" trademark, emptying
the field, one-change-per-save. Current value:
`wsl, manager, gui, linux, wsl2, docker, virtual disk compact`
Next step: try one swap by hand; if it reverts for you too, raise it with
Partner Center support.

### Submission 71 is live (2026-09-06)
Published 2026-09-06 19:54 UTC. The public listing now serves the new
description, short description, 11 feature bullets, 8 v1.11.0 screenshots and
the "WSL Manager 2.0" release notes; the old notes ("Fixed window not
closing…") are gone. Seeing the previous screenshots for a while after a
submission goes live is the Store client and CDN caching them, not a failed
submission.

### Checking the listing without Partner Center
`dart run scripts/check_store_listing.dart --min-screenshots 8 --expect-notes
"WSL Manager 2.0"` reads the public product detail endpoint and prints what a
customer actually sees — screenshot count and sizes, logos, feature bullets,
description lengths and "What's new" — exiting non-zero when the live listing
falls short. Partner Center shows the draft; this shows what shipped.

Nothing in the repo submits listing assets: `.github/workflows/publish-store.yml`
uploads the MSIX only, so screenshots and text stay whatever was last submitted
by hand.

---

## Build pins to re-check before release
- Flutter `3.41.6` in both workflows (`re_editor` breaks on newer). Local
  toolchain matches.
- `releaser.yml` pins `CodeDependencies.iss` to commit `7ab4aac4…` because
  upstream edited `master` and broke the checksum.

---

## Decisions open

### Remove or merge Templates into Distro packages
Templates (app-internal snapshot tars) and Distro packages (official `.wsl`
files with `wsl-distribution.conf`) solve the same problem; packages are the
portable superset. The Templates screen now carries a deprecation banner
pointing at Distro packages (2026-08-31). Open: pick removal or merge — a
merge would mean a "convert template to package" path so existing template
files are not orphaned — and drop the Home-row archive button along with it.


### Mac version with Apple Virtualization
Microsoft Store and Mac App Store share no entitlements, so a cross-platform
user pays twice. Recommendation: accept that rather than build a licence
server, which would undo the no-account, no-key design. Update 2026-09:
the macOS port exists (`macos/`, `vmctl`, `AppleVmApi`) and Pro on the Mac is
sold as a licence key from wslmanager.com — see the review above.

---

## Done — the 2026-08 backlog audit (Phases 01–08)

Each phase's full record lives in its playbook file; verification is quoted
from there.

### Follow-ups closed 2026-08-31
- **Remote WSL argv quoting** — `_buildRemoteArgs(quoteCommand: true)` now
  POSIX single-quotes each remote-command token so the remote login shell
  keeps it whole; a `bash -c 'a | b'` no longer loses everything after the
  first space over SSH. The exec paths (`_runWsl`, `_brokeredWsl`,
  `_startWsl`) opt in; the interactive terminal launches stay raw. Verified:
  `wsl_test.dart` "a remote command with spaces and metacharacters is quoted
  whole".
- **Keep-alive survives a hard kill** — `ProcessReaper` puts every child
  started through `ProcessShell.start` into a Windows job object with
  `KILL_ON_JOB_CLOSE`, so a force-kill of the app (Task Manager,
  `Stop-Process -Force`) takes the `wsl … sleep infinity` keep-alive and any
  streaming exec down with it. Best-effort and no-op on failure. Verified:
  `process_reaper_test.dart` confirms an adopted child is actually placed in a
  job (`IsProcessInJob`), and never throws on a bad pid.

### Phase 01 — foundation & ship blockers (2026-08-28)
- **ExecutionBroker kills timed-out children** instead of leaking `wsl.exe`
  (measured 842 orphans before the fix). Verified: leak watch over the 5s
  poll held the process count flat.
- **The unconditional Pro grant is gone** from `license_manager.dart`;
  Pro-gated click-throughs use `--dart-define=WSLM_FORCE_PRO=true`, debug-only.
  Verified: the 4 licence tests that documented the hack pass.
- PowerShell UI-automation toolkit added under `.maestro/tools/`.

### Phase 02 — AI workspace correctness (2026-08-28)
- Docker readiness, install-survives-navigation, retry-from-error, shell
  quoting, sticky failure messages, installPath reset. Verified live against
  the real `ai-workspace` distro and by the service/screen test suites.

### Phase 03 — Hermes/OpenClaw lifecycle (2026-08-28)
- Hermes driven through `serve` (not the messaging gateway), installs
  budgeted by silence (measured 482s cold with 306s of quiet), `--skip-setup`
  for the TTY wizard, port-based status, session keep-alive, dashboard URL
  handling. Verified end to end: install exit 0 in 244s unattended, 9119
  answers HTTP 200 from Windows, stop frees the port.

### Phase 04 — WSL docs audit (2026-08-28)
- The documented `.wslconfig` / `wsl.conf` / CLI surface inventoried, diffed
  against the app, verified against a running WSL 2.6.3, and ranked into the
  Phase 05 list.

### Phase 05 — WSL feature gaps (2026-08-28)
- New `.wslconfig` engine (comment-preserving round trips), `wsl.conf` and
  `wsl-distribution.conf` editors, `--manage` surfaces, custom-distro
  packaging, serialized config writes (measured live: concurrent writes had
  silently dropped keys). Verified: `wsl_test.dart`'s round-trip suites and a
  live runtime pass, both recorded in the playbook.

### Phase 06 — rootfs catalogue (2026-08-28)
- `images.json` re-sourced to official vendor infrastructure, every URL
  verified mechanically, all 19 entries install-tested in the app. Verified:
  the catalogue test suite plus the recorded install runs. **The CDN push is
  the one step still open — see "Now".**

### Phase 07 — click-through UI audit (2026-08-28)
- Every screen, dialog and state walked at 1400x860 and 900x860, light and
  dark, all nine locales: **214 findings** (14 blockers, 107 majors, 93 nits),
  each with `file:line` and a screenshot or measurement, consolidated into 20
  ordered work items in `doc/audit/ui-ux/index.md`.

### Phase 08 — fix the findings (2026-08-28 – 2026-08-30)
- **All 214 findings closed, none deferred**, across all 20 work items —
  unsaved-work guards, honest error reporting, one notification surface,
  cancellable long operations, keyboard operability, accessible names,
  destructive-action styling and confirmation, one dialog contract, theme
  tokens with AA-measured contrast, localization holes (a whole dialog was
  English in six locales), sentence-case copy, an honest paid surface with a
  price, settings validation, the create form, home-list layout, the
  recommendations/chat panels, and the templates/snippets/mount polish pass.
- Verified: `flutter analyze` clean (two pre-existing warnings, untouched),
  `flutter test` 828 passing, `dart run scripts/check_translations.dart`
  exit 0, `flutter build windows --release` succeeds, no `return true;` Pro
  grant in `license_manager.dart`, and the running tally per slice in the
  Phase 08 playbook. The per-finding fix locations live in the `Fixed in`
  columns of `doc/audit/ui-ux/index.md`.
