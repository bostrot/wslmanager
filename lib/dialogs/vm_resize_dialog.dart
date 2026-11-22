import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/vm_resize.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// Opens the hardware editor for [instance] (bostrot/ai-tasks#103).
///
/// [service] is injected by tests; the dialog otherwise builds one over the
/// host's backend — outside `build`, because constructing the backend has
/// side effects of its own.
Future<void> showVmResizeDialog(String instance,
    {VmResizeService? service, BuildContext? context}) async {
  final host = context ?? GlobalVariable.infobox.currentContext!;
  VmResizeService resolved;
  if (service != null) {
    resolved = service;
  } else {
    final backend = vmBackend();
    // The button is gated on the same check, so this only fires if a
    // backend changed underneath an open window.
    if (backend is! AppleVmApi) return;
    resolved = VmResizeService(backend);
  }
  await showDialog<void>(
    context: host,
    builder: (_) => VmResizeDialog(instance: instance, service: resolved),
  );
}

class VmResizeDialog extends StatefulWidget {
  final String instance;
  final VmResizeService service;

  const VmResizeDialog(
      {super.key, required this.instance, required this.service});

  @override
  State<VmResizeDialog> createState() => _VmResizeDialogState();
}

class _VmResizeDialogState extends State<VmResizeDialog> {
  final TextEditingController _cpusController = TextEditingController();
  final TextEditingController _memoryController = TextEditingController();
  final TextEditingController _diskController = TextEditingController();

  VmResources? _current;
  String? _loadError;

  /// What is wrong with the numbers in the boxes, shown under them rather
  /// than as a toast: the field it is about is right there.
  String? _fieldError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'vm_resize_dialog');
    _load();
  }

  @override
  void dispose() {
    _cpusController.dispose();
    _memoryController.dispose();
    _diskController.dispose();
    super.dispose();
  }

  /// What went wrong, for the user: the service's own failures carry an i18n
  /// key, anything else is read the way every other error is.
  static String reasonFor(Object error) {
    if (error is VmResizeException && error.message.endsWith('-text')) {
      return error.message.i18n();
    }
    return WslFailure.from(error).shortReason;
  }

  Future<void> _load() async {
    try {
      final current = await widget.service.read(widget.instance);
      if (!mounted) return;
      setState(() {
        _current = current;
        _cpusController.text = '${current.cpus}';
        _memoryController.text = '${current.memoryGb}';
        _diskController.text = '${current.diskGb}';
      });
    } catch (error) {
      if (mounted) setState(() => _loadError = reasonFor(error));
    }
  }

  /// A whole positive number, or null when the box does not hold one.
  static int? wholeNumber(String text) {
    final value = int.tryParse(text.trim());
    return (value == null || value < 1) ? null : value;
  }

  Future<void> _save() async {
    final current = _current;
    if (current == null) return;
    final cpus = wholeNumber(_cpusController.text);
    final memoryGb = wholeNumber(_memoryController.text);
    final diskGb = wholeNumber(_diskController.text);
    if (cpus == null || memoryGb == null || diskGb == null) {
      setState(() => _fieldError = 'vmresizepositive-text'.i18n());
      return;
    }
    final problem = validateVmResize(
        current: current, cpus: cpus, memoryGb: memoryGb, diskGb: diskGb);
    if (problem != null) {
      setState(() => _fieldError = problem.i18n());
      return;
    }

    setState(() {
      _fieldError = null;
      _saving = true;
    });
    Notify.message('vmresizing-text'.i18n([distroLabel(widget.instance)]),
        loading: true);
    try {
      final result = await widget.service.apply(widget.instance,
          cpus: cpus, memoryGb: memoryGb, diskGb: diskGb);
      Notify.message(
          'vmresized-text'.i18n([
            distroLabel(widget.instance),
            '${result.cpus}',
            '${gigabytesOf(result.memoryBytes)}',
            '${gigabytesOf(result.diskSizeBytes)}',
          ]),
          severity: InfoBarSeverity.success);
      // The one thing the user still has to do themselves, and only when
      // they do: a guest that grows its own root on the next boot is not
      // worth a second message.
      if (result.needsGuestAction) {
        Notify.message('vmresizeguestmanual-text'.i18n(),
            severity: InfoBarSeverity.warning);
      }
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _fieldError = reasonFor(error);
      });
    }
  }

  Widget _numberBox(
      String label, String testKey, TextEditingController controller) {
    return InfoLabel(
      label: label,
      child: TextBox(
        key: ValueKey(testKey),
        controller: controller,
        keyboardType: TextInputType.number,
        enabled: !_saving,
        onChanged: (_) {
          if (_fieldError != null) setState(() => _fieldError = null);
        },
      ),
    );
  }

  Widget _body() {
    final loadError = _loadError;
    if (loadError != null) {
      return Text(loadError,
          key: const ValueKey('test-vmresize-error'),
          style: TextStyle(color: destructiveColor(context)));
    }
    final current = _current;
    if (current == null) {
      return Row(children: [
        const SizedBox.square(
            dimension: 16.0, child: ProgressRing(strokeWidth: 2.0)),
        const SizedBox(width: 8.0),
        Text('loading-text'.i18n()),
      ]);
    }
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('vmresizebody-text'.i18n()),
          const SizedBox(height: 12.0),
          if (current.running)
            Padding(
              padding: const EdgeInsets.only(bottom: 12.0),
              child: InfoBar(
                key: const ValueKey('test-vmresize-running'),
                title: Text('vmresizerunning-text'.i18n()),
                severity: InfoBarSeverity.warning,
                isLong: true,
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                  child: _numberBox('vmresizecpus-text'.i18n(),
                      'test-vmresize-cpus', _cpusController)),
              const SizedBox(width: 8.0),
              Expanded(
                  child: _numberBox('vmresizememory-text'.i18n(),
                      'test-vmresize-memory', _memoryController)),
              const SizedBox(width: 8.0),
              Expanded(
                  child: _numberBox('vmresizedisk-text'.i18n(),
                      'test-vmresize-disk', _diskController)),
            ],
          ),
          const SizedBox(height: 6.0),
          Text(
              'vmresizecurrent-text'.i18n([
                '${current.cpus}',
                '${current.memoryGb}',
                '${current.diskGb}',
                '${Platform.numberOfProcessors}',
              ]),
              key: const ValueKey('test-vmresize-current'),
              style: TextStyle(
                  fontSize: 12, color: secondaryTextColor(context))),
          if (_fieldError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(_fieldError!,
                  key: const ValueKey('test-vmresize-field-error'),
                  style:
                      TextStyle(fontSize: 12, color: destructiveColor(context))),
            ),
          const SizedBox(height: 12.0),
          InfoBar(
            key: const ValueKey('test-vmresize-nextstart'),
            title: Text('vmresizenextstart-text'.i18n()),
            content: Text(current.guestMayGrowItself
                ? 'vmresizeguestgrows-text'.i18n()
                : 'vmresizeguestmanual-text'.i18n()),
            severity: InfoBarSeverity.info,
            isLong: true,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 620.0),
      title: Text('vmresizetitle-text'.i18n([distroLabel(widget.instance)])),
      content: _body(),
      actions: [
        FilledButton(
          key: const ValueKey('test-vmresize-save'),
          onPressed:
              current == null || current.running || _saving ? null : _save,
          child: Text('save-text'.i18n()),
        ),
        Button(
          key: const ValueKey('test-dialog-cancel'),
          onPressed: _saving
              ? null
              : () => Navigator.of(context, rootNavigator: true).pop(),
          child: Text('cancel-text'.i18n()),
        ),
      ],
    );
  }
}
