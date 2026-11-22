import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/recipes/recipe_catalog.dart';
import 'package:wsl2distromanager/api/recipes/recipe_service.dart';
import 'package:wsl2distromanager/api/recipes/service_recipe.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'vm_backend_test.dart' show FakeBackend;

/// A backend that records the scripts run against it and answers with a
/// canned exec output.
class _RecordingBackend extends FakeBackend {
  final List<String> ran = [];
  String response = 'RECIPE_OK';
  Object? throwOn;

  @override
  Future<String> execCmdAsRoot(String distribution, String cmd) async {
    ran.add(cmd);
    if (throwOn != null) throw throwOn!;
    return response;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('catalog', () {
    test('every recipe has the pieces the UI and tools rely on', () {
      expect(RecipeCatalog.recipes, isNotEmpty);
      final ids = <String>{};
      for (final r in RecipeCatalog.recipes) {
        expect(r.id, isNotEmpty);
        expect(ids.add(r.id), isTrue, reason: 'duplicate recipe id ${r.id}');
        expect(r.image, contains(':'), reason: '${r.id} image needs a tag');
        expect(r.port, greaterThan(0));
        expect(r.containerName, startsWith('wslm-'));
      }
      // The three families the feature promises are all represented.
      for (final cat in RecipeCategory.values) {
        expect(RecipeCatalog.inCategory(cat), isNotEmpty);
      }
    });

    test('byId is case-insensitive and returns null for unknown', () {
      expect(RecipeCatalog.byId('MINIO')?.id, 'minio');
      expect(RecipeCatalog.byId('nope'), isNull);
    });
  });

  group('script', () {
    final minio = RecipeCatalog.byId('minio')!;

    test('installs docker, clears any prior container, and confirms success',
        () {
      final script = minio.buildScript();
      expect(script, contains('command -v docker'));
      expect(script, contains('docker rm -f wslm-minio'));
      expect(script, contains('docker run -d'));
      expect(script, contains('--name wslm-minio'));
      expect(script, contains('echo RECIPE_OK'));
    });

    test('the run line carries ports, env and command', () {
      final line = minio.dockerRunLine;
      expect(line, contains('-p 9001:9001'));
      expect(line, contains('-p 9000:9000'));
      expect(line, contains('-e MINIO_ROOT_USER=minioadmin'));
      expect(line, contains('minio/minio:latest'));
      expect(line, contains('server /data'));
    });

    test('surface is a URL for a dashboard recipe, host:port otherwise', () {
      expect(minio.surface('127.0.0.1'), 'http://127.0.0.1:9001/');
      final postgres = RecipeCatalog.byId('postgres')!;
      expect(postgres.surface('10.0.0.5'), '10.0.0.5:5432');
    });
  });

  group('apply', () {
    test('a script that confirms success reports the surface and creds',
        () async {
      final backend = _RecordingBackend();
      final result = await RecipeService(backend: backend)
          .apply('box', RecipeCatalog.byId('redis')!);
      expect(result.ok, isTrue);
      expect(backend.ran.single, contains('docker run'));
      expect(result.surface, '127.0.0.1:6379');
      expect(result.credentials, isNotEmpty);
    });

    test('a script that does not confirm success is a failure', () async {
      final backend = _RecordingBackend()..response = 'docker: permission denied';
      final result = await RecipeService(backend: backend)
          .apply('box', RecipeCatalog.byId('redis')!);
      expect(result.ok, isFalse);
      expect(result.error, contains('permission denied'));
    });

    test('an exec exception is caught and reported, not thrown', () async {
      final backend = _RecordingBackend()..throwOn = Exception('unreachable');
      final result = await RecipeService(backend: backend)
          .apply('box', RecipeCatalog.byId('redis')!);
      expect(result.ok, isFalse);
      expect(result.error, contains('unreachable'));
    });
  });

  group('pending', () {
    test('a queued recipe applies once and clears only on success', () async {
      final backend = _RecordingBackend();
      final service = RecipeService(backend: backend);
      await prefs.setString(RecipeService.pendingKey('box'), 'postgres');

      expect(RecipeService.hasPending('box'), isTrue);
      final result = await service.applyPending('box');
      expect(result!.ok, isTrue);
      // Cleared, so the next poll does nothing.
      expect(RecipeService.hasPending('box'), isFalse);
      expect(await service.applyPending('box'), isNull);
    });

    test('a failed pending install stays queued for a later retry', () async {
      final backend = _RecordingBackend()..throwOn = Exception('still booting');
      final service = RecipeService(backend: backend);
      await prefs.setString(RecipeService.pendingKey('box'), 'postgres');

      final result = await service.applyPending('box');
      expect(result!.ok, isFalse);
      expect(RecipeService.hasPending('box'), isTrue,
          reason: 'a VM that is not reachable yet must be retried');
    });

    test('an unknown queued id is dropped rather than retried forever',
        () async {
      await prefs.setString(RecipeService.pendingKey('box'), 'ghost');
      final result =
          await RecipeService(backend: _RecordingBackend()).applyPending('box');
      expect(result, isNull);
      expect(RecipeService.hasPending('box'), isFalse);
    });
  });
}
