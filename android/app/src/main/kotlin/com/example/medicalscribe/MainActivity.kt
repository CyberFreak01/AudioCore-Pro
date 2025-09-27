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
    private val prefsName = "record_prefs"
    private val keyLastActiveSession = "last_active_session"
    private val keyLastActiveAt = "last_active_at"
    private val notifChannelId = "record_control"
    private val notifId = 987654
    
    // Chunk queue management
    private val chunkQueue = ConcurrentLinkedQueue<ChunkItem>()
    private val nextExpectedChunk = AtomicInteger(0)
    private val isUploading = AtomicBoolean(false)
    private val uploadExecutor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    private val maxRetries = 3
    private val retryDelays = longArrayOf(1000, 2000, 5000) // 1s, 2s, 5s
    private var serverBaseUrl = "https://scribe-server-production-f150.up.railway.app"
    
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
                    
                    hapticIfAllowed()
                    if (startAudioRecording(sessionId, sampleRate)) {
                        result.success("Recording started")
                    } else {
                        result.error("RECORDING_ERROR", "Failed to start recording", null)
                    }
                }
                "stopRecording" -> {
                    hapticIfAllowed()
                    if (stopAudioRecording()) {
                        result.success("Recording stopped")
                    } else {
                        result.error("RECORDING_ERROR", "Failed to stop recording", null)
                    }
                }
                "pauseRecording" -> {
                    hapticIfAllowed()
                    if (pauseAudioRecording()) {
                        result.success("Recording paused")
                    } else {
                        result.error("RECORDING_ERROR", "Failed to pause recording", null)
                    }
                }
                "resumeRecording" -> {
                    hapticIfAllowed()
                    if (resumeAudioRecording()) {
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
                    val status = mapOf(
                        "queueSize" to chunkQueue.size,
                        "nextExpectedChunk" to nextExpectedChunk.get(),
                        "isUploading" to isUploading.get()
                    )
                    result.success(status)
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

        registerAudioRouteReceivers()
        registerNetworkAvailableReceiver()
        registerRecordingActionReceiver()
        ensureControlNotificationChannel()

        // On Android 13+, request notification permission once at startup to show controls
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            try {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 2002)
            } catch (_: Exception) {}
        }
        
        // Recover any pending chunks from previous session
        recoverChunkQueue()
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
            // Only reset chunk counter when starting a completely new session
            // Keep incrementing for pause/resume within same session
            chunkBuffer.clear()

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

    private fun saveAndStreamChunk(audioData: ByteArray) {
        try {
            // Create chunk file
            val chunksDir = File(filesDir, "audio_chunks/${sessionId}")
            chunksDir.mkdirs()
            
            val chunkFile = File(chunksDir, "chunk_${chunkCounter}.wav")
            
            // Write WAV header and audio data
            writeWavFile(chunkFile, audioData, 44100)

            // Add to ordered queue instead of immediate upload
            val chunkItem = ChunkItem(
                sessionId = sessionId!!,
                chunkNumber = chunkCounter,
                filePath = chunkFile.absolutePath
            )
            chunkQueue.offer(chunkItem)
            
            // Start upload process if not already running
            startOrderedUpload()
            
            chunkCounter++
        } catch (e: Exception) {
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
            val stopIntent = Intent(this, NotificationActionReceiver::class.java).apply { 
            action = "ACTION_STOP"
            // Add these flags for better reliability
            addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)
        }
            val pauseIntent = Intent(this, NotificationActionReceiver::class.java).apply { 
                action = if (isRecording) "ACTION_PAUSE" else "ACTION_RESUME"
                addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)
            }

        val stopPi = PendingIntent.getBroadcast(
            this, 
            100, 
            stopIntent, 
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
            val pausePi = PendingIntent.getBroadcast(
            this, 
            101, 
            pauseIntent, 
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(this, notifChannelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Recording in progress")
                .setContentText(if (isRecording) "Tap to pause or stop" else "Paused: tap to resume or stop")
            .setOngoing(true)
            .setSilent(true)
                .addAction(NotificationCompat.Action(0, if (isRecording) "Pause" else "Resume", pausePi))
            .addAction(NotificationCompat.Action(0, "Stop", stopPi))
            .setAutoCancel(false) // Prevent accidental dismissal

        val nm = getSystemService(NotificationManager::class.java)
        nm?.notify(notifId, builder.build())
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
        if (isUploading.compareAndSet(false, true)) {
            uploadExecutor.execute {
                processChunkQueue()
            }
        }
    }

    private fun processChunkQueue() {
        try {
            var consecutiveFailures = 0
            val maxConsecutiveFailures = 3
            
            while (true) {
                val expectedChunk = nextExpectedChunk.get()
                val chunkToProcess = findChunkByNumber(expectedChunk)
                
                if (chunkToProcess == null) {
                    // Check if we have any chunks in queue at all
                    if (chunkQueue.isEmpty()) {
                        android.util.Log.d("MainActivity", "No more chunks in queue, processing complete")
                        break
                    }
                    
                    // Check if we have chunks with higher numbers (gap detection)
                    val nextAvailableChunk = chunkQueue.minByOrNull { it.chunkNumber }
                    if (nextAvailableChunk != null && nextAvailableChunk.chunkNumber > expectedChunk) {
                        android.util.Log.w("MainActivity", "Gap detected: expected chunk $expectedChunk, but next available is ${nextAvailableChunk.chunkNumber}")
                        // Skip to the next available chunk
                        nextExpectedChunk.set(nextAvailableChunk.chunkNumber)
                        continue
                    }
                    
                    // No chunk available for this number yet, wait a bit
                    Thread.sleep(100)
                    continue
                }
                
                val success = uploadChunkToServer(chunkToProcess)
                
                if (success) {
                    consecutiveFailures = 0 // Reset failure counter
                    // Move to next expected chunk
                    nextExpectedChunk.incrementAndGet()
                    
                    // Notify Flutter of successful upload
                    runOnUiThread {
                        eventSink?.success(mapOf(
                            "type" to "chunk_uploaded",
                            "sessionId" to chunkToProcess.sessionId,
                            "chunkNumber" to chunkToProcess.chunkNumber
                        ))
                    }
                } else {
                    consecutiveFailures++
                    android.util.Log.w("MainActivity", "Upload failed for chunk ${chunkToProcess.chunkNumber}, consecutive failures: $consecutiveFailures")
                    
                    if (consecutiveFailures >= maxConsecutiveFailures) {
                        android.util.Log.e("MainActivity", "Too many consecutive failures ($consecutiveFailures), stopping processing")
                        break
                    }
                    
                    // Handle retry logic
                    handleChunkRetry(chunkToProcess)
                    break // Exit to allow retry scheduling
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error in chunk queue processing", e)
        } finally {
            isUploading.set(false)
        }
    }

    private fun findChunkByNumber(chunkNumber: Int): ChunkItem? {
        return chunkQueue.firstOrNull { it.chunkNumber == chunkNumber }
    }

    private fun uploadChunkToServer(chunk: ChunkItem): Boolean {
        return try {
            val file = File(chunk.filePath)
            if (!file.exists()) {
                android.util.Log.w("MainActivity", "Chunk file not found: ${chunk.filePath}")
                return false
            }
            
            // Step 1: Get presigned URL from server
            val presignedUrl = getPresignedUrl(chunk.sessionId, chunk.chunkNumber)
            if (presignedUrl == null) {
                android.util.Log.w("MainActivity", "Failed to get presigned URL for chunk ${chunk.chunkNumber}")
                return false
            }
            
            // Step 2: Upload chunk to server
            val uploadSuccess = uploadChunkFile(presignedUrl, file)
            if (!uploadSuccess) {
                android.util.Log.w("MainActivity", "Failed to upload chunk file ${chunk.chunkNumber}")
                return false
            }
            
            // Step 3: Notify server of successful upload
            val notifySuccess = notifyChunkUploaded(chunk.sessionId, chunk.chunkNumber)
            if (!notifySuccess) {
                android.util.Log.w("MainActivity", "Failed to notify server of chunk ${chunk.chunkNumber}")
                return false
            }
            
            // Step 4: Clean up chunk file and remove from queue on success
            cleanupChunkOnSuccess(chunk)
            
            android.util.Log.d("MainActivity", "Successfully uploaded and cleaned up chunk ${chunk.chunkNumber}")
            true
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Upload failed for chunk ${chunk.chunkNumber}", e)
            false
        }
    }
    
    private fun cleanupChunkOnSuccess(chunk: ChunkItem) {
        try {
            // Remove chunk from queue
            chunkQueue.remove(chunk)
            
            // Delete chunk file from storage
            val file = File(chunk.filePath)
            if (file.exists()) {
                val deleted = file.delete()
                android.util.Log.d("MainActivity", "Deleted chunk file ${chunk.filePath}: $deleted")
            }
            
            // Update pending chunks file
            markChunkAsUploaded(chunk.sessionId, chunk.chunkNumber)
            
            android.util.Log.d("MainActivity", "Cleaned up chunk ${chunk.chunkNumber} from queue and storage")
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error cleaning up chunk ${chunk.chunkNumber}", e)
        }
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
        if (chunk.retryCount >= maxRetries) {
            android.util.Log.e("MainActivity", "Max retries exceeded for chunk ${chunk.chunkNumber}, removing from queue")
            // Remove from queue after max retries
            chunkQueue.remove(chunk)
            // Try to continue with next chunk
            uploadExecutor.schedule({
                if (isUploading.compareAndSet(false, true)) {
                    processChunkQueue()
                }
            }, 1000, TimeUnit.MILLISECONDS)
            return
        }
        
        val retryDelay = if (chunk.retryCount < retryDelays.size) {
            retryDelays[chunk.retryCount]
        } else {
            retryDelays.last()
        }
        
        val retryChunk = chunk.copy(retryCount = chunk.retryCount + 1)
        chunkQueue.remove(chunk)
        chunkQueue.offer(retryChunk)
        
        android.util.Log.d("MainActivity", "Scheduling retry ${chunk.retryCount + 1} for chunk ${chunk.chunkNumber} in ${retryDelay}ms")
        
        uploadExecutor.schedule({
            if (isUploading.compareAndSet(false, true)) {
                processChunkQueue()
            }
        }, retryDelay, TimeUnit.MILLISECONDS)
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
                // Resume upload processing when network is available with delay
                android.util.Log.d("MainActivity", "Network available, resuming upload processing")
                uploadExecutor.schedule({
                    startOrderedUpload()
                }, 1000, TimeUnit.MILLISECONDS)
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
    val recordingActionReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: Intent?) {
            val action = intent?.getStringExtra("action")
            when (action) {
                "stop" -> {
                    hapticIfAllowed()
                    stopAudioRecording()
                }
                "pause" -> {
                    hapticIfAllowed()
                    pauseAudioRecording()
                }
                "resume" -> {
                    hapticIfAllowed()
                    resumeAudioRecording()
                }
            }
        }
    }
    
    if (android.os.Build.VERSION.SDK_INT >= 33) {
        registerReceiver(recordingActionReceiver, filter, RECEIVER_NOT_EXPORTED)
    } else {
        @Suppress("DEPRECATION")
        registerReceiver(recordingActionReceiver, filter)
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
            val dir = File(filesDir, "audio_chunks/$sid")
            val file = File(dir, "pending.txt")
            if (!file.exists()) return
            val lines = file.readLines().filterNot { it.trim() == "chunk_$number" }
            file.writeText(lines.joinToString("\n", postfix = if (lines.isNotEmpty()) "\n" else ""))
        } catch (_: Exception) {}
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

    override fun onDestroy() {
        super.onDestroy()
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