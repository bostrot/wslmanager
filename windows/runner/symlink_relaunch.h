#ifndef RUNNER_SYMLINK_RELAUNCH_H_
#define RUNNER_SYMLINK_RELAUNCH_H_

// When the executable was started through a symbolic link, such as the
// launcher winget creates in %LOCALAPPDATA%\Microsoft\WinGet\Links, Windows
// searches for DLLs and Flutter looks for its data directory next to the
// link rather than next to the real executable, so the app cannot start.
//
// Detects that case (no engine DLL next to the path the process was started
// through, and that path resolves to a different file) and starts the real
// executable with |arguments|, the command line without the program name as
// wWinMain receives it, and |show_command|. With |wait_for_exit| the call
// blocks until the real process ends and stores its exit code in
// |exit_code|; otherwise |exit_code| is EXIT_SUCCESS. Returns true when a
// relaunch happened and the caller should exit with |exit_code|, false when
// the process should simply continue.
bool RelaunchThroughRealPath(const wchar_t* arguments, int show_command,
                             bool wait_for_exit, int* exit_code);

#endif  // RUNNER_SYMLINK_RELAUNCH_H_
