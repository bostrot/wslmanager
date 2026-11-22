import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/components/wsl_size.dart';

/// The `.wslconfig` size parser behind the Settings screen's sliders.
///
/// Every case here is a value the WSL documentation says is legal and the old
/// `double.tryParse(text.replaceAll('GB', ''))` got wrong — either by throwing
/// out of `Slider`'s range assert or by silently snapping to the minimum.
/// See doc/audit/wsl-docs/ CC-9, R-9 and R-10.
void main() {
  group('parseWslSize', () {
    test('reads the documented byte form of a size', () {
      // wsl-config.md:252 — sizes default to bytes, the unit is omissible.
      // 8589934592 B is 8 GB, and it used to reach the slider unclamped.
      expect(parseWslSize('8589934592', unit: 'GB'), 8);
    });

    test('reads an MB suffix instead of collapsing to the minimum', () {
      // R-10: memory=6144MB is honoured by WSL and used to render as 1 GB.
      expect(parseWslSize('6144MB', unit: 'GB'), 6);
    });

    test('reads the unit the value already carries', () {
      expect(parseWslSize('8GB', unit: 'GB'), 8);
      expect(parseWslSize('1TB', unit: 'GB'), 1024);
      expect(parseWslSize('512MB', unit: 'MB'), 512);
      expect(parseWslSize('1099511627776', unit: 'GB'), 1024);
    });

    test('matches the suffix case-insensitively, like the format itself', () {
      expect(parseWslSize('8gb', unit: 'GB'), 8);
      expect(parseWslSize('6144mb', unit: 'GB'), 6);
    });

    test('tolerates a space between the number and the unit', () {
      expect(parseWslSize(' 8 GB ', unit: 'GB'), 8);
    });

    test('reads a bare number below the widget maximum in the widget unit', () {
      // The app has always written and read plain slider positions this way.
      expect(parseWslSize('8', unit: 'GB', bareUnitMax: 33), 8);
      // Above the maximum it can only be the documented byte form.
      expect(parseWslSize('8589934592', unit: 'GB', bareUnitMax: 33), 8);
    });

    test('returns null for anything that is not a size', () {
      expect(parseWslSize('', unit: 'GB'), isNull);
      expect(parseWslSize('lots', unit: 'GB'), isNull);
      expect(parseWslSize('8 gigabytes', unit: 'GB'), isNull);
      expect(parseWslSize('8PB', unit: 'GB'), isNull);
      expect(parseWslSize('-1', unit: 'GB'), isNull);
    });

    test('reads zero, which is how the docs disable swap', () {
      expect(parseWslSize('0', unit: 'GB', bareUnitMax: 32), 0);
    });
  });

  group('parseWslCount', () {
    test('reads a plain integer', () {
      expect(parseWslCount('64'), 64);
      expect(parseWslCount(' 10 '), 10);
    });

    test('returns null for empty, fractional and suffixed values', () {
      expect(parseWslCount(''), isNull);
      expect(parseWslCount('1.5'), isNull);
      expect(parseWslCount('10ms'), isNull);
    });
  });

  group('wslSliderFits', () {
    // The values that used to throw the Settings page. CC-9 / V-1: fluent_ui's
    // Slider asserts its range in the constructor, so these have to be caught
    // before the widget is built.
    test('refuses the documented byte form on a GB-scaled slider', () {
      final memory = parseWslSize('8589934592', unit: 'GB', bareUnitMax: 33);
      expect(memory, 8);
      expect(wslSliderFits(memory, min: 1, max: 33), isTrue);
      // Same file opened on a 4 GB machine: still legal to WSL, off the slider.
      expect(wslSliderFits(memory, min: 1, max: 4), isFalse);
    });

    test('refuses a processor count above the host core count', () {
      // R-9: WSL warns and clamps processors=64 on a 10-thread host; the app
      // used to assert on it instead.
      expect(wslSliderFits(parseWslCount('64')?.toDouble(), min: 1, max: 10),
          isFalse);
    });

    test('refuses an unreadable value rather than snapping to the minimum', () {
      expect(wslSliderFits(parseWslSize('lots', unit: 'GB'), min: 1, max: 33),
          isFalse);
    });

    test('refuses a range that is not a range', () {
      expect(wslSliderFits(8, min: 0, max: 0), isFalse);
    });

    test('accepts a value inside the range', () {
      expect(wslSliderFits(parseWslSize('6144MB', unit: 'GB'), min: 1, max: 33),
          isTrue);
      expect(
          wslSliderFits(parseWslSize('0', unit: 'GB', bareUnitMax: 32),
              min: 0, max: 32),
          isTrue);
    });
  });

  group('formatWslSize', () {
    test('writes back a whole number with the unit appended', () {
      expect(formatWslSize(8, 'GB'), '8GB');
      expect(formatWslSize(7.6, 'GB'), '8GB');
      expect(formatWslSize(4, ''), '4');
    });
  });

  group('wslSizeUnitFactor', () {
    test('knows every documented suffix and nothing else', () {
      expect(wslSizeUnitFactor(''), 1);
      expect(wslSizeUnitFactor('b'), 1);
      expect(wslSizeUnitFactor('KB'), 1024);
      expect(wslSizeUnitFactor('tb'), 1024 * 1024 * 1024 * 1024);
      expect(wslSizeUnitFactor('PB'), isNull);
    });
  });
}
