/// Utility class for formatting durations consistently across the app
class DurationFormatter {
  /// Formats duration as MM:SS for display in UI
  static String formatMinutesSeconds(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
  
  /// Formats duration as detailed text (e.g., "1h 23m 45s")
  static String formatDetailed(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    
    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }
  
  /// Formats duration for timer display (e.g., "5 min", "1 hour")
  static String formatTimerLabel(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours} hour${duration.inHours > 1 ? 's' : ''}';
    } else {
      return '${duration.inMinutes} min';
    }
  }
  
  /// Formats remaining time for countdown display
  static String formatCountdown(Duration duration) {
    if (duration.inSeconds <= 0) return '00:00';
    
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}
