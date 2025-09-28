package com.example.medicalscribe

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.d("NotificationAction", "Received broadcast: ${intent.action}")
        
        when (intent.getStringExtra("action")) {
            "stop" -> {
                Log.d("NotificationAction", "Stop action received")
                val broadcastIntent = Intent("com.example.medicalscribe.RECORDING_ACTION")
                broadcastIntent.putExtra("action", "stop")
                context.sendBroadcast(broadcastIntent)
            }
            "pause" -> {
                Log.d("NotificationAction", "Pause action received")
                val broadcastIntent = Intent("com.example.medicalscribe.RECORDING_ACTION")
                broadcastIntent.putExtra("action", "pause")
                context.sendBroadcast(broadcastIntent)
            }
            "resume" -> {
                Log.d("NotificationAction", "Resume action received")
                val broadcastIntent = Intent("com.example.medicalscribe.RECORDING_ACTION")
                broadcastIntent.putExtra("action", "resume")
                context.sendBroadcast(broadcastIntent)
            }
            else -> {
                Log.d("NotificationAction", "Unknown action: ${intent.action}")
            }
        }
    }
}
