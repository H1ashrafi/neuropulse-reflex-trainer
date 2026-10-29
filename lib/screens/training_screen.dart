import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../models/session_result.dart';
import '../services/feedback_service.dart';
import '../services/native_cues.dart';
import '../services/storage_service.dart';
import '../services/timing_engine.dart';
import '../theme/neuro_theme.dart';
import 'result_screen.dart';

class TrainingScreen extends StatefulWidget {
  const TrainingScreen({
    super.key,
    required this.mode,
    required this.repository,
    required this.feedback,
  });

  static const String leftAppMessage =
      'Session stopped: the app left the screen, so its timing was discarded.';
  static const String stoppedMessage = 'Session stopped. Nothing was saved.';

  final ProtocolMode mode;
  final ReflexRepository repository;
  final FeedbackService feedback;

  @override
  State<TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends State<TrainingScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TimingEngine _engine;
  late final Ticker _ticker;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _engine = TimingEngine(
      plan: ProtocolPlan.forMode(widget.mode),
      clock: StopwatchClock(),
      frames: const BindingFrameScheduler(),
      cues: widget.feedback,
    )..addListener(_onEngineChanged);
    _ticker = createTicker((_) => _engine.tick());
    unawaited(_ticker.start());
    WidgetsBinding.instance.addObserver(this);
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    unawaited(const NativeCues().keepScreenOn(true));
    _engine.start(DateTime.now());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _engine
      ..removeListener(_onEngineChanged)
      ..dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(const NativeCues().keepScreenOn(false));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final leftScreen = state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (leftScreen) {
      _stop(TrainingScreen.leftAppMessage);
    }
  }

  void _stop(String message) {
    if (_leaving) {
      return;
    }
    _leaving = true;
    _engine.abort();
    _ticker.stop();
    Navigator.of(context).pop(message);
  }

  void _onEngineChanged() {
    final result = _engine.result;
    if (_leaving || result == null) {
      return;
    }
    _leaving = true;
    _ticker.stop();
    unawaited(_finish(result));
  }

  Future<void> _finish(SessionResult result) async {
    final receipt = await widget.repository.record(result);
    if (!mounted) {
      return;
    }
    unawaited(Navigator.of(context).pushReplacement(MaterialPageRoute<String>(
      builder: (_) => ResultScreen(
        result: result,
        receipt: receipt,
        repository: widget.repository,
        feedback: widget.feedback,
      ),
    )));
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            _stop(TrainingScreen.stoppedMessage);
          }
        },
        child: Scaffold(
          backgroundColor: NeuroColors.black,
          body: SafeArea(
            child: Column(
              children: [
                ListenableBuilder(
                  listenable: _engine,
                  builder: (context, _) => _TopBar(
                    engine: _engine,
                    onClose: () => _stop(TrainingScreen.stoppedMessage),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(builder: (context, constraints) {
                    final area = constraints.biggest;
                    return Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) => _engine.onPointerDown(event.localPosition, area),
                      child: ListenableBuilder(
                        listenable: _engine,
                        builder: (context, _) => _Stage(engine: _engine, area: area),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      );
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.engine, required this.onClose});

  final TimingEngine engine;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 16, 4),
        child: Row(
          children: [
            IconButton(
              onPressed: onClose,
              tooltip: 'Stop session',
              icon: const Icon(Icons.close, color: NeuroColors.muted),
            ),
            Expanded(
              child: Text(
                'PHASE ${engine.phaseNumber}/${engine.plan.phases.length} · '
                '${engine.phase.kind.title.toUpperCase()}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: NeuroColors.muted, fontSize: 12, letterSpacing: 1.1),
              ),
            ),
            Text(
              Readout.countdown(engine.protocolRemaining),
              style: const TextStyle(
                color: NeuroColors.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );
}

class _Stage extends StatelessWidget {
  const _Stage({required this.engine, required this.area});

  final TimingEngine engine;
  final Size area;

  @override
  Widget build(BuildContext context) {
    final kind = engine.phase.kind;
    return switch (engine.state) {
      TrainingState.idle => const SizedBox.expand(),
      TrainingState.countdown => _CountdownView(engine: engine),
      TrainingState.jitterWait || TrainingState.intervalRest =>
        kind == PhaseKind.saccade ? const SizedBox.expand() : const _Fixation(),
      TrainingState.activeStimulus => switch (kind) {
          PhaseKind.saccade => _SaccadeView(engine: engine, area: area, flash: null),
          PhaseKind.simpleReaction || PhaseKind.goNoGo => _CueView(cue: engine.cue),
          PhaseKind.burstCadence => _BurstView(engine: engine),
        },
      TrainingState.responseCaptured => kind == PhaseKind.saccade
          ? _SaccadeView(engine: engine, area: area, flash: engine.lastFeedback)
          : _FeedbackView(feedback: engine.lastFeedback),
      TrainingState.sessionComplete => const _Scoring(),
    };
  }
}

class _CountdownView extends StatelessWidget {
  const _CountdownView({required this.engine});

  final TimingEngine engine;

  @override
  Widget build(BuildContext context) {
    final kind = engine.phase.kind;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'PHASE ${engine.phaseNumber} OF ${engine.plan.phases.length}',
              style: const TextStyle(color: NeuroColors.muted, fontSize: 12, letterSpacing: 2),
            ),
            const SizedBox(height: 8),
            Text(kind.title,
                textAlign: TextAlign.center,
                style: const TextStyle(color: NeuroColors.text, fontSize: 28, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Text(kind.instruction,
                textAlign: TextAlign.center,
                style: const TextStyle(color: NeuroColors.muted, fontSize: 15, height: 1.4)),
            const SizedBox(height: 36),
            Text('${engine.countdownValue}',
                style: const TextStyle(color: NeuroColors.go, fontSize: 96, fontWeight: FontWeight.w900)),
          ],
        ),
      ),
    );
  }
}

class _Fixation extends StatelessWidget {
  const _Fixation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand(
        child: Center(
          child: Text('+',
              style: TextStyle(color: NeuroColors.muted, fontSize: 56, fontWeight: FontWeight.w300)),
        ),
      );
}

class _CueView extends StatelessWidget {
  const _CueView({required this.cue});

  final CueKind cue;

  @override
  Widget build(BuildContext context) {
    final go = cue == CueKind.go;
    return ColoredBox(
      color: go ? NeuroColors.go : NeuroColors.noGo,
      child: SizedBox.expand(
        child: Center(
          child: Text(go ? 'TAP' : 'HOLD',
              style: const TextStyle(color: NeuroColors.black, fontSize: 56, fontWeight: FontWeight.w900)),
        ),
      ),
    );
  }
}

class _FeedbackView extends StatelessWidget {
  const _FeedbackView({required this.feedback});

  final TrialFeedback? feedback;

  @override
  Widget build(BuildContext context) {
    final shown = feedback;
    if (shown == null) {
      return const _Fixation();
    }
    final reaction = shown.reactionMs;
    final (headline, detail, color) = switch (shown.outcome) {
      TrialOutcome.hit => (Readout.millis(reaction), 'HIT', NeuroColors.go),
      TrialOutcome.anticipationFault => (
          'FALSE START',
          reaction == null ? 'tapped before the cue' : 'under 100 ms counts as anticipation',
          NeuroColors.noGo,
        ),
      TrialOutcome.lateResponse => ('LATE', Readout.millis(reaction), NeuroColors.noGo),
      TrialOutcome.timeout => ('MISS', 'no tap within 600 ms', NeuroColors.noGo),
      TrialOutcome.correctRejection => ('GOOD HOLD', 'no-go inhibited', NeuroColors.go),
      TrialOutcome.commissionError => ('NO-GO TAPPED', 'hold still on red', NeuroColors.noGo),
    };
    return SizedBox.expand(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(headline, style: TextStyle(color: color, fontSize: 48, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text(detail, style: const TextStyle(color: NeuroColors.muted, fontSize: 14, letterSpacing: 1)),
        ],
      ),
    );
  }
}

class _SaccadeView extends StatelessWidget {
  const _SaccadeView({required this.engine, required this.area, required this.flash});

  final TimingEngine engine;
  final Size area;
  final TrialFeedback? flash;

  @override
  Widget build(BuildContext context) {
    final drill = engine.saccade;
    final radius = drill.radiusIn(area);
    final target = drill.target;
    final shown = flash;
    final color = switch (shown?.outcome) {
      null => NeuroColors.go,
      TrialOutcome.hit => NeuroColors.text,
      _ => NeuroColors.noGo,
    };
    return Stack(
      children: [
        Positioned(
          left: target.dx * area.width - radius,
          top: target.dy * area.height - radius,
          child: Container(
            width: radius * 2,
            height: radius * 2,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 20,
          child: Text(
            '${drill.hits}/${drill.shown} targets'
            '${shown?.reactionMs == null ? '' : ' · ${Readout.millis(shown?.reactionMs)}'}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: NeuroColors.muted, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

class _BurstView extends StatelessWidget {
  const _BurstView({required this.engine});

  static const double pulseSize = 170;
  static const Duration pulseFade = Duration(milliseconds: 380);

  final TimingEngine engine;

  String _offsetLabel(double? offsetMs) {
    if (offsetMs == null) {
      return 'tap with the beat';
    }
    final direction = offsetMs >= 0 ? 'late' : 'early';
    return '${offsetMs.abs().round()} ms $direction';
  }

  @override
  Widget build(BuildContext context) {
    final drill = engine.burst;
    final bursting = drill.segment == BurstSegment.burst;
    return SizedBox.expand(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(bursting ? 'BURST' : 'CADENCE · 120 BPM',
              style: TextStyle(
                color: bursting ? NeuroColors.go : NeuroColors.text,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              )),
          const SizedBox(height: 6),
          Text(bursting ? 'tap as fast as you can' : 'tap on every beat',
              style: const TextStyle(color: NeuroColors.muted, fontSize: 14)),
          const SizedBox(height: 28),
          SizedBox(
            width: pulseSize,
            height: pulseSize,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (!bursting)
                  TweenAnimationBuilder<double>(
                    key: ValueKey(engine.beatCount),
                    tween: Tween(begin: 1, end: 0),
                    duration: pulseFade,
                    builder: (context, strength, _) => Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: NeuroColors.go.withValues(alpha: 0.15 + 0.85 * strength),
                          width: 2 + 6 * strength,
                        ),
                      ),
                    ),
                  ),
                Text(
                  bursting ? '${drill.segmentTaps}' : _offsetLabel(drill.lastAsynchronyMs),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: NeuroColors.text,
                    fontSize: bursting ? 88 : 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text('${engine.burstSegmentRemaining.inSeconds}s left in this block',
              style: const TextStyle(color: NeuroColors.muted, fontSize: 13)),
          if (drill.peakTapsPerSecond != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('peak ${Readout.rate(drill.peakTapsPerSecond)}',
                  style: const TextStyle(color: NeuroColors.muted, fontSize: 13)),
            ),
        ],
      ),
    );
  }
}

class _Scoring extends StatelessWidget {
  const _Scoring();

  @override
  Widget build(BuildContext context) => const Center(
        child: Text('Scoring…', style: TextStyle(color: NeuroColors.muted, fontSize: 16)),
      );
}
