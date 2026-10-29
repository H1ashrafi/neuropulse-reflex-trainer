import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../models/session_result.dart';
import 'dri_engine.dart';

enum TrainingState {
  idle,
  countdown,
  jitterWait,
  activeStimulus,
  responseCaptured,
  intervalRest,
  sessionComplete,
}

abstract interface class MonotonicClock {
  int get elapsedMicros;
}

final class StopwatchClock implements MonotonicClock {
  StopwatchClock() : _watch = Stopwatch()..start();

  final Stopwatch _watch;

  @override
  int get elapsedMicros => _watch.elapsedMicroseconds;
}

abstract interface class FrameScheduler {
  void afterNextFrame(VoidCallback callback);
}

final class BindingFrameScheduler implements FrameScheduler {
  const BindingFrameScheduler();

  @override
  void afterNextFrame(VoidCallback callback) {
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) => callback());
    binding.scheduleFrame();
  }
}

abstract interface class CueSink {
  void phaseStarted(PhaseKind phase);

  void countdownTick();

  void stimulusPresented(CueKind cue);

  void responseJudged(TrialOutcome outcome);

  void metronomeBeat();

  void sessionFinished();
}

final class LatencyProbe {
  LatencyProbe(this._clock);

  final MonotonicClock _clock;
  int? _armedAt;

  bool get isArmed => _armedAt != null;

  void arm() => _armedAt = _clock.elapsedMicros;

  void disarm() => _armedAt = null;

  int elapsedAt(int now) => now - (_armedAt ?? now);

  int capture(int now) {
    final elapsed = elapsedAt(now);
    _armedAt = null;
    return elapsed;
  }
}

final class PhaseSpec {
  const PhaseSpec(this.kind, this.duration);

  final PhaseKind kind;
  final Duration duration;
}

final class ProtocolPlan {
  const ProtocolPlan(this.mode, this.phases);

  factory ProtocolPlan.forMode(ProtocolMode mode) => switch (mode) {
        ProtocolMode.fullProtocol => const ProtocolPlan(ProtocolMode.fullProtocol, [
            PhaseSpec(PhaseKind.saccade, Duration(minutes: 2)),
            PhaseSpec(PhaseKind.simpleReaction, Duration(minutes: 3)),
            PhaseSpec(PhaseKind.goNoGo, Duration(minutes: 3)),
            PhaseSpec(PhaseKind.burstCadence, Duration(minutes: 2)),
          ]),
        ProtocolMode.quickProtocol => const ProtocolPlan(ProtocolMode.quickProtocol, [
            PhaseSpec(PhaseKind.saccade, Duration(seconds: 30)),
            PhaseSpec(PhaseKind.simpleReaction, Duration(minutes: 1)),
            PhaseSpec(PhaseKind.goNoGo, Duration(minutes: 1)),
            PhaseSpec(PhaseKind.burstCadence, Duration(seconds: 30)),
          ]),
        ProtocolMode.simpleReaction => const ProtocolPlan(ProtocolMode.simpleReaction, [
            PhaseSpec(PhaseKind.simpleReaction, Duration(minutes: 3)),
          ]),
        ProtocolMode.goNoGo => const ProtocolPlan(ProtocolMode.goNoGo, [
            PhaseSpec(PhaseKind.goNoGo, Duration(minutes: 3)),
          ]),
      };

  final ProtocolMode mode;
  final List<PhaseSpec> phases;

  Duration get totalDuration =>
      phases.fold(Duration.zero, (total, phase) => total + phase.duration);
}

final class EngineTimings {
  const EngineTimings({
    this.countdown = const Duration(seconds: 3),
    this.foreperiodMin = const Duration(milliseconds: 1500),
    this.foreperiodMax = const Duration(milliseconds: 4500),
    this.feedback = const Duration(milliseconds: 600),
    this.rest = const Duration(milliseconds: 400),
    this.saccadeTimeout = const Duration(milliseconds: 1500),
    this.saccadeFeedback = const Duration(milliseconds: 150),
    this.saccadeRest = Duration.zero,
    this.transitionSlack = const Duration(milliseconds: 100),
    this.goProbability = 0.7,
  });

