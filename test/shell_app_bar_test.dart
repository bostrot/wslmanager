/// The app bar's trailing controls (bug report, dark mode switch). fluent_ui
/// parks the actions widget in the bar's top end corner; with no caption
/// buttons to stretch the row — macOS, web — the switch used to sit hard
/// against the top edge and 8px from the window corner (ai-tasks#15).
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/nav/root_screen.dart';
import 'package:wsl2distromanager/theme.dart';

void main() {
  const surface = Size(900, 600);
  late AppTheme appTheme;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    appTheme = AppTheme();
  });

  /// A shell-shaped NavigationView: the real app bar height, the real
  /// actions widget, an open pane, the theme mode bound to [AppTheme] as
  /// main.dart binds it — but no window plugin, so the caption buttons
  /// (which query it at build time) stay out.
  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppTheme>.value(
        value: appTheme,
        child: Consumer<AppTheme>(
          builder: (context, theme, _) => FluentApp(
            themeMode: theme.mode,
            theme: FluentThemeData.light(),
            darkTheme: FluentThemeData.dark(),
            home: NavigationView(
              appBar: const NavigationAppBar(
                height: shellAppBarHeight,
                automaticallyImplyLeading: false,
                title: Text('WSL Manager'),
                actions: ShellAppBarActions(windowButtons: false),
              ),
              pane: NavigationPane(
                displayMode: PaneDisplayMode.open,
                items: [
                  PaneItem(
                    icon: const Icon(FluentIcons.home),
                    title: const Text('Home'),
                    body: const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final toggle = find.byType(ToggleSwitch);

  group('ShellAppBarActions without caption buttons', () {
    testWidgets('centres the dark mode switch in the app bar', (tester) async {
      await pump(tester);

      final rect = tester.getRect(toggle);
      // Vertically centred in the 50px bar, like the title next to it — not
      // flush with the top edge.
      expect(rect.center.dy, closeTo(shellAppBarHeight / 2, 1.0));
      expect(rect.top, greaterThanOrEqualTo(8.0));
      expect(rect.bottom, lessThanOrEqualTo(shellAppBarHeight - 8.0));
    });

    testWidgets('keeps a margin between the switch and the window edge',
        (tester) async {
      await pump(tester);

      final rect = tester.getRect(toggle);
      expect(surface.width - rect.right,
          closeTo(ShellAppBarActions.windowEdgeInset, 0.5));
      // The row is sized to the bar rather than to its tallest child.
      expect(tester.getSize(find.byType(ShellAppBarActions)).height,
          shellAppBarHeight);
    });

    testWidgets('bug report button sits before the switch, on the same line',
        (tester) async {
      await pump(tester);

      final bug = tester.getRect(find.byIcon(FluentIcons.bug));
      final rect = tester.getRect(toggle);
      expect(bug.right, lessThanOrEqualTo(rect.left));
      expect(bug.center.dy, closeTo(rect.center.dy, 2.0));
    });

    testWidgets('flips the theme and persists it', (tester) async {
      appTheme.mode = ThemeMode.light;
      await pump(tester);
      expect(tester.widget<ToggleSwitch>(toggle).checked, isFalse);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(appTheme.mode, ThemeMode.dark);
      expect(prefs.getString('themeMode'), 'dark');
      expect(tester.widget<ToggleSwitch>(toggle).checked, isTrue);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(appTheme.mode, ThemeMode.light);
      expect(prefs.getString('themeMode'), 'light');
      expect(tester.widget<ToggleSwitch>(toggle).checked, isFalse);
    });

    testWidgets('reads as on under a dark theme', (tester) async {
      appTheme.mode = ThemeMode.dark;
      await pump(tester);
      expect(tester.widget<ToggleSwitch>(toggle).checked, isTrue);
      // Same geometry in dark: the inset is not theme-dependent.
      expect(surface.width - tester.getRect(toggle).right,
          closeTo(ShellAppBarActions.windowEdgeInset, 0.5));
    });
  });
}
