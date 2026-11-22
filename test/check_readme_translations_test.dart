import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../scripts/check_readme_translations.dart';

/// A miniature README shaped like the real one: a language switcher, a local
/// screenshot, a badge, a feature bullet, a `<details>` block and a command
/// that must not be translated.
String readmeSource({
  String languageSwitcher = "<a href='./readme/README_de.md'>Deutsch</a> | "
      "<a href='./readme/README_ja.md'>日本語</a>",
  String screenshot = './readme/images/home-dark.png',
  String heading = '## Features',
  String bullet = '- [x] Install from a built-in catalogue',
  String command = 'flutter build windows # build it',
  String details = '''
<details>
<summary>Preview</summary>
</details>
''',
}) {
  return '''
<h1 align="center">Welcome to WSL Manager</h1>

[![Discord](https://img.shields.io/discord/1100070299308937287)](https://discord.gg/fY5uE5WRTP)

<p align='center'>
    $languageSwitcher
</p>

![WSL Distro Manager]($screenshot)

$details

$heading

$bullet

```powershell
$command
```
''';
}

/// The translation of [readmeSource] a maintainer is supposed to keep in step.
String translationSource({
  String languageSwitcher = "<a href='../README.md'>English</a> | "
      "<a href='./README_ja.md'>日本語</a>",
  String screenshot = './images/home-dark.png',
  String heading = '## Funktionen',
  String bullet = '- [x] Installation aus einem eingebauten Katalog',
  String command = 'flutter build windows # build it',
  String details = '''
<details>
<summary>Vorschau</summary>
</details>
''',
}) {
  return readmeSource(
    languageSwitcher: languageSwitcher,
    screenshot: screenshot,
    heading: heading,
    bullet: bullet,
    command: command,
    details: details,
  );
}

List<String> compareSources(String english, String translation) {
  return compareStructures(
    parseReadme(english, path: 'README.md'),
    parseReadme(translation, path: 'readme/README_de.md'),
    expectedDocumentLinks: <String>{
      'README.md',
      'readme/README_ja.md',
    },
  );
}

