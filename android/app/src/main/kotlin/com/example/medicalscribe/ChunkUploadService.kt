package com.example.medicalscribe

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.content.Context

/**
 * Background service for continuous chunk upload processing
 * 
 * Features:
 * - Runs continuously while app is open
 * - Survives app backgrounding
 * - Processes chunks every 10 seconds
 * - Network-aware processing
 * - Battery optimization friendly
 * - Automatic recovery on service restart
 */
class ChunkUploadService : Service() {
    
    companion object {
        private const val TAG = "ChunkUploadService"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "chunk_upload_service"
        private const val PROCESSING_INTERVAL_SECONDS = 10L
        private const val IDLE_CHECK_INTERVAL_SECONDS = 30L
    }
    
    private lateinit var robustChunkManager: RobustChunkManager
    private lateinit var networkMonitor: NetworkMonitor
    private val uploadExecutor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    private val isProcessing = AtomicBoolean(false)
    private val isServiceRunning = AtomicBoolean(false)
    private var wakeLock: PowerManager.WakeLock? = null
    
    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "ChunkUploadService created")
        
        createNotificationChannel()
        initializeComponents()
        startForegroundService()
        startContinuousProcessing()
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "ChunkUploadService started")
        
        when (intent?.action) {
            "STOP_SERVICE" -> {
                stopSelf()
                return START_NOT_STICKY
            }
            "FORCE_PROCESS" -> {
                forceProcessChunks()
            }
        }
        
        if (!isServiceRunning.get()) {
            startContinuousProcessing()
        }
        
        // Restart service if killed by system
        return START_STICKY
    }
    
    override fun onBind(intent: Intent?): IBinder? = null
    
    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "ChunkUploadService destroyed")
        
        isServiceRunning.set(false)
        stopContinuousProcessing()
        releaseWakeLock()
    }
    
    private fun initializeComponents() {
        try {
            robustChunkManager = RobustChunkManager(this)
            networkMonitor = NetworkMonitor(this)
            
            // Initialize chunk manager and recover any pending chunks
            val recoveredCount = robustChunkManager.initialize()
            Log.d(TAG, "Service initialized, recovered $recoveredCount chunks")
            
            // Start network monitoring
            networkMonitor.startMonitoring { networkState ->
                Log.d(TAG, "Network state changed in service: ${networkState.isAvailable}")
                if (networkState.isAvailable) {
                    // Trigger immediate processing when network becomes available
                    forceProcessChunks()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize service components", e)
        }
    }
    
    private fun startForegroundService() {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Medical Transcription")
            .setContentText("Processing audio chunks...")
            .setSmallIcon(android.R.drawable.ic_menu_upload)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
        
        startForeground(NOTIFICATION_ID, notification)
    }
    
    private fun startContinuousProcessing() {
        if (isServiceRunning.compareAndSet(false, true)) {
            Log.d(TAG, "Starting continuous chunk processing")
            
            // Immediate processing on start
            uploadExecutor.execute {
                processChunkQueue()
            }
            
            // Regular processing every 10 seconds
            uploadExecutor.scheduleWithFixedDelay({
                processChunkQueue()
            }, PROCESSING_INTERVAL_SECONDS, PROCESSING_INTERVAL_SECONDS, TimeUnit.SECONDS)
            
            // Idle check every 30 seconds (stops service if no chunks for extended period)
            uploadExecutor.scheduleWithFixedDelay({
                checkIdleState()
            }, IDLE_CHECK_INTERVAL_SECONDS, IDLE_CHECK_INTERVAL_SECONDS, TimeUnit.SECONDS)
        }
    }
    
    private fun processChunkQueue() {
        if (!isServiceRunning.get() || isProcessing.get()) {
            return
        }
        
        if (!::robustChunkManager.isInitialized || !::networkMonitor.isInitialized) {
            Log.w(TAG, "Components not initialized, skipping processing")
            return
        }
        
        if (!networkMonitor.isUploadRecommended()) {
            Log.d(TAG, "Network not suitable for upload, skipping processing")
            return
        }
        
        if (!isProcessing.compareAndSet(false, true)) {
            Log.d(TAG, "Already processing, skipping")
            return
        }
        
        try {
            acquireWakeLock()
            
            val stats = robustChunkManager.getStatistics()
            val pendingCount = stats["pendingChunks"] as? Int ?: 0
            
            if (pendingCount == 0) {
                Log.d(TAG, "No pending chunks to process")
                return
            }
            
            Log.d(TAG, "Processing $pendingCount pending chunks")
            updateNotification("Processing $pendingCount chunks...")
            
            val batchSize = networkMonitor.getOptimalBatchSize()
            val chunks = robustChunkManager.getNextChunkBatch(batchSize)
            
            if (chunks.isNotEmpty()) {
                Log.d(TAG, "Processing batch of ${chunks.size} chunks")
                
                var successCount = 0
                var failureCount = 0
                
                for (chunk in chunks) {
                    try {
                        // Mark as uploading
                        robustChunkManager.markChunkUploading(chunk.id)
                        
                        // Upload chunk
                        val success = uploadChunkToServer(chunk)
                        
                        if (success) {
                            // Mark as completed and cleanup
                            robustChunkManager.markChunkCompleted(chunk.id, chunk.filePath)
                            successCount++
                            Log.d(TAG, "Chunk ${chunk.chunkNumber} uploaded successfully")
                        } else {
                            // Handle failure with retry logic
                            val newRetryCount = chunk.retryCount + 1
                            robustChunkManager.markChunkFailed(chunk.id, newRetryCount)
                            failureCount++
                            Log.w(TAG, "Chunk ${chunk.chunkNumber} upload failed, retry count: $newRetryCount")
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error processing chunk ${chunk.chunkNumber}", e)
                        failureCount++
                    }
                }
                
                Log.d(TAG, "Batch processing complete: $successCount successful, $failureCount failed")
                updateNotification("Processed batch: $successCount uploaded, $failureCount failed")
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "Error in chunk processing", e)
        } finally {
            isProcessing.set(false)
            releaseWakeLock()
        }
    }
    
    private fun uploadChunkToServer(chunk: RobustChunkManager.ChunkItem): Boolean {
        return try {
            val file = java.io.File(chunk.filePath)
            if (!file.exists()) {
                Log.e(TAG, "Chunk file not found: ${chunk.filePath}")
                return false
            }
            
            // Step 1: Get presigned URL from server
            val presignedUrl = getPresignedUrl(chunk.sessionId, chunk.chunkNumber)
            if (presignedUrl == null) {
                Log.w(TAG, "Failed to get presigned URL for chunk ${chunk.chunkNumber}")
                return false
            }
            
            // Step 2: Upload chunk to server
            val uploadSuccess = uploadChunkFile(presignedUrl, file)
            if (!uploadSuccess) {
                Log.w(TAG, "Failed to upload chunk file ${chunk.chunkNumber}")
                return false
            }
            
            // Step 3: Notify server of successful upload
            val notifySuccess = notifyChunkUploaded(chunk.sessionId, chunk.chunkNumber)
            if (!notifySuccess) {
                Log.w(TAG, "Failed to notify server of chunk ${chunk.chunkNumber}")
                return false
            }
            
            Log.d(TAG, "Successfully uploaded chunk ${chunk.chunkNumber}")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error uploading chunk to server", e)
            false
        }
    }
    
    private fun getPresignedUrl(sessionId: String, chunkNumber: Int): String? {
        return try {
            val serverBaseUrl = "https://scribe-server-production-f150.up.railway.app"
            val url = java.net.URL("$serverBaseUrl/get-presigned-url")
            val connection = url.openConnection() as java.net.HttpURLConnection
            connection.requestMethod = "POST"
            connection.setRequestProperty("Content-Type", "application/json")
            connection.doOutput = true
            connection.connectTimeout = 10000
            connection.readTimeout = 15000
            
            val jsonInput = """{"sessionId":"$sessionId","chunkNumber":$chunkNumber}"""
            val outputStream = connection.outputStream
            outputStream.write(jsonInput.toByteArray())
            outputStream.close()
            
            val responseCode = connection.responseCode
            if (responseCode == 200) {
                val response = connection.inputStream.bufferedReader().use { it.readText() }
                val presignedUrl = response.substringAfter("\"presignedUrl\":\"").substringBefore("\"")
                Log.d(TAG, "Got presigned URL for chunk $chunkNumber")
                presignedUrl
            } else {
                Log.e(TAG, "Failed to get presigned URL: $responseCode")
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error getting presigned URL", e)
            null
        }
    }
    
    private fun uploadChunkFile(presignedUrl: String, file: java.io.File): Boolean {
        return try {
            val url = java.net.URL(presignedUrl)
            val connection = url.openConnection() as java.net.HttpURLConnection
            connection.requestMethod = "PUT"
            connection.setRequestProperty("Content-Type", "audio/wav")
            connection.doOutput = true
            connection.connectTimeout = 30000
            connection.readTimeout = 60000
            
            java.io.FileInputStream(file).use { fileInput ->
                connection.outputStream.use { output ->
                    fileInput.copyTo(output)
                }
            }
            
            val responseCode = connection.responseCode
            val success = responseCode in 200..299
            Log.d(TAG, "Upload response: $responseCode")
            success
        } catch (e: Exception) {
            Log.e(TAG, "Error uploading file", e)
            false
        }
    }
    
    private fun notifyChunkUploaded(sessionId: String, chunkNumber: Int): Boolean {
        return try {
            val serverBaseUrl = "https://scribe-server-production-f150.up.railway.app"
            val url = java.net.URL("$serverBaseUrl/chunk-uploaded")
            val connection = url.openConnection() as java.net.HttpURLConnection
            connection.requestMethod = "POST"
            connection.setRequestProperty("Content-Type", "application/json")
            connection.doOutput = true
            connection.connectTimeout = 10000
            connection.readTimeout = 15000
            
            val jsonInput = """{"sessionId":"$sessionId","chunkNumber":$chunkNumber}"""
            val outputStream = connection.outputStream
            outputStream.write(jsonInput.toByteArray())
            outputStream.close()
            
            val responseCode = connection.responseCode
            val success = responseCode in 200..299
            Log.d(TAG, "Notify response: $responseCode")
            success
        } catch (e: Exception) {
            Log.e(TAG, "Error notifying server", e)
            false
        }
    }
    
    private fun forceProcessChunks() {
        Log.d(TAG, "Force processing chunks")
        uploadExecutor.execute {
            processChunkQueue()
        }
    }
    
    private fun checkIdleState() {
        try {
            val stats = robustChunkManager.getStatistics()
            val pendingCount = stats["pendingChunks"] as? Int ?: 0
            val uploadingCount = stats["uploadingChunks"] as? Int ?: 0
            
            if (pendingCount == 0 && uploadingCount == 0) {
                Log.d(TAG, "No chunks to process, service can idle")
                updateNotification("Waiting for chunks...")
            } else {
                Log.d(TAG, "Chunks still pending: $pendingCount pending, $uploadingCount uploading")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error checking idle state", e)
        }
    }
    
    private fun stopContinuousProcessing() {
        isServiceRunning.set(false)
        try {
            networkMonitor.stopMonitoring()
            uploadExecutor.shutdown()
            if (!uploadExecutor.awaitTermination(5, TimeUnit.SECONDS)) {
                uploadExecutor.shutdownNow()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping processing", e)
        }
    }
    
    private fun acquireWakeLock() {
        try {
            if (wakeLock == null) {
                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "MedicalScribe:ChunkUpload"
                )
            }
            wakeLock?.acquire(10 * 60 * 1000L) // 10 minutes max
        } catch (e: Exception) {
            Log.e(TAG, "Error acquiring wake lock", e)
        }
    }
    
    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing wake lock", e)
        }
    }
    
    private fun updateNotification(text: String) {
        try {
            val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Medical Transcription")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_menu_upload)
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .build()
            
            val notificationManager = NotificationManagerCompat.from(this)
            notificationManager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.e(TAG, "Error updating notification", e)
        }
    }
    
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Chunk Upload Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Background service for uploading audio chunks"
                setShowBadge(false)
            }
            
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }
}
