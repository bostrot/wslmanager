/// Tests for the grouped layout of the two create screens
/// (bostrot/ai-tasks#50): both used to be one flat column of every control
/// they own, so the tests here pin the card grouping and the parts of it that
/// depend on what the form is currently showing.
///
/// There is no localization delegate here, so `.i18n()` returns the key it was
/// handed — which is what the assertions match on.
// ignore_for_file: dangling_library_doc_comments

import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/form_card.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/create_dialog.dart';
import 'package:wsl2distromanager/screens/create_vm_screen.dart';

import 'fake_vmctl_shell.dart';
import 'mocks.dart';

void main() {
  late Directory dataDir;

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {};
  });

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('create-form-layout-test');
    SharedPreferences.setMockInitialValues({'DataPath': dataDir.path});
    prefs = await SharedPreferences.getInstance();
    final shell = FakeVmctlShell();
    shell.responses['list'] = '{"vms":[]}';
    appleVmApiBuilder = () => AppleVmApi(
          shell: shell,
          helperPathOverride: '/fake/vmctl',
          storeDirOverride: '${dataDir.path}/vms',
          earlyExitProbeDelay: Duration.zero,
        );
  });

  tearDown(() {
    appleVmApiBuilder = AppleVmApi.new;
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  Future<void> pumpCard(WidgetTester tester, List<Widget?> children) async {
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: SizedBox(
          width: 400,
          child: FormCard(
            icon: FluentIcons.settings,
            title: 'Basics',
            children: children,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  group('FormCard', () {
    testWidgets('draws its heading over its fields, in order', (tester) async {
      await pumpCard(tester, [const Text('first'), const Text('second')]);

      expect(find.text('Basics'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Basics')).dy,
          lessThan(tester.getTopLeft(find.text('first')).dy));
      expect(tester.getTopLeft(find.text('first')).dy,
          lessThan(tester.getTopLeft(find.text('second')).dy));
    });

    testWidgets('a null field is dropped instead of spacing a hidden control',
        (tester) async {
      await pumpCard(tester, [const Text('first'), const Text('second')]);
      final withoutHidden = tester.getSize(find.byType(FormCard));

      await pumpCard(
          tester, [const Text('first'), null, const Text('second')]);

      // The old form used an empty `Container()` for a control that is off
      // for the current source type and kept the gap around it.
      expect(tester.getSize(find.byType(FormCard)), withoutHidden);
    });
  });

  group('FormPageHeader', () {
    Future<void> pumpHeader(WidgetTester tester, String? description) async {
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: FormPageHeader(
            icon: FluentIcons.add_to,
            title: 'Create a new instance',
            description: description,
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('puts the description under the title', (tester) async {
      await pumpHeader(tester, 'What this page does.');

      expect(tester.getTopLeft(find.text('Create a new instance')).dy,
          lessThan(tester.getTopLeft(find.text('What this page does.')).dy));
    });

    testWidgets('renders the title alone when there is no description',
        (tester) async {
      await pumpHeader(tester, null);

      expect(find.text('Create a new instance'), findsOneWidget);
      expect(find.byType(Text), findsOneWidget);
    });
  });

  group('the VM create page', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const FluentApp(home: ScaffoldPage(content: CreateVmPage())));
      await tester.pump();
    }

    testWidgets('groups its fields into basics, boot source and resources',
        (tester) async {
      await pump(tester);

      expect(find.byType(FormCard), findsNWidgets(3));
      expect(find.text('createbasics-text'), findsOneWidget);
      expect(find.text('vmbootsource-text'), findsOneWidget);
      expect(find.text('createresources-text'), findsOneWidget);

      // The name is in the first card, the boot choice in the second.
      expect(
          find.descendant(
              of: find.byType(FormCard).first,
              matching: find.byKey(const ValueKey('test-vm-name'))),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(FormCard).at(1),
              matching: find.byKey(const ValueKey('test-vm-boot-cloud-image'))),
          findsOneWidget);
    });

    testWidgets('lays out without overflowing a narrow window', (tester) async {
      // The cards add 16px of padding each side of a column that was already
      // as wide as the page allows, and the three resource fields sit in one
      // Row — the narrow case is where that would break.
      tester.view.physicalSize = const Size(560, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const FluentApp(home: ScaffoldPage(content: CreateVmPage())));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('a macOS guest keeps the grouping and swaps the boot card',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('test-vm-guest-os')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('macOS').last);
      await tester.pumpAndSettle();

      expect(find.byType(FormCard), findsNWidgets(3));
      expect(
          find.descendant(
              of: find.byType(FormCard).at(1),
              matching: find.byKey(const ValueKey('test-vm-restore-image'))),
          findsOneWidget);
      // A macOS guest installs from a restore image: neither Linux boot
      // choice belongs on the page any more.
      expect(find.byKey(const ValueKey('test-vm-boot-cloud-image')),
          findsNothing);
    });
  });

  group('the WSL create form', () {
    Future<ValueNotifier<CreateSourceType>> pumpForm(
        WidgetTester tester) async {
      final sourceType = ValueNotifier(CreateSourceType.local);
      addTearDown(sourceType.dispose);
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: SingleChildScrollView(
            child: CreateWidget(
              nameController: TextEditingController(),
              api: WSLApi(shell: MockShell()),
              autoSuggestBox: TextEditingController(),
              locationController: TextEditingController(),
              userController: TextEditingController(),
              sourceType: sourceType,
            ),
          ),
        ),
      ));
      await tester.pump();
      // The form's own list of existing instances resolves a frame later.
      await tester.pump(const Duration(seconds: 1));
      return sourceType;
    }

    testWidgets('splits its controls into a basics card and an options card',
        (tester) async {
      await pumpForm(tester);

      expect(find.byType(FormCard), findsNWidgets(2));
      expect(find.text('createbasics-text'), findsOneWidget);
      expect(find.text('createoptions-text'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(FormCard).first,
              matching: find.byKey(const ValueKey('test-create-name-input'))),
          findsOneWidget);
    });

    testWidgets('the save location field opens inside the options card',
        (tester) async {
      await pumpForm(tester);
      expect(find.byKey(const ValueKey('test-create-location-input')),
          findsNothing);

      await tester.tap(find.byType(ToggleSwitch).first);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(
          find.descendant(
              of: find.byType(FormCard).last,
              matching:
                  find.byKey(const ValueKey('test-create-location-input'))),
          findsOneWidget);
    });
  });
}
