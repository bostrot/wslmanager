/// Guards the macOS entitlements the app cannot do without.
///
/// file_picker checks for a user-selected file entitlement before it opens
/// any panel, whether or not the app is sandboxed. Without one every folder
/// and file picker on macOS fails with ENTITLEMENT_NOT_FOUND, which is how the
/// mount dialog's folder button broke. Both profiles must carry it, since
/// `flutter run` signs with the debug one and the release scripts with the
/// other.
// ignore_for_file: dangling_library_doc_comments

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _profiles = <String>[
  'macos/Runner/DebugProfile.entitlements',
  'macos/Runner/Release.entitlements',
];

/// The boolean an entitlements plist assigns to [key], or null when the key
/// is absent.
bool? entitlementValue(String plist, String key) {
  final match = RegExp('<key>${RegExp.escape(key)}</key>\\s*<(true|false)/>')
      .firstMatch(plist);
  if (match == null) return null;
  return match.group(1) == 'true';
}

void main() {
  group('entitlementValue', () {
    test('reads a granted key', () {
      expect(
        entitlementValue('<key>a.b</key>\n\t<true/>', 'a.b'),
        isTrue,
      );
    });

    test('reads a denied key', () {
      expect(entitlementValue('<key>a.b</key><false/>', 'a.b'), isFalse);
    });

    test('does not confuse a key with a longer one sharing its prefix', () {
      const plist = '<key>a.b.read-only</key><true/>';
      expect(entitlementValue(plist, 'a.b'), isNull);
    });
  });

  for (final profile in _profiles) {
    test('$profile lets the user pick files and folders', () {
      final plist = File(profile).readAsStringSync();
      // The save panel in the package screen needs read-write; read-only
      // would only cover the open panels.
      expect(
        entitlementValue(
          plist,
          'com.apple.security.files.user-selected.read-write',
        ),
        isTrue,
        reason: 'file_picker refuses every panel without this entitlement',
      );
    });
  }
}
