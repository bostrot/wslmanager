/// Tests for lib/api/cloud_init.dart — the saved cloud-init configurations,
/// what counts as a user-data document, and the file cloud-init's WSL
/// datasource reads (bostrot/ai-tasks#76).
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/cloud_init.dart';
import 'package:wsl2distromanager/components/helpers.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    CloudInitStore.instance.reload();
  });

  group('validateCloudInitUserData', () {
    test('accepts a cloud-config mapping and a shell script', () {
      expect(validateCloudInitUserData('#cloud-config\npackages:\n  - git\n'),
          isNull);
      expect(validateCloudInitUserData('#!/bin/sh\necho hi\n'), isNull);
      // Leading blank lines are what cloud-init strips too.
      expect(validateCloudInitUserData('\n\n#cloud-config\n'), isNull);
      // The starter the editor opens with has to pass its own check.
      expect(validateCloudInitUserData(kCloudInitStarter), isNull);
    });

    test('accepts the other headers cloud-init knows without parsing them',
        () {
      expect(validateCloudInitUserData('#include\nhttps://example.com/x'),
          isNull);
      expect(validateCloudInitUserData('#include-once\nhttps://x'), isNull);
      expect(validateCloudInitUserData('#cloud-boothook\necho hi'), isNull);
      // A cloud-config-archive is YAML but a list, not a mapping; it is
      // not held to the plain cloud-config rule.
      expect(validateCloudInitUserData('#cloud-config-archive\n- type: x'),
          isNull);
      expect(
          validateCloudInitUserData('## template: jinja\n#cloud-config\n'),
          isNull);
    });

    test('refuses a MIME multipart document', () {
      // The macOS seed nests the document inside a multipart of its own,
      // where cloud-init would not recognise a second one; refused up front
      // rather than dropped in the guest.
      expect(
          validateCloudInitUserData(
                  'Content-Type: multipart/mixed; boundary="x"\n')
              ?.key,
          'cloudinitheaderinvalid-text');
      expect(validateCloudInitUserData('MIME-Version: 1.0\n')?.key,
          'cloudinitheaderinvalid-text');
    });

    test('refuses an empty document', () {
      expect(validateCloudInitUserData('')?.key,
          'cloudinitcontentrequired-text');
      expect(validateCloudInitUserData('  \n\n')?.key,
          'cloudinitcontentrequired-text');
    });

    test('refuses a document cloud-init would not recognise', () {
      // Valid YAML, but without the header cloud-init logs it as
      // unhandled and does nothing — inside the guest, where nobody looks.
      expect(validateCloudInitUserData('packages:\n  - git\n')?.key,
          'cloudinitheaderinvalid-text');
    });

    test('refuses a cloud-config that is not valid YAML, naming the error',
        () {
      final problem =
          validateCloudInitUserData('#cloud-config\npackages: [git\n');
      expect(problem?.key, 'cloudinityamlinvalid-text');
      expect(problem?.detail, isNotEmpty);
    });

    test('refuses a cloud-config that is not a mapping', () {
      expect(validateCloudInitUserData('#cloud-config\n- git\n')?.key,
          'cloudinityamlnotamap-text');
    });
  });

  group('isValidCloudInitName', () {
    test('is a path segment and nothing else', () {
      expect(isValidCloudInitName('dev-tools_1.0'), isTrue);
      expect(isValidCloudInitName(''), isFalse);
      expect(isValidCloudInitName('has space'), isFalse);
      expect(isValidCloudInitName('../escape'), isFalse);
      expect(isValidCloudInitName('..'), isFalse);
      expect(isValidCloudInitName('.hidden'), isFalse);
      expect(isValidCloudInitName('a' * 65), isFalse);
    });
  });

  group('CloudInitStore', () {
    final store = CloudInitStore.instance;

    test('starts empty and persists what is saved', () async {
      expect(store.items, isEmpty);
      await store.save(const CloudInitConfig(
          name: 'dev', description: 'tools', content: '#cloud-config\n'));
      expect(store.items.map((e) => e.name), ['dev']);
      expect(store.byName('dev')?.description, 'tools');
      expect(store.byName('nope'), isNull);

      final stored =
          jsonDecode(prefs.getString(CloudInitStore.prefsKey)!) as List;
      expect(stored, hasLength(1));
      expect(stored.first['content'], '#cloud-config\n');
    });

    test('reads back what an earlier session stored', () async {
      await prefs.setString(
          CloudInitStore.prefsKey,
          jsonEncode([
            {'name': 'a', 'description': '', 'content': '#!/bin/sh\n'},
            {'name': 'b', 'content': '#cloud-config\n'},
          ]));
      store.reload();
      expect(store.items.map((e) => e.name), ['a', 'b']);
      // A missing description is an empty one, not a crash.
      expect(store.byName('b')?.description, '');
    });

    test('saving under an existing name replaces it in place', () async {
      await store.save(const CloudInitConfig(name: 'a', content: '1'));
      await store.save(const CloudInitConfig(name: 'b', content: '2'));
      await store.save(const CloudInitConfig(name: 'a', content: '3'));
      expect(store.items.map((e) => '${e.name}${e.content}'), ['a3\n', 'b2\n']);
    });

    test('an edit that renames keeps the slot and drops the old name',
        () async {
      await store.save(const CloudInitConfig(name: 'a', content: '1'));
      await store.save(const CloudInitConfig(name: 'b', content: '2'));
      await store.save(const CloudInitConfig(name: 'renamed', content: '1'),
          previousName: 'a');
      expect(store.items.map((e) => e.name), ['renamed', 'b']);
    });

    test('a rename onto a taken name never leaves two entries', () async {
      await store.save(const CloudInitConfig(name: 'a', content: '1'));
      await store.save(const CloudInitConfig(name: 'b', content: '2'));
      // The editor refuses this; the store must not depend on it.
      await store.save(const CloudInitConfig(name: 'b', content: '9'),
          previousName: 'a');
      expect(store.items.map((e) => '${e.name}${e.content}'), ['b9\n']);
    });

    test('stores every document with LF endings and a final newline',
        () async {
      await store.save(const CloudInitConfig(
          name: 'crlf', content: '#cloud-config\r\npackages:\r\n  - git'));
      expect(store.byName('crlf')?.content, '#cloud-config\npackages:\n  - git\n');
    });

    test('a bad element does not cost the entries after it', () async {
      await prefs.setString(
          CloudInitStore.prefsKey,
          jsonEncode([
            {'name': 'a', 'content': '1'},
            {'content': 'no name'},
            {'name': 'c', 'content': '3'},
          ]));
      store.reload();
      // The bad element alone is dropped, never the ones after it — the
      // next save writes the list back whole.
      expect(store.items.map((e) => e.name), ['a', 'c']);
      await store.save(const CloudInitConfig(name: 'd', content: '4'));
      expect(store.items.map((e) => e.name), ['a', 'c', 'd']);
    });

    test('items is a live view, not a copy', () async {
      final view = store.items;
      await store.save(const CloudInitConfig(name: 'a', content: '1'));
      expect(view.map((e) => e.name), ['a']);
      expect(() => view.add(view.first), throwsUnsupportedError);
    });

    test('remove reports whether anything went', () async {
      await store.save(const CloudInitConfig(name: 'a', content: '1'));
      expect(await store.remove('a'), isTrue);
      expect(await store.remove('a'), isFalse);
      expect(store.items, isEmpty);
      expect(prefs.getString(CloudInitStore.prefsKey), '[]');
    });

    test('a corrupt preference reads as an empty list', () async {
      await prefs.setString(CloudInitStore.prefsKey, '{not json');
      store.reload();
      expect(store.items, isEmpty);
    });

    test('notifies listeners on every change', () async {
      var calls = 0;
      void listener() => calls++;
      store.addListener(listener);
      addTearDown(() => store.removeListener(listener));
      await store.save(const CloudInitConfig(name: 'a', content: '1'));
      await store.remove('a');
      expect(calls, 2);
    });
  });

  group('CloudInitFiles', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('cloud-init-files-');
      CloudInitFiles.userDataDirOverride = '${dir.path}/.cloud-init';
    });

    tearDown(() {
      CloudInitFiles.userDataDirOverride = null;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('writes <distro>.user-data under the .cloud-init directory',
        () async {
      expect(CloudInitFiles.exists('Ubuntu-dev'), isFalse);
      final path =
          await CloudInitFiles.write('Ubuntu-dev', '#cloud-config\nx: 1\n');
      expect(path, CloudInitFiles.userDataPath('Ubuntu-dev'));
      expect(path, endsWith('.cloud-init${Platform.pathSeparator}'
          'Ubuntu-dev.user-data'));
      expect(CloudInitFiles.exists('Ubuntu-dev'), isTrue);
      expect(File(path).readAsStringSync(), '#cloud-config\nx: 1\n');
    });

    test('normalises line endings and ends the file with a newline',
        () async {
      // The file is read from inside the guest: CRLF from a Windows editor
      // would put a \r on the end of every YAML value.
      final path = await CloudInitFiles.write(
          'd', '#cloud-config\r\npackages:\r\n  - git');
      final bytes = File(path).readAsBytesSync();
      expect(bytes, isNot(contains(13)));
      expect(utf8.decode(bytes), '#cloud-config\npackages:\n  - git\n');
      // No BOM: it would be the first byte of the header.
      expect(bytes.take(3).toList(), isNot([0xEF, 0xBB, 0xBF]));
    });

    test('remove takes the file away and tolerates its absence', () async {
      await CloudInitFiles.write('d', '#cloud-config\n');
      await CloudInitFiles.remove('d');
      expect(CloudInitFiles.exists('d'), isFalse);
      await CloudInitFiles.remove('d');
    });
  });

  test('the first-boot wait leaves a distro without cloud-init alone', () {
    // One line, no bash-only syntax: it goes through `bash -c` as a single
    // argument. The guards are what keep Alpine or Debian from failing on a
    // command they do not have, and what keeps `status --wait` from
    // spinning on a distro whose cloud-init nothing will ever start.
    expect(cloudInitWaitScript, contains('command -v cloud-init'));
    expect(cloudInitWaitScript, contains('[ -d /run/systemd/system ]'));
    expect(cloudInitWaitScript, contains('cloud-init status --wait'));
    expect(cloudInitWaitScript, isNot(contains('\n')));
  });

  test('the wait answer is read off the last line', () {
    expect(parseCloudInitWait(0, 'done\n'), CloudInitWaitOutcome.done);
    expect(parseCloudInitWait(0, 'noise\nskipped'),
        CloudInitWaitOutcome.skipped);
    // Nothing printed means the script never ran to its end — a distro that
    // failed to start, or the broker's timeout.
    expect(parseCloudInitWait(0, ''), CloudInitWaitOutcome.failed);
    expect(parseCloudInitWait(1, 'done'), CloudInitWaitOutcome.failed);
  });
}
