import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/enums/recording_state.dart';
import '../core/constants/app_constants.dart';
import '../models/session_model.dart';
import '../models/audio_level_model.dart';

/// Manages the core recording state and provides state change notifications
class RecordingStateManager extends ChangeNotifier {
  RecordingState _state = RecordingState.stopped;
  SessionModel? _currentSession;
  AudioLevelModel _audioLevel = AudioLevelModel.silent();
  String? _errorMessage;
  double _gain = 1.0;
  
  // Timer management
  Duration? _selectedTimerDuration;
  Duration? _remainingTime;
  Timer? _recordingTimer;
  Timer? _autoStopTimer;
  Duration _recordingDuration = Duration.zero;
  DateTime? _recordingStartTime;
  DateTime? _pausedAt;
  
  // Chunk tracking
  int _chunkCounter = 0;
  final List<String> _uploadedChunks = [];
  
  // Getters
  RecordingState get state => _state;
  SessionModel? get currentSession => _currentSession;
  AudioLevelModel get audioLevel => _audioLevel;
  String? get errorMessage => _errorMessage;
  double get gain => _gain;
  Duration? get selectedTimerDuration => _selectedTimerDuration;
  Duration? get remainingTime => _remainingTime;
  Duration get recordingDuration => _recordingDuration;
  int get chunkCounter => _chunkCounter;
  List<String> get uploadedChunks => List.unmodifiable(_uploadedChunks);
  
  // Computed properties
  bool get isRecording => _state == RecordingState.recording;
  bool get isTimerEnabled => _selectedTimerDuration != null;
  bool get hasTimerExpired => _remainingTime != null && _remainingTime!.inSeconds <= 0;
  String? get currentSessionId => _currentSession?.id;
  
  /// Set the recording state
  void setState(RecordingState newState) {
    if (_state != newState) {
      _state = newState;
      _updateSessionStatus();
      notifyListeners();
    }
  }
  
  /// Set an error message and change state to error
  void setError(String message) {
    _errorMessage = message;
    setState(RecordingState.error);
  }
  
  /// Clear the current error
  void clearError() {
    if (_errorMessage != null) {
      _errorMessage = null;
      notifyListeners();
    }
  }
  
  /// Start a new recording session
  void startSession(String sessionId) {
    _currentSession = SessionModel(
      id: sessionId,
      createdAt: DateTime.now(),
      duration: Duration.zero,
      totalChunks: 0,
      uploadedChunks: 0,
      isTimerEnabled: isTimerEnabled,
      timerDuration: _selectedTimerDuration,
      status: SessionStatus.ready,
    );
    
    _chunkCounter = 0;
    _uploadedChunks.clear();
    _recordingDuration = Duration.zero;
    _remainingTime = _selectedTimerDuration;
    _recordingStartTime = DateTime.now();
    _pausedAt = null;
    clearError();
    
    setState(RecordingState.recording);
    _startRecordingTimer();
    
    if (isTimerEnabled) {
      _startAutoStopTimer();
    }
  }
  
  /// Stop the current recording session
  void stopSession() {
    _stopAllTimers();
    setState(RecordingState.stopped);
    
    if (_currentSession != null) {
      _currentSession = _currentSession!.copyWith(
        duration: _recordingDuration,
        totalChunks: _chunkCounter,
        uploadedChunks: _uploadedChunks.length,
        status: SessionStatus.completed,
      );
    }
    
    // Reset timer state
    _remainingTime = _selectedTimerDuration;
  }
  
  /// Pause the current recording session
  void pauseSession() {
    _pausedAt = DateTime.now();
    _stopAllTimers();
    setState(RecordingState.paused);
  }
  
  /// Resume the current recording session
  void resumeSession() {
    // Adjust recording start time to account for pause duration
    if (_pausedAt != null && _recordingStartTime != null) {
      final pauseDuration = DateTime.now().difference(_pausedAt!);
      _recordingStartTime = _recordingStartTime!.add(pauseDuration);
    }
    _pausedAt = null;
    
    setState(RecordingState.recording);
    _startRecordingTimer();
    
    if (isTimerEnabled && _remainingTime != null && _remainingTime!.inSeconds > 0) {
      _startAutoStopTimer();
    }
  }
  
  /// Set the timer duration for new recordings
  void setTimerDuration(Duration? duration) {
    _selectedTimerDuration = duration;
    _remainingTime = duration;
    notifyListeners();
  }
  
