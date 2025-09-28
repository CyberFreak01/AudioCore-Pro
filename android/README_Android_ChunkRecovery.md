# Android Native Chunk Recovery System

This document describes the enhanced Android native implementation for robust chunk handling and recovery after app kills/restarts.

## Overview

The Android chunk recovery system has been completely redesigned to handle app kill scenarios gracefully. When the app is killed while chunks are in the upload queue, the system ensures that all pending chunks are recovered and uploaded when the app restarts.

## Core Components

### 1. ChunkManager.kt
**Purpose**: SQLite-based persistent chunk queue management with integrity validation

**Key Features**:
- SQLite database for persistent storage that survives app kills
- SHA-256 checksum validation for data integrity
- Priority-based queue processing (recovery chunks get higher priority)
- Automatic retry logic with exponential backoff
- File cleanup after successful uploads
- Comprehensive queue statistics and monitoring

**Database Schema**:
```sql
CREATE TABLE chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    chunk_number INTEGER NOT NULL,
    file_path TEXT NOT NULL,
    file_size INTEGER DEFAULT 0,
    checksum TEXT DEFAULT '',
    retry_count INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL,
    status TEXT DEFAULT 'pending',
    priority INTEGER DEFAULT 2,
    UNIQUE(session_id, chunk_number)
)
```

### 2. NetworkMonitor.kt
**Purpose**: Intelligent network state monitoring and upload optimization

**Key Features**:
- Real-time network connectivity monitoring
- Connection type detection (WiFi/Cellular/Ethernet)
- Metered connection detection for data usage optimization
- Adaptive batch sizing based on network conditions
- Smart retry delay calculation based on network type
- Network constraint detection for background uploads

**Network-Aware Behavior**:
- WiFi: Aggressive uploading with larger batch sizes
- Cellular: Conservative uploading with smaller batches
- Metered: Minimal uploading, user preference dependent
- No Network: Queue chunks for later processing

### 3. BackgroundTaskManager.kt
**Purpose**: Background task scheduling using Android WorkManager

**Key Features**:
- Periodic chunk upload tasks (every 15 minutes)
- Immediate chunk recovery on app restart
- Daily cleanup of old completed chunks
- Network-constrained task execution
- Exponential backoff for failed tasks

**WorkManager Tasks**:
- `ChunkUploadWorker`: Processes pending chunks in background
- `ChunkRecoveryWorker`: Recovers chunks on app restart
- `ChunkCleanupWorker`: Cleans up old completed chunks

### 4. Enhanced MainActivity.kt
**Purpose**: Integration layer between Flutter and native chunk management

**Key Enhancements**:
- Integration with ChunkManager for persistent storage
- Network-aware chunk processing
- Background task coordination
- Enhanced method channels for Flutter communication
- Comprehensive error handling and logging

## Recovery Process Flow

### 1. App Startup Recovery
```
App Starts → Initialize ChunkManager → Schedule Recovery Task → 
Recover Pending Chunks → Validate File Integrity → 
Priority Queue Processing → Upload Recovered Chunks
```

### 2. Chunk Processing Priority
1. **Recovery Chunks** (Priority 1): Chunks recovered from previous sessions
2. **Normal Chunks** (Priority 2): Newly created chunks from current session

### 3. Network-Aware Processing
```
Network Available → Check Connection Type → 
Determine Batch Size → Process Queue → 
Monitor Upload Progress → Handle Failures
```

## Key Improvements Over Previous Implementation

### 1. Persistent Storage
- **Before**: SharedPreferences with limited string storage
- **After**: SQLite database with proper schema and indexing

### 2. Data Integrity
- **Before**: No integrity validation
- **After**: SHA-256 checksums for all chunks

### 3. Network Intelligence
- **Before**: Basic network availability check
- **After**: Comprehensive network monitoring with adaptive behavior

### 4. Background Processing
- **Before**: No background task management
- **After**: WorkManager integration for reliable background processing

### 5. Priority Management
- **Before**: FIFO queue processing
- **After**: Priority-based processing with recovery chunks prioritized

