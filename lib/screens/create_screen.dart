import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/busy_button.dart';
import 'package:wsl2distromanager/components/form_card.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/unsaved_changes.dart';
import 'package:wsl2distromanager/dialogs/create_dialog.dart';
import 'package:wsl2distromanager/nav/router.dart';

/// What the user chose when they tried to leave an install in progress.
enum _LeaveChoice { stop, background, stay }

/// Full-page version of the create flow.
///
/// The form itself is [CreateWidget], shared with the old dialog. A page
/// rather than a dialog because creating an instance downloads and extracts
/// image layers: that can run for minutes, and a dialog both hides the
/// progress notifications behind it and invites an accidental dismiss.
class CreatePage extends StatefulWidget {
  const CreatePage({super.key});

  @override
  State<CreatePage> createState() => _CreatePageState();
}

class _CreatePageState extends State<CreatePage> {
  final WSLApi _api = WSLApi();
  final TextEditingController _autoSuggestBox = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final ValueNotifier<CreateSourceType> _sourceType =
      ValueNotifier<CreateSourceType>(CreateSourceType.repo);
  final ValueNotifier<bool> _creating = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _createUser = ValueNotifier<bool>(false);
  final ValueNotifier<CreateFailure?> _createError =
      ValueNotifier<CreateFailure?>(null);
  final ValueNotifier<CreateProgress?> _progress =
      ValueNotifier<CreateProgress?>(null);

  /// Mirrors the form's live duplicate check (audit CI-02).
  final ValueNotifier<bool> _nameTaken = ValueNotifier<bool>(false);

  /// The saved cloud-init configuration to apply on first start, by name;
  /// empty for none. Only offered where the backend can use it — a local
  /// wsl.exe, whose user profile this app can write into (ai-tasks#76).
  final ValueNotifier<String> _cloudInitName = ValueNotifier<String>('');

  /// Live only while a create is running.
  CancelSignal? _cancelSignal;

  /// The page is gone but the install it started is not, because the user
  /// chose to leave it running. [_creating], [_createError] and [_progress]
  /// are still held by that create, so disposal waits for it.
  bool _detached = false;

