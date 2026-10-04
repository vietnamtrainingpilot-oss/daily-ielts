import 'package:flutter/material.dart';

/// Design tokens transcribed from `DESIGN.md` at the repo root.
///
/// AGENTS.md 8 makes `DESIGN.md` the single source of truth for visual identity.
/// Every constant here has a named token in that file. If you need a value that
/// is not present, add it to `DESIGN.md` first, then add it here — do not
/// hardcode hex values or magic numbers in widgets.
///
/// The Stitch export shipped conflicting palettes in its YAML frontmatter and
/// prose body. The prose palette won; see the "Resolution note" in `DESIGN.md`.
class Tokens {
  const Tokens._();

  // --- Core canvas & structure -------------------------------------------
  /// surface / background. Eggshell paper substrate.
  static const canvas = Color(0xFFF8F9FA);

  /// surface-container-lowest. Reserved for test cards, passage containers.
  static const surface = Color(0xFFFFFFFF);

  /// outline-variant. Card outlines, pane dividers, split seams, tabular rules.
  static const rule = Color(0xFFE2E8F0);

  /// on-surface. Primary body copy, passage paragraphs, data outputs.
  static const ink = Color(0xFF0F172A);

  /// on-surface-variant. Secondary prompts, metadata labels, reference indices.
  static const inkMuted = Color(0xFF475569);

  // --- Functional accents ------------------------------------------------
  /// primary. Academic Deep Navy: navigation, headers, primary CTAs.
  static const navy = Color(0xFF1E3A8A);

  /// primary hover. Per DESIGN.md "Buttons".
  static const navyHover = Color(0xFF0F172A);

  /// secondary. Signature Crimson: lock indicators, terminal countdown,
  /// target band badges.
  static const crimson = Color(0xFFBE185D);

  /// error. Strict state limits.
  static const strict = Color(0xFFDC2626);

  /// primary-container. Multiple-choice selection tint base.
  static const navyTint = Color(0xFFE0E7FF);

  /// secondary-container.
  static const crimsonTint = Color(0xFFFCE7F3);

  // --- Gate signals ------------------------------------------------------
  /// Verified / met target.
  static const gateMet = Color(0xFF15803D);

  /// Unverified / bypass caution. Shares the skill-writing hue by design.
  static const gateCaution = Color(0xFFB45309);

  /// Deficit / locked. Shares the secondary hue by design.
  static const gateLocked = Color(0xFFBE185D);

  // --- Skill identifiers -------------------------------------------------
  static const skillReading = Color(0xFF0D9488);
  static const skillReadingBg = Color(0xFFCCFBF1);
  static const skillReadingInk = Color(0xFF0F766E);

  static const skillListening = Color(0xFF4338CA);
  static const skillListeningBg = Color(0xFFE0E7FF);
  static const skillListeningInk = Color(0xFF3730A3);

  static const skillWriting = Color(0xFFB45309);
  static const skillWritingBg = Color(0xFFFEF3C7);
  static const skillWritingInk = Color(0xFF92400E);

  static const skillSpeaking = Color(0xFF6D28D9);
  static const skillSpeakingBg = Color(0xFFEDE9FE);
  static const skillSpeakingInk = Color(0xFF5B21B6);

  // --- Field states ------------------------------------------------------
  /// outline. The heavier field-input boundary.
  static const fieldBorder = Color(0xFFCBD5E1);

  /// outline. Form-control and radio-ring boundary, lighter than [fieldBorder].
  static const outline = Color(0xFFCBD5E1);

  /// Locked / gating action background.
  static const fieldDisabledBg = Color(0xFFF1F5F9);

  /// Locked / gating action text.
  static const fieldDisabledInk = Color(0xFF94A3B8);

  /// Inline IELTS sentence-completion underline.
  static const sentenceUnderline = Color(0xFF64748B);

  /// Answered cell fill in the question matrix.
  static const answeredCell = Color(0xFF1E293B);

  // --- Elevation ---------------------------------------------------------
  /// Surface level 2 ambient shadow. Deliberately low-contrast: the design
  /// uses tonal tiering, not drop shadows.
  static const ambientShadow = <BoxShadow>[
    BoxShadow(color: Color(0x0F0F172A), offset: Offset(0, 1), blurRadius: 3),
    BoxShadow(color: Color(0x0A0F172A), offset: Offset(0, 1), blurRadius: 2),
  ];

  // --- Shape -------------------------------------------------------------
  static const radiusSm = 4.0;
  static const radiusDefault = 4.0;
  static const radiusMd = 6.0;
  static const radiusLg = 8.0;

  // --- Spacing (4px baseline) -------------------------------------------
  static const spaceXs = 4.0;
  static const spaceSm = 8.0;
  static const spaceMd = 16.0;
  static const spaceLg = 24.0;
  static const spaceXl = 40.0;

  // --- Typography --------------------------------------------------------
  static const editorial = 'Newsreader';
  static const interface = 'Inter';

  // --- Elevation (modals, locked overlays) --------------------------------
  /// Surface level 3 backdrop. Surface 3 is `surface` framed by `ink`.
  static const modalBackdrop = Color(0x990F172A);
}

