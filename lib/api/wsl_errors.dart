// Turning what `wsl.exe` wrote into something a user can act on.
//
// Two things make WSL failures hard to report honestly, and both are handled
// here rather than at every call site:
//
// * The reason is not always on stderr. `wsl --mount` writes its failure to
//   *stdout* and leaves stderr empty, so `Exception(result.stderr)` throws an
//   exception with no message and the dialog built from it reads, in full,
//   `Exception:` (audit IA-16). `WslFailure.fromStreams` reads both.
// * The prose is localised, the code is not. A German-locale host answers
//   `Das System kann den angegebenen Pfad nicht finden. Fehlercode:
//   Wsl/ERROR_PATH_NOT_FOUND`. Matching the sentence can never work; the
//   `Wsl/…` code suffix is stable across locales and is what `wslErrorCode`
//   pulls out (audit IA-19).
//
// The result is a translated sentence for the user plus the untouched original
// in `WslFailure.details`, which the UI shows in a secondary position and the
// AI diagnosis passes through verbatim.

import 'package:localization/localization.dart';

import 'process_output.dart';

/// The `Wsl/…` code WSL stamps on its own failures.
///
/// Matched anywhere in the text because the surrounding label ("Error code:",
/// "Fehlercode:", …) is translated and the code is not.
final RegExp _codePattern = RegExp(r'Wsl/[A-Za-z0-9_/]*[A-Za-z0-9_]');

/// Known code fragments, most specific first, mapped to the sentence to show.
///
/// Matching is by substring on the code rather than by equality: WSL nests the
/// failing stage into the code (`Wsl/Service/CreateInstance/CreateVm/E_FAIL`),
/// and the stage list is not stable across releases while the tail is. Order
/// is load-bearing — a map literal iterates in insertion order, and the
/// catch-all `CreateInstance` has to lose to every specific code above it.
const Map<String, String> codeMessageKeys = <String, String>{
  'WSL_E_DEFAULT_DISTRO_NOT_FOUND': 'wslerror-distronotfound-text',
  'WSL_E_DISTRO_NOT_FOUND': 'wslerror-distronotfound-text',
  'WSL_E_DISTRIBUTION_NAME_NEEDED': 'wslerror-distronotfound-text',
  'WSL_E_VM_MODE_NOT_SUPPORTED': 'wslerror-vmplatform-text',
  'WSL_E_WSL2_NOT_SUPPORTED': 'wslerror-vmplatform-text',
  'HCS_E_HYPERV_NOT_INSTALLED': 'wslerror-vmplatform-text',
  'WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED': 'wslerror-wslmissing-text',
  'WSL_E_INSTALL_PROCESS_FAILED': 'wslerror-wslmissing-text',
  'ERROR_ALREADY_EXISTS': 'wslerror-alreadyexists-text',
  'ERROR_DISK_FULL': 'wslerror-diskfull-text',
  'ERROR_SHARING_VIOLATION': 'wslerror-inuse-text',
  'ERROR_LOCK_VIOLATION': 'wslerror-inuse-text',
  'ERROR_PATH_NOT_FOUND': 'wslerror-pathnotfound-text',
  'ERROR_FILE_NOT_FOUND': 'wslerror-pathnotfound-text',
  'ERROR_ACCESS_DENIED': 'wslerror-accessdenied-text',
  'E_ACCESSDENIED': 'wslerror-accessdenied-text',
  'ERROR_INVALID_PARAMETER': 'wslerror-invalidparameter-text',
  'ERROR_INVALID_NAME': 'wslerror-invalidparameter-text',
  'CreateInstance': 'wslerror-createinstance-text',
};

/// The `Wsl/…` error code in [text], or null when there is none.
String? wslErrorCode(String text) => _codePattern.firstMatch(text)?.group(0);

/// A failed WSL (or WSL-adjacent) operation, in a form the UI can render.
///
/// Thrown instead of `Exception(result.stderr)` so that no code path can put a
/// bare `Exception.toString()` in front of a user.
class WslFailure implements Exception {
  const WslFailure({this.code, this.details = ''});

  /// The stable `Wsl/…` code, when WSL supplied one.
  final String? code;

  /// Everything the tool wrote, trimmed. Shown only in a secondary position
  /// ("Technical details"), never as the message.
  final String details;

