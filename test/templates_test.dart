/// Tests for the wsl.dart file.
import 'dart:io';
import 'dart:ui';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/templates.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/create_dialog.dart';

import 'mocks.dart';

bool useRealIntegrations = Platform.environment['INTEGRATION_TESTS'] == 'true';

void main() {
  WSLApi api = useRealIntegrations ? WSLApi() : WSLApi(shell: MockShell());
  Templates templates = Templates(wslApi: api);

  void statusMsg(
    String msg, {
    Duration? duration,
    dynamic severity = "",
    bool loading = false,
    bool useWidget = false,
    bool leadingIcon = true,
    dynamic widget,
  }) {}

  createDistro(name, loc, image, user) async {
    await createInstance(
      TextEditingController(text: name),
      TextEditingController(text: loc),
      api,
      TextEditingController(text: image),
      TextEditingController(text: user),
      dockerImage: useRealIntegrations ? null : MockDockerImage(),
    );
  }

  Future<bool> isInstance(String name) async {
    bool found = false;
    // Get list
    var list = await api.list(false);
    found = false;

    for (var item in list.all) {
      if (item == name) {
        found = true;
      }
    }
    return found;
  }

  // Stuff before tests
  setUpAll(() async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await initPrefs();

    Notify();
    Notify.message = statusMsg;

    await api.remove('test');

    await createDistro(
      'test',
      '',
      'Debian',
      '',
    );

    expect(await isInstance('test'), true);

    var res = await api.execCmdAsRoot('test', 'touch /testfile');

    expect(res, "");
  });

  tearDownAll(() async {
    // Delete the instance. Awaited: unawaited futures here failed the suite
    // *after* it had completed whenever a template file was already gone.
    await api.remove('test');
    await api.remove('test2');
    await templates.deleteTemplate('test');
    await templates.deleteTemplate('test-2');
    await templates.deleteTemplate('test-3');
  });

  test('Create template', () async {
    await templates.saveTemplate('test');
    expect(File(templates.getTemplateFilePath('test')).existsSync(), true);
  });

  test('Create template of already existent', () async {
    await templates.saveTemplate('test');
    expect(File(templates.getTemplateFilePath('test')).existsSync(), true);
    await templates.saveTemplate('test');
    expect(File(templates.getTemplateFilePath('test-2')).existsSync(), true);
    await templates.saveTemplate('test');
    expect(File(templates.getTemplateFilePath('test-3')).existsSync(), true);
  });

  test('Use template', () async {
    await templates.useTemplate('test', 'test2');
    expect(await isInstance('test2'), true);

    // Check if testfile exists
    var res = await api.execCmdAsRoot('test2', 'ls /testfile');
    expect(res, "/testfile\n");
  });

  test('Delete template', () async {
    await templates.deleteTemplate('test');
    expect(File(templates.getTemplateFilePath('test')).existsSync(), false);
  });

  test('Rename template and set description', () async {
    await templates.saveTemplate('test_rename');
    await templates.setTemplateDescription(
        'test_rename', 'Initial description');

    expect(
        templates.getTemplateDescription('test_rename'), 'Initial description');

    await templates.renameTemplate('test_rename', 'test_renamed');

    expect(
        File(templates.getTemplateFilePath('test_renamed')).existsSync(), true);
    expect(
        File(templates.getTemplateFilePath('test_rename')).existsSync(), false);
    expect(templates.getTemplateDescription('test_renamed'),
        'Initial description');
    expect(templates.getTemplateDescription('test_rename'), '');

    await templates.deleteTemplate('test_renamed');
  });

  test('Templates on disk are recovered when the prefs list is lost', () async {
    await templates.saveTemplate('recoverable');
    expect(templates.getTemplates(), contains('recoverable'));

    // Simulate the preferences file being reset while the .ext4 survives.
    await prefs.remove('templates');

    expect(templates.getTemplates(), contains('recoverable'));
    // The recovered list is written back so it survives the next start too.
    expect(prefs.getStringList('templates'), contains('recoverable'));

    await templates.deleteTemplate('recoverable');
  });

  test('Templates whose file is gone are dropped from the list', () async {
    await templates.saveTemplate('vanishing');
    File(templates.getTemplateFilePath('vanishing')).deleteSync();

    expect(templates.getTemplates(), isNot(contains('vanishing')));
  });
}
