import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/enums/recording_state.dart';
import '../core/constants/app_constants.dart';
import '../services/session_service.dart';
import '../services/mic_service.dart';
import '../services/share_service.dart';
import '../services/platform_service.dart';
import '../models/session_model.dart';
import '../models/audio_level_model.dart';
import 'recording_state_manager.dart';
import 'recording_event_handler.dart';

/// Main provider for recording functionality - coordinates between state manager and services
class RecordingProvider extends ChangeNotifier {
  final RecordingStateManager _stateManager = RecordingStateManager();
  final PlatformService _platformService = PlatformService();
  
  SessionService? _sessionService;
  RecordingEventHandler? _eventHandler;

  // Delegate getters to state manager
  RecordingState get state => _stateManager.state;
  String? get currentSessionId => _stateManager.currentSessionId;
  SessionModel? get currentSession => _stateManager.currentSession;
  int get chunkCounter => _stateManager.chunkCounter;
  Duration get recordingDuration => _stateManager.recordingDuration;
  List<String> get uploadedChunks => _stateManager.uploadedChunks;
  String? get errorMessage => _stateManager.errorMessage;
  bool get isRecording => _stateManager.isRecording;
  AudioLevelModel get audioLevel => _stateManager.audioLevel;
  double? get rmsDb => _stateManager.audioLevel.rmsDb;
  int? get peakLevel => _stateManager.audioLevel.peakLevel;
  double get gain => _stateManager.gain;
  
  // Timer getters
  Duration? get selectedDuration => _stateManager.selectedTimerDuration;
  Duration? get remainingTime => _stateManager.remainingTime;
  bool get isTimerEnabled => _stateManager.isTimerEnabled;
  bool get hasTimerExpired => _stateManager.hasTimerExpired;

  /// Initialize the provider with session service
  void initialize(SessionService sessionService) {
    _sessionService = sessionService;
    
    // Initialize platform service
    _platformService.initialize();
    
    // Set up event handler
    _eventHandler = RecordingEventHandler(
      stateManager: _stateManager,
      sessionService: sessionService,
      platformService: _platformService,
    );
    _eventHandler!.initialize();
    
    // Listen to state manager changes
    _stateManager.addListener(_onStateManagerChanged);
  }

  /// Handle state manager changes and forward to listeners
  void _onStateManagerChanged() {
    // Check if timer expired and auto-stop is needed
    if (_stateManager.hasTimerExpired && _stateManager.isRecording) {
      stopRecording();
    }
    
    notifyListeners();
  }

  /// Set recording timer duration
  void setTimerDuration(Duration? duration) {
    _stateManager.setTimerDuration(duration);
  }

