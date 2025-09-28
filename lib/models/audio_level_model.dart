/// Represents audio level data from the recording system
class AudioLevelModel {
  final double? rmsDb;
  final int? peakLevel;
  final DateTime timestamp;
  
  const AudioLevelModel({
    required this.rmsDb,
    required this.peakLevel,
    required this.timestamp,
  });
  
  /// Creates an audio level model from platform event data
  factory AudioLevelModel.fromEventData(Map<dynamic, dynamic> eventData) {
    return AudioLevelModel(
      rmsDb: (eventData['rmsDb'] as num?)?.toDouble(),
      peakLevel: eventData['peak'] as int?,
      timestamp: DateTime.now(),
    );
  }
  
  /// Creates an empty/silent audio level model
  factory AudioLevelModel.silent() {
    return AudioLevelModel(
      rmsDb: null,
      peakLevel: null,
      timestamp: DateTime.now(),
    );
  }
  
  /// Returns true if this represents valid audio data
  bool get hasValidData => rmsDb != null && peakLevel != null;
  
  /// Returns true if the audio levels have changed significantly
  bool hasSignificantChange(AudioLevelModel? other) {
    if (other == null) return true;
    
    // Consider significant if RMS changes by more than 1dB or peak changes by more than 1000
    final rmsChange = (rmsDb ?? 0) - (other.rmsDb ?? 0);
    final peakChange = (peakLevel ?? 0) - (other.peakLevel ?? 0);
    
    return rmsChange.abs() > 1.0 || peakChange.abs() > 1000;
  }
  
  @override
  String toString() {
    return 'AudioLevelModel(rmsDb: $rmsDb, peakLevel: $peakLevel, timestamp: $timestamp)';
  }
  
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AudioLevelModel &&
        other.rmsDb == rmsDb &&
        other.peakLevel == peakLevel;
  }
  
  @override
  int get hashCode => Object.hash(rmsDb, peakLevel);
}
