import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuropulse/services/feedback_service.dart';
import 'package:neuropulse/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neuropulse/native');
  late List<MethodCall> nativeCalls;

  setUp(() {
    nativeCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('countdown and metronome use the native tone with their own lengths', () async {
    final feedback = FeedbackService(MemoryStore());
    feedback.countdownTick();
    feedback.metronomeBeat();
    await Future<void>.delayed(Duration.zero);
    expect(nativeCalls.map((call) => call.method), ['beep', 'beep']);
    expect(nativeCalls.map((call) => (call.arguments as Map<Object?, Object?>)['ms']), [70, 40]);
  });

  test('sound off sends no tone and the choice survives a restart', () async {
    final store = MemoryStore();
    final feedback = FeedbackService(store);
    await feedback.setSound(false);
    feedback.metronomeBeat();
    await Future<void>.delayed(Duration.zero);
    expect(nativeCalls, isEmpty);

    final reloaded = FeedbackService(store);
    await reloaded.load();
    expect(reloaded.soundOn, isFalse);
    expect(reloaded.hapticsOn, isTrue);
  });

  test('malformed settings fall back to defaults instead of failing', () async {
    final store = MemoryStore()..values[FeedbackService.settingsKey] = '{"sound": "loud"';
    final feedback = FeedbackService(store);
    await feedback.load();
    expect(feedback.soundOn, isTrue);
    store.values[FeedbackService.settingsKey] = '{"sound": "loud", "haptics": 3}';
    await feedback.load();
    expect(feedback.soundOn, isTrue);
  });
}
