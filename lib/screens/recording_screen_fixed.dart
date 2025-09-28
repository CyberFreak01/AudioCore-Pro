import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/enums/recording_state.dart';
import '../core/constants/app_constants.dart';
import '../core/utils/duration_formatter.dart';
import '../core/utils/audio_level_calculator.dart';
import '../providers/recording_provider.dart';
import '../services/session_service.dart';
import '../services/share_service.dart';

class RecordingScreen extends StatelessWidget {
  const RecordingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    print('Flutter: Building RecordingScreen');
    return Scaffold(
      appBar: AppBar(
        title: const Text('Medical Transcription'),
      ),
      body: SafeArea(
        child: Consumer<RecordingProvider>(
          builder: (context, recordingProvider, child) {
            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(16.0),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      // Session Info Card
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Session Status',
                                    style: Theme.of(context).textTheme.headlineSmall,
                                  ),
                                  if (recordingProvider.currentSessionId != null)
                                    IconButton(
                                      onPressed: () => _showShareDialog(context, recordingProvider),
                                      icon: const Icon(Icons.share),
                                      tooltip: 'Share Session',
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _buildInfoRow(context, 'Session ID', recordingProvider.currentSessionId ?? 'None'),
                              _buildInfoRow(context, 'Status', _getStatusText(recordingProvider.state)),
                              _buildInfoRow(context, 'Duration', DurationFormatter.formatMinutesSeconds(recordingProvider.recordingDuration)),
                              _buildInfoRow(context, 'Chunks', '${recordingProvider.chunkCounter}'),
                              if (recordingProvider.isTimerEnabled) ...[
                                const SizedBox(height: 8),
                                const Divider(),
                                const SizedBox(height: 8),
                                _buildInfoRow(context, 'Timer', DurationFormatter.formatDetailed(recordingProvider.selectedDuration ?? Duration.zero)),
                                _buildInfoRow(context, 'Remaining', DurationFormatter.formatCountdown(recordingProvider.remainingTime ?? Duration.zero)),
                              ],
                            ],
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 16),
                      
                      // Timer Configuration Card
                      if (recordingProvider.state == RecordingState.stopped)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Recording Timer',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Set a duration for automatic recording stop',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _buildTimerChip(context, recordingProvider, null, 'No Timer'),
                                    ...AppConstants.timerPresets.map((duration) => 
                                      _buildTimerChip(context, recordingProvider, duration, DurationFormatter.formatTimerLabel(duration))
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      
                      const SizedBox(height: 20),
                      
                      // Recording Indicator
                      if (recordingProvider.isRecording)
                        Card(
                          color: Theme.of(context).colorScheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.radio_button_checked, 
                                  color: Theme.of(context).colorScheme.onErrorContainer,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'RECORDING IN PROGRESS',
                                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                          color: Theme.of(context).colorScheme.onErrorContainer,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      if (recordingProvider.isTimerEnabled && recordingProvider.remainingTime != null)
                                        Text(
                                          'Time remaining: ${DurationFormatter.formatCountdown(recordingProvider.remainingTime!)}',
                                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                            color: Theme.of(context).colorScheme.onErrorContainer,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      
                      const SizedBox(height: 20),
                      
                      // Audio Level + Gain Controls
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Audio Levels',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: LinearProgressIndicator(
                                      value: AudioLevelCalculator.normalizePeakLevel(recordingProvider.peakLevel),
                                      minHeight: 8,
                                      backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Theme.of(context).colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.secondaryContainer,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      AudioLevelCalculator.formatRmsDb(recordingProvider.rmsDb),
                                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                        color: Theme.of(context).colorScheme.onSecondaryContainer,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('Gain', style: Theme.of(context).textTheme.titleMedium),
                                  Text(
                                    recordingProvider.gain.toStringAsFixed(2),
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Slider(
                                value: recordingProvider.gain.clamp(AppConstants.minGain, AppConstants.maxGain),
                                min: AppConstants.minGain,
                                max: AppConstants.maxGain,
                                divisions: AppConstants.gainDivisions,
                                label: recordingProvider.gain.toStringAsFixed(2),
                                onChanged: (v) => recordingProvider.setGain(v),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Error Message
                      if (recordingProvider.errorMessage != null)
                        Card(
                          color: recordingProvider.errorMessage!.contains('permission') 
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context).colorScheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Icon(
                                  recordingProvider.errorMessage!.contains('permission') 
                                      ? Icons.mic_off 
                                      : Icons.warning, 
                                  color: recordingProvider.errorMessage!.contains('permission') 
                                      ? Theme.of(context).colorScheme.onPrimaryContainer
                                      : Theme.of(context).colorScheme.onErrorContainer,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    recordingProvider.errorMessage!,
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: recordingProvider.errorMessage!.contains('permission') 
                                          ? Theme.of(context).colorScheme.onPrimaryContainer
                                          : Theme.of(context).colorScheme.onErrorContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      
                      // Add spacing before bottom controls
                      const SizedBox(height: 40),
                      
                      // Control Buttons
                      _buildControlButtons(context, recordingProvider),
                      
                      const SizedBox(height: 20),
                      
                      // Session Management Button
                      FilledButton.tonalIcon(
                        onPressed: () => _showSessionsDialog(context),
                        icon: const Icon(Icons.list),
                        label: const Text('View All Sessions'),
                      ),
                      
                      // Bottom padding for safe area and navigation
                      SizedBox(height: MediaQuery.of(context).padding.bottom + 20),
                    ]),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildControlButtons(BuildContext context, RecordingProvider provider) {
    switch (provider.state) {
      case RecordingState.stopped:
        return SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => _startRecording(context),
            icon: const Icon(Icons.mic),
            label: const Text('Start Recording'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        );
      
      case RecordingState.recording:
        return Row(
          children: [
            Flexible(
              flex: 1,
              child: FilledButton.tonalIcon(
                onPressed: () => provider.pauseRecording(),
                icon: const Icon(Icons.pause),
                label: const Text('Pause'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              flex: 1,
              child: FilledButton.icon(
                onPressed: () => provider.stopRecording(),
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        );
      
      case RecordingState.paused:
        return Row(
          children: [
            Flexible(
              flex: 1,
              child: FilledButton.icon(
                onPressed: () => provider.resumeRecording(),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Resume'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              flex: 1,
              child: FilledButton.icon(
                onPressed: () => provider.stopRecording(),
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        );
      
      case RecordingState.error:
        return SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: () => provider.reset(),
            icon: const Icon(Icons.refresh),
            label: const Text('Reset & Try Again'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        );
    }
  }

  Future<void> _startRecording(BuildContext context) async {
    final sessionService = Provider.of<SessionService>(context, listen: false);
    final recordingProvider = Provider.of<RecordingProvider>(context, listen: false);
    
    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(),
      ),
    );
    
    try {
      // Create new session
      final sessionId = await sessionService.createSession();
      
      // Close loading dialog
      Navigator.of(context).pop();
      
      if (sessionId != null) {
        // Start recording with the new session
        final success = await recordingProvider.startRecording(sessionId);
        
        if (!success) {
          _showErrorDialog(context, 'Failed to start recording');
        }
      } else {
        _showErrorDialog(context, 'Failed to create recording session');
      }
    } catch (e) {
      // Close loading dialog
      Navigator.of(context).pop();
      _showErrorDialog(context, 'Error: $e');
    }
  }

  Future<void> _showSessionsDialog(BuildContext context) async {
    final sessionService = Provider.of<SessionService>(context, listen: false);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('All Sessions'),
        content: FutureBuilder<List<Map<String, dynamic>>>(
          future: sessionService.getAllSessions(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            
            if (snapshot.hasError) {
              return Text('Error: ${snapshot.error}');
            }
            
            final sessions = snapshot.data ?? [];
            
            if (sessions.isEmpty) {
              return const Text('No sessions found');
            }
            
            return SizedBox(
              width: double.maxFinite,
              height: 300,
              child: ListView.builder(
                itemCount: sessions.length,
                itemBuilder: (context, index) {
                  final session = sessions[index];
                  return ListTile(
                    title: Text(session['sessionId'] ?? 'Unknown'),
                    subtitle: Text('Chunks: ${session['totalChunks'] ?? 0}'),
                    trailing: Text(session['status'] ?? 'Unknown'),
                  );
                },
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showShareDialog(BuildContext context, RecordingProvider provider) async {
    final shareOptions = provider.getAvailableShareOptions();
    
    if (shareOptions.isEmpty) {
      _showErrorDialog(context, 'No sharing options available for this session');
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.share),
            const SizedBox(width: 8),
            const Text('Share Session'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Session: ${provider.currentSessionId}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            ...shareOptions.map((option) => _buildShareOptionTile(
              context, 
              provider, 
              option,
            )),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildShareOptionTile(
    BuildContext context, 
    RecordingProvider provider, 
    ShareOption option,
  ) {
    return ListTile(
      leading: Text(
        option.icon,
        style: const TextStyle(fontSize: 24),
      ),
      title: Text(option.title),
      subtitle: Text(option.description),
      onTap: () async {
        Navigator.of(context).pop(); // Close dialog first
        
        try {
          // Show loading indicator
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => const AlertDialog(
              content: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 16),
                  Text('Preparing to share...'),
                ],
              ),
            ),
          );

          // Get the share position for iPad
          final RenderBox? box = context.findRenderObject() as RenderBox?;
          final Rect? sharePositionOrigin = box != null 
              ? box.localToGlobal(Offset.zero) & box.size
              : null;

          // Execute share action
          switch (option.type) {
            case ShareType.sessionSummary:
              await provider.shareSessionSummary(
                sharePositionOrigin: sharePositionOrigin,
              );
              break;
            case ShareType.audioFile:
              await provider.shareSessionAudio(
                sharePositionOrigin: sharePositionOrigin,
              );
              break;
            case ShareType.sessionLink:
              await provider.shareSessionLink(
                sharePositionOrigin: sharePositionOrigin,
              );
              break;
            case ShareType.text:
              await provider.shareCompleteSession(
                sharePositionOrigin: sharePositionOrigin,
              );
              break;
          }

          // Close loading dialog
          Navigator.of(context).pop();
          
          // Show success message
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${option.title} shared successfully!'),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
        } catch (e) {
          // Close loading dialog
          Navigator.of(context).pop();
          
          // Show error
          _showErrorDialog(context, 'Failed to share: $e');
        }
      },
    );
  }

  void _showErrorDialog(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  String _getStatusText(RecordingState state) {
    return state.displayName;
  }

  Widget _buildInfoRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimerChip(BuildContext context, RecordingProvider provider, Duration? duration, String label) {
    final isSelected = provider.selectedDuration == duration;
    
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        provider.setTimerDuration(selected ? duration : null);
      },
      selectedColor: Theme.of(context).colorScheme.primaryContainer,
      checkmarkColor: Theme.of(context).colorScheme.onPrimaryContainer,
    );
  }
}
