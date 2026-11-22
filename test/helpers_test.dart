import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/components/helpers.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'DistroName_test': 'Test Distro',
    });
    prefs = await SharedPreferences.getInstance();
  });

  test('distroLabel returns correct label', () {
    expect(distroLabel('test'), 'Test Distro');
    expect(distroLabel('unknown'), 'unknown');
  });

  test('replaceSpecialChars replaces non-alphanumeric characters', () {
    expect(replaceSpecialChars('test-distro'), 'test_distro');
    expect(replaceSpecialChars('test/distro'), 'test_distro');
    expect(replaceSpecialChars('test distro'), 'test_distro');
    expect(replaceSpecialChars('test123distro'), 'test123distro');
  });

  test('tryDecodeJson decodes valid JSON', () {
    expect(tryDecodeJson('{"key": "value"}'), {'key': 'value'});
    expect(tryDecodeJson('[1, 2, 3]'), [1, 2, 3]);
  });

  test('tryDecodeJson returns null for invalid JSON', () {
    expect(tryDecodeJson('{invalid}'), null);
    expect(tryDecodeJson(''), null);
  });

  test('fixJsonContent fixes JSON with extra characters', () {
    expect(fixJsonContent('{"key": "value"}'), '{"key": "value"}');
    expect(fixJsonContent(' {"key": "value"} '), '{"key": "value"}');
    // Assuming fixJsonContent logic handles these cases based on implementation
    // It tries removing first/last char if decode fails
    expect(fixJsonContent('x{"key": "value"}'), '{"key": "value"}');
    expect(fixJsonContent('{"key": "value"}x'), '{"key": "value"}');
  });

  // A destructive control has to read as one in both themes: a flat
  // `Colors.red` is the light-theme shade, and it turns muddy against the
  // dark background (audit LN-04, FIX-08).
  testWidgets('destructiveColor follows the theme brightness', (tester) async {
    Future<Color> read(Brightness brightness) async {
      late Color colour;
      await tester.pumpWidget(FluentApp(
        home: FluentTheme(
          data: FluentThemeData(brightness: brightness),
          child: Builder(
              key: ValueKey(brightness),
              builder: (context) {
                colour = destructiveColor(context);
                return const SizedBox();
              }),
        ),
      ));
      return colour;
    }

    final light = await read(Brightness.light);
    final dark = await read(Brightness.dark);

    expect(light, isNot(dark));
    // The dark-theme shade is the lighter one: it sits on a dark background.
    expect(dark.computeLuminance(), greaterThan(light.computeLuminance()));
  });
}
