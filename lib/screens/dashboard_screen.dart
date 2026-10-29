import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/json_guard.dart';
import '../models/session_result.dart';
import '../services/feedback_service.dart';
import '../services/storage_service.dart';
import '../services/timing_engine.dart';
import '../theme/neuro_theme.dart';
import '../widgets/hall_of_fame_card.dart';
import '../widgets/hixiv_logo.dart';
import '../widgets/trend_chart.dart';
import 'training_screen.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.repository, required this.feedback});

  final ReflexRepository repository;
  final FeedbackService feedback;

  Future<void> _start(BuildContext context, ProtocolMode mode) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => TrainingScreen(mode: mode, repository: repository, feedback: feedback),
    ));
    if (message != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([repository, feedback]),
        builder: (context, _) {
          final ledger = repository.ledger;
          final today = repository.today;
          final warning = repository.loadWarning;
          return Scaffold(
            body: SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  _Header(repository: repository, feedback: feedback),
                  if (warning != null)
                    _WarningBanner(text: warning, onClose: repository.dismissLoadWarning),
                  const SizedBox(height: 14),
                  _TodayCard(ledger: ledger, today: today),
                  const SizedBox(height: 12),
                  _StartPanel(onStart: (mode) => _start(context, mode)),
                  const SizedBox(height: 12),
                  _TrendCard(days: ledger.dailyBests(today)),
                  const SizedBox(height: 12),
                  HallOfFameCard(entries: ledger.hallOfFame, today: today),
                  const SizedBox(height: 12),
                  _TodaySessions(sessions: ledger.sessionsOn(today), hallOfFame: ledger.hallOfFame),
                ],
              ),
            ),
          );
        },
      );
}

enum _MenuAction { exportBackup, importBackup, sound, haptics, about }

class _Header extends StatelessWidget {
  const _Header({required this.repository, required this.feedback});

  final ReflexRepository repository;
  final FeedbackService feedback;

  Future<void> _exportBackup(BuildContext context) async {
    final backup = repository.exportJson();
    await Clipboard.setData(ClipboardData(text: backup));
    if (!context.mounted) {
      return;
    }
    final kilobytes = (backup.length / 1024).toStringAsFixed(1);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Backup copied'),
        content: Text(
          '${repository.ledger.sessions.length} sessions and ${repository.ledger.hallOfFame.length} '
          'records ($kilobytes KB) are on the clipboard. Paste them into a note or a file to keep them.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _importBackup(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = await showDialog<String>(
      context: context,
      builder: (_) => _ImportDialog(repository: repository),
    );
    if (message != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _about(BuildContext context) => showAboutDialog(
        context: context,
        applicationName: 'NeuroPulse',
        applicationVersion: '1.0.0',
        applicationIcon: const HixivLogo(size: 40),
        children: const [
          Text(
            'Offline reflex and cognitive speed trainer by Hixiv. No accounts, no network, '
            'no analytics.\n\nDRI = clamp(100 − (meanRT − 150) / 2.5 − 25 × false-start rate '
            '− 20 × miss rate − 0.15 × SD, 0, 100)',
          ),
        ],
      );

  void _onSelected(BuildContext context, _MenuAction action) {
    switch (action) {
      case _MenuAction.exportBackup:
        unawaited(_exportBackup(context));
      case _MenuAction.importBackup:
        unawaited(_importBackup(context));
      case _MenuAction.sound:
        unawaited(feedback.setSound(!feedback.soundOn));
      case _MenuAction.haptics:
        unawaited(feedback.setHaptics(!feedback.hapticsOn));
      case _MenuAction.about:
        _about(context);
    }
  }

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const HixivLogo(size: 38),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('NeuroPulse',
                    style: TextStyle(color: NeuroColors.text, fontSize: 22, fontWeight: FontWeight.w800)),
                Text('Reflex & cognitive engine · offline',
                    style: TextStyle(color: NeuroColors.muted, fontSize: 12)),
              ],
            ),
          ),
          PopupMenuButton<_MenuAction>(
            icon: const Icon(Icons.more_vert, color: NeuroColors.muted),
            onSelected: (action) => _onSelected(context, action),
            itemBuilder: (_) => [
              const PopupMenuItem(value: _MenuAction.exportBackup, child: Text('Export backup')),
              const PopupMenuItem(value: _MenuAction.importBackup, child: Text('Import backup')),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                  value: _MenuAction.sound, checked: feedback.soundOn, child: const Text('Sound cues')),
              CheckedPopupMenuItem(
                  value: _MenuAction.haptics, checked: feedback.hapticsOn, child: const Text('Haptics')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: _MenuAction.about, child: Text('About')),
            ],
          ),
        ],
      );
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.repository});

  final ReflexRepository repository;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final TextEditingController _backup = TextEditingController();
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _backup.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    _backup.text = clip?.text ?? '';
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    String? problem;
    try {
      final report = await widget.repository.importJson(_backup.text);
      if (mounted) {
        Navigator.of(context).pop(
            'Imported ${report.addedSessions} new sessions · ${report.totalSessions} in history');
      }
      return;
    } on DataFormatException catch (rejected) {
      problem = rejected.message;
    } on Exception catch (failure) {
      problem = 'Could not save: $failure';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _problem = problem;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Import backup'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Paste a NeuroPulse backup. Sessions are merged; nothing is deleted.',
                  style: TextStyle(color: NeuroColors.muted, fontSize: 13)),
              const SizedBox(height: 10),
              TextField(
                controller: _backup,
                maxLines: 6,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '{ "app": "neuropulse", ... }',
                ),
              ),
              if (_problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_problem!, style: const TextStyle(color: NeuroColors.noGo, fontSize: 12)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : _paste, child: const Text('Paste')),
          TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _submit, child: const Text('Import')),
        ],
      );
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.text, required this.onClose});

  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: NeuroColors.noGo.withValues(alpha: 0.7)),
        ),
        child: Row(
          children: [
            Expanded(child: Text(text, style: const TextStyle(color: NeuroColors.text, fontSize: 13))),
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 18, color: NeuroColors.muted),
            ),
          ],
        ),
      );
}

