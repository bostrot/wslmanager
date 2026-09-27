// Live CPU and memory for one instance, with a graph of the last two minutes
// (bostrot/ai-tasks#109).
//
// The disk dialog next door answers "how much room is this taking"; this
// answers "what is it doing right now", which is the question behind a fan
// that will not stop or a machine that has gone slow. Both numbers the user
// needs are in the same reading: what this instance's own processes are
// using, and what the virtual machine around them is using — see
// `api/vm_stats.dart` for why those differ on WSL.
//
// It polls, because CPU is a rate and a rate needs two readings. Nothing
// polls until the dialog is open and everything stops when it closes, which
// is also why there is no live figure on the list row: a per-row poll would
// run a command inside every instance every few seconds for a number nobody
// asked for.

import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/vm_stats.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'dart:async';

/// Opens the resource monitor for [instance].
///
/// [running] is false for a stopped instance: the dialog says so instead of
/// sampling, because reading `/proc` means running a command inside the
/// instance and `wsl.exe` would boot a stopped distro to do it — opening a
/// monitor must not be what starts the thing being monitored.
///
/// [service], [backendId] and [pollInterval] are injected by tests; the
/// dialog otherwise builds them over the host's backend.
Future<void> showVmResourcesDialog(
  String instance, {
  required bool running,
  VmStatsService? service,
  String? backendId,
  Duration pollInterval = const Duration(seconds: 2),
  BuildContext? context,
}) async {
  final host = context ?? GlobalVariable.infobox.currentContext!;
  final VmBackend backend = service?.backend ?? vmBackend();
  await showDialog<void>(
    context: host,
    builder: (_) => VmResourcesDialog(
      instance: instance,
      running: running,
      service: service ?? VmStatsService(backend),
      backendId: backendId ?? backend.backendId,
      pollInterval: pollInterval,
    ),
  );
}

class VmResourcesDialog extends StatefulWidget {
  const VmResourcesDialog({
    super.key,
    required this.instance,
    required this.running,
    required this.service,
    required this.backendId,
    this.pollInterval = const Duration(seconds: 2),
  });

  final String instance;
  final bool running;
  final VmStatsService service;
  final String backendId;
  final Duration pollInterval;

  @override
  State<VmResourcesDialog> createState() => _VmResourcesDialogState();
}

class _VmResourcesDialogState extends State<VmResourcesDialog> {
  /// Readings kept for the graph, oldest first. A minute at the default
  /// interval, the window a task manager shows: long enough to see a build
  /// spin the fans up, short enough that the chart is not mostly empty for
  /// the first minute the dialog is open.
  static const int historyLength = 30;

  final List<VmResourceUsage> _history = [];
  String? _error;
  bool _sampling = false;
  Timer? _timer;

  /// Set once the backend says the instance is not running — at open time or
  /// because it went down while the monitor was watching it. Ends the poll:
  /// there is nothing to read, and probing anyway is what would start it.
  bool _stopped = false;

