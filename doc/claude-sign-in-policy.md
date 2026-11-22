# Why there is no "Sign in with Claude"

The AI chat used to offer a second provider next to the OpenAI-compatible
API key: *Claude subscription*, an OAuth 2.0 + PKCE sign-in against
`claude.ai` that then called the Messages API with the user's Pro/Max plan.
It shipped disabled (no client ID) and was removed in September 2026
(`bostrot/ai-tasks#20`). This note records why, so it is not rebuilt.

## Anthropic's position

Anthropic's Claude Code documentation, *Legal and compliance* →
*Authentication and credential use*
(<https://code.claude.com/docs/en/legal-and-compliance>), states:

- OAuth authentication "is intended exclusively for purchasers of Claude
  Free, Pro, Max, Team, and Enterprise subscription plans and is designed to
  support ordinary use of Claude Code and other native Anthropic
  applications."
- Developers building products that interact with Claude "should use API key
  authentication through Claude Console or a supported cloud provider.
  Anthropic does not permit third-party developers to offer Claude.ai login
  into their own applications, or to route requests through Free, Pro, or
  Max plan credentials on behalf of their users. Moreover, developers may not
  collect, store, or intermediate Claude.ai credentials or session tokens."
- "Anthropic reserves the right to take measures to enforce these
  restrictions and may do so without prior notice."

Consequences for this app:

- There is no public "Sign in with Claude" registration and no way to obtain
  a client ID for a third-party desktop app. The only OAuth client is Claude
  Code's own, and reusing it is exactly what the policy forbids; Anthropic
  has enforced this server-side since early 2026 (consumer OAuth tokens are
  rejected outside Claude Code / claude.ai).
- Storing the resulting access/refresh tokens in the app's preferences would
  itself violate the "may not collect, store, or intermediate" clause.

The support article the task linked
(<https://support.claude.com/en/articles/13371040-log-in-to-your-console-account>)
only covers Console login and does not describe any third-party sign-in
program.

## What the app does instead

Users bring an API key. For Claude that is a key from the Claude Console
(platform.claude.com), billed to the key owner under the Commercial Terms,
which the policy explicitly allows. The Settings → *Bring Your Own AI Key*
fields take any OpenAI-compatible endpoint; nothing Claude-specific remains
in the app.

Builds before the removal may have left `ClaudeAccessToken`,
`ClaudeRefreshToken`, `ClaudeTokenExpiry`, `ClaudeOAuthClientId`,
`ClaudeModel` and `AiProvider` in shared preferences.
`AiService.purgeRetiredClaudePrefs()` deletes them at startup.
