import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as path;

enum ShareType {
  text,
  audioFile,
  sessionSummary,
  sessionLink,
}

class ShareService {
  /// Share plain text content
  static Future<void> shareText({
    required String text,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    try {
      await Share.share(
        text,
        subject: subject,
        sharePositionOrigin: sharePositionOrigin,
      );
      debugPrint('Text shared successfully');
    } catch (e) {
      debugPrint('Error sharing text: $e');
      rethrow;
    }
  }

  /// Share audio file
  static Future<void> shareAudioFile({
    required String filePath,
    String? text,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('Audio file does not exist: $filePath');
      }

      final xFile = XFile(filePath);
      await Share.shareXFiles(
        [xFile],
        text: text ?? 'Medical transcription audio recording',
        subject: subject ?? 'Audio Recording',
        sharePositionOrigin: sharePositionOrigin,
      );
      debugPrint('Audio file shared successfully: $filePath');
    } catch (e) {
      debugPrint('Error sharing audio file: $e');
      rethrow;
    }
  }

  /// Share multiple audio files (chunks)
  static Future<void> shareAudioFiles({
    required List<String> filePaths,
    String? text,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    try {
      final existingFiles = <XFile>[];
      
      for (final filePath in filePaths) {
        final file = File(filePath);
        if (await file.exists()) {
          existingFiles.add(XFile(filePath));
        } else {
          debugPrint('Warning: Audio file does not exist: $filePath');
        }
      }

      if (existingFiles.isEmpty) {
        throw Exception('No valid audio files found to share');
      }

      await Share.shareXFiles(
        existingFiles,
        text: text ?? 'Medical transcription audio recordings (${existingFiles.length} files)',
        subject: subject ?? 'Audio Recordings',
        sharePositionOrigin: sharePositionOrigin,
      );
      debugPrint('${existingFiles.length} audio files shared successfully');
    } catch (e) {
      debugPrint('Error sharing audio files: $e');
      rethrow;
    }
  }

  /// Share session summary with metadata
  static Future<void> shareSessionSummary({
    required String sessionId,
    required Duration recordingDuration,
    required int totalChunks,
    required List<String> uploadedChunks,
    String? additionalNotes,
    Rect? sharePositionOrigin,
  }) async {
    try {
      final summary = _buildSessionSummary(
        sessionId: sessionId,
        recordingDuration: recordingDuration,
        totalChunks: totalChunks,
        uploadedChunks: uploadedChunks,
        additionalNotes: additionalNotes,
      );

      await Share.share(
        summary,
        subject: 'Medical Transcription Session Summary - $sessionId',
        sharePositionOrigin: sharePositionOrigin,
      );
      debugPrint('Session summary shared successfully');
    } catch (e) {
      debugPrint('Error sharing session summary: $e');
      rethrow;
    }
  }

  /// Share session link (if you have a web interface)
  static Future<void> shareSessionLink({
    required String sessionId,
    required String baseUrl,
    String? additionalText,
    Rect? sharePositionOrigin,
  }) async {
    try {
      final link = '$baseUrl/session/$sessionId';
      final text = additionalText != null 
          ? '$additionalText\n\nSession Link: $link'
          : 'Medical Transcription Session: $link';

      await Share.share(
        text,
        subject: 'Medical Transcription Session Link',
        sharePositionOrigin: sharePositionOrigin,
      );
      debugPrint('Session link shared successfully');
    } catch (e) {
      debugPrint('Error sharing session link: $e');
      rethrow;
    }
  }

  /// Share session with multiple options (audio + summary)
  static Future<void> shareSessionComplete({
    required String sessionId,
    required Duration recordingDuration,
    required int totalChunks,
    required List<String> uploadedChunks,
    List<String>? audioFilePaths,
    String? additionalNotes,
    Rect? sharePositionOrigin,
  }) async {
    try {
      final summary = _buildSessionSummary(
        sessionId: sessionId,
        recordingDuration: recordingDuration,
        totalChunks: totalChunks,
        uploadedChunks: uploadedChunks,
        additionalNotes: additionalNotes,
      );

      if (audioFilePaths != null && audioFilePaths.isNotEmpty) {
        // Share audio files with summary
        final existingFiles = <XFile>[];
        
        for (final filePath in audioFilePaths) {
          final file = File(filePath);
          if (await file.exists()) {
            existingFiles.add(XFile(filePath));
          }
        }

        if (existingFiles.isNotEmpty) {
          await Share.shareXFiles(
            existingFiles,
            text: summary,
            subject: 'Medical Transcription Session - $sessionId',
            sharePositionOrigin: sharePositionOrigin,
          );
          debugPrint('Complete session shared successfully (${existingFiles.length} files + summary)');
        } else {
          // Fallback to text-only sharing
          await Share.share(
            summary,
            subject: 'Medical Transcription Session Summary - $sessionId',
            sharePositionOrigin: sharePositionOrigin,
          );
          debugPrint('Session summary shared (no audio files available)');
        }
      } else {
        // Share summary only
        await Share.share(
          summary,
          subject: 'Medical Transcription Session Summary - $sessionId',
          sharePositionOrigin: sharePositionOrigin,
        );
        debugPrint('Session summary shared successfully');
      }
    } catch (e) {
      debugPrint('Error sharing complete session: $e');
      rethrow;
    }
  }

  /// Build formatted session summary text
  static String _buildSessionSummary({
    required String sessionId,
    required Duration recordingDuration,
    required int totalChunks,
    required List<String> uploadedChunks,
    String? additionalNotes,
  }) {
    final buffer = StringBuffer();
    
    buffer.writeln('📋 Medical Transcription Session Summary');
    buffer.writeln('=' * 40);
    buffer.writeln();
    buffer.writeln('🆔 Session ID: $sessionId');
    buffer.writeln('⏱️ Recording Duration: ${_formatDuration(recordingDuration)}');
    buffer.writeln('📦 Total Chunks: $totalChunks');
    buffer.writeln('✅ Uploaded Chunks: ${uploadedChunks.length}');
    
    if (uploadedChunks.length < totalChunks) {
      buffer.writeln('⚠️ Pending Uploads: ${totalChunks - uploadedChunks.length}');
    }
    
    buffer.writeln('📅 Generated: ${DateTime.now().toString().split('.')[0]}');
    
    if (additionalNotes != null && additionalNotes.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('📝 Notes:');
      buffer.writeln(additionalNotes);
    }
    
    buffer.writeln();
    buffer.writeln('Generated by Medical Transcription App');
    
    return buffer.toString();
  }

  /// Format duration for display
  static String _formatDuration(Duration duration) {
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

  /// Get available share options for a session
  static List<ShareOption> getShareOptionsForSession({
    required String sessionId,
    required bool hasAudioFiles,
    required bool isCompleted,
    String? serverUrl,
  }) {
    final options = <ShareOption>[];
    
    // Always available
    options.add(ShareOption(
      type: ShareType.sessionSummary,
      title: 'Share Summary',
      description: 'Share session details and statistics',
      icon: '📋',
    ));
    
    // Available if audio files exist
    if (hasAudioFiles) {
      options.add(ShareOption(
        type: ShareType.audioFile,
        title: 'Share Audio',
        description: 'Share audio recording files',
        icon: '🎵',
      ));
    }
    
    // Available if server URL is configured
    if (serverUrl != null && serverUrl.isNotEmpty) {
      options.add(ShareOption(
        type: ShareType.sessionLink,
        title: 'Share Link',
        description: 'Share session access link',
        icon: '🔗',
      ));
    }
    
    return options;
  }
}

/// Share option model
class ShareOption {
  final ShareType type;
  final String title;
  final String description;
  final String icon;

  const ShareOption({
    required this.type,
    required this.title,
    required this.description,
    required this.icon,
  });
}