class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.ledger, required this.today});

  final ReflexLedger ledger;
  final DayKey today;

  @override
  Widget build(BuildContext context) {
    final todayBest = ledger.dailyBestOn(today);
    final yesterdayDri = ledger.dailyBestOn(today.shift(-1)).bestDri;
    final best = todayBest.bestDri;
    final attempts = todayBest.attempts == 1 ? '1 ranked attempt' : '${todayBest.attempts} ranked attempts';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text("TODAY'S BEST DRI",
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: NeuroColors.muted, fontSize: 12, letterSpacing: 1.6)),
                ),
                Text(Readout.shortDay(today),
                    style: const TextStyle(color: NeuroColors.muted, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 14,
              runSpacing: 4,
              children: [
                Text(Readout.score(best),
                    style: const TextStyle(color: NeuroColors.text, fontSize: 64, fontWeight: FontWeight.w900)),
                _YesterdayDelta(best: best, yesterday: yesterdayDri),
              ],
            ),
            Text(
              '$attempts today · consistency ${todayBest.best?.grade?.label ?? Readout.missing}',
              style: const TextStyle(color: NeuroColors.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _YesterdayDelta extends StatelessWidget {
  const _YesterdayDelta({required this.best, required this.yesterday});

  final double? best;
  final double? yesterday;

  @override
  Widget build(BuildContext context) {
    final today = best;
    final previous = yesterday;
    if (today == null || previous == null) {
      return Text(
        previous == null ? 'no score yesterday' : 'yesterday ${Readout.score(previous)}',
        style: const TextStyle(color: NeuroColors.muted, fontSize: 13),
      );
    }
    final delta = today - previous;
    final color = delta >= 0 ? NeuroColors.go : NeuroColors.noGo;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text('${Readout.signed(delta)} pts vs yesterday',
          style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700)),
    );
  }
}

class _StartPanel extends StatelessWidget {
  const _StartPanel({required this.onStart});

  static const List<(ProtocolMode, String)> practiceModes = [
    (ProtocolMode.quickProtocol, 'Quick'),
    (ProtocolMode.simpleReaction, 'SRT'),
    (ProtocolMode.goNoGo, 'Go/No-Go'),
  ];

  final ValueChanged<ProtocolMode> onStart;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(
            onPressed: () => onStart(ProtocolMode.fullProtocol),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: const Column(
              children: [
                Text('START 10-MIN PROTOCOL',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                SizedBox(height: 2),
                Text('saccades · reaction · go/no-go · burst — ranked',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final (index, (mode, label)) in practiceModes.indexed) ...[
                if (index > 0) const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => onStart(mode),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NeuroColors.text,
                      side: const BorderSide(color: NeuroColors.line),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Column(
                      children: [
                        Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(Readout.countdown(ProtocolPlan.forMode(mode).totalDuration),
                            style: const TextStyle(color: NeuroColors.muted, fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          const Text('Practice runs are scored but never ranked.',
              textAlign: TextAlign.center, style: TextStyle(color: NeuroColors.muted, fontSize: 11)),
        ],
      );
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.days});

  final List<DailyBest> days;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('30-DAY TREND',
                  style: TextStyle(color: NeuroColors.text, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
              const SizedBox(height: 6),
              const Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _LegendKey(color: NeuroColors.go, label: 'daily best'),
                  _LegendKey(color: NeuroColors.muted, label: '7-day mean'),
                  _LegendKey(color: NeuroColors.faint, label: 'attempts'),
                ],
              ),
              const SizedBox(height: 12),
              TrendChart(days: days),
            ],
          ),
        ),
      );
}

class _LegendKey extends StatelessWidget {
  const _LegendKey({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: NeuroColors.muted, fontSize: 10)),
        ],
      );
}

class _TodaySessions extends StatelessWidget {
  const _TodaySessions({required this.sessions, required this.hallOfFame});

  final List<SessionResult> sessions;
  final List<SessionResult> hallOfFame;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text("TODAY'S SESSIONS",
                  style: TextStyle(color: NeuroColors.text, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
              const SizedBox(height: 8),
              if (sessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text("No sessions yet today. Your first full protocol sets today's bar.",
                      style: TextStyle(color: NeuroColors.muted, fontSize: 13)),
                ),
              for (final session in sessions) _SessionRow(session: session, hallOfFame: hallOfFame),
            ],
          ),
        ),
      );
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, required this.hallOfFame});

  final SessionResult session;
  final List<SessionResult> hallOfFame;

  @override
  Widget build(BuildContext context) {
    final hallIndex = hallOfFame.indexWhere((entry) => entry.id == session.id);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(Readout.clock(session.startedAt),
              style: const TextStyle(color: NeuroColors.muted, fontSize: 13)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(session.mode.label,
                style: const TextStyle(color: NeuroColors.text, fontSize: 14)),
          ),
          if (hallIndex >= 0) ...[
            RankBadge(rank: hallIndex + 1, size: 24),
            const SizedBox(width: 8),
          ] else if (!session.mode.ranked) ...[
            const Text('practice', style: TextStyle(color: NeuroColors.faint, fontSize: 11)),
            const SizedBox(width: 8),
          ],
          Text(Readout.score(session.dri),
              style: const TextStyle(color: NeuroColors.text, fontSize: 16, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}
