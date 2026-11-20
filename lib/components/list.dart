import 'dart:async';

import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/recipes/recipe_service.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:wsl2distromanager/components/ai_diagnosis.dart';
import 'package:wsl2distromanager/components/error_view.dart';
import 'package:wsl2distromanager/components/named_button.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/dialogs.dart';
import 'package:wsl2distromanager/nav/router.dart';
import 'list_item.dart';
import 'helpers.dart';

/// The widget of distros in the main page. This is being refreshed every 5
/// seconds using the reloadEvery5Seconds() function.
class DistroList extends StatefulWidget {
  const DistroList({super.key, required this.api});

  final VmBackend api;

  @override
  DistroListState createState() => DistroListState();
}

/// From this many instances on, the list gets a name filter. Below it every
/// row is already on screen and the box would only push them down.
const kInstanceFilterThreshold = 6;

/// The instances whose name contains [query], ignoring case and the
/// surrounding whitespace. An empty query keeps them all.
List<String> filterInstances(List<String> names, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return names;
  return names.where((n) => n.toLowerCase().contains(needle)).toList();
}

class DistroListState extends State<DistroList> {
  Map<String, bool> hover = {};
  bool isSyncing = false;
  bool showDocker = false;
  int reloadTick = 0;

  void syncing(var item) {
    if (mounted) {
      setState(() {
        isSyncing = item;
      });
    }
  }

  void init() async {
    await initPrefs();
    // Get shared prefs for showing docker containers
    showDocker = prefs.getBool('showDocker') ?? false;
    if (mounted) {
      setState(() {});
    }
    reloadEvery5Seconds();
  }

  @override
  void initState() {
    init();
    super.initState();
  }

  // Lives here, not in the builder: the 5s poll rebuilds the rows, and the
  // typed filter has to survive every one of those rebuilds.
  final TextEditingController _filterController = TextEditingController();
  String _filter = '';

