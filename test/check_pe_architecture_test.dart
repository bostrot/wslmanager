import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../scripts/check_pe_architecture.dart';

/// Builds the smallest thing [peArchitecture] accepts: a DOS header whose
/// `e_lfanew` points at a COFF header carrying [machine].
Uint8List peImage(int machine, {int peOffset = 0x80, int totalLength = 0x100}) {
  final Uint8List bytes = Uint8List(totalLength);
  final ByteData view = ByteData.sublistView(bytes);
  bytes[0] = 0x4d; // 'M'
  bytes[1] = 0x5a; // 'Z'
  view.setUint32(0x3c, peOffset, Endian.little);
  bytes[peOffset] = 0x50; // 'P'
  bytes[peOffset + 1] = 0x45; // 'E'
  bytes[peOffset + 2] = 0x00;
  bytes[peOffset + 3] = 0x00;
  view.setUint16(peOffset + 4, machine, Endian.little);
  return bytes;
}

void main() {
  group('peArchitecture', () {
    test('names an x86-64 image', () {
      expect(peArchitecture(peImage(0x8664)), 'x64');
    });

    test('names an Arm64 image', () {
      expect(peArchitecture(peImage(0xaa64)), 'arm64');
    });

    test('names the architectures that are neither', () {
      expect(peArchitecture(peImage(0x014c)), 'x86');
      expect(peArchitecture(peImage(0x01c4)), 'armnt');
    });

    test('reports an unknown machine type as its raw value rather than '
        'passing it off as the expected one', () {
      expect(peArchitecture(peImage(0x1234)), '0x1234');
    });

    test('reads the COFF header wherever the DOS header points it', () {
      expect(peArchitecture(peImage(0xaa64, peOffset: 0xc8)), 'arm64');
    });

    test('rejects a file that is not a PE image', () {
      final Uint8List script = Uint8List.fromList(
        List<int>.filled(0x100, 0x20)..[0] = 0x23, // '#'
      );
      expect(
        () => peArchitecture(script),
        throwsA(
          isA<PeFormatException>().having(
            (PeFormatException e) => e.message,
            'message',
            contains('MZ'),
          ),
        ),
      );
    });

    test('rejects a file too short to hold a DOS header', () {
      expect(
        () => peArchitecture(Uint8List.fromList(<int>[0x4d, 0x5a])),
        throwsA(isA<PeFormatException>()),
      );
    });

    test('rejects a DOS header pointing outside the file', () {
      final Uint8List truncated = peImage(0x8664, peOffset: 0x80)
          .sublist(0, 0x60);
      expect(
        () => peArchitecture(truncated),
        throwsA(
          isA<PeFormatException>().having(
            (PeFormatException e) => e.message,
            'message',
            contains('outside'),
          ),
        ),
      );
    });

    test('rejects an offset that overlaps the DOS header itself', () {
      final Uint8List bytes = peImage(0x8664);
      ByteData.sublistView(bytes).setUint32(0x3c, 0x10, Endian.little);
      expect(() => peArchitecture(bytes), throwsA(isA<PeFormatException>()));
    });

    test('rejects a DOS stub with no PE signature behind it', () {
      final Uint8List bytes = peImage(0x8664);
      bytes[0x80] = 0x4d; // 'M', not 'P'
      expect(
        () => peArchitecture(bytes),
        throwsA(
          isA<PeFormatException>().having(
            (PeFormatException e) => e.message,
            'message',
            contains('PE'),
          ),
        ),
      );
    });
  });

  group('peArchitectureOfFile', () {
    late Directory temporaryDirectory;

    setUp(() {
      temporaryDirectory = Directory.systemTemp.createTempSync('pe_arch_test');
    });

    tearDown(() {
      temporaryDirectory.deleteSync(recursive: true);
    });

    test('reads an image from disk', () {
      final File file = File('${temporaryDirectory.path}/app.exe')
        ..writeAsBytesSync(peImage(0xaa64));
      expect(peArchitectureOfFile(file.path), 'arm64');
    });

    test('says which file is missing instead of throwing a FileSystemException',
        () {
      expect(
        () => peArchitectureOfFile('${temporaryDirectory.path}/absent.exe'),
        throwsA(
          isA<PeFormatException>().having(
            (PeFormatException e) => e.message,
            'message',
            contains('absent.exe'),
          ),
        ),
      );
    });
  });
}
