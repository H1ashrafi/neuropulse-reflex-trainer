import 'package:flutter/material.dart';

import '../models/session_result.dart';

abstract final class NeuroColors {
  static const Color black = Color(0xFF000000);
  static const Color panel = Color(0xFF0E0E0E);
  static const Color panelRaised = Color(0xFF161616);
  static const Color line = Color(0xFF262626);
  static const Color text = Color(0xFFF2F2F2);
  static const Color muted = Color(0xFF8C8C8C);
  static const Color faint = Color(0xFF4A4A4A);
  static const Color go = Color(0xFF00FFA3);
  static const Color noGo = Color(0xFFFF3B30);
  static const Color gold = Color(0xFFFFD700);
}

abstract final class NeuroTheme {
  static ThemeData build() {
    const scheme = ColorScheme.dark(
      primary: NeuroColors.go,
      onPrimary: NeuroColors.black,
      secondary: NeuroColors.gold,
      onSecondary: NeuroColors.black,
      error: NeuroColors.noGo,
      surface: NeuroColors.panel,
      onSurface: NeuroColors.text,
      outline: NeuroColors.line,
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: NeuroColors.black,
      canvasColor: NeuroColors.black,
      dividerColor: NeuroColors.line,
      splashFactory: NoSplash.splashFactory,
      appBarTheme: const AppBarTheme(
        backgroundColor: NeuroColors.black,
        foregroundColor: NeuroColors.text,
        elevation: 0,
      ),
      cardTheme: const CardThemeData(
        color: NeuroColors.panel,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          side: BorderSide(color: NeuroColors.line),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: NeuroColors.panelRaised,
        contentTextStyle: TextStyle(color: NeuroColors.text),
      ),
      dialogTheme: const DialogThemeData(backgroundColor: NeuroColors.panelRaised),
      popupMenuTheme: const PopupMenuThemeData(color: NeuroColors.panelRaised),
    );
  }
}

abstract final class Readout {
  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static const String missing = '—';

  static String score(double? value) => value == null ? missing : value.toStringAsFixed(1);

  static String signed(double value) {
    final magnitude = value.abs().toStringAsFixed(1);
    return value < 0 ? '−$magnitude' : '+$magnitude';
  }

  static String millis(double? value) => value == null ? missing : '${value.round()} ms';

  static String percent(double share) => '${(share * 100).round()}%';

  static String rate(double? perSecond) =>
      perSecond == null ? missing : '${perSecond.toStringAsFixed(1)}/s';

  static String shortDay(DayKey day) => '${day.day} ${_months[day.month - 1]}';

  static String longDay(DayKey day) => '${shortDay(day)} ${day.year}';

  static String clock(DateTime moment) {
    final local = moment.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  static String countdown(Duration remaining) {
    final seconds = remaining.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
