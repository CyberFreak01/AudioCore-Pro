package com.example.medicalscribe

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.AudioFormat
import android.content.pm.PackageManager
import android.Manifest
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import android.os.VibrationEffect
import android.os.Vibrator
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.app.NotificationManager
import androidx.core.content.getSystemService
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import android.app.PendingIntent
import androidx.core.app.NotificationCompat
import android.app.NotificationChannel
import android.os.Build
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import android.content.BroadcastReceiver
import java.net.HttpURLConnection
import java.net.URL
import java.io.OutputStream
import java.io.FileInputStream
import java.io.BufferedInputStream

class MainActivity: FlutterActivity() {
    private val CHANNEL = "medical_transcription/audio"
    private val EVENT_CHANNEL = "medical_transcription/audio_stream"
    private val MICCHANNEL = "com.example.mediascribe.micService"
    private var audioRecord: AudioRecord? = null
    private var isRecording = false
    private var recordingThread: Thread? = null
    private var eventSink: EventChannel.EventSink? = null
    private var chunkCounter = 0
    private var sessionId: String? = null
    private var chunkBuffer = mutableListOf<Byte>()
    private var gainFactor: Float = 1.0f
    private var lastLevelEmitMs: Long = 0
    private var networkReceiver: android.content.BroadcastReceiver? = null
    
    // Timer functionality
    private var timerDurationMs: Long? = null
    private var timerExecutor: ScheduledExecutorService? = null
    private var recordingStartTime: Long = 0
    private val keyLastActiveSession = "last_active_session"
    private val keyLastActiveAt = "last_active_at"
    private val notifChannelId = "record_control"
    private val notifId = 987654
    private val prefsName = "medical_transcription_prefs"
    
    // Robust chunk management
    private lateinit var robustChunkManager: RobustChunkManager
    private lateinit var networkMonitor: NetworkMonitor
    private lateinit var backgroundTaskManager: BackgroundTaskManager
    private val chunkQueue = ConcurrentLinkedQueue<ChunkItem>()
    private val nextExpectedChunk = AtomicInteger(0)
    private val isUploading = AtomicBoolean(false)
    private val uploadExecutor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    private val maxRetries = 3
    private val retryDelays = longArrayOf(1000, 2000, 5000) // 1s, 2s, 5s
    private var serverBaseUrl = "https://scribe-server-production-f150.up.railway.app"
    private var chunkProcessingReceiver: BroadcastReceiver? = null
    private var recordingActionReceiver: BroadcastReceiver? = null
    
    data class ChunkItem(
        val sessionId: String,
        val chunkNumber: Int,
        val filePath: String,
        val retryCount: Int = 0,
        val createdAt: Long = System.currentTimeMillis()
    )
    
    companion object {
        private const val PERMISSION_REQUEST_CODE = 1001
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startRecording" -> {
                    val newSessionId = call.argument<String>("sessionId")
                    val outputFormat = call.argument<String>("outputFormat") ?: "wav"
                    val sampleRate = call.argument<Int>("sampleRate") ?: 44100
                    val timerDurationArg = call.argument<Any>("timerDuration")
                    val timerDuration = when (timerDurationArg) {
                        is Int -> timerDurationArg.toLong()
                        is Long -> timerDurationArg
                        else -> null
                    }
                    
                    // Check for microphone permission first
                    if (!hasRecordAudioPermission()) {
                        requestRecordAudioPermission()
                        result.error("PERMISSION_ERROR", "Microphone permission required", null)
                        return@setMethodCallHandler
                    }
                    
            // Reset chunk counter and queue only for new sessions
                    if (sessionId != newSessionId) {
                        chunkCounter = 0
                nextExpectedChunk.set(0)
                chunkQueue.clear()
                    }
                    sessionId = newSessionId
                    timerDurationMs = timerDuration
                    
                    hapticIfAllowed()
                    if (startAudioRecording(sessionId, sampleRate)) {
                        result.success("Recording started")
                    } else {
                        result.error("RECORDING_ERROR", "Failed to start recording", null)
                    }
                }
                "stopRecording" -> {
                    hapticIfAllowed()
                    stopTimer()
                    if (stopAudioRecording()) {
                        result.success("Recording stopped")
                    } else {
                        result.error("RECORDING_ERROR", "Failed to stop recording", null)
                    }
                }
                "pauseRecording" -> {
                    hapticIfAllowed()
                    stopTimer()
                    if (pauseAudioRecording()) {
                        result.success("Recording paused")
                    } else {
                        result.error("RECORDING_ERROR", "Failed to pause recording", null)
                    }
                }
                "resumeRecording" -> {
                    hapticIfAllowed()
                    if (resumeAudioRecording()) {
                        // Restart timer if it was set and we still have time
                        if (timerDurationMs != null) {
                            val elapsed = System.currentTimeMillis() - recordingStartTime
                            val remaining = timerDurationMs!! - elapsed
                            if (remaining > 0) {
                                startTimer(remaining)
                            }
                        }
                        result.success("Recording resumed")
                    } else {
                        result.error("RECORDING_ERROR", "Failed to resume recording", null)
                    }
                }
                "setGain" -> {
                    val gain = (call.argument<Double>("gain") ?: 1.0).toFloat()
                    gainFactor = gain.coerceIn(0.1f, 5.0f)
                    result.success(null)
                }
                "getGain" -> {
                    result.success(gainFactor.toDouble())
                }
                "markChunkUploaded" -> {
                    val sid = call.argument<String>("sessionId")
                    val num = call.argument<Int>("chunkNumber")
                    if (sid != null && num != null) {
                        markChunkAsUploaded(sid, num)
                        result.success(true)
                    } else result.success(false)
                }
                "rescanPending" -> {
                    val sid = call.argument<String>("sessionId")
                    if (sid != null) {
                        val pending = getPendingChunks(sid)
                        val list = pending.sorted().map { num ->
                            val f = File(filesDir, "audio_chunks/$sid/chunk_${num}.wav")
                            mapOf(
                                "chunkNumber" to num,
                                "filePath" to f.absolutePath,
                                "exists" to f.exists()
                            )
                        }
                        runOnUiThread {
                            eventSink?.success(mapOf(
                                "type" to "pending_chunks",
                                "sessionId" to sid,
                                "chunks" to list
                            ))
                        }
                        result.success(list.size)
                    } else result.success(0)
                }
                "listPendingSessions" -> {
                    val sessions = listSessionsWithPending()
                    result.success(sessions)
                }
                "getLastActiveSessionId" -> {
                    val prefs = getSharedPreferences(prefsName, MODE_PRIVATE)
                    val sid = prefs.getString(keyLastActiveSession, null)
                    result.success(sid)
                }
                "clearLastActiveSession" -> {
                    val prefs = getSharedPreferences(prefsName, MODE_PRIVATE)
                    prefs.edit().remove(keyLastActiveSession).remove(keyLastActiveAt).apply()
                    result.success(true)
                }
                "setServerUrl" -> {
                    val url = call.argument<String>("url")
                    if (url != null) {
                        serverBaseUrl = url
                        android.util.Log.d("MainActivity", "Server URL updated to: $url")
                        result.success(true)
                    } else {
                        result.error("INVALID_URL", "URL is required", null)
                    }
                }
                "forceResumeProcessing" -> {
                    forceResumeProcessing()
                    result.success(true)
                }
                "getQueueStatus" -> {
                    val stats = robustChunkManager.getStatistics()
                    val networkInfo = networkMonitor.getNetworkInfo()
                    val workInfo = backgroundTaskManager.getWorkInfo()
                    
                    val status = mapOf(
                        "robustStats" to stats,
                        "networkInfo" to networkInfo,
                        "backgroundWork" to workInfo,
                        "isProcessing" to isUploading.get()
                    )
                    result.success(status)
                }
                "recoverChunks" -> {
                    val stats = robustChunkManager.getStatistics()
                    val pendingCount = stats["pendingChunks"] as? Int ?: 0
                    android.util.Log.d("MainActivity", "Manual recovery requested, $pendingCount chunks pending")
                    processChunkQueue()
                    result.success(pendingCount)
                }
                "getNetworkInfo" -> {
                    val networkInfo = networkMonitor.getNetworkInfo()
                    result.success(networkInfo)
                }
                "retryFailedChunks" -> {
                    retryFailedChunks()
                    result.success(true)
                }
                "getSessionAudioFiles" -> {
                    val sid = call.argument<String>("sessionId")
                    if (sid != null) {
                        val audioFiles = getSessionAudioFiles(sid)
                        result.success(audioFiles)
                    } else {
                        result.error("INVALID_SESSION", "Session ID is required", null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Set up event channel for streaming audio chunks
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            }
        )

        // MethodChannel for controlling Mic foreground service
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MICCHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startMic" -> {
                    val intent = Intent(this, MicService::class.java)
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "stopMic" -> {
                    val intent = Intent(this, MicService::class.java)
                    stopService(intent)
                    result.success(null)
                }
                "shareSession" -> {
                    val sid = call.argument<String>("sessionId")
                    if (sid == null) { result.error("ARG_ERROR", "sessionId required", null); return@setMethodCallHandler }
                    shareSessionChunks(sid)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Initialize enhanced chunk management system
        initializeChunkManagement()
        
        registerAudioRouteReceivers()
        registerNetworkAvailableReceiver()
        registerRecordingActionReceiver()
        registerChunkProcessingReceiver()
        ensureControlNotificationChannel()

        // On Android 13+, request notification permission once at startup to show controls
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            try {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 2002)
            } catch (_: Exception) {}
        }
        
