package com.example.medicalscribe

import android.content.Context
import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.database.Cursor
import android.util.Log
import java.io.File
import java.security.MessageDigest
import java.io.FileInputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Robust chunk manager with reliable persistence and recovery
 * 
 * Design Principles:
 * 1. Atomic operations with proper locking
 * 2. Immediate persistence on chunk creation
 * 3. Automatic recovery on app restart
 * 4. Comprehensive error handling and logging
 * 5. File integrity validation with checksums
 * 6. Background processing with WorkManager integration
 */
class RobustChunkManager(private val context: Context) {
    private val dbHelper = ChunkDatabaseHelper(context)
    private val processingLock = ReentrantLock()
    private val isInitialized = AtomicBoolean(false)
    private val isProcessing = AtomicBoolean(false)
    private val uploadExecutor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    
    companion object {
        private const val TAG = "RobustChunkManager"
        
        // Database constants
        private const val DATABASE_NAME = "robust_chunks.db"
        private const val DATABASE_VERSION = 1
        private const val TABLE_CHUNKS = "chunks"
        
        // Column names
        private const val COLUMN_ID = "id"
        private const val COLUMN_SESSION_ID = "session_id"
        private const val COLUMN_CHUNK_NUMBER = "chunk_number"
        private const val COLUMN_FILE_PATH = "file_path"
        private const val COLUMN_FILE_SIZE = "file_size"
        private const val COLUMN_CHECKSUM = "checksum"
        private const val COLUMN_RETRY_COUNT = "retry_count"
        private const val COLUMN_CREATED_AT = "created_at"
        private const val COLUMN_UPDATED_AT = "updated_at"
        private const val COLUMN_STATUS = "status"
        private const val COLUMN_PRIORITY = "priority"
        
        // Status constants
        private const val STATUS_PENDING = "pending"
        private const val STATUS_UPLOADING = "uploading"
        private const val STATUS_COMPLETED = "completed"
        private const val STATUS_FAILED = "failed"
        
        // Priority constants
        private const val PRIORITY_NORMAL = 2
        private const val PRIORITY_RECOVERY = 1
        
        // Retry constants
        private const val MAX_RETRIES = 5
    }
    
    data class ChunkItem(
        val id: Long = -1,
        val sessionId: String,
        val chunkNumber: Int,
        val filePath: String,
        val fileSize: Long = 0,
        val checksum: String = "",
        val retryCount: Int = 0,
        val createdAt: Long = System.currentTimeMillis(),
        val updatedAt: Long = System.currentTimeMillis(),
        val status: String = STATUS_PENDING,
        val priority: Int = PRIORITY_NORMAL
    )
    
    /**
     * Initialize the chunk manager and perform automatic recovery
     */
    fun initialize(): Int {
        return processingLock.withLock {
            try {
                Log.d(TAG, "Initializing robust chunk manager")
                
                // Ensure database is ready
                dbHelper.writableDatabase.close()
                
                // Perform automatic recovery
                val recoveredCount = performAutomaticRecovery()
                
                isInitialized.set(true)
                Log.d(TAG, "Chunk manager initialized successfully, recovered $recoveredCount chunks")
                
                // Start background processing
                startBackgroundProcessing()
                
                recoveredCount
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize chunk manager", e)
                0
            }
        }
    }
    
    /**
     * Add a new chunk with immediate persistence
     */
    fun addChunk(sessionId: String, chunkNumber: Int, filePath: String): Boolean {
        return processingLock.withLock {
            try {
                val file = File(filePath)
                if (!file.exists()) {
                    Log.e(TAG, "Chunk file does not exist: $filePath")
                    return false
                }
                
                val fileSize = file.length()
                val checksum = calculateChecksum(file)
                
                val chunk = ChunkItem(
                    sessionId = sessionId,
                    chunkNumber = chunkNumber,
                    filePath = filePath,
                    fileSize = fileSize,
                    checksum = checksum,
                    createdAt = System.currentTimeMillis(),
                    updatedAt = System.currentTimeMillis()
                )
                
                val success = persistChunk(chunk)
                if (success) {
                    Log.d(TAG, "Chunk $chunkNumber for session $sessionId persisted successfully")
                    
                    // Trigger immediate processing if network is available
                    scheduleImmediateProcessing()
                } else {
                    Log.e(TAG, "Failed to persist chunk $chunkNumber for session $sessionId")
                }
                
                success
            } catch (e: Exception) {
                Log.e(TAG, "Error adding chunk", e)
                false
            }
        }
    }
    
