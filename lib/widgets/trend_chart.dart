import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/session_result.dart';
import '../theme/neuro_theme.dart';

final class TrendGeometry {
  const TrendGeometry(this.size, this.count);

  static const double leftGutter = 30;
  static const double rightGutter = 10;
  static const double topGutter = 10;
  static const double attemptBandHeight = 24;
  static const double bandGap = 10;
  static const double maxScore = 100;

  final Size size;
  final int count;

  Rect get plot => Rect.fromLTRB(
        leftGutter,
        topGutter,
        size.width - rightGutter,
        size.height - attemptBandHeight - bandGap,
      );

  Rect get attemptBand => Rect.fromLTRB(
        leftGutter,
        size.height - attemptBandHeight,
        size.width - rightGutter,
        size.height,
      );

  double xFor(int index) =>
      count <= 1 ? plot.center.dx : plot.left + plot.width * index / (count - 1);

  double yFor(double score) => plot.bottom - plot.height * (score.clamp(0, maxScore) / maxScore);

  int indexAt(double dx) {
    if (count <= 1) {
      return 0;
    }
    final fraction = (dx - plot.left) / plot.width;
    return (fraction * (count - 1)).round().clamp(0, count - 1);
  }
}

final class MovingAverage {
  const MovingAverage(this.window);

  final int window;

  List<double?> over(List<double?> values) => [
        for (var index = 0; index < values.length; index += 1)
          _meanOf(values.sublist(math.max(0, index - window + 1), index + 1)),
      ];

  static double? _meanOf(List<double?> slice) {
    final present = slice.whereType<double>().toList();
    if (present.isEmpty) {
      return null;
    }
    return present.reduce((sum, value) => sum + value) / present.length;
  }
}

class TrendChartPainter extends CustomPainter {
  TrendChartPainter({required this.days, required this.selectedIndex});

  static const MovingAverage weeklyMean = MovingAverage(7);
  static const List<double> labelledLevels = [0, 50, 100];
  static const List<double> quietLevels = [25, 75];
  static const double dotRadius = 3;
  static const double todayDotRadius = 4.5;
  static const double selectionRingRadius = 7;
  static const double barWidthShare = 0.5;
  static const double minBarWidth = 2;

