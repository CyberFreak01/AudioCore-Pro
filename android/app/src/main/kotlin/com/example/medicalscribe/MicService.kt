    package com.example.medicalscribe

    import android.app.Notification
    import android.app.NotificationChannel
    import android.app.NotificationManager
    import android.app.Service
    import android.content.Intent
    import android.os.Build
    import android.os.IBinder
    import androidx.core.app.NotificationCompat
    import android.net.ConnectivityManager
    import android.net.Network
    import android.net.NetworkCapabilities
    import android.net.NetworkRequest
    import android.content.SharedPreferences
    import android.app.PendingIntent
    import android.content.pm.PackageManager

    class MicService : Service() {

        companion object {
            const val CHANNEL_ID = "MicServiceChannel"
            const val NOTIFICATION_ID = 2345678
            const val PREFS = "mic_prefs"
            const val PREF_RESUME = "resume_mic_service"
        }

        override fun onCreate() {
            super.onCreate()
            createNotificationChannel()
            // Create intents for notification actions
            val stopIntent = Intent(this, NotificationActionReceiver::class.java).apply {
                action = "com.example.medicalscribe.RECORDING_ACTION"
                putExtra("action", "stop")
            }
            val pauseIntent = Intent(this, NotificationActionReceiver::class.java).apply {
                action = "com.example.medicalscribe.RECORDING_ACTION"
                putExtra("action", "pause")
            }
            val resumeIntent = Intent(this, NotificationActionReceiver::class.java).apply {
                action = "com.example.medicalscribe.RECORDING_ACTION"
                putExtra("action", "resume")
            }

            // Convert intents to pending intents
            val stopPendingIntent = PendingIntent.getBroadcast(
                this, 0, stopIntent, 
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val pausePendingIntent = PendingIntent.getBroadcast(
                this, 0, pauseIntent, 
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val resumePendingIntent = PendingIntent.getBroadcast(
                this, 0, resumeIntent, 
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            // Create the notification with actions
            val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Recording in Progress")
                .setContentText("Tap to open the app")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setOngoing(true)
                .addAction(android.R.drawable.ic_media_pause, "Pause", pausePendingIntent)
                .addAction(R.drawable.ic_media_stop, "Stop", stopPendingIntent)
                .setContentIntent(
                    PendingIntent.getActivity(
                        this,
                        0,
                        packageManager.getLaunchIntentForPackage(packageName),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                )
                .build()
            startForeground(NOTIFICATION_ID, notification)
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean(PREF_RESUME, true).apply()
            registerNetworkCallback()
        }

        private fun createNotificationChannel() {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val serviceChannel = NotificationChannel(
                    CHANNEL_ID,
                    "Recording Controls",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Shows recording controls and status"
                    setShowBadge(false)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                }
                val manager = getSystemService(NotificationManager::class.java)
                manager?.createNotificationChannel(serviceChannel)
            }
        }

        override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
            // Service keeps running while recording takes place
            return START_STICKY
        }

        override fun onBind(intent: Intent?): IBinder? {
            return null
        }

        override fun onDestroy() {
            super.onDestroy()
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean(PREF_RESUME, false).apply()
        }

        override fun onTaskRemoved(rootIntent: Intent?) {
            super.onTaskRemoved(rootIntent)
            stopSelf()
        }

        private fun registerNetworkCallback() {
            try {
                val cm = getSystemService(ConnectivityManager::class.java)
                val request = NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build()
                cm?.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        sendBroadcast(Intent("com.example.medicalscribe.NETWORK_AVAILABLE"))
                    }
                })
            } catch (_: Exception) { }
        }
    }