  /// Update audio levels
  void updateAudioLevel(AudioLevelModel newLevel) {
    if (newLevel.hasSignificantChange(_audioLevel)) {
      _audioLevel = newLevel;
      notifyListeners();
    }
  }
  
  /// Update microphone gain
  void updateGain(double newGain) {
    if (_gain != newGain) {
      _gain = newGain.clamp(AppConstants.minGain, AppConstants.maxGain);
      notifyListeners();
    }
  }
  
  /// Add an uploaded chunk
  void addUploadedChunk(String chunkId, int chunkNumber) {
    if (!_uploadedChunks.contains(chunkId)) {
      _uploadedChunks.add(chunkId);
      
      // Update chunk counter if this chunk number is higher
      if (chunkNumber >= _chunkCounter) {
        _chunkCounter = chunkNumber + 1;
      }
      
      _updateSessionFromState();
      notifyListeners();
    }
  }
  
  /// Sync state from native platform (for notification actions)
  void syncFromNative({
    required String stateString,
    String? sessionId,
    int? totalChunks,
    int? remainingTimeMs,
  }) {
    // Update session ID if provided
    if (sessionId != null && sessionId != currentSessionId) {
      if (_currentSession != null) {
        _currentSession = _currentSession!.copyWith(id: sessionId);
      }
    }
    
    // Update chunk counter if provided
    if (totalChunks != null) {
      _chunkCounter = totalChunks;
    }
    
    // Sync timer state from native
    if (remainingTimeMs != null) {
      _remainingTime = Duration(milliseconds: remainingTimeMs);
    }
    
    // Update state based on native state
    switch (stateString) {
      case 'stopped':
        stopSession();
        break;
      case 'paused':
        pauseSession();
        break;
      case 'recording':
        if (_state != RecordingState.recording) {
          resumeSession();
        }
        break;
    }
  }
  
  /// Reset all state to initial values
  void reset() {
    _stopAllTimers();
    setState(RecordingState.stopped);
    _currentSession = null;
    _chunkCounter = 0;
    _recordingDuration = Duration.zero;
    _recordingStartTime = null;
    _pausedAt = null;
    _uploadedChunks.clear();
    _errorMessage = null;
    _remainingTime = _selectedTimerDuration;
    _audioLevel = AudioLevelModel.silent();
  }
  
  /// Start the recording duration timer
  void _startRecordingTimer() {
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(AppConstants.timerUpdateInterval, (timer) {
      if (_recordingStartTime != null) {
        _recordingDuration = DateTime.now().difference(_recordingStartTime!);
      }
      _updateSessionFromState();
      notifyListeners();
    });
  }
  
  /// Start the auto-stop timer
  void _startAutoStopTimer() {
    if (_remainingTime == null || _remainingTime!.inSeconds <= 0) return;
    
    _autoStopTimer?.cancel();
    _autoStopTimer = Timer.periodic(AppConstants.timerUpdateInterval, (timer) {
      if (_remainingTime != null && _remainingTime!.inSeconds > 0) {
        _remainingTime = Duration(seconds: _remainingTime!.inSeconds - 1);
        notifyListeners();
        
        // Auto-stop when timer reaches zero
        if (_remainingTime!.inSeconds <= 0) {
          debugPrint('Recording timer expired, auto-stopping...');
          _autoStopTimer?.cancel();
          // Notify listeners that timer expired - they should handle stopping
          notifyListeners();
        }
      } else {
        _autoStopTimer?.cancel();
      }
    });
  }
  
  /// Stop all running timers
  void _stopAllTimers() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
  }
  
  /// Update session model from current state
  void _updateSessionFromState() {
    if (_currentSession != null) {
      _currentSession = _currentSession!.copyWith(
        duration: _recordingDuration,
        totalChunks: _chunkCounter,
        uploadedChunks: _uploadedChunks.length,
      );
    }
  }
  
  /// Update session status based on recording state
  void _updateSessionStatus() {
    if (_currentSession != null) {
      SessionStatus status;
      switch (_state) {
        case RecordingState.stopped:
          status = SessionStatus.completed;
          break;
        case RecordingState.recording:
          status = SessionStatus.recording;
          break;
        case RecordingState.paused:
          status = SessionStatus.paused;
          break;
        case RecordingState.error:
          status = SessionStatus.error;
          break;
      }
      
      _currentSession = _currentSession!.copyWith(status: status);
    }
  }
  
  @override
  void dispose() {
    _stopAllTimers();
    super.dispose();
  }
}
