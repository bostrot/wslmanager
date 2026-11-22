import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// The destinations that are finished enough to develop against and not
/// finished enough to put in front of everyone by default. Each drives
/// something this app does not own — a container engine, a cluster,
/// somebody else's servers, a first-boot seed, an instance's state as code
/// — so each is off until the user switches it on in Settings, one switch
/// per feature (bostrot/ai-tasks#87). Before that, Containers, Kubernetes
/// and Cloud were visible in a debug run only, and cloud-init and Playbooks
/// had landed unreleased with no gate at all.
enum ExperimentalFeature {
  containers('ExperimentalContainers', 'containers-text',
      'experimental-containers-info-text'),
  kubernetes('ExperimentalKubernetes', 'kubernetes-text',
      'experimental-kubernetes-info-text'),
  cloud('ExperimentalCloud', 'cloud-text', 'experimental-cloud-info-text'),
  cloudInit('ExperimentalCloudInit', 'cloudinit-text',
      'experimental-cloudinit-info-text'),
  playbooks('ExperimentalPlaybooks', 'playbooks-text',
      'experimental-playbooks-info-text');

  const ExperimentalFeature(this.prefKey, this.labelKey, this.infoKey);

  /// Where the opt-in is stored. Absent means "not decided", which
  /// [ExperimentalFeatures.isEnabled] reads as off outside a debug run.
  final String prefKey;

  /// The i18n key of the name the pane entry carries, reused by the switch.
  final String labelKey;

  /// The i18n key of the one line under the switch saying what it opens.
  final String infoKey;

  /// Whether [backend] can carry the feature at all. A switch for a
  /// destination the backend cannot offer would toggle nothing, so the
  /// Settings section leaves it out; the pane applies the same gate.
  bool offeredBy(VmBackend backend) {
    final features = backend.features;
    switch (this) {
      case ExperimentalFeature.containers:
      case ExperimentalFeature.kubernetes:
        // The engine and kubectl run on the host, whatever the backend.
        return true;
      case ExperimentalFeature.cloud:
        // Deploying needs an instance the backend can hand over as a rootfs
        // tarball (bostrot/ai-tasks#62).
        return features.rootfsExport;
      case ExperimentalFeature.cloudInit:
        return features.cloudInit;
      case ExperimentalFeature.playbooks:
        // Scripted commands inside an instance, which remote WSL caps at a
        // couple of KB per command (bostrot/ai-tasks#78).
        return features.quickActions && !backend.isRemote;
    }
  }
}

/// The opt-in state of every [ExperimentalFeature], read wherever one of them
/// surfaces: the nav pane, the router, the Settings sections that belong to
/// one, the MCP tool families, the assistant's prompt and the create pages'
/// cloud-init picker. All of those ask [isVisible]; [isEnabled] alone is the
/// switch itself, for the section that shows it.
class ExperimentalFeatures {
  ExperimentalFeatures._();

  /// Forces every switch on or off at once, over the user's own choices.
  /// For tests, which have to be able to pump both sides of each gate in
  /// one line; null in the app.
  static bool? overrideAll;

  /// Whether the switch for [feature] is on.
  ///
  /// [overrideAll] wins when a test sets it. Otherwise the user's choice,
  /// and with none made, the debug rule the features used to live under: on
  /// in a `flutter run`, off everywhere else. A developer can still switch
  /// one off in Settings to see the shipped side.
  static bool isEnabled(ExperimentalFeature feature) =>
      overrideAll ??
      prefs.getBool(feature.prefKey) ??
      LicenseManager.isDebugRun;

  /// Whether [feature] is both switched on and carried by [backend] — the
  /// active one when none is passed — which is the one condition every
  /// surface of a feature shares.
  static bool isVisible(ExperimentalFeature feature, {VmBackend? backend}) =>
      isEnabled(feature) && feature.offeredBy(backend ?? vmBackend());

  /// Moves on every flip, and notifies. The shell listens to rebuild the
  /// pane at once instead of on the next navigation; the places that build
  /// something from the switches once and keep it — the assistant's tool
  /// list, the MCP server's and the web dashboard's — remember the value
  /// they built at and rebuild when it has moved, so a family switched on
  /// in Settings is callable on the next request rather than after a
  /// restart. The pref stays the single source of truth for the state.
  static final ValueNotifier<int> generation = ValueNotifier(0);

  static void setEnabled(ExperimentalFeature feature, bool value) {
    // Against the stored choice, not [isEnabled]: with the test override
    // set, comparing to the effective value would drop a real flip.
    if (prefs.getBool(feature.prefKey) == value) return;
    prefs.setBool(feature.prefKey, value);
    generation.value++;
  }
}
