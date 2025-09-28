package com.example.medicalscribe.constants

/**
 * Audio recording and processing constants
 */
object AudioConstants {
    // Audio format constants
    const val DEFAULT_SAMPLE_RATE = 44100
    const val DEFAULT_CHANNEL_CONFIG = android.media.AudioFormat.CHANNEL_IN_MONO
    const val DEFAULT_AUDIO_FORMAT = android.media.AudioFormat.ENCODING_PCM_16BIT
    const val DEFAULT_OUTPUT_FORMAT = "wav"
    
    // Buffer and chunk constants
    const val BUFFER_SIZE_MULTIPLIER = 2
    const val CHUNK_SIZE_BYTES = 1024 * 1024 // 1MB chunks
    const val MAX_CHUNK_DURATION_MS = 30000 // 30 seconds
    
    // Gain constants
    const val MIN_GAIN = 0.1f
    const val MAX_GAIN = 5.0f
    const val DEFAULT_GAIN = 1.0f
    
    // Audio level constants
    const val PCM_16_BIT_MAX = 32767
    const val LEVEL_UPDATE_INTERVAL_MS = 100L
    
    // Permission constants
    const val PERMISSION_REQUEST_CODE = 1001
    
    // Notification constants
    const val NOTIFICATION_CHANNEL_ID = "record_control"
    const val NOTIFICATION_ID = 987654
    
    // Retry constants
    const val MAX_RETRIES = 5
    const val RETRY_DELAY_BASE_MS = 1000L
    const val RETRY_DELAY_MULTIPLIER = 2
    
    // File constants
    const val AUDIO_CHUNKS_DIR = "audio_chunks"
    const val CHUNK_FILE_EXTENSION = ".wav"
}
