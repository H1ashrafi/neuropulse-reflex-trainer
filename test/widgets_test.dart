import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuropulse/main.dart';
import 'package:neuropulse/models/session_result.dart';
import 'package:neuropulse/screens/result_screen.dart';
import 'package:neuropulse/services/feedback_service.dart';
import 'package:neuropulse/services/storage_service.dart';
import 'package:neuropulse/widgets/trend_chart.dart';

import 'support/fakes.dart';

final DateTime noon = DateTime(2026, 10, 27, 12);
final DayKey today = DayKey.fromLocal(noon);

Future<ReflexRepository> seededRepository(List<SessionResult> sessions) async {
  final repository = ReflexRepository(MemoryStore(), clock: () => noon);
  await repository.load();
  for (final session in sessions) {
    await repository.record(session);
  }
  return repository;
}

void main() {
  group('TrendGeometry', () {
    const geometry = TrendGeometry(Size(330, 180), 30);

    test('maps the plot edges to the first and last day and clamps outside', () {
      expect(geometry.indexAt(geometry.plot.left), 0);
      expect(geometry.indexAt(geometry.plot.right), 29);
      expect(geometry.indexAt(-50), 0);
      expect(geometry.indexAt(5000), 29);
      expect(geometry.indexAt(geometry.xFor(17)), 17);
    });

    test('puts 100 at the top of the plot and 0 at the bottom', () {
      expect(geometry.yFor(100), geometry.plot.top);
      expect(geometry.yFor(0), geometry.plot.bottom);
      expect(geometry.yFor(140), geometry.plot.top);
    });
  });

  test('MovingAverage skips empty days instead of treating them as zero', () {
    expect(const MovingAverage(3).over([null, 60, null, 90, null]), [null, 60, 60, 75, 90]);
  });

  testWidgets('dashboard renders an empty first-run state', (tester) async {
    final repository = await seededRepository(const []);
    await tester.pumpWidget(NeuroPulseApp(repository: repository, feedback: FeedbackService(MemoryStore())));
    expect(find.text('NeuroPulse'), findsOneWidget);
    expect(find.text('START 10-MIN PROTOCOL'), findsOneWidget);
    expect(find.text("TODAY'S BEST DRI"), findsOneWidget);
    await tester.scrollUntilVisible(find.text('HALL OF FAME'), 300);
    expect(find.textContaining('Open slot'), findsNWidgets(3));
  });

  testWidgets('dashboard shows today, the delta to yesterday and the hall of fame', (tester) async {
    final repository = await seededRepository([
      SessionFactory.make(day: today.shift(-1), dri: 70),
      SessionFactory.make(day: today, dri: 74.5, hour: 8),
      SessionFactory.make(day: today, dri: 61, hour: 9),
    ]);
    await tester.pumpWidget(NeuroPulseApp(repository: repository, feedback: FeedbackService(MemoryStore())));
    expect(find.text('74.5'), findsWidgets);
    expect(find.text('+4.5 pts vs yesterday'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('HALL OF FAME'), 300);
    expect(find.text('#1'), findsWidgets);
  });

  testWidgets('dashboard fits a 320 dp wide phone without overflow', (tester) async {
    tester.view.physicalSize = const Size(960, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = await seededRepository([
      SessionFactory.make(day: today.shift(-1), dri: 70),
      SessionFactory.make(day: today, dri: 74.5),
      SessionFactory.make(day: today, dri: 91, mode: ProtocolMode.quickProtocol),
    ]);
    await tester.pumpWidget(NeuroPulseApp(repository: repository, feedback: FeedbackService(MemoryStore())));
    await tester.scrollUntilVisible(find.text("TODAY'S SESSIONS"), 300);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the trend chart selects a day', (tester) async {
    final repository = await seededRepository([SessionFactory.make(day: today.shift(-3), dri: 58)]);
    final days = repository.ledger.dailyBests(today);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 330, child: TrendChart(days: days)))));
    expect(find.textContaining('best 58.0'), findsOneWidget);
    final chart = tester.getTopLeft(find.byType(CustomPaint).last);
    const geometry = TrendGeometry(Size(330, 180), 30);
    await tester.tapAt(chart + Offset(geometry.xFor(29), 60));
    await tester.pump();
    expect(find.text('no ranked attempt'), findsOneWidget);
  });

  testWidgets('a new all-time record is celebrated on the result screen', (tester) async {
    final repository = await seededRepository(const []);
    final session = SessionFactory.make(day: today, dri: 83.4);
    final receipt = await repository.record(session);
    await tester.pumpWidget(MaterialApp(
      home: ResultScreen(
        result: session,
        receipt: receipt,
        repository: repository,
        feedback: FeedbackService(MemoryStore()),
      ),
    ));
    expect(find.text('ALL-TIME RANK #1!'), findsOneWidget);
    expect(find.text('83.4'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a practice result says it is not ranked', (tester) async {
    final repository = await seededRepository(const []);
    final session = SessionFactory.make(day: today, dri: 90, mode: ProtocolMode.goNoGo);
    final receipt = await repository.record(session);
    await tester.pumpWidget(MaterialApp(
      home: ResultScreen(
        result: session,
        receipt: receipt,
        repository: repository,
        feedback: FeedbackService(MemoryStore()),
      ),
    ));
    expect(find.text('PRACTICE · NOT RANKED'), findsOneWidget);
  });

  testWidgets('starting and stopping a session returns to the dashboard with a message', (tester) async {
    final repository = await seededRepository(const []);
    await tester.pumpWidget(NeuroPulseApp(repository: repository, feedback: FeedbackService(MemoryStore())));
    await tester.tap(find.text('START 10-MIN PROTOCOL'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('PHASE 1 OF 4'), findsOneWidget);
    expect(find.text('Visual saccades'), findsOneWidget);
    await tester.tap(find.byTooltip('Stop session'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('START 10-MIN PROTOCOL'), findsOneWidget);
    expect(find.text('Session stopped. Nothing was saved.'), findsOneWidget);
    expect(repository.ledger.sessions, isEmpty);
  });
}