  VmResourceUsage? get _latest => _history.isEmpty ? null : _history.last;

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'vm_resources_dialog');
    _stopped = !widget.running;
    if (widget.running) {
      _sample();
      _timer = Timer.periodic(widget.pollInterval, (_) => _sample());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    // The baseline belongs to this run of the dialog: reopening it after the
    // instance restarted would otherwise work the first rate out across the
    // reboot.
    widget.service.forget(widget.instance);
    super.dispose();
  }

  /// What went wrong, for the user: the service's own failures carry an i18n
  /// key, anything else is read the way every other error is.
  static String reasonFor(Object error) {
    if (error is VmStatsException && error.message.endsWith('-text')) {
      return error.message.i18n();
    }
    return WslFailure.from(error).shortReason;
  }

  Future<void> _sample() async {
    // A guest slower than the poll interval must not pile up commands.
    if (_sampling) return;
    _sampling = true;
    try {
      final usage = await widget.service.sample(widget.instance);
      if (!mounted) return;
      setState(() {
        _error = null;
        _history.add(usage);
        if (_history.length > historyLength) _history.removeAt(0);
      });
    } on VmStatsNotRunningException {
      if (!mounted) return;
      // Not an error: the instance is down, so the readings stop here and
      // the dialog says why rather than reporting a failure.
      _timer?.cancel();
      _timer = null;
      setState(() {
        _stopped = true;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      // A blip keeps the figures already on screen — a busy guest that
      // missed one poll should not blank the graph it just filled.
      setState(() => _error = reasonFor(error));
    } finally {
      _sampling = false;
    }
  }

  String _percent(double value) =>
      '${value.toStringAsFixed(value >= 10 ? 0 : 1)}%';

  Widget _card({
    required Key key,
    required String title,
    required String value,
    required String detail,
    required List<double> series,
    required int offset,
    required Color color,
  }) {
    final theme = FluentTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6.0),
        border: Border.all(color: surfaceBorderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Name at one end, figure at the other. Both sides are flexible and
          // the space between them is the row's slack: `Expanded` on the
          // name would cap it at half the width and leave the figure
          // floating in the middle, and an unflexed figure would overflow
          // the header the moment a locale spells "measuring…" out in full.
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(title,
                    style: theme.typography.bodyStrong,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              Flexible(
                child: Text(value,
                    key: key,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: theme.typography.subtitle
                        ?.copyWith(color: color, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 2.0),
          Text(detail,
              style:
                  TextStyle(fontSize: 12.0, color: secondaryTextColor(context))),
          const SizedBox(height: 10.0),
          SizedBox(
            height: 56.0,
            width: double.infinity,
            child: CustomPaint(
              painter: UsageGraphPainter(
                values: series,
                capacity: historyLength,
                offset: offset,
                color: color,
                gridColor: surfaceBorderColor(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_stopped) {
      return Text(
          'vmresourcesnotrunning-text'.i18n([distroLabel(widget.instance)]),
          key: const ValueKey('test-vmresources-stopped'),
          style: TextStyle(color: secondaryTextColor(context)));
    }

    final latest = _latest;
    final error = _error;
    if (latest == null) {
      if (error != null) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'vmresourcesfailed-text'.i18n([distroLabel(widget.instance)]),
                key: const ValueKey('test-vmresources-error'),
                style: TextStyle(color: destructiveColor(context))),
            const SizedBox(height: 6.0),
            Text(error,
                style: TextStyle(
                    fontSize: 12.0, color: secondaryTextColor(context))),
          ],
        );
      }
      return Row(children: [
        const SizedBox.square(
            dimension: 16.0, child: ProgressRing(strokeWidth: 2.0)),
        const SizedBox(width: 8.0),
        Text('loading-text'.i18n(),
            key: const ValueKey('test-vmresources-loading')),
      ]);
    }

    final instanceCpu = latest.instanceCpuPercent;
    final guestCpu = latest.guestCpuPercent;
    final cpuSeries = <double>[
      for (final usage in _history)
        if (usage.instanceCpuPercent != null) usage.instanceCpuPercent!
    ];
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card(
            key: const ValueKey('test-vmresources-cpu'),
            title: 'vmresourcescpu-text'.i18n(),
            value: instanceCpu == null
                ? 'vmresourcesmeasuring-text'.i18n()
                : _percent(instanceCpu),
            detail: 'vmresourcescpudetail-text'.i18n([
              guestCpu == null
                  ? 'vmresourcesmeasuring-text'.i18n()
                  : _percent(guestCpu),
              '${latest.cpuCount}',
            ]),
            series: cpuSeries,
            // The first reading has no rate, so the CPU line starts one
            // reading later than the memory line. Both are drawn against the
            // same time axis, so it has to begin one step in rather than at
            // the left edge, or the two charts would disagree about when
            // anything happened.
            offset: _history.length - cpuSeries.length,
            color: FluentTheme.of(context).accentColor,
          ),
          const SizedBox(height: 10.0),
          _card(
            key: const ValueKey('test-vmresources-memory'),
            title: 'vmresourcesmemory-text'.i18n(),
            value: formatBytes(latest.instanceMemoryBytes),
            detail: 'vmresourcesmemorydetail-text'.i18n([
              formatBytes(latest.memoryUsedBytes),
              formatBytes(latest.memoryTotalBytes),
            ]),
            series: [for (final usage in _history) usage.instanceMemoryPercent],
            offset: 0,
            color: Colors.teal,
          ),
          const SizedBox(height: 10.0),
          Text(
            [
              'vmresourcesprocesses-text'.i18n(['${latest.processCount}']),
              if (latest.swapTotalBytes > 0)
                'vmresourcesswap-text'.i18n([
                  formatBytes(latest.swapUsedBytes),
                  formatBytes(latest.swapTotalBytes),
                ]),
            ].join(' · '),
            key: const ValueKey('test-vmresources-footer'),
            style:
                TextStyle(fontSize: 12.0, color: secondaryTextColor(context)),
          ),
          // Only WSL shares one virtual machine between every instance, and
          // that is exactly where the two figures above stop meaning the
          // same thing.
          if (widget.backendId == 'wsl')
            Padding(
              padding: const EdgeInsets.only(top: 12.0),
              child: InfoBar(
                key: const ValueKey('test-vmresources-shared-note'),
                title: Text('vmresourcesshared-text'.i18n()),
                content: Text('vmresourcessharedbody-text'.i18n()),
                severity: InfoBarSeverity.info,
                isLong: true,
              ),
            ),
          // A poll that started failing after the graph filled up: the
          // figures are the last good ones, and saying so beats a frozen
          // chart that looks live.
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12.0),
              child: Text(
                  '${'vmresourcesstale-text'.i18n([distroLabel(widget.instance)])} $error'
                      .trim(),
                  key: const ValueKey('test-vmresources-stale'),
                  style: TextStyle(
                      fontSize: 12.0, color: destructiveColor(context))),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 560.0, maxHeight: 640.0),
      title: Text(
          'vmresourcestitle-text'.i18n([distroLabel(widget.instance)])),
      content: _body(),
      actions: [
        Button(
          key: const ValueKey('test-dialog-cancel'),
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
          child: Text('close-text'.i18n()),
        ),
      ],
    );
  }
}