  void _setFilter(String value) {
    if (_filterController.text != value) _filterController.text = value;
    setState(() => _filter = value);
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  Widget _filterBox() {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0, left: 12.0, right: 12.0),
      // Escape clears, like every other search box on Windows.
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              _setFilter(''),
        },
        child: TextBox(
          key: const ValueKey('test-instance-filter'),
          controller: _filterController,
          placeholder: 'filterinstances-text'.i18n(),
          prefix: const Padding(
            padding: EdgeInsets.only(left: 8.0),
            child: Icon(FluentIcons.filter, size: 12),
          ),
          suffix: _filter.isEmpty
              ? null
              : NamedIconButton(
                  key: const ValueKey('test-instance-filter-clear'),
                  label: 'clear-text'.i18n(),
                  icon: FluentIcons.cancel,
                  iconSize: 10,
                  onPressed: () => _setFilter(''),
                ),
          onChanged: (value) => setState(() => _filter = value),
        ),
      ),
    );
  }

  /// Instances whose pending recipe is being installed right now, so the 5s
  /// poll does not launch a second install over the first.
  final Set<String> _installingRecipes = {};

  /// For each running instance with a recipe queued at create time, install
  /// it once and clear the queue on success (a not-yet-reachable VM retries
  /// on a later poll). Fire-and-forget: a slow docker pull must not block
  /// the list from rendering.
  void _installPendingRecipes(List<String> running) {
    for (final instance in running) {
      if (_installingRecipes.contains(instance)) continue;
      if (!RecipeService.hasPending(instance)) continue;
      _installingRecipes.add(instance);
      () async {
        try {
          Notify.message('installingservice-text'.i18n([instance]),
              loading: true);
          final result =
              await RecipeService(backend: widget.api).applyPending(instance);
          if (result == null) return;
          Notify.message(
              result.ok
                  ? 'installedservice-text'.i18n([instance, result.surface])
                  : 'installservicefailed-text'.i18n([instance, result.error]),
              severity: result.ok
                  ? InfoBarSeverity.success
                  : InfoBarSeverity.warning);
        } finally {
          _installingRecipes.remove(instance);
        }
      }();
    }
  }

  /// Consecutive [VmBackend.list] failures. One blip — a helper briefly
  /// starved while a VM image is being copied, a wsl.exe hiccup — must not
  /// replace the whole page with an error view when a known-good list
  /// exists; only a persistent failure earns that.
  int _listFailureStreak = 0;

  Future<Instances> _listWithGrace() async {
    try {
      final result = await widget.api.list(showDocker);
      _listFailureStreak = 0;
      return result;
    } catch (_) {
      _listFailureStreak++;
      final cached = widget.api.lastDistroList;
      if (_listFailureStreak < 3 && cached.all.isNotEmpty) {
        return cached;
      }
      rethrow;
    }
  }

  void reloadEvery5Seconds() async {
    for (;;) {
      await Future.delayed(const Duration(seconds: 5));
      // A disposed state must also stop the loop — before, every visit to
      // the home page left another eternal timer chain behind.
      if (!mounted) return;
      setState(() {
        reloadTick++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final remoteEnabled = widget.api.isRemote;
    final remoteTarget = widget.api.remoteLabel;

    // List as FutureBuilder with WSLApi
    return FutureBuilder<Instances>(
      key: const ValueKey('test-distro-list'),
      future: _listWithGrace(),
      initialData: GlobalVariable.initialSnapshot,
      builder: (context, snapshot) {
        // Update every 20 seconds
        if (snapshot.hasData) {
          GlobalVariable.initialSnapshot = snapshot.data;
          List<Widget> newList = [];
          List<String> list = snapshot.data?.all ?? [];
          List<String> running = snapshot.data?.running ?? [];
          // A service chosen at create time installs the first time its
          // instance is running (a VM has to boot first).
          _installPendingRecipes(running);
          // Check if there are distros
          if (list.isEmpty) {
            // Two unrelated states used to share one sentence written from
            // the code's point of view — "No instances found or there is a
            // migration in progress" (audit LN-22). A move leaves its marker
            // in prefs, so the ordinary first-run state can speak to a new
            // user instead.
            final moving = prefs.getString('MoveOp_Distro') != null;
            // The CTA sits under the sentence that motivates it. Pinned to
            // the bottom-right corner it shared ~44x28px with the AI chat
            // FAB, which covered exactly the spot a user clicks after
            // reading "no instances found" (audit LN-21).
            return Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text((moving
                            ? 'moveinprogress-text'
                            : 'noinstancesfound-text')
                        .i18n()),
                    if (!moving) ...[
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () {
                          router.pushNamed('addinstance');
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(FluentIcons.add),
                            const SizedBox(width: 8),
                            Text('addinstance-text'.i18n()),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }
          // Check if WSL is installed
          if (list[0] == 'wslNotInstalled') {
            return const InstallDialog();
          }
          // Kept while a query is typed, so deleting instances down to
          // below the threshold cannot strand a filter nobody can clear.
          final showFilter =
              list.length >= kInstanceFilterThreshold || _filter.isNotEmpty;
          final visible = showFilter ? filterInstances(list, _filter) : list;
          for (String item in visible) {
            newList.add(ListItem(
              // A row holds its instance's busy and sync state; filtering
              // moves rows, and an unkeyed one would hand that state to
              // whichever instance slid into its slot.
              key: ValueKey('instance-row-$item'),
              item: item,
              running: running,
              trailing: widget.api.instanceMetaLabel(item),
            ));
          }
          final rows = ListView.custom(
            childrenDelegate: SliverChildListDelegate(newList),
          );
          if (!showFilter) return Expanded(child: rows);
          return Expanded(
            child: Column(
              children: [
                _filterBox(),
                Expanded(
                  child: visible.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'filternomatch-text'.i18n([_filter.trim()]),
                                key: const ValueKey(
                                    'test-instance-filter-empty'),
                              ),
                              const SizedBox(height: 12),
                              Button(
                                onPressed: () => _setFilter(''),
                                child: Text('clearfilter-text'.i18n()),
                              ),
                            ],
                          ),
                        )
                      : rows,
                ),
              ],
            ),
          );
        } else if (snapshot.hasError) {
          // Not `snapshot.error.toString()`: that put `Exception: <localized
          // WSL prose>` on the page and offered a Retry that could only fail
          // the same way. The sentence is translated and mapped from the
          // stable error code; the raw text keeps its place underneath, and a
          // remote failure gets the one remedy that actually changes the
          // outcome — going back to the local WSL (audit LN-17, LN-18).
          final failure = WslFailure.from(snapshot.error);
          return Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ErrorBody(
                      failure: failure,
                      leading: remoteEnabled
                          ? 'listfailedremote-text'.i18n([
                              remoteTarget.isEmpty
                                  ? 'remotenotset-text'.i18n()
                                  : remoteTarget
                            ])
                          : (widget.api.backendId == 'wsl'
                                  ? 'listfailed-text'
                                  : 'listfailed-vm-text')
                              .i18n(),
                      hint: remoteEnabled
                          ? 'listfailedremotehint-text'.i18n()
                          : (widget.api.backendId == 'wsl'
                                  ? 'listfailedhint-text'
                                  : 'listfailedhint-vm-text')
                              .i18n(),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (remoteEnabled)
                          Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: FilledButton(
                              key: const ValueKey('test-list-use-local'),
                              onPressed: () async {
                                await prefs.setBool('UseRemoteWSL', false);
                                if (mounted) {
                                  setState(() {
                                    reloadTick++;
                                  });
                                }
                              },
                              child: Text('uselocalwsl-text'.i18n()),
                            ),
                          ),
                        Button(
                          key: const ValueKey('test-list-retry'),
                          onPressed: () {
                            if (mounted) {
                              setState(() {
                                reloadTick++;
                              });
                            }
                          },
                          child: Text('retry-text'.i18n()),
                        ),
                        const SizedBox(width: 8),
                        AiDiagnoseButton(errorMessage: failure.details),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        // By default, show a loading spinner.
        //
        // `Expanded`, like the data and error branches: a bare `Padding` has
        // no height to centre within, so the spinner drew at y=90 and the
        // error that replaced it at y=420 — 330 px of jump when the load
        // resolved (audit LN-20).
        return Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ProgressRing(),
                if (remoteEnabled) ...[
                  const SizedBox(height: 10),
                  Text('connectingtoremote-text'.i18n([
                    remoteTarget.isEmpty ? 'remotenotset-text'.i18n() : remoteTarget
                  ])),
                  const SizedBox(height: 12),
                  // `getSshClientOptions` sets no ConnectTimeout, so an
                  // unreachable host holds this for the OS default TCP
                  // timeout. Going back to the local WSL is the one action
                  // that ends the wait, and it is the same remedy the error
                  // branch offers.
                  Button(
                    key: const ValueKey('test-list-loading-use-local'),
                    onPressed: () async {
                      await prefs.setBool('UseRemoteWSL', false);
                      if (mounted) {
                        setState(() {
                          reloadTick++;
                        });
                      }
                    },
                    child: Text('uselocalwsl-text'.i18n()),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
