import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/session_result.dart';
import '../services/feedback_service.dart';
import '../services/storage_service.dart';
import '../theme/neuro_theme.dart';
import '../widgets/hall_of_fame_card.dart';
import 'training_screen.dart';

class ResultScreen extends StatefulWidget {
  const ResultScreen({
    super.key,
    required this.result,
    required this.receipt,
    required this.repository,
    required this.feedback,
  });

  final SessionResult result;
  final RecordReceipt receipt;
  final ReflexRepository repository;
  final FeedbackService feedback;

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> with SingleTickerProviderStateMixin {
  static const Duration celebrationLength = Duration(milliseconds: 1800);

  late final AnimationController _celebration =
      AnimationController(vsync: this, duration: celebrationLength);

  @override
  void initState() {
    super.initState();
    if (widget.receipt.verdict.allTimeRank != null) {
      unawaited(_celebration.forward());
    }
  }

  @override
  void dispose() {
    _celebration.dispose();
    super.dispose();
  }

  void _again() => Navigator.of(context).pushReplacement(MaterialPageRoute<String>(
        builder: (_) => TrainingScreen(
          mode: widget.result.mode,
          repository: widget.repository,
          feedback: widget.feedback,
        ),
      ));

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final reaction = result.reaction;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          children: [
            _VerdictBanner(verdict: widget.receipt.verdict, celebration: _celebration),
            const SizedBox(height: 28),
            const Text('DAILY REFLEX INDEX',
                textAlign: TextAlign.center,
                style: TextStyle(color: NeuroColors.muted, fontSize: 12, letterSpacing: 2)),
            Text(Readout.score(result.dri),
                textAlign: TextAlign.center,
                style: const TextStyle(color: NeuroColors.text, fontSize: 88, fontWeight: FontWeight.w900)),
            Text(
              '${result.mode.label} · consistency ${result.grade?.label ?? Readout.missing}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: NeuroColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 24),
            _MetricGrid(tiles: [
              ('MEAN RT', Readout.millis(reaction.meanRtMs)),
              ('STD DEV', Readout.millis(reaction.stdDevMs)),
              ('ACCURACY', Readout.percent(reaction.accuracy)),
              ('TRIALS', '${reaction.trials}'),
              ('FALSE STARTS', '${reaction.anticipationFaults} · ${Readout.percent(reaction.falseStartRate)}'),
              ('MISSES', '${reaction.misses} · ${Readout.percent(reaction.missRate)}'),
            ]),
            if (result.saccade.shown > 0) ...[
              const _SectionLabel('VISUAL SACCADES'),
              _MetricGrid(tiles: [
                ('TARGETS HIT', '${result.saccade.hits}/${result.saccade.shown}'),
                ('ACQUISITION', Readout.millis(result.saccade.meanAcquisitionMs)),
              ]),
            ],
            if (result.burst.burstTaps + result.burst.cadenceTaps > 0) ...[
              const _SectionLabel('BURST & CADENCE'),
              _MetricGrid(tiles: [
                ('PEAK BURST', Readout.rate(result.burst.peakTapsPerSecond)),
                ('BEAT ERROR', Readout.millis(result.burst.meanAsynchronyMs)),
              ]),
            ],
            if (!widget.receipt.saved)
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Text('Not saved: ${widget.receipt.saveProblem}',
                    style: const TextStyle(color: NeuroColors.noGo, fontSize: 13)),
              ),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NeuroColors.text,
                      side: const BorderSide(color: NeuroColors.line),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text('DASHBOARD'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _again,
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                    child: const Text('AGAIN', style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VerdictBanner extends StatelessWidget {
  const _VerdictBanner({required this.verdict, required this.celebration});

  final RecordVerdict verdict;
  final Animation<double> celebration;

  (String, String, Color) _wording() {
    final rank = verdict.allTimeRank;
    final delta = verdict.deltaToTodayBest;
    if (rank != null) {
      final today = delta == null ? 'first ranked attempt today' : "${Readout.signed(delta)} vs today's best";
      return ('ALL-TIME RANK #$rank!', 'New personal record · $today', NeuroColors.gold);
    }
    if (!verdict.ranked) {
      return ('PRACTICE · NOT RANKED', 'Run the full 10-minute protocol to rank.', NeuroColors.muted);
    }
    if (delta == null) {
      return ('FIRST RANKED ATTEMPT TODAY', 'This sets the bar for today.', NeuroColors.go);
    }
    if (verdict.beatTodayBest) {
      return ("BEAT TODAY'S BEST (${Readout.signed(delta)})", 'Keep the streak alive.', NeuroColors.go);
    }
    return (
      "TODAY'S BEST STAYS ${Readout.score(verdict.previousTodayBest)}",
      "${Readout.signed(delta)} vs today's best",
      NeuroColors.muted,
    );
  }

  @override
  Widget build(BuildContext context) {
    final (headline, detail, color) = _wording();
    final rank = verdict.allTimeRank;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: CelebrationPainter(celebration)),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.7)),
          ),
          child: Row(
            children: [
              if (rank != null) ...[
                ScaleTransition(
                  scale: CurvedAnimation(parent: celebration, curve: Curves.elasticOut),
                  child: RankBadge(rank: rank, size: 44),
                ),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(headline,
                        style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text(detail, style: const TextStyle(color: NeuroColors.muted, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class CelebrationPainter extends CustomPainter {
  CelebrationPainter(this.progress) : super(repaint: progress);

  static const int sparkCount = 28;
  static const double maxSparkRadius = 4;

  final Animation<double> progress;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0 || t >= 1) {
      return;
    }
    final center = size.center(Offset.zero);
    final reach = Curves.easeOutCubic.transform(t) * size.longestSide * 0.6;
    final spark = Paint()..color = NeuroColors.gold.withValues(alpha: 1 - t);
    for (var index = 0; index < sparkCount; index += 1) {
      final angle = 2 * math.pi * index / sparkCount;
      final lane = index % 3 == 0 ? 1.0 : 0.7;
      final position = center + Offset(math.cos(angle), math.sin(angle) * 0.6) * reach * lane;
      canvas.drawCircle(position, 1 + maxSparkRadius * (1 - t), spark);
    }
  }

  @override
  bool shouldRepaint(CelebrationPainter oldDelegate) => oldDelegate.progress != progress;
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 10),
        child: Text(text,
            style: const TextStyle(color: NeuroColors.muted, fontSize: 12, letterSpacing: 2)),
      );
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.tiles});

  static const int columns = 2;
  static const double gap = 10;

  final List<(String, String)> tiles;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (var start = 0; start < tiles.length; start += columns)
            Padding(
              padding: const EdgeInsets.only(bottom: gap),
              child: Row(
                children: [
                  for (var column = 0; column < columns; column += 1) ...[
                    if (column > 0) const SizedBox(width: gap),
                    Expanded(
                      child: start + column < tiles.length
                          ? _MetricTile(label: tiles[start + column].$1, value: tiles[start + column].$2)
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
        ],
      );
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: NeuroColors.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: NeuroColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: NeuroColors.muted, fontSize: 11, letterSpacing: 1.2)),
            const SizedBox(height: 4),
            Text(value,
                style: const TextStyle(color: NeuroColors.text, fontSize: 19, fontWeight: FontWeight.w800)),
          ],
        ),
      );
}
