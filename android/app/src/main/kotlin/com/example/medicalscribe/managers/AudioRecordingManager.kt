package com.example.medicalscribe.managers

import android.content.Context
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import com.example.medicalscribe.constants.AudioConstants
import com.example.medicalscribe.utils.AudioUtils
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Manages audio recording operations with proper lifecycle and error handling
 */
class AudioRecordingManager(private val context: Context) {
    
    companion object {
        private const val TAG = "AudioRecordingManager"
    }
    
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    private val isRecording = AtomicBoolean(false)
    private val isPaused = AtomicBoolean(false)
    private val chunkCounter = AtomicInteger(0)
    
    private var currentSessionId: String? = null
    private var gainFactor: Float = AudioConstants.DEFAULT_GAIN
    private var sampleRate: Int = AudioConstants.DEFAULT_SAMPLE_RATE
    
    // Callbacks
    private var onChunkReady: ((sessionId: String, chunkNumber: Int, filePath: String, checksum: String) -> Unit)? = null
    private var onAudioLevel: ((rmsDb: Double, peakLevel: Int) -> Unit)? = null
    private var onError: ((error: String) -> Unit)? = null
    
    /**
     * Set callback for when audio chunks are ready
     */
    fun setOnChunkReady(callback: (sessionId: String, chunkNumber: Int, filePath: String, checksum: String) -> Unit) {
        onChunkReady = callback
    }
    
    /**
     * Set callback for audio level updates
     */
    fun setOnAudioLevel(callback: (rmsDb: Double, peakLevel: Int) -> Unit) {
        onAudioLevel = callback
    }
    
    /**
     * Set callback for errors
     */
    fun setOnError(callback: (error: String) -> Unit) {
        onError = callback
    }
    
    /**
     * Start audio recording
     */
    fun startRecording(sessionId: String, sampleRate: Int = AudioConstants.DEFAULT_SAMPLE_RATE): Boolean {
        if (isRecording.get()) {
            Log.w(TAG, "Recording already in progress")
            return false
        }
        
        try {
            this.currentSessionId = sessionId
            this.sampleRate = sampleRate
            
            // Create audio chunks directory
            val audioDir = File(context.filesDir, "${AudioConstants.AUDIO_CHUNKS_DIR}/$sessionId")
            if (!audioDir.exists()) {
                audioDir.mkdirs()
            }
            
            // Get optimal audio configuration
            val audioConfig = AudioUtils.getOptimalAudioConfig()
            val bufferSize = AudioUtils.calculateBufferSize(audioConfig.sampleRate, audioConfig.channelConfig, audioConfig.audioFormat)
            
            // Initialize AudioRecord
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                audioConfig.sampleRate,
                audioConfig.channelConfig,
                audioConfig.audioFormat,
                bufferSize
            )
            
            if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
                onError?.invoke("Failed to initialize AudioRecord")
                return false
            }
            
            // Start recording
            audioRecord?.startRecording()
            isRecording.set(true)
            isPaused.set(false)
            chunkCounter.set(0)
            
            // Start recording thread
            startRecordingThread(sessionId, bufferSize)
            
