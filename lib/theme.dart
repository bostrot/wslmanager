import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:system_theme/system_theme.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:wsl2distromanager/components/helpers.dart';

enum NavigationIndicators { sticky, end }

class ThemeModeManager {}

class AppTheme extends ChangeNotifier {
  static var themeMode = ThemeMode.system;

  AppTheme() {
    _loadTheme();
  }

  void _loadTheme() {
    String? theme = prefs.getString('themeMode');
    if (theme == 'dark') {
      _mode = ThemeMode.dark;
    } else if (theme == 'light') {
      _mode = ThemeMode.light;
    } else {
      _mode = ThemeMode.system;
    }
    themeMode = _mode;
  }

  AccentColor _color = systemAccentColor;
  AccentColor get color => _color;
  set color(AccentColor color) {
    _color = color;
    notifyListeners();
  }

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;
  set mode(ThemeMode mode) {
    _mode = mode;
    themeMode = mode;
    if (mode == ThemeMode.dark) {
      prefs.setString('themeMode', 'dark');
    } else if (mode == ThemeMode.light) {
      prefs.setString('themeMode', 'light');
    } else {
      prefs.setString('themeMode', 'system');
    }
    notifyListeners();
  }

  PaneDisplayMode _displayMode = PaneDisplayMode.auto;
  PaneDisplayMode get displayMode => _displayMode;
  set displayMode(PaneDisplayMode displayMode) {
    _displayMode = displayMode;
    notifyListeners();
  }

  NavigationIndicators _indicator = NavigationIndicators.sticky;
  NavigationIndicators get indicator => _indicator;
  set indicator(NavigationIndicators indicator) {
    _indicator = indicator;
    notifyListeners();
  }

  WindowEffect _windowEffect = WindowEffect.disabled;
  WindowEffect get windowEffect => _windowEffect;
  set windowEffect(WindowEffect windowEffect) {
    _windowEffect = windowEffect;
    notifyListeners();
  }

  void setEffect(WindowEffect effect, BuildContext context) {
    Window.setEffect(
      effect: effect,
      color: [
        WindowEffect.solid,
        WindowEffect.acrylic,
      ].contains(effect)
          ? FluentTheme.of(context).micaBackgroundColor.withValues(alpha: 0.05)
          : Colors.transparent,
      dark: FluentTheme.of(context).brightness.isDark,
    );
  }

  TextDirection _textDirection = TextDirection.ltr;
  TextDirection get textDirection => _textDirection;
  set textDirection(TextDirection direction) {
    _textDirection = direction;
    notifyListeners();
  }

  Locale? _locale;
  Locale? get locale => _locale;
  set locale(Locale? locale) {
    _locale = locale;
    notifyListeners();
  }
}

AccentColor get systemAccentColor {
  if ((defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.android) &&
      !kIsWeb) {
    return AccentColor('normal', {
      'darkest': SystemTheme.accentColor.darkest,
      'darker': SystemTheme.accentColor.darker,
      'dark': SystemTheme.accentColor.dark,
      'normal': SystemTheme.accentColor.accent,
      'light': SystemTheme.accentColor.light,
      'lighter': SystemTheme.accentColor.lighter,
      'lightest': SystemTheme.accentColor.lightest,
    });
  }
  return Colors.blue;
}

/// The app's theme, built once per brightness so light and dark cannot drift.
///
/// [tenFootScreen] adds the TV-distance glow; [focusTheme] is what widens the
/// focus indicator to a real two-colour perimeter (audit IA-07). fluent_ui's
/// own default draws a 2px outer stroke and a 1px inner one, which measured as
/// a hairline on screen — the second stroke is what separates the ring from
/// whatever it is drawn against, so it gets the same width as the first.
FluentThemeData buildAppTheme({
  required Brightness brightness,
  required AccentColor accentColor,
  required bool tenFootScreen,
}) {
  final base = FluentThemeData(
    brightness: brightness,
    accentColor: accentColor,
    visualDensity: VisualDensity.standard,
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 50),
    ),
  );
  return base.copyWith(
    focusTheme: FocusThemeData(
      primaryBorder: BorderSide(
        width: 2.0,
        color: base.resources.focusStrokeColorOuter,
      ),
      secondaryBorder: BorderSide(
        width: 2.0,
        color: base.resources.focusStrokeColorInner,
      ),
      glowFactor: tenFootScreen ? 2.0 : 0.0,
    ),
  );
}
