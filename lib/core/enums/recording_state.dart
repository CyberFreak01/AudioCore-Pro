/// Represents the current state of audio recording
enum RecordingState {
  /// Recording is stopped
  stopped,
  
  /// Recording is actively in progress
  recording,
  
  /// Recording is temporarily paused
  paused,
  
  /// An error occurred during recording
  error;
  
  /// Returns true if recording is currently active
  bool get isActive => this == RecordingState.recording;
  
  /// Returns true if recording can be resumed
  bool get canResume => this == RecordingState.paused;
  
  /// Returns true if recording can be started
  bool get canStart => this == RecordingState.stopped || this == RecordingState.error;
  
  /// Returns true if recording can be paused
  bool get canPause => this == RecordingState.recording;
  
  /// Returns true if recording can be stopped
  bool get canStop => this == RecordingState.recording || this == RecordingState.paused;
  
  /// Returns a human-readable display name for the state
  String get displayName {
    switch (this) {
      case RecordingState.stopped:
        return 'Stopped';
      case RecordingState.recording:
        return 'Recording';
      case RecordingState.paused:
        return 'Paused';
      case RecordingState.error:
        return 'Error';
    }
  }
}
