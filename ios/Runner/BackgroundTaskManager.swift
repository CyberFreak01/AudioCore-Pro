import Foundation
import BackgroundTasks
import UIKit

class BackgroundTaskManager: NSObject {
    static let shared = BackgroundTaskManager()
    
    // Background task identifiers (must match Info.plist)
    private let audioUploadTaskId = "com.medicalscribe.audio-upload"
    private let chunkRetryTaskId = "com.medicalscribe.chunk-retry"
    
    // Background task tracking
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var isBackgroundTaskActive = false
    
    override init() {
        super.init()
        setupNotifications()
    }
    
    // MARK: - Public Interface
    func registerBackgroundTasks() {
        // Register background app refresh task for audio uploads
        BGTaskScheduler.shared.register(forTaskWithIdentifier: audioUploadTaskId, using: nil) { task in
            self.handleAudioUploadTask(task as! BGAppRefreshTask)
        }
        
        // Register background processing task for chunk retry
        BGTaskScheduler.shared.register(forTaskWithIdentifier: chunkRetryTaskId, using: nil) { task in
            self.handleChunkRetryTask(task as! BGProcessingTask)
        }
        
        print("BackgroundTaskManager: Registered background tasks")
    }
    
    func scheduleAudioUploadTask() {
        let request = BGAppRefreshTaskRequest(identifier: audioUploadTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes from now
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("BackgroundTaskManager: Scheduled audio upload task")
        } catch {
            print("BackgroundTaskManager: Failed to schedule audio upload task: \(error)")
        }
    }
    
    func scheduleChunkRetryTask() {
        let request = BGProcessingTaskRequest(identifier: chunkRetryTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60) // 5 minutes from now
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("BackgroundTaskManager: Scheduled chunk retry task")
        } catch {
            print("BackgroundTaskManager: Failed to schedule chunk retry task: \(error)")
        }
    }
    
    func beginBackgroundTask(name: String = "AudioRecording") -> UIBackgroundTaskIdentifier {
        let taskId = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Task expiration handler
            print("BackgroundTaskManager: Background task \(name) expired")
            self.endBackgroundTask()
        }
        
        if taskId != .invalid {
            backgroundTaskId = taskId
            isBackgroundTaskActive = true
            print("BackgroundTaskManager: Started background task \(name) with ID \(taskId)")
        }
        
        return taskId
    }
    
    func endBackgroundTask() {
        guard isBackgroundTaskActive && backgroundTaskId != .invalid else { return }
        
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
        isBackgroundTaskActive = false
        print("BackgroundTaskManager: Ended background task")
    }
    
    func getRemainingBackgroundTime() -> TimeInterval {
        return UIApplication.shared.backgroundTimeRemaining
    }
    
    // MARK: - Private Methods
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }
    
    @objc private func appDidEnterBackground() {
        print("BackgroundTaskManager: App entered background")
        
        // Start background task to keep audio recording alive
        beginBackgroundTask(name: "AudioRecordingBackground")
        
        // Schedule background tasks for later execution
        scheduleAudioUploadTask()
        scheduleChunkRetryTask()
        
        // Monitor remaining background time
        monitorBackgroundTime()
    }
    
    @objc private func appWillEnterForeground() {
        print("BackgroundTaskManager: App will enter foreground")
        
        // Cancel scheduled background tasks since app is becoming active
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: audioUploadTaskId)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: chunkRetryTaskId)
        
        // End background task
        endBackgroundTask()
    }
    
    @objc private func appWillTerminate() {
        print("BackgroundTaskManager: App will terminate")
        endBackgroundTask()
    }
    
    private func monitorBackgroundTime() {
        guard isBackgroundTaskActive else { return }
        
        let remainingTime = getRemainingBackgroundTime()
        print("BackgroundTaskManager: Remaining background time: \(remainingTime) seconds")
        
        // If we have less than 30 seconds left, prepare for termination
        if remainingTime < 30 {
            print("BackgroundTaskManager: Low background time, preparing for termination")
            
            // Notify audio manager to save state
            NotificationCenter.default.post(name: NSNotification.Name("backgroundTimeExpiring"), object: nil)
            
            // Schedule a final background task
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self.endBackgroundTask()
            }
        } else {
            // Check again in 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                self.monitorBackgroundTime()
            }
        }
    }
    
    private func handleAudioUploadTask(_ task: BGAppRefreshTask) {
        print("BackgroundTaskManager: Handling audio upload background task")
        
        // Schedule next task
        scheduleAudioUploadTask()
        
        // Process pending uploads
        let chunkManager = ChunkManager.shared
        
        task.expirationHandler = {
            print("BackgroundTaskManager: Audio upload task expired")
            task.setTaskCompleted(success: false)
        }
        
        // Perform upload work
        DispatchQueue.global(qos: .utility).async {
            // Process a limited number of chunks to avoid timeout
            let pendingSessions = chunkManager.getPendingSessions()
            
            if pendingSessions.isEmpty {
                print("BackgroundTaskManager: No pending uploads")
                task.setTaskCompleted(success: true)
                return
            }
            
            // Try to upload a few chunks
            print("BackgroundTaskManager: Processing \(pendingSessions.count) pending sessions")
            
            // Simulate processing time (in real implementation, this would trigger actual uploads)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                task.setTaskCompleted(success: true)
            }
        }
    }
    
    private func handleChunkRetryTask(_ task: BGProcessingTask) {
        print("BackgroundTaskManager: Handling chunk retry background task")
        
        // Schedule next task
        scheduleChunkRetryTask()
        
        task.expirationHandler = {
            print("BackgroundTaskManager: Chunk retry task expired")
            task.setTaskCompleted(success: false)
        }
        
        // Retry failed chunks
        DispatchQueue.global(qos: .utility).async {
            let chunkManager = ChunkManager.shared
            chunkManager.retryFailedChunks()
            
            // Allow some time for retries to process
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                task.setTaskCompleted(success: true)
            }
        }
    }
}

