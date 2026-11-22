import 'dart:io';

/// Checks that every translated README under `readme/` still mirrors the
/// English `README.md`.
///
/// Translations rot quietly: the English README gains a section, swaps a
/// screenshot or changes a link, and the eight translations keep advertising
/// the app as it was two years ago. Prose cannot be diffed automatically, but
/// structure can — headings, images, links, code blocks, feature bullets and
/// `<details>` blocks all have to line up, and any of them drifting apart is a
/// translation that no longer describes this app.
///
///   dart run scripts/check_readme_translations.dart
const String englishReadmePath = 'README.md';
const String translationDirectory = 'readme';

/// Only `readme/README_<lang>.md` is a translation of the English README;
/// anything else that happens to live there is left alone.
final RegExp translationFileName = RegExp(r'^README_[a-z_]+\.md$');

/// The parts of a README that must be identical in every language.
class ReadmeStructure {
  ReadmeStructure({
    required this.path,
    required this.imagePaths,
    required this.documentLinks,
    required this.urls,
    required this.codeBlocks,
    required this.headingLevels,
    required this.checklistItems,
    required this.detailsBlocks,
  });

  /// Repo-relative path of the README itself, e.g. `readme/README_de.md`.
  final String path;

  /// Repo-relative targets of the local images, in the order they appear.
  final List<String> imagePaths;

  /// Repo-relative targets of the links to the other README translations.
  final Set<String> documentLinks;

  /// Every external link and badge the document points at.
  final Set<String> urls;

  /// Fenced code blocks, info string included. Commands are never translated.
  final List<String> codeBlocks;

  /// The level of each Markdown heading, in order.
  final List<int> headingLevels;

  /// Number of `- [x]` feature bullets.
  final int checklistItems;

  /// Number of `<details>` blocks.
  final int detailsBlocks;
}

final RegExp _imagePattern = RegExp(r'!\[[^\]]*\]\(([^)\s]+)\)');
final RegExp _linkPattern = RegExp(r'\]\(([^)\s]+)\)');
final RegExp _hrefPattern = RegExp('''href=['"]([^'"]+)['"]''');
final RegExp _headingPattern = RegExp(r'^(#{1,6})\s');
final RegExp _checklistPattern =
    RegExp(r'^\s*-\s\[x\]\s', caseSensitive: false);

ReadmeStructure parseReadme(String markdown, {required String path}) {
  final directory =
      path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';

  final codeBlocks = <String>[];
  final proseLines = <String>[];
  final buffer = <String>[];
  var insideCodeBlock = false;

  for (final line in markdown.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      buffer.add(line);
      if (insideCodeBlock) {
        codeBlocks.add(buffer.join('\n'));
        buffer.clear();
      }
      insideCodeBlock = !insideCodeBlock;
      continue;
    }
    if (insideCodeBlock) {
      buffer.add(line);
    } else {
      proseLines.add(line);
    }
  }
  if (insideCodeBlock) {
    codeBlocks.add(buffer.join('\n'));
  }

  final prose = proseLines.join('\n');
  final imagePaths = <String>[];
  final documentLinks = <String>{};
  final urls = <String>{};

  for (final match in _imagePattern.allMatches(prose)) {
    final target = match.group(1)!;
    if (!_isExternal(target)) {
      imagePaths.add(resolveRelativePath(directory, target));
    }
  }

  final targets = <String>[
    for (final match in _linkPattern.allMatches(prose)) match.group(1)!,
    for (final match in _hrefPattern.allMatches(prose)) match.group(1)!,
  ];
  for (final target in targets) {
    if (_isExternal(target)) {
      urls.add(target);
    } else if (target.endsWith('.md')) {
      documentLinks.add(resolveRelativePath(directory, target));
    }
  }

  final headingLevels = <int>[];
  var checklistItems = 0;
  var detailsBlocks = 0;
  for (final line in proseLines) {
    final heading = _headingPattern.firstMatch(line);
    if (heading != null) {
      headingLevels.add(heading.group(1)!.length);
    }
    if (_checklistPattern.hasMatch(line)) {
      checklistItems++;
    }
    if (line.toLowerCase().contains('<details>')) {
      detailsBlocks++;
    }
  }

  return ReadmeStructure(
    path: path,
    imagePaths: imagePaths,
    documentLinks: documentLinks,
    urls: urls,
    codeBlocks: codeBlocks,
    headingLevels: headingLevels,
    checklistItems: checklistItems,
    detailsBlocks: detailsBlocks,
  );
}

/// Turns a link target that is relative to [directory] into a repo-relative
/// path, so `./images/home-dark.png` in `readme/` and `./readme/images/
/// home-dark.png` in the root README compare equal.
String resolveRelativePath(String directory, String target) {
  final segments = <String>[
    ...directory.split('/').where((segment) => segment.isNotEmpty),
  ];
  for (final segment in target.split('/')) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..') {
      if (segments.isNotEmpty) {
        segments.removeLast();
      }
      continue;
    }
    segments.add(segment);
  }
  return segments.join('/');
}

