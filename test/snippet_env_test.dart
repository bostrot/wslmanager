/// Tests for lib/api/snippet_env.dart — the environment a snippet asks for
/// before it runs, instead of expecting its `token=""` line to be edited
/// first (bostrot/ai-tasks#99).
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/github_publish.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/api/snippet_env.dart';

/// The manifest shape the community repo uses, with an optional `env:` block.
String manifest(String env) => '''
name: github-runner
description: A self-hosted runner
version: 1.0.0
author: bostrot
license: MIT
git: https://github.com/bostrot/wsl-scripts
distro: Ubuntu
$env''';

void main() {
  group('SnippetEnv.parse', () {
    test('reads a declared block', () {
      final vars = QuickActionItem.fromYamlString(manifest('''
env:
  - name: RUNNER_URL
    description: Where the runner registers
    required: true
  - name: RUNNER_TOKEN
    description: Registration token
    required: true
    secret: true
  - name: RUNNER_DIR
    default: /opt/actions-runner
''')).env;

      expect(vars.map((v) => v.name),
          ['RUNNER_URL', 'RUNNER_TOKEN', 'RUNNER_DIR']);
      expect(vars[0].isRequired, true);
      expect(vars[0].secret, false);
      expect(vars[1].secret, true);
      expect(vars[2].isRequired, false);
      expect(vars[2].defaultValue, '/opt/actions-runner');
      expect(vars[2].description, '');
    });

    test('a manifest without the block still parses', () {
      expect(QuickActionItem.fromYamlString(manifest('')).env, isEmpty);
    });

    test('a numeric default keeps working as text', () {
      final vars = SnippetEnv.parse([
        {'name': 'PORT', 'default': 8080}
      ]);
      expect(vars.single.defaultValue, '8080');
    });

    test('rejects a block that is not a list', () {
      expect(() => SnippetEnv.parse({'RUNNER_URL': 'x'}), throwsException);
    });

    test('rejects an entry without a usable name', () {
      expect(
          () => SnippetEnv.parse([
                {'description': 'nameless'}
              ]),
          throwsException);
      // A name is interpolated straight into an `export`, so anything that is
      // not an identifier has to be refused rather than escaped.
      expect(
          () => SnippetEnv.parse([
                {'name': 'PATH=/tmp; rm -rf /'}
              ]),
          throwsException);
      expect(
          () => SnippetEnv.parse([
                {'name': '2FA'}
              ]),
          throwsException);
    });

    test('rejects a duplicate name', () {
      expect(
          () => SnippetEnv.parse([
                {'name': 'TOKEN'},
                {'name': 'TOKEN'},
              ]),
          throwsException);
    });

    test('rejects required/secret that are not yes or no', () {
      expect(
          () => SnippetEnv.parse([
                {'name': 'TOKEN', 'required': 'yes'}
              ]),
          throwsException);
    });

    test('a malformed block costs the dialog, not the whole snippet', () {
      // The community browser drops a manifest it cannot parse, and a bad
      // env: block upstream must not make a script disappear from the list.
      final item = QuickActionItem.fromYamlString(manifest('env: nope'),
          content: 'echo "\${API_KEY:-}"');
      expect(item.env, isEmpty);
      // What the script reads is still asked for.
      expect(item.envPrompts.map((v) => v.name), ['API_KEY']);
    });

    test('a description that is not text is refused', () {
      expect(
          () => SnippetEnv.parse([
                {
                  'name': 'TOKEN',
                  'description': {'a': 'b'}
                }
              ]),
          throwsException);
    });
  });

  group('round trip through prefs metadata', () {
    test('a declared block survives being saved and read back', () {
      final item = QuickActionItem.fromYamlString(manifest('''
env:
  - name: RUNNER_URL
    description: Where the runner registers
    required: true
  - name: RUNNER_TOKEN
    secret: true
'''), content: 'echo hi');

      final reread = QuickActionItem.fromYamlString(item.toYamlString());
      expect(reread.env.map((v) => v.name), ['RUNNER_URL', 'RUNNER_TOKEN']);
      expect(reread.env[0].description, 'Where the runner registers');
      expect(reread.env[0].isRequired, true);
      expect(reread.env[1].secret, true);
    });

    test('a snippet with no block writes no env line', () {
      final item = QuickActionItem.fromYamlString(manifest(''));
      expect(item.toYamlString(), isNot(contains('env:')));
      expect(QuickActionItem.fromYamlString(item.toYamlString()).env, isEmpty);
    });
  });

  group('the block a shared snippet carries', () {
    test('survives the trip through a pull request', () {
      final item = QuickActionItem.fromYamlString(manifest('''
env:
  - name: RUNNER_URL
    description: "Register with: https://github.com/OWNER/REPO # or an org"
    required: true
  - name: RUNNER_DIR
    default: /opt/actions-runner
  - name: RUNNER_TOKEN
    secret: true
'''), content: 'echo hi');

      final info =
          GithubPublisher.filesFor(item)['scripts/github-runner/info.yml']!;
      final reread = QuickActionItem.fromYamlString(info);
      expect(reread.env.map((v) => v.name),
          ['RUNNER_URL', 'RUNNER_DIR', 'RUNNER_TOKEN']);
      expect(reread.env[0].description,
          'Register with: https://github.com/OWNER/REPO # or an org');
      expect(reread.env[0].isRequired, true);
      expect(reread.env[1].defaultValue, '/opt/actions-runner');
      expect(reread.env[2].secret, true);
    });

    test('a snippet with no block shares no block', () {
      final info = GithubPublisher.filesFor(QuickActionItem.fromYamlString(
          manifest(''),
          content: 'echo hi'))['scripts/github-runner/info.yml']!;
      expect(info, isNot(contains('env:')));
    });
  });

  group('SnippetEnv.detect', () {
    test('finds what the script reads but never sets', () {
      const script = '''
url="\${RUNNER_URL:-\$url}"
token="\${RUNNER_TOKEN:-\$token}"
dir="\${RUNNER_DIR:-/opt/actions-runner}"
''';
      expect(SnippetEnv.detect(script).map((v) => v.name),
          ['RUNNER_URL', 'RUNNER_TOKEN', 'RUNNER_DIR']);
    });

    test('skips what the script sets itself', () {
      const script = '''
PREFIX=/opt
export MARKER=1
for STEP in 1 2 3; do echo "\$STEP \$PREFIX \$MARKER"; done
''';
      expect(SnippetEnv.detect(script), isEmpty);
    });

    test('a variable defaulting to itself is still an input', () {
      // `TOKEN="${TOKEN:-}"` is how a script says "from the environment".
      expect(
          SnippetEnv.detect('TOKEN="\${TOKEN:-}"\necho "\$TOKEN"')
              .map((v) => v.name),
          ['TOKEN']);
    });

    test('skips the shell, the login and /etc/os-release', () {
      const script = '''
. /etc/os-release
echo "\$ID \$VERSION_CODENAME \$PRETTY_NAME"
cd "\$HOME" && echo "\$PATH \$USER \$WSL_DISTRO_NAME"
''';
      expect(SnippetEnv.detect(script), isEmpty);
    });

    test('a variable named only in a comment is not offered', () {
      // The runner scripts explain their inputs in prose above the code; a
      // sentence mentioning one is not the script reading it.
      expect(SnippetEnv.detect('# set \$API_KEY before running\necho done'),
          isEmpty);
    });

    test('lower-case locals are not offered', () {
      expect(SnippetEnv.detect('echo "\$dir \$token \$missing"'), isEmpty);
    });

    test('a name is offered once, however often it is read', () {
      expect(
          SnippetEnv.detect('echo \$API_KEY; curl -H "x: \${API_KEY}"')
              .map((v) => v.name),
          ['API_KEY']);
    });
  });

  group('SnippetEnv.prompts', () {
    test('a declared block is taken as complete', () {
      // GH_TOKEN is an alias the github-runner script reads; the author who
      // declared the block left it out on purpose, so it is not asked for.
      final declared = SnippetEnv.parse([
        {'name': 'RUNNER_TOKEN', 'description': 'Token', 'secret': true},
      ]);
      final prompts =
          SnippetEnv.prompts(declared, 'echo "\$RUNNER_TOKEN \${GH_TOKEN:-}"');
      expect(prompts.map((v) => v.name), ['RUNNER_TOKEN']);
      expect(prompts.single.secret, true);
    });

    test('a declared variable is asked for even when the shell provides it',
        () {
      final declared = SnippetEnv.parse([
        {'name': 'VERSION'}
      ]);
      expect(SnippetEnv.prompts(declared, 'echo \$VERSION').map((v) => v.name),
          ['VERSION']);
    });

    test('a snippet with no block falls back to what it reads', () {
      expect(
          SnippetEnv.prompts(const [], 'echo "\${API_KEY:-}"')
              .map((v) => v.name),
          ['API_KEY']);
    });
  });

  group('SnippetEnv.exportLines', () {
    test('sets each value, encoded so no shell can read it', () {
      final lines = SnippetEnv.exportLines({'RUNNER_URL': 'https://x/y'});
      expect(lines.first, startsWith('#'));
      expect(lines.last,
          'export RUNNER_URL="\$(printf %s ${base64.encode(utf8.encode('https://x/y'))} | base64 -d)"');
    });

    test('a value full of shell metacharacters survives', () {
      const password = 'p\$ass`word"with\'quotes and a \\slash';
      final line = SnippetEnv.exportLines({'PASSWORD': password}).last;
      final encoded = RegExp(r'printf %s (\S+) \|').firstMatch(line)!.group(1)!;
      expect(utf8.decode(base64.decode(encoded)), password);
      // Nothing of the value itself is in the line, so nothing in it can be
      // expanded on the way to the guest.
      expect(line, isNot(contains('quotes')));
    });

    test('an empty value stays unset instead of being exported empty', () {
      expect(SnippetEnv.exportLines({'RUNNER_NAME': ''}), isEmpty);
      final lines = SnippetEnv.exportLines({'A': '', 'B': 'set'});
      expect(lines.where((l) => l.startsWith('export')).length, 1);
    });

    test('a name that is not an identifier is dropped, never interpolated', () {
      expect(SnippetEnv.exportLines({'PATH; rm -rf /': 'x'}), isEmpty);
    });
  });

  group('SnippetEnv.filled', () {
    test('keeps what was typed and drops what was not', () {
      expect(
          SnippetEnv.filled({'A': 'x', 'B': '', 'bad name': 'y'}), {'A': 'x'});
    });
  });
}
