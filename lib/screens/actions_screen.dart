import 'dart:io' show Platform;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:re_editor/re_editor.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';
import 'package:wsl2distromanager/dialogs/guest_access_dialog.dart';
import 'package:wsl2distromanager/dialogs/snippet_env_dialog.dart';
import 'package:wsl2distromanager/nav/router.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

class QuickPage extends StatefulWidget {
  const QuickPage({Key? key, this.api}) : super(key: key);

  /// Injected in tests; the screen builds its own.
  final VmBackend? api;

  @override
  QuickPageState createState() => QuickPageState();
}

class QuickPageState extends State<QuickPage> {
  List<Widget> quickSettings = [];
  String lineNumbers = '';
  bool showInput = false;
  var scrollController = ScrollController();
  var nameController = TextEditingController();
  var contentController = CodeLineEditingController();
  int lineNum = 30;

  /// What Save is waiting for. Pressing it with an empty name used to hit a
  /// branch whose entire body was the comment `// Error` (audit ST-53).
  String? saveError;

  /// The instances a snippet can be run in from this screen — running used
  /// to be reachable only from a distro row's dropdown on Home (audit ST-60).
  List<String> _instances = [];

  /// A snippet runs as root inside a chosen instance; the flyout is that
  /// choice.
  Widget _runSnippetButton(QuickActionItem action) {
    if (_instances.isEmpty) return const SizedBox.shrink();
    return DropDownButton(
      leading: const Icon(FluentIcons.play, size: 14.0),
      title: Text('runininstance-text'.i18n()),
      items: [
        for (final instance in _instances)
          MenuFlyoutItem(
            text: Text(distroLabel(instance)),
            onPressed: () async {
              plausible.event(name: "wsl_quickaction_run");
              final api = widget.api ?? vmBackend();
              final user = prefs.getString('StartUser_$instance');
              // Apple VMs installed from an ISO get the app's SSH key
              // installed here, once, before the snippet runs.
              if (!await ensureGuestAccess(context, api, instance,
                  user: user)) {
                return;
              }
              if (!mounted) return;
              // A snippet that declares or reads environment variables asks
              // for them here instead of expecting the script to be edited
              // first (bostrot/ai-tasks#99).
              final env = await askSnippetEnv(context, action);
              if (env == null) return;
              api.runCommands(instance, action.content.split('\n'),
                  user: guestRunUser(instance, user), env: env);
            },
          ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();

    plausible.event(page: 'actions_screen');
    genLineNumbers(0);
    // Only when injected or in a real app run: a widget test that pumps this
    // screen must not spawn wsl.exe from initState.
    if (widget.api != null ||
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      (widget.api ?? vmBackend()).list(false).then((instances) {
        if (mounted) setState(() => _instances = instances.all);
      }).catchError((_) {});
    }
    // So a "the script is empty" message goes away as soon as it stops being
    // true, the same way the name one does.
    contentController.addListener(() {
      if (saveError != null && contentController.text.trim().isNotEmpty) {
        setState(() => saveError = null);
      }
    });
    scrollController.addListener(() {
      lineNumbers = '';
      int offset = (scrollController.offset ~/ 12);
      genLineNumbers(offset);
    });
  }

  void genLineNumbers(int offset) {
    for (int i = 1 + offset; i < lineNum + offset + 1; i++) {
      lineNumbers += i.toString();
      if (i < lineNum + offset) {
        lineNumbers += '\n';
      }
    }
    setState(() {
      lineNumbers = lineNumbers;
    });
  }

  Map<int, bool> opened = {};

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        children: [
          !showInput ? communityActionsBtn() : Container(),
          Positioned(
            left: 20.0,
            right: 20.0,
            bottom: 10.0,
            child: Column(
              children: [
                showInput
                    ? SizedBox(
                        width: MediaQuery.of(context).size.width - 40.0,
                        height: 35.0,
                        child: TextBox(
                          controller: nameController,
                          placeholder: 'settingname-text'.i18n(),
                          onChanged: (_) {
                            if (saveError != null) {
                              setState(() => saveError = null);
                            }
                          },
                        ),
                      )
                    : Container(),
                if (showInput && saveError != null)
                  SizedBox(
                    width: MediaQuery.of(context).size.width - 40.0,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text(
                        saveError!,
                        key: const ValueKey('test-action-save-error'),
                        style: TextStyle(color: destructiveColor(context), fontSize: 12.0),
                      ),
                    ),
                  ),
                showInput
                    ? const SizedBox(
                        height: 10.0,
                      )
                    : Container(),
                // TODO: Better line numbers
                showInput
                    ? Editor(
                        contentController: contentController,
                        scrollController: scrollController,
                        lineNumbers: lineNumbers,
                        lineNum: lineNum)
                    : Container(),
                //const SizedBox(height: 10.0),
                SizedBox(
                  width: MediaQuery.of(context).size.width - 40.0,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: bottomButtonRow(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Padding communityActionsBtn() {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0),
      child: Column(
        children: [
          Flexible(
              child: SingleChildScrollView(child: quickSettingsListBuilder())),
        ],
      ),
    );
  }

  Row bottomButtonRow() {
    return Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Beside "Add a snippet", not centred at the top of the content
            // area in the opposite corner — the two closely related adds
            // shared no grouping, alignment or wording pattern (audit ST-61).
            if (!showInput) ...[
              Button(
                style: ButtonStyle(
                    padding: ButtonState.all<EdgeInsets>(const EdgeInsets.only(
                        top: 8.0, bottom: 8.0, left: 20.0, right: 20.0))),
                onPressed: () async {
                  await router.pushNamed('community');
                  if (mounted) setState(() {});
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(FluentIcons.cloud_download),
                    const SizedBox(width: 10.0),
                    Text('addcommunityactions-text'.i18n()),
                  ],
                ),
              ),
              const SizedBox(width: 10.0),
            ],
            showInput
                ? Tooltip(
                    message: 'close-text'.i18n(),
                    child: Button(
                      style: ButtonStyle(
                          padding: ButtonState.all<EdgeInsets>(
                              const EdgeInsets.only(
                                  top: 8.0,
                                  bottom: 8.0,
                                  left: 20.0,
                                  right: 20.0))),
                      onPressed: () {
                        setState(() {
                          showInput = false;
                          saveError = null;
                        });
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(FluentIcons.chrome_close),
                          const SizedBox(
                            width: 10.0,
                          ),
                          Text('close-text'.i18n()),
                        ],
                      ),
                    ),
                  )
                : Container(),
            const SizedBox(
              width: 10.0,
            ),
            Tooltip(
              message:
                  showInput ? 'save-text'.i18n() : 'addquickaction-text'.i18n(),
              child: Button(
                style: ButtonStyle(
                    padding: ButtonState.all<EdgeInsets>(const EdgeInsets.only(
                        top: 8.0, bottom: 8.0, left: 20.0, right: 20.0))),
                onPressed: () async {
                  if (!showInput) {
                    await router.pushNamed('snippet');
                    if (mounted) setState(() {});
                    return;
                  } else if (nameController.text.trim().isEmpty ||
                      contentController.text.trim().isEmpty) {
                    // Say which of the two is missing rather than leaving the
                    // screen exactly as it was.
                    setState(() {
                      saveError = nameController.text.trim().isEmpty
                          ? 'snippetnamerequired-text'.i18n()
                          : 'snippetcontentrequired-text'.i18n();
                    });
                  } else {
                    plausible.event(page: 'add_action');

                    // Load data
                    List<String>? titles =
                        prefs.getStringList('quickSettingsTitles');
                    titles ??= [];
                    List<String>? contents =
                        prefs.getStringList('quickSettingsContents');
                    contents ??= [];

                    // Override if already exists
                    if (titles.contains(nameController.text)) {
                      int pos = titles.indexOf(nameController.text);
                      titles.removeAt(pos);
                      contents.removeAt(pos);
                    }

                    // Add title to list
                    titles.add(nameController.text);
                    prefs.setStringList('quickSettingsTitles', titles);

                    // Add content to list
                    contents.add(contentController.text);
                    prefs.setStringList('quickSettingsContents', contents);

                    setState(() {
                      showInput = false;
                      saveError = null;
                    });
                  }
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    showInput
                        ? Text('save-text'.i18n())
                        : Text('addquickaction-text'.i18n()),
                    const SizedBox(
                      width: 10.0,
                    ),
                    Icon(
                      showInput ? FluentIcons.save : FluentIcons.settings_add,
                      size: 15.0,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Builder quickSettingsListBuilder() {
    return Builder(
      builder: (context) {
        List<QuickActionItem> quickActions = QuickAction().getFromPrefs();
        quickSettings = [];
        for (int i = 0; i < quickActions.length; i++) {
          if (opened[i] == null) {
            opened[i] = false;
          }
          // No invented "[v0.0.0]" on a snippet that has no version, and no
          // hardcoded English "you" — the byline is a key like every other
          // word on this screen (audit ST-57).
          final version = quickActions[i].version;
          final author = quickActions[i].author;
          quickSettings.add(Padding(
            padding: const EdgeInsets.only(left: 8.0, right: 8.0, top: 8.0),
            child: Column(
              children: [
                Expander(
                    initiallyExpanded: false,
                    // The old spans took their colour from a getter that read
                    // the *preference*, so `system` rendered black on the dark
                    // theme (audit TL-03), and the accent-blue "(by you)"
                    // measured 4.41:1 and read as an author link that went
                    // nowhere (ST-57).
                    header: RichText(
                      text: TextSpan(children: [
                        TextSpan(
                          text: quickActions[i].name,
                          style: TextStyle(
                            color: FluentTheme.of(context)
                                .resources
                                .textFillColorPrimary,
                          ),
                        ),
                        if (version.isNotEmpty)
                          TextSpan(
                            text: ' [v$version]',
                            style: TextStyle(
                              color: secondaryTextColor(context),
                            ),
                          ),
                        TextSpan(
                          text:
                              ' ${author.isNotEmpty ? 'snippetauthor-text'.i18n([
                                  author
                                ]) : 'snippetauthoryou-text'.i18n()}',
                          style: TextStyle(
                            fontSize: 13.0,
                            color: secondaryTextColor(context),
                          ),
                        ),
                      ]),
                    ),
                    trailing: Row(
                      children: [
                        MergeSemantics(
                          child: Tooltip(
                            message: 'edit-text'.i18n(),
                            child: IconButton(
                              icon: const Icon(FluentIcons.edit),
                              onPressed: () async {
                                await router.pushNamed('snippet',
                                    extra: quickActions[i]);
                                if (mounted) setState(() {});
                              },
                            ),
                          ),
                        ),
                        MergeSemantics(
                          child: Tooltip(
                            message: 'delete-text'.i18n(),
                            child: IconButton(
                              icon: Icon(FluentIcons.delete,
                                  color: destructiveColor(context)),
                              onPressed: () {
                                // A snippet is two SharedPreferences entries.
                                // This asked "Delete instance … permanently? /
                                // If you delete this Distro …" — the third
                                // object to be offered the distro copy
                                // (audit ST-54).
                                dialog(
                                    item: quickActions[i],
                                    title: 'deletesnippetquestion-text'
                                        .i18n([quickActions[i].name]),
                                    body: 'deletesnippetbody-text'.i18n(),
                                    submitText: 'delete-text'.i18n(),
                                    submitInput: false,
                                    submitStyle: ButtonStyle(
                                      backgroundColor:
                                          ButtonState.all(Colors.red),
                                      foregroundColor:
                                          ButtonState.all(Colors.white),
                                    ),
                                    onSubmit: (inputText) {
                                      QuickAction.removeFromPrefs(
                                          quickActions[i]);
                                      setState(() {});
                                    });
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                    // Sized to the script, capped at 40% of the window — a
                    // one-line snippet used to open a 430px panel that was
                    // 97% empty (audit ST-55). The sentence above the script
                    // says what a snippet actually is, and Run makes it
                    // usable from this screen instead of only from a distro
                    // row on Home (ST-60).
                    content: ConstrainedBox(
                      constraints: BoxConstraints(
                          maxHeight:
                              MediaQuery.of(context).size.height * 0.4),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(
                                  left: 20.0, right: 20.0, bottom: 8.0),
                              child: Text(
                                'snippetrunsasroot-text'.i18n(),
                                style: TextStyle(
                                    fontSize: 12.0,
                                    color: secondaryTextColor(context)),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(
                                  left: 20.0, bottom: 8.0),
                              child: _runSnippetButton(quickActions[i]),
                            ),
                            SizedBox(
                                width: MediaQuery.of(context).size.width,
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                      left: 20.0, right: 20.0, bottom: 4.0),
                                  child:
                                      SelectableText(quickActions[i].content),
                                )),
                          ],
                        ),
                      ),
                    )),
              ],
            ),
          ));
        }
        if (quickSettings.isNotEmpty) {
          return Column(children: quickSettings);
        } else {
          // The list sits in a loosely sized Stack child, so Center has no
          // room of its own to work with.
          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: FluentTheme.of(context)
                          .accentColor
                          .withValues(alpha: 0.10),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      FluentIcons.code,
                      size: 26,
                      color: FluentTheme.of(context).accentColor,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'addquickactioninfo-text'.i18n(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: secondaryTextColor(context), fontSize: 14),
                  ),
                ],
              ),
            ),
          );
        }
      },
    );
  }
}

class Editor extends StatelessWidget {
  const Editor({
    Key? key,
    required this.contentController,
    required this.scrollController,
    required this.lineNumbers,
    required this.lineNum,
    this.label,
    this.hint,
    this.languages,
    this.heightFactor = 0.62,
    this.editorKey,
  }) : super(key: key);

  final CodeLineEditingController contentController;
  final ScrollController scrollController;
  final String lineNumbers;
  final int lineNum;

  /// The heading over the frame; the snippet script's by default.
  final String? label;

  /// What an empty editor shows; the snippet script's by default.
  final String? hint;

  /// The highlighter(s) to use; bash by default. The cloud-init editor
  /// hands in YAML (bostrot/ai-tasks#76).
  final Map<String, CodeHighlightThemeMode>? languages;

  /// The frame's share of the window height.
  final double heightFactor;

  /// A key on the inner [CodeEditor], for tests that read its controller.
  final Key? editorKey;

  @override
  Widget build(BuildContext context) {
    // Framed and labelled: the editor used to sit directly on the page
    // background with no border, no fill and no heading — 580px of click
    // target that did not look like one (audit ST-58). The label also says
    // what the script *is*: a root bash script run inside an instance
    // (ST-60).
    return InfoLabel(
      label: label ?? 'snippetscript-text'.i18n(),
      labelStyle: const TextStyle(fontWeight: FontWeight.w500),
      child: Container(
        decoration: BoxDecoration(
          color: cardFillColor(context),
          border: Border.all(color: surfaceBorderColor(context)),
          borderRadius: BorderRadius.circular(4.0),
        ),
        padding: const EdgeInsets.all(4.0),
        height: MediaQuery.of(context).size.height * heightFactor,
        width: MediaQuery.of(context).size.width * 0.9,
        child: CodeEditor(
            key: editorKey,
            hint: hint ?? '# ${'yourcodehere-text'.i18n()}',
            indicatorBuilder:
                (context, editingController, chunkController, notifier) {
              return Row(
                children: [
                  DefaultCodeLineNumber(
                    controller: editingController,
                    notifier: notifier,
                  ),
                  DefaultCodeChunkIndicator(
                      width: 20,
                      controller: chunkController,
                      notifier: notifier)
                ],
              );
            },
            style: CodeEditorStyle(
              // The editor was pinned to the light syntax palette in both
              // themes (audit ST-59).
              codeTheme: CodeHighlightTheme(
                  languages: languages ??
                      {'bash': CodeHighlightThemeMode(mode: langBash)},
                  theme: FluentTheme.of(context).brightness.isDark
                      ? atomOneDarkTheme
                      : atomOneLightTheme),
            ),
            controller: contentController),
      ),
    );
  }
}
