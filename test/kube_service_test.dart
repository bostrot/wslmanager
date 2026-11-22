import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/kubernetes/kube_models.dart';
import 'package:wsl2distromanager/api/kubernetes/kube_service.dart';
import 'package:wsl2distromanager/api/remote_command.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'fake_kubectl_shell.dart';

/// A `kubectl config view -o json` document.
String kubeConfig(List<String> names, {String? current}) => json.encode({
      'current-context': current ?? (names.isEmpty ? '' : names.first),
      'contexts': [
        for (final name in names)
          {
            'name': name,
            'context': {'cluster': '$name-cluster', 'namespace': 'team-$name'},
          },
      ],
    });

/// A `kubectl get <kind> -o json` list.
String kubeList(List<Map<String, Object?>> items) =>
    json.encode({'apiVersion': 'v1', 'kind': 'List', 'items': items});

/// The age a default [deployment] renders with, for tests that assert the
/// row subtitle. A constant beside the fixture, so the two cannot drift.
const String deploymentAge = '7d';

Map<String, Object?> deployment(
  String name, {
  String namespace = 'default',
  int replicas = 3,
  int ready = 3,
  String image = 'nginx:1.25',
  String? created,
}) {
  // Relative to now, never a literal date: the screen prints this age against
  // the wall clock, so a fixed timestamp gives an assertion on it a shelf
  // life. The previous '2026-09-01T10:00:00Z' read as "7d" for one day and
  // turned into "8d" at 10:00 UTC on 2026-09-09 — which the beta job, running
  // at 07:38 UTC, passed and the main job failed, having waited four hours for
  // a macOS runner and started at 12:11 UTC. The extra hour keeps the answer
  // "7d" whenever in the day the job is finally picked up.
  final timestamp = created ??
      DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 7, hours: 1))
          .toIso8601String();
  return {
    'kind': 'Deployment',
    'metadata': {
      'name': name,
      'namespace': namespace,
      'creationTimestamp': timestamp,
    },
    'spec': {
      'replicas': replicas,
      'selector': {
        'matchLabels': {'app': name},
      },
      'template': {
        'spec': {
          'containers': [
            {'name': name, 'image': image},
          ],
        },
      },
    },
    'status': {'readyReplicas': ready},
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeKubectlShell shell;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    shell = FakeKubectlShell();
  });

  KubeService service({Duration? timeout}) => KubeService(
      shell: shell, timeout: timeout ?? const Duration(seconds: 45));

  /// Every command the shell has been handed, one string per call.
  List<String> ran() => shell.calls.map((call) => call.join(' ')).toList();

  const workload = KubeWorkload(
    name: 'api',
    namespace: 'team-a',
    kind: WorkloadKind.deployment,
    desired: 3,
    ready: 3,
  );

  group('installation', () {
    test('a missing kubectl reads as not installed', () async {
      shell.missing.add('kubectl');
      expect(await service().isInstalled(), isFalse);
    });

    test('the client version is asked for, never the server one', () async {
      // `kubectl version` without --client also contacts the API server, so a
      // working kubectl with an unreachable cluster would read as missing.
      await service().isInstalled();
      expect(ran().single, contains('--client'));
    });

    test('the probe is cached until it is invalidated', () async {
      final api = service();
      await api.isInstalled();
      final probes = shell.calls.length;
      await api.isInstalled();
      expect(shell.calls.length, probes);

      api.invalidateInstallCache();
      await api.isInstalled();
      expect(shell.calls.length, greaterThan(probes));
    });
  });

  group('parseContexts', () {
    test('reads every context and flags the current one', () {
      final contexts = KubeService.parseContexts(
          kubeConfig(['dev', 'prod'], current: 'prod'));

      expect(contexts.map((c) => c.name), ['dev', 'prod']);
      expect(contexts.first.cluster, 'dev-cluster');
      expect(contexts.first.namespace, 'team-dev');
      expect(contexts.first.isCurrent, isFalse);
      expect(contexts.last.isCurrent, isTrue);
    });

    test('a context without a namespace falls back to default', () {
      final contexts = KubeService.parseContexts(json.encode({
        'contexts': [
          {
            'name': 'minikube',
            'context': {'cluster': 'minikube'},
          },
        ],
      }));
      expect(contexts.single.namespace, '');
      expect(contexts.single.defaultNamespace, 'default');
    });

    test('output that is not JSON yields no contexts instead of throwing', () {
      // kubectl prints plugin warnings and deprecation notices as plain text.
      expect(KubeService.parseContexts('W0908 plugin not found'), isEmpty);
      expect(KubeService.parseContexts(''), isEmpty);
    });

    test('a cloud context name is shortened for the picker but kept whole', () {
      final contexts = KubeService.parseContexts(
          kubeConfig(['arn:aws:eks:eu-central-1:1234:cluster/prod']));
      expect(contexts.single.label, 'prod');
      expect(
          contexts.single.name, 'arn:aws:eks:eu-central-1:1234:cluster/prod');
    });
  });

  group('parseWorkloads', () {
    test('reads a deployment down to its selector and image', () {
      final workloads =
          KubeService.parseWorkloads(kubeList([deployment('api', ready: 2)]));

      final parsed = workloads.single;
      expect(parsed.name, 'api');
      expect(parsed.namespace, 'default');
      expect(parsed.kind, WorkloadKind.deployment);
      expect(parsed.desired, 3);
      expect(parsed.ready, 2);
      expect(parsed.images, ['nginx:1.25']);
      expect(parsed.selectorArgument, 'app=api');
      expect(parsed.health, WorkloadHealth.degraded);
    });

    test('a DaemonSet counts nodes, not spec replicas', () {
      // A DaemonSet has no spec.replicas at all: only its status knows how
      // many nodes it should be on.
      final workloads = KubeService.parseWorkloads(kubeList([
        {
          'kind': 'DaemonSet',
          'metadata': {'name': 'log-agent', 'namespace': 'kube-system'},
          'spec': {},
          'status': {'desiredNumberScheduled': 5, 'numberReady': 5},
        },
      ]));

      final parsed = workloads.single;
      expect(parsed.kind, WorkloadKind.daemonSet);
      expect(parsed.desired, 5);
      expect(parsed.ready, 5);
      expect(parsed.health, WorkloadHealth.healthy);
      expect(parsed.kind.scalable, isFalse);
    });

    test('a manifest without spec.replicas means one, as the API server says',
        () {
      final workloads = KubeService.parseWorkloads(kubeList([
        {
          'kind': 'Deployment',
          'metadata': {'name': 'api'},
          'spec': {},
          'status': {'readyReplicas': 1},
        },
      ]));
      expect(workloads.single.desired, 1);
      expect(workloads.single.health, WorkloadHealth.healthy);
    });

    test('scaled to zero is not reported as down', () {
      final workloads = KubeService.parseWorkloads(
          kubeList([deployment('api', replicas: 0, ready: 0)]));
      expect(workloads.single.health, WorkloadHealth.scaledToZero);
    });

    test('no ready replicas at all is down', () {
      final workloads = KubeService.parseWorkloads(
          kubeList([deployment('api', replicas: 2, ready: 0)]));
      expect(workloads.single.health, WorkloadHealth.down);
      expect(workloads.single.readiness, '0/2');
    });

    test('the sort order puts what needs attention first', () {
      // Not the enum's declaration order, which reads healthiest-first; and a
      // workload someone parked at zero sits below a healthy one.
      final order = [
        WorkloadHealth.down,
        WorkloadHealth.degraded,
        WorkloadHealth.healthy,
        WorkloadHealth.scaledToZero,
      ]..sort((a, b) => a.attentionRank.compareTo(b.attentionRank));
      expect(order, [
        WorkloadHealth.down,
        WorkloadHealth.degraded,
        WorkloadHealth.healthy,
        WorkloadHealth.scaledToZero,
      ]);
    });

    test('a kind the screen does not list is skipped, not guessed at', () {
      final workloads = KubeService.parseWorkloads(kubeList([
        {
          'kind': 'CronJob',
          'metadata': {'name': 'nightly'},
        },
        deployment('api'),
      ]));
      expect(workloads.map((w) => w.name), ['api']);
    });
  });

  group('parsePods', () {
    Map<String, Object?> pod(String name,
            {String phase = 'Running',
            List<Map<String, Object?>>? statuses,
            String node = 'node-1'}) =>
        {
          'metadata': {
            'name': name,
            'creationTimestamp': '2026-09-08T09:00:00Z',
          },
          'spec': {
            'nodeName': node,
            'containers': [
              {'name': 'app'},
              {'name': 'sidecar'},
            ],
          },
          'status': {
            'phase': phase,
            if (statuses != null) 'containerStatuses': statuses,
          },
        };

    test('counts ready containers and sums restarts', () {
      final pods = KubeService.parsePods(kubeList([
        pod('api-1', statuses: [
          {'ready': true, 'restartCount': 2},
          {'ready': false, 'restartCount': 5},
        ]),
      ]));

      final parsed = pods.single;
      expect(parsed.name, 'api-1');
      expect(parsed.readiness, '1/2');
      expect(parsed.restarts, 7);
      expect(parsed.node, 'node-1');
      expect(parsed.isRunning, isFalse);
    });

    test('a pending pod still shows how many containers it will have', () {
      // Nothing is scheduled yet, so there are no container statuses; the
      // row has to read 0/2 rather than 0/0.
      final pods =
          KubeService.parsePods(kubeList([pod('api-1', phase: 'Pending')]));
      expect(pods.single.readiness, '0/2');
      expect(pods.single.phase, 'Pending');
    });
  });

  group('command shapes', () {
    test('the cluster is a flag, never a kubeconfig the app rewrites',
        () async {
      // `kubectl config use-context` would repoint the user's own terminal.
      await service().workloads(contextName: 'prod', namespace: 'team-a');
      final call = ran().single;
      expect(call, contains('--context=prod'));
      expect(call, contains('--namespace=team-a'));
      expect(call, isNot(contains('use-context')));
      expect(call, contains('deployments,statefulsets,daemonsets'));
    });

    test('all namespaces replaces the namespace flag', () async {
      await service()
          .workloads(contextName: 'prod', namespace: kubeAllNamespaces);
      expect(ran().single, contains('--all-namespaces'));
      expect(ran().single, isNot(contains('--namespace=')));
    });

    test('a pinned kubeconfig is passed to every command', () async {
      final api = service();
      await api.setKubeConfigPath('  /home/dev/clusters.yaml  ');
      await api.workloads(contextName: 'prod', namespace: 'team-a');
      expect(ran().last, contains('--kubeconfig=/home/dev/clusters.yaml'));
    });

    test('no kubeconfig pinned leaves kubectl its own lookup', () async {
      await service().workloads(contextName: 'prod', namespace: 'team-a');
      expect(ran().single, isNot(contains('--kubeconfig')));
    });

    test('pods are fetched by the workload selector', () async {
      await service().pods(
        contextName: 'prod',
        workload: const KubeWorkload(
          name: 'api',
          namespace: 'team-a',
          kind: WorkloadKind.deployment,
          desired: 1,
          ready: 1,
          selector: {'app': 'api'},
        ),
      );
      expect(ran().single, contains('--selector=app=api'));
    });

    test('a workload with no selector never lists the whole namespace',
        () async {
      // An unfiltered `get pods` would put every other team's pods under this
      // workload's row.
      final pods = await service().pods(
        contextName: 'prod',
        workload: workload,
      );
      expect(pods, isEmpty);
      expect(shell.calls, isEmpty);
    });

    test('logs cover every container and are bounded', () async {
      shell.responses['logs'] = 'listening on :8080';
      shell.errors['logs'] = 'warning: config missing';

      final output = await service().podLogs(
          contextName: 'prod', namespace: 'team-a', pod: 'api-abc', lines: 50);

      expect(ran().single, contains('--all-containers=true'));
      expect(ran().single, contains('--tail=50'));
      // A crashing container writes only to stderr; dropping it would show
      // an empty log for the pod the user came to debug.
      expect(output, contains('listening on :8080'));
      expect(output, contains('warning: config missing'));
    });

    test('restart rolls the workload rather than deleting it', () async {
      await service().restart(contextName: 'prod', workload: workload);
      expect(ran().single, contains('rollout restart deployment/api'));
    });

    test('scale passes the replica count through', () async {
      await service()
          .scale(contextName: 'prod', workload: workload, replicas: 5);
      expect(ran().single, contains('scale deployment/api --replicas=5'));
    });

    test('a DaemonSet cannot be scaled', () async {
      const agent = KubeWorkload(
        name: 'log-agent',
        namespace: 'kube-system',
        kind: WorkloadKind.daemonSet,
        desired: 3,
        ready: 3,
      );
      expect(
          () => service()
              .scale(contextName: 'prod', workload: agent, replicas: 2),
          throwsA(isA<ArgumentError>()));
      expect(shell.calls, isEmpty);
    });

    test('a negative replica count never reaches the cluster', () async {
      expect(
          () => service()
              .scale(contextName: 'prod', workload: workload, replicas: -1),
          throwsA(isA<ArgumentError>()));
      expect(shell.calls, isEmpty);
    });
  });

  group('input validation', () {
    test('a name that could pass for a flag is refused', () async {
      final api = service();
      for (final bad in ['--all', '-n', 'api;rm -rf /', '', 'a b', 'API']) {
        expect(
            () =>
                api.podLogs(contextName: 'prod', namespace: 'team-a', pod: bad),
            throwsA(isA<ArgumentError>()),
            reason: '"$bad" must not reach the command line');
      }
      expect(shell.calls, isEmpty);
    });

    test('a namespace is checked as strictly as a name', () async {
      expect(
          () => service()
              .workloads(contextName: 'prod', namespace: '--all-namespaces'),
          throwsA(isA<ArgumentError>()));
      expect(shell.calls, isEmpty);
    });

    test('a real cloud context name is accepted whole', () async {
      // EKS and GKE generate names with colons, slashes and underscores; a
      // name check written for object names would lock those users out.
      for (final name in [
        'arn:aws:eks:eu-central-1:1234:cluster/prod',
        'gke_my-project_europe-west1_cluster-1',
        'Docker-Desktop',
      ]) {
        await service().workloads(contextName: name, namespace: 'default');
        expect(ran().last, contains('--context=$name'));
      }
    });

    test('a context that could pass for a flag is refused', () async {
      expect(
          () => service().workloads(contextName: '-prod', namespace: 'default'),
          throwsA(isA<ArgumentError>()));
      expect(shell.calls, isEmpty);
    });

    test('a non-positive log line count is refused', () async {
      expect(
          () => service().podLogs(
              contextName: 'prod',
              namespace: 'team-a',
              pod: 'api-abc',
              lines: 0),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('failures', () {
    test("a refused cluster surfaces kubectl's own message", () async {
      shell.exitCodes['get deployments'] = 1;
      shell.errors['get deployments'] =
          'error: You must be logged in to the server (Unauthorized)';

      expect(
        () => service().workloads(contextName: 'prod', namespace: 'team-a'),
        throwsA(isA<KubeException>().having((e) => e.message, 'message',
            allOf(contains('exit 1'), contains('Unauthorized')))),
      );
    });

    test('a namespace list the account may not read falls back to its own',
        () async {
      // The common developer case: allowed to work in one namespace, not to
      // enumerate the cluster's. Emptying the screen would be wrong.
      shell.exitCodes['get namespaces'] = 1;
      shell.errors['get namespaces'] =
          'Error from server (Forbidden): namespaces is forbidden';

      final namespaces = await service()
          .namespaces(const KubeContext(name: 'prod', namespace: 'team-a'));
      expect(namespaces, ['team-a']);
    });

    test('a listable cluster reports its namespaces', () async {
      shell.responses['get namespaces'] = kubeList([
        {
          'metadata': {'name': 'default'}
        },
        {
          'metadata': {'name': 'team-a'}
        },
      ]);
      final namespaces = await service()
          .namespaces(const KubeContext(name: 'prod', namespace: 'team-a'));
      expect(namespaces, ['default', 'team-a']);
    });

    test('a hung kubectl is killed, not just stopped being awaited', () async {
      shell.hangs.add('get deployments');
      final api = service(timeout: const Duration(milliseconds: 50));

      await expectLater(
        api.workloads(contextName: 'prod', namespace: 'team-a'),
        throwsA(isA<KubeException>()
            .having((e) => e.message, 'message', contains('did not answer'))),
      );
      expect(shell.started.single.killCount, greaterThan(0));
    });
  });

  test('with a remote WSL target the command runs over ssh', () async {
    SharedPreferences.setMockInitialValues({
      'UseRemoteWSL': true,
      'RemoteWSLTarget': 'user@host',
    });
    prefs = await SharedPreferences.getInstance();

    await service().workloads(contextName: 'prod', namespace: 'team-a');

    final call = shell.calls.last;
    expect(call.first, 'ssh');
    expect(call, contains('user@host'));
    // Everything after the target is the command the host runs, which the
    // remote layer encodes when a token is not shell-neutral — `--context=`
    // is one — so the assertion has to decode it rather than read the argv.
    final hostCommand =
        decodeRemoteCommand(call.sublist(call.indexOf('user@host') + 1));
    expect(hostCommand.first, 'kubectl');
    expect(hostCommand, contains('--context=prod'));
  });

  group('formatKubeAge', () {
    final now = DateTime.utc(2026, 9, 8, 12, 0, 0);

    test('picks the largest unit that still has a digit', () {
      expect(formatKubeAge(now.subtract(const Duration(days: 12)), now: now),
          '12d');
      expect(formatKubeAge(now.subtract(const Duration(hours: 3)), now: now),
          '3h');
      expect(formatKubeAge(now.subtract(const Duration(minutes: 45)), now: now),
          '45m');
      expect(formatKubeAge(now.subtract(const Duration(seconds: 9)), now: now),
          '9s');
    });

    test('an object with no timestamp shows no age', () {
      expect(formatKubeAge(null), '');
    });

    test('a clock skewed ahead of the cluster does not print a negative age',
        () {
      expect(
          formatKubeAge(now.add(const Duration(minutes: 5)), now: now), '0s');
    });
  });

  // The read-only surface the kube_* MCP family sits on
  // (bostrot/ai-tasks#67). What is worth testing here is the argv: every one
  // of these carries a hardcoded read verb, and the assertions below are what
  // stops a later edit from letting a caller's string choose it.
  group('read-only inspection', () {
    test('getResource reads a kind in the format asked for', () async {
      shell.responses['get ingress'] = 'NAME';
      await service().getResource(
          contextName: 'prod',
          namespace: 'team-a',
          kind: 'ingress',
          output: 'json');
      final call = ran().single;
      expect(call, contains('get'));
      expect(call, contains('--output=json'));
      expect(call, contains('--namespace=team-a'));
    });

    test('the empty-namespace shortcut is read-only: a mutating call still '
        'refuses it', () async {
      // Folding kubeNoNamespace into the shared namespace helper would let a
      // workload whose object came back without metadata.namespace fall
      // through to the context's own namespace and delete a same-named pod
      // in the wrong one.
      await expectLater(
          service()
              .deletePod(contextName: 'prod', namespace: '', pod: 'web-1'),
          throwsArgumentError);
      expect(ran(), isEmpty);
    });

    test('a cluster-scoped read passes neither namespace flag', () async {
      shell.responses['get nodes'] = 'NAME';
      await service().getResource(
          contextName: 'prod', namespace: kubeNoNamespace, kind: 'nodes');
      expect(ran().single, isNot(contains('--namespace')));
      expect(ran().single, isNot(contains('--all-namespaces')));
    });

    test('an output format outside the allowlist is refused', () async {
      // `--output` also takes jsonpath= and go-template=, which is a
      // scripting language reached through a flag.
      await expectLater(
          service().getResource(
              contextName: 'prod',
              namespace: 'team-a',
              kind: 'pods',
              output: 'jsonpath={.items[*].spec}'),
          throwsArgumentError);
      expect(ran(), isEmpty);
    });

    test('a kind that could pass for a flag never reaches kubectl', () async {
      await expectLater(
          service().getResource(
              contextName: 'prod', namespace: 'team-a', kind: '-o=json'),
          throwsArgumentError);
      expect(ran(), isEmpty);
    });

    test('a selector with whitespace is refused', () async {
      await expectLater(
          service().podsInNamespace(
              contextName: 'prod',
              namespace: 'team-a',
              selector: 'env in (a, b)'),
          throwsArgumentError);
      expect(ran(), isEmpty);
    });

    test('podsInNamespace lists the namespace rather than one workload',
        () async {
      shell.responses['get pods'] = kubeList([]);
      await service()
          .podsInNamespace(contextName: 'prod', namespace: 'team-a');
      expect(ran().single, isNot(contains('--selector')));
    });

    test('events are sorted oldest first and can be narrowed to warnings',
        () async {
      shell.responses['get events'] = 'LAST SEEN';
      await service().events(
          contextName: 'prod', namespace: 'team-a', warningsOnly: true);
      expect(ran().single, contains('--sort-by=.lastTimestamp'));
      expect(ran().single, contains('--field-selector=type=Warning'));
    });

    test('top nodes is cluster-scoped, top pods is not', () async {
      shell.responses['top'] = 'NAME';
      final api = service();
      await api.top(contextName: 'prod', namespace: 'team-a', nodes: true);
      expect(ran().single, isNot(contains('--namespace')));
      shell.calls.clear();
      await api.top(contextName: 'prod', namespace: 'team-a');
      expect(ran().single, contains('--namespace=team-a'));
    });

    test('describeResource describes any kind', () async {
      shell.responses['describe'] = 'Name: web-1';
      await service().describeResource(
          contextName: 'prod',
          namespace: 'team-a',
          kind: 'pod',
          name: 'web-1');
      expect(ran().single, contains('describe'));
      expect(ran().single, endsWith('web-1'));
    });
  });

  group('podLogs options', () {
    test('a named container replaces --all-containers', () async {
      shell.responses['logs'] = 'line';
      await service().podLogs(
          contextName: 'prod',
          namespace: 'team-a',
          pod: 'web-1',
          container: 'sidecar');
      expect(ran().single, contains('--container=sidecar'));
      expect(ran().single, isNot(contains('--all-containers')));
    });

    test('previous and since are passed through', () async {
      shell.responses['logs'] = 'line';
      await service().podLogs(
          contextName: 'prod',
          namespace: 'team-a',
          pod: 'web-1',
          previous: true,
          since: '2h',
          timestamps: true);
      final call = ran().single;
      expect(call, contains('--previous=true'));
      expect(call, contains('--since=2h'));
      expect(call, contains('--timestamps=true'));
    });

    test('a since that is not a duration is refused before the call',
        () async {
      await expectLater(
          service().podLogs(
              contextName: 'prod',
              namespace: 'team-a',
              pod: 'web-1',
              since: '; rm -rf /'),
          throwsArgumentError);
      expect(ran(), isEmpty);
    });

    test('a container name that could pass for a flag is refused', () async {
      await expectLater(
          service().podLogs(
              contextName: 'prod',
              namespace: 'team-a',
              pod: 'web-1',
              container: '--previous'),
          throwsArgumentError);
      expect(ran(), isEmpty);
    });
  });
}
