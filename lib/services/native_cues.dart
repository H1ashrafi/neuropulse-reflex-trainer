import 'package:flutter/services.dart';

final class NativeCues {
  const NativeCues();

  static const MethodChannel _channel = MethodChannel('neuropulse/native');

  Future<void> beep(Duration length) async {
    try {
      await _channel.invokeMethod<void>('beep', {'ms': length.inMilliseconds});
    } on MissingPluginException {
      await SystemSound.play(SystemSoundType.click);
    }
  }

  Future<void> keepScreenOn(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('keepScreenOn', {'on': enabled});
    } on MissingPluginException {
      return;
    }
  }
}
