import 'dart:math' as math;

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

  /// The height of every control in the panel — the composer's send/stop
  /// button, the header's actions, the task row's buttons. Each used to
  /// take its own default, so the box, Send and Cancel next to it were three
  /// different heights (user-reported).
  static const double controlSize = 32;

  /// The corner radius those controls share. Containers that hold one of
  /// them (the composer card) add their inset, so the corners stay
  /// concentric.
  static const double controlRadius = 8;

  /// Message bubbles' corner radius; the corner nearest the speaker is
  /// tightened to [controlRadius] / 2 so the bubble points at its side.
  static const double bubbleRadius = 12;

  /// Body text in bubbles and the composer.
  static const double bodyFontSize = 13;

  /// Secondary text: tool chips, task rows, the run status.
  static const double metaFontSize = 12;

  /// The widest the transcript and composer get when the dock is expanded.
  static const double readableWidth = 820;

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
  final FocusNode _todoInputFocus = FocusNode(debugLabel: 'AI task input');
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
    // The cards around the two inputs draw the focus ring themselves.
    _inputFocus.addListener(_onFocusChanged);
    _todoInputFocus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
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
        // Header: one 48px bar, every action the same 32px square. The
        // buttons used to mix 12 and 14px glyphs with 4 and 8px gaps, so the
        // row looked hand-placed (user-reported).
        Container(
          height: 48,
          padding: const EdgeInsets.only(left: 14, right: 8),
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
              // the pair and the action buttons, not inside it. One Expanded
              // rather than a Flexible title beside a Spacer: those split the
              // spare width in half, and the title was cut to "AI Assis…"
              // with room to spare.
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        _sandbox == null
                            ? 'ai-assistant-title'.i18n()
                            : 'sandbox-chat-title'
                                .i18n([_shortSandboxName(_sandbox!.distro)]),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    const BetaBadge(),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              // Start a fresh context without losing the running thread:
              // it is filed under "Previous chats" (ai-tasks#104).
              if (_hasSessions)
                _PanelIconButton(
                  key: const ValueKey('test-chat-new'),
                  label: 'ai-new-chat-text'.i18n(),
                  icon: FluentIcons.add,
                  onPressed: (_busy || history.isEmpty) ? null : _newChat,
                ),
              // Switch between the app assistant, sandbox sessions and the
              // chats filed away earlier — every transcript persists, so any
              // of them can be reopened.
              _sessionsButton(context),
              if (widget.onToggleExpanded != null)
                _PanelIconButton(
                  key: const ValueKey('test-chat-expand'),
                  label: (widget.expanded
                          ? 'ai-chat-collapse-text'
                          : 'ai-chat-expand-text')
                      .i18n(),
                  icon: widget.expanded
                      ? FluentIcons.back_to_window
                      : FluentIcons.full_screen,
                  // The chrome glyphs are drawn larger in the font; 12px
                  // matches the others' optical size.
                  iconSize: 12,
                  onPressed: widget.onToggleExpanded,
                ),
              // No quota counter anymore — chat runs on the user's own API
              // key, so usage is between them and their provider.
              // One mis-click used to erase the whole conversation with no
              // undo, and the control stayed live over an empty history
              // (audit PS-35).
              _PanelIconButton(
                key: const ValueKey('test-chat-clear'),
                label: 'clearchat-text'.i18n(),
                icon: FluentIcons.delete,
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
              if (widget.onClose != null)
                _PanelIconButton(
                  key: const ValueKey('test-chat-close'),
                  label: 'close-text'.i18n(),
                  icon: FluentIcons.chrome_close,
                  iconSize: 12,
                  onPressed: widget.onClose,
                ),
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
                      _AssistantAvatar(
                        size: 48,
                        icon: _sandbox == null
                            ? FluentIcons.chat
                            : FluentIcons.cube_shape,
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32.0),
                        child: Text(
                          (_sandbox == null
                                  ? 'ai-assistant-hint'
                                  : 'sandbox-chat-hint-text')
                              .i18n(),
                          style: TextStyle(
                            fontSize: AiChatPanel.bodyFontSize,
                            height: 1.4,
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
                    child: _readable((gutter) => ListView.builder(
                          controller: _scrollController,
                          padding: EdgeInsets.fromLTRB(gutter, 14, gutter, 6),
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
                        )),
                  ),
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

        // Composer: one card holding the growing input and the send button,
        // which turns into Stop while a run is in flight. Send, the box and
        // a separate Cancel used to sit side by side at three different
        // heights (user-reported).
        _readable((gutter) => Padding(
              padding: EdgeInsets.fromLTRB(gutter - 2, 4, gutter - 2, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_busy)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                      child: Row(
                        children: [
                          const SizedBox.square(
                              dimension: 14,
                              child: ProgressRing(strokeWidth: 2)),
                          const SizedBox(width: 8),
                          // "Generating… · step 12 · 34.5k tokens": a long agent
                          // run is visibly moving, not hanging (plan item 3).
                          Expanded(
                            child: ValueListenableBuilder<String?>(
                              valueListenable: _ai.runStatus,
                              builder: (context, status, _) => Text(
                                status == null
                                    ? 'ai-generating-text'.i18n()
                                    : "${'ai-generating-text'.i18n()} · $status",
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: AiChatPanel.metaFontSize,
                                    color: secondaryTextColor(context)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  _InputCard(
                    focused: _inputFocus.hasFocus,
                    input: _CardTextBox(
                      fieldKey: const ValueKey('test-chat-input'),
                      controller: _inputController,
                      focusNode: _inputFocus,
                      placeholder: 'ai-assistant-placeholder'.i18n(),
                      // A question longer than one line was typed into a
                      // one-line box; it grows with the text now, capped so a
                      // pasted log cannot push the transcript out of the panel.
                      maxLines: 6,
                      onChanged: (_) => setState(() {}),
                    ),
                    // Really stops the run — request, tools and auto-continue —
                    // not just this panel's spinner (plan item 1).
                    action: _busy
                        ? _ComposerButton(
                            buttonKey:
                                const ValueKey('test-chat-cancel-request'),
                            label: 'ai-stop-text'.i18n(),
                            icon: FluentIcons.stop,
                            onPressed: _cancelRun,
                          )
                        : _ComposerButton(
                            buttonKey: const ValueKey('test-chat-send'),
                            label: 'ai-send-text'.i18n(),
                            icon: FluentIcons.send,
                            onPressed: _inputController.text.trim().isNotEmpty
                                ? _sendMessage
                                : null,
                          ),
                  ),
                  const SizedBox(height: 6),
                  // Enter no longer sends, so the box says what does.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'ai-send-hint-text'.i18n([AiChatPanel.sendModifierLabel]),
                      style: TextStyle(
                        fontSize: 11,
                        color: secondaryTextColor(context),
                      ),
                    ),
                  ),
                ],
              ),
            )),
      ],
    );
  }

  /// Expanded over a wide page, a line of text ran 1,500px; the transcript
  /// and the composer keep a readable column centred in it instead.
  Widget _readable(Widget Function(double gutter) builder) => LayoutBuilder(
      builder: (context, constraints) => builder(math.max(
          14.0, (constraints.maxWidth - AiChatPanel.readableWidth) / 2)));

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
      child: _PanelIconButton(
        key: const ValueKey('test-chat-sessions'),
        label: 'ai-sessions-text'.i18n(),
        icon: FluentIcons.history,
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
    final theme = FluentTheme.of(context);
    final header = SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 8),
        child: Row(
          children: [
            Icon(
              _tasksExpanded
                  ? FluentIcons.chevron_down
                  : FluentIcons.chevron_right,
              size: 10,
              color: secondaryTextColor(context),
            ),
            const SizedBox(width: 8),
            Icon(FluentIcons.task_list,
                size: 14, color: secondaryTextColor(context)),
            const SizedBox(width: 8),
            Text('ai-tasks-title'.i18n(),
                style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: AiChatPanel.metaFontSize)),
            const SizedBox(width: 8),
            if (items.isNotEmpty)
              // Open over total, as a count pill rather than loose text.
              Container(
                key: const ValueKey('test-chat-tasks-count'),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: _todos.hasOpen
                      ? theme.accentColor.withValues(alpha: 0.15)
                      : subtleFillColor(context),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('${_todos.openCount}/${items.length}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _todos.hasOpen
                            ? theme.accentColor
                                .defaultBrushFor(theme.brightness)
                            : secondaryTextColor(context))),
              ),
            const Spacer(),
            if (_todos.hasOpen)
              _PanelIconButton(
                key: const ValueKey('test-chat-work-tasks'),
                label: 'ai-tasks-work-text'.i18n(),
                icon: FluentIcons.play,
                iconSize: 12,
                onPressed: _isLoading ? null : _workOnTasks,
              ),
          ],
        ),
      ),
    );

    void addTask() {
      final v = _todoInputController.text.trim();
      if (v.isEmpty) return;
      _todos.add(v);
      _todoInputController.clear();
      setState(() {});
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // HoverButton, not GestureDetector: the header is the only way to
        // fold the queue, and a GestureDetector cannot be reached or
        // activated by keyboard (IA-04 — enforced by keyboard_focus_test).
        HoverButton(
          key: const ValueKey('test-chat-tasks-toggle'),
          onPressed: () => setState(() => _tasksExpanded = !_tasksExpanded),
          builder: (context, states) => FocusBorder(
            focused: states.isFocused,
            child: ColoredBox(
              color: states.isHovered
                  ? subtleFillColor(context)
                  : Colors.transparent,
              child: header,
            ),
          ),
        ),
        if (_tasksExpanded)
          // Capped: a long queue scrolls inside its own box instead of
          // squeezing the conversation out of the panel.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final t in items)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: SizedBox(
                        height: AiChatPanel.controlSize,
                        child: Row(
                          children: [
                            Checkbox(
                              checked: t.done,
                              onChanged: (v) =>
                                  _todos.setDone(t.id, v ?? false),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                t.text,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AiChatPanel.metaFontSize,
                                  decoration: t.done
                                      ? TextDecoration.lineThrough
                                      : null,
                                  color: t.done
                                      ? secondaryTextColor(context)
                                      : null,
                                ),
                              ),
                            ),
                            _PanelIconButton(
                              key: ValueKey('test-chat-task-delete-${t.id}'),
                              label: 'delete-text'.i18n(),
                              icon: FluentIcons.clear,
                              iconSize: 10,
                              onPressed: () => _todos.remove(t.id),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (items.isNotEmpty) const SizedBox(height: 6),
                  _InputCard(
                    focused: _todoInputFocus.hasFocus,
                    input: _CardTextBox(
                      fieldKey: const ValueKey('test-chat-task-input'),
                      controller: _todoInputController,
                      focusNode: _todoInputFocus,
                      placeholder: 'ai-tasks-add-hint-text'.i18n(),
                      maxLines: 1,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => addTask(),
                    ),
                    action: _PanelIconButton(
                      key: const ValueKey('test-chat-task-add'),
                      label: 'ai-tasks-add-hint-text'.i18n(),
                      icon: FluentIcons.add,
                      onPressed: _todoInputController.text.trim().isEmpty
                          ? null
                          : addTask,
                    ),
                  ),
                ],
              ),
            ),
          ),
        Container(height: 1, color: surfaceBorderColor(context)),
      ],
    );
  }

  TextStyle get _noteStyle => TextStyle(
        fontSize: 11.5,
        color: secondaryTextColor(context),
      );

  /// What happened on the machine mid-run, as a compact chip under the
  /// assistant's column — not a chat bubble.
  Widget _noteChip(IconData icon, Widget body, {Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.only(
            bottom: 6, left: _AssistantAvatar.defaultSize + 8),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: subtleFillColor(context),
              border: Border.all(color: surfaceBorderColor(context)),
              borderRadius:
                  BorderRadius.circular(AiChatPanel.controlRadius - 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 11, color: secondaryTextColor(context)),
                const SizedBox(width: 6),
                Flexible(child: body),
              ],
            ),
          ),
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
        FluentIcons.developer_tools,
        Text('ai-ran-tool-text'.i18n([msg.content]),
            overflow: TextOverflow.ellipsis, style: _noteStyle),
      );
    }
    final theme = FluentTheme.of(context);
    final isUser = msg.role == 'user';
    const round = Radius.circular(AiChatPanel.bubbleRadius);
    const tight = Radius.circular(AiChatPanel.controlRadius / 2);
    const body = TextStyle(fontSize: AiChatPanel.bodyFontSize, height: 1.45);
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: isUser
            ? theme.accentColor.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.32 : 0.14)
            : cardFillColor(context),
        border: isUser ? null : Border.all(color: surfaceBorderColor(context)),
        // The corner at the speaker's side is tightened, so the bubble
        // points at who said it — that replaces the user's avatar.
        borderRadius: BorderRadius.only(
          topLeft: isUser ? round : tight,
          topRight: isUser ? tight : round,
          bottomLeft: round,
          bottomRight: round,
        ),
      ),
      child: msg.role == 'assistant'
          ? MarkdownBody(
              data: msg.content,
              // Fenced code blocks get a copy button — the assistant
              // hands out commands, and retyping them defeats the
              // point (plan item 6).
              builders: {'pre': _CodeBlockBuilder(context)},
              styleSheet: MarkdownStyleSheet(
                p: body,
                listBullet: body,
                h1: body.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
                h2: body.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
                h3: body.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                blockSpacing: 8,
                code: TextStyle(
                  fontSize: AiChatPanel.metaFontSize,
                  fontFamily: _CodeBlockBuilder.monoFamily,
                  fontFamilyFallback: _CodeBlockBuilder.monoFallback,
                  backgroundColor: subtleFillColor(context),
                ),
                // [_CodeBlockBuilder] draws the block's box; a second one
                // from the style sheet framed it twice.
                codeblockDecoration: const BoxDecoration(),
                codeblockPadding: EdgeInsets.zero,
              ),
            )
          : Text(msg.content, style: body),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (isUser)
            // Room on the left, so a short question stays a bubble on the
            // right and a long one does not run edge to edge.
            const SizedBox(width: 40)
          else ...[
            _AssistantAvatar(
              icon:
                  _sandbox == null ? FluentIcons.chat : FluentIcons.cube_shape,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(child: bubble),
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
    _inputFocus.removeListener(_onFocusChanged);
    _todoInputFocus.removeListener(_onFocusChanged);
    _inputFocus.dispose();
    _todoInputFocus.dispose();
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

  /// Consolas exists only on Windows; the fallbacks keep code monospaced on
  /// a Mac instead of dropping to the proportional UI font.
  static const String monoFamily = 'Consolas';
  static const List<String> monoFallback = ['Menlo', 'Monaco', 'monospace'];

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
          padding: const EdgeInsets.fromLTRB(10, 9, 36, 9),
          decoration: BoxDecoration(
            color: subtleFillColor(context),
            border: Border.all(color: surfaceBorderColor(context)),
            borderRadius: BorderRadius.circular(AiChatPanel.controlRadius - 2),
          ),
          child: Text(
            code,
            style: const TextStyle(
              fontSize: AiChatPanel.metaFontSize,
              height: 1.4,
              fontFamily: monoFamily,
              fontFamilyFallback: monoFallback,
            ),
          ),
        ),
        Positioned(
          top: 6,
          right: 2,
          child: _PanelIconButton(
            label: 'copy-text'.i18n(),
            icon: FluentIcons.copy,
            iconSize: 12,
            size: 28,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              Notify.message('copied-text'.i18n(),
                  severity: InfoBarSeverity.success,
                  duration: const Duration(seconds: 2));
            },
          ),
        ),
      ],
    );
  }
}

