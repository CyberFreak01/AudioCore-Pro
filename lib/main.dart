import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'core/constants/app_constants.dart';
import 'services/session_service.dart';
import 'providers/recording_provider.dart';
import 'screens/recording_screen.dart';
import 'themes/app_theme.dart';

void main() {
  print('Flutter: Starting app');
  runApp(const MedicalTranscriptionApp());
}

class MedicalTranscriptionApp extends StatelessWidget {
  const MedicalTranscriptionApp({super.key});

  @override
  Widget build(BuildContext context) {
    print('Flutter: Building MedicalTranscriptionApp');
    return MultiProvider(
      providers: [
        Provider(
            create: (_) => SessionService(AppConstants.defaultServerUrl)),
        ChangeNotifierProxyProvider<SessionService, RecordingProvider>(
          create: (_) => RecordingProvider(),
          update: (_, sessionService, recordingProvider) {
            recordingProvider?.initialize(sessionService);
            // Configure native server URL to match Flutter service
            recordingProvider?.setServerUrl(AppConstants.defaultServerUrl);
            return recordingProvider!;
          },
        ),
      ],
      child: DynamicColorBuilder(
        builder: (lightDynamic, darkDynamic) {
          return MaterialApp(
            title: 'Medical Transcription',
            theme: AppTheme.lightTheme(lightDynamic),
            darkTheme: AppTheme.darkTheme(darkDynamic),
            themeMode: ThemeMode.system,
            home: const RecordingScreen(),
            debugShowCheckedModeBanner: false,
          );
        },
      ),
    );
  }
}
