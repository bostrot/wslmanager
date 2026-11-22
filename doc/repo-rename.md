# Renaming the GitHub repository to `wslmanager`

The repository was created as `bostrot/wsl2-distro-manager`. The app, the
website and the Store listing have been called WSL Manager for a long time, and
the local checkouts already live in a folder named `wslmanager`. This note
lists what the rename touches, what was changed in the tree ahead of it, and
what only the repository owner can do by hand.

## What the tree already carries

Every link and API URL that named the repository now uses `bostrot/wslmanager`:

- the in-app links (releases page, issue tracker, wiki, Features wiki page,
  info dialog, documentation footer) and the two URLs the app fetches at
  start-up: the releases feed used by the update check and `motd.json`;
- the `images.json` fallback under `raw.githubusercontent.com`;
- the README and its eight translations (badges, wiki, releases, nightly
  build, contributors graph, issues, contributing guide, licence);
- `CONTRIBUTING.md`, the issue-template contact link, the first-timer
  greeting workflow, the releaser's "does this tag exist" lookup and the
  `repository_dispatch` hint in the community-catalogue workflow;
- the audit notes under `doc/audit` and the generated API docs under
  `doc/api`;
- the website (`wslmanager-page`): the macOS download link and its test.

Deliberately left alone, because they are names rather than addresses:

- the release asset and workflow artifact file names
  (`wsl2-distro-manager-v<version>-….zip/.msix/.exe/.dmg`,
  `wsl2-distro-manager-setup.exe`, `…-nightly-archive`). The updater built
  into every installed copy picks its download by asset name, the Homebrew
  cask and the WinGet manifests point at them, and renaming them would
  strand older installs. Rename them, if ever, in a release of their own.
- the Dart package name `wsl2distromanager` and the bundle, MSIX and Store
  identities. Changing any of those is an app rename, not a repository
  rename, and the MSIX identity in particular must never change or the
  Store cannot upgrade existing installs.
- the WinGet identifier (already `Bostrot.WSLManager`), the Scoop and
  Chocolatey package names (owned by their buckets), the MCP server name
  and the catalogue user agent.
- the GitLab mirror links (`gitlab.com/bostrot/wsl2-distro-manager`) — see
  below for what to do with the mirror.

## Order of operations

Do the GitHub rename first and close the tracking issue right after it: the
tree's new links resolve only once the repository exists under the new name.
GitHub then redirects the old name for web pages, the REST API, release
downloads and git operations, so nothing already shipped breaks in between.

1. **Rename on GitHub.** Settings → General → Repository name →
   `wslmanager`. The wiki, issues, releases, stars, secrets, variables,
   environments, Actions history and the Pages site (custom domain
   `wslmanager.bostrot.com`, `CNAME` in the tree) all move with it.
2. **Check that nobody else already owns `bostrot/wslmanager`** — the rename
   form refuses if the name is taken, and a fork or an old experiment under
   that name would need deleting or renaming first.
3. **Point every clone at the new name.** Old-name pushes keep working
   through the redirect, but GitHub warns on each one:

   ```bash
   git remote set-url origin git@github.com:bostrot/wslmanager.git
   ```

   Clones to update: this checkout, the Windows test VM, any CI runner
   caches, and any other machine that pulls the repo.
4. **Verify the redirects the shipped app depends on.** Installed copies
   still call the old URLs until they update:

   ```bash
   curl -sSI https://api.github.com/repos/bostrot/wsl2-distro-manager/releases | head -1
   curl -sSI https://raw.githubusercontent.com/bostrot/wsl2-distro-manager/main/motd.json | head -1
   curl -sSIL https://github.com/bostrot/wsl2-distro-manager/releases/latest | grep -i '^location' | tail -1
   ```

   The first two should answer `301`; the app's HTTP client follows
   redirects on GET, so the update check and the message of the day keep
   working. If either answers `404`, publish a release promptly so users get
   the build with the new URLs.
5. **Homebrew tap.** `bostrot/homebrew-tap`'s `wsl-manager` cask carries the
   full download URL, and the macOS workflow only rewrites its `version`
   and `sha256` lines. Edit the cask's `url` and `homepage` by hand to the
   new name (the old one keeps redirecting, so this is tidiness, not a
   fix). The cask name, `brew install --cask bostrot/tap/wsl-manager`, does
   not change.
6. **WinGet.** Published manifests keep the old download URLs and keep
   working through the redirect; the next release's `publish-winget.yml` run
   submits manifests with the new URL on its own. Nothing to do by hand.
7. **Microsoft Store.** Partner Center → the listing's support, privacy and
   website links, if any of them point at the GitHub repository.
8. **GitLab mirror.** Either rename `gitlab.com/bostrot/wsl2-distro-manager`
   to match and then update the GitLab links and the star badge in the
   README family, or leave the mirror as it is; its links in the tree were
   left untouched on purpose. If the mirror is a push mirror configured on
   GitLab's side, its source URL needs the new name.
9. **n8n.** The `cdn/images.json` webhook caches the raw `images.json` from
   this repository; switch its source URL to the new name (the redirect
   covers it meanwhile).
10. **Website.** Deploy `wslmanager-page` so the macOS download link goes
    straight to the new address.
11. **Anything else that stores the old URL.** Discord server links and
    pinned messages, the Store screenshots' captions, Sponsors and profile
    READMEs, browser bookmarks. `gh repo view bostrot/wsl2-distro-manager`
    still resolves after the rename, which makes old references easy to
    miss; grep for `wsl2-distro-manager` in each place instead.

## Why not rename the Dart package too

`package:wsl2distromanager/…` appears in every import of every file. Renaming
it is a tree-wide mechanical edit with no user-visible effect, and it collides
with whatever else is in flight in the working tree. If it is ever wanted, do
it as its own change on an otherwise clean tree.
