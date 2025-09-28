package com.example.medicalscribe

/**
 * Data class representing a chunk item for audio upload
 * Used by both legacy and robust chunk management systems
 */
data class ChunkItem(
    val sessionId: String,
    val chunkNumber: Int,
    val filePath: String,
    val retryCount: Int = 0
)