### 6. Error Handling
- **Before**: Basic retry with fixed delays
- **After**: Exponential backoff with network-aware delays

## Usage Examples

### 1. Adding a Chunk
```kotlin
val success = chunkManager.addChunk(sessionId, chunkNumber, filePath)
if (success) {
    // Chunk added to persistent queue
    // Will be uploaded when network conditions are favorable
}
```

### 2. Recovering Chunks on App Start
```kotlin
val recoveredCount = chunkManager.recoverPendingChunks()
// Automatically prioritizes recovered chunks for upload
```

### 3. Getting Queue Statistics
```kotlin
val stats = chunkManager.getQueueStats()
// Returns comprehensive statistics including:
// - Pending/uploading/completed/failed counts
// - Queue size and processing state
// - Sessions with pending chunks
```

### 4. Network State Monitoring
```kotlin
networkMonitor.startMonitoring { networkState ->
    // Automatically adjusts upload behavior based on:
    // - Connection availability
    // - Connection type (WiFi/Cellular)
    // - Metered status
    // - Optimal batch size
}
```

## Flutter Integration

### New Method Channels
- `recoverChunks`: Manually trigger chunk recovery
- `getNetworkInfo`: Get current network state information
- `retryFailedChunks`: Retry chunks that have failed
- `getQueueStatus`: Get enhanced queue statistics

### Enhanced Event Channels
- `chunks_recovered`: Notifies when chunks are recovered on startup
- `network_state_changed`: Real-time network state updates
- `chunk_uploaded`: Enhanced upload notifications with metadata

## Configuration Options

### Retry Configuration
```kotlin
companion object {
    private const val MAX_RETRIES = 5
    private val RETRY_DELAYS = longArrayOf(1000, 2000, 5000, 10000, 30000)
}
```

### Network Batch Sizes
```kotlin
fun getOptimalBatchSize(): Int {
    return when {
        !isNetworkAvailable.get() -> 0
        isWifiConnected.get() -> 5      // Aggressive on WiFi
        isMetered.get() -> 1            // Conservative on metered
        else -> 3                       // Moderate on cellular
    }
}
```

### Cleanup Configuration
```kotlin
fun cleanupOldChunks(olderThanDays: Int = 7): Int
// Automatically cleans up chunks older than 7 days
```

## Testing Scenarios

### 1. App Kill During Upload
1. Start recording and generate chunks
2. Kill app while chunks are uploading
3. Restart app
4. Verify all chunks are recovered and uploaded

### 2. Network Interruption
1. Start chunk upload process
2. Disable network connection
3. Re-enable network
4. Verify chunks resume uploading automatically

### 3. Storage Integrity
1. Generate chunks with known content
2. Kill and restart app multiple times
3. Verify chunk checksums remain valid
4. Verify no data corruption

## Performance Considerations

### Database Optimization
- Proper indexing on frequently queried columns
- Efficient batch operations for large chunk sets
- Automatic cleanup of old completed records

### Memory Management
- Lazy loading of chunk data
- Efficient cursor management for database operations
- Proper resource cleanup in all code paths

### Network Efficiency
- Intelligent batching based on network conditions
- Exponential backoff to prevent network flooding
- Respect for metered connections and user preferences

## Security Considerations

### Data Protection
- Chunks stored in app's private directory
- SQLite database protected by Android app sandbox
- No sensitive data logged in production builds

### Network Security
- HTTPS enforcement for all upload operations
- Proper certificate validation
- Secure handling of presigned URLs

## Monitoring and Debugging

### Logging
- Comprehensive logging at all levels (DEBUG/INFO/WARN/ERROR)
- Network state change logging
- Chunk processing progress tracking
- Error condition logging with stack traces

### Statistics
- Real-time queue statistics
- Network performance metrics
- Upload success/failure rates
- Recovery operation metrics

This enhanced Android chunk recovery system provides robust, reliable chunk handling that survives app kills, network interruptions, and various edge cases while maintaining optimal performance and user experience.
