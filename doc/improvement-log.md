# Daily improvement log

One line per run of the daily improvement job: date · area · change · PR.

## Log

- 2026-11-20 · User experience · Filter the Home instance list by name once it holds six or more instances · https://github.com/bostrot/wslmanager/pull/323
- 2026-11-23 · Localization · Say "Work stopped." and "Saving Work as a template..." as whole translated sentences under the instance's own label · https://github.com/bostrot/wslmanager/pull/326
- 2026-11-24 · Bug fix · Point the TurnKey Linux source at TurnKey's own mirror (the RWTH copy 404s) and read single-quoted and absolute links · https://github.com/bostrot/wslmanager/pull/327
- 2026-11-25 · User experience · Ctrl+F (Cmd+F on macOS) jumps to the Home instance filter, F5 reloads the list · https://github.com/bostrot/wslmanager/pull/328
- 2026-11-25 · User experience · Default keyboard shortcuts: Ctrl+N, Ctrl+,, Ctrl+1…9, Ctrl+Tab, F1, a Ctrl+/ cheat sheet, and arrow-key selection with Enter, F2, Delete, Ctrl+D, Ctrl+Shift+T/S on Home · https://github.com/bostrot/wslmanager/pull/329
- 2026-11-26 · Reliability · AI Workspace keeps a tool's last confirmed status unless WSL or vmctl explicitly says the workspace is gone, instead of reading any "not found" as "not installed" · https://github.com/bostrot/wslmanager/pull/330
- 2026-11-27 · Reliability · Say why the TurnKey Linux list could not load (HTTP status, unreachable, or no images) as a translated error, and time out a hung mirror after 20 s · https://github.com/bostrot/wslmanager/pull/331

## Lessons from reviews

- None yet: #323 and #326–#329 merged without review comments, and no
  `daily-improvement` PR has been closed unmerged.

## Ideas backlog

- **Close issue #321.** The setting it asks for ("don't recreate the
  ai-workspace distro after I delete it") shipped in `2c2e2d0`
  (`AiWorkspaceService.autoProvisionPrefKey`), but the issue is still open.
  Needs a maintainer reply pointing at the release that carries it.
- **Stale translation keys.** `de.json`, `pt.json`, `zh_CN.json`, `zh_TW.json`
  each carry one or two keys `en.json` no longer has. Harmless, but
  `check_translations.dart` could flag extras as well as gaps.
- **WSL Containers (`wslc`) went GA on 2026-09-29**
  (https://blogs.windows.com/windowsdeveloper/2026/09/29/wsl-containers-now-generally-available/)
  and added `wslc container restart` and `wslc container cp`. The Containers
  screen already drives `wslc`; check whether restart and copy-in/out are
  exposed for it.
- **More glued-together notices.** `sync.dart` still builds
  `'${'downloaded-text'.i18n()} $distroName'` and
  `'${'connectingtoip-text'.i18n()}: "$syncIP"...'`; same fix as the
  start/stop notices, a `%s` key per sentence. A source-level guard (no
  `'$name ${'…-text'.i18n()}'` shape in `Notify.message`) could keep them out.
- **Tidy TurnKey names.** Scraped names keep the version and a trailing
  space (`Debian 12 Turnkey Core 18.0 `), and the mirror lists Debian 11 and
  12 builds of each appliance side by side. Renaming changes the cache file
  a download is stored under (`rootfsDisplayName`), so it needs a migration.
- **`defaultRepoLink` in `constants.dart` is now unused** (the live default
  is `turnkeyRepoLink` in `lib/api/rootfs_repo.dart`). Remove it the next time
  `constants.dart` is changed by hand on purpose.
- **Ctrl+E / Ctrl+I.** Not bound: no instance has an export action of its
  own (Save as template is the closest), and importing lives inside Add
  instance, which Ctrl+N already opens. Bind them if either gets a button.
- **Settings check for the TurnKey address.** The same three answers
  (`rootfsListingProblem`) could validate "Extra repo for Distros" as it is
  saved, instead of only when the TurnKey Linux source is next opened.
- **Mirror URLs in notices are not links.** The new TurnKey errors name the
  address; a "Copy address" or "Open in browser" action on the InfoBar would
  save retyping it.
- **Other English-substring matches on WSL output.** Grep for
  `.contains('not found')`/`toLowerCase().contains(` on `stderr` across
  `lib/api/` — AGENTS.md says to match `Wsl/…` codes via `wslErrorCode()`.