  final Duration countdown;
  final Duration foreperiodMin;
  final Duration foreperiodMax;
  final Duration feedback;
  final Duration rest;
  final Duration saccadeTimeout;
  final Duration saccadeFeedback;
  final Duration saccadeRest;
  final Duration transitionSlack;
  final double goProbability;
}

final class TrialFeedback {
  const TrialFeedback({required this.outcome, required this.cue, required this.reactionMicros});

  final TrialOutcome outcome;
  final CueKind cue;
  final int? reactionMicros;

  double? get reactionMs {
    final micros = reactionMicros;
    return micros == null ? null : micros / ReactionWindow.microsPerMilli;
  }
}

final class SaccadeDrill {
  static const double targetRadiusFraction = 0.085;
  static const double hitSlackFactor = 1.35;
  static const double edgeMargin = 0.14;
  static const double minimumHop = 0.3;
  static const int maxHopDraws = 12;

  final RunningStats _acquisitionMs = RunningStats();
  Offset _target = const Offset(0.5, 0.5);
  int _shown = 0;
  int _hits = 0;
  int _offTarget = 0;

  Offset get target => _target;

  int get shown => _shown;

  int get hits => _hits;

  double radiusIn(Size area) => targetRadiusFraction * area.shortestSide;

  void spawn(math.Random random) {
    var candidate = _draw(random);
    for (var draw = 1; draw < maxHopDraws && _tooClose(candidate); draw += 1) {
      candidate = _draw(random);
    }
    _target = _tooClose(candidate) ? _farthestCorner() : candidate;
    _shown += 1;
  }

  bool _tooClose(Offset candidate) => (candidate - _target).distance < minimumHop;

  Offset _farthestCorner() => Offset(
        _target.dx < 0.5 ? 1 - edgeMargin : edgeMargin,
        _target.dy < 0.5 ? 1 - edgeMargin : edgeMargin,
      );

  bool contains(Offset position, Size area) {
    final center = Offset(_target.dx * area.width, _target.dy * area.height);
    return (position - center).distance <= radiusIn(area) * hitSlackFactor;
  }

  void recordHit(int acquisitionMicros) {
    _hits += 1;
    _acquisitionMs.add(acquisitionMicros / ReactionWindow.microsPerMilli);
  }

  void recordOffTarget() => _offTarget += 1;

  SaccadeSummary summary() => SaccadeSummary(
        shown: _shown,
        hits: _hits,
        offTargetTaps: _offTarget,
        meanAcquisitionMs: _acquisitionMs.mean,
      );

  Offset _draw(math.Random random) {
    const span = 1 - 2 * edgeMargin;
    return Offset(
      edgeMargin + random.nextDouble() * span,
      edgeMargin + random.nextDouble() * span,
    );
  }
}

enum BurstSegment { burst, cadence }

final class BurstAdvance {
  const BurstAdvance({required this.segmentChanged, required this.beat});

  static const BurstAdvance idle = BurstAdvance(segmentChanged: false, beat: false);

  final bool segmentChanged;
  final bool beat;
}

final class BurstDrill {
  static const int cycleMicros = 30 * Duration.microsecondsPerSecond;
  static const int burstMicros = 10 * Duration.microsecondsPerSecond;
  static const int beatPeriodMicros = 500 * Duration.microsecondsPerMillisecond;
  static const int minimumRatedBurstMicros = 2 * Duration.microsecondsPerSecond;

  final RunningStats _asynchronyMs = RunningStats();
  int _startedAt = 0;
  int _segmentIndex = 0;
  int _segmentStartedAt = 0;
  int _segmentTaps = 0;
  int _nextBeatAt = 0;
  int? _lastBeatAt;
  int _burstTaps = 0;
  int _cadenceTaps = 0;
  double? _peakTapsPerSecond;
  double? _lastAsynchronyMs;
  bool _running = false;

  BurstSegment get segment => _segmentIndex.isEven ? BurstSegment.burst : BurstSegment.cadence;

