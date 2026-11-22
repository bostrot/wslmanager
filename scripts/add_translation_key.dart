import 'dart:convert';
import 'dart:io';

void main() {
  final i18nDir = Directory('lib/i18n');
  final englishFile = File('${i18nDir.path}/en.json');
  
  // Load English keys
  final englishJson = json.decode(englishFile.readAsStringSync()) as Map<String, dynamic>;
  
  // Find files missing ai-workspace-title
  for (final file in i18nDir.listSync().whereType<File>()) {
    if (!file.path.endsWith('.json') || file.path == englishFile.path) {
      continue;
    }
    
    final content = file.readAsStringSync();
    if (content.trim().isEmpty) {
      print('Skipping empty file: ${file.uri.pathSegments.last}');
      continue;
    }
    final jsonMap = json.decode(content) as Map<String, dynamic>;
    
    // Add all missing keys with English fallback
    var hasMissing = false;
    for (final key in englishJson.keys) {
      if (!jsonMap.containsKey(key)) {
        jsonMap[key] = englishJson[key];
        print('Added $key to ${file.uri.pathSegments.last}');
        hasMissing = true;
      }
    }
    
    if (hasMissing) {
      
      // Write back preserving formatting
      final encoder = JsonEncoder.withIndent('  ');
      file.writeAsStringSync(
        '${encoder.convert(jsonMap)}\n',
        mode: FileMode.write,
      );
      
      print('Added ai-workspace-title to ${file.uri.pathSegments.last}');
    }
  }
}
