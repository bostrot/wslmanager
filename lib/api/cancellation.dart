/// A one-way "stop what you are doing" signal.
///
/// Every long operation in this app used to be uncancellable: the create
/// screen disabled its own Cancel button for the whole install and the AI
/// Workspace card disabled every control it had, so a multi-GB download or a
/// wedged `curl | bash` could only be escaped by killing the app (audit
/// CI-14, PS-18).
///
/// Deliberately not `CancelableOperation` from `package:async`: what has to be
/// cancelled here is not a `Future` but a *child process* and a socket, and
/// both are reached through a callback the worker registers with [onCancel]
/// while it owns them. A token is also the only shape that survives being
/// handed down four call levels — screen to [createInstance] to `WSLApi.create`
/// to the downloader — without every one of them returning a different type.
class CancelSignal {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  /// True once [cancel] has been called. Workers poll this between steps.
  bool get isCancelled => _cancelled;

  /// Request cancellation and run every registered listener exactly once.
  ///
  /// Idempotent: the UI can fire it from a button that is still on screen
  /// while the worker is already unwinding.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    // Copied and cleared first: a listener that registers another one while
    // unwinding must not mutate the list being walked, and nothing may run
    // twice.
    final listeners = List<void Function()>.from(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      try {
        listener();
      } catch (_) {
        // A cleanup that fails must not stop the rest of them from running.
      }
    }
  }

  /// Run [listener] when [cancel] is called, or immediately if it already was.
  ///
  /// The immediate case is not a nicety: a worker registers *after* it has the
  /// handle it wants to kill, which leaves a window in which the user has
  /// already pressed Cancel.
  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  /// Drop [listener] once the step it belonged to is over, so a token reused
  /// across steps cannot kill a process that has already been replaced.
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// Throw [CancelledException] if cancellation has been requested.
  void throwIfCancelled() {
    if (_cancelled) throw const CancelledException();
  }
}

/// Thrown by work that stopped because its [CancelSignal] was cancelled.
///
/// Distinct from every other failure on purpose: a cancel is the user getting
/// what they asked for, so the UI reports it as such instead of raising it as
/// an error the way it does a failed download.
class CancelledException implements Exception {
  const CancelledException();

  @override
  String toString() => 'CancelledException';
}