    /**
     * Persist chunk to database with atomic transaction
     */
    private fun persistChunk(chunk: ChunkItem): Boolean {
        return try {
            val db = dbHelper.writableDatabase
            db.beginTransaction()
            
            try {
                val values = ContentValues().apply {
                    put(COLUMN_SESSION_ID, chunk.sessionId)
                    put(COLUMN_CHUNK_NUMBER, chunk.chunkNumber)
                    put(COLUMN_FILE_PATH, chunk.filePath)
                    put(COLUMN_FILE_SIZE, chunk.fileSize)
                    put(COLUMN_CHECKSUM, chunk.checksum)
                    put(COLUMN_RETRY_COUNT, chunk.retryCount)
                    put(COLUMN_CREATED_AT, chunk.createdAt)
                    put(COLUMN_UPDATED_AT, chunk.updatedAt)
                    put(COLUMN_STATUS, chunk.status)
                    put(COLUMN_PRIORITY, chunk.priority)
                }
                
                val id = db.insertOrThrow(TABLE_CHUNKS, null, values)
                db.setTransactionSuccessful()
                
                Log.d(TAG, "Chunk persisted with ID: $id")
                true
            } finally {
                db.endTransaction()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to persist chunk", e)
            false
        }
    }
    
    /**
     * Perform automatic recovery on app restart
     */
    private fun performAutomaticRecovery(): Int {
        return try {
            Log.d(TAG, "Starting automatic chunk recovery")
            
            val db = dbHelper.readableDatabase
            val cursor = db.query(
                TABLE_CHUNKS,
                null,
                "$COLUMN_STATUS IN (?, ?)",
                arrayOf(STATUS_PENDING, STATUS_UPLOADING),
                null,
                null,
                "$COLUMN_PRIORITY ASC, $COLUMN_CREATED_AT ASC"
            )
            
            var recoveredCount = 0
            val validChunks = mutableListOf<ChunkItem>()
            
            cursor.use {
                while (it.moveToNext()) {
                    val chunk = cursorToChunk(it)
                    
                    // Validate file existence and integrity
                    val file = File(chunk.filePath)
                    if (file.exists() && file.length() == chunk.fileSize) {
                        val currentChecksum = calculateChecksum(file)
                        if (currentChecksum == chunk.checksum) {
                            // Mark as recovery priority
                            updateChunkPriority(chunk.id, PRIORITY_RECOVERY)
                            updateChunkStatus(chunk.id, STATUS_PENDING)
                            validChunks.add(chunk)
                            recoveredCount++
                            Log.d(TAG, "Recovered valid chunk ${chunk.chunkNumber} for session ${chunk.sessionId}")
                        } else {
                            Log.w(TAG, "Checksum mismatch for chunk ${chunk.chunkNumber}, marking as failed")
                            updateChunkStatus(chunk.id, STATUS_FAILED)
                            cleanupChunkFile(chunk.filePath)
                        }
                    } else {
                        Log.w(TAG, "File missing or size mismatch for chunk ${chunk.chunkNumber}, marking as failed")
                        updateChunkStatus(chunk.id, STATUS_FAILED)
                        cleanupChunkFile(chunk.filePath)
                    }
                }
            }
            
            Log.d(TAG, "Recovery completed: $recoveredCount valid chunks found")
            recoveredCount
        } catch (e: Exception) {
            Log.e(TAG, "Error during automatic recovery", e)
            0
        }
    }
    
    /**
     * Get next batch of chunks for processing
     */
    fun getNextChunkBatch(batchSize: Int = 3): List<ChunkItem> {
        return try {
            val db = dbHelper.readableDatabase
            val cursor = db.query(
                TABLE_CHUNKS,
                null,
                "$COLUMN_STATUS = ?",
                arrayOf(STATUS_PENDING),
                null,
                null,
                "$COLUMN_PRIORITY ASC, $COLUMN_CREATED_AT ASC",
                batchSize.toString()
            )
            
            val chunks = mutableListOf<ChunkItem>()
            cursor.use {
                while (it.moveToNext()) {
                    chunks.add(cursorToChunk(it))
                }
            }
            
            Log.d(TAG, "Retrieved ${chunks.size} chunks for processing")
            chunks
        } catch (e: Exception) {
            Log.e(TAG, "Error getting next chunk batch", e)
            emptyList()
        }
    }
    
    /**
     * Mark chunk as uploading
     */
    fun markChunkUploading(chunkId: Long): Boolean {
        return updateChunkStatus(chunkId, STATUS_UPLOADING)
    }
    
    /**
     * Mark chunk as completed and cleanup
     */
    fun markChunkCompleted(chunkId: Long, filePath: String): Boolean {
        return try {
            val success = updateChunkStatus(chunkId, STATUS_COMPLETED)
            if (success) {
                cleanupChunkFile(filePath)
                Log.d(TAG, "Chunk $chunkId marked as completed and file cleaned up")
            }
            success
        } catch (e: Exception) {
            Log.e(TAG, "Error marking chunk as completed", e)
            false
        }
    }
    
    /**
     * Handle chunk failure with retry logic
     */
    fun markChunkFailed(chunkId: Long, retryCount: Int): Boolean {
        return try {
            val db = dbHelper.writableDatabase
            val values = ContentValues().apply {
                put(COLUMN_RETRY_COUNT, retryCount)
                put(COLUMN_UPDATED_AT, System.currentTimeMillis())
                put(COLUMN_STATUS, if (retryCount >= MAX_RETRIES) STATUS_FAILED else STATUS_PENDING)
            }
            
            val rowsUpdated = db.update(
                TABLE_CHUNKS,
                values,
                "$COLUMN_ID = ?",
                arrayOf(chunkId.toString())
            )
            
            val success = rowsUpdated > 0
            if (success) {
                val status = if (retryCount >= MAX_RETRIES) "failed permanently" else "pending retry"
                Log.d(TAG, "Chunk $chunkId marked as $status (retry count: $retryCount)")
            }
            success
        } catch (e: Exception) {
            Log.e(TAG, "Error marking chunk as failed", e)
            false
        }
    }
    
    /**
     * Start background processing
     */
    private fun startBackgroundProcessing() {
        uploadExecutor.scheduleWithFixedDelay({
            if (isInitialized.get() && !isProcessing.get()) {
                processNextBatch()
            }
        }, 5, 15, TimeUnit.SECONDS)
    }
    
    /**
     * Schedule immediate processing
     */
    private fun scheduleImmediateProcessing() {
        uploadExecutor.schedule({
            processNextBatch()
        }, 1, TimeUnit.SECONDS)
    }
    
    /**
     * Process next batch of chunks
     */
    private fun processNextBatch() {
        if (!isProcessing.compareAndSet(false, true)) {
            return // Already processing
        }
        
        try {
            val chunks = getNextChunkBatch()
            if (chunks.isNotEmpty()) {
                Log.d(TAG, "Processing batch of ${chunks.size} chunks")
                // Processing will be handled by MainActivity
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error processing chunk batch", e)
        } finally {
            isProcessing.set(false)
        }
    }
    
    /**
     * Get comprehensive statistics
     */
    fun getStatistics(): Map<String, Any> {
        return try {
            val db = dbHelper.readableDatabase
            val stats = mutableMapOf<String, Any>()
            
            // Count by status
            val statusCounts = mutableMapOf<String, Int>()
            val statusCursor = db.rawQuery(
                "SELECT $COLUMN_STATUS, COUNT(*) FROM $TABLE_CHUNKS GROUP BY $COLUMN_STATUS",
                null
            )
            statusCursor.use {
                while (it.moveToNext()) {
                    statusCounts[it.getString(0)] = it.getInt(1)
                }
            }
            
            stats["statusCounts"] = statusCounts
            stats["totalChunks"] = statusCounts.values.sum()
            stats["pendingChunks"] = statusCounts[STATUS_PENDING] ?: 0
            stats["completedChunks"] = statusCounts[STATUS_COMPLETED] ?: 0
            stats["failedChunks"] = statusCounts[STATUS_FAILED] ?: 0
            
            Log.d(TAG, "Statistics: $stats")
            stats
        } catch (e: Exception) {
            Log.e(TAG, "Error getting statistics", e)
            mapOf("error" to (e.message ?: "Unknown error"))
        }
    }
    
    // Helper methods
    private fun updateChunkStatus(chunkId: Long, status: String): Boolean {
        return try {
            val db = dbHelper.writableDatabase
            val values = ContentValues().apply {
                put(COLUMN_STATUS, status)
                put(COLUMN_UPDATED_AT, System.currentTimeMillis())
            }
            
            val rowsUpdated = db.update(
                TABLE_CHUNKS,
                values,
                "$COLUMN_ID = ?",
                arrayOf(chunkId.toString())
            )
            
            rowsUpdated > 0
        } catch (e: Exception) {
            Log.e(TAG, "Error updating chunk status", e)
            false
        }
    }
    
    private fun updateChunkPriority(chunkId: Long, priority: Int): Boolean {
        return try {
            val db = dbHelper.writableDatabase
            val values = ContentValues().apply {
                put(COLUMN_PRIORITY, priority)
                put(COLUMN_UPDATED_AT, System.currentTimeMillis())
            }
            
            val rowsUpdated = db.update(
                TABLE_CHUNKS,
                values,
                "$COLUMN_ID = ?",
                arrayOf(chunkId.toString())
            )
            
            rowsUpdated > 0
        } catch (e: Exception) {
            Log.e(TAG, "Error updating chunk priority", e)
            false
        }
    }
    
    private fun cursorToChunk(cursor: Cursor): ChunkItem {
        return ChunkItem(
            id = cursor.getLong(cursor.getColumnIndexOrThrow(COLUMN_ID)),
            sessionId = cursor.getString(cursor.getColumnIndexOrThrow(COLUMN_SESSION_ID)),
            chunkNumber = cursor.getInt(cursor.getColumnIndexOrThrow(COLUMN_CHUNK_NUMBER)),
            filePath = cursor.getString(cursor.getColumnIndexOrThrow(COLUMN_FILE_PATH)),
            fileSize = cursor.getLong(cursor.getColumnIndexOrThrow(COLUMN_FILE_SIZE)),
            checksum = cursor.getString(cursor.getColumnIndexOrThrow(COLUMN_CHECKSUM)),
            retryCount = cursor.getInt(cursor.getColumnIndexOrThrow(COLUMN_RETRY_COUNT)),
            createdAt = cursor.getLong(cursor.getColumnIndexOrThrow(COLUMN_CREATED_AT)),
            updatedAt = cursor.getLong(cursor.getColumnIndexOrThrow(COLUMN_UPDATED_AT)),
            status = cursor.getString(cursor.getColumnIndexOrThrow(COLUMN_STATUS)),
            priority = cursor.getInt(cursor.getColumnIndexOrThrow(COLUMN_PRIORITY))
        )
    }
    
    private fun calculateChecksum(file: File): String {
        return try {
            val digest = MessageDigest.getInstance("SHA-256")
            FileInputStream(file).use { fis ->
                val buffer = ByteArray(8192)
                var bytesRead: Int
                while (fis.read(buffer).also { bytesRead = it } != -1) {
                    digest.update(buffer, 0, bytesRead)
                }
            }
            digest.digest().joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            Log.e(TAG, "Error calculating checksum", e)
            ""
        }
    }
    
    private fun cleanupChunkFile(filePath: String) {
        try {
            val file = File(filePath)
            if (file.exists() && file.delete()) {
                Log.d(TAG, "Cleaned up chunk file: $filePath")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to cleanup chunk file: $filePath", e)
        }
    }
    
    /**
     * Database helper for chunk persistence
     */
    private inner class ChunkDatabaseHelper(context: Context) : 
        SQLiteOpenHelper(context, DATABASE_NAME, null, DATABASE_VERSION) {
        
        override fun onCreate(db: SQLiteDatabase) {
            val createTable = """
                CREATE TABLE $TABLE_CHUNKS (
                    $COLUMN_ID INTEGER PRIMARY KEY AUTOINCREMENT,
                    $COLUMN_SESSION_ID TEXT NOT NULL,
                    $COLUMN_CHUNK_NUMBER INTEGER NOT NULL,
                    $COLUMN_FILE_PATH TEXT NOT NULL,
                    $COLUMN_FILE_SIZE INTEGER DEFAULT 0,
                    $COLUMN_CHECKSUM TEXT DEFAULT '',
                    $COLUMN_RETRY_COUNT INTEGER DEFAULT 0,
                    $COLUMN_CREATED_AT INTEGER NOT NULL,
                    $COLUMN_UPDATED_AT INTEGER NOT NULL,
                    $COLUMN_STATUS TEXT DEFAULT '$STATUS_PENDING',
                    $COLUMN_PRIORITY INTEGER DEFAULT $PRIORITY_NORMAL,
                    UNIQUE($COLUMN_SESSION_ID, $COLUMN_CHUNK_NUMBER)
                )
            """.trimIndent()
            
            db.execSQL(createTable)
            
            // Create indexes for performance
            db.execSQL("CREATE INDEX idx_status_priority ON $TABLE_CHUNKS($COLUMN_STATUS, $COLUMN_PRIORITY)")
            db.execSQL("CREATE INDEX idx_session_chunk ON $TABLE_CHUNKS($COLUMN_SESSION_ID, $COLUMN_CHUNK_NUMBER)")
            db.execSQL("CREATE INDEX idx_created_at ON $TABLE_CHUNKS($COLUMN_CREATED_AT)")
            
            Log.d(TAG, "Chunk database created successfully")
        }
        
        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            Log.d(TAG, "Upgrading chunk database from version $oldVersion to $newVersion")
            db.execSQL("DROP TABLE IF EXISTS $TABLE_CHUNKS")
            onCreate(db)
        }
    }
}
