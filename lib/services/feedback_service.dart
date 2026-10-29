import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/session_result.dart';
import 'native_cues.dart';
import 'storage_service.dart';
import 'timing_engine.dart';

final class FeedbackService extends ChangeNotifier implements CueSink {
  FeedbackService(this._store, {this._native = const NativeCues()});

  static const String settingsKey = 'neuropulse.settings';
  static const Duration countdownBeep = Duration(milliseconds: 70);
  static const Duration metronomeBeep = Duration(milliseconds: 40);

  final KeyValueStore _store;
  final NativeCues _native;
  bool _soundOn = true;
  bool _hapticsOn = true;

  bool get soundOn => _soundOn;

  bool get hapticsOn => _hapticsOn;

  Future<void> load() async {
    final Object? decoded;
    try {
      final raw = await _store.read(settingsKey);
      decoded = raw == null ? null : jsonDecode(raw);
    } on Exception {
      return;
    }
    if (decoded case {'sound': final bool sound, 'haptics': final bool haptics}) {
      _soundOn = sound;
      _hapticsOn = haptics;
      notifyListeners();
    }
  }

  Future<void> setSound(bool enabled) => _update(sound: enabled, haptics: _hapticsOn);

  Future<void> setHaptics(bool enabled) => _update(sound: _soundOn, haptics: enabled);

  Future<void> _update({required bool sound, required bool haptics}) {
    _soundOn = sound;
    _hapticsOn = haptics;
    notifyListeners();
    return _store.write(settingsKey, jsonEncode({'sound': sound, 'haptics': haptics}));
  }

  void _beep(Duration length) {
    if (_soundOn) {
      unawaited(_native.beep(length));
    }
  }

  void _buzz(Future<void> Function() pattern) {
    if (_hapticsOn) {
      unawaited(pattern());
    }
  }

  @override
  void phaseStarted(PhaseKind phase) => _buzz(HapticFeedback.mediumImpact);

  @override
  void countdownTick() => _beep(countdownBeep);

  @override
  void stimulusPresented(CueKind cue) {}

  @override
  void responseJudged(TrialOutcome outcome) => switch (outcome) {
        TrialOutcome.hit => _buzz(HapticFeedback.lightImpact),
        TrialOutcome.correctRejection => _buzz(HapticFeedback.selectionClick),
        TrialOutcome.anticipationFault ||
        TrialOutcome.lateResponse ||
        TrialOutcome.timeout ||
        TrialOutcome.commissionError =>
          _buzz(HapticFeedback.heavyImpact),
      };

  @override
  void metronomeBeat() => _beep(metronomeBeep);

  @override
  void sessionFinished() => _buzz(HapticFeedback.heavyImpact);
}
