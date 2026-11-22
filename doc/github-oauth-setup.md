# GitHub OAuth setup (snippet sharing)

"Share with community" opens a pull request on `bostrot/wsl-scripts`. It signs
in with GitHub's **device flow**, which needs a client id and no client
secret.

## Client id yes, client secret never

- **Client id** is public information. It travels in every device-flow
  request and is safe to compile into the app or commit to CI config.
- **Client secret must never be in the app.** Anything shipped in a binary
  can be extracted from it, so a secret in a desktop build is a published
  secret. GitHub classes desktop apps as *public clients* for exactly this
  reason, and the device flow takes no secret at all.

So: do not generate a client secret for this app. If one already exists,
leave it unused — its presence is not needed and copying it anywhere is a
leak. A confidential flow (with a secret) would only make sense behind a
server we control, which this app deliberately does not have.

## Creating the app

Two minutes by hand, or drive it with the Claude browser MCP. Either way the
steps and the guardrails are the same.

**Agent instructions (browser MCP):**

1. Ask the user to sign in to GitHub themselves in the browser pane — do not
   type their credentials, and do not use a saved password to log in to an
   account for a task they did not ask for. If a password manager
   integration is available and the user asked for the sign-in, request the
   credential through it rather than handling the value.
2. Navigate to <https://github.com/settings/developers> → **OAuth Apps** →
   **New OAuth App**.
3. Fill in: application name `WSL Manager`, homepage
   `https://wslmanager.com`, and any URL as the authorization callback —
   the device flow never redirects, but the field is required (the existing
   app uses `http://localhost:33210/callback`, see below).
4. Submit, then on the app's page tick **Enable Device Flow** and save.
5. Copy the **Client ID** only. **Do not click "Generate a new client
   secret".** Report the id back; it is not sensitive.
6. Nothing else on that page needs changing.

## The app that exists

The "WSL Manager" OAuth app was created on 2026-09-04 (bostrot/ai-tasks#6):

- Client ID `9c2cbef8ac5d26ec745b` — bundled in the app as
  `kDefaultGithubClientId` in `lib/api/github_publish.dart`.
- Authorization callback URL `http://localhost:33210/callback`. The device
  flow never redirects, so this value is unused; it only had to be filled
  in because GitHub requires the field.

**Device flow was still disabled on that app when checked on 2026-09-04**:
GitHub answered the device-code request with `device_flow_disabled`. Until
the box is ticked, "Share with community" shows GitHub's own message,
*Device Flow must be explicitly enabled for this App*, on the first click.
To fix: <https://github.com/settings/developers> → OAuth Apps → WSL Manager
→ tick **Enable Device Flow** → Update application. No code change needed.

To check from a terminal (creates nothing but a throw-away device code):

```bash
curl -s -X POST https://github.com/login/device/code \
  -H "Accept: application/json" \
  -d "client_id=9c2cbef8ac5d26ec745b&scope=public_repo"
```

A `device_code` in the reply means the flow works; `device_flow_disabled`
means the box is not ticked.

## Wiring the id in

Nothing to do for the app above: the id is compiled in and
`GithubPublisher.isConfigured` is true in every build. To point a build at a
different OAuth app instead:

```bash
flutter build macos --dart-define=GITHUB_CLIENT_ID=Ov23liXXXXXXXXXXXXXX
```

`kGithubClientId` in `lib/api/github_publish.dart` takes the define when it
is non-empty and falls back to the bundled id otherwise. An *empty* define
(`--dart-define=GITHUB_CLIENT_ID=`) therefore does not disable sharing; it
is what the release scripts pass while their CI variable is unset.

The requested scope is `public_repo` — enough to fork, push a branch and open
a pull request, and nothing more.

### Release builds

Both release paths forward the optional repository **variable**
`WSLMANAGER_GITHUB_CLIENT_ID` as that override (GitHub → Settings → Secrets
and variables → Actions → *Variables* tab — not *Secrets*, the id is public,
and variable names may not start with `GITHUB_`):

- `.github/workflows/macos.yml` exports it as `GITHUB_CLIENT_ID` for
  `scripts/build_macos.sh`, which passes it on as the `--dart-define` above.
  The same env var works for local builds:
  `GITHUB_CLIENT_ID=Ov23li... ./scripts/build_macos.sh`.
- `.github/workflows/releaser.yml` passes it straight to
  `flutter build windows`.

The variable does not need to exist: unset, both builds ship the bundled id.
