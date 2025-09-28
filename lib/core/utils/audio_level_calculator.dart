/// Utility class for audio level calculations and normalization
class AudioLevelCalculator {
  /// Maximum value for 16-bit PCM audio
  static const int pcm16BitMax = 32767;
  
  /// Normalizes peak level to 0.0-1.0 range for UI display
  static double normalizePeakLevel(int? peak) {
    if (peak == null) return 0.0;
    final normalized = peak.abs() / pcm16BitMax;
    return normalized.clamp(0.0, 1.0);
  }
  
  /// Formats RMS dB value for display
  static String formatRmsDb(double? rmsDb) {
    if (rmsDb == null) return '--';
    return '${rmsDb.toStringAsFixed(1)} dB';
  }
  
  /// Determines if audio level is considered "good" for recording
  static bool isGoodLevel(double? rmsDb, int? peak) {
    if (rmsDb == null || peak == null) return false;
    
    // Good level: RMS between -40dB and -6dB, peak not clipping
    return rmsDb >= -40.0 && rmsDb <= -6.0 && peak.abs() < (pcm16BitMax * 0.95);
  }
  
  /// Gets color indicator based on audio level quality
  static AudioLevelQuality getLevelQuality(double? rmsDb, int? peak) {
    if (rmsDb == null || peak == null) {
      return AudioLevelQuality.none;
    }
    
    // Check for clipping first
    if (peak.abs() >= (pcm16BitMax * 0.95)) {
      return AudioLevelQuality.clipping;
    }
    
    // Check RMS levels
    if (rmsDb >= -6.0) {
      return AudioLevelQuality.tooHigh;
    } else if (rmsDb >= -12.0) {
      return AudioLevelQuality.good;
    } else if (rmsDb >= -24.0) {
      return AudioLevelQuality.acceptable;
    } else if (rmsDb >= -40.0) {
      return AudioLevelQuality.low;
    } else {
      return AudioLevelQuality.tooLow;
    }
  }
}

/// Represents the quality of audio input levels
enum AudioLevelQuality {
  none,
  tooLow,
  low,
  acceptable,
  good,
  tooHigh,
  clipping;
  
  /// Returns a color that represents this quality level
  String get colorDescription {
    switch (this) {
      case AudioLevelQuality.none:
        return 'gray';
      case AudioLevelQuality.tooLow:
        return 'red';
      case AudioLevelQuality.low:
        return 'orange';
      case AudioLevelQuality.acceptable:
        return 'yellow';
      case AudioLevelQuality.good:
        return 'green';
      case AudioLevelQuality.tooHigh:
        return 'orange';
      case AudioLevelQuality.clipping:
        return 'red';
    }
  }
  
  /// Returns a description of this quality level
  String get description {
    switch (this) {
      case AudioLevelQuality.none:
        return 'No signal';
      case AudioLevelQuality.tooLow:
        return 'Too quiet';
      case AudioLevelQuality.low:
        return 'Low level';
      case AudioLevelQuality.acceptable:
        return 'Acceptable';
      case AudioLevelQuality.good:
        return 'Good level';
      case AudioLevelQuality.tooHigh:
        return 'Too loud';
      case AudioLevelQuality.clipping:
        return 'Clipping!';
    }
  }
}
