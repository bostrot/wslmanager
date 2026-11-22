import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';

void main() {
  group('QuickActionItem.fromYamlString', () {
    test('parses valid yaml with string distro', () {
      const yaml = '''
name: Test Action
description: A test action
version: "1.0.0"
author: Test Author
license: MIT
git: https://github.com/test/repo
distro: ubuntu
''';

      final item = QuickActionItem.fromYamlString(yaml);

      expect(item.name, 'Test Action');
      expect(item.description, 'A test action');
      expect(item.version, '1.0.0');
      expect(item.author, 'Test Author');
      expect(item.license, 'MIT');
      expect(item.git, 'https://github.com/test/repo');
      expect(item.distro, 'ubuntu');
    });

    test('parses valid yaml with list distro', () {
      const yaml = '''
name: Multi Distro Action
description: Works on multiple distros
version: "2.0.0"
author: Another Author
license: Apache-2.0
git: https://github.com/another/repo
distro:
  - ubuntu
  - debian
''';

      final item = QuickActionItem.fromYamlString(yaml);

      expect(item.name, 'Multi Distro Action');
      expect(item.distro, isA<List>());
    });

    test('throws on invalid yaml structure', () {
      const yaml = '''
this: is not valid
''';

      expect(() => QuickActionItem.fromYamlString(yaml), throwsException);
    });

    test('throws when name is missing', () {
      const yaml = '''
description: Missing name field
version: "1.0.0"
author: Test
license: MIT
git: https://example.com
distro: ubuntu
''';

      expect(() => QuickActionItem.fromYamlString(yaml), throwsException);
    });

    test('throws when distro is invalid type', () {
      const yaml = '''
name: Bad Distro
description: Test
version: "1.0.0"
author: Test
license: MIT
git: https://example.com
distro: 123
''';

      expect(() => QuickActionItem.fromYamlString(yaml), throwsException);
    });
  });

  group('QuickActionItem.toYamlString', () {
    test('serializes to yaml string', () {
      final item = QuickActionItem(
        name: 'Test Action',
        description: 'A test action',
        version: '1.0.0',
        author: 'Test Author',
        license: 'MIT',
        git: 'https://github.com/test/repo',
        distro: 'ubuntu',
        content: 'echo hello',
      );

      final yaml = item.toYamlString();

      // Scalars are JSON-quoted now, so an empty field survives the reload
      // round-trip instead of parsing back as YAML null.
      expect(yaml, contains('name: "Test Action"'));
      expect(yaml, contains('description: "A test action"'));
      expect(yaml, contains('version: "1.0.0"'));
      expect(yaml, contains('author: "Test Author"'));
      expect(yaml, contains('license: "MIT"'));
      expect(yaml, contains('git: "https://github.com/test/repo"'));
      expect(yaml, contains('distro: "ubuntu"'));

      // The point of the quoting: a snippet with empty fields still parses.
      final round = QuickActionItem.fromYamlString(
          QuickActionItem(name: 'n', content: 'c').toYamlString());
      expect(round.name, 'n');
      expect(round.description, '');
    });

    test('round-trips yaml parse and serialize', () {
      const originalYaml = '''
name: Round Trip Test
description: Testing round trip
version: "3.0.0"
author: Round Tripper
license: GPL-3.0
git: https://github.com/rt/test
distro: debian
''';

      final item = QuickActionItem.fromYamlString(originalYaml);
      final serialized = item.toYamlString();
      final reparsed = QuickActionItem.fromYamlString(serialized);

      expect(reparsed.name, 'Round Trip Test');
      expect(reparsed.description, 'Testing round trip');
      expect(reparsed.version, '3.0.0');
      expect(reparsed.author, 'Round Tripper');
      expect(reparsed.license, 'GPL-3.0');
      expect(reparsed.git, 'https://github.com/rt/test');
      expect(reparsed.distro, 'debian');
    });
  });

  group('QuickActionItem constructor', () {
    test('creates item with default values', () {
      final item = QuickActionItem(name: 'Minimal', content: 'echo hi');

      expect(item.name, 'Minimal');
      expect(item.description, '');
      expect(item.version, '');
      expect(item.author, '');
      expect(item.license, '');
      expect(item.git, '');
      expect(item.distro, '');
      expect(item.content, 'echo hi');
    });
  });
}
