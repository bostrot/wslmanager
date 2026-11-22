# WSL2 Distro Manager - Flutter Desktop Application

WSL2 Distro Manager is a Flutter desktop application for managing Windows Subsystem for Linux (WSL) distributions. It provides a graphical interface for installing, uninstalling, updating, backing up, and restoring WSL distros, as well as working with Docker images and LXC containers.

Always reference these instructions first and fallback to search or bash commands only when you encounter unexpected information that does not match the info here.

## Working Effectively

### Prerequisites and Setup
- Install Flutter SDK from https://flutter.dev/desktop
- Ensure Windows development is enabled:
  - `flutter config --enable-windows-desktop`
  - `flutter upgrade`

### Bootstrap, Build, and Test the Repository
- **Clone and setup dependencies**:
  - `flutter pub get` -- downloads all Dart dependencies from pubspec.yaml. Takes 2-3 minutes. NEVER CANCEL. Set timeout to 5+ minutes.
- **Analyze code quality**:
  - `flutter analyze` -- runs static analysis using analysis_options.yaml. Takes 30-60 seconds.
- **Run unit tests**:
  - `flutter test` -- runs all tests in /test directory. Takes 2-5 minutes for WSL-dependent tests. NEVER CANCEL. Set timeout to 10+ minutes.
  - Note: Some tests require WSL to be available and may create/delete test instances
- **Build the application**:
  - `flutter build windows` -- builds Windows executable. Takes 3-8 minutes. NEVER CANCEL. Set timeout to 15+ minutes.
  - Creates build artifacts in `build/windows/x64/runner/Release/`
- **Create MSIX package**:
  - `dart run msix:create` -- creates Windows Store package. Takes 1-2 minutes. NEVER CANCEL. Set timeout to 5+ minutes.

### Run the Application
- **Development mode**:
  - `flutter run -d windows` -- runs in debug mode with hot reload
  - Note: Application requires Windows environment for WSL management functionality
- **Release executable**:
  - Run `build/windows/x64/runner/Release/wsl2distromanager.exe` after building

## Validation

### Manual Testing Scenarios
- **CRITICAL**: This application manages WSL distributions and requires Windows/WSL for full functionality
- Always test core functionality after making changes:
  1. **Application Launch**: Verify the app starts without errors and displays the main interface
  2. **WSL Instance Listing**: Test that existing WSL distributions are properly detected and displayed
  3. **UI Navigation**: Verify all screens (Home, Create, Actions, Settings) are accessible and render correctly
  4. **Theme and Localization**: Test both light/dark themes and different language settings work properly

### Build Validation
- Always run `flutter analyze` before committing -- the CI (.github/workflows/releaser.yml) will fail if analysis finds issues
- Always run `flutter test` to ensure no regressions in core functionality
- Verify the build completes successfully with `flutter build windows`

### Commits
- One author only: `Eric Trenkel <eric@bostrot.com>`. No `Co-Authored-By:` trailers.
- No tool attribution anywhere -- no "Generated with", no session links, no bot
  signatures, no emoji footers, in commit messages or PR descriptions.
- Commit subjects and PR titles are plain sentences starting with an uppercase
  letter that say what changed, e.g. `Filter the home instance list by name`.
  No Conventional Commits prefixes (`feat(ui):`, `fix:`, `docs:`, ...).
- Keep the subject short, imperative and descriptive, with no trailing period.
  Add a body only when the reason is not obvious from the subject.

### Code Quality
- Follow Dart/Flutter conventions as enforced by analysis_options.yaml
- Use the existing localization system in `/lib/i18n/` for any user-facing strings
- Maintain the existing theme structure in `theme.dart`

## Common Tasks

### Repository Structure
```
lib/
├── api/           # Core API classes for WSL, Docker, archives
├── components/    # Reusable UI components and utilities
├── dialogs/       # Modal dialogs for user interactions
├── i18n/          # Internationalization JSON files
├── nav/           # Navigation and routing
├── screens/       # Main application screens
├── main.dart      # Application entry point
└── theme.dart     # Theme and styling definitions

test/              # Unit tests
├── wsl_test.dart          # WSL API tests
├── dockerimages_test.dart # Docker functionality tests
├── templates_test.dart    # Template handling tests
└── safepaths_test.dart    # Path validation tests

.github/workflows/ # CI/CD pipeline definitions
scripts/           # PowerShell build and utility scripts
windows/           # Windows-specific Flutter configuration
```

### Key Files to Know
- **pubspec.yaml**: Dependencies, version, and build configuration
- **lib/main.dart**: Application entry point and window setup
- **lib/api/wsl.dart**: Core WSL management functionality
- **lib/components/constants.dart**: App constants including version
- **analysis_options.yaml**: Linting and code analysis rules
- **.github/workflows/releaser.yml**: CI/CD build pipeline

### Common Development Patterns
- **State Management**: Uses Provider package for state management
- **UI Framework**: Fluent UI for Windows-native appearance
- **Async Operations**: Extensive use of async/await for WSL operations
- **Error Handling**: Custom notification system in `lib/components/notify.dart`
- **Logging**: Centralized logging in `lib/components/logging.dart`

### Building and Testing Notes
- **Windows Dependencies**: The Inno installer uses InnoDependencyInstaller (`Dependency_AddVC2015To2022`) to install VC++ runtime when needed; runtime DLLs are not bundled from `windows-dlls/`
- **Version Management**: Version is managed in pubspec.yaml and automatically updated in constants.dart during CI
- **Test Timeouts**: WSL-related tests have 10-minute timeouts due to potential download/installation time
- **MSIX Configuration**: Windows Store packaging configuration is in pubspec.yaml under `msix_config`

### Troubleshooting
- **Build Issues**: Ensure Flutter Windows development is properly configured
- **Test Failures**: Some tests require WSL to be installed and functional
- **Permission Issues**: WSL operations may require administrator privileges
- **Network Issues**: Docker image downloads and distro installations require internet access

### Development Workflow
1. Make code changes in appropriate `/lib` directories
2. Run `flutter analyze` to check for issues
3. Run `flutter test` to ensure no regressions
4. Test changes with `flutter run -d windows`
5. Build release version with `flutter build windows`
6. Verify MSIX creation with `dart run msix:create`

Always ensure Windows development environment is properly set up before beginning work, as this application is specifically designed for Windows WSL management.