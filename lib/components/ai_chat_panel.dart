import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart'
    show
        DirectionallyExtendSelectionEvent,
        GranularlyExtendSelectionEvent,
        SelectedContent,
        SelectionEvent,
        SelectionEventType,
        SelectionResult;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        LogicalKeyboardKey;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/ai_chat_sessions.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/api/sandbox_service.dart';
import 'package:wsl2distromanager/api/todo_store.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/beta_badge.dart';
import 'package:wsl2distromanager/components/named_button.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';
import 'package:wsl2distromanager/nav/router.dart';

class AiChatPanel extends StatefulWidget {
  const AiChatPanel({
    Key? key,
    this.onClose,
    this.sandbox,
    this.expanded = false,
    this.onToggleExpanded,
  }) : super(key: key);

  /// Closes the panel. Without it the only way to dismiss the panel was the
  /// FAB behind it (audit PS-34).
  final VoidCallback? onClose;

  /// When set, this panel is that sandbox's chat: same UI, same task queue,
  /// but the transcript and tools come from [SandboxChat] — scoped to one
  /// distro. Null is the normal app-wide assistant.
  final SandboxChat? sandbox;

  /// Whether the dock currently fills the page area. The panel only reports
  /// the state in its header; the dock owns it.
  final bool expanded;

  /// Flips [expanded]. Null hides the toggle — the panel is also used
  /// outside the dock, where there is nothing to expand into.
  final VoidCallback? onToggleExpanded;

  /// Whether the chord that sends a message is Command rather than Control.
  ///
  /// Read off [defaultTargetPlatform] rather than `Platform.isMacOS`: the
  /// same build of the tests runs on both CI runners, and only the former
  /// can be pinned from a test.
  static bool get sendsWithCommand =>
      defaultTargetPlatform == TargetPlatform.macOS;

  /// How the hint under the box spells that chord.
  static String get sendModifierLabel => sendsWithCommand ? '⌘' : 'Ctrl';

  @override
  State<AiChatPanel> createState() => _AiChatPanelState();
}

class _AiChatPanelState extends State<AiChatPanel> {
  final AiService _ai = AiService();
  final LicenseManager _license = LicenseManager();
  final TodoStore _todos = TodoStore.instance;
  final TextEditingController _inputController = TextEditingController();
  late final FocusNode _inputFocus = FocusNode(
    debugLabel: 'AI chat input',
    onKeyEvent: _onInputKey,
  );
  final TextEditingController _todoInputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FlyoutController _sessionsFlyout = FlyoutController();
  final _TranscriptSelectionDelegate _selectionDelegate =
      _TranscriptSelectionDelegate();
  bool _isLoading = false;
  bool _tasksExpanded = false;

  /// A run is in flight — this panel's own, or one the web dashboard
  /// started on the shared service (ai-tasks#83). Either way Send waits and
  /// the progress row shows.
  bool get _busy => _isLoading || _ai.isRunning;

  /// The signal that genuinely stops the current run — tools and the
  /// in-flight request included, not just the UI (plan item 1).
  CancelSignal? _runCancel;

  /// Set by Cancel so the task runner's auto-continue stops too, instead of
  /// immediately dispatching the next round of the queue.
  bool _stopTasksRequested = false;

  /// The last send failed. The user message is already in the transcript,
  /// so the banner this drives offers to re-run it — a failure used to
  /// leave only an expiring toast and no way to try again.
  bool _sendFailed = false;

  /// How many times a "work on tasks" run may auto-continue itself before it
  /// stops on its own — a queue that never drains must not loop forever.
  static const int _maxAutoContinue = 6;

  SandboxChat? get _sandbox => widget.sandbox;

  /// Previous conversations with the app assistant. Sandbox chats are
  /// already one thread per distro, so they keep their own store.
  final AiChatSessions _sessions = AiChatSessions.instance;

  /// Whether this panel can start and reopen chats — the app assistant can,
  /// a sandbox chat is its distro's single thread.
  bool get _hasSessions => _sandbox == null;

  /// Files the running conversation under "Previous chats" and starts an
  /// empty one. Clearing used to be the only way to a fresh context, and it
  /// threw the conversation away (ai-tasks#104).
  void _newChat() {
    if (!_hasSessions || _busy) return;
    _sessions.archive(_ai.conversationHistory);
    _ai.clearHistory();
    _unblock();
    setState(() => _sendFailed = false);
  }