  final List<DailyBest> days;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = TrendGeometry(size, days.length);
    _paintGrid(canvas, geometry);
    _paintAttempts(canvas, geometry);
    final bests = [for (final day in days) day.bestDri];
    _paintSeries(canvas, geometry, weeklyMean.over(bests),
        Paint()
          ..color = NeuroColors.muted
          ..strokeWidth = 1.4
          ..style = PaintingStyle.stroke);
    _paintSeries(canvas, geometry, bests,
        Paint()
          ..color = NeuroColors.go
          ..strokeWidth = 2.2
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round);
    _paintDots(canvas, geometry, bests);
    _paintSelection(canvas, geometry, bests);
  }

  void _paintGrid(Canvas canvas, TrendGeometry geometry) {
    final plot = geometry.plot;
    final quiet = Paint()
      ..color = NeuroColors.line
      ..strokeWidth = 1;
    for (final level in [...quietLevels, ...labelledLevels]) {
      final y = geometry.yFor(level);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), quiet);
    }
    for (final level in labelledLevels) {
      final label = TextPainter(
        text: TextSpan(
          text: level.toInt().toString(),
          style: const TextStyle(color: NeuroColors.muted, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(plot.left - label.width - 6, geometry.yFor(level) - label.height / 2));
      label.dispose();
    }
  }

  void _paintAttempts(Canvas canvas, TrendGeometry geometry) {
    final band = geometry.attemptBand;
    final mostAttempts = days.fold(1, (most, day) => math.max(most, day.attempts));
    final slot = days.length <= 1 ? band.width : band.width / (days.length - 1);
    final barWidth = math.max(minBarWidth, slot * barWidthShare);
    for (final (index, day) in days.indexed) {
      if (day.attempts == 0) {
        continue;
      }
      final height = band.height * day.attempts / mostAttempts;
      final x = geometry.xFor(index);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x - barWidth / 2, band.bottom - height, barWidth, height),
          const Radius.circular(1.5),
        ),
        Paint()..color = index == selectedIndex ? NeuroColors.muted : NeuroColors.faint,
      );
    }
  }

  void _paintSeries(Canvas canvas, TrendGeometry geometry, List<double?> values, Paint stroke) {
    final path = Path();
    var started = false;
    for (final (index, value) in values.indexed) {
      if (value == null) {
        continue;
      }
      final point = Offset(geometry.xFor(index), geometry.yFor(value));
      if (started) {
        path.lineTo(point.dx, point.dy);
      } else {
        path.moveTo(point.dx, point.dy);
        started = true;
      }
    }
    canvas.drawPath(path, stroke);
  }

  void _paintDots(Canvas canvas, TrendGeometry geometry, List<double?> bests) {
    final fill = Paint()..color = NeuroColors.go;
    final lastIndex = bests.length - 1;
    for (final (index, value) in bests.indexed) {
      if (value == null) {
        continue;
      }
      final radius = index == lastIndex ? todayDotRadius : dotRadius;
      canvas.drawCircle(Offset(geometry.xFor(index), geometry.yFor(value)), radius, fill);
    }
  }

  void _paintSelection(Canvas canvas, TrendGeometry geometry, List<double?> bests) {
    final index = selectedIndex;
    if (index == null || index < 0 || index >= bests.length) {
      return;
    }
    final x = geometry.xFor(index);
    canvas.drawLine(
      Offset(x, geometry.plot.top),
      Offset(x, geometry.attemptBand.bottom),
      Paint()
        ..color = NeuroColors.faint
        ..strokeWidth = 1,
    );
    final value = bests[index];
    if (value == null) {
      return;
    }
    canvas.drawCircle(
      Offset(x, geometry.yFor(value)),
      selectionRingRadius,
      Paint()
        ..color = NeuroColors.text
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  @override
  bool shouldRepaint(TrendChartPainter oldDelegate) =>
      oldDelegate.selectedIndex != selectedIndex || !listEquals(oldDelegate.days, days);
}

class TrendChart extends StatefulWidget {
  const TrendChart({super.key, required this.days, this.height = 180});

  final List<DailyBest> days;
  final double height;

  @override
  State<TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<TrendChart> {
  int? _selected;

  int get _selection {
    final chosen = _selected;
    if (chosen != null && chosen < widget.days.length) {
      return chosen;
    }
    final lastWithData = widget.days.lastIndexWhere((day) => day.best != null);
    return lastWithData >= 0 ? lastWithData : widget.days.length - 1;
  }

  void _select(TrendGeometry geometry, Offset position) {
    final index = geometry.indexAt(position.dx);
    if (index != _selected) {
      setState(() => _selected = index);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.days.isEmpty) {
      return const SizedBox.shrink();
    }
    final selection = _selection;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(builder: (context, constraints) {
          final size = Size(constraints.maxWidth, widget.height);
          final geometry = TrendGeometry(size, widget.days.length);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _select(geometry, details.localPosition),
            onHorizontalDragUpdate: (details) => _select(geometry, details.localPosition),
            child: Semantics(
              label: '30 day trend of daily best scores',
              child: CustomPaint(
                size: size,
                painter: TrendChartPainter(days: widget.days, selectedIndex: selection),
              ),
            ),
          );
        }),
        const SizedBox(height: 10),
        _SelectionReadout(day: widget.days[selection]),
      ],
    );
  }
}

class _SelectionReadout extends StatelessWidget {
  const _SelectionReadout({required this.day});

  final DailyBest day;

  @override
  Widget build(BuildContext context) {
    final attempts = day.attempts == 1 ? '1 attempt' : '${day.attempts} attempts';
    return Row(
      children: [
        Text(Readout.shortDay(day.day),
            style: const TextStyle(color: NeuroColors.muted, fontSize: 13)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            day.best == null ? 'no ranked attempt' : 'best ${Readout.score(day.bestDri)} · $attempts',
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: NeuroColors.text, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