/// The panel's icon-only button: a [AiChatPanel.controlSize] square with the
/// shared corner radius, named through its tooltip.
///
/// [NamedIconButton] with the geometry pinned. fluent's own icon button sizes
/// itself from its glyph and fills a gray square when disabled, which is what
/// made the header's five buttons five different shapes.
class _PanelIconButton extends StatelessWidget {
  const _PanelIconButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.iconSize = 14,
    this.size = AiChatPanel.controlSize,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final double iconSize;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return MergeSemantics(
      child: Tooltip(
        message: label,
        child: SizedBox.square(
          dimension: size,
          child: IconButton(
            icon: Icon(icon, size: iconSize),
            onPressed: onPressed,
            style: ButtonStyle(
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AiChatPanel.controlRadius))),
              backgroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.isDisabled
                      ? Colors.transparent
                      : ButtonThemeData.uncheckedInputColor(theme, states,
                          transparentWhenNone: true)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Send, or Stop while a run is in flight: an accent square inside the
/// composer card, the same size as every other control in the panel.
class _ComposerButton extends StatelessWidget {
  const _ComposerButton({
    required this.buttonKey,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  /// On the [FilledButton] itself, so a finder for it reaches the button
  /// and its onPressed.
  final Key buttonKey;
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Tooltip(
        message: label,
        child: SizedBox.square(
          dimension: AiChatPanel.controlSize,
          child: FilledButton(
            key: buttonKey,
            onPressed: onPressed,
            style: ButtonStyle(
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AiChatPanel.controlRadius))),
            ),
            child: Icon(icon, size: 14),
          ),
        ),
      ),
    );
  }
}

