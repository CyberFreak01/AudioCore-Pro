import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../services/session_service.dart';
import '../services/mic_service.dart';

enum RecordingState {
  stopped,
  recording,
  paused,
  error
}

class RecordingProvider extends ChangeNotifier {
  static const MethodChannel _platform = MethodChannel('medical_transcription/audio');
  static const EventChannel _eventChannel = EventChannel('medical_transcription/audio_stream');
  
  RecordingState _state = RecordingState.stopped;
  String? _currentSessionId;
  int _chunkCounter = 0;
  Duration _recordingDuration = Duration.zero;
  Timer? _timer;
  Timer? _retryTimer;
  List<String> _uploadedChunks = [];
  String? _errorMessage;
  SessionService? _sessionService;
  StreamSubscription? _eventSubscription;
  double? _rmsDb;
  int? _peakLevel;
  double _gain = 1.0;

  // Getters
  RecordingState get state => _state;
  String? get currentSessionId => _currentSessionId;
  int get chunkCounter => _chunkCounter;
  Duration get recordingDuration => _recordingDuration;
  List<String> get uploadedChunks => _uploadedChunks;
  String? get errorMessage => _errorMessage;
  bool get isRecording => _state == RecordingState.recording;
  double? get rmsDb => _rmsDb;
  int? get peakLevel => _peakLevel;
  double get gain => _gain;

  /// Initialize the provider with session service
  void initialize(SessionService sessionService) {
    _sessionService = sessionService;
    _setupEventListener();
    _recoverLastSessionPending();
  }