  /// Registered while creating, so the nav pane, the back button and the
  /// window X all have to ask before abandoning the page. Without it the
  /// labelled escape hatch was disabled and the unlabelled one was not
  /// (audit CI-14).
  late final Future<bool> Function() _leaveGuard = _confirmLeaveWhileCreating;

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'create');
  }

  @override
  void dispose() {
    UnsavedChangesGuard.release(_leaveGuard);
    _autoSuggestBox.dispose();
    _locationController.dispose();
    _nameController.dispose();
    _userController.dispose();
    _sourceType.dispose();
    _createUser.dispose();
    _nameTaken.dispose();
    _cloudInitName.dispose();
    if (_creating.value) {
      _detached = true;
    } else {
      _disposeCreateNotifiers();
    }
    super.dispose();
  }

  void _disposeCreateNotifiers() {
    _creating.dispose();
    _createError.dispose();
    _progress.dispose();
  }

  void _leave() {
    if (router.canPop()) {
      router.pop();
    } else {
      router.goNamed('home');
    }
  }

  /// Asked by [UnsavedChangesGuard] on every route out of this page.
  Future<bool> _confirmLeaveWhileCreating() async {
    if (!_creating.value || !mounted) return true;
    final choice = await showDialog<_LeaveChoice>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: Text('createrunning-title'.i18n()),
        content: Text('createrunning-text'.i18n()),
        actions: [
          Button(
            key: const ValueKey('test-create-leave-stay'),
            onPressed: () => Navigator.pop(dialogContext, _LeaveChoice.stay),
            child: Text('stayonpage-text'.i18n()),
          ),
          Button(
            key: const ValueKey('test-create-leave-stop'),
            onPressed: () => Navigator.pop(dialogContext, _LeaveChoice.stop),
            child: Text('stopinstall-text'.i18n()),
          ),
          FilledButton(
            key: const ValueKey('test-create-leave-background'),
            onPressed: () =>
                Navigator.pop(dialogContext, _LeaveChoice.background),
            child: Text('keepinstalling-text'.i18n()),
          ),
        ],
      ),
    );
    // Escape or a tap outside: the safe reading is "I did not mean to leave",
    // never "abandon the install".
    switch (choice ?? _LeaveChoice.stay) {
      case _LeaveChoice.stay:
        return false;
      case _LeaveChoice.stop:
        _cancelSignal?.cancel();
        return true;
      case _LeaveChoice.background:
        return true;
    }
  }

  Future<void> _create() async {
    final token = CancelSignal();
    _cancelSignal = token;
    _creating.value = true;
    _createError.value = null;
    _progress.value = CreateProgress(
      phase: CreatePhase.downloading,
      label: 'creatinginstance-text'.i18n(),
    );
    UnsavedChangesGuard.register(_leaveGuard);
    bool success = false;
    try {
      success = await createInstance(
        _nameController,
        _locationController,
        _api,
        _autoSuggestBox,
        _userController,
        isDocker: _sourceType.value == CreateSourceType.docker,
        isDockerLocalImage:
            _sourceType.value == CreateSourceType.dockerLocalImage,
        isVhdx: _sourceType.value == CreateSourceType.vhdx,
        requireUser: _createUser.value && supportsDefaultUser(_sourceType.value),
        cloudInitName: _cloudInitName.value,
        onError: _createError,
        onProgress: _progress,
        cancelSignal: token,
      );
    } finally {
      _cancelSignal = null;
      _creating.value = false;
      _progress.value = null;
      UnsavedChangesGuard.release(_leaveGuard);
    }
    // The page was left while this ran, so it owns the notifiers' disposal.
    if (_detached) {
      _disposeCreateNotifiers();
      return;
    }
    if (!mounted) return;
    if (success) {
      _leave();
    }
    // Otherwise stay put so the error is readable and the form can be
    // corrected. A cancel lands here too, with the banner already cleared.
  }

  /// The bar, the phase line and the elapsed clock, drawn on the page itself.
  ///
  /// The only progress signal used to be a one-line toast at the bottom of the
  /// window, ~700 px from the form, which read "Downloading 100%" for the
  /// whole `wsl --import` (audit CI-16).
  Widget _progressPanel(CreateProgress progress) {
    return Padding(
      padding: const EdgeInsets.only(top: 20.0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          key: const ValueKey('test-create-progress'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // An indeterminate bar where there is no percentage to show: an
            // import has none, and inventing one is how the old status line
            // came to claim a finished download for minutes.
            SizedBox(
              width: double.infinity,
              child: ProgressBar(
                value: progress.fraction == null
                    ? null
                    : (progress.fraction! * 100).clamp(0.0, 100.0),
              ),
            ),
            const SizedBox(height: 8),
            Text(progress.label),
            const SizedBox(height: 4),
            Text(
              'createkeepsrunning-text'.i18n(),
              style: TextStyle(color: secondaryTextColor(context)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _creating,
      builder: (context, isCreating, _) {
        // The form is ~400px tall; pinned into the top-left corner of a
        // desktop window it left two thirds of the page dead. Centre the
        // block in whatever height the window has; below that the scroll
        // view takes over as before.
        return LayoutBuilder(
            builder: (context, viewport) => SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (viewport.maxHeight - 48).clamp(0.0, double.infinity),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FormPageHeader(
                icon: FluentIcons.add_to,
                title: 'createnewinstance-text'.i18n(),
                description: 'createinstanceinfo-text'.i18n(),
              ),
              const SizedBox(height: 20),
              CreateWidget(
                  nameController: _nameController,
                  api: _api,
                  autoSuggestBox: _autoSuggestBox,
                  locationController: _locationController,
                  userController: _userController,
                  sourceType: _sourceType,
                  creating: _creating,
                  createError: _createError,
                  createUserEnabled: _createUser,
                  nameTaken: _nameTaken,
                  cloudInitName:
                      _api.features.cloudInit ? _cloudInitName : null,
              ),
              if (isCreating)
                ValueListenableBuilder<CreateProgress?>(
                  valueListenable: _progress,
                  builder: (context, progress, _) => progress == null
                      ? const SizedBox.shrink()
                      : _progressPanel(progress),
                ),
              const SizedBox(height: 24),
              Row(
                children: [
                  // Disabled while the inline duplicate message shows, so
                  // submitting cannot add a second copy of the same
                  // complaint in a second visual style (audit CI-02).
                  ValueListenableBuilder<bool>(
                    valueListenable: _nameTaken,
                    builder: (context, taken, _) => BusyButton(
                      key: const ValueKey('test-create-button'),
                      filled: true,
                      label: 'create-text'.i18n(),
                      busyLabel: 'creating-text'.i18n(),
                      busy: isCreating,
                      onPressed: (isCreating || taken) ? null : _create,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Enabled throughout: while creating it stops the install,
                  // otherwise it leaves the page.
                  Button(
                    key: const ValueKey('test-cancel-button'),
                    onPressed: isCreating ? _cancelSignal?.cancel : _leave,
                    child: Text(isCreating
                        ? 'stopinstall-text'.i18n()
                        : 'cancel-text'.i18n()),
                  ),
                ],
              ),
            ],
                  ),
                ),
              ],
            ),
          ),
        ));
      },
    );
  }
}
