import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/community_scripts.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/busy_button.dart';
import 'package:wsl2distromanager/components/error_view.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/named_button.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/info_dialog.dart';
import 'package:wsl2distromanager/nav/router.dart';

/// Test seam: replaces the catalogue service (and its network).
CommunityScripts Function() communityScriptsBuilder = () => CommunityScripts();

enum ScriptSort { name, updated }

/// The community script browser.
///
/// Was a 420px-tall modal with a search box and a flat list of names; the
/// catalogue has since grown past fifty entries across four distro families,
/// which a dialog cannot show usefully.
class CommunityPage extends StatefulWidget {
  const CommunityPage({super.key});

  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<CommunityPage> {
  late final CommunityScripts _service;
  late Future<List<CommunityScript>> _future;

  final List<CommunityScript> _scripts = [];
  final Set<String> _selected = {};
  Set<String> _installed = {};

  String _search = '';
  String _distro = '';
  ScriptSort _sort = ScriptSort.name;
  bool _hideInstalled = false;

  bool _downloading = false;
  int _done = 0;
  String _loadError = '';

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'community_scripts');
    _service = communityScriptsBuilder();
    _installed = CommunityScripts.installedNames();
    _future = _load();
  }

  Future<List<CommunityScript>> _load({bool force = false}) async {
    try {
      final scripts = await _service.list(force: force);
      _scripts
        ..clear()
        ..addAll(scripts);
      // Dates arrive after the list is already on screen: the catalogue is
      // useful without them, and they cost one request each.
      unawaited(_service.loadUpdatedDates(scripts).then((_) {
        if (mounted) setState(() {});
      }));
      return scripts;
    } catch (err) {
      _loadError = err.toString();
      rethrow;
    }
  }

  void _refresh() {
    CommunityScripts.clearCache();
    setState(() {
      _loadError = '';
      _selected.clear();
      _future = _load(force: true);
    });
  }

  /// Every distro named by any script, for the filter.
  List<String> get _distroOptions {
    final all = <String>{};
    for (final script in _scripts) {
      all.addAll(script.distros);
    }
    final sorted = all.toList()..sort();
    return sorted;
  }

  List<CommunityScript> get _visible {
    final needle = _search.trim().toLowerCase();
    final list = _scripts.where((script) {
      if (_hideInstalled && _installed.contains(script.name)) return false;
      if (_distro.isNotEmpty &&
          !script.distros.any((d) => d.toLowerCase() == _distro.toLowerCase())) {
        return false;
      }
      if (needle.isEmpty) return true;
      return script.name.toLowerCase().contains(needle) ||
          script.description.toLowerCase().contains(needle) ||
          script.author.toLowerCase().contains(needle);
    }).toList();

    list.sort((a, b) {
      if (_sort == ScriptSort.updated) {
        final da = a.updatedAt, db = b.updatedAt;
        // Unknown dates sort last rather than jumbling in among real ones.
        if (da == null && db == null) return a.name.compareTo(b.name);
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da);
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  Future<void> _install() async {
    if (_downloading || _selected.isEmpty) return;
    final chosen =
        _scripts.where((script) => _selected.contains(script.name)).toList();
    setState(() {
      _downloading = true;
      _done = 0;
    });

    for (final script in chosen) {
      try {
        await _service.install(script);
      } catch (err) {
        if (!mounted) return;
        setState(() => _downloading = false);
        Notify.message('${'snippetdownloadfailed-text'.i18n()} $err',
            severity: InfoBarSeverity.error);
        return;
      }
      if (!mounted) return;
      setState(() => _done++);
    }

    if (!mounted) return;
    setState(() {
      _downloading = false;
      _installed = CommunityScripts.installedNames();
      _selected.clear();
    });
    Notify.message('snippetsdownloaded-text'.i18n(),
        severity: InfoBarSeverity.success);
  }

  /// "3 days ago" / "2 months ago" — relative beats an absolute date here,
  /// where the question is "is this still maintained".
  String _relativeDate(DateTime date) {
    final days = DateTime.now().difference(date).inDays;
    if (days <= 0) return 'updatedtoday-text'.i18n();
    if (days == 1) return 'updatedyesterday-text'.i18n();
    if (days < 30) return 'updateddaysago-text'.i18n(['$days']);
    if (days < 365) {
      return 'updatedmonthsago-text'.i18n(['${(days / 30).floor()}']);
    }
    return 'updatedyearsago-text'.i18n(['${(days / 365).floor()}']);
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('communitysnippetstitle-text'.i18n(),
                    style: FluentTheme.of(context).typography.titleLarge),
                const Spacer(),
                NamedIconButton(
                  key: const ValueKey('test-community-refresh'),
                  label: 'refresh-text'.i18n(),
                  icon: FluentIcons.refresh,
                  onPressed: _downloading ? null : _refresh,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('communitysnippetssubtitle-text'.i18n(),
                style: TextStyle(color: secondaryTextColor(context))),
            const SizedBox(height: 14),
            _filterBar(context),
            const SizedBox(height: 10),
          ],
        ),
      ),
      content: FutureBuilder<List<CommunityScript>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: ProgressRing());
          }
          if (snapshot.hasError) {
            return _errorState(context);
          }
          final visible = _visible;
          if (visible.isEmpty) {
            return Center(
              child: Text('noresultsfound-text'.i18n(),
                  key: const ValueKey('test-community-no-results'),
                  style: TextStyle(color: secondaryTextColor(context))),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: LayoutBuilder(builder: (context, constraints) {
              // Cards stay readable rather than stretching: roughly 320px
              // each, so the grid gains a column as the window grows.
              final columns = (constraints.maxWidth / 320).floor().clamp(1, 4);
              return GridView.builder(
                padding: const EdgeInsets.only(bottom: 16.0),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  mainAxisExtent: 140,
                ),
                itemCount: visible.length,
                itemBuilder: (context, index) =>
                    _scriptCard(context, visible[index]),
              );
            }),
          );
        },
      ),
      bottomBar: _bottomBar(context),
    );
  }

  Widget _filterBar(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 260,
          child: TextBox(
            key: const ValueKey('test-community-search'),
            placeholder: 'search-text'.i18n(),
            prefix: const Padding(
              padding: EdgeInsets.only(left: 8.0),
              child: Icon(FluentIcons.search, size: 12),
            ),
            onChanged: (value) => setState(() => _search = value),
          ),
        ),
        const SizedBox(width: 10),
        ComboBox<String>(
          key: const ValueKey('test-community-distro'),
          value: _distro,
          placeholder: Text('alldistros-text'.i18n()),
          items: [
            ComboBoxItem(value: '', child: Text('alldistros-text'.i18n())),
            for (final distro in _distroOptions)
              ComboBoxItem(value: distro, child: Text(distro)),
          ],
          onChanged: (value) => setState(() => _distro = value ?? ''),
        ),
        const SizedBox(width: 10),
        ComboBox<ScriptSort>(
          key: const ValueKey('test-community-sort'),
          value: _sort,
          items: [
            ComboBoxItem(
                value: ScriptSort.name, child: Text('sortbyname-text'.i18n())),
            ComboBoxItem(
                value: ScriptSort.updated,
                child: Text('sortbyupdated-text'.i18n())),
          ],
          onChanged: (value) =>
              setState(() => _sort = value ?? ScriptSort.name),
        ),
        const SizedBox(width: 10),
        Checkbox(
          checked: _hideInstalled,
          onChanged: (value) =>
              setState(() => _hideInstalled = value ?? false),
          content: Text('hideinstalled-text'.i18n()),
        ),
      ],
    );
  }

  Widget _scriptCard(BuildContext context, CommunityScript script) {
    final installed = _installed.contains(script.name);
    final selected = _selected.contains(script.name);
    final accent = FluentTheme.of(context).accentColor;

    // HoverButton, not GestureDetector: a card is the only way to select a
    // script, and a GestureDetector can be neither focused nor activated by
    // keyboard (IA-04 — enforced by keyboard_focus_test).
    return HoverButton(
      onPressed: installed
          ? null
          : () => setState(() {
                if (!_selected.remove(script.name)) _selected.add(script.name);
              }),
      builder: (context, states) => FocusBorder(
        focused: states.isFocused,
        child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.10)
              : FluentTheme.of(context).cardColor,
          border: Border.all(
            color: selected ? accent : surfaceBorderColor(context),
            width: selected ? 1.4 : 1.0,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    script.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                ),
                if (installed)
                  Icon(FluentIcons.completed_solid,
                      size: 14, color: Colors.successPrimaryColor)
                else if (selected)
                  Icon(FluentIcons.check_mark, size: 14, color: accent),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Text(
                script.description,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12, color: secondaryTextColor(context)),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final distro in script.distros.take(3)) _chip(context, distro),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(FluentIcons.contact, size: 10, color: secondaryTextColor(context)),
                const SizedBox(width: 4),
                // Expanded, not Flexible + Spacer: two flex-1 siblings split
                // the free space evenly, so a short author name left its
                // unused half pushing the date away from the card edge.
                Expanded(
                  child: Text(
                    script.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: secondaryTextColor(context)),
                  ),
                ),
                const SizedBox(width: 8),
                if (script.updatedAt != null)
                  Text(
                    _relativeDate(script.updatedAt!),
                    style: TextStyle(
                        fontSize: 11, color: secondaryTextColor(context)),
                  )
                else
                  Text(
                    'v${script.version}',
                    style: TextStyle(
                        fontSize: 11, color: secondaryTextColor(context)),
                  ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: subtleFillColor(context),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: secondaryTextColor(context))),
    );
  }

  Widget _errorState(BuildContext context) {
    return Center(
      key: const ValueKey('test-community-load-error'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('snippetsloadfailed-text'.i18n(),
                textAlign: TextAlign.center,
                style: TextStyle(color: secondaryTextColor(context))),
            const SizedBox(height: 10),
            Button(
              key: const ValueKey('test-community-retry'),
              onPressed: _refresh,
              child: Text('retry-text'.i18n()),
            ),
            if (_loadError.isNotEmpty) ...[
              const SizedBox(height: 8),
              ErrorDetails(details: _loadError),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
      child: Row(
        children: [
          ClickableUrl(
            clickEvent: "community_actions_url_clicked",
            url: 'https://github.com/bostrot/wsl-scripts#contribute',
            text: 'shareyourquickaction-text'.i18n(),
          ),
          const Spacer(),
          if (_downloading)
            Padding(
              padding: const EdgeInsets.only(right: 12.0),
              child: Text(
                'downloadingsnippets-text'
                    .i18n(['${_done + 1}', '${_selected.length}']),
                key: const ValueKey('test-community-progress'),
                style:
                    TextStyle(fontSize: 12, color: secondaryTextColor(context)),
              ),
            )
          else if (_selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12.0),
              child: Text('nselected-text'.i18n(['${_selected.length}']),
                  style: TextStyle(
                      fontSize: 12, color: secondaryTextColor(context))),
            ),
          Button(
            onPressed: _downloading ? null : () => router.pop(),
            child: Text('close-text'.i18n()),
          ),
          const SizedBox(width: 8),
          BusyButton(
            key: const ValueKey('test-community-install'),
            filled: true,
            label: 'download-text'.i18n(),
            busyLabel: 'downloading-text'.i18n(),
            busy: _downloading,
            onPressed: (_downloading || _selected.isEmpty) ? null : _install,
          ),
        ],
      ),
    );
  }
}
