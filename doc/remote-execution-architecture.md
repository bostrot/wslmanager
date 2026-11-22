# Remote Execution Architecture

## Overview
The Execution Broker provides a unified abstraction layer for shell command execution, enabling both local and remote WSL operations through a single interface. This enables managing WSL distributions on remote machines via SSH without duplicating business logic.

> **Status (accurate as of 2026-08):** the `ExecutionBroker` is wired and
> load-bearing — every Phase-05 verb and every in-distro file read/write in
> `wsl.dart` goes through `_brokeredWsl` → `ExecutionBroker.run`, which enforces
> the per-call timeout and reaps the child. **Remote** WSL, however, is *not*
> routed through the `RemoteShell` class the diagram below shows: `RemoteShell`
> exists (`lib/api/execution/remote_shell.dart`) but is **not instantiated
> anywhere in production**. Instead, `wsl.dart` decides local-vs-remote itself
> and, for remote, builds a plain `ssh … wsl …` command (with the remote
> command made safe for the host's login shell by `remoteHostCommand()` in
> `lib/api/remote_command.dart` — bare when every token is shell-neutral, an
> encoded PowerShell wrapper otherwise; see that file's header for why no
> quoting style works across cmd.exe, PowerShell and bash) that it hands to either
> the broker (`_brokeredWsl`) or, for the older `_runWsl`/`_startWsl` paths,
> straight to `shell.run`/`shell.start`. So the diagram is the *intended*
> design; the "RemoteShell" box is aspirational until those call sites are
> migrated onto it. Treat the "✅ Complete" table below as "broker-wired", not
> "RemoteShell-wired".

## Architecture Diagram

```
┌─────────────────────────────────────────────────┐
│                 Widget Tree                      │
│  Provider<ExecutionBroker>.value                 │
└──────────┬──────────────────────────────────────┘
           │
┌──────────▼──────────────────────────────────────┐
│              ExecutionBroker                     │
│                                                  │
│  • Policy Enforcement                            │
│    - allowedCommands whitelist                   │
│    - readOnly mode (blocks apt/pip/npm)          │
│  • Audit Trail                                   │
│    - Timestamp, command, exit code, duration     │
│    - Severity classification                     │
│  • Execution Methods                             │
│    - run(ExecutionRequest) → ExecutionResult     │
│    - runStream(ExecutionRequest) → Stream        │
└───────┬──────────────────────────────────────────┘
        │ wraps
        ▼
┌──────────────────┐      ┌──────────────────┐
│   ProcessShell   │      │   RemoteShell    │
│  (local exec)    │      │  (SSH mux exec)   │
└──────────────────┘      └──────────────────┘
```

## Core Components

### 1. Execution Models (`lib/api/execution/models.dart`)

#### ExecutionRequest
Typed request object replacing raw command/argument arrays:
```dart
class ExecutionRequest {
  final String command;
  final List<String> arguments;
  final Duration timeout;           // default: 5 minutes
  final bool captureOutput;         // default: true
  final bool readOnly;              // policy flag
  final String? workingDirectory;
  final Map<String, String>? environment;
  final bool runInShell;
}
```

#### ExecutionResult
Typed result with structured output:
```dart
class ExecutionResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration duration;
  final Object? error;
  final AuditSeverity auditSeverity; // info | warning | error
}
```

#### ExecutionEvent Hierarchy (Streaming)
For long-running commands with real-time output:
- `ExecutionStarted` → command, arguments, timestamp
- `StdOutChunk` / `StdErrChunk` → data bytes
- `ExecutionExited` → exitCode, duration
- `ExecutionError` → error message

#### AuditEntry
Immutable audit log entry:
```dart
class AuditEntry {
  final DateTime timestamp;
  final ExecutionRequest request;
  final int? exitCode;
  final Duration? duration;
  final AuditSeverity severity;
  final String? errorMessage;
}
```

### 2. ExecutionBroker (`lib/api/execution/broker.dart`)

Wraps any `Shell` implementation with cross-cutting concerns:

