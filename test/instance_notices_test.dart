/// The notice after stopping an instance from its row.
///
/// It used to be the raw WSL name glued in front of a translated fragment:
/// "Ubuntu-22.04 Stopped." right after "Stopping Work...", for an instance the
/// user had renamed to Work, and no way for a translation to put the name
/// where its grammar wants it. The real English strings are loaded here so
/// the assertion reads the sentence a user sees.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localization/localization.dart';
import 'package:plausible_analytics/plausible_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/list_item.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'mocks.dart';

class _MockPlausible implements Plausible {
  @override
  Future<int> event(
          {String? name,
          String? page,
          Map<String, String>? props,
          String? referrer,
          PlausibleRevenue? revenue,
          bool interactive = true}) async =>
      200;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late List<String> messages;

  setUpAll(() async {
    MapLocalization.delegate.translations[const Locale('en')] =
        json.decode(File('lib/i18n/en.json').readAsStringSync())
            as Map<String, dynamic>;
    await MapLocalization.delegate.load(const Locale('en'));
  });

  tearDownAll(() => MapLocalization.delegate.load(const Locale('xx')));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    plausible = _MockPlausible();
    messages = [];
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        dynamic widget,
        leadingIcon = true}) {
      messages.add(msg);
    };
    // Built outside the pump: the first WSLApi ever constructed starts the
    // distro-catalogue fetch, and a Dio timer left pending in a widget
    // test's fake zone fails it.
    final backend = WSLApi(shell: MockShell());
    vmBackendBuilder = () => backend;
  });

  tearDown(() {
    vmBackendBuilder = defaultVmBackendBuilder;
  });

  Future<void> stop(WidgetTester tester, String item) async {
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: ListItem(item: item, running: [item], trailing: '2.1 GB'),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('test-listitem-stop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a renamed instance is stopped under the name the user gave it',
      (tester) async {
    await prefs.setString('DistroName_Ubuntu-22.04', 'Work');

    await stop(tester, 'Ubuntu-22.04');

    expect(messages, ['Stopping Work...', 'Work stopped.']);
  });

  testWidgets('an instance without a label keeps its WSL name',
      (tester) async {
    await stop(tester, 'Ubuntu');

    expect(messages, ['Stopping Ubuntu...', 'Ubuntu stopped.']);
  });
}