  /// Puts a stored chat back on screen, filing the running one first.
  void _openChat(String id) {
    if (!_hasSessions || _busy) return;
    final messages = _sessions.switchTo(id, _ai.conversationHistory);
    if (messages == null) return;
    _ai.restoreHistory(messages);
    _unblock();
    setState(() => _sendFailed = false);
    _scrollToBottom();
  }
  List<AiMessage> get _transcript =>
      _sandbox?.history ?? _ai.conversationHistory;

  /// Incremented on every Send and on Cancel. A reply whose generation is
  /// stale was cancelled while in flight and is dropped — the panel used to
  /// have no way out of a hung request at all (audit PS-34).
  int _requestGeneration = 0;

  /// i18n key of the precondition that stopped the last Send, if any.
  ///
  /// Send used to answer a missing API key by navigating to Settings on its
  /// own, which destroyed this panel and took the typed question with it
  /// (audit PS-33). The notice is rendered in the panel instead, and the text
  /// stays in the box.
  String? _blockedReasonKey;

  /// The route the notice's button goes to, and its label.
  String? _blockedRouteName;
  String? _blockedActionKey;

  void _block(String reasonKey, String routeName, String actionKey) {
    if (!mounted) return;
    setState(() {
      _blockedReasonKey = reasonKey;
      _blockedRouteName = routeName;
      _blockedActionKey = actionKey;
    });
  }

  void _unblock() {
    if (_blockedReasonKey == null) return;
    setState(() {
      _blockedReasonKey = null;
      _blockedRouteName = null;
      _blockedActionKey = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _ai.init().then((_) => setState(() {}));
    _todos.addListener(_onTodosChanged);
    _ai.transcriptRevision.addListener(_onTranscriptChanged);
    _sessions.addListener(_onSessionsChanged);
  }

  /// A chat was filed away or reopened: the history flyout and the header
  /// count come from the store, so repaint.
  void _onSessionsChanged() {
    if (mounted) setState(() {});
  }

  void _onTodosChanged() {
    if (mounted) setState(() {});
  }

  /// The transcript changed under this panel — a run started from the web
  /// dashboard added a turn, or the other side cleared the chat. This
  /// panel's own runs already repaint through their onUpdate callback.
  void _onTranscriptChanged() {
    if (!mounted || _isLoading) return;
    setState(() {});
    _scrollToBottom();
  }

  /// Sends the "work through the queue" instruction, then auto-continues while
  /// the assistant keeps completing tasks — this is the "keep going until all
  /// are done" the user asked for. It stops when the queue is empty, when a
  /// run makes no progress, or after [_maxAutoContinue] rounds.
  Future<void> _workOnTasks() async {
    if (_busy || !_todos.hasOpen) return;
    _stopTasksRequested = false;
    await _dispatch(
        'Work through the task list until every item is done. Use todo_list '
        'to see what is left, do each task with your tools, and call '
        'todo_set_done the moment you finish one.');
    var rounds = 0;
    while (mounted &&
        !_stopTasksRequested &&
        _todos.hasOpen &&
        rounds < _maxAutoContinue &&
        !_busy) {
      final before = _todos.openCount;
      rounds++;
      await _dispatch('Continue with the remaining tasks.');
      // No progress this round — stop rather than spin.
      if (_todos.openCount >= before) break;
    }
  }

  /// One button stops everything: the in-flight request, further tool
  /// executions, and the task runner's auto-continue.
  void _cancelRun() {
    _stopTasksRequested = true;
    _runCancel?.cancel();
    // Also stops a run the web dashboard started: one assistant, one run.
    _ai.cancelRun();
    setState(() {
      _requestGeneration++;
      _isLoading = false;
    });
  }

  /// Enter puts in a newline, the platform's chord sends — the box holds a
  /// multi-line question now, and Enter used to fire it off half-written
  /// (ai-tasks#104).
  ///
  /// This sits on the input's own focus node, the first thing a key press
  /// reaches. Reporting the chord as handled is also what keeps the engine
  /// from turning that same press into a line break in the box.
  KeyEventResult _onInputKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final sends = AiChatPanel.sendsWithCommand
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
    if (!sends) return KeyEventResult.ignored;
    _sendMessage();
    return KeyEventResult.handled;
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _busy) return;
    _inputController.clear();
    await _dispatch(text);
  }

  /// Re-run the agent over the transcript as it stands.
  Future<void> _retryLast() => _dispatch('', retry: true);