            Log.d(TAG, "Started recording for session: $sessionId")
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "Error starting recording", e)
            onError?.invoke("Failed to start recording: ${e.message}")
            cleanup()
            return false
        }
    }
    
    /**
     * Stop audio recording
     */
    fun stopRecording(): Boolean {
        if (!isRecording.get()) {
            Log.w(TAG, "No recording in progress")
            return false
        }
        
        try {
            isRecording.set(false)
            isPaused.set(false)
            
            // Wait for recording thread to finish
            recordingThread?.join(5000) // 5 second timeout
            
            cleanup()
            
            Log.d(TAG, "Stopped recording for session: $currentSessionId")
            currentSessionId = null
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping recording", e)
            onError?.invoke("Failed to stop recording: ${e.message}")
            return false
        }
    }
    
    /**
     * Pause audio recording
     */
    fun pauseRecording(): Boolean {
        if (!isRecording.get() || isPaused.get()) {
            Log.w(TAG, "Cannot pause - not recording or already paused")
            return false
        }
        
        isPaused.set(true)
        Log.d(TAG, "Paused recording for session: $currentSessionId")
        return true
    }
    
    /**
     * Resume audio recording
     */
    fun resumeRecording(): Boolean {
        if (!isRecording.get() || !isPaused.get()) {
            Log.w(TAG, "Cannot resume - not recording or not paused")
            return false
        }
        
        isPaused.set(false)
        Log.d(TAG, "Resumed recording for session: $currentSessionId")
        return true
    }
    
    /**
     * Set microphone gain
     */
    fun setGain(gain: Float) {
        gainFactor = gain.coerceIn(AudioConstants.MIN_GAIN, AudioConstants.MAX_GAIN)
        Log.d(TAG, "Set gain to: $gainFactor")
    }
    
    /**
     * Get current microphone gain
     */
    fun getGain(): Float = gainFactor
    
    /**
     * Check if currently recording
     */
    fun isRecording(): Boolean = isRecording.get()
    
    /**
     * Check if currently paused
     */
    fun isPaused(): Boolean = isPaused.get()
    
    /**
     * Get current session ID
     */
    fun getCurrentSessionId(): String? = currentSessionId
    
    /**
     * Get current chunk count
     */
    fun getChunkCount(): Int = chunkCounter.get()
    
    /**
     * Start the recording thread
     */
    private fun startRecordingThread(sessionId: String, bufferSize: Int) {
        recordingThread = Thread {
            val buffer = ShortArray(bufferSize / 2) // 16-bit samples
            val chunkBuffer = mutableListOf<Short>()
            var lastLevelUpdate = 0L
            
            while (isRecording.get()) {
                try {
                    if (isPaused.get()) {
                        Thread.sleep(100)
                        continue
                    }
                    
                    val readSize = audioRecord?.read(buffer, 0, buffer.size) ?: 0
                    if (readSize > 0) {
                        // Apply gain
                        val gainedBuffer = AudioUtils.applyGain(buffer, readSize, gainFactor)
                        
                        // Add to chunk buffer
                        for (i in 0 until readSize) {
                            chunkBuffer.add(gainedBuffer[i])
                        }
                        
                        // Update audio levels periodically
                        val now = System.currentTimeMillis()
                        if (now - lastLevelUpdate >= AudioConstants.LEVEL_UPDATE_INTERVAL_MS) {
                            val rms = AudioUtils.calculateRMS(gainedBuffer, readSize)
                            val rmsDb = AudioUtils.rmsToDecibels(rms)
                            val peakLevel = AudioUtils.findPeakLevel(gainedBuffer, readSize)
                            
                            onAudioLevel?.invoke(rmsDb, peakLevel)
                            lastLevelUpdate = now
                        }
                        
                        // Check if chunk is ready
                        if (chunkBuffer.size >= AudioConstants.CHUNK_SIZE_BYTES / 2) { // 16-bit samples
                            saveChunk(sessionId, chunkBuffer.toShortArray())
                            chunkBuffer.clear()
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error in recording thread", e)
                    onError?.invoke("Recording error: ${e.message}")
                    break
                }
            }
            
            // Save remaining data as final chunk
            if (chunkBuffer.isNotEmpty()) {
                saveChunk(sessionId, chunkBuffer.toShortArray())
            }
        }
        
        recordingThread?.start()
    }
    
    /**
     * Save audio chunk to file
     */
    private fun saveChunk(sessionId: String, audioData: ShortArray) {
        try {
            val chunkNumber = chunkCounter.getAndIncrement()
            val chunkFile = File(
                context.filesDir,
                "${AudioConstants.AUDIO_CHUNKS_DIR}/$sessionId/chunk_$chunkNumber${AudioConstants.CHUNK_FILE_EXTENSION}"
            )
            
            // Write WAV file
            writeWavFile(chunkFile, audioData, sampleRate)
            
            // Calculate checksum
            val checksum = calculateFileChecksum(chunkFile)
            
            // Notify chunk ready
            onChunkReady?.invoke(sessionId, chunkNumber, chunkFile.absolutePath, checksum)
            
            Log.d(TAG, "Saved chunk $chunkNumber for session $sessionId")
            
        } catch (e: Exception) {
            Log.e(TAG, "Error saving chunk", e)
            onError?.invoke("Failed to save audio chunk: ${e.message}")
        }
    }
    
    /**
     * Write audio data as WAV file
     */
    private fun writeWavFile(file: File, audioData: ShortArray, sampleRate: Int) {
        FileOutputStream(file).use { fos ->
            // WAV header
            val channels = 1 // Mono
            val bitsPerSample = 16
            val byteRate = sampleRate * channels * bitsPerSample / 8
            val blockAlign = channels * bitsPerSample / 8
            val dataSize = audioData.size * 2 // 16-bit samples
            val fileSize = 36 + dataSize
            
            // RIFF header
            fos.write("RIFF".toByteArray())
            fos.write(intToByteArray(fileSize))
            fos.write("WAVE".toByteArray())
            
            // Format chunk
            fos.write("fmt ".toByteArray())
            fos.write(intToByteArray(16)) // Chunk size
            fos.write(shortToByteArray(1)) // Audio format (PCM)
            fos.write(shortToByteArray(channels.toShort()))
            fos.write(intToByteArray(sampleRate))
            fos.write(intToByteArray(byteRate))
            fos.write(shortToByteArray(blockAlign.toShort()))
            fos.write(shortToByteArray(bitsPerSample.toShort()))
            
            // Data chunk
            fos.write("data".toByteArray())
            fos.write(intToByteArray(dataSize))
            
            // Audio data
            for (sample in audioData) {
                fos.write(shortToByteArray(sample))
            }
        }
    }
    
    /**
     * Calculate SHA-256 checksum of file
     */
    private fun calculateFileChecksum(file: File): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(8192)
            var bytesRead: Int
            while (input.read(buffer).also { bytesRead = it } != -1) {
                digest.update(buffer, 0, bytesRead)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
    
    /**
     * Convert int to little-endian byte array
     */
    private fun intToByteArray(value: Int): ByteArray {
        return byteArrayOf(
            (value and 0xFF).toByte(),
            ((value shr 8) and 0xFF).toByte(),
            ((value shr 16) and 0xFF).toByte(),
            ((value shr 24) and 0xFF).toByte()
        )
    }
    
    /**
     * Convert short to little-endian byte array
     */
    private fun shortToByteArray(value: Short): ByteArray {
        return byteArrayOf(
            (value.toInt() and 0xFF).toByte(),
            ((value.toInt() shr 8) and 0xFF).toByte()
        )
    }
    
    /**
     * Clean up resources
     */
    private fun cleanup() {
        try {
            audioRecord?.stop()
            audioRecord?.release()
            audioRecord = null
        } catch (e: Exception) {
            Log.e(TAG, "Error during cleanup", e)
        }
    }
}