/// A filled line over [values], each a percentage, on a fixed 0–100 scale.
///
/// Fixed rather than auto-scaled on purpose: a graph whose axis follows its
/// own data draws 3% of one CPU as a mountain range, and the question this
/// answers is how much of the machine is in use, not how the last minute
/// compares with itself. [capacity] is how many readings the width stands
/// for, so a series that is still filling grows in from the left instead of
/// stretching to fit.
class UsageGraphPainter extends CustomPainter {
  const UsageGraphPainter({
    required this.values,
    required this.capacity,
    required this.color,
    required this.gridColor,
    this.offset = 0,
  });

  final List<double> values;
  final int capacity;

  /// How many readings the series starts after the oldest one on screen, so
  /// a chart whose first point arrived late still lines up in time with the
  /// one beside it.
  final int offset;

  final Color color;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1.0;
    // Quarters of the machine, so a glance places the line without an axis.
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (values.isEmpty) return;

    final step = capacity > 1 ? size.width / (capacity - 1) : size.width;
    double xOf(int i) => ((i + offset) * step).clamp(0.0, size.width);
    double yOf(double percent) =>
        size.height - size.height * percent.clamp(0, 100) / 100;

    final line = Path()..moveTo(xOf(0), yOf(values.first));
    for (var i = 1; i < values.length; i++) {
      line.lineTo(xOf(i), yOf(values[i]));
    }

    // A single reading has no line to draw, so it gets a dot; otherwise the
    // first sample renders as an empty chart that looks broken.
    if (values.length == 1) {
      canvas.drawCircle(
          Offset(xOf(0), yOf(values.first)),
          2.0,
          Paint()
            ..color = color
            ..style = PaintingStyle.fill);
      return;
    }

    final area = Path.from(line)
      ..lineTo(xOf(values.length - 1), size.height)
      ..lineTo(xOf(0), size.height)
      ..close();
    canvas.drawPath(
        area,
        Paint()
          ..color = color.withValues(alpha: 0.18)
          ..style = PaintingStyle.fill);
    canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke
          ..isAntiAlias = true);
  }

  @override
  bool shouldRepaint(UsageGraphPainter old) =>
      old.values.length != values.length ||
      old.offset != offset ||
      old.color != color ||
      old.gridColor != gridColor ||
      old.capacity != capacity ||
      (values.isNotEmpty && old.values.last != values.last);
}
