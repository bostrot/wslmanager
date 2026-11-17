// The create-container form.
//
// Its own file rather than more of containers_screen.dart, which is already the
// screen *and* four row actions, and because the create path is the one part of
// the container layer that takes user input and therefore carries the
// validation (lib/api/containers/container_create_request.dart).
//
// The form is deliberately the common subset of `run` rather than all of it:
// image, name, ports, volumes, environment and a command. Everything `wslc`,
// Docker and Podman spell identically, so one dialog serves all three. The
// flags that only make sense with a terminal attached — `-it`, `--attach` —
// are not offered at all: a GUI has no stdin to give them.

import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/containers/container_create_request.dart';
import 'package:wsl2distromanager/api/containers/container_models.dart';
import 'package:wsl2distromanager/api/containers/container_service.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// Show the create form over [host], which must be the Containers screen's own
/// context — `showDialog`'s default key belongs to the home screen, which is
/// not mounted while this screen is the body.
///
/// [engines] is what the screen already probed, so the picker does not re-run
/// the probe. [onCreated] fires after the engine has accepted the container,
/// for the screen to reload itself.
Future<void> showCreateContainerDialog(
  BuildContext host, {
  required ContainerService service,
  required List<ContainerEngine> engines,
  ContainerEngine? active,
  void Function()? onCreated,
}) {
  return showDialog<void>(
    context: host,
    builder: (_) => CreateContainerDialog(
      service: service,
      engines: engines,
      active: active,
      onCreated: onCreated,
    ),
  );
}

class CreateContainerDialog extends StatefulWidget {
  const CreateContainerDialog({
    super.key,
    required this.service,
    required this.engines,
    this.active,
    this.onCreated,
  });

  final ContainerService service;
  final List<ContainerEngine> engines;
  final ContainerEngine? active;
  final void Function()? onCreated;

  @override
  State<CreateContainerDialog> createState() => _CreateContainerDialogState();
}

class _CreateContainerDialogState extends State<CreateContainerDialog> {
  final TextEditingController _image = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _ports = TextEditingController();
  final TextEditingController _volumes = TextEditingController();
  final TextEditingController _env = TextEditingController();
  final TextEditingController _command = TextEditingController();

  bool _removeOnExit = false;
  bool _creating = false;

  /// Which field the message belongs under, and the message. Shown at the
  /// field rather than as a toast, so "not a port mapping" is next to the
  /// ports box; the engine's own refusals have no field and sit at the bottom.
  String? _errorField;
  String? _error;

  late ContainerEngine? _engine = _initialEngine();

