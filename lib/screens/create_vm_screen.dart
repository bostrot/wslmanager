import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/apple/vm_image_catalog.dart';
import 'package:wsl2distromanager/api/recipes/recipe_catalog.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/cloud_init.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart' show formatTransferSize;
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/busy_button.dart';
import 'package:wsl2distromanager/components/cloud_init_picker.dart';
import 'package:wsl2distromanager/components/error_view.dart';
import 'package:wsl2distromanager/components/form_card.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/components/suggest_on_focus.dart';
import 'package:wsl2distromanager/nav/router.dart';

/// Test seam: replaces the backend used by the page.
AppleVmApi Function() appleVmApiBuilder = () {
  final backend = vmBackend();
  return backend is AppleVmApi ? backend : AppleVmApi();
};

/// What a new Linux VM boots from. The two are one exclusive choice on the
/// page: a cloud image (or any raw disk image, e.g. an exported template)
/// seeds the disk and comes up ready to use, an installer ISO is attached
/// and the user clicks through a normal install. They used to be two
/// free-form fields, with the catalog's cloud images listed under the
/// installer box (bostrot/ai-tasks#5).
enum VmBootKind { cloudImage, installerIso }

/// Create-page for native VMs on macOS (Apple Virtualization framework).
///
/// The counterpart of [CreatePage]: instead of downloading a WSL rootfs it
/// provisions a VM — a Linux guest from a cloud image / raw disk image or
/// from an installer ISO, or a macOS guest from a restore image on Apple
/// Silicon.
class CreateVmPage extends StatefulWidget {
  const CreateVmPage({super.key});

  @override
  State<CreateVmPage> createState() => _CreateVmPageState();
}

class _CreateVmPageState extends State<CreateVmPage> {
  final _name = TextEditingController();
  final _user = TextEditingController(text: 'user');
  final _iso = TextEditingController();
  final _image = TextEditingController();
  final _restoreImage = TextEditingController();
  final _diskSize = TextEditingController(text: '32');
  final _cpus = TextEditingController(text: '2');
  final _memory = TextEditingController(text: '4');

  String _guestOs = 'linux';
  // Cloud image first: it is the recommended path (no manual install).
  VmBootKind _bootKind = VmBootKind.cloudImage;
  String _recipeId = '';

  /// The saved cloud-init configuration to seed a Linux guest with, by
  /// name; empty for none (bostrot/ai-tasks#76).
  String _cloudInitName = '';
  bool _creating = false;
  String? _nameError;
  String? _userError;
  String? _bootSourceError;

  /// Live while a catalog ISO is being fetched; the Cancel button stops it.
  CancelSignal? _cancelSignal;
  String? _downloadLabel;
  double? _downloadFraction;

  /// What the helper is doing right now, and how far it is — a macOS guest
  /// downloads several GB and then runs a full installer, and the page used
  /// to show one unchanging "Creating instance" for the whole hour
  /// (bostrot/ai-tasks#100). Null outside a create that reports progress.
  String? _createLabel;
  double? _createFraction;

  /// The last plain line the helper printed. A helper older than the
  /// progress protocol reports no steps at all, and a dev run keeps using
  /// the installed `vmctl` until it is rebuilt, so this is what stops the
  /// page going quiet again; with a current helper it names the restore
  /// image being fetched.
  String? _createDetail;

  /// The step [_createDetail] belongs to, so a line about the download
  /// does not sit under "Installing macOS" once the download is over.
  VmCreatePhase? _createPhase;

