import Foundation
import CryptoKit

// MARK: - Chunk Data Models
struct AudioChunk {
    let sessionId: String
    let chunkNumber: Int
    let filePath: String
    let checksum: String
    let fileSize: Int64
    let timestamp: Date
    let sampleRate: Double
    let duration: Double
    var uploadStatus: ChunkUploadStatus
    var retryCount: Int
    var lastRetryTime: Date?
    
    init(sessionId: String, chunkNumber: Int, filePath: String, sampleRate: Double, duration: Double) {
        self.sessionId = sessionId
        self.chunkNumber = chunkNumber
        self.filePath = filePath
        self.sampleRate = sampleRate
        self.duration = duration
        self.timestamp = Date()
        self.uploadStatus = .pending
        self.retryCount = 0
        self.lastRetryTime = nil
        
        // Calculate file size and checksum
        let url = URL(fileURLWithPath: filePath)
        if let data = try? Data(contentsOf: url) {
            self.fileSize = Int64(data.count)
            self.checksum = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        } else {
            self.fileSize = 0
            self.checksum = ""
        }
    }
}

enum ChunkUploadStatus: String, CaseIterable {
    case pending = "pending"
    case uploading = "uploading"
    case uploaded = "uploaded"
    case failed = "failed"
    case retrying = "retrying"
}

// MARK: - Chunk Manager
class ChunkManager: NSObject {
    static let shared = ChunkManager()
    
    private let persistentQueue = PersistentQueue()
    private let networkMonitor = NetworkMonitor()
    private let backgroundTaskManager = BackgroundTaskManager()
    
    private var uploadQueue: [AudioChunk] = []
    private var activeUploads: Set<String> = []
    private let maxConcurrentUploads = 3
    private let maxRetryCount = 5
    private let retryDelayBase: TimeInterval = 2.0 // Exponential backoff base
    
    private let processingQueue = DispatchQueue(label: "ChunkManager.processing", qos: .utility)
    private let uploadQueue_concurrent = DispatchQueue(label: "ChunkManager.upload", qos: .utility, attributes: .concurrent)
    
    override init() {
        super.init()
        loadPersistentQueue()
        setupNetworkMonitoring()
        setupBackgroundTasks()
    }
    
    // MARK: - Public Interface
    func addChunk(_ chunk: AudioChunk) {
        processingQueue.async {
            self.uploadQueue.append(chunk)
            self.persistentQueue.saveChunk(chunk)
            self.processUploadQueue()
        }
    }
    
    func markChunkUploaded(sessionId: String, chunkNumber: Int) {
        processingQueue.async {
            if let index = self.uploadQueue.firstIndex(where: { $0.sessionId == sessionId && $0.chunkNumber == chunkNumber }) {
                self.uploadQueue[index].uploadStatus = .uploaded
                self.persistentQueue.updateChunkStatus(sessionId: sessionId, chunkNumber: chunkNumber, status: .uploaded)
                
                // Remove from active uploads
                let chunkId = "\(sessionId)_\(chunkNumber)"
                self.activeUploads.remove(chunkId)
                
                // Clean up local file after successful upload
                self.cleanupChunkFile(self.uploadQueue[index])
                
                // Remove from queue
                self.uploadQueue.remove(at: index)
                
                // Process next chunks
                self.processUploadQueue()
            }
        }
    }
    
    func getPendingSessions() -> [[String: Any]] {
        var sessions: [String: [String: Any]] = [:]
        
        for chunk in uploadQueue {
            if sessions[chunk.sessionId] == nil {
                sessions[chunk.sessionId] = [
                    "sessionId": chunk.sessionId,
                    "totalChunks": 0,
                    "uploadedChunks": 0,
                    "pendingChunks": 0,
                    "failedChunks": 0,
                    "totalSize": 0,
                    "firstChunkTime": chunk.timestamp.timeIntervalSince1970
                ]
            }
            
            sessions[chunk.sessionId]!["totalChunks"] = (sessions[chunk.sessionId]!["totalChunks"] as! Int) + 1
            sessions[chunk.sessionId]!["totalSize"] = (sessions[chunk.sessionId]!["totalSize"] as! Int64) + chunk.fileSize
            
            switch chunk.uploadStatus {
            case .uploaded:
                sessions[chunk.sessionId]!["uploadedChunks"] = (sessions[chunk.sessionId]!["uploadedChunks"] as! Int) + 1
            case .pending, .retrying:
                sessions[chunk.sessionId]!["pendingChunks"] = (sessions[chunk.sessionId]!["pendingChunks"] as! Int) + 1
            case .failed:
                sessions[chunk.sessionId]!["failedChunks"] = (sessions[chunk.sessionId]!["failedChunks"] as! Int) + 1
            default:
                break
            }
        }
        
        return Array(sessions.values)
    }
    
    func retryFailedChunks(sessionId: String? = nil) {
        processingQueue.async {
            for i in 0..<self.uploadQueue.count {
                let chunk = self.uploadQueue[i]
                if chunk.uploadStatus == .failed && (sessionId == nil || chunk.sessionId == sessionId) {
                    self.uploadQueue[i].uploadStatus = .pending
                    self.uploadQueue[i].retryCount = 0
                    self.persistentQueue.updateChunkStatus(sessionId: chunk.sessionId, chunkNumber: chunk.chunkNumber, status: .pending)
                }
            }
            self.processUploadQueue()
        }
    }
    
    // MARK: - Private Methods
    private func loadPersistentQueue() {
        uploadQueue = persistentQueue.loadAllChunks()
    }
    
    private func setupNetworkMonitoring() {
        networkMonitor.onNetworkAvailable = { [weak self] in
            self?.processUploadQueue()
        }
        networkMonitor.startMonitoring()
    }
    
