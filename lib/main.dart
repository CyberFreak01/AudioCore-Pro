import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/session_service.dart';
import 'providers/recording_provider.dart';
import 'screens/recording_screen.dart';

void main() {
  runApp(const MedicalTranscriptionApp());
}

class MedicalTranscriptionApp extends StatelessWidget {
  const MedicalTranscriptionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider(create: (_) => SessionService('http://192.168.137.1:3000')),
        ChangeNotifierProxyProvider<SessionService, RecordingProvider>(
          create: (_) => RecordingProvider(),
          update: (_, sessionService, recordingProvider) {
            recordingProvider?.initialize(sessionService);
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