/// Compares one translation against the English original and describes every
/// way the two have drifted apart.
List<String> compareStructures(
  ReadmeStructure english,
  ReadmeStructure translation, {
  required Set<String> expectedDocumentLinks,
}) {
  final problems = <String>[];

  if (!_sameList(english.imagePaths, translation.imagePaths)) {
    problems.add(
      'images differ: expected ${english.imagePaths}, found '
      '${translation.imagePaths}',
    );
  }

  if (english.codeBlocks.length != translation.codeBlocks.length) {
    problems.add(
      'expected ${english.codeBlocks.length} code blocks, found '
      '${translation.codeBlocks.length}',
    );
  } else {
    for (var index = 0; index < english.codeBlocks.length; index++) {
      if (english.codeBlocks[index] != translation.codeBlocks[index]) {
        problems.add(
          'code block ${index + 1} was translated; commands must stay verbatim',
        );
      }
    }
  }

  final missingUrls = english.urls.difference(translation.urls).toList()
    ..sort();
  if (missingUrls.isNotEmpty) {
    problems.add('missing links: ${missingUrls.join(', ')}');
  }
  final extraUrls = translation.urls.difference(english.urls).toList()..sort();
  if (extraUrls.isNotEmpty) {
    problems.add('stale or unknown links: ${extraUrls.join(', ')}');
  }

  if (!_sameList(english.headingLevels, translation.headingLevels)) {
    problems.add(
      'heading structure differs: expected ${english.headingLevels.length} '
      'headings shaped ${english.headingLevels}, found '
      '${translation.headingLevels.length} shaped ${translation.headingLevels}',
    );
  }

  if (english.checklistItems != translation.checklistItems) {
    problems.add(
      'expected ${english.checklistItems} feature bullets, found '
      '${translation.checklistItems}',
    );
  }

  if (english.detailsBlocks != translation.detailsBlocks) {
    problems.add(
      'expected ${english.detailsBlocks} <details> blocks, found '
      '${translation.detailsBlocks}',
    );
  }

  final missingLanguages = expectedDocumentLinks
      .difference(translation.documentLinks)
      .toList()
    ..sort();
  if (missingLanguages.isNotEmpty) {
    problems.add(
      'language switcher is missing ${missingLanguages.join(', ')}',
    );
  }
  if (translation.documentLinks.contains(translation.path)) {
    problems.add('language switcher links to itself');
  }
  final unknownLanguages = translation.documentLinks
      .difference(expectedDocumentLinks)
      .where((link) => link != translation.path)
      .toList()
    ..sort();
  if (unknownLanguages.isNotEmpty) {
    problems.add(
      'language switcher points at ${unknownLanguages.join(', ')}, which does '
      'not exist',
    );
  }

  return problems;
}

bool _sameList<T>(List<T> first, List<T> second) {
  if (first.length != second.length) {
    return false;
  }
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) {
      return false;
    }
  }
  return true;
}

bool _isExternal(String target) =>
    target.startsWith('http://') || target.startsWith('https://');

Future<void> main(List<String> arguments) async {
  final root = _findRepoRoot(Directory.current);
  final english = parseReadme(
    await File('${root.path}/$englishReadmePath').readAsString(),
    path: englishReadmePath,
  );

  final translationFiles = Directory('${root.path}/$translationDirectory')
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.md'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (translationFiles.isEmpty) {
    stderr.writeln('No translated READMEs found in $translationDirectory/.');
    exitCode = 1;
    return;
  }

  final allDocuments = <String>{
    englishReadmePath,
    for (final file in translationFiles)
      '$translationDirectory/${file.uri.pathSegments.last}',
  };

  var failed = false;
  final missingFromEnglish = allDocuments
      .difference({english.path, ...english.documentLinks}).toList()
    ..sort();
  if (missingFromEnglish.isNotEmpty) {
    stderr.writeln(
      "$englishReadmePath does not link to ${missingFromEnglish.join(', ')}",
    );
    failed = true;
  }

  final danglingLinks = english.documentLinks
      .where((link) => !File('${root.path}/$link').existsSync())
      .toList()
    ..sort();
  if (danglingLinks.isNotEmpty) {
    stderr.writeln(
      "$englishReadmePath links to ${danglingLinks.join(', ')}, which does "
      'not exist',
    );
    failed = true;
  }

  for (final file in translationFiles) {
    final path = '$translationDirectory/${file.uri.pathSegments.last}';
    final translation = parseReadme(
      await file.readAsString(),
      path: path,
    );
    final problems = compareStructures(
      english,
      translation,
      expectedDocumentLinks: allDocuments.difference({path}),
    );
    if (problems.isEmpty) {
      continue;
    }

    failed = true;
    stderr.writeln('$path is out of sync with $englishReadmePath:');
    for (final problem in problems) {
      stderr.writeln('  - $problem');
    }
  }

  if (failed) {
    stderr.writeln(
      'README translation check failed. Update the translations to match '
      '$englishReadmePath.',
    );
    exitCode = 1;
  }
}

Directory _findRepoRoot(Directory startDirectory) {
  Directory currentDirectory = startDirectory;
  while (true) {
    if (File('${currentDirectory.path}/$englishReadmePath').existsSync() &&
        Directory('${currentDirectory.path}/$translationDirectory')
            .existsSync()) {
      return currentDirectory;
    }

    final parentDirectory = currentDirectory.parent;
    if (parentDirectory.path == currentDirectory.path) {
      break;
    }
    currentDirectory = parentDirectory;
  }

  throw StateError(
    'Could not find repo root containing $englishReadmePath and '
    '$translationDirectory/ starting from ${startDirectory.path}.',
  );
}