  /// Set up event listener for audio chunks
  void _setupEventListener() {
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        _handleAudioEvent(event);
      },
      onError: (error) {
        _setError('Audio stream error: $error');
      },
    );
  }

  /// Handle audio events from native platform
  void _handleAudioEvent(dynamic event) async {
    if (event is Map) {
      final type = event['type'] as String?;
      
      switch (type) {
        case 'chunk_ready':
          await _handleChunkReady(event);
          break;
        case 'recording_stopped':
          _handleRecordingStopped(event);
          break;
        case 'permission_granted':
          _handlePermissionGranted(event);
          break;
        case 'audio_level':
          _handleAudioLevel(event);
          break;
        case 'chunk_uploaded':
          _handleChunkUploaded(event);
          break;
        case 'pending_chunks':
          await _handlePendingChunks(event);
          break;
        case 'network_available':
          await _handleNetworkAvailable();
          break;
      }
    }
  }

  void _handleAudioLevel(Map event) {
    final db = (event['rmsDb'] as num?)?.toDouble();
    final peak = event['peak'] as int?;
    bool changed = false;
    if (_rmsDb != db) {
      _rmsDb = db;
      changed = true;
    }
    if (_peakLevel != peak) {
      _peakLevel = peak;
      changed = true;
    }
    if (changed) {
      notifyListeners();
    }
  }

  void _handleChunkUploaded(Map event) {
    final chunkNumber = event['chunkNumber'] as int?;
    if (chunkNumber != null) {
      _uploadedChunks.add('chunk_$chunkNumber');
      if (chunkNumber + 1 > _chunkCounter) {
        _chunkCounter = chunkNumber + 1;
      }
      notifyListeners();
      debugPrint('Chunk $chunkNumber uploaded successfully');
    }
  }

  /// Handle permission granted event
  void _handlePermissionGranted(Map event) {
    final permission = event['permission'] as String?;
    debugPrint('Permission granted: $permission');
    
    // Clear any permission-related errors
    if (_errorMessage?.contains('permission') == true) {
      _errorMessage = null;
      notifyListeners();
    }
  }

  /// Handle new audio chunk from native platform (now handled natively)
  Future<void> _handleChunkReady(Map event) async {
    // Chunk handling is now done entirely in native code
    // This method is kept for compatibility but does nothing
    debugPrint('Chunk ready event received - handled natively');
  }

  /// Handle list of pending chunks from native (rescanPending) - now handled natively
  Future<void> _handlePendingChunks(Map event) async {
    // Chunk uploads are now handled entirely in native code
    // This method is kept for compatibility but does nothing
    debugPrint('Pending chunks event received - handled natively');
  }

  /// Trigger rescan on network available
  Future<void> _handleNetworkAvailable() async {
    // Network recovery is now handled natively
    debugPrint('Network available - native upload system will resume automatically');
  }

  Future<void> _recoverAllSessionsPending() async {
    // Recovery is now handled natively in MainActivity.recoverChunkQueue()
    debugPrint('Session recovery handled natively');
  }

  /// Recover only the most recent active session's pending chunks on cold start
  Future<void> _recoverLastSessionPending() async {
    // Recovery is now handled natively in MainActivity.recoverChunkQueue()
    debugPrint('Last session recovery handled natively');
  }

  void _startRetryTimer() {
    // Retry logic is now handled natively
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _stopRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> _triggerRescanPending() async {
    // Rescan is now handled natively
    debugPrint('Rescan handled natively');
  }

  /// Handle recording stopped event
  void _handleRecordingStopped(Map event) {
    final totalChunks = event['totalChunks'] as int?;
    debugPrint('Recording stopped with $totalChunks total chunks');
  }

  /// Start recording session
  Future<bool> startRecording(String sessionId) async {
    try {
      if (_sessionService == null) {
        _setError('Session service not initialized');
        return false;
      }

      debugPrint('Starting recording for session: $sessionId');

      _setState(RecordingState.recording);
      _currentSessionId = sessionId;
      
      // Only reset chunk counter and uploads for new sessions
      if (_currentSessionId != sessionId) {
        _chunkCounter = 0;
        _uploadedChunks.clear();
      }
      
      _recordingDuration = Duration.zero;
      _errorMessage = null;

      // Start the timer for recording duration
      _startTimer();
      _startRetryTimer();

      // Start native audio recording (native code will handle server communication)
      await _platform.invokeMethod('startRecording', {
        'sessionId': sessionId,
        'outputFormat': 'wav',
        'sampleRate': 44100,
      });

      // Ensure foreground service is running to keep mic alive in background
      await MicService.startMic();

      debugPrint('Started recording for session: $sessionId');
      return true;
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_ERROR') {
        _setError('Microphone permission required. Please grant permission and try again.');
      } else {
        _setError('Failed to start recording: ${e.message}');
      }
      return false;
    } catch (e) {
      _setError('Unexpected error starting recording: $e');
      return false;
    }
  }

  /// Stop recording session
  Future<bool> stopRecording() async {
    try {
      if (_state != RecordingState.recording) {
        return false;
      }

      _stopTimer();
      _stopRetryTimer();

      // Mock platform channel call to stop recording
      await _platform.invokeMethod('stopRecording');

      // Stop foreground mic service
      await MicService.stopMic();

      _setState(RecordingState.stopped);
      debugPrint('Stopped recording for session: $_currentSessionId');
      
      final sessionId = _currentSessionId;
      _currentSessionId = null;
      try {
        await _platform.invokeMethod('clearLastActiveSession');
      } catch (_) {}
      
      return true;
    } on PlatformException catch (e) {
      _setError('Failed to stop recording: ${e.message}');
      return false;
    } catch (e) {
      _setError('Unexpected error stopping recording: $e');
      return false;
    }
  }

  /// Pause recording
  Future<bool> pauseRecording() async {
    try {
      if (_state != RecordingState.recording) {
        return false;
      }

      _stopTimer();
      await _platform.invokeMethod('pauseRecording');
      _setState(RecordingState.paused);
      
      debugPrint('Paused recording for session: $_currentSessionId');
      return true;
    } on PlatformException catch (e) {
      _setError('Failed to pause recording: ${e.message}');
      return false;
    }
  }

  /// Resume recording
  Future<bool> resumeRecording() async {
    try {
      if (_state != RecordingState.paused) {
        return false;
      }

      _startTimer();
      _startRetryTimer();
      await _platform.invokeMethod('resumeRecording');
      _setState(RecordingState.recording);
      
      debugPrint('Resumed recording for session: $_currentSessionId');
      _triggerRescanPending();
      return true;
    } on PlatformException catch (e) {
      _setError('Failed to resume recording: ${e.message}');
      return false;
    }
  }

  /// Set microphone gain on native recorder
  Future<void> setGain(double newGain) async {
    try {
      await _platform.invokeMethod('setGain', { 'gain': newGain });
      _gain = newGain;
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to set gain: $e');
    }
  }

  /// Fetch current gain from native
  Future<double> fetchGain() async {
    try {
      final g = await _platform.invokeMethod<double>('getGain');
      if (g != null) {
        _gain = g;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Failed to get gain: $e');
    }
    return _gain;
  }

  /// Configure server URL for native uploads
  Future<void> setServerUrl(String url) async {
    try {
      await _platform.invokeMethod('setServerUrl', {'url': url});
      debugPrint('Server URL configured: $url');
    } catch (e) {
      debugPrint('Failed to set server URL: $e');
    }
  }

  /// Force resume chunk processing (useful after network issues)
  Future<void> forceResumeProcessing() async {
    try {
      await _platform.invokeMethod('forceResumeProcessing');
      debugPrint('Force resumed chunk processing');
    } catch (e) {
      debugPrint('Failed to force resume processing: $e');
    }
  }

  /// Get current queue status
  Future<Map<String, dynamic>?> getQueueStatus() async {
    try {
      final status = await _platform.invokeMethod<Map<dynamic, dynamic>>('getQueueStatus');
      return status?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('Failed to get queue status: $e');
      return null;
    }
  }

  /// Mock audio chunk generation (for testing)
  void mockChunkUploaded(String chunkId) {
    _chunkCounter++;
    _uploadedChunks.add(chunkId);
    notifyListeners();
  }

  /// Reset the provider state
  void reset() {
    _stopTimer();
    _setState(RecordingState.stopped);
    _currentSessionId = null;
    _chunkCounter = 0;
    _recordingDuration = Duration.zero;
    _uploadedChunks.clear();
    _errorMessage = null;
  }

  void _setState(RecordingState newState) {
    _state = newState;
    notifyListeners();
  }

  void _setError(String error) {
    _errorMessage = error;
    _setState(RecordingState.error);
    debugPrint('Recording error: $error');
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _recordingDuration = Duration(seconds: timer.tick);
      notifyListeners();
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopTimer();
    _stopRetryTimer();
    _eventSubscription?.cancel();
    super.dispose();
  }
}