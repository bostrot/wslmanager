import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:localization/localization.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wsl2distromanager/api/github_publish.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/components/busy_button.dart';
import 'package:wsl2distromanager/components/error_view.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Test seam: replaces the publisher (and its network).
GithubPublisher Function() githubPublisherBuilder = () => GithubPublisher();

/// Shares one snippet as a pull request on the community scripts repo.
///
/// Sign-in is GitHub's device flow: the user opens a URL, types a short
/// code, and this polls until they are done. The app never handles their
/// password and needs no client secret.
class ShareSnippetDialog extends StatefulWidget {
  const ShareSnippetDialog({super.key, required this.item});

  final QuickActionItem item;

  @override
  State<ShareSnippetDialog> createState() => _ShareSnippetDialogState();
}

enum _Stage { idle, awaitingUser, publishing, done }

class _ShareSnippetDialogState extends State<ShareSnippetDialog> {
  late final GithubPublisher _publisher;
  _Stage _stage = _Stage.idle;
  DeviceCodePrompt? _prompt;
  String? _error;
  String? _prUrl;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _publisher = githubPublisherBuilder();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _stage = _Stage.idle;
    });
    try {
      // Already signed in from a previous share: go straight to the PR.
      if (GithubPublisher.storedToken != null) {
        await _publish();
        return;
      }
      final prompt = await _publisher.requestDeviceCode();
      if (!mounted) return;
      setState(() {
        _prompt = prompt;
        _stage = _Stage.awaitingUser;
      });
      await Clipboard.setData(ClipboardData(text: prompt.userCode));
      await launchUrl(Uri.parse(prompt.verificationUri));

      final signedIn = await _publisher.pollForToken(prompt,
          cancelled: () => _cancelled);
      if (!mounted || _cancelled) return;
      if (!signedIn) {
        setState(() {
          _stage = _Stage.idle;
          _error = 'githubsignintimeout-text'.i18n();
        });
        return;
      }
      await _publish();
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.idle;
        _error = err.toString();
      });
    }
  }

  Future<void> _publish() async {
    setState(() => _stage = _Stage.publishing);
    try {
      final result = await _publisher.publish(widget.item);
      if (!mounted) return;
      setState(() {
        _stage = _Stage.done;
        _prUrl = result.pullRequestUrl;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.idle;
        // A token can be revoked between shares; make the next try sign in
        // again rather than failing the same way forever.
        if (err.toString().contains('401')) {
          GithubPublisher.clearToken();
        }
        _error = err.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: Text('sharesnippettitle-text'.i18n()),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!GithubPublisher.isConfigured)
              InfoBar(
                key: const ValueKey('test-share-unconfigured'),
                title: Text('githubnotconfigured-text'.i18n()),
                severity: InfoBarSeverity.warning,
                isLong: true,
              )
            else ...[
              Text('sharesnippetbody-text'.i18n([widget.item.name]),
                  style: TextStyle(color: secondaryTextColor(context))),
              const SizedBox(height: 12),
              _stageBody(context),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              ErrorDetails(details: _error!),
            ],
          ],
        ),
      ),
      actions: [
        if (_stage == _Stage.done)
          FilledButton(
            key: const ValueKey('test-share-open-pr'),
            onPressed: () => launchUrl(Uri.parse(_prUrl!)),
            child: Text('openpullrequest-text'.i18n()),
          )
        else
          BusyButton(
            key: const ValueKey('test-share-publish'),
            filled: true,
            label: 'sharesnippet-text'.i18n(),
            busyLabel: 'sharing-text'.i18n(),
            busy: _stage != _Stage.idle,
            onPressed: (!GithubPublisher.isConfigured || _stage != _Stage.idle)
                ? null
                : _start,
          ),
        Button(
          onPressed: () {
            _cancelled = true;
            Navigator.pop(context);
          },
          child: Text('close-text'.i18n()),
        ),
      ],
    );
  }

  Widget _stageBody(BuildContext context) {
    switch (_stage) {
      case _Stage.awaitingUser:
        final prompt = _prompt!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('githubentercode-text'.i18n(),
                style: TextStyle(color: secondaryTextColor(context))),
            const SizedBox(height: 8),
            SelectableText(
              prompt.userCode,
              key: const ValueKey('test-share-user-code'),
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 3),
            ),
            const SizedBox(height: 4),
            Text('githubcodecopied-text'.i18n(),
                style: TextStyle(
                    fontSize: 11, color: secondaryTextColor(context))),
          ],
        );
      case _Stage.publishing:
        return Row(children: [
          const SizedBox.square(
              dimension: 14, child: ProgressRing(strokeWidth: 2)),
          const SizedBox(width: 8),
          Text('creatingpullrequest-text'.i18n()),
        ]);
      case _Stage.done:
        return InfoBar(
          key: const ValueKey('test-share-done'),
          title: Text('pullrequestcreated-text'.i18n()),
          severity: InfoBarSeverity.success,
          isLong: true,
        );
      case _Stage.idle:
        return const SizedBox.shrink();
    }
  }
}
