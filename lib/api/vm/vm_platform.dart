import 'dart:io';

import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/remote_target.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Whether this host manages instances through Apple's
/// Virtualization.framework rather than WSL.
bool get isAppleHost => Platform.isMacOS;

/// Builds the [VmBackend] for this host. Replaced by tests to inject fakes;
/// production code always calls [vmBackend] instead of constructing a
/// backend directly, so the whole app follows one switch.
VmBackend Function() vmBackendBuilder = defaultVmBackendBuilder;

/// Whether the remote-WSL preference points at a usable target — the same
/// test [WSLApi] applies before routing anything over SSH.
bool get remoteWslActive {
  try {
    final enabled = prefs.getBool('UseRemoteWSL') ?? false;
    final target = prefs.getString('RemoteWSLTarget')?.trim() ?? '';
    return enabled && isValidRemoteTarget(target);
  } catch (_) {
    return false;
  }
}

/// Apple hosts run native VMs — unless a remote Windows/WSL target is
/// configured, in which case the whole app drives that host's distros over
/// SSH, exactly like the Linux build does.
VmBackend defaultVmBackendBuilder() =>
    isAppleHost && !remoteWslActive ? AppleVmApi() : WSLApi();

/// The instance backend for this host.
VmBackend vmBackend() => vmBackendBuilder();
