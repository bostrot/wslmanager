cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "store_channel.cpp"
  "symlink_relaunch.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# C++/WinRT (store_channel.cpp) is built on coroutines. Under the C++17 the
# standard settings ask for, it falls back to <experimental/coroutine>, which
# the MSVC 14.51 STL (Visual Studio 2026, today's windows-latest) rejects with
# a static assertion; with C++20 it takes the standard <coroutine> header.
target_compile_features(${BINARY_NAME} PRIVATE cxx_std_20)

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# C++/WinRT (store_channel.cpp) resolves its activation and error plumbing
# through the umbrella library; the DLLs behind it ship with every Windows
# 10 and later, so nothing here needs delay-loading.
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")

# Delay-load the Flutter engine so that wWinMain runs before the DLL has to
# be found. When the app is started through a symlink (e.g. the launcher
# winget creates in %LOCALAPPDATA%\Microsoft\WinGet\Links) the loader looks
# for DLLs next to the link and would otherwise abort the process before
# main.cpp gets the chance to relaunch through the real path. The plugin
# DLLs are delay-loaded the same way from the top-level CMakeLists.txt.
target_link_libraries(${BINARY_NAME} PRIVATE "delayimp.lib")
target_link_options(${BINARY_NAME} PRIVATE "/DELAYLOAD:flutter_windows.dll")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
