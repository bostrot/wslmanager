/// Publishing a snippet as a pull request on the community scripts repo.
///
/// The files this produces have to satisfy the repo's own structure check
/// (name equal to the folder, semver version, required keys), so the format
/// assertions below mirror that CI job.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/github_publish.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:yaml/yaml.dart';

/// Answers the GitHub endpoints the publisher walks through.
class _GithubAdapter implements HttpClientAdapter {
  _GithubAdapter({this.forkExists = true});

  final bool forkExists;
  /// GitHub creates forks asynchronously; this flips once /forks is posted.
  bool _forkCreated = false;
  final List<String> calls = [];
  final Map<String, String> written = {};
  int pendingPolls = 0;
  Map<String, dynamic>? prBody;

  /// What the app sent to /login/device/code, if anything.
  Map<String, dynamic>? deviceCodeBody;

  /// "Enable Device Flow" is a checkbox on the OAuth app's settings page;
  /// left unticked, GitHub refuses every device-code request.
  bool deviceFlowEnabled = true;

  /// When set, served verbatim for /login/device/code instead of JSON.
  ResponseBody? deviceCodeRaw;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.uri.toString();
    calls.add('${options.method} $path');

    ResponseBody json(Object body, [int code = 200]) =>
        ResponseBody.fromString(jsonEncode(body), code, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });

    if (path.contains('login/device/code')) {
      deviceCodeBody = Map<String, dynamic>.from(options.data as Map);
      if (deviceCodeRaw != null) return deviceCodeRaw!;
      if (!deviceFlowEnabled) {
        // Verified against GitHub on 2026-09-04: a 400 with this body.
        return json({
          'error': 'device_flow_disabled',
          'error_description':
              'Device Flow must be explicitly enabled for this App',
        }, 400);
      }
      return json({
        'device_code': 'DEV-CODE',
        'user_code': 'ABCD-1234',
        'verification_uri': 'https://github.com/login/device',
        'interval': 0,
        'expires_in': 900,
      });
    }
    if (path.contains('login/oauth/access_token')) {
      if (pendingPolls > 0) {
        pendingPolls--;
        return json({'error': 'authorization_pending'}, 400);
      }
      return json({'access_token': 'gho_test'});
    }
    if (path.endsWith('/user')) {
      return json({'login': 'erict'});
    }
    if (path.contains('/repos/erict/wsl-scripts') &&
        options.method == 'GET' &&
        !path.contains('/contents/')) {
      return (forkExists || _forkCreated)
          ? json({'name': 'wsl-scripts'})
          : json({}, 404);
    }
    if (path.contains('/forks')) {
      _forkCreated = true;
      return json({'name': 'wsl-scripts'});
    }
    if (path.contains('/git/ref/heads/')) {
      return json({
        'object': {'sha': 'base-sha'}
      });
    }
    if (path.contains('/git/refs')) return json({'ref': 'created'});
    if (path.contains('/contents/')) {
      final data = options.data as Map;
      final file = path.split('/contents/').last;
      written[file] = utf8.decode(base64.decode(data['content'].toString()));
      return json({'content': {}});
    }
    if (path.endsWith('/pulls')) {
      prBody = Map<String, dynamic>.from(options.data as Map);
      return json({'html_url': 'https://github.com/bostrot/wsl-scripts/pull/42'});
    }
    return json({}, 404);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  QuickActionItem item({dynamic distro = 'Debian'}) => QuickActionItem(
        name: 'my-script',
        description: 'Does a thing',
        version: '1.2.0',
        author: 'erict',
        license: 'MIT',
        git: 'https://github.com/bostrot/wsl-scripts',
        distro: distro,
        content: 'echo hi\n',
      );

  GithubPublisher build(_GithubAdapter adapter) => GithubPublisher(
      dio: Dio()..httpClientAdapter = adapter, clientId: 'test-client');

  group('generated files', () {
    test('match the repo format the structure check enforces', () {
      final files = GithubPublisher.filesFor(item());
      expect(files.keys,
          containsAll(['scripts/my-script/info.yml', 'scripts/my-script/script.noshell']));

      final info = loadYaml(files['scripts/my-script/info.yml']!) as Map;
      // Every key the repo requires, and the name must equal the folder.
      for (final key in ['name', 'description', 'version', 'author', 'license',
        'git', 'distro']) {
        expect(info[key], isNotNull, reason: '$key missing');
      }
      expect(info['name'], 'my-script');
      expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(info['version'].toString()),
          isTrue);
      expect(files['scripts/my-script/script.noshell'], 'echo hi\n');
    });

    test('several distros become a YAML list', () {
      final files =
          GithubPublisher.filesFor(item(distro: ['Debian', 'Alpine']));
      final info = loadYaml(files['scripts/my-script/info.yml']!) as Map;
      expect(info['distro'], isA<List>());
      expect(List.from(info['distro']), ['Debian', 'Alpine']);
    });

    test('empty optional fields fall back rather than emitting blanks', () {
      final bare = QuickActionItem(
          name: 'bare', description: 'x', content: 'echo', distro: 'Debian');
      final info =
          loadYaml(GithubPublisher.filesFor(bare)['scripts/bare/info.yml']!)
              as Map;
      expect(info['version'], '1.0.0');
      expect(info['license'], 'MIT');
      expect(info['git'].toString(), contains('wsl-scripts'));
    });
  });

  group('device flow', () {
    test('polls until the user finishes, then keeps the token', () async {
      final adapter = _GithubAdapter()..pendingPolls = 2;
      final publisher = build(adapter);

      final prompt = await publisher.requestDeviceCode();
      expect(prompt.userCode, 'ABCD-1234');

      final ok = await publisher.pollForToken(prompt,
          pollInterval: Duration.zero);
      expect(ok, isTrue);
      expect(GithubPublisher.storedToken, 'gho_test');
    });

    test('a cancelled sign-in stops polling and stores nothing', () async {
      final publisher = build(_GithubAdapter()..pendingPolls = 100);
      final prompt = await publisher.requestDeviceCode();

      final ok = await publisher.pollForToken(prompt,
          pollInterval: Duration.zero, cancelled: () => true);
      expect(ok, isFalse);
      expect(GithubPublisher.storedToken, isNull);
    });
  });

  group('publish', () {
    test('forks, branches, writes both files and opens the PR', () async {
      await prefs.setString('GithubToken', 'gho_test');
      final adapter = _GithubAdapter();
      final result = await build(adapter).publish(item());

      expect(result.pullRequestUrl, endsWith('/pull/42'));
      expect(adapter.written.keys,
          containsAll(['scripts/my-script/info.yml',
            'scripts/my-script/script.noshell']));
      // The PR targets upstream's default branch from the user's fork.
      expect(adapter.prBody!['base'], kScriptsBranch);
      expect(adapter.prBody!['head'].toString(), startsWith('erict:'));
      expect(adapter.prBody!['title'], 'Add my-script');
    });

    test('a missing fork is created first', () async {
      await prefs.setString('GithubToken', 'gho_test');
      final adapter = _GithubAdapter(forkExists: false);
      await build(adapter).publish(item());
      expect(adapter.calls.any((c) => c.contains('/forks')), isTrue);
    });

    test('publishing without a token is refused', () async {
      expect(() => build(_GithubAdapter()).publish(item()), throwsException);
    });
  });

  // The bundled id can be overridden with --dart-define=GITHUB_CLIENT_ID, so
  // these run in all three states: plain `flutter test` (no define → bundled
  // id), `flutter test --dart-define=GITHUB_CLIENT_ID=x` (override) and
  // `flutter test --dart-define=GITHUB_CLIENT_ID=` (empty define, what the
  // release scripts pass while the CI variable is unset → bundled id).
  group('configuration', () {
    test('the bundled id is a GitHub OAuth app client id, not a secret', () {
      // 20 hex chars (classic OAuth apps) or the newer Ov23li... form; a
      // client *secret* is 40 hex chars and must never appear here.
      expect(kDefaultGithubClientId,
          matches(RegExp(r'^(?:[0-9a-f]{20}|Ov23li[A-Za-z0-9]{14})$')));
    });

    test('a --dart-define overrides the bundled id, an empty one does not', () {
      const defined = String.fromEnvironment('GITHUB_CLIENT_ID');
      expect(
          kGithubClientId, defined.isEmpty ? kDefaultGithubClientId : defined);
      expect(kGithubClientId, isNotEmpty);
    });

    test('isConfigured mirrors the compile-time id the publisher uses', () {
      expect(GithubPublisher.isConfigured, isTrue);
      expect(GithubPublisher().clientId, kGithubClientId);
      // An explicit id still wins over the compile-time one.
      expect(GithubPublisher(clientId: 'other').clientId, 'other');
    });

    test('the device-code request carries the id and the narrow scope',
        () async {
      final adapter = _GithubAdapter();
      // No explicit id: the compile-time one has to reach the wire.
      await GithubPublisher(dio: Dio()..httpClientAdapter = adapter)
          .requestDeviceCode();
      expect(adapter.deviceCodeBody!['client_id'], kGithubClientId);
      expect(adapter.deviceCodeBody!['scope'], 'public_repo');
    });

    test('an app without device flow enabled fails with GitHub\'s reason',
        () async {
      // GitHub sends the refusal on a 400, so a default Dio would surface a
      // generic bad-status error instead of the sentence the user needs.
      final adapter = _GithubAdapter()..deviceFlowEnabled = false;
      await expectLater(
          build(adapter).requestDeviceCode(),
          throwsA(predicate((e) => e
              .toString()
              .contains('Device Flow must be explicitly enabled'))));
    });

    test('a non-JSON refusal still fails with a readable reason', () async {
      final adapter = _GithubAdapter()..deviceFlowEnabled = false;
      adapter.deviceCodeRaw = ResponseBody.fromString('<html>nope</html>', 404,
          headers: {
            Headers.contentTypeHeader: ['text/html']
          });
      await expectLater(
          build(adapter).requestDeviceCode(),
          throwsA(predicate(
              (e) => e.toString().contains('GitHub refused the request'))));
    });

    test('both release builds forward the optional override variable', () {
      final script = File('scripts/build_macos.sh').readAsStringSync();
      expect(script, contains('--dart-define=GITHUB_CLIENT_ID='));
      // The script has to tolerate an unset variable: the define is then
      // passed empty, which the app treats as "use the bundled id".
      expect(script, contains(r'${GITHUB_CLIENT_ID:-}'));

      final mac = File('.github/workflows/macos.yml').readAsStringSync();
      expect(
          mac,
          contains(
              r'GITHUB_CLIENT_ID: ${{ vars.WSLMANAGER_GITHUB_CLIENT_ID }}'));

      final win = File('.github/workflows/releaser.yml').readAsStringSync();
      expect(
          win,
          contains('flutter build windows '
              r'--dart-define=GITHUB_CLIENT_ID=${{ vars.WSLMANAGER_GITHUB_CLIENT_ID }}'));
    });

    test('the id is never read from a secret', () {
      // The client id is public and belongs in a variable; a secret would
      // invite the client *secret* in next to it, which must never ship.
      for (final path in [
        '.github/workflows/macos.yml',
        '.github/workflows/releaser.yml',
        'scripts/build_macos.sh',
        'lib/api/github_publish.dart',
      ]) {
        final text = File(path).readAsStringSync();
        expect(text, isNot(matches(RegExp(r'secrets\.\w*CLIENT_ID'))),
            reason: '$path reads the client id from a secret');
        expect(text, isNot(contains('CLIENT_SECRET')),
            reason: '$path references a client secret');
      }
      // A GitHub client secret is a 40-hex-char string. Checked on the
      // compiled constants rather than the source text, so an override
      // passed through --dart-define is covered too and a commit SHA in a
      // comment cannot trip it.
      for (final id in [kDefaultGithubClientId, kGithubClientId]) {
        expect(id, isNot(matches(RegExp(r'^[0-9a-f]{40}$'))),
            reason: 'the compiled client id is shaped like a client secret');
      }
    });
  });
}
