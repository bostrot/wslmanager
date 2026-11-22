# AI Workspace Plan

## Overview
AI Workspace provides lifecycle management for local AI tooling within WSL distributions, enabling users to install, start, stop, and uninstall AI services directly from the WSL2 Distro Manager UI.

## Supported Tools

| Tool | Port | Description | Install Method |
|------|------|-------------|----------------|
| **Hermes Agent** | 8081 | Local LLM inference engine | Shell script in distro |
| **OpenClaw** | 8082 | AI agent framework | Shell script in distro |
| **Open WebUI** | 8083 | Chat interface (via Docker) | Docker container |
| **OpenCode** | 4096 | Coding agent with a browser UI (`opencode web`) | Shell script in distro |

## Architecture

### Service Layer (`lib/api/ai_workspace/service.dart`)
```dart
class AiWorkspaceService {
  final ExecutionBroker broker;
  
  // Lifecycle operations per tool
  Future<bool> isInstalled(String distro, String tool);
  Future<bool> isRunning(String distro, String tool);
  Future<void> install(String distro, String tool);
  Future<void> start(String distro, String tool);
  Future<void> stop(String distro, String tool);
  Future<void> uninstall(String distro, String tool);
}
```

**Key Design Decisions:**
- All shell commands routed through `ExecutionBroker` for policy enforcement + audit trail
- Each tool has install/start/stop/uninstall scripts stored in the target distro
- Health checks via HTTP port probing (curl to localhost:PORT)
- Open WebUI runs as Docker container; others run as background processes

### UI Layer (`lib/screens/ai_workspace_screen.dart`)
- Card-based layout showing each tool's status per selected distro
- Actions: Install → Start → Stop / Uninstall buttons with loading states
- Status indicators: installed, running, stopped badges
- Broker wired via `Provider<ExecutionBroker>` from app initialization

### Configuration Layer (`lib/api/ai_workspace/config_service.dart`)
Each card carries a **Configure** button that opens a form built at runtime
from the tool's own description of its settings — no per-tool form lives in
this app, so a tool that adds a setting in its next release gets a field for
it without a code change here.

| Tool | Configuration | Schema source (pulled on app start) | Written by |
|------|---------------|-------------------------------------|------------|
| **OpenCode** | `~/.config/opencode/opencode.jsonc` (JSONC) | `https://opencode.ai/config.json`, the URL its own config file points at (JSON Schema 2020-12) | Merge + whole-file write |
| **OpenClaw** | `~/.openclaw/openclaw.json` (JSON5) | `openclaw config schema` in the workspace (draft-07, ~2 MB, ~2 000 settings) | `openclaw config patch --stdin`, its own validated single write |
| **Hermes Agent** | `~/.hermes/config.json`, if its setup wrote one | None published — the shape is inferred from the file's own values | Merge + whole-file write |
| **Open WebUI** | The container's environment variables | None — inferred from `docker inspect` | Read-only: changing one means re-creating a container that has no volume |

**Key design decisions:**
- The schema is pulled at app start (`AiWorkspaceConfigService.ensureSchemas`),
  never shipped, because what a tool accepts changes with the version the
  workspace installed, not with this app's release.
- A tool that publishes nothing still gets a form: `ConfigSchema.inferred`
  derives field kinds from the values its config file already holds.
- Only edited keys are written. A setting the form never rendered, a comment
  it never parsed and a credential it deliberately never read all stay as they
  are.
- Credentials (`token`, `secret`, `password`, `api_key`, …) are stripped
  before the document reaches the UI and are never re-written unless the user
  types a new value.
- Documents cross into the environment base64-encoded, so quotes, `$` and
  backticks in a value cannot reach bash.

### Routing
- Route: `/ai-workspace` in `lib/nav/router.dart`
- Accessible from navigation sidebar

## Security Considerations
- All commands pass through ExecutionBroker policy enforcement
- `allowedCommands` whitelist restricts which shell commands can execute
- `readOnly` mode blocks package installation (apt/pip/npm) unless explicitly allowed
- Audit trail records every install/start/stop/uninstall operation with timestamp, command, exit code, and duration

## Future Enhancements
- [ ] Configurable tool ports per distro
- [ ] Resource usage monitoring (CPU/RAM per service)
- [ ] Multi-distro AI cluster support
- [x] Tool configuration UI — dynamic, from each tool's own schema (bostrot/ai-tasks#72)
- [ ] Automatic health check scheduling