  /// Build from a process result's two streams.
  ///
  /// Both are read, stdout first when stderr is empty, because `wsl --mount`
  /// reports on stdout and `wsl --import` on stderr.
  factory WslFailure.fromStreams(dynamic stdout, dynamic stderr) {
    final err = _clean(_asText(stderr));
    final out = _clean(_asText(stdout));
    // stderr wins as the text to keep: `wsl --import` paints a progress
    // animation on stdout, and showing that instead of the reason was its own
    // bug. But `--mount` writes the whole failure — code included — to stdout
    // and leaves stderr empty, so stdout is read when stderr is silent, and
    // its code is taken whenever stderr carries none.
    final details = err.isNotEmpty ? err : out;
    return WslFailure(
      code: wslErrorCode(details) ?? wslErrorCode(out),
      details: details,
    );
  }

  /// Build from an already-flattened blob of tool output.
  factory WslFailure.fromText(String raw) {
    final text = _clean(raw);
    return WslFailure(code: wslErrorCode(text), details: text);
  }

  /// Build from anything that was caught.
  ///
  /// A [WslFailure] is returned unchanged; anything else is stripped of its
  /// `Exception: ` prefix and scanned for a code, so a raw `throw
  /// Exception(stderr)` further down still surfaces as a sentence.
  factory WslFailure.from(Object? error) {
    if (error is WslFailure) return error;
    return WslFailure.fromText(error?.toString() ?? '');
  }

  /// The translated sentence to show the user.
  ///
  /// Never empty and never a class name: an unrecognised code (or none at all)
  /// falls back to the generic sentence, and the original text stays in
  /// [details] where it belongs.
  String get message {
    final matched = explanation;
    return matched.isEmpty ? 'wslerror-generic-text'.i18n() : matched;
  }

  /// The mapped sentence, or `''` when nothing matched.
  ///
  /// Distinct from [message] because a caller that already has a lead sentence
  /// ("Could not start Ubuntu.") wants to add nothing rather than add
  /// "The operation could not be completed."
  String get explanation {
    final matched = messageKey;
    return matched == null ? '' : matched.i18n();
  }

  /// One line of [details], for a surface with no room for a disclosure.
  ///
  /// A toast cannot expand, and dropping the tool's answer entirely would make
  /// a failure unsupportable — so the first non-empty line survives, without
  /// the `Exception: ` prefix [WslFailure] already stripped and clipped so it
  /// cannot push the InfoBar off the screen.
  String get detailLine {
    for (final line in details.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      return trimmed.length <= 160 ? trimmed : '${trimmed.substring(0, 157)}...';
    }
    return '';
  }

  /// What to append to a caller's own lead sentence: the mapped explanation
  /// when there is one, otherwise the tool's own first line.
  String get shortReason =>
      explanation.isNotEmpty ? explanation : detailLine;

  /// The i18n key [message] resolves to, or null when nothing matched.
  ///
  /// Separate from [message] so a test can assert the mapping without a
  /// loaded locale.
  String? get messageKey {
    final c = code;
    if (c == null) return null;
    for (final entry in codeMessageKeys.entries) {
      if (c.contains(entry.key)) return entry.value;
    }
    return null;
  }

  /// True when [details] adds something the message does not already say.
  bool get hasDetails => details.isNotEmpty;

  /// True when the failure is Windows still holding the disk.
  ///
  /// The hint this gates used to be attached by matching the English phrases
  /// "process cannot access" / "being used by another process", which cannot
  /// fire on a localized Windows (audit IA-19).
  bool get isResourceInUse => messageKey == 'wslerror-inuse-text';

  @override
  String toString() => message;
}

/// One-line convenience for a caught object: the sentence to show.
String friendlyErrorText(Object? error) => WslFailure.from(error).message;

/// What to append to a caller's own lead sentence. See [WslFailure.shortReason].
String friendlyErrorReason(Object? error) =>
    WslFailure.from(error).shortReason;

String _asText(dynamic stream) {
  if (stream == null) return '';
  if (stream is List<int>) {
    // Bytes only reach here from a caller that did not decode.
    return decodeProcessOutput(stream).replaceAll('\u0000', '').trim();
  }
  return stream.toString().trim();
}

/// Strip the `Exception: ` wrapper Dart prints, and collapse blank lines.
String _clean(String raw) {
  var text = raw.trim();
  while (text.startsWith('Exception: ')) {
    text = text.substring('Exception: '.length).trim();
  }
  if (text == 'Exception') return '';
  return text
      .split('\n')
      .map((line) => line.trimRight())
      .where((line) => line.trim().isNotEmpty)
      .join('\n');
}