  int get segmentTaps => _segmentTaps;

  int get segmentEndsAt => _segmentStartedAt + _lengthOf(segment);

  double? get lastAsynchronyMs => _lastAsynchronyMs;

  double? get peakTapsPerSecond => _peakTapsPerSecond;

  static int _lengthOf(BurstSegment segment) =>
      segment == BurstSegment.burst ? burstMicros : cycleMicros - burstMicros;

  void begin(int now) {
    _startedAt = now;
    _running = true;
    _open(0, now);
  }

  BurstAdvance advance(int now) {
    if (!_running) {
      return BurstAdvance.idle;
    }
    final index = _segmentIndexAt(now);
    final changed = index != _segmentIndex;
    if (changed) {
      _close(segmentEndsAt);
      _open(index, _segmentStartFor(index));
    }
    return BurstAdvance(segmentChanged: changed, beat: _consumeBeat(now));
  }

  void tap(int now) {
    if (!_running) {
      return;
    }
    _segmentTaps += 1;
    if (segment == BurstSegment.burst) {
      _burstTaps += 1;
      return;
    }
    _cadenceTaps += 1;
    final offsetMs = (now - _nearestBeat(now)) / ReactionWindow.microsPerMilli;
    _lastAsynchronyMs = offsetMs;
    _asynchronyMs.add(offsetMs.abs());
  }

  void finish(int now) {
    if (!_running) {
      return;
    }
    _close(math.min(now, segmentEndsAt));
    _running = false;
  }

  BurstSummary summary() => BurstSummary(
        burstTaps: _burstTaps,
        cadenceTaps: _cadenceTaps,
        peakTapsPerSecond: _peakTapsPerSecond,
        meanAsynchronyMs: _asynchronyMs.mean,
      );

  int _segmentIndexAt(int now) {
    final elapsed = math.max(0, now - _startedAt);
    final cycle = elapsed ~/ cycleMicros;
    final inCycle = elapsed % cycleMicros;
    return cycle * 2 + (inCycle < burstMicros ? 0 : 1);
  }

  int _segmentStartFor(int index) =>
      _startedAt + (index ~/ 2) * cycleMicros + (index.isOdd ? burstMicros : 0);

  void _open(int index, int startedAt) {
    _segmentIndex = index;
    _segmentStartedAt = startedAt;
    _segmentTaps = 0;
    _lastBeatAt = null;
    _nextBeatAt = startedAt + beatPeriodMicros;
  }

  void _close(int endedAt) {
    final lengthMicros = endedAt - _segmentStartedAt;
    if (segment != BurstSegment.burst || lengthMicros < minimumRatedBurstMicros) {
      return;
    }
    final rate = _segmentTaps / (lengthMicros / Duration.microsecondsPerSecond);
    final peak = _peakTapsPerSecond;
    _peakTapsPerSecond = peak == null ? rate : math.max(peak, rate);
  }

  bool _consumeBeat(int now) {
    if (segment != BurstSegment.cadence || now < _nextBeatAt) {
      return false;
    }
    final skippedBeats = (now - _nextBeatAt) ~/ beatPeriodMicros;
    final beatAt = _nextBeatAt + skippedBeats * beatPeriodMicros;
    _lastBeatAt = beatAt;
    _nextBeatAt = beatAt + beatPeriodMicros;
    return true;
  }

  int _nearestBeat(int now) {
    final last = _lastBeatAt;
    if (last == null) {
      return _nextBeatAt;
    }
    return now - last <= _nextBeatAt - now ? last : _nextBeatAt;
  }
}

final class TimingEngine extends ChangeNotifier {
  TimingEngine({
    required this.plan,
    required MonotonicClock clock,
    required this._frames,
    required this._cues,
    math.Random? random,
    this.timings = const EngineTimings(),
  })  : _clock = clock,
        _random = random ?? math.Random(),
        _probe = LatencyProbe(clock) {
    if (plan.phases.isEmpty) {
      throw ArgumentError.value(plan, 'plan', 'needs at least one phase');
    }
  }

