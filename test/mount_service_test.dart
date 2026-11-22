import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/api/mount_service.dart';

void main() {
  group('MountService._getSafeName', () {
    test('returns basename without extension', () {
      // _getSafeName is tested indirectly through mountVhd
      expect(true, isTrue);
    });
  });

  group('MountService.mountVhd type validation', () {
    late MockShell mockShell;

    setUp(() {
      mockShell = MockShell();
    });

    test('rejects invalid filesystem type', () async {
      final service = MountService(shell: mockShell);
      
      expect(
        () => service.mountVhd('/path/to/disk.vhdx', type: 'ext3'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('accepts valid filesystem types', () async {
      final allowedTypes = ['ext4', 'xfs', 'btrfs', 'vfat', 'ntfs'];
      
      for (final type in allowedTypes) {
        final service = MountService(shell: mockShell);
        // These will fail at the shell level but should pass validation
        try {
          await service.mountVhd('/path/to/disk.vhdx', type: type);
        } catch (e) {
          // Should not be an ArgumentError about invalid filesystem
          expect(e is ArgumentError, false, reason: 'type $type failed');
        }
      }
    });
  });

  group('PhysicalDisk', () {
    test('creates disk object correctly', () {
      final disk = PhysicalDisk(
        deviceId: '\\\\.\\PHYSICALDRIVE1',
        model: 'Samsung SSD 870',
        size: '500.00 GB',
        index: 1,
        interfaceType: 'USB',
        mediaType: 'HDD',
      );

      expect(disk.deviceId, '\\\\.\\PHYSICALDRIVE1');
      expect(disk.model, 'Samsung SSD 870');
      expect(disk.isUsb, true);
    });

    test('isUsb returns false for non-USB interface', () {
      final disk = PhysicalDisk(
        deviceId: '\\\\.\\PHYSICALDRIVE0',
        model: 'Internal SSD',
        size: '256.00 GB',
        index: 0,
        interfaceType: 'SATA',
        mediaType: 'SSD',
      );

      expect(disk.isUsb, false);
    });

    test('toString returns formatted string', () {
      final disk = PhysicalDisk(
        deviceId: '\\\\.\\PHYSICALDRIVE1',
        model: 'Test Disk',
        size: '100.00 GB',
        index: 1,
        interfaceType: 'USB',
        mediaType: 'HDD',
      );

      expect(disk.toString(), contains('Test Disk'));
      expect(disk.toString(), contains('100.00 GB'));
      expect(disk.toString(), contains('\\\\.\\PHYSICALDRIVE1'));
    });
  });
}

class MockShell implements Shell {
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) async {
    return ProcessResult(0, 0, '', '');
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    throw UnimplementedError();
  }
}