        // Schedule background tasks and recovery
        backgroundTaskManager.scheduleChunkUploadWork()
        backgroundTaskManager.scheduleCleanupWork()
        backgroundTaskManager.scheduleChunkRecoveryWork()
    }

    private fun startAudioRecording(sessionId: String?, sampleRate: Int): Boolean {
        try {
            if (isRecording) {
                return false
            }

            val channelConfig = AudioFormat.CHANNEL_IN_MONO
            val audioFormat = AudioFormat.ENCODING_PCM_16BIT
            val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)

            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                channelConfig,
                audioFormat,
                bufferSize
            )

            if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
                return false
            }

            audioRecord?.startRecording()
            isRecording = true
            recordingStartTime = System.currentTimeMillis()
            // Only reset chunk counter when starting a completely new session
            // Keep incrementing for pause/resume within same session
            chunkBuffer.clear()
            
            // Start timer if duration is set
            timerDurationMs?.let { duration ->
                startTimer(duration)
            }

            // Persist last active session for crash/kill recovery
            sessionId?.let {
                val prefs = getSharedPreferences(prefsName, MODE_PRIVATE)
                prefs.edit()
                    .putString(keyLastActiveSession, it)
                    .putLong(keyLastActiveAt, System.currentTimeMillis())
                    .apply()
            }

            // Start recording thread that captures audio and creates chunks
            recordingThread = Thread {
                val buffer = ByteArray(bufferSize)
                val chunkDurationMs = 5000 // 5 second chunks
                val samplesPerChunk = (sampleRate * chunkDurationMs) / 1000
                val bytesPerChunk = samplesPerChunk * 2 // 16-bit samples = 2 bytes each
                
                while (isRecording) {
                    val bytesRead = audioRecord?.read(buffer, 0, buffer.size) ?: 0
                    if (bytesRead > 0) {
                        applyGainInPlace(buffer, bytesRead)
                        emitAudioLevel(buffer, bytesRead)
                        // Add to chunk buffer
                        for (i in 0 until bytesRead) {
                            chunkBuffer.add(buffer[i])
                        }
                        
                        // Check if chunk is ready
                        if (chunkBuffer.size >= bytesPerChunk) {
                            saveAndStreamChunk(chunkBuffer.toByteArray())
                            chunkBuffer.clear()
                        }
                    }
                    Thread.sleep(10) // Small delay to prevent excessive CPU usage
                }
                
                // Flush any remaining buffer when recording stops
                if (chunkBuffer.isNotEmpty()) {
                    saveAndStreamChunk(chunkBuffer.toByteArray())
                    chunkBuffer.clear()
                }
            }
            recordingThread?.start()

            // Show control notification with actions (Pause/Stop)
            showControlNotification()

            return true
        } catch (e: Exception) {
            return false
        }
    }
    
    private fun startTimer(durationMs: Long) {
        stopTimer() // Stop any existing timer
        
        timerExecutor = Executors.newSingleThreadScheduledExecutor()
        timerExecutor?.schedule({
            // Auto-stop recording when timer expires
            if (isRecording) {
                android.util.Log.d("MainActivity", "Recording timer expired, auto-stopping...")
                stopAudioRecording()
                // Notify Flutter that recording stopped due to timer
                eventSink?.success(mapOf(
                    "type" to "recording_stopped",
                    "reason" to "timer_expired",
                    "totalChunks" to chunkCounter
                ))
            }
        }, durationMs, TimeUnit.MILLISECONDS)
    }
    
    private fun stopTimer() {
        timerExecutor?.shutdown()
        timerExecutor = null
    }

    private fun saveAndStreamChunk(audioData: ByteArray) {
        try {
            // Create chunk file
            val chunksDir = File(filesDir, "audio_chunks/${sessionId}")
            chunksDir.mkdirs()
            
            val chunkFile = File(chunksDir, "chunk_${chunkCounter}.wav")
            
            // Write WAV header and audio data
            writeWavFile(chunkFile, audioData, 44100)

            // Add to robust chunk manager with immediate persistence
            val success = robustChunkManager.addChunk(sessionId!!, chunkCounter, chunkFile.absolutePath)
            if (success) {
                android.util.Log.d("MainActivity", "Chunk $chunkCounter saved and persisted successfully")
                
                // Start upload process immediately if network is available
                if (networkMonitor.isUploadRecommended()) {
                    android.util.Log.d("MainActivity", "Network available - processing chunks")
                    processChunkQueue()
                }
            } else {
                android.util.Log.e("MainActivity", "Failed to persist chunk $chunkCounter")
            }
            
            chunkCounter++
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Failed to save chunk: ${e.message}", e)
            runOnUiThread {
                eventSink?.error("CHUNK_ERROR", "Failed to save chunk: ${e.message}", null)
            }
        }
    }

    private fun writeWavFile(file: File, audioData: ByteArray, sampleRate: Int) {
        try {
            val fos = FileOutputStream(file)
            
            // WAV header
            val channels = 1
            val bitsPerSample = 16
            val dataSize = audioData.size
            val fileSize = dataSize + 36
            
            // RIFF header
            fos.write("RIFF".toByteArray())
            fos.write(intToByteArray(fileSize))
            fos.write("WAVE".toByteArray())
            
            // Format chunk
            fos.write("fmt ".toByteArray())
            fos.write(intToByteArray(16)) // Chunk size
            fos.write(shortToByteArray(1)) // Audio format (PCM)
            fos.write(shortToByteArray(channels))
            fos.write(intToByteArray(sampleRate))
            fos.write(intToByteArray(sampleRate * channels * bitsPerSample / 8)) // Byte rate
            fos.write(shortToByteArray(channels * bitsPerSample / 8)) // Block align
            fos.write(shortToByteArray(bitsPerSample))
            
            // Data chunk
            fos.write("data".toByteArray())
            fos.write(intToByteArray(dataSize))
            fos.write(audioData)
            
            fos.close()
        } catch (e: IOException) {
            throw e
        }
    }

    private fun intToByteArray(value: Int): ByteArray {
        return byteArrayOf(
            (value and 0xFF).toByte(),
            ((value shr 8) and 0xFF).toByte(),
            ((value shr 16) and 0xFF).toByte(),
            ((value shr 24) and 0xFF).toByte()
        )
    }

    private fun shortToByteArray(value: Int): ByteArray {
        return byteArrayOf(
            (value and 0xFF).toByte(),
            ((value shr 8) and 0xFF).toByte()
        )
    }

    private fun stopAudioRecording(): Boolean {
        try {
            // Allow stop from any state (recording or paused)
            val hadSession = sessionId != null
            isRecording = false
            try { audioRecord?.stop() } catch (_: Exception) {}
            try { audioRecord?.release() } catch (_: Exception) {}
            audioRecord = null
            
            // Wait for the thread to finish naturally (allow final flush)
            try { recordingThread?.join(2000) } catch (_: Exception) {}
            recordingThread = null

            if (hadSession) {
            // Notify Flutter that recording stopped on main thread
            runOnUiThread {
                eventSink?.success(mapOf(
                    "type" to "recording_stopped",
                    "sessionId" to sessionId,
                    "totalChunks" to chunkCounter
                ))
            }

                // Persist remaining chunks for recovery
                persistChunkQueue()
            }

            cancelControlNotification()
            return true
        } catch (e: Exception) {
            return false
        }
    }

    private fun pauseAudioRecording(): Boolean {
        val ok = stopAudioRecording() // pause implemented as stop stream while keeping session
        if (ok) {
            // Update notification to show Resume
            showControlNotification()
        }
        return ok
    }

    private fun resumeAudioRecording(): Boolean {
        // For simplicity, just continue with current session
        val ok = sessionId?.let { startAudioRecording(it, 44100) } ?: false
        if (ok) {
            showControlNotification()
        }
        return ok
    }

    private fun hasRecordAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestRecordAudioPermission() {
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            PERMISSION_REQUEST_CODE
        )
    }

    private fun applyGainInPlace(buffer: ByteArray, length: Int) {
        if (gainFactor == 1.0f) return
        var i = 0
        while (i + 1 < length) {
            val low = buffer[i].toInt() and 0xFF
            val high = buffer[i+1].toInt()
            var sample = (high shl 8) or low
            if (sample and 0x8000 != 0) sample = sample or -0x10000
            var out = (sample * gainFactor).toInt()
            if (out > Short.MAX_VALUE.toInt()) out = Short.MAX_VALUE.toInt()
            if (out < Short.MIN_VALUE.toInt()) out = Short.MIN_VALUE.toInt()
            buffer[i] = (out and 0xFF).toByte()
            buffer[i+1] = ((out shr 8) and 0xFF).toByte()
            i += 2
        }
    }

    private fun emitAudioLevel(buffer: ByteArray, length: Int) {
        val now = System.currentTimeMillis()
        if (now - lastLevelEmitMs < 100) return
        lastLevelEmitMs = now
        var i = 0
        var sumSq = 0.0
        var count = 0
        var peak = 0
        while (i + 1 < length) {
            val low = buffer[i].toInt() and 0xFF
            val high = buffer[i+1].toInt()
            var sample = (high shl 8) or low
            if (sample and 0x8000 != 0) sample = sample or -0x10000
            val abs = kotlin.math.abs(sample)
            if (abs > peak) peak = abs
            sumSq += (sample.toDouble() * sample.toDouble())
            count++
            i += 2
        }
        if (count == 0) return
        val rms = kotlin.math.sqrt(sumSq / count)
        val db = 20.0 * kotlin.math.log10(rms / Short.MAX_VALUE.toDouble() + 1e-9)
        runOnUiThread {
            eventSink?.success(mapOf(
                "type" to "audio_level",
                "rmsDb" to db,
                "peak" to peak
            ))
        }
    }

    private fun hapticIfAllowed() {
        try {
        // Check Do Not Disturb mode
        val nm = getSystemService(NotificationManager::class.java)
            if (nm != null && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
            // Only allow haptics if interruption filter is set to ALL (normal mode)
            if (nm.currentInterruptionFilter != NotificationManager.INTERRUPTION_FILTER_ALL) {
                return
            }
        }
        
        // Check ringer mode - only vibrate in normal or vibrate mode
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager?
        if (audioManager?.ringerMode == AudioManager.RINGER_MODE_SILENT) {
            return
        }
        
        // Check if user has enabled haptic feedback
        val vibrationEnabled = android.provider.Settings.System.getInt(
            contentResolver, 
            android.provider.Settings.System.HAPTIC_FEEDBACK_ENABLED, 
            1
        ) == 1
        
        if (!vibrationEnabled) {
            return
        }
        
        // Perform haptic feedback
        val vibrator = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            val vibratorManager = getSystemService(VIBRATOR_MANAGER_SERVICE) as android.os.VibratorManager
            vibratorManager.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(VIBRATOR_SERVICE) as Vibrator
        }
        
        if (vibrator?.hasVibrator() == true) {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                vibrator.vibrate(VibrationEffect.createOneShot(50, VibrationEffect.DEFAULT_AMPLITUDE))
                } else {
                    @Suppress("DEPRECATION")
                vibrator.vibrate(50)
            }
        }
    } catch (e: Exception) {
        android.util.Log.d("MainActivity", "Haptic feedback skipped: ${e.message}")
    }
}

    private fun ensureControlNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                notifChannelId,
                "Recording Controls",
                NotificationManager.IMPORTANCE_LOW // No sound, respectful of DND
            )
            val nm = getSystemService(NotificationManager::class.java)
            nm?.createNotificationChannel(channel)
        }
    }

    private fun showControlNotification() {
        try {
            // Create explicit intents with the component name
            val stopIntent = Intent(this, NotificationActionReceiver::class.java).apply { 
                action = "com.example.medicalscribe.RECORDING_ACTION"
                putExtra("action", "stop")
                addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)
            }
            
            val pauseResumeIntent = Intent(this, NotificationActionReceiver::class.java).apply { 
                action = "com.example.medicalscribe.RECORDING_ACTION"
                putExtra("action", if (isRecording) "pause" else "resume")
                addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)
            }

            val stopPi = PendingIntent.getBroadcast(
                this, 
                100, 
                stopIntent, 
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            
            val pauseResumePi = PendingIntent.getBroadcast(
                this, 
                101, 
                pauseResumeIntent, 
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            )

            val builder = NotificationCompat.Builder(this, notifChannelId)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(if (isRecording) "Recording in progress" else "Recording paused")
                .setContentText(if (isRecording) "Tap to pause or stop" else "Tap to resume or stop")
                .setOngoing(true)
                .setSilent(true)
                .addAction(
                    if (!isRecording)
                        NotificationCompat.Action(
                            android.R.drawable.ic_media_play, 
                            "Resume", 
                            pauseResumePi
                        )
                    else 
                        NotificationCompat.Action(
                            android.R.drawable.ic_media_pause, 
                            "Pause", 
                            pauseResumePi
                        )
                )
                .addAction(
                    NotificationCompat.Action(
                        R.drawable.ic_media_stop, 
                        "Stop", 
                        stopPi
                    )
                )
                .setAutoCancel(false) // Prevent accidental dismissal
                .setContentIntent(
                    PendingIntent.getActivity(
                        this,
                        0,
                        packageManager.getLaunchIntentForPackage(packageName),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                )

            val notification = builder.build()

            // Start service and post the notification
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                startForegroundService(Intent(this, MicService::class.java))
            } else {
                @Suppress("DEPRECATION")
                startService(Intent(this, MicService::class.java))
            }
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .notify(notifId, notification)
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Failed to show notification", e)
        }
}

    private fun cancelControlNotification() {
        try {
            val nm = getSystemService(NotificationManager::class.java)
            nm?.cancel(notifId)
        } catch (_: Exception) {}
    }

    // Ordered chunk upload system
    private fun startOrderedUpload() {
        // Legacy method - now delegates to robust chunk processing
        processChunkQueue()
    }
    
    private fun getPresignedUrl(sessionId: String, chunkNumber: Int): String? {
        return try {
            val url = URL("$serverBaseUrl/get-presigned-url")
            val connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.setRequestProperty("Content-Type", "application/json")
            connection.doOutput = true
            connection.connectTimeout = 10000 // 10 second timeout
            connection.readTimeout = 15000 // 15 second read timeout
            
            val jsonInput = """{"sessionId":"$sessionId","chunkNumber":$chunkNumber}"""
            val outputStream = connection.outputStream
            outputStream.write(jsonInput.toByteArray())
            outputStream.close()
            
            val responseCode = connection.responseCode
            if (responseCode == 200) {
                val response = connection.inputStream.bufferedReader().use { it.readText() }
                // Parse JSON response to get presignedUrl
                val presignedUrl = response.substringAfter("\"presignedUrl\":\"").substringBefore("\"")
                android.util.Log.d("MainActivity", "Got presigned URL: $presignedUrl")
                presignedUrl
            } else {
                val errorResponse = connection.errorStream?.bufferedReader()?.use { it.readText() }
                android.util.Log.e("MainActivity", "Failed to get presigned URL: $responseCode - $errorResponse")
                null
            }
        } catch (e: java.net.ConnectException) {
            android.util.Log.e("MainActivity", "Network connection failed to server: ${e.message}")
            null
        } catch (e: java.net.SocketTimeoutException) {
            android.util.Log.e("MainActivity", "Request timeout to server: ${e.message}")
            null
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error getting presigned URL: ${e.javaClass.simpleName} - ${e.message}")
            null
        }
    }
    
    private fun uploadChunkFile(presignedUrl: String, file: File): Boolean {
        return try {
            // Ensure HTTPS for production server
            val secureUrl = if (presignedUrl.startsWith("http://") && presignedUrl.contains("railway.app")) {
                presignedUrl.replace("http://", "https://")
            } else {
                presignedUrl
            }
            android.util.Log.d("MainActivity", "Original URL: $presignedUrl")
            android.util.Log.d("MainActivity", "Secure URL: $secureUrl")
            val url = URL(secureUrl)
            val connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            
            // Create multipart/form-data boundary
            val boundary = "----WebKitFormBoundary${System.currentTimeMillis()}"
            connection.setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
            connection.doOutput = true
            
            val outputStream = connection.outputStream
            
            // Write multipart form data
            outputStream.write("--$boundary\r\n".toByteArray())
            outputStream.write("Content-Disposition: form-data; name=\"audio\"; filename=\"chunk.wav\"\r\n".toByteArray())
            outputStream.write("Content-Type: audio/wav\r\n\r\n".toByteArray())
            
            // Write file content
            val inputStream = BufferedInputStream(FileInputStream(file))
            val buffer = ByteArray(8192)
            var bytesRead: Int
            
            while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                outputStream.write(buffer, 0, bytesRead)
            }
            
            inputStream.close()
            
            // Write closing boundary
            outputStream.write("\r\n--$boundary--\r\n".toByteArray())
            outputStream.close()
            
            val responseCode = connection.responseCode
            val success = responseCode in 200..299
            
            if (success) {
                val response = connection.inputStream.bufferedReader().use { it.readText() }
                android.util.Log.d("MainActivity", "Upload successful: $response")
            } else {
                val errorResponse = connection.errorStream?.bufferedReader()?.use { it.readText() }
                android.util.Log.e("MainActivity", "Upload failed: $responseCode - $errorResponse")
            }
            
            success
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error uploading file", e)
            false
        }
    }
    
    private fun notifyChunkUploaded(sessionId: String, chunkNumber: Int): Boolean {
        return try {
            val url = URL("$serverBaseUrl/notify-chunk-uploaded")
            val connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.setRequestProperty("Content-Type", "application/json")
            connection.doOutput = true
            
            val jsonInput = """{"sessionId":"$sessionId","chunkNumber":$chunkNumber}"""
            val outputStream = connection.outputStream
            outputStream.write(jsonInput.toByteArray())
            outputStream.close()
            
            val responseCode = connection.responseCode
            val success = responseCode in 200..299
            android.util.Log.d("MainActivity", "Notify response: $responseCode")
            success
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error notifying server", e)
            false
        }
    }

    private fun handleChunkRetry(chunk: ChunkItem) {
        // Legacy method - now handled by robust chunk manager
        android.util.Log.d("MainActivity", "Chunk retry handled by robust chunk manager")
    }
    
    // Force resume processing (can be called from Flutter)
    private fun forceResumeProcessing() {
        android.util.Log.d("MainActivity", "Force resuming chunk processing")
        uploadExecutor.schedule({
            if (isUploading.compareAndSet(false, true)) {
                processChunkQueue()
            }
        }, 500, TimeUnit.MILLISECONDS)
    }

    private fun registerAudioRouteReceivers() {
        val filter = IntentFilter()
        filter.addAction(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        val noisyReceiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: android.content.Context?, intent: Intent?) {
                if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    runOnUiThread {
                        eventSink?.success(mapOf(
                            "type" to "route_change",
                            "reason" to "becoming_noisy"
                        ))
                    }
                }
            }
        }
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            registerReceiver(noisyReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(noisyReceiver, filter)
        }
    }

    private fun registerNetworkAvailableReceiver() {
        val filter = IntentFilter("com.example.medicalscribe.NETWORK_AVAILABLE")
        networkReceiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: android.content.Context?, intent: Intent?) {
                runOnUiThread {
                    eventSink?.success(mapOf(
                        "type" to "network_available"
                    ))
                }
                // Resume upload processing when network is available - be aggressive
                android.util.Log.d("MainActivity", "Network available broadcast received - resuming upload processing immediately")
                
                // Process chunk queue immediately
                uploadExecutor.schedule({
                    processChunkQueue()
                }, 200, TimeUnit.MILLISECONDS)
            }
        }
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            registerReceiver(networkReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(networkReceiver, filter)
        }
    }

    private fun registerRecordingActionReceiver() {
        val filter = IntentFilter("com.example.medicalscribe.RECORDING_ACTION")
        recordingActionReceiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: android.content.Context?, intent: Intent?) {
                val action = intent?.getStringExtra("action")
                android.util.Log.d("MainActivity", "Received notification action: $action")
                when (action) {
                    "stop" -> {
                        hapticIfAllowed()
                        stopTimer()
                        stopAudioRecording()
                        cancelControlNotification()
                        // Notify Flutter that recording was stopped from notification
                        runOnUiThread {
                            eventSink?.success(mapOf(
                                "type" to "recording_state_changed",
                                "state" to "stopped",
                                "source" to "notification",
                                "sessionId" to sessionId,
                                "totalChunks" to chunkCounter
                            ))
                        }
                    }
                    "pause" -> {
                        hapticIfAllowed()
                        if (isRecording) {
                            stopTimer()
                            pauseAudioRecording()
                            showControlNotification() // Update notification to show resume button
                            // Notify Flutter that recording was paused from notification
                            runOnUiThread {
                                val elapsed = System.currentTimeMillis() - recordingStartTime
                                val remainingMs = if (timerDurationMs != null) {
                                    maxOf(0, timerDurationMs!! - elapsed)
                                } else null
                                
                                eventSink?.success(mapOf(
                                    "type" to "recording_state_changed",
                                    "state" to "paused",
                                    "source" to "notification",
                                    "sessionId" to sessionId,
                                    "remainingTimeMs" to remainingMs
                                ))
                            }
                        }
                    }
                    "resume" -> {
                        hapticIfAllowed()
                        if (!isRecording) {
                            resumeAudioRecording()
                            // Restart timer if it was set and we still have time
                            if (timerDurationMs != null) {
                                val elapsed = System.currentTimeMillis() - recordingStartTime
                                val remaining = timerDurationMs!! - elapsed
                                if (remaining > 0) {
                                    startTimer(remaining)
                                }
                            }
                            showControlNotification() // Update notification to show pause button
                            // Notify Flutter that recording was resumed from notification
                            runOnUiThread {
                                val elapsed = System.currentTimeMillis() - recordingStartTime
                                val remainingMs = if (timerDurationMs != null) {
                                    maxOf(0, timerDurationMs!! - elapsed)
                                } else null
                                
                                eventSink?.success(mapOf(
                                    "type" to "recording_state_changed",
                                    "state" to "recording",
                                    "source" to "notification",
                                    "sessionId" to sessionId,
                                    "remainingTimeMs" to remainingMs
                                ))
                            }
                        }
                    }
                }
            }
        }
        
        recordingActionReceiver?.let { receiver ->
            try {
                if (android.os.Build.VERSION.SDK_INT >= 34) {
                    // For Android 14+ we need to use the exported flag
                    registerReceiver(receiver, filter, RECEIVER_EXPORTED)
                } else if (android.os.Build.VERSION.SDK_INT >= 33) {
                    // For Android 13
                    registerReceiver(receiver, filter, RECEIVER_NOT_EXPORTED)
                } else {
                    // For older versions
                    @Suppress("DEPRECATION")
                    registerReceiver(receiver, filter)
                }
                android.util.Log.d("MainActivity", "Registered recording action receiver")
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "Error registering receiver", e)
            }
        }
    }

    private fun addPendingChunk(sid: String?, number: Int) {
        if (sid == null) return
        try {
            val dir = File(filesDir, "audio_chunks/$sid")
            dir.mkdirs()
            val file = File(dir, "pending.txt")
            val key = "chunk_$number"
            // Avoid duplicates
            if (!file.exists() || !file.readText().lines().any { it.trim() == key }) {
                FileOutputStream(file, true).use { it.write((key + "\n").toByteArray()) }
            }
        } catch (_: Exception) {}
    }

    private fun markChunkAsUploaded(sid: String, number: Int) {
        try {
            // Legacy method - now handled by robust chunk manager
            android.util.Log.d("MainActivity", "Chunk marked as uploaded: $number")
            
            // Legacy file-based tracking for compatibility
            val dir = File(filesDir, "audio_chunks/$sid")
            val file = File(dir, "pending.txt")
            if (!file.exists()) return
            val lines = file.readLines().filterNot { it.trim() == "chunk_$number" }
            file.writeText(lines.joinToString("\n", postfix = if (lines.isNotEmpty()) "\n" else ""))
            
            android.util.Log.d("MainActivity", "Marked chunk $number as uploaded for session $sid")
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error marking chunk as uploaded", e)
        }
    }

    private fun getPendingChunks(sid: String): List<Int> {
        return try {
            val dir = File(filesDir, "audio_chunks/$sid")
            val file = File(dir, "pending.txt")
            if (!file.exists()) emptyList() else file.readLines()
                .map { it.trim() }
                .filter { it.startsWith("chunk_") }
                .mapNotNull { it.removePrefix("chunk_").toIntOrNull() }
        } catch (_: Exception) { emptyList() }
    }

    private fun shareSessionChunks(sid: String) {
        val dir = File(filesDir, "audio_chunks/$sid")
        if (!dir.exists()) return
        val files = dir.listFiles { f -> f.isFile && f.name.endsWith(".wav") }?.toList() ?: emptyList()
        if (files.isEmpty()) return
        val uris = ArrayList<android.net.Uri>()
        for (f in files) {
            val uri = androidx.core.content.FileProvider.getUriForFile(this, "com.example.medicalscribe.fileprovider", f)
            uris.add(uri)
        }
        val intent = Intent(Intent.ACTION_SEND_MULTIPLE)
        intent.type = "audio/wav"
        intent.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(Intent.createChooser(intent, "Share session $sid"))
    }

    private fun listSessionsWithPending(): List<Map<String, Any>> {
        val root = File(filesDir, "audio_chunks")
        if (!root.exists()) return emptyList()
        val sessions = ArrayList<Map<String, Any>>()
        val dirs = root.listFiles { f -> f.isDirectory } ?: return emptyList()
        for (d in dirs) {
            val sid = d.name
            val pending = getPendingChunks(sid)
            if (pending.isNotEmpty()) {
                sessions.add(mapOf(
                    "sessionId" to sid,
                    "pendingCount" to pending.size
                ))
            }
        }
        return sessions
    }

    // Chunk persistence and recovery
    private fun persistChunkQueue() {
        try {
            val prefs = getSharedPreferences(prefsName, MODE_PRIVATE)
            val chunksJson = chunkQueue.joinToString(",") { chunk ->
                "${chunk.sessionId}:${chunk.chunkNumber}:${chunk.filePath}:${chunk.retryCount}"
            }
            prefs.edit()
                .putString("chunk_queue", chunksJson)
                .putInt("next_expected_chunk", nextExpectedChunk.get())
                .apply()
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Failed to persist chunk queue", e)
        }
    }

    private fun recoverChunkQueue() {
        try {
            val prefs = getSharedPreferences(prefsName, MODE_PRIVATE)
            val chunksJson = prefs.getString("chunk_queue", null)
            val nextChunk = prefs.getInt("next_expected_chunk", 0)
            val lastSessionId = prefs.getString(keyLastActiveSession, null)
            
            if (chunksJson != null && chunksJson.isNotEmpty() && lastSessionId != null) {
                chunkQueue.clear()
                var validChunks = 0
                
                chunksJson.split(",").forEach { chunkStr ->
                    val parts = chunkStr.split(":")
                    if (parts.size >= 4) {
                        val chunk = ChunkItem(
                            sessionId = parts[0],
                            chunkNumber = parts[1].toIntOrNull() ?: 0,
                            filePath = parts[2],
                            retryCount = parts[3].toIntOrNull() ?: 0
                        )
                        
                        // Verify chunk file still exists
                        val file = File(chunk.filePath)
                        if (file.exists() && file.length() > 0) {
                            chunkQueue.offer(chunk)
                            validChunks++
                            android.util.Log.d("MainActivity", "Recovered valid chunk ${chunk.chunkNumber} for session ${chunk.sessionId}")
                        } else {
                            android.util.Log.w("MainActivity", "Skipping invalid chunk ${chunk.chunkNumber} - file missing or empty")
                        }
                    }
                }
                
                nextExpectedChunk.set(nextChunk)
                
                if (validChunks > 0) {
                    android.util.Log.d("MainActivity", "Recovered $validChunks valid chunks from queue for session $lastSessionId")
                    
                    // Start processing recovered chunks with a small delay to ensure network is ready
                    uploadExecutor.schedule({
                        startOrderedUpload()
                    }, 2000, TimeUnit.MILLISECONDS)
                } else {
                    android.util.Log.d("MainActivity", "No valid chunks to recover")
                    // Clear invalid queue data
                    clearChunkQueue()
                }
            } else {
                android.util.Log.d("MainActivity", "No chunk queue data to recover")
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Failed to recover chunk queue", e)
            // Clear corrupted queue data
            clearChunkQueue()
        }
    }

    private fun clearChunkQueue() {
        chunkQueue.clear()
        nextExpectedChunk.set(0)
        val prefs = getSharedPreferences(prefsName, MODE_PRIVATE)
        prefs.edit()
            .remove("chunk_queue")
            .remove("next_expected_chunk")
            .apply()
    }

    /**
     * Initialize enhanced chunk management system
     */
    private fun initializeChunkManagement() {
        try {
            robustChunkManager = RobustChunkManager(this)
            networkMonitor = NetworkMonitor(this)
            backgroundTaskManager = BackgroundTaskManager(this)
            
            // Start network monitoring
            networkMonitor.startMonitoring { networkState ->
                android.util.Log.d("MainActivity", "Network state changed: $networkState")
                
                // Resume chunk processing when network becomes available
                if (networkState.isAvailable) {
                    android.util.Log.d("MainActivity", "Network recovered - resuming chunk uploads immediately")
                    
                    // Immediate upload attempt
                    uploadExecutor.schedule({
                        startOrderedUpload()
                    }, 500, TimeUnit.MILLISECONDS)
                    
                    // Trigger chunk processing
                    uploadExecutor.schedule({
                        processChunkQueue()
                    }, 500, TimeUnit.MILLISECONDS)
                }
                
                // Notify Flutter about network changes
                runOnUiThread {
                    eventSink?.success(mapOf(
                        "type" to "network_state_changed",
                        "networkState" to mapOf(
                            "isAvailable" to networkState.isAvailable,
                            "isWifi" to networkState.isWifi,
                            "isMetered" to networkState.isMetered,
                            "connectionType" to networkState.connectionType,
                            "uploadBatchSize" to networkState.uploadBatchSize
                        )
                    ))
                }
            }
            
            android.util.Log.d("MainActivity", "Enhanced chunk management system initialized")
            
            // Initialize robust chunk manager with automatic recovery
            val recoveredCount = robustChunkManager.initialize()
            android.util.Log.d("MainActivity", "Robust chunk manager initialized, recovered $recoveredCount chunks")
            
            // Immediately start processing recovered chunks if any exist
            if (recoveredCount > 0) {
                android.util.Log.d("MainActivity", "Starting immediate processing of $recoveredCount recovered chunks")
                
                // Start processing immediately (no delay)
                uploadExecutor.execute {
                    processChunkQueue()
                }
                
                // Notify Flutter about recovery
                runOnUiThread {
                    eventSink?.success(mapOf(
                        "type" to "chunks_recovered",
                        "count" to recoveredCount
                    ))
                }
            } else {
                android.util.Log.d("MainActivity", "No chunks to recover")
            }
            
            // Start continuous background processing system
            startContinuousBackgroundProcessing()
            
            // Schedule periodic chunk processing to ensure nothing gets stuck
            uploadExecutor.scheduleWithFixedDelay({
                try {
                    val stats = robustChunkManager.getStatistics()
                    val pendingCount = stats["pendingChunks"] as? Int ?: 0
                    if (pendingCount > 0 && networkMonitor.isUploadRecommended()) {
                        android.util.Log.d("MainActivity", "Periodic check: Processing $pendingCount pending chunks")
                        processChunkQueue()
                    }
                } catch (e: Exception) {
                    android.util.Log.e("MainActivity", "Error in periodic chunk processing", e)
                }
            }, 10, 10, TimeUnit.SECONDS) // Check every 10 seconds (more frequent)
            
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Failed to initialize chunk management", e)
        }
    }
    
    /**
     * Start continuous background processing system
     */
    private fun startContinuousBackgroundProcessing() {
        try {
            android.util.Log.d("MainActivity", "Starting continuous background processing system")
            
            // Start foreground service for continuous processing while app is open
            backgroundTaskManager.startChunkUploadService()
            
            // Schedule WorkManager tasks for background processing when app is closed
            backgroundTaskManager.scheduleContinuousUploadWork()
            backgroundTaskManager.scheduleChunkRecoveryWork()
            
            android.util.Log.d("MainActivity", "Continuous background processing system started")
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Failed to start continuous background processing", e)
        }
    }
    
    /**
     * Process chunk queue using RobustChunkManager
     */
    private fun processChunkQueue() {
        if (!::robustChunkManager.isInitialized || !networkMonitor.isUploadRecommended()) {
            return
        }
        
        uploadExecutor.execute {
            try {
                val batchSize = networkMonitor.getOptimalBatchSize()
                val chunks = robustChunkManager.getNextChunkBatch(batchSize)
                
                if (chunks.isNotEmpty()) {
                    android.util.Log.d("MainActivity", "Processing ${chunks.size} chunks from robust queue")
                    
                    for (chunk in chunks) {
                        // Mark as uploading
                        robustChunkManager.markChunkUploading(chunk.id)
                        
                        // Upload chunk
                        val success = uploadChunkToServer(chunk)
                        
                        if (success) {
                            // Mark as completed and cleanup
                            robustChunkManager.markChunkCompleted(chunk.id, chunk.filePath)
                            android.util.Log.d("MainActivity", "Chunk ${chunk.chunkNumber} uploaded and completed")
                            
                            // Notify Flutter
                            runOnUiThread {
                                eventSink?.success(mapOf(
                                    "type" to "chunk_uploaded",
                                    "sessionId" to chunk.sessionId,
                                    "chunkNumber" to chunk.chunkNumber
                                ))
                            }
                        } else {
                            // Handle failure with retry logic
                            val newRetryCount = chunk.retryCount + 1
                            robustChunkManager.markChunkFailed(chunk.id, newRetryCount)
                            android.util.Log.w("MainActivity", "Chunk ${chunk.chunkNumber} upload failed, retry count: $newRetryCount")
                        }
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "Error processing chunk queue", e)
            }
        }
    }
    
    /**
     * Upload chunk to server using existing logic
     */
    private fun uploadChunkToServer(chunk: RobustChunkManager.ChunkItem): Boolean {
        return try {
            val file = File(chunk.filePath)
            if (!file.exists()) {
                android.util.Log.e("MainActivity", "Chunk file not found: ${chunk.filePath}")
                return false
            }
            
            // Use existing upload logic
            val presignedUrl = getPresignedUrl(chunk.sessionId, chunk.chunkNumber)
            if (presignedUrl != null) {
                uploadChunkFile(presignedUrl, file)
            } else {
                android.util.Log.e("MainActivity", "Failed to get presigned URL for chunk ${chunk.chunkNumber}")
                false
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error uploading chunk to server", e)
            false
        }
    }

    /**
     * Register receiver for chunk processing broadcasts from background workers
     */
    private fun registerChunkProcessingReceiver() {
        val filter = IntentFilter().apply {
            addAction("com.example.medicalscribe.PROCESS_CHUNKS")
            addAction("com.example.medicalscribe.RECOVER_CHUNKS")
            addAction("com.example.medicalscribe.CLEANUP_CHUNKS")
        }
        
        chunkProcessingReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: android.content.Context?, intent: Intent?) {
                when (intent?.action) {
                    "com.example.medicalscribe.PROCESS_CHUNKS" -> {
                        android.util.Log.d("MainActivity", "Processing chunks from background worker")
                        startOrderedUpload()
                    }
                    "com.example.medicalscribe.RECOVER_CHUNKS" -> {
                        android.util.Log.d("MainActivity", "Recovering chunks from background worker")
                        val stats = robustChunkManager.getStatistics()
                        val pendingCount = stats["pendingChunks"] as? Int ?: 0
                        android.util.Log.d("MainActivity", "Found $pendingCount pending chunks")
                        
                        // Notify Flutter about recovery
                        runOnUiThread {
                            eventSink?.success(mapOf(
                                "type" to "chunks_recovered",
                                "recoveredCount" to pendingCount
                            ))
                        }
                    }
                    "com.example.medicalscribe.CLEANUP_CHUNKS" -> {
                        android.util.Log.d("MainActivity", "Cleaning up old chunks from background worker")
                        // Cleanup is now handled automatically by robust chunk manager
                        android.util.Log.d("MainActivity", "Cleanup handled by robust chunk manager")
                    }
                }
            }
        }
        
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            registerReceiver(chunkProcessingReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(chunkProcessingReceiver, filter)
        }
    }
    
    /**
     * Retry failed chunks
     */
    private fun retryFailedChunks() {
        try {
            android.util.Log.d("MainActivity", "Retrying failed chunks")
            
            // Get robust queue stats to find failed chunks
            val stats = robustChunkManager.getStatistics()
            val failedCount = stats["failedChunks"] as? Int ?: 0
            
            if (failedCount > 0) {
                // Schedule chunk recovery which will handle failed chunks
                backgroundTaskManager.scheduleChunkRecoveryWork()
                android.util.Log.d("MainActivity", "Scheduled recovery for $failedCount failed chunks")
            } else {
                android.util.Log.d("MainActivity", "No failed chunks to retry")
            }
            
            // Also try to resume normal processing
            startOrderedUpload()
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error retrying failed chunks", e)
        }
    }

    /**
     * Get audio files for a specific session
     */
    private fun getSessionAudioFiles(sessionId: String): List<String> {
        return try {
            val audioFiles = mutableListOf<String>()
            val chunksDir = File(filesDir, "audio_chunks/$sessionId")
            
            if (chunksDir.exists() && chunksDir.isDirectory) {
                val files = chunksDir.listFiles { file ->
                    file.isFile && file.name.endsWith(".wav") && file.name.startsWith("chunk_")
                }
                
                files?.forEach { file ->
                    if (file.exists() && file.length() > 0) {
                        audioFiles.add(file.absolutePath)
                    }
                }
                
                // Sort files by chunk number for proper order
                audioFiles.sortBy { filePath ->
                    val fileName = File(filePath).name
                    val chunkNumber = fileName.removePrefix("chunk_").removeSuffix(".wav").toIntOrNull() ?: 0
                    chunkNumber
                }
            }
            
            android.util.Log.d("MainActivity", "Found ${audioFiles.size} audio files for session $sessionId")
            audioFiles
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error getting session audio files", e)
            emptyList()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        
        // Shutdown robust components
        try {
            networkMonitor.stopMonitoring()
            uploadExecutor.shutdown()
            
            // Stop background service but keep WorkManager tasks running
            backgroundTaskManager.stopChunkUploadService()
            
            // Don't cancel WorkManager tasks - they should continue in background
            android.util.Log.d("MainActivity", "MainActivity destroyed, background tasks continue")
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error during cleanup", e)
        }
        
        // Unregister receivers
        try {
            chunkProcessingReceiver?.let { unregisterReceiver(it) }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error unregistering chunk processing receiver", e)
        }
        
        try {
            recordingActionReceiver?.let { unregisterReceiver(it) }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error unregistering recording action receiver", e)
        }
        
        try {
            networkReceiver?.let { unregisterReceiver(it) }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error unregistering network receiver", e)
        }
        
        uploadExecutor.shutdown()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        
        when (requestCode) {
            PERMISSION_REQUEST_CODE -> {
                if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    // Permission granted, notify Flutter
                    eventSink?.success(mapOf(
                        "type" to "permission_granted",
                        "permission" to "RECORD_AUDIO"
                    ))
                } else {
                    // Permission denied, notify Flutter
                    eventSink?.error(
                        "PERMISSION_DENIED", 
                        "Microphone permission denied by user", 
                        null
                    )
                }
            }
        }
    }
}