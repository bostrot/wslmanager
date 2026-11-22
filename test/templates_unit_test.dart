import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plausible_analytics/plausible_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/templates.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

class MockWSLApi implements WSLApi {
  String? lastImportedDistroName;
  bool throwOnImport = false;

  @override
  String get templateExtension => 'ext4';

  @override
  Future<String> export(String distroName, String path,
      {String? format}) async {
    // Create dummy file
    File(path).createSync(recursive: true);
    return '';
  }

  @override
  Future<String> import(
      String distroName, String installLocation, String fileName,
      {bool isVhd = false}) async {
    if (throwOnImport) {
      throw Exception('Import failed');
    }
    lastImportedDistroName = distroName;
    return 'Imported';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockPlausible implements Plausible {
  @override
  Future<int> event(
      {String? name,
      String? page,
      Map<String, String>? props,
      String? referrer,
      PlausibleRevenue? revenue,
      bool interactive = true}) async {
    return 200;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Templates templates;
  late MockWSLApi mockWSLApi;
  late Directory tempDir;
  late List<String> statusMessages;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();

    // Mock Plausible
    plausible = MockPlausible();

    // Mock Notify
    Notify();
    statusMessages = [];
    Notify.message = (
      String msg, {
      Duration? duration,
      dynamic severity = "",
      bool loading = false,
      bool useWidget = false,
      bool leadingIcon = true,
      dynamic widget,
    }) {
      statusMessages.add(msg);
    };

    mockWSLApi = MockWSLApi();
    templates = Templates(wslApi: mockWSLApi);

    tempDir = await Directory.systemTemp.createTemp('templates_test');

    // Mock getDistroPath
    prefs.setString('DistroPath', tempDir.path);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('saveTemplate saves template', () async {
    await templates.saveTemplate('test');

    // Check if template file created (mock export creates it)
    // Path: tempDir/templates/test.ext4
    final templatePath = '${tempDir.path}/templates/test.ext4';
    expect(File(templatePath).existsSync(), true);

    // Check prefs
    expect(prefs.getStringList('templates'), ['test']);
  });

  test('saveTemplate handles duplicate names', () async {
    await templates.saveTemplate('test');
    await templates.saveTemplate('test');

    expect(prefs.getStringList('templates'), ['test', 'test-2']);
    expect(File('${tempDir.path}/templates/test-2.ext4').existsSync(), true);
  });

  test('useTemplate calls import', () async {
    await templates.useTemplate('test', 'newDistro');
    expect(mockWSLApi.lastImportedDistroName, 'newDistro');
  });

  test('useTemplate falls back to template name when input is empty', () async {
    await templates.useTemplate('test', '   ');
    expect(mockWSLApi.lastImportedDistroName, 'test');
  });

  test('useTemplate surfaces import exceptions', () async {
    mockWSLApi.throwOnImport = true;

    await templates.useTemplate('test', 'newDistro');

    expect(statusMessages.any((m) => m.contains('Import failed')), true);
  });

  test('deleteTemplate deletes file and updates prefs', () async {
    await templates.saveTemplate('test');
    expect(prefs.getStringList('templates'), ['test']);
    expect(File('${tempDir.path}/templates/test.ext4').existsSync(), true);

    await templates.deleteTemplate('test');
    expect(prefs.getStringList('templates'), []);
    expect(File('${tempDir.path}/templates/test.ext4').existsSync(), false);
  });

  test('getTemplates returns list', () async {
    expect(templates.getTemplates(), []);
    await templates.saveTemplate('test');
    expect(templates.getTemplates(), ['test']);
  });

  test('getTemplateSize returns size', () async {
    await templates.saveTemplate('test');
    // Mock file size is 0 — formatted per-unit now, not pinned to GB (ST-42).
    expect(templates.getTemplateSize('test'), '0 B');
  });
}
