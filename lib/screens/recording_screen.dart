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
    return Scaffold(
      appBar: AppBar(title: const Text('Medical Transcription')),
      body: SafeArea(
        child: Consumer<RecordingProvider>(
          builder: (context, provider, _) => _buildBody(context, provider),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, RecordingProvider provider) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16.0),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _SessionInfoCard(provider: provider, onShare: () => _showShareDialog(context, provider)),
              const SizedBox(height: 16),
              if (provider.state == RecordingState.stopped) ...[
                _TimerConfigCard(provider: provider),
                const SizedBox(height: 20),
              ],
              if (provider.isRecording) ...[
                _RecordingIndicatorCard(provider: provider),
                const SizedBox(height: 20),
              ],
              _AudioLevelsCard(provider: provider),
              const SizedBox(height: 20),
              if (provider.errorMessage != null) ...[
                _StatusMessageCard(message: provider.errorMessage!),
                const SizedBox(height: 20),
              ],
              const SizedBox(height: 20),
              _buildControlButtons(context, provider),
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: () => _showSessionsDialog(context),
                icon: const Icon(Icons.list),
                label: const Text('View All Sessions'),
              ),
              SizedBox(height: MediaQuery.of(context).padding.bottom + 20),
            ]),
          ),
        ),
      ],
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
                    subtitle: Text('Total Chunks: ${session['totalChunks'] ?? 0}'),
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

}

class _SessionInfoCard extends StatelessWidget {
  final RecordingProvider provider;
  final VoidCallback onShare;

  const _SessionInfoCard({required this.provider, required this.onShare});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Session Status', style: Theme.of(context).textTheme.headlineSmall),
                if (provider.currentSessionId != null)
                  IconButton(
                    onPressed: onShare,
                    icon: const Icon(Icons.share),
                    tooltip: 'Share Session',
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow(label: 'Session ID', value: provider.currentSessionId ?? 'None'),
            _InfoRow(label: 'Status', value: provider.state.displayName),
            _InfoRow(label: 'Duration', value: DurationFormatter.formatMinutesSeconds(provider.recordingDuration)),
            _InfoRowWithIcon(
              label: 'Uploaded Chunks', 
              value: '${provider.uploadedChunks.length}/${provider.chunkCounter}', 
              icon: Icons.sync
            ),
            if (provider.isTimerEnabled) ...[
              const SizedBox(height: 8),
              const Divider(),
              const SizedBox(height: 8),
              _InfoRow(label: 'Timer', value: DurationFormatter.formatDetailed(provider.selectedDuration ?? Duration.zero)),
              _InfoRow(label: 'Remaining', value: DurationFormatter.formatCountdown(provider.remainingTime ?? Duration.zero)),
            ],
          ],
        ),
      ),
    );
  }
}

class _TimerConfigCard extends StatelessWidget {
  final RecordingProvider provider;

  const _TimerConfigCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Recording Timer', style: Theme.of(context).textTheme.titleLarge),
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
                _TimerChip(provider: provider, duration: null, label: 'No Timer'),
                ...AppConstants.timerPresets.map((duration) => 
                  _TimerChip(provider: provider, duration: duration, label: DurationFormatter.formatTimerLabel(duration))
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordingIndicatorCard extends StatelessWidget {
  final RecordingProvider provider;

  const _RecordingIndicatorCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Card(
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
                  if (provider.isTimerEnabled && provider.remainingTime != null)
                    Text(
                      'Time remaining: ${DurationFormatter.formatCountdown(provider.remainingTime!)}',
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
    );
  }
}

class _AudioLevelsCard extends StatelessWidget {
  final RecordingProvider provider;

  const _AudioLevelsCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Audio Levels', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: AudioLevelCalculator.normalizePeakLevel(provider.peakLevel),
                    minHeight: 8,
                    backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
                    valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
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
                    AudioLevelCalculator.formatRmsDb(provider.rmsDb),
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
                  provider.gain.toStringAsFixed(2),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Slider(
              value: provider.gain.clamp(AppConstants.minGain, AppConstants.maxGain),
              min: AppConstants.minGain,
              max: AppConstants.maxGain,
              divisions: AppConstants.gainDivisions,
              label: provider.gain.toStringAsFixed(2),
              onChanged: (v) => provider.setGain(v),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusMessageCard extends StatelessWidget {
  final String message;

  const _StatusMessageCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: _getCardColor(context, message),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              _getIcon(message),
              color: _getTextColor(context, message),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _getTextColor(context, message),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getCardColor(BuildContext context, String message) {
    if (message.contains('permission')) return Theme.of(context).colorScheme.primaryContainer;
    if (message.contains('auto-paused')) return Theme.of(context).colorScheme.secondaryContainer;
    if (message.contains('Microphone')) return Theme.of(context).colorScheme.tertiaryContainer;
    return Theme.of(context).colorScheme.errorContainer;
  }

  IconData _getIcon(String message) {
    if (message.contains('permission')) return Icons.mic_off;
    if (message.contains('Microphone acquired')) return Icons.mic_external_on;
    if (message.contains('Microphone')) return Icons.mic_none;
    if (message.contains('auto-paused')) return Icons.phone;
    if (message.contains('Incoming call')) return Icons.phone_in_talk;
    if (message.contains('Call in progress')) return Icons.call;
    return Icons.warning;
  }

  Color _getTextColor(BuildContext context, String message) {
    if (message.contains('permission')) return Theme.of(context).colorScheme.onPrimaryContainer;
    if (message.contains('auto-paused')) return Theme.of(context).colorScheme.onSecondaryContainer;
    if (message.contains('Microphone')) return Theme.of(context).colorScheme.onTertiaryContainer;
    return Theme.of(context).colorScheme.onErrorContainer;
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
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
}

class _InfoRowWithIcon extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _InfoRowWithIcon({required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
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
}

class _TimerChip extends StatelessWidget {
  final RecordingProvider provider;
  final Duration? duration;
  final String label;

  const _TimerChip({required this.provider, required this.duration, required this.label});

  @override
  Widget build(BuildContext context) {
    final isSelected = provider.selectedDuration == duration;
    
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) => provider.setTimerDuration(selected ? duration : null),
      selectedColor: Theme.of(context).colorScheme.primaryContainer,
      checkmarkColor: Theme.of(context).colorScheme.onPrimaryContainer,
    );
  }
}
