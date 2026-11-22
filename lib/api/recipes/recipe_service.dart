import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/recipes/recipe_catalog.dart';
import 'package:wsl2distromanager/api/recipes/service_recipe.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Outcome of applying a [ServiceRecipe] to an instance.
class RecipeResult {
  const RecipeResult({
    required this.ok,
    required this.surface,
    required this.credentials,
    this.error = '',
  });

  final bool ok;

  /// Where the service is reachable (URL or host:port), already resolved to
  /// the right host for the backend.
  final String surface;
  final String credentials;
  final String error;
}

/// Installs [ServiceRecipe]s into instances, backend-agnostically.
///
/// The recipe script is plain Docker-in-a-Linux-box, so it runs the same
/// whether the box is a WSL distro (commands over `wsl.exe`) or a VM
/// (commands over SSH via `vmctl`). The only backend-specific bit is which
/// host address the published ports answer on: a WSL distro shares the
/// host's loopback, a VM has its own IP.
class RecipeService {
  RecipeService({VmBackend? backend}) : _backend = backend ?? vmBackend();

  final VmBackend _backend;

  /// Apply [recipe] to [instance]. The instance must exist and — for a VM —
  /// be running and reachable over SSH.
  Future<RecipeResult> apply(String instance, ServiceRecipe recipe) async {
    try {
      final output = await _backend.execCmdAsRoot(instance, recipe.buildScript());
      if (!output.contains('RECIPE_OK')) {
        return RecipeResult(
          ok: false,
          surface: '',
          credentials: recipe.credentials,
          error: output.trim().isEmpty
              ? 'The install script did not confirm success.'
              : output.trim(),
        );
      }
      return RecipeResult(
        ok: true,
        surface: recipe.surface(await _hostFor(instance)),
        credentials: recipe.credentials,
      );
    } catch (error) {
      return RecipeResult(
        ok: false,
        surface: '',
        credentials: recipe.credentials,
        error: error.toString(),
      );
    }
  }

  /// Prefs key holding a recipe queued at create time, applied on first run.
  static String pendingKey(String instance) => 'PendingRecipe_$instance';

  /// Whether [instance] has a recipe waiting to install.
  static bool hasPending(String instance) =>
      (prefs.getString(pendingKey(instance)) ?? '').isNotEmpty;

  /// Apply the recipe queued for [instance] at create time, if any, and
  /// clear the queue only on success — a not-yet-reachable VM is retried on
  /// the next call. Returns null when nothing was queued.
  Future<RecipeResult?> applyPending(String instance) async {
    final id = prefs.getString(pendingKey(instance)) ?? '';
    if (id.isEmpty) return null;
    final recipe = RecipeCatalog.byId(id);
    if (recipe == null) {
      await prefs.remove(pendingKey(instance));
      return null;
    }
    final result = await apply(instance, recipe);
    if (result.ok) {
      await prefs.remove(pendingKey(instance));
    }
    return result;
  }

  /// The address the instance's published ports answer on from the host.
  Future<String> _hostFor(String instance) async {
    final backend = _backend;
    if (backend is AppleVmApi) {
      final ip = await backend.guestIp(instance);
      if (ip != null && ip.isNotEmpty) return ip;
    }
    // WSL shares the host loopback; a VM with no lease yet falls back to it
    // rather than inventing an address.
    return '127.0.0.1';
  }
}
