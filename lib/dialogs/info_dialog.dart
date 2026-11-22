import 'dart:io';

import 'package:flutter/services.dart';
import 'package:localization/localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/oss_licenses.dart';
import 'base_dialog.dart';

const String _repoUrl = 'https://github.com/bostrot/wslmanager';
const String _releasesUrl = '$_repoUrl/releases';
const String _wikiUrl = '$_repoUrl/wiki';
const String _licenseUrl = '$_repoUrl/blob/main/LICENSE';
const String _donateUrl = 'https://paypal.me/bostrot';

/// The app's own icon, bundled so the dialog does not depend on the platform
/// launcher icon (which Flutter cannot read back).
const String _logoAsset = 'assets/logo_wsl_manager.png';

/// About dialog
/// @param prefs: SharedPreferences
/// @param currentVersion: String
///
/// [hostContext] lets a caller on another route (or a test) open the dialog
/// without the home screen being mounted; the default is the root key.
void infoDialog(SharedPreferences prefs, String currentVersion,
    {BuildContext? hostContext}) {
  plausible.event(page: 'info');

  // Get root context by Key
  final context = hostContext ?? GlobalVariable.root.currentContext!;

  showDialog(
    context: context,
    builder: (context) => AppAboutDialog(prefs: prefs, version: currentVersion),
  );
}

/// The "About this app" dialog: identity up top, one tile per destination,
/// the privacy status where it can be read without opening anything.
///
/// The previous version was a centred stack of six blue hyperlinks under a
/// bold title — every link the same weight, no icon, no hint of where each
/// one led, and "License" pointing at the releases page (ai-tasks#25).
class AppAboutDialog extends StatefulWidget {
  const AppAboutDialog({super.key, required this.prefs, required this.version});

  final SharedPreferences prefs;
  final String version;

  @override
  State<AppAboutDialog> createState() => _AppAboutDialogState();
}

class _AppAboutDialogState extends State<AppAboutDialog> {
  /// What "Copy version info" puts on the clipboard: enough for a bug report.
  String get versionInfo =>
      'WSL Manager ${widget.version} · ${_platformLabel()} '
      '${Platform.operatingSystemVersion}';

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 560.0),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(context),
            const SizedBox(height: 20),
            _links(context),
            const SizedBox(height: 10),
            _privacyTile(context),
            const SizedBox(height: 14),
            _footer(context),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('test-about-close'),
          onPressed: () => Navigator.pop(context),
          child: Text('close-text'.i18n()),
        ),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final plan = LicenseManager().getPlanText().i18n();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.asset(
            _logoAsset,
            width: 64,
            height: 64,
            filterQuality: FilterQuality.medium,
            // A missing asset must never take the dialog down with it.
            errorBuilder: (context, _, __) => Container(
              width: 64,
              height: 64,
              color: FluentTheme.of(context).accentColor,
              alignment: Alignment.center,
              child:
                  const Icon(FluentIcons.info, size: 30, color: Colors.white),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'WSL Manager',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _Chip(
                    label: 'v${widget.version}',
                    key: const ValueKey('test-about-version'),
                  ),
                  _Chip(label: _platformLabel()),
                  _Chip(
                    label: plan,
                    accent: true,
                    key: const ValueKey('test-about-plan'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'about-tagline'.i18n(),
                style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: secondaryTextColor(context)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _links(BuildContext context) {
    final tiles = <Widget>[
      AboutTile(
        icon: FluentIcons.code,
        title: 'visitgithub-text'.i18n(),
        description: 'about-github-desc'.i18n(),
        external: true,
        onPressed: () => _open('git_clicked', _repoUrl),
      ),
      AboutTile(
        icon: FluentIcons.history,
        title: 'changelog-text'.i18n(),
        description: 'about-changelog-desc'.i18n(),
        external: true,
        onPressed: () => _open('changelog_clicked', _releasesUrl),
      ),
      AboutTile(
        icon: FluentIcons.help,
        title: 'documentation-text'.i18n(),
        description: 'about-documentation-desc'.i18n(),
        external: true,
        onPressed: () => _open('docs_clicked', _wikiUrl),
      ),
      AboutTile(
        icon: FluentIcons.heart,
        title: 'donate-text'.i18n(),
        description: 'about-donate-desc'.i18n(),
        external: true,
        onPressed: () => _open('donate_clicked', _donateUrl),
      ),
      AboutTile(
        icon: FluentIcons.library,
        title: 'dependencies-text'.i18n(),
        description: 'about-dependencies-desc'.i18n(),
        onPressed: () {
          plausible.event(name: 'libraries_clicked');
          showDependenciesDialog(context);
        },
      ),
      AboutTile(
        icon: FluentIcons.certificate,
        title: 'license-text'.i18n(),
        description: 'about-license-desc'.i18n(),
        external: true,
        onPressed: () => _open('license_clicked', _licenseUrl),
      ),
    ];

    // Two columns while there is room, one when the dialog is squeezed.
    return LayoutBuilder(builder: (context, constraints) {
      const gap = 10.0;
      final twoColumns = constraints.maxWidth >= 420;
      final width =
          twoColumns ? (constraints.maxWidth - gap) / 2 : constraints.maxWidth;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final tile in tiles) SizedBox(width: width, child: tile),
        ],
      );
    });
  }

  Widget _privacyTile(BuildContext context) {
    final privacyMode = widget.prefs.getBool('privacyMode') ?? false;
    return AboutTile(
      key: const ValueKey('test-about-privacy'),
      icon: FluentIcons.shield,
      title: 'privacy-text'.i18n(),
      description: privacyMode
          ? 'notsharingdata-text'.i18n()
          : 'sharingdata-text'.i18n(),
      trailing: FluentIcons.chevron_right,
      onPressed: () => showUsageDataDialog(
        widget.prefs,
        hostContext: context,
        // The description is the current state; redraw it once the user has
        // had a say.
        onChanged: () {
          if (mounted) setState(() {});
        },
      ),
    );
  }

  Widget _footer(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '© 2021–${DateTime.now().year} Eric Trenkel',
            style: TextStyle(fontSize: 12, color: secondaryTextColor(context)),
          ),
        ),
        HyperlinkButton(
          key: const ValueKey('test-about-copy'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: versionInfo));
            Notify.message('copied-text'.i18n());
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(FluentIcons.copy, size: 12),
              const SizedBox(width: 6),
              Text('copyversioninfo-text'.i18n()),
            ],
          ),
        ),
      ],
    );
  }

  void _open(String event, String url) {
    plausible.event(name: event);
    launchUrl(Uri.parse(url));
  }
}

