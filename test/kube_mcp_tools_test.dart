// The kube_* MCP family (bostrot/ai-tasks#67).
//
// Two things are worth testing here and they pull in opposite directions.
// The tools have to be *useful* — a filtered log, a namespace of pods reduced
// to the broken ones — and they have to be *harmless*: this family exists to
// let an agent read a production cluster, so a test that only checked output
// would miss the whole point. Hence the argv assertions: every command
// kubectl is handed is checked for the verb it carries.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/api/kubernetes/kube_models.dart';
import 'package:wsl2distromanager/api/kubernetes/kube_service.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_tools.dart';
import 'package:wsl2distromanager/api/mcp/wsl_terminal_manager.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'fake_kubectl_shell.dart';
import 'kube_service_test.dart' show kubeConfig, kubeList, deployment;
import 'vm_backend_test.dart' show FakeBackend;

/// One pod as the API server returns it. Local rather than shared with
/// kube_service_test: that one is shaped around parsing edge cases, this one
/// around a readable row, and a fixture serving both would serve neither.
Map<String, Object?> pod(
  String name, {
  String phase = 'Running',
  int ready = 1,
  int total = 1,
  int restarts = 0,
  String node = 'node-1',
}) =>
    {
      'metadata': {
        'name': name,
        'namespace': 'team-prod',
        'creationTimestamp': '2026-09-08T09:00:00Z',
      },
      'spec': {
        'nodeName': node,
        'containers': [for (var i = 0; i < total; i++) {'name': 'c$i'}],
      },
      'status': {
        'phase': phase,
        'containerStatuses': [
          for (var i = 0; i < total; i++)
            {'ready': i < ready, 'restartCount': i == 0 ? restarts : 0},
        ],
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {};
  });

  late FakeKubectlShell shell;
  late Map<String, Future<String> Function(Map<String, dynamic>)> handlers;
  late List<String> names;

  /// The whole command line of every kubectl call, for readable assertions.
  List<String> lines() => shell.calls.map((c) => c.join(' ')).toList();

  String lineContaining(String needle) =>
      lines().firstWhere((l) => l.contains(needle), orElse: () => '');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // The family rides behind the same gate the Kubernetes screen does.
    ExperimentalFeatures.overrideAll = true;
    shell = FakeKubectlShell();
    // Every tool probes for kubectl first, and resolves the current context.
    shell.responses['version --client'] = '{"clientVersion":{}}';
    shell.responses['config view'] = kubeConfig(['prod', 'staging']);
    final backend = FakeBackend();
    final tools = buildWslMcpTools(
      backend,
      WslTerminalManager(wslApi: backend),
      kubeService: KubeService(shell: shell),
    );
    handlers = {for (final t in tools) t.name: t.handler};
    names = tools.map((t) => t.name).toList();
  });

  tearDown(() => ExperimentalFeatures.overrideAll = null);

  group('registration', () {
    test('the whole read-only family is registered', () {
      expect(
          names,
          containsAll([
            'kube_contexts',
            'kube_namespaces',
            'kube_workloads',
            'kube_pods',
            'kube_pod_logs',
            'kube_describe',
            'kube_get',
            'kube_events',
            'kube_top',
          ]));
    });

    test('nothing in the family can change a cluster', () {
      // The guarantee this family is built on, asserted as a list rather than
      // trusted to review: a kube_delete or kube_scale added later fails here
      // before it can ship.
      const readOnly = {
        'kube_contexts',
        'kube_namespaces',
        'kube_workloads',
        'kube_pods',
        'kube_pod_logs',
        'kube_describe',
        'kube_get',
        'kube_events',
        'kube_top',
      };
      expect(names.where((n) => n.startsWith('kube_')), everyElement(isIn(readOnly)));
    });

    test('the family is not registered while Kubernetes is unreleased', () {
      ExperimentalFeatures.overrideAll = false;
      final backend = FakeBackend();
      final hidden =
          buildWslMcpTools(backend, WslTerminalManager(wslApi: backend))
              .map((t) => t.name);
      expect(hidden.where((n) => n.startsWith('kube_')), isEmpty);
      // The rest of the surface is untouched.
      expect(hidden, contains('wsl_list_distros'));
    });
  });

  group('kubectl missing', () {
    test('every tool answers with the install message, never an exception',
        () async {
      shell.exitCodes['version --client'] = 1;
      for (final name in const [
        'kube_contexts',
        'kube_workloads',
        'kube_pods',
        'kube_events',
        'kube_top',
      ]) {
        expect(await handlers[name]!({}), KubeService.noKubectlMessage,
            reason: name);
      }
    });
  });

  group('kube_contexts', () {
    test('lists every context and flags the current one', () async {
      final out = await handlers['kube_contexts']!({});
      expect(out, contains('prod (current)'));
      expect(out, contains('staging'));
      expect(out, contains('namespace team-prod'));
    });

    test('an empty kubeconfig is an answer, not a failure', () async {
      shell.responses['config view'] = kubeConfig([]);
      expect(await handlers['kube_contexts']!({}),
          'The kubeconfig has no contexts.');
    });
  });

  group('context and namespace defaults', () {
    test('an omitted context resolves to the kubeconfig current one',
        () async {
      shell.responses['get deployments'] = kubeList([]);
      await handlers['kube_workloads']!({});
      expect(lineContaining('get deployment'), contains('--context=prod'));
    });

    test('one tool call reads the kubeconfig once', () async {
      // resolveContext hands back the whole KubeContext precisely so that
      // kube_namespaces does not have to read the kubeconfig a second time
      // to find the context's default namespace.
      shell.responses['get namespaces'] = kubeList([]);
      await handlers['kube_namespaces']!({});
      expect(lines().where((l) => l.contains('config view')), hasLength(1));
    });

    test('an explicit context is used verbatim', () async {
      shell.responses['get deployments'] = kubeList([]);
      await handlers['kube_workloads']!({'context': 'staging'});
      expect(lineContaining('get deployment'), contains('--context=staging'));
    });

    test('an omitted namespace passes no namespace flag, so kubectl uses the '
        "context's own", () async {
      shell.responses['get deployments'] = kubeList([]);
      await handlers['kube_workloads']!({});
      final line = lineContaining('get deployment');
      expect(line, isNot(contains('--namespace')));
      expect(line, isNot(contains('--all-namespaces')));
    });

    test('"all" crosses every namespace', () async {
      shell.responses['get deployments'] = kubeList([]);
      await handlers['kube_workloads']!({'namespace': 'all'});
      expect(lineContaining('get deployment'), contains('--all-namespaces'));
    });
  });

  group('kube_workloads', () {
    setUp(() {
      shell.responses['get deployments'] = kubeList([
        deployment('web', ready: 3),
        deployment('api', ready: 0),
        deployment('worker', ready: 1),
      ]);
    });

    test('what needs attention comes first', () async {
      final out = await handlers['kube_workloads']!({});
      final rows = out.split('\n');
      expect(rows.first, contains('api'));
      expect(rows.first, contains('down'));
      expect(rows[1], contains('worker'));
      expect(rows[1], contains('degraded'));
      expect(rows.last, contains('web'));
    });

    test('unhealthy_only drops the healthy ones', () async {
      final out = await handlers['kube_workloads']!({'unhealthy_only': true});
      expect(out, contains('api'));
      expect(out, contains('worker'));
      expect(out, isNot(contains('web ')));
    });

    test('a healthy namespace says so rather than answering empty', () async {
      shell.responses['get deployments'] =
          kubeList([deployment('web', ready: 3)]);
      expect(await handlers['kube_workloads']!({'unhealthy_only': true}),
          'Every workload is healthy.');
    });

    test('name_contains narrows the list', () async {
      final out = await handlers['kube_workloads']!({'name_contains': 'WOR'});
      expect(out, contains('worker'));
      expect(out, isNot(contains('api')));
    });
  });

  group('kube_pods', () {
    setUp(() {
      shell.responses['get pods'] = kubeList([
        pod('web-1', ready: 1, total: 1),
        pod('web-2', ready: 0, total: 1, phase: 'Pending'),
        pod('web-3', ready: 1, total: 1, restarts: 7),
      ]);
    });

    test('reports phase, readiness, restarts and node', () async {
      final out = await handlers['kube_pods']!({});
      expect(out, contains('web-1 Running 1/1 restarts=0'));
      expect(out, contains('web-2 Pending 0/1'));
    });

    test('problems_only keeps the pending and the crash-looping pod',
        () async {
      final out = await handlers['kube_pods']!({'problems_only': true});
      expect(out, contains('web-2'));
      // A pod that is Running but has restarted seven times is exactly the
      // one being looked for, so a plain phase check is not enough.
      expect(out, contains('web-3'));
      expect(out, isNot(contains('web-1 ')));
    });

    test('a selector is passed to kubectl rather than filtered here',
        () async {
      await handlers['kube_pods']!({'selector': 'app=web,tier=front'});
      expect(lineContaining('get pods'),
          contains('--selector=app=web,tier=front'));
    });

    test('a selector with a space is refused before it reaches kubectl',
        () async {
      await expectLater(
          handlers['kube_pods']!({'selector': 'app in (a, b)'}),
          throwsArgumentError);
    });
  });

  group('kube_pod_logs', () {
    setUp(() {
      shell.responses['logs'] = [
        'starting up',
        'ERROR connection refused',
        '  at Db.connect()',
        '  at Main.run()',
        'retrying',
      ].join('\n');
    });

    test('reads every container by default and bounds the tail', () async {
      await handlers['kube_pod_logs']!({'pod': 'web-1'});
      final line = lineContaining('logs');
      expect(line, contains('--all-containers=true'));
      expect(line, contains('--tail=300'));
    });

    test('a named container replaces --all-containers', () async {
      await handlers['kube_pod_logs']!({'pod': 'web-1', 'container': 'app'});
      final line = lineContaining('logs');
      expect(line, contains('--container=app'));
      expect(line, isNot(contains('--all-containers')));
    });

    test('previous reads the terminated container, which is where a crash '
        'loop says why', () async {
      await handlers['kube_pod_logs']!({'pod': 'web-1', 'previous': true});
      expect(lineContaining('logs'), contains('--previous=true'));
    });

    test('since bounds the window', () async {
      await handlers['kube_pod_logs']!({'pod': 'web-1', 'since': '15m'});
      expect(lineContaining('logs'), contains('--since=15m'));
    });

    test('a since that is not a duration never reaches kubectl', () async {
      await expectLater(
          handlers['kube_pod_logs']!({'pod': 'web-1', 'since': 'yesterday'}),
          throwsArgumentError);
      expect(lineContaining('logs'), isEmpty);
    });

    test('contains keeps only the matching lines and says how many', () async {
      final out =
          await handlers['kube_pod_logs']!({'pod': 'web-1', 'contains': 'error'});
      expect(out, startsWith('1 of 5 lines matched "error":'));
      expect(out, contains('ERROR connection refused'));
      expect(out, isNot(contains('starting up')));
    });

    test('context_lines brings the stack frames under the match', () async {
      final out = await handlers['kube_pod_logs']!(
          {'pod': 'web-1', 'contains': 'ERROR', 'context_lines': 2});
      expect(out, contains('at Db.connect()'));
      expect(out, contains('at Main.run()'));
      expect(out, contains('starting up'));
      expect(out, isNot(contains('retrying')));
    });

    test('a filter that matches nothing says so instead of looking quiet',
        () async {
      final out = await handlers['kube_pod_logs']!(
          {'pod': 'web-1', 'contains': 'panic'});
      expect(out, 'No line of 5 matched "panic".');
    });

    test('an unfiltered log comes back whole', () async {
      final out = await handlers['kube_pod_logs']!({'pod': 'web-1'});
      expect(out, contains('starting up'));
      expect(out, contains('retrying'));
      expect(out, isNot(contains('lines matched')));
    });

    test('a pattern is a regular expression, and a broken one is refused',
        () async {
      final out = await handlers['kube_pod_logs']!(
          {'pod': 'web-1', 'pattern': r'at \w+\.'});
      expect(out, contains('at Db.connect()'));
      await expectLater(
          handlers['kube_pod_logs']!({'pod': 'web-1', 'pattern': '('}),
          throwsArgumentError);
    });
  });

  group('kube_get', () {
    test('reads any kind in the format asked for', () async {
      shell.responses['get ingress'] = 'NAME   HOSTS\nweb    example.com';
      final out = await handlers['kube_get']!(
          {'kind': 'ingress', 'output': 'wide'});
      expect(out, contains('example.com'));
      expect(lineContaining('get ingress'), contains('--output=wide'));
    });

    test('the default format is wide', () async {
      shell.responses['get svc'] = 'NAME';
      await handlers['kube_get']!({'kind': 'svc'});
      expect(lineContaining('get svc'), contains('--output=wide'));
    });

    test('a template output is refused: --output also takes a scripting '
        'language, which is far more than a read needs', () async {
      await expectLater(
          handlers['kube_get']!(
              {'kind': 'pods', 'output': 'jsonpath={.items[*]}'}),
          throwsArgumentError);
    });

    test('a kind that could pass for a flag is refused', () async {
      await expectLater(
          handlers['kube_get']!({'kind': '--all-namespaces'}),
          throwsArgumentError);
      expect(lines().where((l) => l.contains(' get ')), isEmpty);
    });

    test('a cluster-scoped kind is read without a namespace flag', () async {
      shell.responses['get nodes'] = 'NAME   STATUS\nnode-1 Ready';
      final out = await handlers['kube_get']!({'kind': 'nodes'});
      expect(out, contains('node-1'));
      expect(lineContaining('get nodes'), isNot(contains('--namespace')));
    });
  });

  group('kube_describe', () {
    test('describes a pod, where the Events section is the answer', () async {
      shell.responses['describe pod'] =
          'Name: web-1\nEvents:\n  Warning  FailedScheduling  insufficient cpu';
      final out =
          await handlers['kube_describe']!({'kind': 'pod', 'name': 'web-1'});
      expect(out, contains('insufficient cpu'));
    });

    test('a name that could pass for a flag is refused', () async {
      await expectLater(
          handlers['kube_describe']!({'kind': 'pod', 'name': '-o=json'}),
          throwsArgumentError);
    });
  });

  group('kube_events', () {
    test('events come back oldest first', () async {
      shell.responses['get events'] = 'LAST SEEN   TYPE      REASON';
      await handlers['kube_events']!({});
      expect(lineContaining('get events'), contains('--sort-by=.lastTimestamp'));
    });

    test('warnings_only asks the API server, not this side', () async {
      shell.responses['get events'] = 'LAST SEEN';
      await handlers['kube_events']!({'warnings_only': true});
      expect(lineContaining('get events'),
          contains('--field-selector=type=Warning'));
    });

    test('a quiet namespace says so', () async {
      shell.responses['get events'] = '';
      expect(await handlers['kube_events']!({'warnings_only': true}),
          'No warning events.');
    });
  });

  group('kube_top', () {
    test('pods are read in a namespace', () async {
      shell.responses['top pods'] = 'NAME    CPU\nweb-1   5m';
      final out = await handlers['kube_top']!({'namespace': 'team-prod'});
      expect(out, contains('web-1'));
      expect(lineContaining('top pods'), contains('--namespace=team-prod'));
    });

    test('nodes are cluster-wide and take no namespace flag', () async {
      shell.responses['top nodes'] = 'NAME     CPU';
      await handlers['kube_top']!({'nodes': true, 'namespace': 'team-prod'});
      final line = lineContaining('top nodes');
      expect(line, isNot(contains('--namespace')));
      expect(line, contains('--context=prod'));
    });

    test("a cluster without metrics-server reports the cluster's own words",
        () async {
      shell.exitCodes['top pods'] = 1;
      shell.errors['top pods'] = 'error: Metrics API not available';
      await expectLater(handlers['kube_top']!({}),
          throwsA(isA<KubeException>().having((e) => e.message, 'message',
              contains('Metrics API not available'))));
    });
  });
}