  static const int _microsPerSecond = Duration.microsecondsPerSecond;

  final ProtocolPlan plan;
  final EngineTimings timings;
  final SaccadeDrill saccade = SaccadeDrill();
  final BurstDrill burst = BurstDrill();
  final MonotonicClock _clock;
  final FrameScheduler _frames;
  final CueSink _cues;
  final math.Random _random;
  final LatencyProbe _probe;
  final ResponseClassifier _classifier = const ResponseClassifier();
  final List<TrialRecord> _trials = [];

  late final DateTime _startedAtWall;
  TrainingState _state = TrainingState.idle;
  int _phaseIndex = 0;
  int _sessionStartedAt = 0;
  int _phaseEndsAt = 0;
  int _deadline = 0;
  int _countdownValue = 0;
  int _shownRemainingSecond = -1;
  int _presentationToken = 0;
  int _beatCount = 0;
  CueKind _cue = CueKind.go;
  bool _awaitingPresentation = false;
  bool _aborted = false;
  TrialFeedback? _lastFeedback;
  SessionResult? _result;

  int get _now => _clock.elapsedMicros;

  TrainingState get state => _state;

  PhaseSpec get phase => plan.phases[_phaseIndex];

  int get phaseNumber => _phaseIndex + 1;

  CueKind get cue => _cue;

  bool get stimulusArmed => _probe.isArmed;

  int get countdownValue => _countdownValue;

  int get beatCount => _beatCount;

  TrialFeedback? get lastFeedback => _lastFeedback;

  SessionResult? get result => _result;

  bool get aborted => _aborted;

  List<TrialRecord> get trials => List.unmodifiable(_trials);

  Duration get protocolRemaining {
    if (_aborted || _state == TrainingState.sessionComplete) {
      return Duration.zero;
    }
    if (_state == TrainingState.idle) {
      return plan.totalDuration;
    }
    final currentPhaseLeft = math.max(0, _phaseEndsAt - _now);
    final laterPhases = plan.phases
        .skip(_phaseIndex + 1)
        .fold(0, (total, spec) => total + spec.duration.inMicroseconds);
    return Duration(microseconds: currentPhaseLeft + laterPhases);
  }

  Duration get burstSegmentRemaining => Duration(
        microseconds: math.max(0, math.min(burst.segmentEndsAt, _phaseEndsAt) - _now),
      );

  void start(DateTime wallClockStart) {
    if (_state != TrainingState.idle || _aborted) {
      return;
    }
    _startedAtWall = wallClockStart.toUtc();
    _sessionStartedAt = _now;
    _enterPhase(0, _sessionStartedAt);
  }

  void abort() {
    if (_aborted || _state == TrainingState.sessionComplete) {
      return;
    }
    _aborted = true;
    _probe.disarm();
    _awaitingPresentation = false;
    _state = TrainingState.idle;
    notifyListeners();
  }

  void tick() {
    final now = _now;
    switch (_state) {
      case TrainingState.idle || TrainingState.sessionComplete:
        return;
      case TrainingState.countdown:
        _tickCountdown(now);
      case TrainingState.jitterWait:
        if (now >= _deadline) {
          _presentStimulus();
        }
      case TrainingState.activeStimulus:
        _tickStimulus(now);
      case TrainingState.responseCaptured:
        if (now >= _deadline) {
          _enter(TrainingState.intervalRest, now + _restFor(phase.kind).inMicroseconds);
        }
      case TrainingState.intervalRest:
        if (now >= _deadline) {
          _beginTrial(now);
        }
    }
    _notifyOnSecondChange();
  }

  void onPointerDown(Offset position, Size area) {
    final now = _now;
    switch (_state) {
      case TrainingState.jitterWait:
        _recordTrial(TrialOutcome.anticipationFault, null, now);
      case TrainingState.activeStimulus:
        _onStimulusTap(now, position, area);
      case TrainingState.idle ||
            TrainingState.countdown ||
            TrainingState.responseCaptured ||
            TrainingState.intervalRest ||
            TrainingState.sessionComplete:
        return;
    }
  }

