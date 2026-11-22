import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win32/win32.dart'
    show
        CloseHandle,
        IsProcessInJob,
        OpenProcess,
        PROCESS_QUERY_INFORMATION;
import 'package:wsl2distromanager/api/process_reaper.dart';

void main() {
  group('ProcessReaper', () {
    test('adopt never throws on an invalid pid', () {
      // 0 and negatives are rejected up front; a very high pid that does not
      // exist makes OpenProcess fail, which must degrade to a no-op.
      expect(() => ProcessReaper.instance.adopt(0), returnsNormally);
      expect(() => ProcessReaper.instance.adopt(-1), returnsNormally);
      expect(() => ProcessReaper.instance.adopt(0x7FFFFFF0), returnsNormally);
    });

    test('adopting a real short-lived child does not throw', () async {
      // On Windows this exercises CreateJobObject + AssignProcessToJobObject
      // for real; off Windows it is a no-op. Either way it must not throw and
      // must not disturb the child.
      final proc = Platform.isWindows
          ? await Process.start('cmd', ['/c', 'exit', '0'])
          : await Process.start('true', const []);
      expect(() => ProcessReaper.instance.adopt(proc.pid), returnsNormally);
      final code = await proc.exitCode;
      expect(code, 0);
    });

    test('on Windows an adopted child is actually placed in a job', () async {
      if (!Platform.isWindows) return;
      // A child that lives long enough to be inspected.
      final proc = await Process.start('cmd', ['/c', 'pause']);
      addTearDown(() => proc.kill());
      ProcessReaper.instance.adopt(proc.pid);

      final handle =
          OpenProcess(PROCESS_QUERY_INFORMATION, 0, proc.pid);
      expect(handle, isNot(0));
      final result = calloc<Int32>();
      try {
        // JobHandle null = "is it in ANY job?". Proves adopt() assigned it,
        // not that it merely failed to throw.
        final ok = IsProcessInJob(handle, 0, result);
        expect(ok, isNot(0));
        expect(result.value, 1);
      } finally {
        calloc.free(result);
        CloseHandle(handle);
      }
    });
  });
}
