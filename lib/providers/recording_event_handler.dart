import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../services/session_service.dart';
import '../services/platform_service.dart';
import '../models/audio_level_model.dart';
import 'recording_state_manager.dart';

/// Handles events from the platform and coordinates with other services
class RecordingEventHandler {
  final RecordingStateManager _stateManager;
  final SessionService _sessionService;
  final PlatformService _platformService;
  
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;
  
  RecordingEventHandler({
    required RecordingStateManager stateManager,
    required SessionService sessionService,
    required PlatformService platformService,
  }) : _stateManager = stateManager,
       _sessionService = sessionService,
       _platformService = platformService;
  
  /// Initialize event handling
  void initialize() {
    _eventSubscription = _platformService.eventStream.listen(
      _handlePlatformEvent,
      onError: (error) {
        debugPrint('Platform event error: $error');
        _stateManager.setError('Audio stream error: $error');
      },
    );
  }
  
  /// Handle events from the platform
  void _handlePlatformEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    
    switch (type) {
      case 'chunk_ready':
        _handleChunkReady(event);
        break;
      case 'recording_stopped':
        _handleRecordingStopped(event);
        break;
      case 'recording_state_changed':
        _handleRecordingStateChanged(event);
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
      case 'network_available':
        _handleNetworkAvailable();
        break;
      case 'call_interruption':
        _handleCallInterruption(event);
        break;
      case 'audio_focus_change':
        _handleAudioFocusChange(event);
        break;
      default:
        debugPrint('Unknown event type: $type');
    }
  }
  
  /// Handle new audio chunk ready for upload
  Future<void> _handleChunkReady(Map<String, dynamic> event) async {
    try {
      final sessionId = event['sessionId'] as String?;
      final chunkNumber = (event['chunkNumber'] as num?)?.toInt();
      final filePath = event['filePath'] as String?;
      final checksum = event['checksum'] as String?;
      
      if (sessionId == null || chunkNumber == null || filePath == null) {
        debugPrint('Chunk ready event missing required data: $event');
        return;
      }
      
      final file = File(filePath);
      if (!await file.exists()) {
        debugPrint('Chunk file does not exist: $filePath');
        return;
      }
      
      debugPrint('Uploading chunk $chunkNumber for session $sessionId');
      
      // Upload chunk via session service
      final success = await _sessionService.uploadChunk(sessionId, chunkNumber, file);
      if (!success) {
        debugPrint('Upload failed for chunk $chunkNumber, native system will retry');
        return;
      }
      
      // Notify server of successful upload
      try {
        await _sessionService.notifyChunkUploaded(sessionId, chunkNumber, checksum: checksum);
      } catch (e) {
        debugPrint('Failed to notify server of chunk upload: $e');
      }
      
      // Mark chunk as uploaded in native system
      try {
        await _platformService.markChunkUploaded(sessionId, chunkNumber);
      } catch (e) {
        debugPrint('Failed to mark chunk as uploaded in native system: $e');
      }
      
      // Update state manager
      _stateManager.addUploadedChunk('chunk_$chunkNumber', chunkNumber);
      
      debugPrint('Chunk $chunkNumber uploaded and processed successfully');
    } catch (e) {
      debugPrint('Error handling chunk_ready event: $e');
    }
  }
  
  /// Handle recording stopped event
  void _handleRecordingStopped(Map<String, dynamic> event) {
    final totalChunks = event['totalChunks'] as int?;
    debugPrint('Recording stopped with $totalChunks total chunks');
  }
  
  /// Handle recording state changes from native (e.g., notification actions)
  void _handleRecordingStateChanged(Map<String, dynamic> event) {
    final state = event['state'] as String?;
    final source = event['source'] as String?;
    final sessionId = event['sessionId'] as String?;
    final remainingTimeMs = event['remainingTimeMs'] as int?;
    final totalChunks = event['totalChunks'] as int?;
    
    debugPrint('Recording state changed to: $state from source: $source');
    
    if (state != null) {
      _stateManager.syncFromNative(
        stateString: state,
        sessionId: sessionId,
        totalChunks: totalChunks,
        remainingTimeMs: remainingTimeMs,
      );
    }
  }
  
  /// Handle permission granted event
  void _handlePermissionGranted(Map<String, dynamic> event) {
    final permission = event['permission'] as String?;
    debugPrint('Permission granted: $permission');
    
    // Clear permission-related errors
    if (_stateManager.errorMessage?.contains('permission') == true) {
      _stateManager.clearError();
    }
  }
  
  /// Handle audio level updates
  void _handleAudioLevel(Map<String, dynamic> event) {
    final audioLevel = AudioLevelModel.fromEventData(event);
    _stateManager.updateAudioLevel(audioLevel);
  }
  
  /// Handle chunk uploaded notification
  void _handleChunkUploaded(Map<String, dynamic> event) {
    final chunkNumber = event['chunkNumber'] as int?;
    if (chunkNumber != null) {
      _stateManager.addUploadedChunk('chunk_$chunkNumber', chunkNumber);
      debugPrint('Chunk $chunkNumber uploaded successfully');
    }
  }
  
  /// Handle network available event
  void _handleNetworkAvailable() {
    debugPrint('Network available - native upload system will resume automatically');
  }
  
  /// Handle call interruption events (auto pause/resume)
  void _handleCallInterruption(Map<String, dynamic> event) {
    final action = event['action'] as String?;
    final reason = event['reason'] as String?;
    final sessionId = event['sessionId'] as String?;
    final remainingTimeMs = event['remainingTimeMs'] as int?;
    final totalChunks = event['totalChunks'] as int?;
    
    debugPrint('Call interruption: action=$action, reason=$reason, session=$sessionId');
    
    switch (action) {
      case 'paused':
        // Sync state from native - recording was auto-paused due to call
        _stateManager.syncFromNative(
          stateString: 'paused',
          sessionId: sessionId,
          totalChunks: totalChunks,
          remainingTimeMs: remainingTimeMs,
        );
        
        // Show user-friendly message about auto-pause
        final reasonText = _getCallReasonText(reason);
        _stateManager.setError('Recording auto-paused: $reasonText');
        break;
        
      case 'resumed':
        // Sync state from native - recording was auto-resumed after call ended
        _stateManager.syncFromNative(
          stateString: 'recording',
          sessionId: sessionId,
          totalChunks: totalChunks,
          remainingTimeMs: remainingTimeMs,
        );
        
        // Clear any call-related error messages and show resume message
        _stateManager.clearError();
        debugPrint('Recording auto-resumed after call ended');
        break;
        
      default:
        debugPrint('Unknown call interruption action: $action');
    }
  }
  
  /// Get user-friendly text for call interruption reason
  String _getCallReasonText(String? reason) {
    switch (reason) {
      case 'incoming_call':
        return 'Incoming call detected';
      case 'call_active':
        return 'Call in progress';
      case 'call_ended':
        return 'Call ended';
      default:
        return 'Phone call detected';
    }
  }
  
  /// Handle audio focus change events (microphone acquisition by other apps)
  void _handleAudioFocusChange(Map<String, dynamic> event) {
    final action = event['action'] as String?;
    final reason = event['reason'] as String?;
    final sessionId = event['sessionId'] as String?;
    final remainingTimeMs = event['remainingTimeMs'] as int?;
    final totalChunks = event['totalChunks'] as int?;
    
    debugPrint('Audio focus change: action=$action, reason=$reason, session=$sessionId');
    
    switch (action) {
      case 'paused':
        // Sync state from native - recording was auto-paused due to microphone acquisition
        _stateManager.syncFromNative(
          stateString: 'paused',
          sessionId: sessionId,
          totalChunks: totalChunks,
          remainingTimeMs: remainingTimeMs,
        );
        
        // Show user-friendly message about auto-pause
        final reasonText = _getAudioFocusReasonText(reason);
        _stateManager.setError('Recording auto-paused: $reasonText');
        break;
        
      case 'resumed':
        // Sync state from native - recording was auto-resumed after microphone became available
        _stateManager.syncFromNative(
          stateString: 'recording',
          sessionId: sessionId,
          totalChunks: totalChunks,
          remainingTimeMs: remainingTimeMs,
        );
        
        // Clear any focus-related error messages and show resume message
        _stateManager.clearError();
        debugPrint('Recording auto-resumed after microphone became available');
        break;
        
      default:
        debugPrint('Unknown audio focus action: $action');
    }
  }
  
  /// Get user-friendly text for audio focus change reason
  String _getAudioFocusReasonText(String? reason) {
    switch (reason) {
      case 'permanent_loss':
        return 'Microphone acquired by another app';
      case 'temporary_loss':
        return 'Microphone temporarily unavailable';
      case 'duck_loss':
        return 'Audio focus lost (ducking)';
      case 'focus_gained':
        return 'Microphone available again';
      default:
        return 'Microphone unavailable';
    }
  }
  
  /// Dispose of resources
  void dispose() {
    _eventSubscription?.cancel();
  }
}
