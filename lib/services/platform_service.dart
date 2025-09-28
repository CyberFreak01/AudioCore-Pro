import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/constants/app_constants.dart';

/// Service for handling platform-specific method channel communications
class PlatformService {
  static const MethodChannel _methodChannel = MethodChannel(AppConstants.audioMethodChannel);
  static const EventChannel _eventChannel = EventChannel(AppConstants.audioEventChannel);
  
  StreamSubscription<dynamic>? _eventSubscription;
  final StreamController<Map<String, dynamic>> _eventController = StreamController.broadcast();
  
  /// Stream of events from the native platform
  Stream<Map<String, dynamic>> get eventStream => _eventController.stream;
  
  /// Initialize the platform service and start listening to events
  void initialize() {
    _setupEventListener();
  }
  
  /// Set up event listener for platform events
  void _setupEventListener() {
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          _eventController.add(Map<String, dynamic>.from(event));
        }
      },
      onError: (error) {
        debugPrint('Platform event stream error: $error');
        _eventController.addError(error);
      },
    );
  }
  
  /// Start audio recording with the specified parameters
  Future<void> startRecording({
    required String sessionId,
    String outputFormat = AppConstants.defaultOutputFormat,
    int sampleRate = AppConstants.defaultSampleRate,
    Duration? timerDuration,
  }) async {
    try {
      await _methodChannel.invokeMethod('startRecording', {
        'sessionId': sessionId,
        'outputFormat': outputFormat,
        'sampleRate': sampleRate,
        'timerDuration': timerDuration?.inMilliseconds,
      });
      debugPrint('Started recording for session: $sessionId');
    } on PlatformException catch (e) {
      debugPrint('Failed to start recording: ${e.message}');
      rethrow;
    }
  }
  
  /// Stop audio recording
  Future<void> stopRecording() async {
    try {
      await _methodChannel.invokeMethod('stopRecording');
      debugPrint('Stopped recording');
    } on PlatformException catch (e) {
      debugPrint('Failed to stop recording: ${e.message}');
      rethrow;
    }
  }
  
  /// Pause audio recording
  Future<void> pauseRecording() async {
    try {
      await _methodChannel.invokeMethod('pauseRecording');
      debugPrint('Paused recording');
    } on PlatformException catch (e) {
      debugPrint('Failed to pause recording: ${e.message}');
      rethrow;
    }
  }
  
  /// Resume audio recording
  Future<void> resumeRecording() async {
    try {
      await _methodChannel.invokeMethod('resumeRecording');
      debugPrint('Resumed recording');
    } on PlatformException catch (e) {
      debugPrint('Failed to resume recording: ${e.message}');
      rethrow;
    }
  }
  
  /// Set microphone gain
  Future<void> setGain(double gain) async {
    try {
      await _methodChannel.invokeMethod('setGain', {'gain': gain});
      debugPrint('Set gain to: $gain');
    } on PlatformException catch (e) {
      debugPrint('Failed to set gain: ${e.message}');
      rethrow;
    }
  }
  
  /// Get current microphone gain
  Future<double> getGain() async {
    try {
      final gain = await _methodChannel.invokeMethod<double>('getGain');
      return gain ?? 1.0;
    } on PlatformException catch (e) {
      debugPrint('Failed to get gain: ${e.message}');
      return 1.0;
    }
  }
  
  /// Configure server URL for native uploads
  Future<void> setServerUrl(String url) async {
    try {
      await _methodChannel.invokeMethod('setServerUrl', {'url': url});
      debugPrint('Server URL configured: $url');
    } on PlatformException catch (e) {
      debugPrint('Failed to set server URL: ${e.message}');
    }
  }
  
  /// Mark a chunk as uploaded
  Future<void> markChunkUploaded(String sessionId, int chunkNumber) async {
    try {
      await _methodChannel.invokeMethod('markChunkUploaded', {
        'sessionId': sessionId,
        'chunkNumber': chunkNumber,
      });
      debugPrint('Marked chunk $chunkNumber as uploaded for session $sessionId');
    } on PlatformException catch (e) {
      debugPrint('Failed to mark chunk as uploaded: ${e.message}');
    }
  }
  
  /// Force resume chunk processing
  Future<void> forceResumeProcessing() async {
    try {
      await _methodChannel.invokeMethod('forceResumeProcessing');
      debugPrint('Force resumed chunk processing');
    } on PlatformException catch (e) {
      debugPrint('Failed to force resume processing: ${e.message}');
    }
  }
  
  /// Get current queue status
  Future<Map<String, dynamic>?> getQueueStatus() async {
    try {
      final status = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>('getQueueStatus');
      return status?.cast<String, dynamic>();
    } on PlatformException catch (e) {
      debugPrint('Failed to get queue status: ${e.message}');
      return null;
    }
  }
  
  /// Get session audio files
  Future<List<String>> getSessionAudioFiles(String sessionId) async {
    try {
      final result = await _methodChannel.invokeMethod<List<dynamic>>('getSessionAudioFiles', {
        'sessionId': sessionId,
      });
      return result?.cast<String>() ?? [];
    } on PlatformException catch (e) {
      debugPrint('Failed to get session audio files: ${e.message}');
      return [];
    }
  }
  
  /// Clear last active session
  Future<void> clearLastActiveSession() async {
    try {
      await _methodChannel.invokeMethod('clearLastActiveSession');
      debugPrint('Cleared last active session');
    } on PlatformException catch (e) {
      debugPrint('Failed to clear last active session: ${e.message}');
    }
  }
  
  /// Dispose of resources
  void dispose() {
    _eventSubscription?.cancel();
    _eventController.close();
  }
}