  /// A failed create, kept on the page. The status bar drops its message
  /// after a few seconds, so an install that failed at minute fifty left
  /// nothing behind to read. [_createErrorName] is the name that create was
  /// for: the field is editable again while the banner is up.
  String? _createError;
  String _createErrorName = '';

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'create_vm');
  }

  @override
  void dispose() {
    _name.dispose();
    _user.dispose();
    _iso.dispose();
    _image.dispose();
    _restoreImage.dispose();
    _diskSize.dispose();
    _cpus.dispose();
    _memory.dispose();
    super.dispose();
  }

  Future<void> _pickFile(
      TextEditingController target, List<String> extensions) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    final path = result?.files.single.path;
    if (path != null && mounted) {
      setState(() => target.text = path);
    }
  }

  int _intOf(TextEditingController controller, int fallback) =>
      int.tryParse(controller.text.trim()) ?? fallback;

  /// The account cloud-init will create, checked the way `useradd` would.
  /// vmctl refuses anything else — the name reaches an ssh target and the
  /// `.command` script Terminal opens — so say so under the field rather
  /// than let the create fail with the helper's English-only complaint.
  static final RegExp _guestUserPattern = RegExp(r'^[a-z_][a-z0-9_-]{0,31}$');

  Future<void> _create() async {
    final api = appleVmApiBuilder();
    final name = sanitizeDistroName(_name.text.trim());
    if (name.isEmpty) {
      setState(() => _nameError = 'errorentername-text'.i18n());
      return;
    }
    final user = _user.text.trim();
    if (_guestOs == 'linux' &&
        user.isNotEmpty &&
        !_guestUserPattern.hasMatch(user)) {
      setState(() {
        _nameError = null;
        _userError = 'vminvaliduser-text'.i18n();
      });
      return;
    }
    try {
      final existing = (await api.list(true)).all;
      if (existing.any((e) => e.toLowerCase() == name.toLowerCase())) {
        setState(() => _nameError = 'distroexists-text'.i18n());
        return;
      }
    } catch (_) {
      // The helper may be unavailable; creation below reports that properly.
    }

    // A Linux VM with nothing to boot from boots into nothing: EFI finds no
    // boot option and the guest powers off within seconds. Require a boot
    // source rather than let the user create a VM that can only fail (macOS
    // guests always install from a restore image). Only the chosen kind
    // counts — whatever was typed under the other choice is ignored.
    final isIso = _bootKind == VmBootKind.installerIso;
    final bootSource = (isIso ? _iso : _image).text.trim();
    if (_guestOs == 'linux' && bootSource.isEmpty) {
      setState(() {
        _nameError = null;
        _userError = null;
        _bootSourceError = 'vmbootsourcerequired-text'.i18n();
      });
      return;
    }

    // The picker shows "None" for a configuration deleted since it was
    // chosen, but the choice is still held here; the Windows page refuses
    // that create, and so does this one, rather than seed nothing in
    // silence.
    final cloudInit =
        _cloudInitName.isEmpty ? null : CloudInitStore.instance.byName(_cloudInitName);
    if (_cloudInitName.isNotEmpty && cloudInit == null) {
      Notify.message('cloudinitmissing-text'.i18n([_cloudInitName]),
          severity: InfoBarSeverity.error);
      return;
    }

    setState(() {
      _nameError = null;
      _userError = null;
      _bootSourceError = null;
      _createError = null;
      _createLabel = null;
      _createFraction = null;
      _createDetail = null;
      _createPhase = null;
      _creating = true;
    });

    // A catalog pick downloads (or reuses) the file first; a plain path
    // goes straight through. The catalog entry's own kind decides how the
    // file is used (a cloud image seeds the disk, an ISO is attached), so a
    // catalog name pasted under the wrong choice still boots correctly.
    var isoPath = isIso ? bootSource : '';
    var imagePath = isIso ? '' : bootSource;
    final catalogEntry =
        _guestOs == 'linux' ? VmImageCatalog.entryFor(bootSource) : null;
    if (catalogEntry != null) {
      final token = CancelSignal();
      _cancelSignal = token;
      try {
        final downloadedPath = await vmImageCatalogBuilder().download(
          catalogEntry,
          cancelSignal: token,
          onProgress: (received, total) {
            if (!mounted) return;
            setState(() {
              _downloadFraction =
                  total > 0 ? (received / total).clamp(0.0, 1.0) : null;
              _downloadLabel = total > 0
                  ? '${'downloading-text'.i18n()} '
                      '${(received / total * 100).toStringAsFixed(0)}% '
                      '(${formatTransferSize(received)} / '
                      '${formatTransferSize(total)})'
                  : '${'downloading-text'.i18n()} '
                      '${formatTransferSize(received)}';
            });
          },
        );
        if (catalogEntry.isCloudImage) {
          imagePath = downloadedPath;
          isoPath = '';
        } else {
          isoPath = downloadedPath;
          imagePath = '';
        }
      } on CancelledException {
        Notify.message('');
        if (mounted) setState(() => _creating = false);
        return;
      } catch (error) {
        Notify.message(
            '${'errordownloading-text'.i18n()} ${catalogEntry.name}: $error',
            severity: InfoBarSeverity.error);
        if (mounted) setState(() => _creating = false);
        return;
      } finally {
        _cancelSignal = null;
        if (mounted) {
          setState(() {
            _downloadLabel = null;
            _downloadFraction = null;
          });
        }
      }
    }

    Notify.message('creatinginstance-text'.i18n([name]), loading: true);
    try {
      if (_guestOs == 'macos') {
        await api.createMacosVm(
          name,
          restoreImagePath: _restoreImage.text.trim(),
          diskSizeGb: _intOf(_diskSize, 64),
          cpus: _intOf(_cpus, 4),
          memoryGb: _intOf(_memory, 8),
          onProgress: _reportCreateProgress,
          onStatus: _reportCreateStatus,
        );
      } else {
        await api.createLinuxVm(
          name,
          isoPath: isoPath,
          imagePath: imagePath,
          diskSizeGb: _intOf(_diskSize, 32),
          cpus: _intOf(_cpus, 2),
          memoryGb: _intOf(_memory, 4),
          user: user.isEmpty ? 'user' : user,
          // Only a cloud image reads the seed; an installer ISO does not.
          userData: isIso ? null : cloudInit?.content,
        );
      }
      if (_recipeId.isNotEmpty) {
        // A fresh VM is not reachable yet; the recipe installs on the first
        // run once the guest answers (home list applies pending recipes).
        await prefs.setString('PendingRecipe_$name', _recipeId);
      }
      Notify.message(
          _recipeId.isEmpty
              ? 'vmcreated-text'.i18n([name])
              : 'vmcreatedwithservice-text'.i18n(
                  [name, RecipeCatalog.byId(_recipeId)?.name ?? _recipeId]),
          severity: InfoBarSeverity.success);
      if (mounted) {
        if (router.canPop()) {
          router.pop();
        } else {
          router.goNamed('home');
        }
      }
    } catch (error) {
      Notify.message('${'vmcreatefailed-text'.i18n([name])} $error',
          severity: InfoBarSeverity.error);
      if (mounted) {
        setState(() {
          _createError = '$error';
          _createErrorName = name;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _creating = false;
          _createLabel = null;
          _createFraction = null;
          _createDetail = null;
          _createPhase = null;
        });
      }
    }
  }

  /// One step the helper reported, turned into the page's progress bar and
  /// the status bar's message — the latter because the create screen is not
  /// where the user necessarily waits.
  void _reportCreateProgress(VmCreateProgress update) {
    if (!mounted) return;
    final label = _createProgressLabel(update);
    setState(() {
      // Only on a *change* of step: the line naming the restore image is
      // printed just before the download step is announced, and belongs to
      // it.
      if (_createPhase != null && update.phase != _createPhase) {
        _createDetail = null;
      }
      _createPhase = update.phase;
      _createLabel = label;
      _createFraction = update.fraction;
    });
    Notify.message(label, loading: true);
  }

  /// Whatever the helper said that was not a step. Shown under the bar,
  /// and in the status bar while no step has been reported — an older
  /// helper only ever gets this far, and one unchanging message for an
  /// hour is what this issue was about.
  void _reportCreateStatus(String line) {
    if (!mounted) return;
    setState(() => _createDetail = line);
    if (_createLabel == null) Notify.message(line, loading: true);
  }

  /// "Downloading the macOS restore image 42% (6.0 GB / 14.2 GB)" and the
  /// like: the step in words, then whatever numbers it has.
  static String _createProgressLabel(VmCreateProgress update) {
    String step;
    switch (update.phase) {
      case VmCreatePhase.lookup:
        step = 'vmcreatelookup-text'.i18n();
        break;
      case VmCreatePhase.download:
        step = 'vmcreatedownload-text'.i18n();
        break;
      case VmCreatePhase.prepare:
        step = 'vmcreateprepare-text'.i18n();
        break;
      case VmCreatePhase.install:
        step = 'vmcreateinstall-text'.i18n();
        break;
    }
    final fraction = update.fraction;
    final received = update.received;
    final total = update.total;
    // A download the server sent no length for has bytes and no percent;
    // saying how much has arrived still tells the user it is moving.
    if (fraction == null) {
      return received == null ? step : '$step ${formatTransferSize(received)}';
    }
    final percent = '${(fraction * 100).toStringAsFixed(0)}%';
    if (received == null || total == null) return '$step $percent';
    return '$step $percent '
        '(${formatTransferSize(received)} / ${formatTransferSize(total)})';
  }

  /// The boot-source choice for a Linux guest: two radio buttons and one
  /// field that follows them. The field is an autocomplete over the curated
  /// arm64 catalog filtered to the chosen kind — cloud images under "Cloud
  /// image", ISOs under "Installer ISO" — (picked entries are downloaded
  /// and cached, the way the Windows create screen offers its rootfs
  /// catalogue), while a local path or the file picker keeps working
  /// unchanged. The list opens on click, so the catalog is visible before
  /// anything is typed. Each kind keeps its own controller, so switching
  /// back and forth does not lose what was entered.
  /// A "nothing to boot from" complaint was about the other choice's
  /// field; it must not linger under the one just switched to.
  void _chooseBootKind(VmBootKind kind) {
    setState(() {
      _bootKind = kind;
      _bootSourceError = null;
    });
  }

  Widget _bootSourceSection() {
    final isIso = _bootKind == VmBootKind.installerIso;
    final controller = isIso ? _iso : _image;
    final suggestions = [
      for (final entry in VmImageCatalog.entries)
        if (entry.isCloudImage != isIso) suggestionItem(entry.name),
    ];
    return FormCard(
      icon: FluentIcons.pop_expand,
      // The card's heading is the label the two choices used to carry; a
      // second one inside it would say "Boot from" twice.
      title: 'vmbootsource-text'.i18n(),
      children: [
        // A Wrap, not a Row: the two labels do not fit side by side in
        // every locale (or at a narrow window), and must not overflow.
        Wrap(
          spacing: 24,
          runSpacing: 8,
          children: [
            RadioButton(
              key: const ValueKey('test-vm-boot-cloud-image'),
              checked: !isIso,
              onChanged: _creating
                  ? null
                  : (_) => _chooseBootKind(VmBootKind.cloudImage),
              content: Text('vmbootcloudimage-text'.i18n()),
            ),
            RadioButton(
              key: const ValueKey('test-vm-boot-installer-iso'),
              checked: isIso,
              onChanged: _creating
                  ? null
                  : (_) => _chooseBootKind(VmBootKind.installerIso),
              content: Text('vmbootinstalleriso-text'.i18n()),
            ),
          ],
        ),
        InfoLabel(
          label: isIso
              ? 'vminstalleriso-text'.i18n()
              : 'vmcloudimage-text'.i18n(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SuggestOnFocus<String>(
                      key: ValueKey(isIso ? 'test-vm-iso' : 'test-vm-image'),
                      builder: (context, boxKey, focusNode) =>
                          AutoSuggestBox<String>(
                        key: boxKey,
                        focusNode: focusNode,
                        controller: controller,
                        enabled: !_creating,
                        placeholder: isIso
                            ? 'vmisoplaceholder-text'.i18n()
                            : 'vmcloudimageplaceholder-text'.i18n(),
                        items: suggestions,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    onPressed: _creating
                        ? null
                        : () => _pickFile(
                            controller,
                            isIso
                                ? const ['iso']
                                : const ['img', 'raw', 'qcow2']),
                    child: Text('selectfile-text'.i18n()),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                    isIso
                        ? 'vminstallerisohint-text'.i18n()
                        : 'vmcloudimagehint-text'.i18n(),
                    style: TextStyle(
                        fontSize: 12, color: secondaryTextColor(context))),
              ),
              if (_bootSourceError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(_bootSourceError!,
                      key: const ValueKey('test-vm-boot-error'),
                      style: TextStyle(color: destructiveColor(context))),
                ),
              if (_downloadLabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: ProgressBar(
                          value: _downloadFraction == null
                              ? null
                              : (_downloadFraction! * 100).clamp(0.0, 100.0),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(_downloadLabel!,
                          key: const ValueKey('test-vm-iso-progress'),
                          style: TextStyle(
                              fontSize: 12,
                              color: secondaryTextColor(context))),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fileField(String label, TextEditingController controller,
      List<String> extensions,
      {String? hint, Key? key}) {
    return InfoLabel(
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextBox(key: key, controller: controller),
              ),
              const SizedBox(width: 8),
              Button(
                onPressed:
                    _creating ? null : () => _pickFile(controller, extensions),
                child: Text('selectfile-text'.i18n()),
              ),
            ],
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 4.0),
              child: Text(hint,
                  style: TextStyle(
                      fontSize: 12, color: secondaryTextColor(context))),
            ),
        ],
      ),
    );
  }

  Widget _numberField(String label, TextEditingController controller,
      {Key? key}) {
    return Expanded(
      child: InfoLabel(
        label: label,
        child: TextBox(key: key, controller: controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLinux = _guestOs == 'linux';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FormPageHeader(
                icon: FluentIcons.add_to,
                title: 'createnewinstance-text'.i18n(),
                description: 'vmcreateinfo-text'.i18n(),
              ),
              const SizedBox(height: 20),
              // A create that fails after an hour deserves better than a
              // status bar that clears itself: the helper's own words stay
              // here until the next attempt, foldable and selectable so
              // they can be pasted into a report.
              if (_createError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: InfoBar(
                    key: const ValueKey('test-vm-create-error'),
                    title:
                        Text('vmcreatefailed-text'.i18n([_createErrorName])),
                    content: ErrorDetails(details: _createError!),
                    severity: InfoBarSeverity.error,
                    isLong: true,
                    onClose: () => setState(() => _createError = null),
                  ),
                ),
              FormCard(
                icon: FluentIcons.text_document,
                title: 'createbasics-text'.i18n(),
                children: [
                  InfoLabel(
                    label: 'name-text'.i18n(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextBox(
                          key: const ValueKey('test-vm-name'),
                          controller: _name,
                          enabled: !_creating,
                        ),
                        if (_nameError != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: Text(_nameError!,
                                key: const ValueKey('test-vm-name-error'),
                                style: TextStyle(
                                    fontSize: 12,
                                    color: destructiveColor(context))),
                          ),
                      ],
                    ),
                  ),
                  InfoLabel(
                    label: 'vmguestos-text'.i18n(),
                    child: ComboBox<String>(
                      key: const ValueKey('test-vm-guest-os'),
                      value: _guestOs,
                      isExpanded: true,
                      items: const [
                        ComboBoxItem(value: 'linux', child: Text('Linux')),
                        ComboBoxItem(value: 'macos', child: Text('macOS')),
                      ],
                      onChanged: _creating
                          ? null
                          : (value) =>
                              setState(() => _guestOs = value ?? 'linux'),
                    ),
                  ),
                  if (isLinux)
                    InfoLabel(
                      label: 'optionalusername-text'.i18n(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextBox(
                              key: const ValueKey('test-vm-user'),
                              controller: _user,
                              enabled: !_creating),
                          if (_userError != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Text(_userError!,
                                  key: const ValueKey('test-vm-user-error'),
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: destructiveColor(context))),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (isLinux)
                _bootSourceSection()
              else
                FormCard(
                  icon: FluentIcons.pop_expand,
                  title: 'vmbootsource-text'.i18n(),
                  spacing: 8,
                  children: [
                    _fileField(
                      'vmrestoreimage-text'.i18n(),
                      _restoreImage,
                      const ['ipsw'],
                      hint: 'vmrestoreimagehint-text'.i18n(),
                      key: const ValueKey('test-vm-restore-image'),
                    ),
                    Text('vmmacosrequiresapplesilicon-text'.i18n(),
                        style: TextStyle(
                            fontSize: 12, color: secondaryTextColor(context))),
                  ],
                ),
              const SizedBox(height: 12),
              FormCard(
                icon: FluentIcons.processing,
                title: 'createresources-text'.i18n(),
                children: [
                  // Bottom-aligned: the three labels are short in English and
                  // two lines long in more than one locale, and the boxes have
                  // to line up either way.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _numberField('vmdisksize-text'.i18n(), _diskSize,
                          key: const ValueKey('test-vm-disk-size')),
                      const SizedBox(width: 8),
                      _numberField('vmcpus-text'.i18n(), _cpus,
                          key: const ValueKey('test-vm-cpus')),
                      const SizedBox(width: 8),
                      _numberField('vmmemorygb-text'.i18n(), _memory,
                          key: const ValueKey('test-vm-memory')),
                    ],
                  ),
                  // Optional: a curated service (MinIO, Postgres, …)
                  // installed into the VM the first time it is running.
                  InfoLabel(
                    label: 'vmservice-text'.i18n(),
                    child: ComboBox<String>(
                      key: const ValueKey('test-vm-recipe'),
                      value: _recipeId,
                      isExpanded: true,
                      placeholder: Text('vmservicenone-text'.i18n()),
                      items: [
                        ComboBoxItem(
                            value: '',
                            child: Text('vmservicenone-text'.i18n())),
                        for (final recipe in RecipeCatalog.recipes)
                          ComboBoxItem(
                            value: recipe.id,
                            child: Text(
                                '${recipe.name} — ${recipe.description}',
                                overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: _creating
                          ? null
                          : (value) => setState(() => _recipeId = value ?? ''),
                    ),
                  ),
                  // Optional: a saved cloud-init configuration, folded into
                  // the seed next to the account vmctl sets up, so it runs
                  // on the first boot. Only a Linux guest booting a cloud
                  // image reads the seed; an installer ISO does not.
                  if (isLinux && _bootKind == VmBootKind.cloudImage)
                    CloudInitPicker(
                      value: _cloudInitName,
                      enabled: !_creating,
                      hint: 'cloudinitvmhint-text'.i18n(),
                      onChanged: (value) =>
                          setState(() => _cloudInitName = value),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              // Either half is enough to show the block: a helper that
              // reports no steps still prints lines, and those are then all
              // the page has to say the create is alive.
              if (_createLabel != null || _createDetail != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: ProgressBar(
                          key: const ValueKey('test-vm-create-progress-bar'),
                          value: _createFraction == null
                              ? null
                              : (_createFraction! * 100).clamp(0.0, 100.0),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(_createLabel ?? _createDetail!,
                          key: const ValueKey('test-vm-create-progress'),
                          style: TextStyle(
                              fontSize: 12,
                              color: secondaryTextColor(context))),
                      if (_createLabel != null && _createDetail != null)
                        Text(_createDetail!,
                            key: const ValueKey('test-vm-create-detail'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11,
                                color: secondaryTextColor(context))),
                    ],
                  ),
                ),
              Row(
                children: [
                  BusyButton(
                    key: const ValueKey('test-vm-create-button'),
                    filled: true,
                    label: 'create-text'.i18n(),
                    busyLabel: 'creating-text'.i18n(),
                    busy: _creating,
                    onPressed: _creating ? null : _create,
                  ),
                  const SizedBox(width: 8),
                  Button(
                    key: const ValueKey('test-vm-cancel-button'),
                    // While a catalog download runs, Cancel stops it; the
                    // rest of a create is too quick to need one.
                    onPressed: _creating
                        ? (_cancelSignal == null
                            ? null
                            : () => _cancelSignal?.cancel())
                        : () {
                            if (router.canPop()) {
                              router.pop();
                            } else {
                              router.goNamed('home');
                            }
                          },
                    child: Text('cancel-text'.i18n()),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
