import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/dashboard_screen.dart';
import 'services/feedback_service.dart';
import 'services/storage_service.dart';
import 'theme/neuro_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  final store = SharedPreferencesStore();
  final repository = ReflexRepository(store);
  final feedback = FeedbackService(store);
  await Future.wait([repository.load(), feedback.load()]);
  runApp(NeuroPulseApp(repository: repository, feedback: feedback));
}

class NeuroPulseApp extends StatelessWidget {
  const NeuroPulseApp({super.key, required this.repository, required this.feedback});

  final ReflexRepository repository;
  final FeedbackService feedback;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'NeuroPulse',
        debugShowCheckedModeBanner: false,
        theme: NeuroTheme.build(),
        home: DashboardScreen(repository: repository, feedback: feedback),
      );
}
