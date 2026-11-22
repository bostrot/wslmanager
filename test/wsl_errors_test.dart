import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';

/// The failure text `wsl.exe` produced on the audit machine, verbatim.
///
/// German, because the host is — which is the whole point of matching on the
/// code and not on the sentence (audit IA-19).
const _germanPathNotFound = 'Das System kann den angegebenen Pfad nicht '
    'finden. \nFehlercode: Wsl/ERROR_PATH_NOT_FOUND';

void main() {
  group('wslErrorCode', () {
    test('finds the code inside localized prose', () {
      expect(wslErrorCode(_germanPathNotFound), 'Wsl/ERROR_PATH_NOT_FOUND');
    });

    test('finds a nested service code', () {
      expect(
        wslErrorCode('Error code: Wsl/Service/CreateInstance/CreateVm/E_FAIL'),
        'Wsl/Service/CreateInstance/CreateVm/E_FAIL',
      );
    });

    test('returns null when there is no code', () {
      expect(wslErrorCode('SocketException: connection refused'), isNull);
    });
  });

  group('WslFailure.fromStreams', () {
    test('reads stdout when stderr is empty', () {
      // The IA-16 mechanism: `wsl --mount` reports on stdout, so throwing
      // Exception(stderr) produced a dialog whose whole body was "Exception:".
      final failure = WslFailure.fromStreams(_germanPathNotFound, '');
      expect(failure.code, 'Wsl/ERROR_PATH_NOT_FOUND');
      expect(failure.messageKey, 'wslerror-pathnotfound-text');
      expect(failure.details, contains('Fehlercode'));
      expect(failure.hasDetails, isTrue);
    });

    test('stderr wins the text, so import progress noise stays out', () {
      // `wsl --import` paints a progress animation on stdout; showing that
      // instead of the reason is guarded by wsl_test.dart as well.
      final failure = WslFailure.fromStreams('cOv...NO', 'Invalid path');
      expect(failure.details, 'Invalid path');
    });

    test('takes the code from stdout when stderr carries none', () {
      final failure =
          WslFailure.fromStreams(_germanPathNotFound, 'something went wrong');
      expect(failure.details, 'something went wrong');
      expect(failure.messageKey, 'wslerror-pathnotfound-text');
    });

    test('a failure with nothing on either stream has no details', () {
      final failure = WslFailure.fromStreams('', '');
      expect(failure.details, isEmpty);
      expect(failure.hasDetails, isFalse);
      expect(failure.code, isNull);
    });
  });

  group('WslFailure.from', () {
    test('strips the Exception wrapper', () {
      final failure = WslFailure.from(Exception(_germanPathNotFound));
      expect(failure.details.startsWith('Exception:'), isFalse);
      expect(failure.messageKey, 'wslerror-pathnotfound-text');
    });

    test('an exception with no message leaves nothing behind', () {
      // `Exception().toString()` is the bare class name; putting that in a
      // dialog is exactly the blocker being fixed.
      final failure = WslFailure.from(Exception());
      expect(failure.details, isEmpty);
      expect(failure.explanation, isEmpty);
      expect(failure.shortReason, isEmpty);
    });

    test('passes a WslFailure through unchanged', () {
      const original = WslFailure(code: 'Wsl/ERROR_DISK_FULL', details: 'x');
      expect(identical(WslFailure.from(original), original), isTrue);
    });
  });

  group('code mapping', () {
    test('maps the codes the audit met', () {
      expect(
        WslFailure.fromText('Wsl/Service/WSL_E_DISTRO_NOT_FOUND').messageKey,
        'wslerror-distronotfound-text',
      );
      expect(
        WslFailure.fromText('Wsl/ERROR_SHARING_VIOLATION').messageKey,
        'wslerror-inuse-text',
      );
      expect(
        WslFailure.fromText('Wsl/Service/RegisterDistro/ERROR_ALREADY_EXISTS')
            .messageKey,
        'wslerror-alreadyexists-text',
      );
    });

    test('a specific code beats the CreateInstance catch-all', () {
      // Order in the map is load-bearing: this code contains both.
      expect(
        WslFailure.fromText('Wsl/Service/CreateInstance/ERROR_DISK_FULL')
            .messageKey,
        'wslerror-diskfull-text',
      );
      expect(
        WslFailure.fromText('Wsl/Service/CreateInstance/CreateVm/E_FAIL')
            .messageKey,
        'wslerror-createinstance-text',
      );
    });

    test('an unknown code maps to nothing rather than to a guess', () {
      final failure = WslFailure.fromText('Wsl/Service/SOMETHING_NEW');
      expect(failure.code, 'Wsl/Service/SOMETHING_NEW');
      expect(failure.messageKey, isNull);
    });

    test('the disk-in-use flag is driven by the code, not by English text', () {
      expect(
        WslFailure.fromText(
                'Der Prozess kann nicht zugreifen. '
                'Fehlercode: Wsl/ERROR_SHARING_VIOLATION')
            .isResourceInUse,
        isTrue,
      );
      // The English phrase alone, with no code, must not trigger it — that is
      // the old behaviour, and it could never fire on a localized host.
      expect(
        WslFailure.fromText('The process cannot access the file')
            .isResourceInUse,
        isFalse,
      );
    });
  });

  group('detailLine', () {
    test('takes the first non-empty line', () {
      expect(WslFailure.fromText('\n\nfirst\nsecond').detailLine, 'first');
    });

    test('clips a line that would overflow the status bar', () {
      final long = 'x' * 400;
      final line = WslFailure.fromText(long).detailLine;
      expect(line.length, 160);
      expect(line.endsWith('...'), isTrue);
    });

    test('shortReason prefers the mapped sentence key over raw output', () {
      final mapped = WslFailure.fromText(_germanPathNotFound);
      // Without a loaded locale `.i18n()` answers with the key itself, which
      // is enough to prove which of the two branches was taken.
      expect(mapped.shortReason, isNot(contains('Fehlercode')));
      expect(WslFailure.fromText('plain trouble').shortReason, 'plain trouble');
    });
  });

  group('the sentences exist', () {
    test('every mapped key is in every locale', () {
      final locales = Directory('lib/i18n')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'));
      expect(locales, isNotEmpty);

      for (final file in locales) {
        final strings = json.decode(file.readAsStringSync()) as Map;
        for (final key in {...codeMessageKeys.values, 'wslerror-generic-text'}) {
          expect(strings[key], isA<String>(),
              reason: '${file.path} is missing "$key"');
          expect((strings[key] as String).trim(), isNotEmpty,
              reason: '${file.path}: "$key" is blank');
        }
      }
    });
  });
}