**Policy Enforcement:**
- `allowedCommands`: whitelist of permitted commands (null = no restriction)
- `readOnly`: blocks known writable operations (apt install, pip install, npm install, etc.)
- Throws `SecurityException` on policy violation (no audit entry created)

**Audit Logging:**
- Every execution creates an AuditEntry with timestamp + request
- Updated post-execution with exitCode, duration, severity
- Accessible via `auditLog` getter; clearable via `clearAuditLog()`

### 3. RemoteShell (`lib/api/execution/remote_shell.dart`)

Implements the `Shell` interface over SSH:

**SSH Multiplexing:**
```bash
ssh -o ControlMaster=auto \
    -o ControlPersist=10m \
    -o ControlPath=~/.tmp/wsl2dm_ssh_mux.sock \
    user@host command args...
```

- Single persistent connection reused across commands (10min TTL)
- Server alive keepalive: 30s interval, 3 max misses
- Batch mode: no password prompts, key-only auth

**Prefs Keys:**
| Key | Type | Description |
|-----|------|-------------|
| `UseRemoteWSL` | bool | Enable remote WSL execution |
| `RemoteWSLTarget` | string | SSH target (user@host) |

## Migration Pattern

### Before (raw shell.run)
```dart
final result = await shell.run('wsl', ['--list']);
if (result.exitCode != 0) throw Exception(result.stderr.toString());
return WSLApi().utf8Convert(result.stdout);
```

### After (broker with fallback)
```dart
_ShellResult _runWsl(List<String> args) async {
  if (_broker != null) {
    final result = await _broker!.run(ExecutionRequest(command: 'wsl', arguments: args));
    return _ShellResult.fromExecution(result);
  } else {
    final result = await shell.run('wsl', args);
    return _ShellResult.fromProcess(result);
  }
}
```

### _ShellResult Adapter
Unifies `ExecutionResult` and `ProcessResult` access patterns:
```dart
class _ShellResult {
  final int exitCode;
  final dynamic stdout;   // String (broker) or List<int> (shell)
  final dynamic stderr;
  
  factory _ShellResult.fromExecution(ExecutionResult r);
  factory _ShellResult.fromProcess(ProcessResult r);
}
```

## Files Migrated

| File | Calls Migrated | Status |
|------|----------------|--------|
| `lib/api/wsl.dart` | Phase-05 verbs + file I/O via `_brokeredWsl` | ✅ Broker-wired (timeouts, child reaping). Legacy `_runWsl`/`_startWsl` still call `shell.run`/`shell.start` directly. |
| `lib/api/mount_service.dart` | 5 shell.run() | ⚠️ Uses `ProcessShell` directly, not the broker |
| `lib/api/execution/remote_shell.dart` | — | ❌ Defined but not instantiated in production; remote is done inline in `wsl.dart` |

## Testing Strategy

### Unit Tests (`test/execution_broker_test.dart`)
- **TestShell mock**: returns configurable ProcessResult without spawning real processes
- Policy enforcement: whitelist blocking, readOnly mode
- Audit trail: recording, accumulation, clearing
- Result capture: stdout/stderr bytes, exit code, duration
- Streaming events: ExecutionStarted, ExecutionError paths
- Error handling: shell exception catching

### Integration Tests
- `WSLManager` accepts optional `executionBroker` for test compatibility
- Full broker wiring tested via app startup flow

## Security Model

1. **Command Whitelisting**: `allowedCommands` restricts which executables can run
2. **Read-Only Mode**: Blocks package installation commands (apt/pip/npm) by default
3. **Audit Trail**: Every execution logged with full metadata for forensic analysis
4. **Policy Failures**: Thrown as SecurityException, NOT recorded in audit log

## Future Enhancements
- [ ] Per-command timeout enforcement
- [ ] Rate limiting for rapid successive commands  
- [ ] Command templating (parameterized ExecutionRequest presets)
- [ ] Remote connection status indicator UI
- [ ] SSH key management integration
