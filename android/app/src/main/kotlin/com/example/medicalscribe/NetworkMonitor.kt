package com.example.medicalscribe

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Network monitoring class to track connectivity state and optimize upload behavior
 */
class NetworkMonitor(private val context: Context) {
    
    companion object {
        private const val TAG = "NetworkMonitor"
    }
    
    private val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val isNetworkAvailable = AtomicBoolean(false)
    private val isWifiConnected = AtomicBoolean(false)
    private val isMetered = AtomicBoolean(false)
    
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var onNetworkStateChanged: ((NetworkState) -> Unit)? = null
    
    data class NetworkState(
        val isAvailable: Boolean,
        val isWifi: Boolean,
        val isMetered: Boolean,
        val connectionType: String,
        val uploadBatchSize: Int
    )
    
    /**
     * Start monitoring network state
     */
    fun startMonitoring(onStateChanged: (NetworkState) -> Unit) {
        this.onNetworkStateChanged = onStateChanged
        
        val networkRequest = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            .build()
        
        networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                super.onAvailable(network)
                Log.d(TAG, "Network available: $network")
                updateNetworkState()
            }
            
            override fun onLost(network: Network) {
                super.onLost(network)
                Log.d(TAG, "Network lost: $network")
                updateNetworkState()
            }
            
            override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                super.onCapabilitiesChanged(network, networkCapabilities)
                Log.d(TAG, "Network capabilities changed: $network")
                updateNetworkState()
            }
        }
        
        try {
            connectivityManager.registerNetworkCallback(networkRequest, networkCallback!!)
            // Initial state check
            updateNetworkState()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register network callback", e)
        }
    }
    
    /**
     * Stop monitoring network state
     */
    fun stopMonitoring() {
        networkCallback?.let { callback ->
            try {
                connectivityManager.unregisterNetworkCallback(callback)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to unregister network callback", e)
            }
        }
        networkCallback = null
        onNetworkStateChanged = null
    }
    
    /**
     * Get current network state
     */
    fun getCurrentNetworkState(): NetworkState {
        updateNetworkState()
        return NetworkState(
            isAvailable = isNetworkAvailable.get(),
            isWifi = isWifiConnected.get(),
            isMetered = isMetered.get(),
            connectionType = getConnectionType(),
            uploadBatchSize = getOptimalBatchSize()
        )
    }
    
    /**
     * Check if network is suitable for uploading
     */
    fun isUploadRecommended(): Boolean {
        val state = getCurrentNetworkState()
        // Allow uploads on any available network, but be conservative on metered
        return state.isAvailable
    }
    
    /**
     * Check if network is suitable for aggressive uploading
     */
    fun isAggressiveUploadRecommended(): Boolean {
        val state = getCurrentNetworkState()
        return state.isAvailable && (!state.isMetered || state.isWifi)
    }
    
    /**
     * Get optimal batch size based on network conditions
     */
    fun getOptimalBatchSize(): Int {
        return when {
            !isNetworkAvailable.get() -> 0
            isWifiConnected.get() -> 5 // Higher batch size on WiFi
            isMetered.get() -> 1 // Conservative on metered connections
            else -> 3 // Moderate batch size on cellular
        }
    }
    
    /**
     * Get retry delay based on network conditions
     */
    fun getRetryDelay(retryCount: Int): Long {
        val baseDelay = when {
            isWifiConnected.get() -> 1000L // Fast retry on WiFi
            isMetered.get() -> 10000L // Slower retry on metered
            else -> 5000L // Moderate retry on cellular
        }
        
        // Exponential backoff
        return baseDelay * (1 shl minOf(retryCount, 5))
    }
    
    /**
     * Update network state based on current connectivity
     */
    private fun updateNetworkState() {
        try {
            val activeNetwork = connectivityManager.activeNetwork
            val networkCapabilities = activeNetwork?.let { connectivityManager.getNetworkCapabilities(it) }
            
            val wasAvailable = isNetworkAvailable.get()
            val wasWifi = isWifiConnected.get()
            val wasMetered = isMetered.get()
            
            if (networkCapabilities != null) {
                isNetworkAvailable.set(
                    networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                )
                
                isWifiConnected.set(
                    networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                )
                
                isMetered.set(
                    !networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                )
            } else {
                isNetworkAvailable.set(false)
                isWifiConnected.set(false)
                isMetered.set(true)
            }
            
            // Notify if state changed
            val currentAvailable = isNetworkAvailable.get()
            val currentWifi = isWifiConnected.get()
            val currentMetered = isMetered.get()
            
            if (wasAvailable != currentAvailable || wasWifi != currentWifi || wasMetered != currentMetered) {
                val state = NetworkState(
                    isAvailable = currentAvailable,
                    isWifi = currentWifi,
                    isMetered = currentMetered,
                    connectionType = getConnectionType(),
                    uploadBatchSize = getOptimalBatchSize()
                )
                
                Log.d(TAG, "Network state changed: $state")
                onNetworkStateChanged?.invoke(state)
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "Error updating network state", e)
            isNetworkAvailable.set(false)
            isWifiConnected.set(false)
            isMetered.set(true)
        }
    }
    
    /**
     * Get human-readable connection type
     */
    private fun getConnectionType(): String {
        return try {
            val activeNetwork = connectivityManager.activeNetwork
            val networkCapabilities = activeNetwork?.let { connectivityManager.getNetworkCapabilities(it) }
            
            when {
                networkCapabilities == null -> "None"
                networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "WiFi"
                networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Cellular"
                networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
                networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "Bluetooth"
                else -> "Unknown"
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error getting connection type", e)
            "Error"
        }
    }
    
    /**
     * Check if current network is constrained (limited bandwidth/data)
     */
    fun isNetworkConstrained(): Boolean {
        return try {
            val activeNetwork = connectivityManager.activeNetwork
            val networkCapabilities = activeNetwork?.let { connectivityManager.getNetworkCapabilities(it) }
            
            networkCapabilities?.let {
                // Check if network is metered or has restricted background data
                !it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ||
                !it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            } ?: true
        } catch (e: Exception) {
            Log.e(TAG, "Error checking network constraints", e)
            true
        }
    }
    
    /**
     * Get network info for debugging/logging
     */
    fun getNetworkInfo(): Map<String, Any> {
        return try {
            val activeNetwork = connectivityManager.activeNetwork
            val networkCapabilities = activeNetwork?.let { connectivityManager.getNetworkCapabilities(it) }
            
            mapOf(
                "isAvailable" to isNetworkAvailable.get(),
                "isWifi" to isWifiConnected.get(),
                "isMetered" to isMetered.get(),
                "connectionType" to getConnectionType(),
                "isConstrained" to isNetworkConstrained(),
                "uploadRecommended" to isUploadRecommended(),
                "optimalBatchSize" to getOptimalBatchSize(),
                "capabilities" to (networkCapabilities?.toString() ?: "None")
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error getting network info", e)
            mapOf("error" to (e.message ?: "Unknown error"))
        }
    }
}
