import Foundation
import Network

class NetworkMonitor: ObservableObject {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    
    @Published var isNetworkAvailable = false
    @Published var connectionType: ConnectionType = .unknown
    @Published var isExpensive = false
    @Published var isConstrained = false
    
    var onNetworkAvailable: (() -> Void)?
    var onNetworkUnavailable: (() -> Void)?
    var onConnectionTypeChanged: ((ConnectionType) -> Void)?
    
    enum ConnectionType {
        case wifi
        case cellular
        case ethernet
        case unknown
    }
    
    init() {
        startMonitoring()
    }
    
    deinit {
        stopMonitoring()
    }
    
    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.updateNetworkStatus(path)
            }
        }
        monitor.start(queue: queue)
    }
    
    func stopMonitoring() {
        monitor.cancel()
    }
    
    private func updateNetworkStatus(_ path: NWPath) {
        let wasAvailable = isNetworkAvailable
        let previousConnectionType = connectionType
        
        isNetworkAvailable = path.status == .satisfied
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        
        // Determine connection type
        if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionType = .ethernet
        } else {
            connectionType = .unknown
        }
        
        // Notify about network availability changes
        if isNetworkAvailable && !wasAvailable {
            print("NetworkMonitor: Network became available (\(connectionType))")
            onNetworkAvailable?()
        } else if !isNetworkAvailable && wasAvailable {
            print("NetworkMonitor: Network became unavailable")
            onNetworkUnavailable?()
        }
        
        // Notify about connection type changes
        if connectionType != previousConnectionType {
            print("NetworkMonitor: Connection type changed to \(connectionType)")
            onConnectionTypeChanged?(connectionType)
        }
        
        // Log network characteristics
        if isExpensive {
            print("NetworkMonitor: Network is expensive (cellular data)")
        }
        
        if isConstrained {
            print("NetworkMonitor: Network is constrained (low data mode)")
        }
    }
    
    func getNetworkInfo() -> [String: Any] {
        return [
            "isAvailable": isNetworkAvailable,
            "connectionType": connectionTypeString(),
            "isExpensive": isExpensive,
            "isConstrained": isConstrained
        ]
    }
    
    private func connectionTypeString() -> String {
        switch connectionType {
        case .wifi:
            return "wifi"
        case .cellular:
            return "cellular"
        case .ethernet:
            return "ethernet"
        case .unknown:
            return "unknown"
        }
    }
    
    // Check if we should pause uploads due to network conditions
    func shouldPauseUploads() -> Bool {
        // Pause if network is unavailable
        guard isNetworkAvailable else { return true }
        
        // Pause if network is constrained (low data mode)
        if isConstrained {
            print("NetworkMonitor: Pausing uploads due to constrained network")
            return true
        }
        
        // Could add logic here to pause on expensive networks based on user preferences
        // For now, continue uploads even on cellular
        
        return false
    }
    
    // Get recommended upload batch size based on network conditions
    func getRecommendedBatchSize() -> Int {
        guard isNetworkAvailable else { return 0 }
        
        switch connectionType {
        case .wifi, .ethernet:
            return isConstrained ? 1 : 3
        case .cellular:
            return isExpensive ? 1 : 2
        case .unknown:
            return 1
        }
    }
    
    // Get recommended retry delay based on network conditions
    func getRecommendedRetryDelay() -> TimeInterval {
        guard isNetworkAvailable else { return 60.0 } // 1 minute if no network
        
        switch connectionType {
        case .wifi, .ethernet:
            return 5.0 // 5 seconds
        case .cellular:
            return isExpensive ? 30.0 : 10.0 // 30s for expensive, 10s otherwise
        case .unknown:
            return 15.0 // 15 seconds
        }
    }
}
