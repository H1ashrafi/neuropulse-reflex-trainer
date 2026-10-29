import 'package:flutter/material.dart';

import '../models/session_result.dart';
import '../services/reflex_ledger.dart';
import '../theme/neuro_theme.dart';

class HallOfFameCard extends StatelessWidget {
  const HallOfFameCard({super.key, required this.entries, required this.today});

  final List<SessionResult> entries;
  final DayKey today;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.emoji_events_outlined, color: NeuroColors.gold, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('HALL OF FAME',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: NeuroColors.text, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(left: 28, top: 2),
                child: Text('All-time top 3 · kept forever',
                    style: TextStyle(color: NeuroColors.muted, fontSize: 11)),
              ),
              const SizedBox(height: 8),
              for (var rank = 1; rank <= ReflexLedger.hallSize; rank += 1)
                _HallRow(
                  rank: rank,
                  entry: entries.elementAtOrNull(rank - 1),
                  today: today,
                ),
            ],
          ),
        ),
      );
}

class _HallRow extends StatelessWidget {
  const _HallRow({required this.rank, required this.entry, required this.today});

  final int rank;
  final SessionResult? entry;
  final DayKey today;

  @override
  Widget build(BuildContext context) {
    final record = entry;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          RankBadge(rank: rank, filled: record != null),
          const SizedBox(width: 14),
          Expanded(
            child: record == null
                ? const Text('Open slot — finish a full protocol to claim it',
                    style: TextStyle(color: NeuroColors.faint, fontSize: 13))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          Text(Readout.score(record.dri),
                              style: const TextStyle(
                                  color: NeuroColors.text, fontSize: 22, fontWeight: FontWeight.w800)),
                          if (record.dayKey == today)
                            const Text('NEW',
                                style: TextStyle(
                                    color: NeuroColors.gold, fontSize: 11, fontWeight: FontWeight.w800)),
                        ],
                      ),
                      Text(
                        'mean ${Readout.millis(record.meanRtMs)} · acc ${Readout.percent(record.accuracy)}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: NeuroColors.muted, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      _DateBadge(record: record),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class RankBadge extends StatelessWidget {
  const RankBadge({super.key, required this.rank, this.filled = true, this.size = 34});

  final int rank;
  final bool filled;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? NeuroColors.gold : Colors.transparent,
          border: Border.all(color: filled ? NeuroColors.gold : NeuroColors.faint, width: 1.5),
        ),
        child: Text(
          '#$rank',
          style: TextStyle(
            color: filled ? NeuroColors.black : NeuroColors.faint,
            fontWeight: FontWeight.w800,
            fontSize: size * 0.36,
          ),
        ),
      );
}

class _DateBadge extends StatelessWidget {
  const _DateBadge({required this.record});

  final SessionResult record;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: NeuroColors.gold.withValues(alpha: 0.6)),
        ),
        child: Text(
          '${Readout.longDay(record.dayKey)} · ${Readout.clock(record.startedAt)}',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: NeuroColors.gold, fontSize: 11, fontWeight: FontWeight.w700),
        ),
      );
}
