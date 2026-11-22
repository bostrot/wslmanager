import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final baseDir = _findRepoRoot(Directory.current);
  final i18nDir = Directory('${baseDir.path}/lib/i18n');
  final englishFile = File('${i18nDir.path}/en.json');

  if (!await englishFile.exists()) {
    stderr.writeln('Missing base locale file: ${englishFile.path}');
    exitCode = 1;
    return;
  }

  final englishKeys = _loadKeys(await englishFile.readAsString());
  final localeFiles = i18nDir
      .listSync()
      .whereType<File>()
      .where((file) =>
          file.path.endsWith('.json') && file.path != englishFile.path)
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  var hasMissingTranslations = false;

  for (final localeFile in localeFiles) {
    final localeName = localeFile.uri.pathSegments.last;
    final localeKeys = _loadKeys(await localeFile.readAsString());
    final missingKeys = englishKeys.difference(localeKeys).toList()..sort();

    if (missingKeys.isEmpty) {
      continue;
    }

    hasMissingTranslations = true;
    stderr.writeln('Missing translation keys in $localeName:');
    for (final key in missingKeys) {
      stderr.writeln('  - $key');
    }
  }

  if (hasMissingTranslations) {
    stderr.writeln(
        'Translation check failed. Every locale must contain all English keys.');
    exitCode = 1;
  }
}

Directory _findRepoRoot(Directory startDirectory) {
  Directory currentDirectory = startDirectory;
  while (true) {
    final candidate = File('${currentDirectory.path}/lib/i18n/en.json');
    if (candidate.existsSync()) {
      return currentDirectory;
    }

    final parentDirectory = currentDirectory.parent;
    if (parentDirectory.path == currentDirectory.path) {
      break;
    }
    currentDirectory = parentDirectory;
  }

  throw StateError(
    'Could not find repo root containing lib/i18n/en.json starting from ${startDirectory.path}.',
  );
}

Set<String> _loadKeys(String jsonText) {
  final decoded = json.decode(jsonText);
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('Locale file is not a JSON object.');
  }
  return decoded.keys.toSet();
}
