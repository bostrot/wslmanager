/// Widget tests for lib/screens/kubernetes_screen.dart — the cluster surface
/// added for bostrot/ai-tasks#61.
///
/// There is no localization delegate here, so `.i18n()` returns the key it was
/// given; asserting on `kubernetes-text` is what proves the label goes through
/// i18n rather than being a hardcoded English string.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plausible_analytics/plausible_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/kubernetes/kube_service.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/screens/kubernetes_screen.dart';

import 'fake_kubectl_shell.dart';
import 'kube_service_test.dart'
    show deployment, deploymentAge, kubeConfig, kubeList;

/// `dialog()` reports a page view, and the real client posts to
/// analytics.bostrot.com.
class _MockPlausible implements Plausible {
  @override
  Future<int> event(
          {String? name,
          String? page,
          Map<String, String>? props,
          String? referrer,
          PlausibleRevenue? revenue,
          bool interactive = true}) async =>
      200;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeKubectlShell shell;
  final messages = <String>[];

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {
      messages.add(msg.toString());
    };
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    plausible = _MockPlausible();
    messages.clear();
    shell = FakeKubectlShell();
    shell.responses['config view'] =
        kubeConfig(['dev', 'prod'], current: 'dev');
    shell.responses['get namespaces'] = kubeList([
      {
        'metadata': {'name': 'default'}
      },
      {
        'metadata': {'name': 'team-dev'}
      },
      {
        'metadata': {'name': 'team-prod'}
      },
    ]);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: KubernetesPage(service: KubeService(shell: shell)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Every command the shell has been handed, one string per call.
  List<String> ran() => shell.calls.map((call) => call.join(' ')).toList();

  /// A row's buttons live inside a collapsed Expander, so nothing under it is
  /// in the tree until the header is tapped.
  Future<void> openRow(WidgetTester tester, String name) async {
    await tester.tap(find.textContaining(name).first);
    await tester.pumpAndSettle();
  }

  testWidgets('a host without kubectl gets an explanation, not an error',
      (tester) async {
    shell.missing.add('kubectl');
    await pump(tester);

    expect(find.byKey(const ValueKey('test-kubernetes-no-kubectl')),
        findsOneWidget);
    expect(find.text('nokubectlhint-text'), findsOneWidget);
  });

  testWidgets('an empty kubeconfig says so rather than showing a blank list',
      (tester) async {
    shell.responses['config view'] = kubeConfig([]);
    await pump(tester);

    expect(find.byKey(const ValueKey('test-kubernetes-no-context')),
        findsOneWidget);
  });

  testWidgets('the kubeconfig current-context is the one selected first',
      (tester) async {
    shell.responses['config view'] =
        kubeConfig(['dev', 'prod'], current: 'prod');
    await pump(tester);

    expect(ran().last, contains('--context=prod'));
    // The context's own namespace, not a hardcoded "default".
    expect(ran().last, contains('--namespace=team-prod'));
  });

  testWidgets("a refused cluster shows the cluster's own message",
      (tester) async {
    shell.exitCodes['get deployments'] = 1;
    shell.errors['get deployments'] =
        'error: You must be logged in to the server (Unauthorized)';
    await pump(tester);

    expect(find.byKey(const ValueKey('test-kubernetes-error')), findsOneWidget);
    expect(find.textContaining('Unauthorized'), findsOneWidget);
    // The pickers survive the failure, so the user can switch to a cluster
    // that does answer instead of being stuck on an error page.
    expect(
        find.byKey(const ValueKey('test-kubernetes-context')), findsOneWidget);
  });

  testWidgets('an empty namespace says so', (tester) async {
    shell.responses['get deployments'] = kubeList([]);
    await pump(tester);
    expect(find.byKey(const ValueKey('test-kubernetes-empty')), findsOneWidget);
  });

  testWidgets('workloads are listed with their health and readiness',
      (tester) async {
    shell.responses['get deployments'] = kubeList([
      deployment('api', namespace: 'team-dev', ready: 3),
      deployment('worker', namespace: 'team-dev', replicas: 2, ready: 0),
    ]);
    await pump(tester);

    expect(find.textContaining('api (healthy-text 3/3)'), findsOneWidget);
    expect(find.textContaining('worker (kubedown-text 0/2)'), findsOneWidget);
    expect(find.text('Deployment · nginx:1.25 · $deploymentAge'), findsWidgets);
  });

  testWidgets('the broken workload is listed above the healthy one',
      (tester) async {
    // Alphabetically "api" comes first; with a hundred rows the one that
    // needs attention has to be at the top instead.
    shell.responses['get deployments'] = kubeList([
      deployment('api', namespace: 'team-dev', ready: 3),
      deployment('zzz-worker', namespace: 'team-dev', replicas: 2, ready: 1),
    ]);
    await pump(tester);

    final broken =
        tester.getTopLeft(find.textContaining('zzz-worker').first).dy;
    final healthy = tester.getTopLeft(find.textContaining('api (').first).dy;
    expect(broken, lessThan(healthy));
  });

  testWidgets('the summary counts what is healthy and what is not',
      (tester) async {
    shell.responses['get deployments'] = kubeList([
      deployment('api', namespace: 'team-dev', ready: 3),
      deployment('worker', namespace: 'team-dev', replicas: 2, ready: 0),
      deployment('cron', namespace: 'team-dev', replicas: 0, ready: 0),
    ]);
    await pump(tester);

    // Three workloads, one healthy, one needing attention — the scaled-to-zero
    // one is neither.
    expect(find.text('kubesummary-text'), findsOneWidget);
  });

  testWidgets('the filter narrows the list without touching the cluster',
      (tester) async {
    shell.responses['get deployments'] = kubeList([
      deployment('api', namespace: 'team-dev'),
      deployment('worker', namespace: 'team-dev'),
    ]);
    await pump(tester);
    final before = shell.calls.length;

    await tester.enterText(
        find.byKey(const ValueKey('test-kubernetes-filter')), 'work');
    await tester.pumpAndSettle();

    expect(find.textContaining('worker ('), findsOneWidget);
    expect(find.textContaining('api ('), findsNothing);
    expect(shell.calls.length, before, reason: 'filtering is local');
  });

  testWidgets('a filter that matches nothing explains itself', (tester) async {
    shell.responses['get deployments'] =
        kubeList([deployment('api', namespace: 'team-dev')]);
    await pump(tester);

    await tester.enterText(
        find.byKey(const ValueKey('test-kubernetes-filter')), 'nothing');
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('test-kubernetes-nomatch')), findsOneWidget);
    expect(find.byKey(const ValueKey('test-kubernetes-empty')), findsNothing);
  });

  testWidgets('switching cluster reloads against the new context',
      (tester) async {
    shell.responses['get deployments'] =
        kubeList([deployment('api', namespace: 'team-dev')]);
    await pump(tester);
    expect(ran().last, contains('--context=dev'));

    await tester.tap(find.byKey(const ValueKey('test-kubernetes-context')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('prod').last);
    await tester.pumpAndSettle();

    expect(ran().last, contains('--context=prod'));
    // The old cluster's namespace does not follow the user across; the new
    // context's own default is used.
    expect(ran().last, contains('--namespace=team-prod'));
  });

  testWidgets('"All namespaces" asks the cluster for all of them',
      (tester) async {
    shell.responses['get deployments'] =
        kubeList([deployment('api', namespace: 'team-dev')]);
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('test-kubernetes-namespace')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('allnamespaces-text').last);
    await tester.pumpAndSettle();

    expect(ran().last, contains('--all-namespaces'));
  });

  testWidgets('pods are only fetched when a row is opened', (tester) async {
    shell.responses['get deployments'] =
        kubeList([deployment('api', namespace: 'team-dev')]);
    shell.responses['get pods'] = kubeList([
      {
        'metadata': {'name': 'api-abc'},
        'spec': {
          'nodeName': 'node-1',
          'containers': [
            {'name': 'app'}
          ]
        },
        'status': {
          'phase': 'Running',
          'containerStatuses': [
            {'ready': true, 'restartCount': 0}
          ],
        },
      },
    ]);
    await pump(tester);

    expect(ran().where((call) => call.contains('get pods')), isEmpty,
        reason: 'a namespace of a hundred apps has thousands of pods');

    await openRow(tester, 'api (');
    expect(find.text('api-abc'), findsOneWidget);
    expect(ran().last, contains('--selector=app=api'));
  });

  testWidgets('restart rolls the workload out', (tester) async {
    shell.responses['get deployments'] =
        kubeList([deployment('api', namespace: 'team-dev')]);
    await pump(tester);

    await openRow(tester, 'api (');
    await tester.tap(find.byKey(const ValueKey('test-workload-restart-api')));
    await tester.pumpAndSettle();

    expect(ran().any((call) => call.contains('rollout restart deployment/api')),
        isTrue);
    expect(messages, contains('restartedworkload-text'));
  });

  testWidgets('an open pod list is refreshed by a restart, not blanked',
      (tester) async {
    // The Expander stays expanded across the reload, so nothing fires
    // onStateChanged a second time — the pods have to be re-fetched by the
    // reload itself or the row goes permanently blank.
    shell.responses['get deployments'] =
        kubeList([deployment('api', namespace: 'team-dev')]);
    shell.responses['get pods'] = kubeList([
      {
        'metadata': {'name': 'api-abc'},
        'spec': {
          'containers': [
            {'name': 'app'}
          ]
        },
        'status': {'phase': 'Running'},
      },
    ]);
    await pump(tester);

    await openRow(tester, 'api (');
    expect(find.text('api-abc'), findsOneWidget);
    final podCalls = ran().where((call) => call.contains('get pods')).length;

    await tester.tap(find.byKey(const ValueKey('test-workload-restart-api')));
    await tester.pumpAndSettle();

    expect(find.text('api-abc'), findsOneWidget);
    expect(ran().where((call) => call.contains('get pods')).length,
        greaterThan(podCalls));
  });

  testWidgets('a DaemonSet is not offered a Scale button', (tester) async {
    // `kubectl scale` refuses a DaemonSet; offering the button and then
    // showing the refusal would be an error about the tool.
    shell.responses['get deployments'] = kubeList([
      {
        'kind': 'DaemonSet',
        'metadata': {'name': 'log-agent', 'namespace': 'team-dev'},
        'spec': {},
        'status': {'desiredNumberScheduled': 3, 'numberReady': 3},
      },
    ]);
    await pump(tester);

    await openRow(tester, 'log-agent');
    expect(find.byKey(const ValueKey('test-workload-restart-log-agent')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-workload-scale-log-agent')),
        findsNothing);
  });

  testWidgets('scale asks for a replica count and refuses a bad one',
      (tester) async {
    shell.responses['get deployments'] =
        kubeList([deployment('api', namespace: 'team-dev')]);
    await pump(tester);

    await openRow(tester, 'api (');
    await tester.tap(find.byKey(const ValueKey('test-workload-scale-api')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextBox).last, 'lots');
    await tester.tap(find.text('scale-text').last);
    await tester.pumpAndSettle();

    // The dialog stays open with a complaint rather than sending nonsense.
    expect(
        find.byKey(const ValueKey('test-dialog-validation')), findsOneWidget);
    expect(ran().any((call) => call.contains('scale ')), isFalse);

    await tester.enterText(find.byType(TextBox).last, '5');
    await tester.tap(find.text('scale-text').last);
    await tester.pumpAndSettle();

    expect(
        ran().any((call) => call.contains('scale deployment/api --replicas=5')),
        isTrue);
  });

  testWidgets('restarting a pod asks first', (tester) async {
    shell.responses['get deployments'] =
        kubeList([deployment('api', namespace: 'team-dev')]);
    shell.responses['get pods'] = kubeList([
      {
        'metadata': {'name': 'api-abc'},
        'spec': {
          'containers': [
            {'name': 'app'}
          ]
        },
        'status': {'phase': 'Running'},
      },
    ]);
    await pump(tester);

    await openRow(tester, 'api (');
    await tester.tap(find.byKey(const ValueKey('test-pod-restart-api-abc')));
    await tester.pumpAndSettle();

    expect(find.text('restartpodbody-text'), findsOneWidget);
    expect(ran().any((call) => call.contains('delete pod')), isFalse);

    await tester.tap(find.text('restart-text').last);
    await tester.pumpAndSettle();

    expect(ran().any((call) => call.contains('delete pod api-abc')), isTrue);
    expect(messages, contains('restartedpod-text'));
  });

  testWidgets('pod logs open in a dialog with the cluster output',
      (tester) async {
    shell.responses['get deployments'] =
        kubeList([deployment('api', namespace: 'team-dev')]);
    shell.responses['get pods'] = kubeList([
      {
        'metadata': {'name': 'api-abc'},
        'spec': {
          'containers': [
            {'name': 'app'}
          ]
        },
        'status': {'phase': 'Running'},
      },
    ]);
    shell.responses['logs'] = 'listening on :8080';
    await pump(tester);

    await openRow(tester, 'api (');
    await tester.tap(find.byKey(const ValueKey('test-pod-logs-api-abc')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-kube-text-dialog')), findsOneWidget);
    expect(find.text('listening on :8080'), findsOneWidget);
    // The pod's own namespace, not the picker's.
    expect(ran().last, contains('--namespace=team-dev'));
  });
}
