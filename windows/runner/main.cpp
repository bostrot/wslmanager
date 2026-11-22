#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

// Must follow windows.h.
#include <delayimp.h>

#include <string>

#include "flutter_window.h"
#include "symlink_relaunch.h"
#include "utils.h"

namespace {

// flutter_windows.dll and the plugin DLLs are delay-loaded (see
// CMakeLists.txt) so that wWinMain runs before any of them has to be found.
// Without a hook a DLL that cannot be loaded, or one from another version
// that lacks an export, would take the process down with an unhandled
// exception at the first call into it; explain the problem instead.
FARPROC WINAPI HandleDelayLoadFailure(unsigned reason, DelayLoadInfo* info) {
  std::string message;
  if (reason == dliFailLoadLib) {
    message = "WSL Manager could not load " + std::string(info->szDll) +
              " (error " + std::to_string(info->dwLastError) +
              "). The file has to be next to the application and readable.";
  } else if (reason == dliFailGetProc) {
    std::string procedure =
        info->dlp.fImportByName ? info->dlp.szProcName
                                : "ordinal " + std::to_string(info->dlp.dwOrdinal);
    message = "WSL Manager found " + std::string(info->szDll) +
              " but it is from a different version (" + procedure +
              " is missing).";
  } else {
    return nullptr;
  }
  message += " Reinstalling WSL Manager should fix this.";
  ::MessageBoxA(nullptr, message.c_str(), "WSL Manager",
                MB_OK | MB_ICONERROR);
  // Not ExitProcess: that takes the loader lock, which another thread may be
  // holding while it waits for this delay-load to finish.
  ::TerminateProcess(::GetCurrentProcess(), EXIT_FAILURE);
  return nullptr;
}

}  // namespace

extern "C" const PfnDliHook __pfnDliFailureHook2 = HandleDelayLoadFailure;

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to the parent's console when there is one (e.g., 'flutter run' or
  // a terminal). Do it before relaunching so that a relaunched process finds
  // the same console through its parent, which is this process.
  bool attached_to_console =
      ::AttachConsole(ATTACH_PARENT_PROCESS) != FALSE;

  // Started through a symlink (e.g. winget's Links folder)? Run the real
  // executable instead; nothing below can work from the link's directory.
  // Stay around for the terminal that is waiting on this process; a launch
  // from Explorer has nobody to wait for.
  int relaunch_exit_code = EXIT_SUCCESS;
  if (RelaunchThroughRealPath(command_line, show_command, attached_to_console,
                              &relaunch_exit_code)) {
    return relaunch_exit_code;
  }

  // Without a console, create one when running with a debugger, or a hidden
  // one so that stdout and stderr have somewhere to go. Skipping this when
  // already attached matters: the hidden cmd.exe below is only terminated
  // when attaching to it succeeds, which it cannot with a console present.
  if (!attached_to_console) {
    if (::IsDebuggerPresent()) {
      CreateAndAttachConsole();
    } else {
      // see https://github.com/flutter/flutter/issues/47891
      STARTUPINFO si = { 0 };
      si.cb = sizeof(si);
      si.dwFlags = STARTF_USESHOWWINDOW;
      si.wShowWindow = SW_HIDE;

      PROCESS_INFORMATION pi = { 0 };
      WCHAR lpszCmd[MAX_PATH] = L"cmd.exe";
      if (::CreateProcess(NULL, lpszCmd, NULL, NULL, FALSE, CREATE_NEW_CONSOLE | CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        do {
          if (::AttachConsole(pi.dwProcessId)) {
            ::TerminateProcess(pi.hProcess, 0);
            break;
          }
        } while (ERROR_INVALID_HANDLE == GetLastError());
        ::CloseHandle(pi.hProcess);
        ::CloseHandle(pi.hThread);
      }
    }
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(650, 500);
  if (!window.CreateAndShow(L"WSL Manager", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