  /// The actual send: precondition checks, the request, and error handling.
  /// Factored out of [_sendMessage] so the task runner can reuse it; with
  /// [retry] the failed exchange already sits in the history and only the
  /// completion is re-run.
  Future<void> _dispatch(String text, {bool retry = false}) async {
    if ((text.isEmpty && !retry) || _busy) return;

    // AI switched off in Settings — the dock is normally gone with it, but
    // a queued task run or a sandbox chat can still land here.
    if (!AiService.featuresEnabled) {
      if (_inputController.text.isEmpty) _inputController.text = text;
      _block('ai-disabled-text', 'settings', 'opensettings-text');
      return;
    }

    // Check license
    if (!_license.isPro) {
      _block('ai-chat-pro-required-text', 'license', 'upgrade-text');
      return;
    }

    // Chat runs on credentials the user brings — nothing to send without
    // a key or a Claude sign-in, whichever provider is picked.
    if (!_ai.hasAiConfigured) {
      _block(_ai.configRequiredKey, 'settings', 'opensettings-text');
      return;
    }

    _unblock();
    final generation = ++_requestGeneration;
    final cancel = _runCancel = CancelSignal();
    setState(() {
      _isLoading = true;
    });
    _scrollToBottom();

    try {
      void onUpdate() {
        // Tool calls and interim narration land in the transcript mid-run;
        // repaint so the user watches the assistant work instead of staring
        // at a spinner.
        if (mounted && generation == _requestGeneration) {
          setState(() {});
          _scrollToBottom();
        }
      }

      if (retry) {
        await (_sandbox != null
            ? _sandbox!.retryLast(onUpdate: onUpdate, cancel: cancel)
            : _ai.retryLast(onUpdate: onUpdate, cancel: cancel));
      } else if (_sandbox != null) {
        await _sandbox!.send(text, onUpdate: onUpdate, cancel: cancel);
      } else {
        await _ai.sendMessage(text, onUpdate: onUpdate, cancel: cancel);
      }
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _isLoading = false;
        _sendFailed = false;
      });
    } on CancelledException {
      // The user pressed Cancel — the run is already unwound and reported.
      // Cancel bumped the generation before the run's last note (the snippet
      // a changed instance was filed as) landed, so its repaint was dropped;
      // paint once more.
      if (mounted) setState(() {});
      return;
    } catch (e) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _isLoading = false;
      });

      final msg = e.toString();
      if (msg.contains('ai-disabled') ||
          msg.contains('pro-required') ||
          msg.contains('byok-required')) {
        // The question never reached a provider, so give it back rather than
        // making the user retype it (PS-33).
        if (_inputController.text.isEmpty) _inputController.text = text;
        if (msg.contains('ai-disabled')) {
          _block('ai-disabled-text', 'settings', 'opensettings-text');
        } else if (msg.contains('pro-required')) {
          _block('ai-chat-pro-required-text', 'license', 'upgrade-text');
        } else {
          _block(_ai.configRequiredKey, 'settings', 'opensettings-text');
        }
      } else {
        setState(() => _sendFailed = true);
      }
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final history = _transcript;

    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: surfaceBorderColor(context),
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(_sandbox == null ? FluentIcons.chat : FluentIcons.cube_shape,
                  size: 16, color: FluentTheme.of(context).accentColor),
              const SizedBox(width: 8),
              // The badge hugs the title; the leftover space sits between
              // the pair and the action buttons, not inside it.
              Flexible(
                child: Text(
                  _sandbox == null
                      ? 'ai-assistant-title'.i18n()
                      : 'sandbox-chat-title'
                          .i18n([_shortSandboxName(_sandbox!.distro)]),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: FluentTheme.of(context).accentColor,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const BetaBadge(),
              const Spacer(),
              const SizedBox(width: 4),
              // Start a fresh context without losing the running thread:
              // it is filed under "Previous chats" (ai-tasks#104).
              if (_hasSessions)
                NamedIconButton(
                  key: const ValueKey('test-chat-new'),
                  label: 'ai-new-chat-text'.i18n(),
                  icon: FluentIcons.add,
                  iconSize: 14,
                  onPressed: (_busy || history.isEmpty) ? null : _newChat,
                ),
              // Switch between the app assistant, sandbox sessions and the
              // chats filed away earlier — every transcript persists, so any
              // of them can be reopened.
              _sessionsButton(context),
              if (widget.onToggleExpanded != null)
                NamedIconButton(
                  key: const ValueKey('test-chat-expand'),
                  label: (widget.expanded
                          ? 'ai-chat-collapse-text'
                          : 'ai-chat-expand-text')
                      .i18n(),
                  icon: widget.expanded
                      ? FluentIcons.back_to_window
                      : FluentIcons.full_screen,
                  iconSize: 12,
                  onPressed: widget.onToggleExpanded,
                ),
              // No quota counter anymore — chat runs on the user's own API
              // key, so usage is between them and their provider.
              const SizedBox(width: 8),
              // One mis-click used to erase the whole conversation with no
              // undo, and the control stayed live over an empty history
              // (audit PS-35).
              NamedIconButton(
                key: const ValueKey('test-chat-clear'),
                label: 'clearchat-text'.i18n(),
                icon: FluentIcons.delete,
                iconSize: 14,
                onPressed: history.isEmpty
                    ? null
                    : () => dialog(
                          hostContext: context,
                          item: '',
                          title: 'clearchatquestion-text'.i18n(),
                          body: 'clearchatbody-text'.i18n(),
                          submitText: 'clear-text'.i18n(),
                          submitInput: false,
                          submitStyle: ButtonStyle(
                            backgroundColor: ButtonState.all(Colors.red),
                            foregroundColor: ButtonState.all(Colors.white),
                          ),
                          onSubmit: (_) {
                            _sandbox == null
                                ? _ai.clearHistory()
                                : _sandbox!.clear();
                            setState(() {});
                          },
                        ),
              ),
              if (widget.onClose != null) ...[
                const SizedBox(width: 4),
                NamedIconButton(
                  key: const ValueKey('test-chat-close'),
                  label: 'close-text'.i18n(),
                  icon: FluentIcons.chrome_close,
                  iconSize: 12,
                  onPressed: widget.onClose,
                ),
              ],
            ],
          ),
        ),

        // The task queue: the user adds todos and can tell the assistant to
        // work through them; the assistant checks them off as it goes.
        _buildTasksSection(context),

        // Said before the first keystroke, not after the first Send: with no
        // key the panel used to be indistinguishable from a working one until
        // the button revealed the precondition (audit PS-34).
        if (!_ai.hasAiConfigured && _blockedReasonKey == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: InfoBar(
              key: const ValueKey('test-aichat-needs-key'),
              title: Text(_ai.configRequiredKey.i18n()),
              severity: InfoBarSeverity.info,
              // The dock is at most 360px wide, so the sentence always wraps;
              // the short layout's Wrap has no run spacing and put the button
              // hard against the last line of text.
              isLong: true,
              action: Button(
                onPressed: () => navigateGuarded('settings'),
                child: Text('opensettings-text'.i18n()),
              ),
            ),
          ),

        // Messages
        Expanded(
          child: history.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        FluentIcons.chat,
                        size: 48,
                        color: disabledTextColor(context),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 24.0),
                        child: Text(
                          (_sandbox == null
                                  ? 'ai-assistant-hint'
                                  : 'sandbox-chat-hint-text')
                              .i18n(),
                          style: TextStyle(
                            fontSize: 12,
                            color: secondaryTextColor(context),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      // No Upgrade button here: the FAB that opens this panel
                      // is Pro-only, so the only people who could ever see
                      // one are already Pro (audit PS-39). If the panel needs
                      // a key instead, Send says so inline (PS-34).
                    ],
                  ),
                )
              // The assistant hands out addresses, URLs and commands, and
              // none of the transcript could be selected — the only way out
              // was the copy button on a fenced code block. One selection
              // region over the whole list makes every bubble, tool note and
              // code block drag-selectable and Ctrl/Cmd+C-copyable; the
              // buttons inside keep working because the region only claims
              // drags and text taps. Each entry is a `_TranscriptEntry` so
              // the copied text keeps its line structure.
              : SelectionArea(
                  key: const ValueKey('test-chat-transcript'),
                  child: SelectionContainer(
                    delegate: _selectionDelegate,
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(12),
                      // One extra slot: the reply currently streaming in, drawn
                      // live under the history (plan item 6, streaming).
                      itemCount: history.length + 1,
                      itemBuilder: (context, index) {
                        if (index == history.length) {
                          final live = _ai.streamingText.value;
                          if (!_busy || live.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return _TranscriptEntry(
                              child: _buildMessageBubble(AiMessage(
                            role: 'assistant',
                            content: live,
                            timestamp: DateTime.now(),
                          )));
                        }
                        return _TranscriptEntry(
                            child: _buildMessageBubble(history[index]));
                      },
                    ),
                  ),
                ),
        ),

        // Loading indicator
        if (_busy)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                const SizedBox(width: 16, height: 16, child: ProgressRing()),
                const SizedBox(width: 8),
                // "Generating… · step 12 · 34.5k tokens": a long agent run is
                // visibly moving, not hanging (plan item 3).
                Expanded(
                  child: ValueListenableBuilder<String?>(
                    valueListenable: _ai.runStatus,
                    builder: (context, status, _) => Text(
                      status == null
                          ? 'ai-generating-text'.i18n()
                          : "${'ai-generating-text'.i18n()} · $status",
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: secondaryTextColor(context)),
                    ),
                  ),
                ),
                // Really stops the run — request, tools and auto-continue —
                // not just this panel's spinner (plan item 1).
                Button(
                  key: const ValueKey('test-chat-cancel-request'),
                  onPressed: _cancelRun,
                  child: Text('cancel-text'.i18n()),
                ),
              ],
            ),
          ),

        // Why Send did nothing, said in the panel instead of by navigating
        // away from it (PS-33).
        if (_blockedReasonKey != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: InfoBar(
              key: const ValueKey('test-aichat-blocked'),
              title: Text(_blockedReasonKey!.i18n()),
              severity: InfoBarSeverity.warning,
              isLong: true,
              onClose: _unblock,
              action: Button(
                key: const ValueKey('test-aichat-blocked-action'),
                onPressed: () {
                  if (_blockedRouteName == 'license') {
                    trackUpgradeClick('ai_chat');
                  }
                  navigateGuarded(_blockedRouteName!);
                },
                child: Text(_blockedActionKey!.i18n()),
              ),
            ),
          ),

        // A failed send stays actionable: the exchange is in the transcript
        // and this re-runs it, instead of an expiring toast and a lost turn.
        if (_sendFailed)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: InfoBar(
              key: const ValueKey('test-aichat-failed'),
              title: Text('ai-error-text'.i18n()),
              severity: InfoBarSeverity.error,
              isLong: true,
              onClose: () => setState(() => _sendFailed = false),
              action: Button(
                key: const ValueKey('test-aichat-retry'),
                onPressed: _busy ? null : _retryLast,
                child: Text('retry-text'.i18n()),
              ),
            ),
          ),

        // Input area
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: surfaceBorderColor(context),
                width: 1,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextBox(
                      key: const ValueKey('test-chat-input'),
                      controller: _inputController,
                      focusNode: _inputFocus,
                      placeholder: 'ai-assistant-placeholder'.i18n(),
                      // A question longer than one line was typed into a
                      // one-line box; it grows with the text now, capped so
                      // a pasted log cannot push the transcript out of the
                      // panel.
                      minLines: 1,
                      maxLines: 6,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    key: const ValueKey('test-chat-send'),
                    onPressed:
                        (_inputController.text.trim().isNotEmpty && !_busy)
                            ? _sendMessage
                            : null,
                    child: Text('ai-send-text'.i18n()),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Enter no longer sends, so the box says what does.
              Text(
                'ai-send-hint-text'.i18n([AiChatPanel.sendModifierLabel]),
                style: TextStyle(
                  fontSize: 10,
                  color: secondaryTextColor(context),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _shortSandboxName(String distro) =>
      distro.startsWith(SandboxService.prefix)
          ? distro.substring(SandboxService.prefix.length)
          : distro;

  /// Flyout listing the app assistant, every sandbox chat and the chats
  /// filed away earlier, so a closed conversation can be reopened —
  /// transcripts persist across close/reopen.
  Widget _sessionsButton(BuildContext context) {
    final sandboxes = SandboxService().list();
    final previous = _hasSessions ? _sessions.list() : const <AiChatSession>[];
    if (sandboxes.isEmpty && _sandbox == null && previous.isEmpty) {
      return const SizedBox.shrink();
    }
    // An icon-only button like its clear/close neighbours, not a
    // DropDownButton: the empty title left a stray gap between the history
    // glyph and the chevron (user-reported).
    return FlyoutTarget(
      controller: _sessionsFlyout,
      child: NamedIconButton(
        key: const ValueKey('test-chat-sessions'),
        label: 'ai-sessions-text'.i18n(),
        icon: FluentIcons.history,
        iconSize: 14,
        onPressed: () => _sessionsFlyout.showFlyout(
          builder: (context) => _sessionsMenu(),
        ),
      ),
    );
  }

  MenuFlyout _sessionsMenu() {
    final sandboxes = SandboxService().list();
    final withHistory = SandboxChat.sessions().toSet();
    final previous = _hasSessions ? _sessions.list() : const <AiChatSession>[];
    return MenuFlyout(
      items: [
        MenuFlyoutItem(
          selected: _sandbox == null,
          leading: _sandbox == null
              ? const Icon(FluentIcons.check_mark, size: 12.0)
              : const SizedBox.square(dimension: 12.0),
          text: Text('ai-assistant-title'.i18n()),
          onPressed: () => GlobalVariable.sandboxChat.value = null,
        ),
        if (sandboxes.isNotEmpty) const MenuFlyoutSeparator(),
        for (final distro in sandboxes)
          MenuFlyoutItem(
            selected: _sandbox?.distro == distro,
            leading: _sandbox?.distro == distro
                ? const Icon(FluentIcons.check_mark, size: 12.0)
                : const SizedBox.square(dimension: 12.0),
            text: Text(withHistory.contains(distro)
                ? _shortSandboxName(distro)
                : "${_shortSandboxName(distro)} — "
                    "${'sandbox-session-new-text'.i18n()}"),
            onPressed: () => GlobalVariable.sandboxChat.value = distro,
          ),
        // The chats "New chat" filed away. Reopening one puts the running
        // conversation in their place, so nothing is lost either way.
        if (previous.isNotEmpty) ...[
          const MenuFlyoutSeparator(),
          MenuFlyoutItemBuilder(
            key: const ValueKey('test-chat-history-header'),
            builder: (context) => Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text(
                'ai-chat-history-text'.i18n(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: secondaryTextColor(context),
                ),
              ),
            ),
          ),
          for (final session in previous)
            MenuFlyoutItem(
              key: ValueKey('test-chat-history-${session.id}'),
              leading: const SizedBox.square(dimension: 12.0),
              text: Text(
                session.title.isEmpty
                    ? 'ai-chat-untitled-text'.i18n()
                    : session.title,
                overflow: TextOverflow.ellipsis,
              ),
              onPressed: _busy ? null : () => _openChat(session.id),
            ),
        ],
      ],
    );
  }

  Widget _buildTasksSection(BuildContext context) {
    final items = _todos.items;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          Icon(
            _tasksExpanded ? FluentIcons.chevron_down : FluentIcons.chevron_right,
            size: 10,
            color: secondaryTextColor(context),
          ),
          const SizedBox(width: 6),
          Text('ai-tasks-title'.i18n(),
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
          const SizedBox(width: 6),
          if (items.isNotEmpty)
            Text('${_todos.openCount}/${items.length}',
                style: TextStyle(
                    fontSize: 11, color: secondaryTextColor(context))),
          const Spacer(),
          if (_todos.hasOpen)
            MergeSemantics(
              child: Tooltip(
                message: 'ai-tasks-work-text'.i18n(),
                child: IconButton(
                  key: const ValueKey('test-chat-work-tasks'),
                  icon: const Icon(FluentIcons.play, size: 12),
                  onPressed: _isLoading ? null : _workOnTasks,
                ),
              ),
            ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // HoverButton, not GestureDetector: the header is the only way to
        // fold the queue, and a GestureDetector cannot be reached or
        // activated by keyboard (IA-04 — enforced by keyboard_focus_test).
        HoverButton(
          onPressed: () => setState(() => _tasksExpanded = !_tasksExpanded),
          builder: (context, states) => FocusBorder(
            focused: states.isFocused,
            child: header,
          ),
        ),
        if (_tasksExpanded) ...[
          // Capped: a long queue scrolls inside its own box instead of
          // squeezing the conversation out of the panel.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: Column(children: [
          for (final t in items)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 12, 4),
              child: Row(
                children: [
                  Checkbox(
                    checked: t.done,
                    onChanged: (v) => _todos.setDone(t.id, v ?? false),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      t.text,
                      style: TextStyle(
                        fontSize: 12,
                        decoration:
                            t.done ? TextDecoration.lineThrough : null,
                        color: t.done ? secondaryTextColor(context) : null,
                      ),
                    ),
                  ),
                  MergeSemantics(
                    child: Tooltip(
                      message: 'delete-text'.i18n(),
                      child: IconButton(
                        icon: Icon(FluentIcons.clear,
                            size: 10, color: secondaryTextColor(context)),
                        onPressed: () => _todos.remove(t.id),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextBox(
                    controller: _todoInputController,
                    placeholder: 'ai-tasks-add-hint-text'.i18n(),
                    onSubmitted: (v) {
                      if (v.trim().isNotEmpty) {
                        _todos.add(v);
                        _todoInputController.clear();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 6),
                MergeSemantics(
                  child: Tooltip(
                    message: 'ai-tasks-add-hint-text'.i18n(),
                    child: IconButton(
                  icon: const Icon(FluentIcons.add, size: 12),
                  onPressed: () {
                    final v = _todoInputController.text.trim();
                    if (v.isNotEmpty) {
                      _todos.add(v);
                      _todoInputController.clear();
                    }
                  },
                ),
                  ),
                ),
              ],
            ),
          ),
              ]),
            ),
          ),
        ],
        Container(height: 1, color: surfaceBorderColor(context)),
      ],
    );
  }

  TextStyle get _noteStyle => TextStyle(
        fontSize: 11,
        fontStyle: FontStyle.italic,
        color: secondaryTextColor(context),
      );

  /// A compact note under the assistant's avatar column — not a chat bubble
  /// — for what happened on the machine mid-run.
  Widget _noteChip(IconData icon, Widget body, {Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.only(bottom: 8, left: 36),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 11, color: secondaryTextColor(context)),
            ),
            const SizedBox(width: 6),
            Flexible(child: body),
          ],
        ),
      );

  /// The note left after a run that changed an instance: which snippet holds
  /// its record, with a link into the editor (ai-tasks#77). Checked by name
  /// on every build — against the stored title list, no YAML — so the note
  /// follows a delete made in the editor since: then it says so and the link
  /// goes.
  Widget _buildSnippetNote(String name) {
    final exists = QuickAction().names().contains(name);
    return _noteChip(
      FluentIcons.code,
      exists
          ? Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text('ai-run-snippet-saved-text'.i18n([name]),
                    style: _noteStyle),
                HyperlinkButton(
                  onPressed: () async {
                    final item = QuickAction().byName(name);
                    if (item != null) {
                      await router.pushNamed('snippet', extra: item);
                    }
                    if (mounted) setState(() {});
                  },
                  child: Text('ai-run-snippet-open-text'.i18n(),
                      style: const TextStyle(fontSize: 11)),
                ),
              ],
            )
          : Text('ai-run-snippet-missing-text'.i18n([name]), style: _noteStyle),
      key: ValueKey('test-aichat-snippet-$name'),
    );
  }

  Widget _buildMessageBubble(AiMessage msg) {
    if (msg.role == 'snippet') return _buildSnippetNote(msg.content);
    // A tool note: a compact "ran <tool>" chip, not a chat bubble, so the
    // user can see what the assistant actually did on their machine.
    if (msg.role == 'tool') {
      return _noteChip(
        FluentIcons.processing,
        Text('ai-ran-tool-text'.i18n([msg.content]), style: _noteStyle),
      );
    }
    final isUser = msg.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color:
                    FluentTheme.of(context).accentColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Icon(
                FluentIcons.chat,
                size: 14,
                color: FluentTheme.of(context).accentColor,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isUser
                    ? FluentTheme.of(context)
                        .accentColor
                        .withValues(alpha: 0.15)
                    : subtleFillColor(context),
                borderRadius: BorderRadius.circular(8),
              ),
              child: msg.role == 'assistant'
                  ? MarkdownBody(
                      data: msg.content,
                      // Fenced code blocks get a copy button — the assistant
                      // hands out commands, and retyping them defeats the
                      // point (plan item 6).
                      builders: {'pre': _CodeBlockBuilder(context)},
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(fontSize: 12),
                        code: TextStyle(
                          fontSize: 11,
                          backgroundColor: subtleFillColor(context),
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: subtleFillColor(context),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    )
                  : Text(
                      msg.content,
                      style: const TextStyle(fontSize: 12),
                    ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: subtleFillColor(context),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              // A person glyph — the user avatar rendered as a plus sign
              // (audit PS-37).
              child: Icon(
                FluentIcons.contact,
                size: 14,
                color: secondaryTextColor(context),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  void dispose() {
    _todos.removeListener(_onTodosChanged);
    _ai.transcriptRevision.removeListener(_onTranscriptChanged);
    _sessions.removeListener(_onSessionsChanged);
    _sessionsFlyout.dispose();
    _selectionDelegate.dispose();
    _inputFocus.dispose();
    _inputController.dispose();
    _todoInputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

/// Trims the line break the last entry adds after a select-all.
///
/// Flutter concatenates the selected text of neighbouring widgets with no
/// separator, so a selection across bubbles — or across the paragraphs of one
/// reply — copied as a single run of words. The line breaks are put in by
/// each [_TranscriptEntry]; this outer container only takes back the one an
/// entry adds when it cannot know it is the last.
class _TranscriptSelectionDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final content = super.getSelectedContent();
    final text = content?.plainText;
    if (text == null || !text.endsWith('\n')) return content;
    return SelectedContent(plainText: text.substring(0, text.length - 1));
  }
}

/// One transcript entry as a unit of selection: its paragraphs, tool note or
/// code block copy as separate lines, and it ends with a line break whenever
/// the selection continues into the entry below it.
class _TranscriptEntry extends StatefulWidget {
  const _TranscriptEntry({required this.child});

  final Widget child;

  @override
  State<_TranscriptEntry> createState() => _TranscriptEntryState();
}

class _TranscriptEntryState extends State<_TranscriptEntry> {
  final _EntrySelectionDelegate _delegate = _EntrySelectionDelegate();

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SelectionContainer(delegate: _delegate, child: widget.child);
}

/// Joins an entry's selected paragraphs with line breaks, and remembers on
/// each selection event whether either edge of the selection went past the
/// entry's end — that is what says a line break belongs after it.
class _EntrySelectionDelegate extends StaticSelectionContainerDelegate {
  bool _startBelow = false;
  bool _endBelow = false;

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final result = super.dispatchSelectionEvent(event);
    final below = result == SelectionResult.next;
    switch (event.type) {
      case SelectionEventType.startEdgeUpdate:
        _startBelow = below;
        break;
      case SelectionEventType.endEdgeUpdate:
        _endBelow = below;
        break;
      case SelectionEventType.granularlyExtendSelection:
        _setEdge((event as GranularlyExtendSelectionEvent).isEnd, below);
        break;
      case SelectionEventType.directionallyExtendSelection:
        _setEdge((event as DirectionallyExtendSelectionEvent).isEnd, below);
        break;
      case SelectionEventType.selectAll:
        // Every entry says "more follows"; the transcript trims the last.
        _startBelow = false;
        _endBelow = true;
        break;
      case SelectionEventType.clear:
      case SelectionEventType.selectWord:
      case SelectionEventType.selectParagraph:
        _startBelow = false;
        _endBelow = false;
        break;
    }
    return result;
  }

  void _setEdge(bool isEnd, bool below) {
    if (isEnd) {
      _endBelow = below;
    } else {
      _startBelow = below;
    }
  }

  @override
  SelectedContent? getSelectedContent() {
    final parts = <String>[];
    for (final selectable in selectables) {
      final text = selectable.getSelectedContent()?.plainText;
      if (text != null && text.isNotEmpty) parts.add(text);
    }
    if (parts.isEmpty) return null;
    final continues = _startBelow || _endBelow;
    return SelectedContent(
        plainText: parts.join('\n') + (continues ? '\n' : ''));
  }
}

/// A fenced code block with a copy button in its corner.
///
/// Replaces flutter_markdown's default `pre` rendering; inline code keeps the
/// default style. The copy is acknowledged through the status bar — a silent
/// copy is indistinguishable from a missed click (audit ST-21).
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder(this.context);

  final BuildContext context;

  /// flutter_markdown opens an inline run for the text inside the block and
  /// only closes it once that run holds a child. The default `visitText`
  /// returns none, so the run leaked past the block and the paragraph after
  /// it was appended to the block's run instead of its own; a debug build
  /// fails the builder's `_inlines.isEmpty` assertion on every reply with a
  /// fenced block. The placeholder is discarded with the default rendering
  /// below.
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) =>
      const SizedBox.shrink();

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final code = element.textContent.trimRight();
    return Stack(
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(8, 8, 32, 8),
          decoration: BoxDecoration(
            color: subtleFillColor(context),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            code,
            style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
          ),
        ),
        Positioned(
          top: 6,
          right: 2,
          child: MergeSemantics(
            child: Tooltip(
              message: 'copy-text'.i18n(),
              child: IconButton(
                icon: const Icon(FluentIcons.copy, size: 12),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  Notify.message('copied-text'.i18n(),
                      severity: InfoBarSeverity.success,
                      duration: const Duration(seconds: 2));
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
