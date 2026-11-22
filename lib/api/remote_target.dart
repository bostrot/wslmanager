// Shared validation for remote WSL SSH targets (format "user@host" or
// "host"). Used by WSLApi, MountService, and the settings screen — kept in
// one place so the three can't drift out of sync with each other.

final RegExp remoteTargetPattern =
    RegExp(r'^(?:(?!-)[A-Za-z0-9._-]+@)?(?!-)[A-Za-z0-9._:-]+$');

/// Whether [target] is a well-formed SSH target ("user@host" or "host").
bool isValidRemoteTarget(String target) {
  final trimmed = target.trim();
  return trimmed.isNotEmpty && remoteTargetPattern.hasMatch(trimmed);
}
