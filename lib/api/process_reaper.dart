// Ties child processes to the app's lifetime with a Windows job object, so a
// force-kill of the app (Task Manager, `Stop-Process -Force`) — which skips
// every Dart-side cleanup — still takes the children with it. The keep-alive
// `wsl … sleep infinity` session and any streaming exec would otherwise linger
// and hold a distro up until `wsl --shutdown`.
//
// Bounded-safe by construction: every step is wrapped and best-effort, the
// current process is never assigned to the job, and any failure degrades to
// exactly today's behaviour (children simply outlive a force-kill). The job is
// created once and its handle is held for the whole process lifetime — closing
// it is what fires KILL_ON_JOB_CLOSE, and only the OS reclaiming the handle on
// process exit should do that.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart'
    show
        AssignProcessToJobObject,
        CloseHandle,
        CreateJobObject,
        JobObjectExtendedLimitInformation,
        OpenProcess,
        PROCESS_SET_QUOTA,
        PROCESS_TERMINATE,
        SetInformationJobObject;

class ProcessReaper {
  ProcessReaper._();
  static final ProcessReaper instance = ProcessReaper._();

  /// JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE — absent from win32 5.15's constants.
  static const int _killOnJobClose = 0x2000;

  /// Size and LimitFlags offset of JOBOBJECT_EXTENDED_LIMIT_INFORMATION on
  /// x64. Writing the one flag into a correctly-sized zeroed buffer avoids
  /// hand-declaring the whole nested struct; a wrong size just makes
  /// SetInformationJobObject fail, which this treats as "unavailable".
  static const int _extendedLimitInfoSize = 144;
  static const int _limitFlagsOffset = 16;

  /// Job handle, 0 once we have decided it is unavailable, null until tried.
  int? _job;

  int? _ensureJob() {
    if (_job != null) return _job == 0 ? null : _job;
    if (!Platform.isWindows) {
      _job = 0;
      return null;
    }
    try {
      final handle = CreateJobObject(nullptr, nullptr);
      if (handle == 0) {
        _job = 0;
        return null;
      }
      final info = calloc<Uint8>(_extendedLimitInfoSize);
      try {
        (info + _limitFlagsOffset).cast<Uint32>().value = _killOnJobClose;
        final ok = SetInformationJobObject(
          handle,
          JobObjectExtendedLimitInformation,
          info.cast(),
          _extendedLimitInfoSize,
        );
        if (ok == 0) {
          CloseHandle(handle);
          _job = 0;
          return null;
        }
      } finally {
        calloc.free(info);
      }
      _job = handle;
      return handle;
    } catch (_) {
      _job = 0;
      return null;
    }
  }

  /// Adds [pid] to the app job so it dies with the app. No-op off Windows or
  /// on any failure — never throws, so a caller can adopt unconditionally.
  void adopt(int pid) {
    if (!Platform.isWindows || pid <= 0) return;
    try {
      final job = _ensureJob();
      if (job == null) return;
      final process =
          OpenProcess(PROCESS_TERMINATE | PROCESS_SET_QUOTA, 0, pid);
      if (process == 0) return;
      try {
        AssignProcessToJobObject(job, process);
      } finally {
        CloseHandle(process);
      }
    } catch (_) {
      // Best-effort: a child that could not be adopted just behaves as before.
    }
  }
}
