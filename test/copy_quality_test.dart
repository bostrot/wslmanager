/// Source-level guards for the Phase 08 copy rules.
///
/// The audit's recurring failure was a raw exception surfacing as UI text —
/// a dialog body that was literally the word `Exception:` (IA-16). Every
/// message was rewritten; this pins the rule so a new key cannot quietly
/// reintroduce the shape.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/components/helpers.dart';

void main() {
  test('no user-facing string carries an exception-shaped fragment', () {
    final en = json.decode(File('lib/i18n/en.json').readAsStringSync())
        as Map<String, dynamic>;
    final offenders = <String>[];
    for (final entry in en.entries) {
      final value = entry.value as String;
      if (value.contains('Exception:') ||
          value.contains('#0 ') ||
          value.contains('TimeoutException') ||
          value.contains('StackTrace')) {
        offenders.add(entry.key);
      }
    }
    expect(offenders, isEmpty,
        reason: 'an exception is a detail for the "Technical details" '
            'disclosure, never the message itself');
  });

  test('formatBytes picks the unit that keeps digits', () {
    // The per-site formatters it replaced were pinned to GB with two
    // decimals: a 40 MB template printed "0.04 GB" and anything under ~5 MB
    // rounded to "0 GB" (ST-37, ST-42).
    expect(formatBytes(0), '0 B');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(40 * 1024 * 1024), '40 MB');
    expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
    expect(formatBytes(2 * 1024 * 1024 * 1024), '2.0 GB');
  });

  test('one sanitiser for instance names, and it keeps _ and -', () {
    // Create and Copy used to disagree on the legal characters (CI-05).
    expect(sanitizeDistroName('my distro!'), 'my_distro_');
    expect(sanitizeDistroName('a_b-c'), 'a_b-c');
    expect(sanitizeDistroName('日本語'), '___');
  });
}