/// A rounded card around a borderless input and one trailing control —
/// the composer and the "add a task" row. The card draws the focus ring, so
/// the input loses fluent's underline.
class _InputCard extends StatelessWidget {
  const _InputCard({
    required this.focused,
    required this.input,
    required this.action,
  });

  final bool focused;
  final Widget input;
  final Widget action;

  /// Space between the card's edge and the control inside it; the card's
  /// radius is the control's plus this, so the corners stay concentric.
  static const double inset = 4;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return AnimatedContainer(
      duration: theme.fasterAnimationDuration,
      padding: const EdgeInsets.all(inset - 1),
      decoration: BoxDecoration(
        color: theme.resources.controlFillColorDefault,
        border: Border.all(
          color: focused
              ? theme.accentColor.defaultBrushFor(theme.brightness)
              : theme.resources.controlStrongStrokeColorDefault
                  .withValues(alpha: 0.35),
        ),
        borderRadius: BorderRadius.circular(AiChatPanel.controlRadius + inset),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: input),
          const SizedBox(width: inset),
          action,
        ],
      ),
    );
  }
}

/// A [TextBox] stripped of its own fill and underline, for an [_InputCard].
class _CardTextBox extends StatelessWidget {
  const _CardTextBox({
    required this.fieldKey,
    required this.controller,
    required this.focusNode,
    required this.placeholder,
    required this.maxLines,
    this.onChanged,
    this.onSubmitted,
  });

  /// On the [TextBox] itself, so a finder for it reaches the box.
  final Key fieldKey;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String placeholder;
  final int maxLines;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextBox(
      key: fieldKey,
      controller: controller,
      focusNode: focusNode,
      placeholder: placeholder,
      minLines: 1,
      maxLines: maxLines,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: const TextStyle(fontSize: AiChatPanel.bodyFontSize, height: 1.4),
      padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
      decoration: const WidgetStatePropertyAll(BoxDecoration(
        color: Colors.transparent,
        border: Border(),
      )),
      foregroundDecoration:
          const WidgetStatePropertyAll(BoxDecoration(border: Border())),
    );
  }
}

/// The assistant's mark beside its replies and in the empty state.
class _AssistantAvatar extends StatelessWidget {
  const _AssistantAvatar({required this.icon, this.size = defaultSize});

  static const double defaultSize = 24;

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final accent = FluentTheme.of(context).accentColor;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(size / 3),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size / 2, color: accent),
    );
  }
}