void main() {
  group('parseReadme', () {
    test('resolves image paths relative to the file that references them', () {
      final english = parseReadme(readmeSource(), path: 'README.md');
      final german = parseReadme(
        translationSource(),
        path: 'readme/README_de.md',
      );

      expect(english.imagePaths, <String>['readme/images/home-dark.png']);
      expect(german.imagePaths, english.imagePaths);
    });

    test('keeps comments inside code blocks out of the heading list', () {
      final structure = parseReadme(
        readmeSource(command: '# Build + sign vmctl\nVMCTL_ONLY=1 build.sh'),
        path: 'README.md',
      );

      expect(structure.headingLevels, <int>[2]);
      expect(structure.codeBlocks.single, contains('# Build + sign vmctl'));
    });

    test('separates external links from links to other translations', () {
      final structure = parseReadme(readmeSource(), path: 'README.md');

      expect(structure.documentLinks, <String>{
        'readme/README_de.md',
        'readme/README_ja.md',
      });
      expect(structure.urls, contains('https://discord.gg/fY5uE5WRTP'));
      expect(
        structure.urls,
        contains('https://img.shields.io/discord/1100070299308937287'),
      );
    });

    test('counts feature bullets and details blocks', () {
      final structure = parseReadme(readmeSource(), path: 'README.md');

      expect(structure.checklistItems, 1);
      expect(structure.detailsBlocks, 1);
    });
  });

  group('resolveRelativePath', () {
    test('walks out of the translation directory', () {
      expect(resolveRelativePath('readme', '../README.md'), 'README.md');
    });

    test('drops the leading dot of a sibling link', () {
      expect(
        resolveRelativePath('readme', './README_de.md'),
        'readme/README_de.md',
      );
    });

    test('leaves a root-level target untouched', () {
      expect(resolveRelativePath('', './readme/images/a.png'),
          'readme/images/a.png');
    });
  });

  group('compareStructures', () {
    test('accepts a translation that only translates prose', () {
      expect(compareSources(readmeSource(), translationSource()), isEmpty);
    });

    test('rejects a screenshot the English README no longer uses', () {
      final problems = compareSources(
        readmeSource(),
        translationSource(
          screenshot:
              'https://user-images.githubusercontent.com/7342321/233077564.png',
        ),
      );

      expect(problems, hasLength(2));
      expect(problems.first, contains('images differ'));
      expect(problems.last, contains('stale or unknown links'));
    });

    test('rejects a translated command', () {
      final problems = compareSources(
        readmeSource(),
        translationSource(command: 'flutter build windows # baue es'),
      );

      expect(problems.single, contains('code block 1 was translated'));
    });

    test('rejects a dropped feature bullet', () {
      final problems = compareSources(
        readmeSource(),
        translationSource(bullet: 'und mehr...'),
      );

      expect(problems.single, contains('expected 1 feature bullets, found 0'));
    });

    test('rejects a section the translation never caught up with', () {
      final problems = compareSources(
        readmeSource(heading: '## Features\n\n### Manage distros'),
        translationSource(),
      );

      expect(problems.single, contains('heading structure differs'));
    });

    test('rejects a language switcher that lost a language', () {
      final problems = compareSources(
        readmeSource(),
        translationSource(
          languageSwitcher: "<a href='../README.md'>English</a>",
        ),
      );

      expect(
        problems.single,
        contains('language switcher is missing readme/README_ja.md'),
      );
    });

    test('rejects a language switcher that links back to its own page', () {
      final problems = compareSources(
        readmeSource(),
        translationSource(
          languageSwitcher: "<a href='../README.md'>English</a> | "
              "<a href='./README_ja.md'>日本語</a> | "
              "<a href='./README_de.md'>Deutsch</a>",
        ),
      );

      expect(problems.single, contains('language switcher links to itself'));
    });

    test('rejects a language switcher pointing at a language that is gone', () {
      final problems = compareSources(
        readmeSource(),
        translationSource(
          languageSwitcher: "<a href='../README.md'>English</a> | "
              "<a href='./README_ja.md'>日本語</a> | "
              "<a href='./README_fr.md'>Français</a>",
        ),
      );

      expect(
        problems.single,
        contains('language switcher points at readme/README_fr.md'),
      );
    });

    test('rejects a link the English README dropped', () {
      final problems = compareSources(
        readmeSource(),
        translationSource().replaceAll(
          'https://discord.gg/fY5uE5WRTP',
          'https://example.com/old-invite',
        ),
      );

      expect(problems, hasLength(2));
      expect(problems.first, contains('missing links'));
      expect(problems.last, contains('stale or unknown links'));
    });
  });

  group('the READMEs in this repo', () {
    late ReadmeStructure english;
    late List<File> translations;

    setUpAll(() {
      english = parseReadme(
        File(englishReadmePath).readAsStringSync(),
        path: englishReadmePath,
      );
      translations = Directory(translationDirectory)
          .listSync()
          .whereType<File>()
          .where((file) =>
              translationFileName.hasMatch(file.uri.pathSegments.last))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    });

    test('only treat README_<lang>.md as a translation', () {
      expect(translationFileName.hasMatch('README_zh_tw.md'), isTrue);
      expect(translationFileName.hasMatch('README.md'), isFalse);
      expect(translationFileName.hasMatch('CONTRIBUTING_de.md'), isFalse);
    });

    test('cover the nine advertised languages', () {
      expect(translations, hasLength(8));
      expect(
        english.documentLinks,
        translations
            .map(
                (file) => '$translationDirectory/${file.uri.pathSegments.last}')
            .toSet(),
      );
    });

    test('are all in sync with README.md', () {
      final allDocuments = <String>{
        englishReadmePath,
        for (final file in translations)
          '$translationDirectory/${file.uri.pathSegments.last}',
      };

      for (final file in translations) {
        final path = '$translationDirectory/${file.uri.pathSegments.last}';
        final problems = compareStructures(
          english,
          parseReadme(file.readAsStringSync(), path: path),
          expectedDocumentLinks: allDocuments.difference(<String>{path}),
        );

        expect(problems, isEmpty, reason: '$path drifted: $problems');
      }
    });

    test('reference screenshots that exist on disk', () {
      for (final imagePath in english.imagePaths) {
        expect(File(imagePath).existsSync(), isTrue,
            reason: '$imagePath is referenced but missing');
      }
    });
  });
}