  void _enter(TrainingState next, int deadline) {
    _state = next;
    _deadline = deadline;
    notifyListeners();
  }

  void _enterPhase(int index, int now) {
    if (index >= plan.phases.length) {
      _complete(now);
      return;
    }
    _phaseIndex = index;
    _phaseEndsAt = now + phase.duration.inMicroseconds;
    final countdownMicros = timings.countdown.inMicroseconds;
    _countdownValue = _ceilSeconds(countdownMicros);
    _cues.phaseStarted(phase.kind);
    _cues.countdownTick();
    _enter(TrainingState.countdown, now + countdownMicros);
  }

  void _advancePhase(int now) => _enterPhase(_phaseIndex + 1, now);

  void _tickCountdown(int now) {
    if (now >= _deadline) {
      _startPhaseRun(now);
      return;
    }
    final secondsLeft = _ceilSeconds(_deadline - now);
    if (secondsLeft != _countdownValue) {
      _countdownValue = secondsLeft;
      _cues.countdownTick();
      notifyListeners();
    }
  }

  void _startPhaseRun(int now) {
    if (phase.kind == PhaseKind.burstCadence) {
      burst.begin(now);
      _enter(TrainingState.activeStimulus, _phaseEndsAt);
      return;
    }
    _beginTrial(now);
  }

  void _beginTrial(int now) {
    switch (phase.kind) {
      case PhaseKind.saccade:
        _beginSaccadeTarget(now);
      case PhaseKind.simpleReaction || PhaseKind.goNoGo:
        _beginReactionTrial(now);
      case PhaseKind.burstCadence:
        _advancePhase(now);
    }
  }

  bool _trialFits(int now, int responseWindowMicros, Duration feedback, Duration rest) {
    final trialCost = responseWindowMicros +
        feedback.inMicroseconds +
        rest.inMicroseconds +
        timings.transitionSlack.inMicroseconds;
    return now + trialCost <= _phaseEndsAt;
  }

  void _beginSaccadeTarget(int now) {
    final fits = _trialFits(
      now,
      timings.saccadeTimeout.inMicroseconds,
      timings.saccadeFeedback,
      timings.saccadeRest,
    );
    if (!fits) {
      _advancePhase(now);
      return;
    }
    saccade.spawn(_random);
    _cue = CueKind.go;
    _presentStimulus();
  }

  void _beginReactionTrial(int now) {
    final foreperiod = _drawForeperiodMicros();
    final fits = _trialFits(
      now,
      foreperiod + ReactionWindow.timeoutMicros,
      timings.feedback,
      timings.rest,
    );
    if (!fits) {
      _advancePhase(now);
      return;
    }
    _cue = _drawCue();
    _enter(TrainingState.jitterWait, now + foreperiod);
  }

  int _drawForeperiodMicros() {
    final shortest = timings.foreperiodMin.inMicroseconds;
    final span = timings.foreperiodMax.inMicroseconds - shortest;
    return shortest + (_random.nextDouble() * span).round();
  }

  CueKind _drawCue() {
    final inhibitionTrial =
        phase.kind == PhaseKind.goNoGo && _random.nextDouble() >= timings.goProbability;
    return inhibitionTrial ? CueKind.noGo : CueKind.go;
  }

  void _presentStimulus() {
    _probe.disarm();
    _awaitingPresentation = true;
    final token = ++_presentationToken;
    _enter(TrainingState.activeStimulus, _phaseEndsAt);
    _frames.afterNextFrame(() => _markPresented(token));
  }

  void _markPresented(int token) {
    final stale = token != _presentationToken ||
        !_awaitingPresentation ||
        _state != TrainingState.activeStimulus;
    if (stale) {
      return;
    }
    _awaitingPresentation = false;
    _probe.arm();
    _cues.stimulusPresented(_cue);
  }