    private func setupBackgroundTasks() {
        backgroundTaskManager.registerBackgroundTasks()
    }
    
    private func processUploadQueue() {
        guard networkMonitor.isNetworkAvailable else { return }
        
        let pendingChunks = uploadQueue.filter { chunk in
            chunk.uploadStatus == .pending && !activeUploads.contains("\(chunk.sessionId)_\(chunk.chunkNumber)")
        }
        
        let availableSlots = maxConcurrentUploads - activeUploads.count
        let chunksToUpload = Array(pendingChunks.prefix(availableSlots))
        
        for chunk in chunksToUpload {
            uploadChunk(chunk)
        }
        
        // Schedule retry for failed chunks
        scheduleRetryForFailedChunks()
    }
    
    private func uploadChunk(_ chunk: AudioChunk) {
        let chunkId = "\(chunk.sessionId)_\(chunk.chunkNumber)"
        activeUploads.insert(chunkId)
        
        // Update status to uploading
        if let index = uploadQueue.firstIndex(where: { $0.sessionId == chunk.sessionId && $0.chunkNumber == chunk.chunkNumber }) {
            uploadQueue[index].uploadStatus = .uploading
            persistentQueue.updateChunkStatus(sessionId: chunk.sessionId, chunkNumber: chunk.chunkNumber, status: .uploading)
        }
        
        uploadQueue_concurrent.async {
            self.performChunkUpload(chunk) { [weak self] success in
                self?.processingQueue.async {
                    self?.activeUploads.remove(chunkId)
                    
                    if let index = self?.uploadQueue.firstIndex(where: { $0.sessionId == chunk.sessionId && $0.chunkNumber == chunk.chunkNumber }) {
                        if success {
                            // Will be marked as uploaded via markChunkUploaded call from Flutter
                            print("ChunkManager: Chunk \(chunkId) uploaded successfully")
                        } else {
                            // Mark as failed and schedule retry
                            self?.uploadQueue[index].uploadStatus = .failed
                            self?.uploadQueue[index].retryCount += 1
                            self?.uploadQueue[index].lastRetryTime = Date()
                            self?.persistentQueue.updateChunkStatus(sessionId: chunk.sessionId, chunkNumber: chunk.chunkNumber, status: .failed)
                            print("ChunkManager: Chunk \(chunkId) upload failed, retry count: \(self?.uploadQueue[index].retryCount ?? 0)")
                        }
                    }
                    
                    // Continue processing queue
                    self?.processUploadQueue()
                }
            }
        }
    }
    
    private func performChunkUpload(_ chunk: AudioChunk, completion: @escaping (Bool) -> Void) {
        // Validate chunk integrity before upload
        guard validateChunkIntegrity(chunk) else {
            print("ChunkManager: Chunk integrity validation failed for \(chunk.sessionId)_\(chunk.chunkNumber)")
            completion(false)
            return
        }
        
        // Emit chunk ready event to Flutter for actual upload
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .chunkReadyForUpload, object: nil, userInfo: [
                "sessionId": chunk.sessionId,
                "chunkNumber": chunk.chunkNumber,
                "filePath": chunk.filePath,
                "checksum": chunk.checksum,
                "fileSize": chunk.fileSize,
                "retryCount": chunk.retryCount
            ])
        }
        
        // For now, assume upload will be handled by Flutter
        // The actual success/failure will be reported back via markChunkUploaded
        completion(true)
    }
    
    private func validateChunkIntegrity(_ chunk: AudioChunk) -> Bool {
        let url = URL(fileURLWithPath: chunk.filePath)
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: chunk.filePath) else {
            print("ChunkManager: File does not exist: \(chunk.filePath)")
            return false
        }
        
        // Verify file size
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: chunk.filePath)
            let fileSize = attributes[.size] as? Int64 ?? 0
            guard fileSize == chunk.fileSize else {
                print("ChunkManager: File size mismatch. Expected: \(chunk.fileSize), Actual: \(fileSize)")
                return false
            }
        } catch {
            print("ChunkManager: Error getting file attributes: \(error)")
            return false
        }
        
        // Verify checksum
        do {
            let data = try Data(contentsOf: url)
            let actualChecksum = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            guard actualChecksum == chunk.checksum else {
                print("ChunkManager: Checksum mismatch. Expected: \(chunk.checksum), Actual: \(actualChecksum)")
                return false
            }
        } catch {
            print("ChunkManager: Error reading file for checksum validation: \(error)")
            return false
        }
        
        return true
    }
    
    private func scheduleRetryForFailedChunks() {
        let now = Date()
        
        for i in 0..<uploadQueue.count {
            let chunk = uploadQueue[i]
            
            if chunk.uploadStatus == .failed && chunk.retryCount < maxRetryCount {
                let retryDelay = retryDelayBase * pow(2.0, Double(chunk.retryCount)) // Exponential backoff
                let nextRetryTime = (chunk.lastRetryTime ?? now).addingTimeInterval(retryDelay)
                
                if now >= nextRetryTime {
                    uploadQueue[i].uploadStatus = .pending
                    persistentQueue.updateChunkStatus(sessionId: chunk.sessionId, chunkNumber: chunk.chunkNumber, status: .pending)
                }
            }
        }
    }
    
    private func cleanupChunkFile(_ chunk: AudioChunk) {
        do {
            try FileManager.default.removeItem(atPath: chunk.filePath)
            print("ChunkManager: Cleaned up chunk file: \(chunk.filePath)")
        } catch {
            print("ChunkManager: Error cleaning up chunk file: \(error)")
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let chunkReadyForUpload = Notification.Name("chunkReadyForUpload")
}
