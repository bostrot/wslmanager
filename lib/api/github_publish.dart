import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/api/snippet_env.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Where a snippet is published to.
const String kScriptsOwner = 'bostrot';
const String kScriptsRepo = 'wsl-scripts';
const String kScriptsBranch = 'main';

/// The client id of the "WSL Manager" OAuth app on GitHub, used for the
/// device flow (bostrot/ai-tasks#6).
///
/// Device flow, not the web flow, precisely because this is a desktop app: a
/// client *secret* shipped in a binary is extractable by anyone who installs
/// it, so GitHub treats desktop apps as public clients and the device flow
/// needs no secret at all. The id is public information — it travels in
/// every device-flow request — which is why it can live here in source. The
/// app's callback URL is irrelevant to the device flow, but **Enable Device
/// Flow** must be ticked on the app's settings page or GitHub answers every
/// sign-in with `device_flow_disabled`.
const String kDefaultGithubClientId = '9c2cbef8ac5d26ec745b';

/// A build can point at a different OAuth app with
/// `--dart-define=GITHUB_CLIENT_ID=...`. The release scripts always pass the
/// define, empty while their CI variable is unset, so an empty value has to
/// mean "the bundled id" rather than "no id".
const String _definedGithubClientId =
    String.fromEnvironment('GITHUB_CLIENT_ID');

/// The client id the app signs in with: the `--dart-define` override when one
/// is set, otherwise [kDefaultGithubClientId]. Never empty, so
/// [GithubPublisher.isConfigured] only turns false if the bundled id is
/// removed from source.
const String kGithubClientId = _definedGithubClientId == ''
    ? kDefaultGithubClientId
    : _definedGithubClientId;

/// What the user has to do to finish signing in.
class DeviceCodePrompt {
  const DeviceCodePrompt({
    required this.userCode,
    required this.verificationUri,
    required this.deviceCode,
    required this.interval,
    required this.expiresIn,
  });

  /// The code the user types into [verificationUri].
  final String userCode;
  final String verificationUri;
  final String deviceCode;

  /// Seconds GitHub asks us to wait between polls.
  final int interval;
  final int expiresIn;
}

class GithubPublishResult {
  const GithubPublishResult({required this.pullRequestUrl});
  final String pullRequestUrl;
}

/// Opens a pull request against the community scripts repo for one snippet.
///
/// The snippet becomes the two files the repo's format requires — an
/// `info.yml` of metadata and the `script.noshell` body — inside a folder
/// named after the snippet, pushed to a branch on the user's own fork.
class GithubPublisher {
  GithubPublisher({Dio? dio, String? clientId})
      : _dio = dio ?? Dio(),
        clientId = clientId ?? kGithubClientId;

  final Dio _dio;
  final String clientId;

  /// Always true while [kDefaultGithubClientId] is set; kept as the gate for
  /// the share dialog so a fork that blanks the id gets the explanatory
  /// InfoBar rather than a failed request.
  static bool get isConfigured => kGithubClientId.isNotEmpty;

  static String? get storedToken {
    final token = prefs.getString('GithubToken');
    return (token == null || token.isEmpty) ? null : token;
  }

  static Future<void> clearToken() => prefs.remove('GithubToken');

  Options get _auth => Options(headers: {
        'Authorization': 'Bearer ${storedToken ?? ''}',
        'Accept': 'application/vnd.github+json',
      });

  // ---------------------------------------------------------------------
  // Device flow
  // ---------------------------------------------------------------------

