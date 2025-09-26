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
            val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Microphone is Active")
                .setContentText("This app is accessing your microphone.")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setOngoing(true)
                .build()
            startForeground(NOTIFICATION_ID, notification)
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean(PREF_RESUME, true).apply()
            registerNetworkCallback()
        }

        private fun createNotificationChannel() {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val serviceChannel = NotificationChannel(
                    CHANNEL_ID,
                    "Mic Service Channel",
                    NotificationManager.IMPORTANCE_DEFAULT
                )
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


