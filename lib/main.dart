import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/session_service.dart';
import 'providers/recording_provider.dart';
import 'screens/recording_screen.dart';

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
            create: (_) => SessionService(
                'https://scribe-server-production-f150.up.railway.app/')),
        ChangeNotifierProxyProvider<SessionService, RecordingProvider>(
          create: (_) => RecordingProvider(),
          update: (_, sessionService, recordingProvider) {
            recordingProvider?.initialize(sessionService);
            // Configure native server URL to match Flutter service
            recordingProvider?.setServerUrl('https://scribe-server-production-f150.up.railway.app');
            return recordingProvider!;
          },
        ),
      ],
      child: MaterialApp(
        title: 'Medical Transcription',
        theme: ThemeData(
          primarySwatch: Colors.blue,
          visualDensity: VisualDensity.adaptivePlatformDensity,
        ),
        home: const RecordingScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