  /// Step one: ask GitHub for a code the user types in a browser.
  Future<DeviceCodePrompt> requestDeviceCode() async {
    final response = await _dio.post(
      'https://github.com/login/device/code',
      data: {'client_id': clientId, 'scope': 'public_repo'},
      options: Options(
        headers: {'Accept': 'application/json'},
        // GitHub explains a refusal (device flow not enabled on the app, an
        // unknown client id) in a JSON body on a 4xx; that sentence is what
        // the user should see, not a generic bad-status error.
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    final data = response.data;
    if (data is! Map || data['device_code'] == null) {
      final reason = data is Map
          ? (data['error_description'] ?? data['error'])
          : null;
      throw Exception(reason ?? 'GitHub refused the request');
    }
    return DeviceCodePrompt(
      userCode: data['user_code'].toString(),
      verificationUri: data['verification_uri'].toString(),
      deviceCode: data['device_code'].toString(),
      interval: (data['interval'] as num?)?.toInt() ?? 5,
      expiresIn: (data['expires_in'] as num?)?.toInt() ?? 900,
    );
  }

  /// Step two: poll until the user finishes in the browser, then keep the
  /// token. Returns false if they never did before the code expired.
  Future<bool> pollForToken(DeviceCodePrompt prompt,
      {Duration? pollInterval, bool Function()? cancelled}) async {
    final wait = pollInterval ?? Duration(seconds: prompt.interval);
    final deadline =
        DateTime.now().add(Duration(seconds: prompt.expiresIn));

    while (DateTime.now().isBefore(deadline)) {
      if (cancelled?.call() ?? false) return false;
      await Future<void>.delayed(wait);

      final response = await _dio.post(
        'https://github.com/login/oauth/access_token',
        data: {
          'client_id': clientId,
          'device_code': prompt.deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
        options: Options(
          headers: {'Accept': 'application/json'},
          // A pending authorization comes back as a 4xx with a body that
          // says so; that is not a failure to retry-with-backoff on.
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final data = response.data as Map;
      final token = data['access_token'];
      if (token != null) {
        await prefs.setString('GithubToken', token.toString());
        return true;
      }
      final error = data['error']?.toString();
      if (error == 'authorization_pending') continue;
      if (error == 'slow_down') {
        await Future<void>.delayed(const Duration(seconds: 5));
        continue;
      }
      throw Exception(data['error_description'] ?? error ?? 'Sign-in failed');
    }
    return false;
  }

  // ---------------------------------------------------------------------
  // Publishing
  // ---------------------------------------------------------------------

  /// The two files the repo's format is made of.
  static Map<String, String> filesFor(QuickActionItem item) {
    final distro = item.distro;
    final distroYaml = distro is List
        ? '\n${distro.map((d) => '  - $d').join('\n')}'
        : ' ${distro ?? 'Debian'}';
    final info = 'name: ${item.name}\n'
        'description: ${item.description}\n'
        'version: ${item.version.isEmpty ? '1.0.0' : item.version}\n'
        'author: ${item.author}\n'
        'license: ${item.license.isEmpty ? 'MIT' : item.license}\n'
        'git: ${item.git.isEmpty ? 'https://github.com/$kScriptsOwner/$kScriptsRepo' : item.git}\n'
        'distro:$distroYaml\n'
        // Kept in the shared copy: the block is what makes the app ask for the
        // snippet's inputs instead of expecting them to be edited in.
        '${SnippetEnv.toBlockYaml(item.env)}';
    return {
      'scripts/${item.name}/info.yml': info,
      'scripts/${item.name}/script.noshell': item.content,
    };
  }

  Future<String> _login() async {
    final response =
        await _dio.get('https://api.github.com/user', options: _auth);
    return (response.data as Map)['login'].toString();
  }

  /// Forks the scripts repo under the signed-in account, or returns the
  /// existing fork. GitHub creates forks asynchronously, so this waits for
  /// the fork to become readable before anything is pushed to it.
  Future<String> _ensureFork(String login) async {
    try {
      await _dio.get('https://api.github.com/repos/$login/$kScriptsRepo',
          options: _auth);
      return login;
    } on DioException {
      // No fork yet.
    }
    await _dio.post(
      'https://api.github.com/repos/$kScriptsOwner/$kScriptsRepo/forks',
      options: _auth,
    );
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        await _dio.get('https://api.github.com/repos/$login/$kScriptsRepo',
            options: _auth);
        return login;
      } on DioException {
        continue;
      }
    }
    throw Exception('The fork was not ready in time; try again in a moment.');
  }

  /// Creates the branch, writes both files and opens the pull request.
  Future<GithubPublishResult> publish(QuickActionItem item) async {
    if (storedToken == null) {
      throw Exception('Not signed in to GitHub');
    }
    final login = await _login();
    await _ensureFork(login);

    // Branch from whatever upstream's default branch points at, so the
    // change is never based on a stale fork.
    final upstreamRef = await _dio.get(
      'https://api.github.com/repos/$kScriptsOwner/$kScriptsRepo/git/ref/heads/$kScriptsBranch',
      options: _auth,
    );
    final baseSha = (upstreamRef.data as Map)['object']['sha'].toString();

    final branch =
        'add-${item.name}-${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    await _dio.post(
      'https://api.github.com/repos/$login/$kScriptsRepo/git/refs',
      data: {'ref': 'refs/heads/$branch', 'sha': baseSha},
      options: _auth,
    );

    for (final entry in filesFor(item).entries) {
      await _dio.put(
        'https://api.github.com/repos/$login/$kScriptsRepo/contents/${entry.key}',
        data: {
          'message': 'Add ${item.name}',
          'content': base64.encode(utf8.encode(entry.value)),
          'branch': branch,
        },
        options: _auth,
      );
    }

    final pr = await _dio.post(
      'https://api.github.com/repos/$kScriptsOwner/$kScriptsRepo/pulls',
      data: {
        'title': 'Add ${item.name}',
        'head': '$login:$branch',
        'base': kScriptsBranch,
        'body': '${item.description}\n\n'
            'Submitted from WSL Manager.',
      },
      options: _auth,
    );
    return GithubPublishResult(
        pullRequestUrl: (pr.data as Map)['html_url'].toString());
  }
}
