import 'package:fluent_ui/fluent_ui.dart';

/// The 8px all-caps pill behind the app's inline markers ("BETA", "NEW").
///
/// Four capitals do not land in the middle of a `Container(padding:) + Text`
/// on their own, because what that centres is the text's *layout box* and for
/// a caps-only label the box is not the ink:
///
///  * Flutter appends [letterSpacing] after every glyph, the last one
///    included, so the box carries a whole letter-space of dead room on its
///    trailing edge and the ink sits half that far towards the leading one.
///    The horizontal padding is shifted by that half to put it back.
///  * The box is also as tall as the platform font's ascent, descent and line
///    gap, so the pill used to be a different height on Windows than on
///    macOS. A tight box (`height: 1`) with [TextLeadingDistribution.even]
///    leading -- which splits the difference equally above and below instead
///    of in proportion to ascent and descent -- makes it [height] everywhere,
///    so a bordered pill and a plain one sit at the same height in the pane.
///
/// What is left is the font's own asymmetry: capitals rest on the baseline
/// and use none of the descent below it, so they sit about half a pixel low
/// in Segoe UI at this size. Flutter exposes no cap-height metric, so
/// correcting that exactly would mean hard-coding a number per platform font.
///
/// The tight box is also why [label] has to be capitals: it reserves less
/// room under the baseline than the font's own descent, so a descender would
/// hang out of the wash.
class BadgePill extends StatelessWidget {
  const BadgePill({
    super.key,
    required this.label,
    required this.foreground,
    required this.background,
    this.border,
  });

  /// The pill's text: capitals, and deliberately not translated at any call
  /// site so it reads the same in every locale.
  final String label;

  /// The label colour.
  final Color foreground;

  /// The wash behind the label.
  final Color background;

  /// The outline colour, or null for a pill without one.
  final Color? border;

  /// Tracking for the small caps — and the width of the dead space the
  /// layout leaves after the last glyph.
  static const double letterSpacing = 0.5;

  /// Padding around the label, before the [letterSpacing] correction.
  static const double horizontalPadding = 4;
  static const double verticalPadding = 1;

  /// The label's font size, and the height of its (tight) line box.
  static const double fontSize = 8;

  /// The pill's outer height at a text scale of 1 -- the tight line box plus
  /// both paddings. The same for every label, border and platform font, none
  /// of which reach the line box any more; a `MediaQuery.textScaler` above 1
  /// still scales it, like any other text.
  static const double height = fontSize + verticalPadding * 2;

  static final BorderRadius _radius = BorderRadius.circular(3);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(
        horizontalPadding + letterSpacing / 2,
        verticalPadding,
        horizontalPadding - letterSpacing / 2,
        verticalPadding,
      ),
      decoration: BoxDecoration(color: background, borderRadius: _radius),
      // foregroundDecoration, not decoration: a border inside `decoration` is
      // laid out like extra padding, which made the bordered BETA pill a pixel
      // taller and wider than the plain NEW one next to it. Painted over the
      // child instead, the outline costs no space.
      foregroundDecoration: border == null
          ? null
          : BoxDecoration(
              borderRadius: _radius,
              border: Border.all(color: border!, width: 0.5),
            ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: fontSize,
          height: 1,
          leadingDistribution: TextLeadingDistribution.even,
          fontWeight: FontWeight.bold,
          color: foreground,
          letterSpacing: letterSpacing,
        ),
      ),
    );
  }
}
