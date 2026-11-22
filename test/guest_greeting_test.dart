import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/apple/guest_greeting.dart';

/// The greeting is shell that runs inside somebody else's machine, on every
/// login, before they get a prompt. These pin the properties that keep a
/// cosmetic banner from being able to break the shell it decorates.
void main() {
  group('snippet', () {
    test('prefers fastfetch and degrades twice', () {
      final snippet = GuestGreeting.snippet;
      final fastfetch = snippet.indexOf('command -v fastfetch');
      final neofetch = snippet.indexOf('command -v neofetch');
      final uname = snippet.indexOf('uname -srm');
      expect(fastfetch, isNonNegative);
      expect(neofetch, greaterThan(fastfetch));
      expect(uname, greaterThan(neofetch),
          reason: 'a guest with neither tool still says where it is');
    });

    test('only interactive shells print anything', () {
      expect(GuestGreeting.snippet, contains(r'case $-'));
      expect(GuestGreeting.snippet, contains('*i*)'));
    });

    test('a second shell in the same session stays quiet', () {
      expect(GuestGreeting.snippet, contains('WSLMANAGER_GREETING_SHOWN'));
      expect(GuestGreeting.snippet,
          contains(r'if [ -z "${WSLMANAGER_GREETING_SHOWN:-}" ]'));
    });

    test('never returns or exits', () {
      // /etc/profile is sourced by non-interactive login shells too (`sh -lc`
      // is a login shell), and an `exit` here would kill whatever was being
      // run rather than skip a banner.
      final words = GuestGreeting.snippet
          .split(RegExp(r'[^A-Za-z_-]+'))
          .where((w) => w == 'exit' || w == 'return');
      expect(words, isEmpty, reason: 'found: $words');
    });
  });

  group('installCommand', () {
    final command = GuestGreeting.installCommand();

    test('carries the snippet verbatim, base64-encoded', () {
      final payloads = RegExp(r"printf %s '([A-Za-z0-9+/=]+)'")
          .allMatches(command)
          .map((m) => utf8.decode(base64.decode(m.group(1)!)))
          .toList();
      expect(payloads, contains(GuestGreeting.snippet));
      expect(payloads, contains(GuestGreeting.fastfetchInstallScript));
    });

    test('writes the snippet where a login shell will read it', () {
      expect(GuestGreeting.path, startsWith('/etc/profile.d/'));
      expect(command, contains('tee ${GuestGreeting.path}'));
      expect(command, contains('chmod 0644 ${GuestGreeting.path}'));
    });

    test('escalates without ever waiting for a password', () {
      expect(command, contains(r'if [ "$(id -u)" = 0 ]'));
      expect(command, contains('sudo -n'));
      expect(command, contains('doas -n'));
      // No sudo and no doas: give up rather than hang on a prompt nobody is
      // there to answer.
      expect(command, contains('exit 1'));
      expect(command, isNot(contains('sudo -S')));
    });

    test('teaches /etc/profile to read profile.d only when it does not', () {
      expect(command, contains(r"! grep -q 'profile\.d' /etc/profile"));
    });

    test('fetches fastfetch only when missing, and never in the foreground',
        () {
      expect(command, contains('if ! command -v fastfetch'));
      final install =
          command.substring(command.indexOf('if ! command -v fastfetch'));
      expect(install, contains('nohup'));
      expect(install, contains(RegExp(r'>/dev/null 2>&1 &\n')),
          reason: 'a package fetch must not hold up the terminal');
    });

    test('a write that fails is reported rather than shrugged off', () {
      expect(
          command, contains('tee ${GuestGreeting.path} >/dev/null || exit 1'));
      // Backgrounding the package fetch succeeds whatever came of it, so the
      // command has to end on something that reflects the file itself —
      // otherwise a guest that refused the write is remembered as done.
      expect(command.trimRight(), endsWith('test -s ${GuestGreeting.path}'));
    });

    test('the package fetch uses the guest own package managers', () {
      for (final manager in ['apk', 'apt-get', 'dnf', 'pacman', 'zypper']) {
        expect(GuestGreeting.fastfetchInstallScript,
            contains('command -v $manager'));
      }
      expect(GuestGreeting.fastfetchInstallScript, isNot(contains('curl')),
          reason: 'nothing is pulled from outside the guest configured repos');
    });
  });

  test('preference keys are namespaced per instance', () {
    expect(GuestGreeting.prefKey('ubuntu'), 'GuestGreeting_ubuntu');
    expect(GuestGreeting.enabledPrefKey, 'VmGreeting');
    expect(GuestGreeting.version, greaterThan(0));
  });
}
