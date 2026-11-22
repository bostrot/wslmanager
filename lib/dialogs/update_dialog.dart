import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wsl2distromanager/api/updater.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// How the app goes away once the installer has been started.
///
/// Both install paths need the running copy gone before they can replace it:
/// the Inno installer would otherwise fail on a locked exe, and the macOS
/// swap script sits waiting on this process id. A plain field so a test can
/// exercise the dialog without taking the test runner down with it.
void Function() quitForUpdate = () => exit(0);

/// Offers [info] and, if the user says yes, downloads and applies it.
///
/// The dialog owns the whole flow rather than handing progress to the status
/// bar: this is the one operation in the app that ends with it closing, so it
/// should not be possible to start it, navigate away and forget.
Future<void> showUpdateDialog(
  UpdateInfo info, {
  UpdateService? service,
  BuildContext? hostContext,
}) async {
  final context = hostContext ?? GlobalVariable.infobox.currentContext;
  if (context == null) return;
  final updater = service ?? UpdateService();
  plausible.event(page: 'update_dialog');

  await showDialog(
    context: context,
    builder: (context) => _UpdateDialog(info: info, updater: updater),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info, required this.updater});

  final UpdateInfo info;
  final UpdateService updater;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  /// Null while nothing is running; 0..1 once bytes are arriving.
  double? _progress;
  bool _installing = false;
  String? _error;
  CancelToken? _cancelToken;

  bool get _busy => _progress != null || _installing;

  Future<void> _start() async {
    final token = CancelToken();
    setState(() {
      _error = null;
      _progress = 0.0;
      _cancelToken = token;
    });

    try {
      final file = await widget.updater.download(
        widget.info,
        cancelToken: token,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      if (!mounted) return;
      setState(() => _installing = true);

      if (!await widget.updater.install(file)) {
        // No installer for this host after all — the release page is still a
        // working answer.
        launchUrlString(widget.info.releaseUrl);
        if (mounted) Navigator.pop(context);
        return;
      }
      // Give the launched installer a moment to come up before the window it
      // is waiting on disappears.
      await Future.delayed(const Duration(seconds: 1));
      quitForUpdate();
    } on UpdateException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.messageKey.i18n();
          _progress = null;
          _installing = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // A cancel is the user's own doing, not a failure to report.
        _error = e is DioException && CancelToken.isCancel(e)
            ? null
            : 'update-failed-text'.i18n();
        _progress = null;
        _installing = false;
      });
    } finally {
      _cancelToken = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 460.0),
      title: Text('update-title-text'.i18n()),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('update-available-text'.i18n([widget.info.version]),
              style: const TextStyle(height: 1.4)),
          const SizedBox(height: 8.0),
          Text(
            widget.info.canInstall
                ? 'update-detail-text'.i18n()
                : 'update-manual-text'.i18n(),
            style: const TextStyle(height: 1.4),
          ),
          const SizedBox(height: 12.0),
          HyperlinkButton(
            key: const ValueKey('test-update-notes'),
            onPressed: () => launchUrlString(widget.info.releaseUrl),
            child: Text('update-notes-text'.i18n()),
          ),
          if (progress != null) ...[
            const SizedBox(height: 12.0),
            ProgressBar(value: progress * 100),
            const SizedBox(height: 6.0),
            // The percent sign travels with the value, so no translation has
            // to carry a literal `%` next to the `%s` placeholder.
            Text('update-downloading-text'
                .i18n(['${(progress * 100).round()}%'])),
          ],
          if (_installing) ...[
            const SizedBox(height: 12.0),
            Text('update-installing-text'.i18n()),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12.0),
            InfoBar(
              title: Text(_error!),
              severity: InfoBarSeverity.error,
              isLong: true,
            ),
          ],
        ],
      ),
      actions: [
        if (_busy)
          Button(
            key: const ValueKey('test-update-cancel'),
            onPressed: _installing
                ? null
                : () {
                    _cancelToken?.cancel();
                    Navigator.pop(context);
                  },
            child: Text('cancel-text'.i18n()),
          )
        else ...[
          Button(
            key: const ValueKey('test-update-skip'),
            onPressed: () {
              widget.updater.skip(widget.info);
              Navigator.pop(context);
            },
            child: Text('update-skip-text'.i18n()),
          ),
          Button(
            key: const ValueKey('test-update-later'),
            onPressed: () => Navigator.pop(context),
            child: Text('update-later-text'.i18n()),
          ),
          FilledButton(
            key: const ValueKey('test-update-install'),
            onPressed: widget.info.canInstall
                ? _start
                : () {
                    launchUrlString(widget.info.releaseUrl);
                    Navigator.pop(context);
                  },
            child: Text((widget.info.canInstall
                    ? 'update-install-text'
                    : 'update-open-page-text')
                .i18n()),
          ),
        ],
      ],
    );
  }
}
