/// Application-wide constants
class AppConstants {
  // Server Configuration
  static const String defaultServerUrl = 'https://scribe-server-production-f150.up.railway.app';
  
  // Audio Configuration
  static const String defaultOutputFormat = 'wav';
  static const int defaultSampleRate = 44100;
  static const double minGain = 0.1;
  static const double maxGain = 5.0;
  static const int gainDivisions = 49;
  
  // Timer Configuration
  static const List<Duration> timerPresets = [
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(hours: 1),
  ];
  
  // UI Configuration
  static const Duration levelUpdateInterval = Duration(milliseconds: 100);
  static const Duration timerUpdateInterval = Duration(seconds: 1);
  
  // Platform Channels
  static const String audioMethodChannel = 'medical_transcription/audio';
  static const String audioEventChannel = 'medical_transcription/audio_stream';
  static const String micServiceChannel = 'com.example.mediascribe.micService';
  
  // Permissions
  static const int permissionRequestCode = 1001;
  
  // Retry Configuration
  static const int maxRetries = 3;
  static const List<Duration> retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
  ];
  
  // Storage Keys
  static const String lastActiveSessionKey = 'last_active_session';
  static const String lastActiveAtKey = 'last_active_at';
  static const String prefsName = 'medical_transcription_prefs';
  
  // Notification
  static const String notificationChannelId = 'record_control';
  static const int notificationId = 987654;
}
