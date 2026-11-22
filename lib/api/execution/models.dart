// Typed execution models for the unified execution layer.
// Replaces scattered raw ProcessResult/Process usage with structured,
// policy-aware request/result/event types.

/// Severity levels for execution audit logging.
enum AuditSeverity { info, warning, error }

/// A single event emitted during command execution (streamed).
abstract class ExecutionEvent {}

/// Command started executing.
class ExecutionStarted extends ExecutionEvent {
  final String command;
  final List<String> arguments;
  final DateTime timestamp;

  ExecutionStarted({
    required this.command,
    required this.arguments,
    required this.timestamp,
  });
}

/// Stdout data chunk received.
class StdOutChunk extends ExecutionEvent {
  final String data;

  StdOutChunk(this.data);
}

/// Stderr data chunk received.
class StdErrChunk extends ExecutionEvent {
  final String data;

  StdErrChunk(this.data);
}

/// Command exited (normally or via signal).
class ExecutionExited extends ExecutionEvent {
  final int exitCode;
  final Duration duration;
  final DateTime timestamp;

  ExecutionExited({
    required this.exitCode,
    required this.duration,
    required this.timestamp,
  });
}

/// Command failed to start or encountered an unexpected error.
class ExecutionError extends ExecutionEvent {
  final Object error;
  final StackTrace? stackTrace;

  ExecutionError(this.error, [this.stackTrace]);
}

/// A policy-controlled request to execute a command.
class ExecutionRequest {
  /// The executable/command name.
  final String command;

  /// Arguments passed to the command.
  final List<String> arguments;

  /// Working directory for execution (null = inherit).
  final String? workingDirectory;

  /// Environment variables override (merged with current env).
  final Map<String, String>? environment;

  /// Maximum allowed runtime before auto-kill.
  final Duration timeout;

  /// Whether to capture stdout/stderr (true) or let them passthrough (false).
  final bool captureOutput;

  /// Policy: list of allowed commands (empty = no restriction).
  final List<String>? allowedCommands;

  /// Policy: forbid commands that modify system state.
  final bool readOnly;

  /// Whether to run on the remote WSL host instead of locally.
  final bool useRemote;

  /// Whether to run inside a shell (cmd.exe /c or bash -c).
  final bool runInShell;

  const ExecutionRequest({
    required this.command,
    this.arguments = const [],
    this.workingDirectory,
    this.environment,
    this.timeout = const Duration(minutes: 5),
    this.captureOutput = true,
    this.allowedCommands,
    this.readOnly = false,
    this.useRemote = false,
    this.runInShell = false,
  });

  /// Returns a human-readable description for audit logs.
  String get description {
    if (arguments.isEmpty) return command;
    return '$command ${arguments.join(' ')}';
  }
}

/// The final result of an executed command.
class ExecutionResult {
  /// Exit code (0 = success, non-zero = failure).
  final int exitCode;

  /// Captured stdout content.
  final String stdout;

  /// Captured stderr content.
  final String stderr;

  /// Total wall-clock duration of the command.
  final Duration duration;

  /// Error thrown during execution (null on normal completion).
  final Object? error;

  /// Audit severity classification.
  final AuditSeverity auditSeverity;

  const ExecutionResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
    required this.duration,
    this.error,
    this.auditSeverity = AuditSeverity.info,
  });

  bool get isSuccess => exitCode == 0 && error == null;

  @override
  String toString() {
    return 'ExecutionResult(exitCode: $exitCode, duration: ${duration.inMilliseconds}ms)';
  }
}

/// An audit log entry recording an execution attempt.
class AuditEntry {
  final DateTime timestamp;
  final ExecutionRequest request;
  final int? exitCode;
  final Duration? duration;
  final AuditSeverity severity;
  final String? errorMessage;

  const AuditEntry({
    required this.timestamp,
    required this.request,
    this.exitCode,
    this.duration,
    this.severity = AuditSeverity.info,
    this.errorMessage,
  });

  @override
  String toString() {
    return '[$severity] ${request.description} => exitCode=$exitCode (${duration?.inMilliseconds ?? -1}ms)';
  }
}
