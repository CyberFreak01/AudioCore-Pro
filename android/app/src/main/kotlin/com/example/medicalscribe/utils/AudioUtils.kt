package com.example.medicalscribe.utils

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import com.example.medicalscribe.constants.AudioConstants
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * Utility functions for audio processing and calculations
 */
object AudioUtils {
    
    /**
     * Calculate the minimum buffer size for AudioRecord
     */
    fun calculateBufferSize(
        sampleRate: Int = AudioConstants.DEFAULT_SAMPLE_RATE,
        channelConfig: Int = AudioConstants.DEFAULT_CHANNEL_CONFIG,
        audioFormat: Int = AudioConstants.DEFAULT_AUDIO_FORMAT
    ): Int {
        val minBufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        return if (minBufferSize != AudioRecord.ERROR_BAD_VALUE && minBufferSize != AudioRecord.ERROR) {
            minBufferSize * AudioConstants.BUFFER_SIZE_MULTIPLIER
        } else {
            sampleRate * 2 // Fallback: 1 second of 16-bit mono audio
        }
    }
    
    /**
     * Calculate RMS (Root Mean Square) value from audio buffer
     */
    fun calculateRMS(buffer: ShortArray, readSize: Int): Double {
        var sum = 0.0
        for (i in 0 until readSize) {
            val sample = buffer[i].toDouble()
            sum += sample * sample
        }
        return sqrt(sum / readSize)
    }
    
    /**
     * Convert RMS to decibels
     */
    fun rmsToDecibels(rms: Double): Double {
        return if (rms > 0) {
            20 * log10(rms / AudioConstants.PCM_16_BIT_MAX)
        } else {
            -Double.MAX_VALUE
        }
    }
    
    /**
     * Find peak level in audio buffer
     */
    fun findPeakLevel(buffer: ShortArray, readSize: Int): Int {
        var peak = 0
        for (i in 0 until readSize) {
            val abs = kotlin.math.abs(buffer[i].toInt())
            if (abs > peak) {
                peak = abs
            }
        }
        return peak
    }
    
    /**
     * Apply gain to audio buffer
     */
    fun applyGain(buffer: ShortArray, readSize: Int, gain: Float): ShortArray {
        val result = ShortArray(readSize)
        for (i in 0 until readSize) {
            val amplified = (buffer[i] * gain).toInt()
            result[i] = amplified.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }
        return result
    }
    
    /**
     * Check if audio format is supported
     */
    fun isAudioFormatSupported(
        sampleRate: Int,
        channelConfig: Int,
        audioFormat: Int
    ): Boolean {
        val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        return bufferSize != AudioRecord.ERROR_BAD_VALUE && bufferSize != AudioRecord.ERROR
    }
    
    /**
     * Get optimal audio configuration for the device
     */
    fun getOptimalAudioConfig(): AudioConfig {
        val sampleRates = intArrayOf(44100, 22050, 16000, 11025, 8000)
        val channelConfigs = intArrayOf(
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.CHANNEL_IN_STEREO
        )
        
        for (sampleRate in sampleRates) {
            for (channelConfig in channelConfigs) {
                if (isAudioFormatSupported(sampleRate, channelConfig, AudioConstants.DEFAULT_AUDIO_FORMAT)) {
                    return AudioConfig(sampleRate, channelConfig, AudioConstants.DEFAULT_AUDIO_FORMAT)
                }
            }
        }
        
        // Fallback to default
        return AudioConfig(
            AudioConstants.DEFAULT_SAMPLE_RATE,
            AudioConstants.DEFAULT_CHANNEL_CONFIG,
            AudioConstants.DEFAULT_AUDIO_FORMAT
        )
    }
    
    /**
     * Calculate recording duration from chunk count and sample rate
     */
    fun calculateRecordingDuration(chunkCount: Int, sampleRate: Int): Long {
        // Assuming each chunk represents approximately 1 second of audio
        return (chunkCount * 1000L * AudioConstants.CHUNK_SIZE_BYTES) / (sampleRate * 2) // 16-bit = 2 bytes per sample
    }
    
    data class AudioConfig(
        val sampleRate: Int,
        val channelConfig: Int,
        val audioFormat: Int
    )
}