  /// The engine the picker opens on, which has to be one of [widget.engines].
  ///
  /// The pin in settings outlives the engine it names: someone who pinned
  /// Podman and then uninstalled it still has a usable Docker. Honouring the
  /// pin blindly sends the `run` to an engine the host does not have — the
  /// picker renders the stale value without complaint and the whole filled-in
  /// form comes back as "command not found". Same rule
  /// [ContainerService.activeEngine] applies to every other command.
  ContainerEngine? _initialEngine() {
    final active = widget.active;
    if (active != null && widget.engines.contains(active)) return active;
    return widget.engines.isEmpty ? null : widget.engines.first;
  }

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'create_container_dialog');
  }

  @override
  void dispose() {
    _image.dispose();
    _name.dispose();
    _ports.dispose();
    _volumes.dispose();
    _env.dispose();
    _command.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    ContainerCreateRequest request;
    try {
      request = ContainerCreateRequest.parse(
        image: _image.text,
        name: _name.text,
        ports: _ports.text,
        volumes: _volumes.text,
        env: _env.text,
        command: _command.text,
        removeOnExit: _removeOnExit,
      );
    } on ContainerFieldError catch (e) {
      // The validators return i18n keys, not sentences.
      setState(() {
        _errorField = e.field;
        _error = e.message.i18n();
      });
      return;
    }

    setState(() {
      _errorField = null;
      _error = null;
      _creating = true;
    });
    Notify.message('creatingcontainer-text'.i18n([request.image]),
        loading: true);
    try {
      await widget.service.create(request, engine: _engine);
      Notify.message('createdcontainer-text'.i18n([request.summary]),
          severity: InfoBarSeverity.success);
      widget.onCreated?.call();
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    } catch (error) {
      if (!mounted) return;
      // The engine's own words — "port is already allocated", "no such
      // image" — are the useful part, and they belong to no single field.
      setState(() {
        _creating = false;
        _errorField = null;
        _error = '$error';
      });
    }
  }

  /// A labelled box. [placeholder] carries the literal syntax, which is the
  /// same in every language and so is not translated.
  Widget _box(
    String labelKey,
    String testKey,
    TextEditingController controller, {
    String placeholder = '',
    String field = '',
    int maxLines = 1,
    String? captionKey,
  }) {
    final showError = _error != null && _errorField == field && field.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InfoLabel(
          label: labelKey.i18n(),
          child: TextBox(
            key: ValueKey(testKey),
            controller: controller,
            enabled: !_creating,
            maxLines: maxLines,
            placeholder: placeholder,
            onChanged: (_) {
              if (_error != null) {
                setState(() {
                  _error = null;
                  _errorField = null;
                });
              }
            },
          ),
        ),
        if (captionKey != null)
          Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: Text(captionKey.i18n(),
                style:
                    TextStyle(fontSize: 11, color: secondaryTextColor(context))),
          ),
        if (showError)
          Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: Text(_error!,
                key: ValueKey('$testKey-error'),
                style:
                    TextStyle(fontSize: 12, color: destructiveColor(context))),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Only worth a picker when there is a choice; with one engine the label
    // would be a row that can never change.
    final showEnginePicker = widget.engines.length > 1;
    final unattachedError =
        _error != null && (_errorField == null || _errorField!.isEmpty);

    return ContentDialog(
      key: const ValueKey('test-create-container-dialog'),
      constraints: const BoxConstraints(maxWidth: 620.0),
      title: Text('createcontainertitle-text'.i18n()),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('createcontainerbody-text'.i18n(),
                style:
                    TextStyle(fontSize: 12, color: secondaryTextColor(context))),
            const SizedBox(height: 12.0),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: _box('containerimage-text', 'test-create-image',
                      _image,
                      placeholder: 'alpine',
                      field: ContainerCreateRequest.fieldImage),
                ),
                const SizedBox(width: 8.0),
                Expanded(
                  flex: 2,
                  child: _box('containername-text', 'test-create-name', _name,
                      placeholder: 'my-container',
                      field: ContainerCreateRequest.fieldName),
                ),
              ],
            ),
            if (showEnginePicker) ...[
              const SizedBox(height: 12.0),
              InfoLabel(
                label: 'containerengine-text'.i18n(),
                child: ComboBox<ContainerEngine>(
                  key: const ValueKey('test-create-engine'),
                  value: _engine,
                  isExpanded: true,
                  items: widget.engines
                      .map((engine) => ComboBoxItem<ContainerEngine>(
                            value: engine,
                            child: Text(engine.label),
                          ))
                      .toList(),
                  onChanged: _creating
                      ? null
                      : (value) => setState(() => _engine = value),
                ),
              ),
            ],
            const SizedBox(height: 12.0),
            _box('containerports-text', 'test-create-ports', _ports,
                placeholder: '8080:80',
                field: ContainerCreateRequest.fieldPorts,
                maxLines: 3,
                captionKey: 'containeroneperline-text'),
            const SizedBox(height: 12.0),
            _box('containervolumes-text', 'test-create-volumes', _volumes,
                placeholder: 'mydata:/data',
                field: ContainerCreateRequest.fieldVolumes,
                maxLines: 3,
                captionKey: 'containeroneperline-text'),
            const SizedBox(height: 12.0),
            _box('containerenv-text', 'test-create-env', _env,
                placeholder: 'KEY=value',
                field: ContainerCreateRequest.fieldEnv,
                maxLines: 3,
                captionKey: 'containeroneperline-text'),
            const SizedBox(height: 12.0),
            _box('containercommand-text', 'test-create-command', _command,
                placeholder: 'sleep 3600',
                field: ContainerCreateRequest.fieldCommand),
            const SizedBox(height: 12.0),
            Checkbox(
              key: const ValueKey('test-create-rm'),
              checked: _removeOnExit,
              onChanged: _creating
                  ? null
                  : (value) => setState(() => _removeOnExit = value ?? false),
              content: Text('containerremoveonexit-text'.i18n()),
            ),
            if (unattachedError)
              Padding(
                padding: const EdgeInsets.only(top: 12.0),
                child: InfoBar(
                  key: const ValueKey('test-create-container-error'),
                  title: Text('createcontainerfailed-text'.i18n()),
                  content: Text(_error!),
                  severity: InfoBarSeverity.error,
                  isLong: true,
                ),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('test-create-container-submit'),
          onPressed: _creating ? null : _submit,
          child: Text('create-text'.i18n()),
        ),
        Button(
          key: const ValueKey('test-dialog-cancel'),
          onPressed: _creating
              ? null
              : () => Navigator.of(context, rootNavigator: true).pop(),
          child: Text('cancel-text'.i18n()),
        ),
      ],
    );
  }
}