String _platformLabel() {
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isWindows) return 'Windows';
  if (Platform.isLinux) return 'Linux';
  return Platform.operatingSystem;
}

/// Small rounded label: version, host platform, licence plan.
class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent
            ? theme.accentColor.withValues(alpha: 0.14)
            : subtleFillColor(context),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: accent
              ? theme.accentColor.defaultBrushFor(theme.brightness)
              : null,
        ),
      ),
    );
  }
}

/// One destination: icon, name, a line saying where it leads.
///
/// Public so tests can count the tiles apart from the other HoverButtons in
/// the dialog (every fluent button is one).
///
/// HoverButton rather than GestureDetector so the tile can be focused and
/// activated from the keyboard, the same rule the community cards follow.
class AboutTile extends StatelessWidget {
  const AboutTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onPressed,
    this.external = false,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onPressed;

  /// Whether the tile leaves the app for a browser.
  final bool external;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor;
    final trailingIcon =
        trailing ?? (external ? FluentIcons.open_in_new_window : null);

    return HoverButton(
      onPressed: onPressed,
      builder: (context, states) => FocusBorder(
        focused: states.isFocused,
        child: Container(
          padding: const EdgeInsets.all(12),
          // Two-line descriptions set the row height; a one-liner beside
          // them would otherwise leave a ragged grid.
          constraints: const BoxConstraints(minHeight: 76),
          decoration: BoxDecoration(
            color: states.isHovered || states.isPressed
                ? subtleFillColor(context)
                : cardFillColor(context),
            border: Border.all(color: surfaceBorderColor(context)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Icon(icon,
                    size: 17, color: accent.defaultBrushFor(theme.brightness)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: secondaryTextColor(context)),
                    ),
                  ],
                ),
              ),
              if (trailingIcon != null) ...[
                const SizedBox(width: 8),
                Icon(trailingIcon,
                    size: 11, color: secondaryTextColor(context)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The share/do-not-share usage data dialog.
///
/// [onChanged] fires after either choice is stored, so a caller showing the
/// current status can redraw it.
void showUsageDataDialog(SharedPreferences prefs,
    {BuildContext? hostContext, VoidCallback? onChanged}) {
  bool privacyMode = prefs.getBool('privacyMode') ?? false;
  String privacyStatus =
      privacyMode ? 'notsharingdata-text'.i18n() : 'sharingdata-text'.i18n();
  dialog(
      hostContext: hostContext,
      item: 'allow-text'.i18n(),
      title: 'usagedata-text'.i18n(),
      body: 'usagedatawarning-text'.i18n([privacyStatus]),
      submitText: 'donotshare-text'.i18n(),
      submitInput: false,
      submitStyle: const ButtonStyle(),
      cancelText: 'share-text'.i18n(),
      onCancel: () {
        plausible.event(name: "privacy_off");
        prefs.setBool('privacyMode', false);
        plausible.enabled = true;
        onChanged?.call();
      },
      onSubmit: (inputText) {
        plausible.event(name: "privacy_on");
        prefs.setBool('privacyMode', true);
        plausible.enabled = false;
        Notify.message('privacymodeenabled-text'.i18n());
        onChanged?.call();
      });
}

/// Hyperlink that opens [showUsageDataDialog]; still used by the first-start
/// dialog's action row.
ClickableText shareUsageData(SharedPreferences prefs) {
  return ClickableText(
      clickEvent: "analytics_clicked",
      onPressed: () => showUsageDataDialog(prefs),
      text: 'privacy-text'.i18n());
}

/// Every bundled package with its version; a tap shows its licence text.
///
/// The list used to be squeezed into the generic dialog's 120-pixel body,
/// which showed four of a hundred entries at a time.
void showDependenciesDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => ContentDialog(
      constraints: const BoxConstraints(maxWidth: 520.0, maxHeight: 560.0),
      title: Text('dependencies-text'.i18n()),
      content: SizedBox(
        height: 380,
        child: DependencyList(hostContext: context),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text('close-text'.i18n()),
        ),
      ],
    ),
  );
}

class DependencyList extends StatelessWidget {
  const DependencyList({super.key, this.hostContext});