  void _tickStimulus(int now) {
    switch (phase.kind) {
      case PhaseKind.saccade:
        if (_probe.isArmed && _probe.elapsedAt(now) > timings.saccadeTimeout.inMicroseconds) {
          _probe.disarm();
          _judge(
            const TrialFeedback(outcome: TrialOutcome.timeout, cue: CueKind.go, reactionMicros: null),
            now + timings.saccadeFeedback.inMicroseconds,
          );
        }
      case PhaseKind.simpleReaction || PhaseKind.goNoGo:
        if (_probe.isArmed && _probe.elapsedAt(now) > ReactionWindow.timeoutMicros) {
          _recordTrial(_classifier.classifySilence(_cue), null, now);
        }
      case PhaseKind.burstCadence:
        if (now >= _phaseEndsAt) {
          burst.finish(now);
          _advancePhase(now);
          return;
        }
        _advanceBurst(now);
    }
  }

  void _onStimulusTap(int now, Offset position, Size area) {
    switch (phase.kind) {
      case PhaseKind.saccade:
        _onSaccadeTap(now, position, area);
      case PhaseKind.simpleReaction || PhaseKind.goNoGo:
        if (!_probe.isArmed) {
          _recordTrial(TrialOutcome.anticipationFault, null, now);
          return;
        }
        final micros = _probe.capture(now);
        _recordTrial(_classifier.classifyTap(_cue, micros), micros, now);
      case PhaseKind.burstCadence:
        if (now >= _phaseEndsAt) {
          return;
        }
        _advanceBurst(now);
        burst.tap(now);
        notifyListeners();
    }
  }

  void _onSaccadeTap(int now, Offset position, Size area) {
    if (!_probe.isArmed) {
      return;
    }
    if (!saccade.contains(position, area)) {
      saccade.recordOffTarget();
      return;
    }
    final micros = _probe.capture(now);
    saccade.recordHit(micros);
    _judge(
      TrialFeedback(outcome: TrialOutcome.hit, cue: CueKind.go, reactionMicros: micros),
      now + timings.saccadeFeedback.inMicroseconds,
    );
  }

  void _advanceBurst(int now) {
    final step = burst.advance(now);
    if (step.beat) {
      _beatCount += 1;
      _cues.metronomeBeat();
    }
    if (step.beat || step.segmentChanged) {
      notifyListeners();
    }
  }

  void _recordTrial(TrialOutcome outcome, int? reactionMicros, int now) {
    _awaitingPresentation = false;
    _probe.disarm();
    _trials.add(TrialRecord(
      phase: phase.kind,
      cue: _cue,
      outcome: outcome,
      reactionMicros: reactionMicros,
    ));
    _judge(
      TrialFeedback(outcome: outcome, cue: _cue, reactionMicros: reactionMicros),
      now + timings.feedback.inMicroseconds,
    );
  }

  void _judge(TrialFeedback feedback, int until) {
    _lastFeedback = feedback;
    _cues.responseJudged(feedback.outcome);
    _enter(TrainingState.responseCaptured, until);
  }

  Duration _restFor(PhaseKind kind) =>
      kind == PhaseKind.saccade ? timings.saccadeRest : timings.rest;

  void _complete(int now) {
    final reaction = const ReactionSummarizer().summarize(_trials);
    final elapsedMs = (now - _sessionStartedAt) ~/ Duration.microsecondsPerMillisecond;
    _result = SessionResult(
      id: SessionResult.idFor(_startedAtWall, plan.mode),
      mode: plan.mode,
      startedAt: _startedAtWall,
      dayKey: DayKey.fromLocal(_startedAtWall),
      durationMs: math.min(elapsedMs, MetricLimits.maxDurationMs),
      dri: const DriCalculator().score(reaction),
      reaction: reaction,
      saccade: saccade.summary(),
      burst: burst.summary(),
    );
    _probe.disarm();
    _cues.sessionFinished();
    _enter(TrainingState.sessionComplete, now);
  }

  void _notifyOnSecondChange() {
    final remainingSecond = protocolRemaining.inSeconds;
    if (remainingSecond != _shownRemainingSecond) {
      _shownRemainingSecond = remainingSecond;
      notifyListeners();
    }
  }

  static int _ceilSeconds(int micros) => (micros + _microsPerSecond - 1) ~/ _microsPerSecond;
}
