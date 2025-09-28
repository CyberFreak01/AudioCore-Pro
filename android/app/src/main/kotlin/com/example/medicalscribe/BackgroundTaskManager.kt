package com.example.medicalscribe
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.work.*
import java.util.concurrent.TimeUnit

/**
 * Background task manager for handling chunk uploads and recovery tasks
 */
class BackgroundTaskManager(private val context: Context) {
    
    companion object {
        private const val TAG = "BackgroundTaskManager"
        private const val CHUNK_UPLOAD_WORK_NAME = "chunk_upload_work"
        private const val CHUNK_RECOVERY_WORK_NAME = "chunk_recovery_work"
        private const val CLEANUP_WORK_NAME = "chunk_cleanup_work"
    }
    
    private val workManager = WorkManager.getInstance(context)
    
    /**
     * Schedule periodic chunk upload work
     */
    fun scheduleChunkUploadWork() {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .setRequiresBatteryNotLow(true)
            .build()
        
        val uploadWork = PeriodicWorkRequestBuilder<ChunkUploadWorker>(15, TimeUnit.MINUTES)
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
            .build()
        
        workManager.enqueueUniquePeriodicWork(
            CHUNK_UPLOAD_WORK_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            uploadWork
        )
        
        Log.d(TAG, "Scheduled periodic chunk upload work")
    }
    
    /**
     * Schedule chunk recovery work (runs immediately)
     */
    fun scheduleChunkRecoveryWork() {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .setRequiresBatteryNotLow(true)
            .build()
            
        val recoveryWork = OneTimeWorkRequestBuilder<ChunkRecoveryWorker>()
            .setConstraints(constraints)
            .setBackoffCriteria(
                BackoffPolicy.EXPONENTIAL,
                WorkRequest.MIN_BACKOFF_MILLIS,
                TimeUnit.MILLISECONDS
            )
            .build()
        
        workManager.enqueueUniqueWork(
            "chunk_recovery",
            ExistingWorkPolicy.REPLACE,
            recoveryWork
        )
        
        Log.d(TAG, "Scheduled chunk recovery work")
    }
    
    /**
     * Schedule continuous chunk upload work (runs every 15 minutes)
     */
    fun scheduleContinuousUploadWork() {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .setRequiresBatteryNotLow(true)
            .build()
            
        val uploadWork = PeriodicWorkRequestBuilder<ChunkUploadWorker>(
            15, TimeUnit.MINUTES,
            5, TimeUnit.MINUTES // Flex interval
        )
            .setConstraints(constraints)
            .setBackoffCriteria(
                BackoffPolicy.EXPONENTIAL,
                WorkRequest.MIN_BACKOFF_MILLIS,
                TimeUnit.MILLISECONDS
            )
            .build()
        
        workManager.enqueueUniquePeriodicWork(
            "continuous_chunk_upload",
            ExistingPeriodicWorkPolicy.KEEP,
            uploadWork
        )
        
        Log.d(TAG, "Scheduled continuous chunk upload work")
    }
    
    /**
     * Start foreground chunk upload service
     */
    fun startChunkUploadService() {
        try {
            val serviceIntent = Intent(context, ChunkUploadService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
            Log.d(TAG, "Started chunk upload service")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start chunk upload service", e)
        }
    }
    
    /**
     * Stop chunk upload service
     */
    fun stopChunkUploadService() {
        try {
            val serviceIntent = Intent(context, ChunkUploadService::class.java)
            context.stopService(serviceIntent)
            Log.d(TAG, "Stopped chunk upload service")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop chunk upload service", e)
        }
    }
    
    /**
     * Schedule periodic cleanup work
     */
    fun scheduleCleanupWork() {
        val cleanupWork = PeriodicWorkRequestBuilder<ChunkCleanupWorker>(1, TimeUnit.DAYS)
            .setInitialDelay(1, TimeUnit.HOURS)
            .build()
        
        workManager.enqueueUniquePeriodicWork(
            CLEANUP_WORK_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            cleanupWork
        )
        
        Log.d(TAG, "Scheduled periodic cleanup work")
    }
    
    /**
     * Cancel all background work
     */
    fun cancelAllWork() {
        workManager.cancelUniqueWork(CHUNK_UPLOAD_WORK_NAME)
        workManager.cancelUniqueWork(CHUNK_RECOVERY_WORK_NAME)
        workManager.cancelUniqueWork(CLEANUP_WORK_NAME)
        Log.d(TAG, "Cancelled all background work")
    }
    
    /**
     * Get work info for debugging
     */
    fun getWorkInfo(): Map<String, String> {
        return try {
            val uploadInfo = workManager.getWorkInfosForUniqueWork(CHUNK_UPLOAD_WORK_NAME).get()
            val recoveryInfo = workManager.getWorkInfosForUniqueWork(CHUNK_RECOVERY_WORK_NAME).get()
            val cleanupInfo = workManager.getWorkInfosForUniqueWork(CLEANUP_WORK_NAME).get()
            
            mapOf(
                "upload_work_state" to (uploadInfo.firstOrNull()?.state?.name ?: "NONE"),
                "recovery_work_state" to (recoveryInfo.firstOrNull()?.state?.name ?: "NONE"),
                "cleanup_work_state" to (cleanupInfo.firstOrNull()?.state?.name ?: "NONE")
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error getting work info", e)
            mapOf("error" to e.message.toString())
        }
    }
}

/**
 * Worker for recovering chunks on app restart
 */
class ChunkRecoveryWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    
    companion object {
        private const val TAG = "ChunkRecoveryWorker"
    }
    
    override fun doWork(): Result {
        return try {
            Log.d(TAG, "Starting chunk recovery work")
            
            // Send broadcast to MainActivity to recover chunks
            val intent = Intent("com.example.medicalscribe.RECOVER_CHUNKS")
            intent.putExtra("source", "recovery_worker")
            applicationContext.sendBroadcast(intent)
            
            Log.d(TAG, "Chunk recovery work completed")
            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "Chunk recovery work failed", e)
            Result.failure()
        }
    }
}

/**
 * Worker for cleaning up old chunks
 */
class ChunkCleanupWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    
    companion object {
        private const val TAG = "ChunkCleanupWorker"
    }
    
    override fun doWork(): Result {
        return try {
            Log.d(TAG, "Starting chunk cleanup work")
            
            // Send broadcast to MainActivity to cleanup chunks
            val intent = Intent("com.example.medicalscribe.CLEANUP_CHUNKS")
            intent.putExtra("source", "cleanup_worker")
            applicationContext.sendBroadcast(intent)
            
            Log.d(TAG, "Chunk cleanup work completed")
            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "Chunk cleanup work failed", e)
            Result.failure()
        }
    }
}
