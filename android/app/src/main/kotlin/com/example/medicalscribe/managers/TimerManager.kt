package com.example.medicalscribe.managers

import android.util.Log
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Manages recording timer functionality with proper lifecycle
 */
class TimerManager {
    
    companion object {
        private const val TAG = "TimerManager"
    }
    
    private var timerExecutor: ScheduledExecutorService? = null
    private val isTimerRunning = AtomicBoolean(false)
    private val recordingStartTime = AtomicLong(0)
    private var timerDurationMs: Long? = null
    
    // Callbacks
    private var onTimerExpired: (() -> Unit)? = null
    private var onTimerTick: ((remainingMs: Long) -> Unit)? = null
    
    /**
     * Set callback for when timer expires
     */
    fun setOnTimerExpired(callback: () -> Unit) {
        onTimerExpired = callback
    }
    
    /**
     * Set callback for timer tick updates
     */
    fun setOnTimerTick(callback: (remainingMs: Long) -> Unit) {
        onTimerTick = callback
    }
    
    /**
     * Start timer with specified duration
     */
    fun startTimer(durationMs: Long) {
        if (isTimerRunning.get()) {
            Log.w(TAG, "Timer already running")
            return
        }
        
        timerDurationMs = durationMs
        recordingStartTime.set(System.currentTimeMillis())
        isTimerRunning.set(true)
        
        timerExecutor = Executors.newSingleThreadScheduledExecutor()
        timerExecutor?.scheduleAtFixedRate({
            try {
                val elapsed = System.currentTimeMillis() - recordingStartTime.get()
                val remaining = durationMs - elapsed
                
                if (remaining <= 0) {
                    // Timer expired
                    Log.d(TAG, "Timer expired after ${durationMs}ms")
                    stopTimer()
                    onTimerExpired?.invoke()
                } else {
                    // Timer tick
                    onTimerTick?.invoke(remaining)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error in timer tick", e)
            }
        }, 0, 1000, TimeUnit.MILLISECONDS) // Update every second
        
        Log.d(TAG, "Started timer for ${durationMs}ms")
    }
    
    /**
     * Start timer with remaining time (for resume operations)
     */
    fun startTimerWithRemaining(remainingMs: Long) {
        if (remainingMs <= 0) {
            Log.w(TAG, "Cannot start timer with non-positive remaining time: $remainingMs")
            return
        }
        
        startTimer(remainingMs)
    }
    
    /**
     * Stop the timer
     */
    fun stopTimer() {
        if (!isTimerRunning.get()) {
            return
        }
        
        isTimerRunning.set(false)
        timerExecutor?.shutdown()
        timerExecutor = null
        
        Log.d(TAG, "Stopped timer")
    }
    
    /**
     * Get remaining time in milliseconds
     */
    fun getRemainingTime(): Long {
        if (!isTimerRunning.get() || timerDurationMs == null) {
            return 0
        }
        
        val elapsed = System.currentTimeMillis() - recordingStartTime.get()
        val remaining = timerDurationMs!! - elapsed
        return maxOf(0, remaining)
    }
    
    /**
     * Check if timer is currently running
     */
    fun isRunning(): Boolean = isTimerRunning.get()
    
    /**
     * Get elapsed time in milliseconds
     */
    fun getElapsedTime(): Long {
        if (recordingStartTime.get() == 0L) {
            return 0
        }
        return System.currentTimeMillis() - recordingStartTime.get()
    }
    
    /**
     * Pause timer (stops executor but keeps state)
     */
    fun pauseTimer() {
        if (!isTimerRunning.get()) {
            return
        }
        
        // Calculate remaining time before stopping
        val remaining = getRemainingTime()
        timerDurationMs = remaining
        
        // Stop executor but keep timer state
        timerExecutor?.shutdown()
        timerExecutor = null
        isTimerRunning.set(false)
        
        Log.d(TAG, "Paused timer with ${remaining}ms remaining")
    }
    
    /**
     * Resume timer with previously calculated remaining time
     */
    fun resumeTimer() {
        val remaining = timerDurationMs
        if (remaining == null || remaining <= 0) {
            Log.w(TAG, "Cannot resume timer - no valid remaining time")
            return
        }
        
        startTimer(remaining)
        Log.d(TAG, "Resumed timer with ${remaining}ms remaining")
    }
    
    /**
     * Clean up resources
     */
    fun cleanup() {
        stopTimer()
        onTimerExpired = null
        onTimerTick = null
        timerDurationMs = null
        recordingStartTime.set(0)
    }
}
