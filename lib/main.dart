import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart' hide Page;
import 'package:flutter/foundation.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as flutter_acrylic;
import 'package:localization/localization.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:system_theme/system_theme.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/ai_workspace/config_service.dart';
import 'package:wsl2distromanager/api/ai_workspace/shared_settings.dart';
import 'package:wsl2distromanager/api/ai_workspace/service.dart';
import 'package:wsl2distromanager/api/app_window.dart';
import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/api/hosts_file_service.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_service.dart';
import 'package:wsl2distromanager/api/web/web_dashboard_service.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/windows_terminal_service.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/logging.dart';
import 'package:wsl2distromanager/nav/router.dart';

import 'theme.dart';

String appTitle = "WSL Manager v$currentVersion";

/// fluent_ui's NavigationPane only switches to full "open" mode (icons +
/// labels) at widths >= 1008px, so a fresh install starts above that
/// breakpoint.
const Size defaultWindowSize = Size(1180, 780);

/// Reapply the geometry saved by RootPageState, falling back to a centered
/// default window.
Future<void> restoreWindowBounds() async {
  final width = prefs.getDouble('WindowWidth');
  final height = prefs.getDouble('WindowHeight');
  final left = prefs.getDouble('WindowLeft');
  final top = prefs.getDouble('WindowTop');

  await appWindow.setSize(width != null && height != null
      ? Size(width, height)
      : defaultWindowSize);

  if (left != null && top != null) {
    await appWindow.setPosition(Offset(left, top));
    // A screen that is gone (undocked laptop, changed layout) would leave the
    // window off-screen.
    if (!await _isOnAVisibleScreen()) {
      await appWindow.center();
    }
  } else {
    await appWindow.center();
  }

  if (prefs.getBool('WindowMaximized') ?? false) {
    await appWindow.maximize();
  }
}

Future<bool> _isOnAVisibleScreen() async {
  try {
    final bounds = await appWindow.getBounds();
    final displays = await screenRetriever.getAllDisplays();
    return displays.any((display) {
      final origin = display.visiblePosition ?? Offset.zero;
      final size = display.visibleSize ?? display.size;
      final area = Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height);
      return area.overlaps(bounds);
    });
  } catch (_) {
    return true;
  }
}

/// Checks if the current environment is a desktop environment.
bool get isDesktop {
  if (kIsWeb) return false;
  return [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ].contains(defaultTargetPlatform);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final isWindows = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  final isLinux = !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
  final isMacOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  // if it's not on the web, windows or android, load the accent color
  if (!kIsWeb &&
      [
        TargetPlatform.windows,
        TargetPlatform.android,
      ].contains(defaultTargetPlatform)) {
    SystemTheme.accentColor.load();
  }

  // Init logging
  await initLogging();
  await initPrefs();

  if (isDesktop) {
    await flutter_acrylic.Window.initialize();
    if (isWindows) {
      await flutter_acrylic.Window.hideWindowControls();
    }
    await appWindow.waitUntilReadyToShow().then((_) async {
      if (isWindows) {
        await appWindow.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );
      } else if (isLinux) {
        await appWindow.setAsFrameless();
      } else if (isMacOS) {
        // One bar, like Windows: hide the native title bar (the traffic
        // lights stay, overlaying the app bar, which insets its leading for
        // them — see root_screen.dart).
        await appWindow.setTitleBarStyle(TitleBarStyle.hidden);
      }
      await appWindow.setMinimumSize(const Size(700, 500));
      await restoreWindowBounds();
      await appWindow.show();
      await appWindow.setPreventClose(true);
      await appWindow.setSkipTaskbar(false);
    });
  }

  // Create execution broker (local shell by default)
  final Shell shell = ProcessShell();
  final ExecutionBroker executionBroker = ExecutionBroker(shell: shell);

  // Init license manager
  await LicenseManager().init();

  // The "Sign in with Claude" provider is gone (Anthropic's terms forbid it
  // in third-party apps); scrub any OAuth tokens an older build stored.
  AiService.purgeRetiredClaudePrefs();

  // Restart the MCP server if it was left enabled — external clients need
  // it actually listening.
  final mcpService = WslMcpService();
  if (mcpService.enabled && LicenseManager().isPro) {
    await mcpService.start();
  }

  // Same for the web dashboard: a phone that scanned the QR code yesterday
  // should still get in today. A taken port is not fatal for the app;
  // Settings reports it when the user looks.
  final webDashboard = WebDashboardService();
  if (webDashboard.enabled && LicenseManager().isPro) {
    try {
      await webDashboard.start();
    } catch (_) {}
  }

  // Names for the running instances in the host's hosts file, for whoever
  // turned that on. The block is only rewritten when an address actually
  // changes, so a tick that finds nothing new never raises an elevation
  // prompt (bostrot/wsl2-distro-manager#214).
  HostsFileService.instance.startAutoSync();

  // The same for the Windows Terminal dropdown: a distro created while the
  // app is open is in the menu the next time Windows Terminal starts. The
  // fragment file is only rewritten when the rendered JSON changes, so a
  // tick that finds nothing new costs one `wsl -l -v`
  // (bostrot/wsl2-distro-manager#239).
  WindowsTerminalService.instance.startAutoSync();

  // Probe AI Workspace in the background so the screen has results by the
  // time it opens. Not awaited; the screen joins this same memoized run.
  // The workspace lives in a dedicated WSL distro, so hosts on another
  // backend (macOS) never probe it.
  final aiWorkspaceService = AiWorkspaceService(broker: executionBroker);
  // Only WSL auto-provisions its environment; a VM-backed workspace needs a
  // running guest the user brings, so it is initialised lazily when the
  // screen opens rather than probed at startup.
  final aiWorkspaceConfigService =
      AiWorkspaceConfigService(workspace: aiWorkspaceService);
  // Nothing is set up for a user who has not asked for it: the switch is
  // off until the first-start question is answered with a yes, which is
  // what the silent first-launch install cost us (bostrot/ai-tasks#98).
  if (AiService.featuresEnabled &&
      LicenseManager().isPro &&
      vmBackend().features.aiWorkspace &&
      !isAppleHost) {
    unawaited(aiWorkspaceService.ensureInitialized());
    // The tools describe their own settings, and what they describe changes
    // with every release they install, so the schemas are pulled here rather
    // than shipped with the app. Not awaited: the dialog joins this same run
    // if it opens first.
    //
    // Chained onto the memoized init rather than started beside it: a schema
    // pull runs a command *inside* the workspace, and starting it in parallel
    // would have two callers find the environment missing at once and
    // provision it twice. `onError` only skips the pull — the init's own
    // failure still surfaces through the call above.
    unawaited(aiWorkspaceService.ensureInitialized().then(
      (_) => aiWorkspaceConfigService.ensureSchemas(),
      onError: (_) {},
    ));
  }

  // Error logging
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    logError(details.exception, details.stack, details.library);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logError(error, stack, null);
    return true;
  };

  // Set version
  await PackageInfo.fromPlatform().then((PackageInfo packageInfo) {
    currentVersion = packageInfo.version;
  });

  // Init app
  runApp(WSLManager(
    executionBroker: executionBroker,
    aiWorkspaceService: aiWorkspaceService,
    aiWorkspaceConfigService: aiWorkspaceConfigService,
  ));
}

