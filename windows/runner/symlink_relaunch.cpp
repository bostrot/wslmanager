#include "symlink_relaunch.h"

#include <windows.h>

#include <cstdlib>
#include <string>

namespace {

// Linked implicitly by the runner; if it sits next to the executable the
// loader and the engine find everything else there too.
constexpr wchar_t kEngineLibrary[] = L"flutter_windows.dll";

// Returns the path this process was started through, as the loader sees it.
// Returns an empty string on failure.
std::wstring GetModulePath() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    DWORD length = ::GetModuleFileNameW(nullptr, path.data(),
                                        static_cast<DWORD>(path.size()));
    if (length == 0) {
      return std::wstring();
    }
    if (length < path.size()) {
      path.resize(length);
      return path;
    }
    // The buffer was too small and the result was truncated.
    path.resize(path.size() * 2);
  }
}

// Resolves symbolic links and junctions in |path|. Drive and UNC paths come
// back in their usual form; anything else keeps the "\\?\" prefix so that it
// stays usable. Returns an empty string on failure.
std::wstring ResolveFinalPath(const std::wstring& path) {
  // Asking for no access rights still lets us query the final name and
  // works even when the file is only readable by the installer.
  HANDLE file = ::CreateFileW(
      path.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, 0, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return std::wstring();
  }

  std::wstring resolved(MAX_PATH, L'\0');
  for (;;) {
    DWORD length = ::GetFinalPathNameByHandleW(
        file, resolved.data(), static_cast<DWORD>(resolved.size()),
        FILE_NAME_NORMALIZED);
    if (length == 0) {
      ::CloseHandle(file);
      return std::wstring();
    }
    if (length < resolved.size()) {
      resolved.resize(length);
      break;
    }
    // On a too-small buffer the return value is the required size including
    // the terminating null.
    resolved.resize(length + 1);
  }
  ::CloseHandle(file);

  constexpr wchar_t kUncPrefix[] = L"\\\\?\\UNC\\";
  constexpr size_t kUncPrefixLength = sizeof(kUncPrefix) / sizeof(wchar_t) - 1;
  constexpr wchar_t kPrefix[] = L"\\\\?\\";
  constexpr size_t kPrefixLength = sizeof(kPrefix) / sizeof(wchar_t) - 1;
  if (resolved.compare(0, kUncPrefixLength, kUncPrefix) == 0) {
    return L"\\\\" + resolved.substr(kUncPrefixLength);
  }
  if (resolved.compare(0, kPrefixLength, kPrefix) == 0 &&
      resolved.size() > kPrefixLength + 1 &&
      resolved[kPrefixLength + 1] == L':') {
    return resolved.substr(kPrefixLength);
  }
  return resolved;
}

bool FileExistsNextTo(const std::wstring& path, const wchar_t* file_name) {
  size_t separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    return false;
  }
  std::wstring sibling = path.substr(0, separator + 1) + file_name;
  return ::GetFileAttributesW(sibling.c_str()) != INVALID_FILE_ATTRIBUTES;
}

// Case-insensitive in the way the file system is, i.e. also for non-ASCII
// letters, which _wcsicmp would get wrong.
bool IsSamePath(const std::wstring& a, const std::wstring& b) {
  return ::CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) ==
         CSTR_EQUAL;
}

}  // namespace

bool RelaunchThroughRealPath(const wchar_t* arguments, int show_command,
                             bool wait_for_exit, int* exit_code) {
  std::wstring module_path = GetModulePath();
  if (module_path.empty() || FileExistsNextTo(module_path, kEngineLibrary)) {
    // The runtime files are where the loader looks for them. This also
    // covers the relaunched process itself, junctions, mapped drives and
    // short names, none of which need a relaunch.
    return false;
  }
  std::wstring real_path = ResolveFinalPath(module_path);
  if (real_path.empty() || IsSamePath(module_path, real_path)) {
    return false;
  }

  std::wstring command_line = L"\"" + real_path + L"\"";
  if (arguments != nullptr && *arguments != L'\0') {
    command_line += L' ';
    command_line += arguments;
  }

  STARTUPINFOW startup_info = {};
  startup_info.cb = sizeof(startup_info);
  // Whoever started this process may have redirected its standard handles;
  // hand exactly those on so that e.g. "> log.txt" keeps working.
  STARTUPINFOW own_startup_info = {};
  own_startup_info.cb = sizeof(own_startup_info);
  ::GetStartupInfoW(&own_startup_info);
  BOOL inherit_handles = FALSE;
  if (own_startup_info.dwFlags & STARTF_USESTDHANDLES) {
    startup_info.dwFlags |= STARTF_USESTDHANDLES;
    startup_info.hStdInput = own_startup_info.hStdInput;
    startup_info.hStdOutput = own_startup_info.hStdOutput;
    startup_info.hStdError = own_startup_info.hStdError;
    inherit_handles = TRUE;
  }
  startup_info.dwFlags |= STARTF_USESHOWWINDOW;
  startup_info.wShowWindow = static_cast<WORD>(show_command);

  PROCESS_INFORMATION process_info = {};
  // CreateProcessW may write into the command line buffer, which is why it
  // gets the string's own writable storage rather than c_str().
  if (!::CreateProcessW(real_path.c_str(), command_line.data(), nullptr,
                        nullptr, inherit_handles, 0, nullptr, nullptr,
                        &startup_info, &process_info)) {
    return false;
  }
  ::CloseHandle(process_info.hThread);

  *exit_code = EXIT_SUCCESS;
  if (wait_for_exit) {
    ::WaitForSingleObject(process_info.hProcess, INFINITE);
    DWORD code = EXIT_FAILURE;
    if (::GetExitCodeProcess(process_info.hProcess, &code)) {
      *exit_code = static_cast<int>(code);
    }
  }
  ::CloseHandle(process_info.hProcess);
  return true;
}
