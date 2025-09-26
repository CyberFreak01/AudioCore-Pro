  import 'package:flutter/material.dart';
  import 'package:provider/provider.dart';
  import '../providers/recording_provider.dart';
  import '../services/session_service.dart';
  
  class RecordingScreen extends StatelessWidget {
    const RecordingScreen({super.key});
  
    @override
    Widget build(BuildContext context) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Medical Transcription'),
          backgroundColor: Colors.blue[600],
          foregroundColor: Colors.white,
        ),
        body: Consumer<RecordingProvider>(
          builder: (context, recordingProvider, child) {
            return Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Session Info Card
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Session Status',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Session ID: ${recordingProvider.currentSessionId ?? 'None'}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          Text(
                            'Status: ${_getStatusText(recordingProvider.state)}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          Text(
                            'Duration: ${_formatDuration(recordingProvider.recordingDuration)}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          Text(
                            'Chunks: ${recordingProvider.chunkCounter}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 20),
                  
                  // Recording Indicator
                  if (recordingProvider.isRecording)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.red[50],
                        border: Border.all(color: Colors.red),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.radio_button_checked, color: Colors.red),
                          const SizedBox(width: 8),
                          Text(
                            'RECORDING IN PROGRESS',
                            style: TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
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
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: LinearProgressIndicator(
                                value: _normalizedPeak(recordingProvider.peakLevel),
                                minHeight: 10,
                                backgroundColor: Colors.grey[200],
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              recordingProvider.rmsDb?.toStringAsFixed(1) ?? '--',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Gain', style: Theme.of(context).textTheme.titleSmall),
                            Text(recordingProvider.gain.toStringAsFixed(2)),
                          ],
                        ),
                        Slider(
                          value: recordingProvider.gain.clamp(0.1, 5.0),
                          min: 0.1,
                          max: 5.0,
                          divisions: 49,
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
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: recordingProvider.errorMessage!.contains('permission') 
                            ? Colors.blue[50] 
                            : Colors.orange[50],
                        border: Border.all(
                          color: recordingProvider.errorMessage!.contains('permission') 
                              ? Colors.blue 
                              : Colors.orange
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            recordingProvider.errorMessage!.contains('permission') 
                                ? Icons.mic_off 
                                : Icons.warning, 
                            color: recordingProvider.errorMessage!.contains('permission') 
                                ? Colors.blue 
                                : Colors.orange
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              recordingProvider.errorMessage!,
                              style: TextStyle(
                                color: recordingProvider.errorMessage!.contains('permission') 
                                    ? Colors.blue[800] 
                                    : Colors.orange[800]
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  
                  const Spacer(),
                  
                  // Control Buttons
                  _buildControlButtons(context, recordingProvider),
                  
                  const SizedBox(height: 20),
                  
                  // Session Management Button
                  ElevatedButton.icon(
                    onPressed: () => _showSessionsDialog(context),
                    icon: const Icon(Icons.list),
                    label: const Text('View All Sessions'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    }
  
    Widget _buildControlButtons(BuildContext context, RecordingProvider provider) {
      switch (provider.state) {
        case RecordingState.stopped:
          return ElevatedButton.icon(
            onPressed: () => _startRecording(context),
            icon: const Icon(Icons.mic),
            label: const Text('Start Recording'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          );
        
        case RecordingState.recording:
          return Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => provider.pauseRecording(),
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => provider.stopRecording(),
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          );
        
        case RecordingState.paused:
          return Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => provider.resumeRecording(),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => provider.stopRecording(),
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          );
        
        case RecordingState.error:
          return Column(
            children: [
              ElevatedButton.icon(
                onPressed: () => provider.reset(),
                icon: const Icon(Icons.refresh),
                label: const Text('Reset & Try Again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ],
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
      switch (state) {
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
  
    String _formatDuration(Duration duration) {
      String twoDigits(int n) => n.toString().padLeft(2, '0');
      final minutes = twoDigits(duration.inMinutes.remainder(60));
      final seconds = twoDigits(duration.inSeconds.remainder(60));
      return '$minutes:$seconds';
    }

  double _normalizedPeak(int? peak) {
    if (peak == null) return 0.0;
    // 16-bit PCM max absolute value is 32767
    final norm = peak.abs() / 32767.0;
    return norm.clamp(0.0, 1.0);
  }
  }