class WSLManager extends StatelessWidget {
  final ExecutionBroker? executionBroker;
  final AiWorkspaceService? aiWorkspaceService;
  final AiWorkspaceConfigService? aiWorkspaceConfigService;

  const WSLManager({
    Key? key,
    this.executionBroker,
    this.aiWorkspaceService,
    this.aiWorkspaceConfigService,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    LocalJsonLocalization.delegate.directories = ['lib/i18n'];
    final broker = executionBroker ?? ExecutionBroker(shell: ProcessShell());
    final workspaceService =
        aiWorkspaceService ?? AiWorkspaceService(broker: broker);
    final workspaceConfigService = aiWorkspaceConfigService ??
        AiWorkspaceConfigService(workspace: workspaceService);
    // App-level, not page-level: an install outlives the AI Workspace page,
    // and the tool it produces is configured whichever page is open then.
    AiWorkspaceSharedSettingsService(
      workspace: workspaceService,
      config: workspaceConfigService,
    ).attach();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AppTheme(),
        ),
        Provider<ExecutionBroker>.value(
          value: broker,
        ),
        Provider<AiWorkspaceService>(
          create: (_) => workspaceService,
          // Releases the held WSL session so the distro can shut down.
          dispose: (_, service) => service.dispose(),
        ),
        Provider<AiWorkspaceConfigService>.value(
          value: workspaceConfigService,
        ),
      ],
      builder: (context, _) {
        final appTheme = context.watch<AppTheme>();
        var selectedLang = prefs.getString('language');
        return FluentApp.router(
          title: appTitle,
          themeMode: appTheme.mode,
          debugShowCheckedModeBanner: false,
          color: appTheme.color,
          darkTheme: buildAppTheme(
            brightness: Brightness.dark,
            accentColor: appTheme.color,
            tenFootScreen: is10footScreen(context),
          ),
          theme: buildAppTheme(
            brightness: Brightness.light,
            accentColor: appTheme.color,
            tenFootScreen: is10footScreen(context),
          ),
          locale: appTheme.locale,
          localeResolutionCallback: (locale, supportedLocales) {
            // A locale set on AppTheme is the settings picker previewing a
            // language the user has not saved yet, so it outranks the stored
            // preference — which is only ever the *saved* language (ST-02).
            final preview = appTheme.locale;
            if (preview != null) {
              language = preview.toLanguageTag();
              return preview;
            }
            // Language was set manually
            if (selectedLang != null) {
              language = selectedLang;
              // Stored before the picker used full locale tags.
              if (selectedLang == "zh") {
                return const Locale('zh', 'CN');
              }
              final parts = selectedLang.split('_');
              return parts.length == 2
                  ? Locale(parts[0], parts[1])
                  : Locale(parts[0]);
            }

            if (locale == null) {
              language = 'en';
              return const Locale('en', '');
            }
            language = locale.toLanguageTag();
            if (supportedLocales.contains(locale)) {
              return locale;
            }

            // Custom matching for chinese (simplified and traditional)
            if (language.toLowerCase().contains("hans")) {
              return const Locale('zh', 'CN');
            } else if (language.toLowerCase().contains("hant")) {
              return const Locale('zh', 'TW');
            } else if (locale.languageCode == "zh") {
              return const Locale('zh', 'CN');
            }

            // No exact match, try language only
            final Locale lang = Locale(locale.languageCode, '');
            if (supportedLocales.contains(lang)) {
              return lang;
            }

            // default language
            return const Locale('en', '');
          },
          localizationsDelegates: [
            LocalJsonLocalization.delegate,
          ],
          supportedLocales: supportedLocalesList,
          builder: (context, child) {
            return Directionality(
              textDirection: appTheme.textDirection,
              child: NavigationPaneTheme(
                data: NavigationPaneThemeData(
                  backgroundColor: appTheme.windowEffect !=
                          flutter_acrylic.WindowEffect.disabled
                      ? Colors.transparent
                      : null,
                ),
                child: child!,
              ),
            );
          },
          routeInformationParser: router.routeInformationParser,
          routerDelegate: router.routerDelegate,
          routeInformationProvider: router.routeInformationProvider,
        );
      },
    );
  }
}
