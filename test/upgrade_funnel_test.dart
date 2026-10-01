// Every "Upgrade to Pro" button lands on the one licence screen, so a
// pageview of that screen says nothing about which paywall sent the user.
// The click itself has to say so.

import 'package:flutter_test/flutter_test.dart';
import 'package:plausible_analytics/plausible_analytics.dart';
import 'package:wsl2distromanager/components/analytics.dart';

class _Recorder implements Plausible {
  final List<String?> names = [];
  final List<Map<String, String>?> props = [];

  @override
  Future<int> event(
      {String? name,
      String? page,
      Map<String, String>? props,
      String? referrer,
      PlausibleRevenue? revenue,
      bool interactive = true}) async {
    names.add(name);
    this.props.add(props);
    return 200;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Recorder recorder;
  late Plausible real;

  setUp(() {
    real = plausible;
    recorder = _Recorder();
    plausible = recorder;
  });

  tearDown(() => plausible = real);

  test('an upgrade click names the paywall it came from', () {
    trackUpgradeClick('ai_workspace');
    trackUpgradeClick('settings_mcp');

    expect(recorder.names, ['upgrade_clicked', 'upgrade_clicked']);
    expect(recorder.props.map((p) => p!['source']).toList(),
        ['ai_workspace', 'settings_mcp']);
  });

  test('the source is the only thing the event carries', () {
    // No key, no email, nothing that would identify the user: the event is
    // a count per paywall and must stay one.
    trackUpgradeClick('pane');
    expect(recorder.props.single!.keys.toList(), ['source']);
  });
}
