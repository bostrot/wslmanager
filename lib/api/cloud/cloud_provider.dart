// The provider-independent surface the cloud screen and the deploy service
// talk to.
//
// Unlike containers and Kubernetes, there is no CLI on the host to shell out
// to here: `hcloud` is an optional extra almost nobody has installed, and a
// provider's REST API is stable, documented and versioned in a way its CLI's
// output format is not. So this one layer speaks HTTP, and everything a
// provider does that is not "create/list/delete a machine" — the deploy
// itself — stays out of it and lives in [CloudDeployService] over plain SSH.

import 'package:wsl2distromanager/api/cloud/cloud_models.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Preference key holding the provider the user configured.
const String cloudProviderPrefKey = 'CloudProvider';

/// Preference key prefix for a provider's API token, e.g.
/// `CloudToken_hetzner`. One key per provider so switching between two
/// accounts does not mean typing a token again.
const String cloudTokenPrefKeyPrefix = 'CloudToken_';

/// The preference key holding [provider]'s API token.
String cloudTokenPrefKey(CloudProviderId provider) =>
    '$cloudTokenPrefKeyPrefix${provider.id}';

/// Read [provider]'s stored API token, or '' when there is none.
String cloudToken(CloudProviderId provider) {
  try {
    return prefs.getString(cloudTokenPrefKey(provider))?.trim() ?? '';
  } catch (_) {
    // Preferences not initialised (tests, early startup).
    return '';
  }
}

/// The provider the user configured, defaulting to the first one. Only ever
/// null-free: a stale value falls back rather than leaving the screen blank.
CloudProviderId activeCloudProviderId() {
  try {
    return CloudProviderId.byId(prefs.getString(cloudProviderPrefKey)) ??
        CloudProviderId.values.first;
  } catch (_) {
    return CloudProviderId.values.first;
  }
}

/// One cloud account, as far as this app needs it.
///
/// Deliberately small: create a machine, look at the machines, power them,
/// delete them. Networks, volumes, firewalls, load balancers and floating IPs
/// are the provider console's job — the same line the Containers screen draws
/// at "we drive what exists, we are not a second control panel".
abstract class CloudProvider {
  CloudProviderId get id;

  /// The account's servers, newest first.
  Future<List<CloudServer>> listServers();

  /// One server by id, for polling a create through to `running`.
  Future<CloudServer> getServer(String serverId);

  /// Server types, locations and images the account may use.
  Future<CloudCatalogue> catalogue();

  /// SSH keys already registered with the provider.
  Future<List<CloudSshKey>> listSshKeys();

  /// Register [publicKey] under [name], returning the stored key. Providers
  /// reject a duplicate key, so callers match on fingerprint first.
  Future<CloudSshKey> createSshKey(String name, String publicKey);

  /// Create a server and return it as the provider first reports it —
  /// usually `initializing` with no address yet, which is what
  /// [CloudDeployService] polls [getServer] for.
  Future<CloudServer> createServer({
    required String name,
    required String serverType,
    required String image,
    required String location,
    List<String> sshKeyIds = const [],
    String userData = '',
    Map<String, String> labels = const {},
  });

  /// Power a server on.
  Future<void> powerOn(String serverId);

  /// Power a server off. Graceful (ACPI) rather than pulling the plug.
  Future<void> powerOff(String serverId);

  /// Delete a server permanently. It stops being billed; its disk is gone.
  Future<void> deleteServer(String serverId);

  /// Cheap call that fails when the token is wrong, so the setup form can
  /// tell "bad token" from "no servers yet".
  Future<void> verifyToken();
}
