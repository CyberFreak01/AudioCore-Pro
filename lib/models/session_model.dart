/// Represents a recording session with its metadata
class SessionModel {
  final String id;
  final DateTime createdAt;
  final Duration duration;
  final int totalChunks;
  final int uploadedChunks;
  final bool isTimerEnabled;
  final Duration? timerDuration;
  final SessionStatus status;
  
  const SessionModel({
    required this.id,
    required this.createdAt,
    required this.duration,
    required this.totalChunks,
    required this.uploadedChunks,
    required this.isTimerEnabled,
    this.timerDuration,
    required this.status,
  });
  
  /// Creates a new session model from the current recording state
  factory SessionModel.fromRecordingState({
    required String sessionId,
    required Duration recordingDuration,
    required int chunkCounter,
    required List<String> uploadedChunksList,
    required bool isTimerEnabled,
    Duration? selectedDuration,
    required SessionStatus status,
  }) {
    return SessionModel(
      id: sessionId,
      createdAt: DateTime.now(),
      duration: recordingDuration,
      totalChunks: chunkCounter,
      uploadedChunks: uploadedChunksList.length,
      isTimerEnabled: isTimerEnabled,
      timerDuration: selectedDuration,
      status: status,
    );
  }
  
  /// Returns true if all chunks have been uploaded
  bool get isFullyUploaded => uploadedChunks >= totalChunks;
  
  /// Returns the percentage of chunks uploaded (0.0 to 1.0)
  double get uploadProgress {
    if (totalChunks == 0) return 0.0;
    return (uploadedChunks / totalChunks).clamp(0.0, 1.0);
  }
  
  /// Returns the number of pending chunks
  int get pendingChunks => (totalChunks - uploadedChunks).clamp(0, totalChunks);
  
  /// Creates a copy of this session with updated values
  SessionModel copyWith({
    String? id,
    DateTime? createdAt,
    Duration? duration,
    int? totalChunks,
    int? uploadedChunks,
    bool? isTimerEnabled,
    Duration? timerDuration,
    SessionStatus? status,
  }) {
    return SessionModel(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      duration: duration ?? this.duration,
      totalChunks: totalChunks ?? this.totalChunks,
      uploadedChunks: uploadedChunks ?? this.uploadedChunks,
      isTimerEnabled: isTimerEnabled ?? this.isTimerEnabled,
      timerDuration: timerDuration ?? this.timerDuration,
      status: status ?? this.status,
    );
  }
  
  @override
  String toString() {
    return 'SessionModel(id: $id, duration: $duration, chunks: $totalChunks/$uploadedChunks, status: $status)';
  }
  
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SessionModel && other.id == id;
  }
  
  @override
  int get hashCode => id.hashCode;
}

/// Represents the current status of a recording session
enum SessionStatus {
  /// Session is being created
  creating,
  
  /// Session is ready to start recording
  ready,
  
  /// Session is currently recording
  recording,
  
  /// Session recording is paused
  paused,
  
  /// Session recording has completed
  completed,
  
  /// Session encountered an error
  error;
  
  /// Returns true if the session is in an active recording state
  bool get isActive => this == SessionStatus.recording;
  
  /// Returns true if the session can be resumed
  bool get canResume => this == SessionStatus.paused;
  
  /// Returns true if the session is finished (completed or error)
  bool get isFinished => this == SessionStatus.completed || this == SessionStatus.error;
  
  /// Returns a human-readable display name
  String get displayName {
    switch (this) {
      case SessionStatus.creating:
        return 'Creating';
      case SessionStatus.ready:
        return 'Ready';
      case SessionStatus.recording:
        return 'Recording';
      case SessionStatus.paused:
        return 'Paused';
      case SessionStatus.completed:
        return 'Completed';
      case SessionStatus.error:
        return 'Error';
    }
  }
}
