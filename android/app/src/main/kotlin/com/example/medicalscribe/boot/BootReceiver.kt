package com.example.medicalscribe.boot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.example.medicalscribe.MicService

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            val prefs = context.getSharedPreferences(com.example.medicalscribe.MicService.PREFS, Context.MODE_PRIVATE)
            if (prefs.getBoolean(com.example.medicalscribe.MicService.PREF_RESUME, false)) {
                val svc = Intent(context, MicService::class.java)
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    context.startForegroundService(svc)
                } else {
                    context.startService(svc)
                }
            }
        }
    }
}


