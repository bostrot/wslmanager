import 'package:fluent_ui/fluent_ui.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/components/ai_chat_button.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/list.dart';
import 'package:wsl2distromanager/components/recommendations_panel.dart';
import 'package:wsl2distromanager/components/sale_banner.dart';

import 'dart:io';

import 'package:wsl2distromanager/theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// Both are app-lifetime globals; merged once so a home rebuild does not
  /// re-subscribe the button to them every time.
  late final Listenable _chatButtonListenable =
      Listenable.merge([GlobalVariable.aiPanel, AiService.featuresChanged]);

  final VmBackend api = vmBackend();
  List<String> distroNames = [];

  /// One key for the life of the page. Re-created inline on every build, it
  /// tore down and rebuilt the whole list subtree — collapsing every expanded
  /// row and restarting the 5s poll — each time the AI panel toggled
  /// (audit LN-03).
  final GlobalKey<NavigatorState> _infoboxKey = GlobalKey<NavigatorState>();

  void enableAnalytics() async {
    String platform = Platform.operatingSystemVersion;
    String exec = 'unknown';
    try {
      exec = Platform.resolvedExecutable.toString();
      if (exec.contains("9891PhantomDevs.WSL2Manager")) {
        exec = "store";
      } else {
        exec = "git";
      }
    } catch (_) {
      exec = 'git';
    }
    var tmpPlatform = platform;
    int? build;
    try {
      if (int.parse(platform.split('Build ')[1].split(')')[0]) >= 22000) {
        tmpPlatform = platform
            .replaceAll('Windows 10', 'Windows 11')
            .replaceAll('10.0', '11.0');
      }
      build = int.tryParse(platform.split('Build ')[1].split(')')[0]);
      if (build != null && build < 21354) {
        explorerPath = "\\\\wsl\$";
      }
    } catch (e) {
      // Empty path
    } finally {
      platform = tmpPlatform;
    }

    plausible.event(name: 'Devices', props: {
      'app_source': exec,
      'app_version': currentVersion,
      'app_platform': platform,
      'app_locale': language,
      'app_theme': AppTheme.themeMode == ThemeMode.dark ? 'dark' : 'light',
    });
  }

  Future<List<String>> _fetchDistroNames() async {
    try {
      final instances = await api.list(prefs.getBool('showDocker') ?? false);
      final list = instances.all;
      if (list.isNotEmpty && list[0] != 'wslNotInstalled') {
        return list;
      }
    } catch (_) {}
    return [];
  }

  @override
  void initState() {
    super.initState();
    enableAnalytics();
  }

  @override
  Widget build(BuildContext context) {
    bool isPro = false;
    try {
      isPro = GlobalVariable.testProEnabled || LicenseManager().isPro;
    } catch (_) {
      isPro = false;
    }

    return Stack(
      children: [
        // Just the main content now. The AI chat is docked by the shell
        // (nav/root_screen.dart) so the status/notification bar sits beside
        // it instead of sliding underneath it and colliding with the panel's
        // own input and this button.
        SizedBox.expand(
          child: Column(
            key: (GlobalVariable.infobox = _infoboxKey),
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (!isPro) const SaleBanner(),
              FutureBuilder<List<String>>(
                future: _fetchDistroNames(),
                builder: (context, snapshot) {
                  final names = snapshot.data ?? [];
                  if (names.isNotEmpty && names != distroNames) {
                    distroNames = names;
                  }
                  return RecommendationsPanel(
                    key: const ValueKey('test-recommendations-panel'),
                    distroNames: distroNames,
                  );
                },
              ),
              DistroList(api: api),
            ],
          ),
        ),
        if (isPro)
          Positioned(
            // The home body already excludes the dock's width, so the button
            // sits at its own right edge — just left of the divider.
            right: 16,
            bottom: 16,
            // The shell dock listens to the same notifiers and rebuilds; the
            // button only needs them for the open/closed semantics and to
            // leave the screen the moment AI is switched off in Settings.
            child: ListenableBuilder(
              listenable: _chatButtonListenable,
              builder: (context, _) {
                if (!AiService.featuresEnabled) return const SizedBox.shrink();
                final open = GlobalVariable.aiPanel.value;
                return AiChatButton(
                  key: const ValueKey('test-ai-chat-toggle'),
                  open: open,
                  onPressed: () => GlobalVariable.aiPanel.value = !open,
                );
              },
            ),
          ),
      ],
    );
  }
}