  /// Where the licence-text dialog opens from; the About dialog passes its
  /// own context so the home screen need not be mounted.
  final BuildContext? hostContext;

  @override
  Widget build(BuildContext context) {
    final packages = List<Package>.from(ossLicenses)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return ListView.separated(
      itemCount: packages.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final package = packages[index];
        return HoverButton(
          onPressed: () {
            plausible.event(name: "license_clicked");
            dialog(
              hostContext: hostContext ?? context,
              item: package.name,
              title: '${package.name} ${package.version}',
              body: package.license ?? 'No License',
              submitInput: false,
            );
          },
          builder: (context, states) => FocusBorder(
            focused: states.isFocused,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: states.isHovered
                    ? subtleFillColor(context)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(package.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 12),
                  Text(package.version,
                      style: TextStyle(
                          fontSize: 12, color: secondaryTextColor(context))),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class ClickableDependency extends StatelessWidget {
  const ClickableDependency({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          HyperlinkButton(
              onPressed: () =>
                  launchUrl(Uri.parse("https://pub.dev/packages/$name")),
              child: Text(name)),
          HyperlinkButton(
              onPressed: () => launchUrl(
                  Uri.parse("https://pub.dev/packages/$name/license")),
              child: const Text("(LICENSE)")),
        ],
      ),
    );
  }
}

class ClickableUrl extends StatelessWidget {
  const ClickableUrl(
      {super.key,
      required this.clickEvent,
      required this.url,
      required this.text});

  final String clickEvent;
  final String url;
  final String text;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: HyperlinkButton(
          onPressed: () async {
            plausible.event(name: clickEvent);
            launchUrl(Uri.parse(url));
          },
          child: Text(text)),
    );
  }
}

class ClickableText extends StatelessWidget {
  const ClickableText(
      {super.key,
      required this.clickEvent,
      required this.onPressed,
      required this.text});

  final String clickEvent;
  final Function() onPressed;
  final String text;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: HyperlinkButton(onPressed: onPressed, child: Text(text)),
    );
  }
}
