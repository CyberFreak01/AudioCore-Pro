package com.example.medicalscribe

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            "ACTION_STOP" -> {
                // Send broadcast to MainActivity
                val broadcastIntent = Intent("com.example.medicalscribe.RECORDING_ACTION")
                broadcastIntent.putExtra("action", "stop")
                context.sendBroadcast(broadcastIntent)
            }
            "ACTION_PAUSE" -> {
                val broadcastIntent = Intent("com.example.medicalscribe.RECORDING_ACTION")
                broadcastIntent.putExtra("action", "pause")
                context.sendBroadcast(broadcastIntent)
            }
            "ACTION_RESUME" -> {
                val broadcastIntent = Intent("com.example.medicalscribe.RECORDING_ACTION")
                broadcastIntent.putExtra("action", "resume")
                context.sendBroadcast(broadcastIntent)
            }
        }
    }
}