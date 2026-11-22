import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';

/// The floating entry point to the AI assistant dock.
///
/// It used to be a plain accent circle with fluent's generic chat-bubble
/// glyph (ai-tasks#27) — indistinguishable from a support-chat launcher and
/// visibly older than the rest of the shell. The pill pairs the sparkle mark
/// that every current assistant uses with a short verb, so the button says
/// what it opens and reads as part of the app rather than an add-on.
///
/// Built on [HoverButton] rather than a `GestureDetector`: this is the only
/// way into the AI panel and a `GestureDetector` has no focus node, so a
/// keyboard could not reach it at all (audit IA-04). Hover, press and focus
/// come through the same widget states fluent's own buttons use.
class AiChatButton extends StatelessWidget {
  const AiChatButton({
    super.key,
    required this.onPressed,
    this.open = false,
    this.focusNode,
    this.autofocus = false,
  });

  /// Toggles the dock. Null disables the button.
  final VoidCallback? onPressed;

  /// Whether the dock is currently showing. The look is the same either way
  /// — the panel next to the button is the visible state, and a dimmed
  /// button was how the closed state came to sit at 1.02:1 against dark
  /// backgrounds (audit TL-06) — but assistive tech is told which way the
  /// next press goes.
  final bool open;

  final FocusNode? focusNode;
  final bool autofocus;

  /// The pill's height; the corner radius follows from it.
  static const double height = 40;

  /// The glyph size inside the pill.
  static const double iconSize = 18;

  /// The label's colour on the accent fill. White in both themes, like the
  /// FilledButton foreground the shell already uses on the accent.
  static const Color foreground = Colors.white;

  /// The fill for a given interaction state. Diagonal so the pill has a
  /// little depth without a drop shadow doing all the work; hover lightens
  /// it, a press darkens it, the same direction fluent's accent buttons move.
  static LinearGradient fillFor(AccentColor accent, Set<WidgetState> states) {
    final List<Color> colors;
    if (states.isDisabled) {
      colors = [
        accent.normal.withValues(alpha: 0.4),
        accent.dark.withValues(alpha: 0.4),
      ];
    } else if (states.isPressed) {
      colors = [accent.dark, accent.darker];
    } else if (states.isHovered) {
      colors = [accent.lighter, accent.normal];
    } else {
      colors = [accent.light, accent.dark];
    }
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: colors,
    );
  }

  /// A tinted shadow rather than a grey one, so the pill looks lit by its
  /// own colour. It lifts on hover and settles on press.
  static List<BoxShadow> shadowFor(
      AccentColor accent, Set<WidgetState> states) {
    if (states.isDisabled) return const [];
    final double blur;
    final double lift;
    final double alpha;
    if (states.isPressed) {
      blur = 6;
      lift = 1;
      alpha = 0.22;
    } else if (states.isHovered) {
      blur = 16;
      lift = 6;
      alpha = 0.45;
    } else {
      blur = 12;
      lift = 4;
      alpha = 0.32;
    }
    return [
      BoxShadow(
        color: accent.normal.withValues(alpha: alpha),
        blurRadius: blur,
        offset: Offset(0, lift),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor;
    final label = 'ai-chat-button-text'.i18n();

    // No semanticLabel: the visible text is the accessible name, exactly
    // once. Naming the HoverButton as well put the same string on two
    // merged nodes, and which one a screen reader got first was a race.
    return HoverButton(
      onPressed: onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      builder: (context, states) {
        final fg =
            states.isDisabled ? foreground.withValues(alpha: 0.7) : foreground;
        return Semantics(
          button: true,
          toggled: open,
          child: FocusBorder(
            focused: states.isFocused,
            style: const FocusThemeData(
              borderRadius: BorderRadius.all(Radius.circular(height / 2)),
            ),
            child: AnimatedContainer(
              duration: theme.fasterAnimationDuration,
              curve: theme.animationCurve,
              height: height,
              padding: const EdgeInsetsDirectional.only(start: 14, end: 18),
              decoration: BoxDecoration(
                gradient: fillFor(accent, states),
                borderRadius: BorderRadius.circular(height / 2),
                boxShadow: shadowFor(accent, states),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SparkleIcon(size: iconSize, color: fg),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The "AI sparkles" mark — a four-point star with a smaller companion at its
/// top-right — drawn as a path so it scales crisply at any size and takes any
/// colour. fluent_ui's icon font has no sparkle; its nearest glyphs are a
/// robot and a chat bubble, one dated and the other already meaning
/// "conversation" elsewhere in the app.
class SparkleIcon extends StatelessWidget {
  const SparkleIcon({
    super.key,
    this.size = 16,
    this.color,
    this.semanticLabel,
  });

  final double size;

  /// Defaults to the ambient [IconTheme] colour, like an [Icon] would.
  final Color? color;

  /// Decoration by default: the button that carries the icon has the name.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final iconColor = color ?? IconTheme.of(context).color ?? Colors.black;
    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: SparklePainter(iconColor)),
      ),
    );
  }
}

/// Paints [SparkleIcon] on a 24-unit design grid, scaled to the canvas.
class SparklePainter extends CustomPainter {
  const SparklePainter(this.color);

  final Color color;

  /// The design grid every coordinate below is expressed on.
  static const double grid = 24;

  /// A four-point star centred on [center]. The sides curve inwards through
  /// a control point near the middle, which is what makes it read as a
  /// sparkle rather than a diamond; [waist] is how far that point sits from
  /// the centre as a fraction of [radius].
  static Path star(Offset center, double radius, {double waist = 0.2}) {
    final w = radius * waist;
    final cx = center.dx;
    final cy = center.dy;
    return Path()
      ..moveTo(cx, cy - radius)
      ..quadraticBezierTo(cx + w, cy - w, cx + radius, cy)
      ..quadraticBezierTo(cx + w, cy + w, cx, cy + radius)
      ..quadraticBezierTo(cx - w, cy + w, cx - radius, cy)
      ..quadraticBezierTo(cx - w, cy - w, cx, cy - radius)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / grid;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.save();
    // Centre the grid in a non-square canvas rather than stretching it.
    canvas.translate(
      (size.width - grid * scale) / 2,
      (size.height - grid * scale) / 2,
    );
    canvas.scale(scale);
    canvas.drawPath(star(const Offset(10, 14), 9), paint);
    canvas.drawPath(star(const Offset(18.5, 5.5), 4), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(SparklePainter oldDelegate) => oldDelegate.color != color;
}
