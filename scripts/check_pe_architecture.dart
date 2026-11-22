import 'dart:io';
import 'dart:typed_data';

/// Reports the CPU architecture a Windows executable was actually compiled
/// for, and fails when it is not the one that was asked for.
///
/// This exists because the Windows Arm64 build has no way to announce that it
/// silently produced an x64 binary. Flutter ships no Arm64 SDK for Windows, so
/// the tool targets whatever the *Dart executable running it* was built for
/// (`bin/internal/update_dart_sdk.ps1` says as much): install the SDK from the
/// published zip on an Arm64 machine and every step of the build succeeds,
/// every artifact lands where the Arm64 job expects it, and what ships is the
/// x64 app again — the exact failure `bostrot/wsl2-distro-manager#229` is
/// about, only now with a filename claiming otherwise. A PE header cannot be
/// talked into lying, so the release asserts on that instead.
///
///   dart run scripts/check_pe_architecture.dart build/.../wsl2distromanager.exe arm64
const String x64Name = 'x64';
const String arm64Name = 'arm64';

/// `IMAGE_FILE_MACHINE_*`, as written into the COFF header.
const Map<int, String> machineNames = <int, String>{
  0x014c: 'x86',
  0x01c0: 'arm',
  0x01c4: 'armnt',
  0x8664: x64Name,
  0xaa64: arm64Name,
  0x0200: 'ia64',
  0x5064: 'riscv64',
};

/// A file that is not a PE image at all — truncated, a script, a stub.
class PeFormatException implements Exception {
  PeFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads the COFF machine word out of [bytes] and names it.
///
/// Returns the raw `0x…` value for machine types not in [machineNames]; an
/// unknown architecture is still a definite answer, and reporting it beats
/// pretending the check passed.
String peArchitecture(Uint8List bytes) {
  final ByteData view = ByteData.sublistView(bytes);

  // The DOS stub every PE still carries: 'MZ', then the offset of the real
  // header at 0x3c.
  if (bytes.length < 0x40) {
    throw PeFormatException(
      'not a PE image: only ${bytes.length} bytes, too short for a DOS header',
    );
  }
  if (bytes[0] != 0x4d || bytes[1] != 0x5a) {
    throw PeFormatException('not a PE image: missing the "MZ" signature');
  }

  final int peOffset = view.getUint32(0x3c, Endian.little);
  if (peOffset < 0x40 || peOffset + 6 > bytes.length) {
    throw PeFormatException(
      'not a PE image: the DOS header points at 0x${peOffset.toRadixString(16)}, '
      'which is outside a ${bytes.length}-byte file',
    );
  }
  if (bytes[peOffset] != 0x50 ||
      bytes[peOffset + 1] != 0x45 ||
      bytes[peOffset + 2] != 0x00 ||
      bytes[peOffset + 3] != 0x00) {
    throw PeFormatException(
      'not a PE image: no "PE\\0\\0" signature at '
      '0x${peOffset.toRadixString(16)}',
    );
  }

  final int machine = view.getUint16(peOffset + 4, Endian.little);
  return machineNames[machine] ?? '0x${machine.toRadixString(16)}';
}

/// [peArchitecture] for a file on disk.
String peArchitectureOfFile(String path) {
  final File file = File(path);
  if (!file.existsSync()) {
    throw PeFormatException('no such file: $path');
  }
  return peArchitecture(file.readAsBytesSync());
}

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'usage: dart run scripts/check_pe_architecture.dart <exe> <$x64Name|$arm64Name>',
    );
    exitCode = 2;
    return;
  }

  final String path = args[0];
  final String expected = args[1].toLowerCase();
  if (expected != x64Name && expected != arm64Name) {
    stderr.writeln('unknown architecture "${args[1]}"');
    exitCode = 2;
    return;
  }

  final String actual;
  try {
    actual = peArchitectureOfFile(path);
  } on PeFormatException catch (error) {
    stderr.writeln('$path: $error');
    exitCode = 1;
    return;
  }

  if (actual != expected) {
    stderr.writeln(
      '$path is a $actual binary, but a $expected build was expected. '
      'On Windows the Flutter tool targets the architecture of the Dart '
      'executable running it, so this usually means the SDK in PATH is the '
      'x64 zip rather than a clone that bootstrapped the native Dart SDK.',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln('$path is $actual, as expected.');
}
