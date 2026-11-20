# Daily improvement log

One line per run of the daily improvement job: date · area · change · PR.

## Log

- 2026-11-20 · User experience · Filter the Home instance list by name once it holds six or more instances · PR_LINK

## Lessons from reviews

- None yet: 2026-11-20 is the first run, and no earlier `daily-improvement`
  PRs exist to learn from.

## Ideas backlog

- **Close issue #321.** The setting it asks for ("don't recreate the
  ai-workspace distro after I delete it") shipped in `2c2e2d0`
  (`AiWorkspaceService.autoProvisionPrefKey`), but the issue is still open.
  Needs a maintainer reply pointing at the release that carries it.
- **Ctrl+F / F5 on Home.** The app has no keyboard shortcuts outside the AI
  chat dock. Ctrl+F could focus the new instance filter (`list.dart`,
  `_filterController`), F5 could bump `reloadTick`. Open question: where to
  put the `Shortcuts` so they work without the list holding focus, and
  without fighting the AI chat input.
- **Stale translation keys.** `de.json`, `pt.json`, `zh_CN.json`, `zh_TW.json`
  each carry one or two keys `en.json` no longer has. Harmless, but
  `check_translations.dart` could flag extras as well as gaps.
- **WSL Containers (`wslc`) went GA on 2026-09-29**
  (https://blogs.windows.com/windowsdeveloper/2026/09/29/wsl-containers-now-generally-available/)
  and added `wslc container restart` and `wslc container cp`. The Containers
  screen already drives `wslc`; check whether restart and copy-in/out are
  exposed for it.
