// Parsing and formatting for the `size` and `number` values of `.wslconfig`.
//
// `wsl-config.md:250-252` documents size entries as defaulting to bytes with
// the unit omissible, so `memory=8589934592`, `memory=6144MB` and `memory=8GB`
// are three legal spellings of roughly the same request. The settings screen
// renders those keys on a slider that works in a single unit, so every spelling
// has to resolve to a number in that unit before the widget sees it:
// `fluent_ui`'s `Slider` asserts its range in the constructor, and an unparsed
// value either throws the Settings page or silently snaps to the minimum
// (doc/audit/wsl-docs/ CC-9, R-9, R-10).

/// Byte multipliers for the suffixes `.wslconfig` accepts, keyed by their
/// upper-case spelling. Suffix matching is case-insensitive, as the format is.
const Map<String, int> wslSizeUnits = <String, int>{
  'B': 1,
  'KB': 1024,
  'MB': 1024 * 1024,
  'GB': 1024 * 1024 * 1024,
  'TB': 1024 * 1024 * 1024 * 1024,
};

final RegExp _sizePattern = RegExp(r'^([0-9]+(?:\.[0-9]+)?)\s*([a-zA-Z]*)$');

/// Byte multiplier for [unit], or null when it is not a documented suffix.
///
/// An empty [unit] means "no unit at all" and multiplies by one, which is what
/// the count keys (`processors`) render in.
int? wslSizeUnitFactor(String unit) {
  if (unit.isEmpty) return 1;
  return wslSizeUnits[unit.toUpperCase()];
}

/// Parse [text] as a `.wslconfig` size and express it in [unit].
///
/// Returns null when [text] is empty or is not a size at all, so the caller can
/// tell "unset" and "unreadable" apart from a real zero.
///
/// A bare number is ambiguous: the documentation reads it as bytes, but the app
/// has always written and read plain slider positions in the widget's own unit.
/// [bareUnitMax] resolves that the way the audit prescribes — a bare number no
/// larger than the widget's maximum is a slider position in [unit], anything
/// larger is the documented byte form. Pass null to always read bare numbers as
/// bytes.
double? parseWslSize(String text, {String unit = 'B', double? bareUnitMax}) {
  final match = _sizePattern.firstMatch(text.trim());
  if (match == null) return null;

  final amount = double.tryParse(match.group(1)!);
  if (amount == null) return null;

  final target = wslSizeUnitFactor(unit);
  if (target == null) return null;

  final suffix = match.group(2)!;
  if (suffix.isEmpty) {
    if (bareUnitMax != null && amount <= bareUnitMax) return amount;
    return amount / target;
  }

  final factor = wslSizeUnitFactor(suffix);
  if (factor == null) return null;
  return amount * factor / target;
}

/// Parse [text] as a plain count, the value type of `processors`,
/// `vmIdleTimeout` and `maxCrashDumpCount`. No unit is documented for these, so
/// a suffix makes the value unreadable rather than large.
int? parseWslCount(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  return int.tryParse(trimmed);
}

/// Whether a `Slider` may be handed [value] with this [min] and [max].
///
/// `fluent_ui`'s `Slider` asserts `value >= min && value <= max` in its own
/// constructor, so this has to be checked before the widget is built rather
/// than clamped afterwards. False means "render the raw text instead", which
/// also keeps a value the app cannot place from being rewritten to a wrong one.
bool wslSliderFits(double? value, {required int min, required int max}) =>
    max > min && value != null && value >= min && value <= max;

/// Render [amount] of [unit] the way the app writes it back to `.wslconfig`.
///
/// Whole numbers only: every documented size key takes an integer, and WSL
/// rejects a fractional one.
String formatWslSize(double amount, String unit) => '${amount.round()}$unit';