  /// Start recording session
  Future<bool> startRecording(String sessionId) async {
    try {
      if (_sessionService == null) {
        _stateManager.setError('Session service not initialized');
        return false;
      }

      debugPrint('Starting recording for session: $sessionId');

      // Start native audio recording
      await _platformService.startRecording(
        sessionId: sessionId,
        timerDuration: _stateManager.selectedTimerDuration,
      );

      // Ensure foreground service is running
      await MicService.startMic();

      // Update state manager
      _stateManager.startSession(sessionId);

      debugPrint('Started recording for session: $sessionId with timer: ${_stateManager.selectedTimerDuration?.inMinutes} minutes');
      return true;
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_ERROR') {
        _stateManager.setError('Microphone permission required. Please grant permission and try again.');
      } else {
        _stateManager.setError('Failed to start recording: ${e.message}');
      }
      return false;
    } catch (e) {
      _stateManager.setError('Unexpected error starting recording: $e');
      return false;
    }
  }

  /// Stop recording session
  Future<bool> stopRecording() async {
    try {
      if (!_stateManager.state.canStop) {
        return false;
      }

      // Stop native recording
      await _platformService.stopRecording();

      // Stop foreground mic service
      await MicService.stopMic();

      // Update state manager
      _stateManager.stopSession();

      debugPrint('Stopped recording for session: ${currentSessionId}');
      
      try {
        await _platformService.clearLastActiveSession();
      } catch (e) {
        debugPrint('Failed to clear last active session: $e');
      }
      
      return true;
    } on PlatformException catch (e) {
      _stateManager.setError('Failed to stop recording: ${e.message}');
      return false;
    } catch (e) {
      _stateManager.setError('Unexpected error stopping recording: $e');
      return false;
    }
  }

  /// Pause recording
  Future<bool> pauseRecording() async {
    try {
      if (!_stateManager.state.canPause) {
        return false;
      }

      await _platformService.pauseRecording();
      _stateManager.pauseSession();
      
      debugPrint('Paused recording for session: $currentSessionId');
      return true;
    } on PlatformException catch (e) {
      _stateManager.setError('Failed to pause recording: ${e.message}');
      return false;
    }
  }

  /// Resume recording
  Future<bool> resumeRecording() async {
    try {
      if (!_stateManager.state.canResume) {
        return false;
      }
      
      await _platformService.resumeRecording();
      _stateManager.resumeSession();
      
      debugPrint('Resumed recording for session: $currentSessionId');
      return true;
    } on PlatformException catch (e) {
      _stateManager.setError('Failed to resume recording: ${e.message}');
      return false;
    }
  }

  /// Set microphone gain on native recorder
  Future<void> setGain(double newGain) async {
    try {
      await _platformService.setGain(newGain);
      _stateManager.updateGain(newGain);
    } catch (e) {
      debugPrint('Failed to set gain: $e');
    }
  }

  /// Fetch current gain from native
  Future<double> fetchGain() async {
    try {
      final gain = await _platformService.getGain();
      _stateManager.updateGain(gain);
      return gain;
    } catch (e) {
      debugPrint('Failed to get gain: $e');
      return _stateManager.gain;
    }
  }

  /// Configure server URL for native uploads
  void setServerUrl(String url) {
    _platformService.setServerUrl(url);
  }

  /// Force resume chunk processing (useful after network issues)
  Future<void> forceResumeProcessing() async {
    await _platformService.forceResumeProcessing();
  }

  /// Get current queue status
  Future<Map<String, dynamic>?> getQueueStatus() async {
    return await _platformService.getQueueStatus();
  }

  /// Share current session summary
  Future<void> shareSessionSummary({Rect? sharePositionOrigin}) async {
    final session = _stateManager.currentSession;
    if (session == null) {
      throw Exception('No active session to share');
    }

    try {
      await ShareService.shareSessionSummary(
        sessionId: session.id,
        recordingDuration: session.duration,
        totalChunks: session.totalChunks,
        uploadedChunks: _stateManager.uploadedChunks,
        additionalNotes: session.isTimerEnabled 
            ? 'Timer: ${session.timerDuration?.inMinutes ?? 0} minutes'
            : null,
        sharePositionOrigin: sharePositionOrigin,
      );
      debugPrint('Session summary shared for: ${session.id}');
    } catch (e) {
      debugPrint('Failed to share session summary: $e');
      rethrow;
    }
  }

  /// Share session audio files
  Future<void> shareSessionAudio({Rect? sharePositionOrigin}) async {
    final session = _stateManager.currentSession;
    if (session == null) {
      throw Exception('No active session to share');
    }

    try {
      // Get audio files from native
      final audioFiles = await _platformService.getSessionAudioFiles(session.id);
      
      if (audioFiles.isEmpty) {
        throw Exception('No audio files available for this session');
      }

      await ShareService.shareAudioFiles(
        filePaths: audioFiles,
        text: 'Medical transcription audio recording - Session: ${session.id}',
        subject: 'Audio Recording - ${session.id}',
        sharePositionOrigin: sharePositionOrigin,
      );
      debugPrint('Session audio shared for: ${session.id} (${audioFiles.length} files)');
    } catch (e) {
      debugPrint('Failed to share session audio: $e');
      rethrow;
    }
  }

  /// Share complete session (audio + summary)
  Future<void> shareCompleteSession({Rect? sharePositionOrigin}) async {
    final session = _stateManager.currentSession;
    if (session == null) {
      throw Exception('No active session to share');
    }

    try {
      // Get audio files from native
      final audioFiles = await _platformService.getSessionAudioFiles(session.id);
      
      await ShareService.shareSessionComplete(
        sessionId: session.id,
        recordingDuration: session.duration,
        totalChunks: session.totalChunks,
        uploadedChunks: _stateManager.uploadedChunks,
        audioFilePaths: audioFiles,
        additionalNotes: session.isTimerEnabled 
            ? 'Timer: ${session.timerDuration?.inMinutes ?? 0} minutes'
            : null,
        sharePositionOrigin: sharePositionOrigin,
      );
      debugPrint('Complete session shared for: ${session.id}');
    } catch (e) {
      debugPrint('Failed to share complete session: $e');
      rethrow;
    }
  }

  /// Share session link (if server URL is available)
  Future<void> shareSessionLink({Rect? sharePositionOrigin}) async {
    final session = _stateManager.currentSession;
    if (session == null) {
      throw Exception('No active session to share');
    }

    if (_sessionService == null) {
      throw Exception('Session service not available');
    }

    try {
      await ShareService.shareSessionLink(
        sessionId: session.id,
        baseUrl: AppConstants.defaultServerUrl,
        additionalText: 'Medical Transcription Session\nDuration: ${session.duration}\nChunks: ${session.totalChunks}',
        sharePositionOrigin: sharePositionOrigin,
      );
      debugPrint('Session link shared for: ${session.id}');
    } catch (e) {
      debugPrint('Failed to share session link: $e');
      rethrow;
    }
  }

  /// Get available share options for current session
  List<ShareOption> getAvailableShareOptions() {
    final session = _stateManager.currentSession;
    if (session == null) {
      return [];
    }

    return ShareService.getShareOptionsForSession(
      sessionId: session.id,
      hasAudioFiles: session.totalChunks > 0,
      isCompleted: session.status.isFinished,
      serverUrl: AppConstants.defaultServerUrl,
    );
  }

  /// Mock audio chunk generation (for testing)
  void mockChunkUploaded(String chunkId) {
    _stateManager.addUploadedChunk(chunkId, _stateManager.chunkCounter);
  }

  /// Reset the provider state
  void reset() {
    _stateManager.reset();
  }

  @override
  void dispose() {
    _eventHandler?.dispose();
    _platformService.dispose();
    _stateManager.removeListener(_onStateManagerChanged);
    _stateManager.dispose();
    super.dispose();
  }
}