/// Digitally-tabular figures, mandated by DESIGN.md ("Systems, Metadata &
/// Numbers") so countdowns and score counters do not jitter horizontally.
const kTabularFigures = <FontFeature>[FontFeature.tabularFigures()];

ThemeData buildTheme() {
  final base = ThemeData.light(useMaterial3: true);

  // Cards and sheets are bordered, never shadowed (Surface level 1).
  final card = base.cardTheme.copyWith(
    color: Tokens.surface,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: Tokens.rule),
      borderRadius: BorderRadius.circular(Tokens.radiusLg),
    ),
  );

  return base.copyWith(
    scaffoldBackgroundColor: Tokens.canvas,
    colorScheme: const ColorScheme.light(
      primary: Tokens.navy,
      onPrimary: Tokens.surface,
      primaryContainer: Tokens.navyTint,
      onPrimaryContainer: Tokens.ink,
      secondary: Tokens.crimson,
      onSecondary: Tokens.surface,
      secondaryContainer: Tokens.crimsonTint,
      onSecondaryContainer: Tokens.ink,
      surface: Tokens.surface,
      onSurface: Tokens.ink,
      surfaceContainerHighest: Tokens.canvas,
      onSurfaceVariant: Tokens.inkMuted,
      outline: Tokens.fieldBorder,
      outlineVariant: Tokens.rule,
      error: Tokens.strict,
      onError: Tokens.surface,
    ),
    textTheme: base.textTheme
        .apply(bodyColor: Tokens.ink, displayColor: Tokens.ink)
        .copyWith(
          // Editorial voice: Newsreader for headings and long-form passages.
          headlineLarge: const TextStyle(
            fontFamily: Tokens.editorial,
            fontSize: 40,
            fontWeight: FontWeight.w600,
            height: 1.2,
            letterSpacing: -0.02,
          ),
          headlineMedium: const TextStyle(
            fontFamily: Tokens.editorial,
            fontSize: 32,
            fontWeight: FontWeight.w600,
            height: 1.25,
            letterSpacing: -0.01,
          ),
          headlineSmall: const TextStyle(
            fontFamily: Tokens.editorial,
            fontSize: 22,
            fontWeight: FontWeight.w600,
            height: 1.27,
            letterSpacing: -0.005,
          ),
          // Long-form reading passages get the loose 30px line height.
          bodyLarge: const TextStyle(
            fontFamily: Tokens.editorial,
            fontSize: 18,
            fontWeight: FontWeight.w400,
            height: 30 / 18,
            letterSpacing: 0.005,
          ),
          // System voice: Inter for questions, labels, controls, numbers.
          bodyMedium: const TextStyle(
            fontFamily: Tokens.interface,
            fontSize: 14,
            fontWeight: FontWeight.w400,
            height: 22 / 14,
          ),
          bodySmall: const TextStyle(
            fontFamily: Tokens.interface,
            fontSize: 12,
            fontWeight: FontWeight.w400,
            height: 18 / 12,
            letterSpacing: 0.01,
          ),
          labelLarge: const TextStyle(
            fontFamily: Tokens.interface,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            height: 20 / 14,
            letterSpacing: 0.01,
          ),
          labelMedium: const TextStyle(
            fontFamily: Tokens.interface,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            height: 16 / 12,
            letterSpacing: 0.02,
          ),
          labelSmall: const TextStyle(
            fontFamily: Tokens.interface,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            height: 14 / 10,
            letterSpacing: 0.05,
          ),
        ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Tokens.canvas,
      foregroundColor: Tokens.ink,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: card,
    dividerTheme: const DividerThemeData(
      color: Tokens.rule,
      thickness: 1,
      space: 1,
    ),
    // Primary action: solid navy, zero elevation, 4px radius.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Tokens.navy,
        foregroundColor: Tokens.surface,
        elevation: 0,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(
          vertical: Tokens.spaceSm,
          horizontal: Tokens.spaceLg,
        ),
        textStyle: const TextStyle(
          fontFamily: Tokens.interface,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.01,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Tokens.radiusDefault),
        ),
      ),
    ),
    // Secondary: transparent with a hairline rule.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Tokens.ink,
        minimumSize: const Size(0, 44),
        side: const BorderSide(color: Tokens.rule),
        textStyle: const TextStyle(
          fontFamily: Tokens.interface,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.01,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Tokens.radiusDefault),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Tokens.navy,
        textStyle: const TextStyle(
          fontFamily: Tokens.interface,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Tokens.surface,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Tokens.spaceMd,
        vertical: Tokens.spaceSm + 4,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusDefault),
        borderSide: const BorderSide(color: Tokens.fieldBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusDefault),
        borderSide: const BorderSide(color: Tokens.fieldBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusDefault),
        borderSide: const BorderSide(color: Tokens.navy, width: 1.5),
      ),
    ),
    // Locked / gating action: muted fill, muted text, no interaction.
    disabledColor: Tokens.fieldDisabledBg,
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Tokens.ink,
      contentTextStyle: TextStyle(
        fontFamily: Tokens.interface,
        fontSize: 14,
        color: Tokens.surface,
      ),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
