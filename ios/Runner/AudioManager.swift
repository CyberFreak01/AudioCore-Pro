import Foundation
import AVFoundation
import CallKit
import MediaPlayer

class AudioManager: NSObject {
  static let shared = AudioManager()

  private let audioEngine = AVAudioEngine()
  private let processingQueue = DispatchQueue(label: "AudioManager.processing", qos: .userInitiated)
  private var eventSink: FlutterEventSink?

  private var isRecording: Bool = false
  private var isPaused: Bool = false
  private var sessionId: String?
  private var chunkNumber: Int = 0
  private var currentChunkFrames: AVAudioFrameCount = 0
  private var framesPerChunk: AVAudioFrameCount = 0
  private var gain: Float = 1.0
  private var sampleRate: Double = 44100.0
  private var secondsPerChunk: Double = 5.0

  // Level metering
  private var levelTimer: Timer?
  private var lastRMS: Float = -80.0
  private var lastPeak: Int = 0

  // Chunk buffer
  private var fileWriter: AVAudioFile?
  private var currentChunkURL: URL?
  
  // Audio format consistency
  private var recordingFormat: AVAudioFormat?
  private var inputFormat: AVAudioFormat?

  // Enhanced components
  private let chunkManager = ChunkManager.shared
  private let backgroundTaskManager = BackgroundTaskManager.shared
  private let networkMonitor = NetworkMonitor.shared
  
  // Audio session management
  private var isAudioSessionInterrupted = false
  private var wasRecordingBeforeInterruption = false
  
  // Call handling
  private var callObserver: CXCallObserver?
  private var wasRecordingBeforeCall = false
  
  // Route change handling
  private var currentAudioRoute: AVAudioSessionRouteDescription?
  
  // Background recording
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
  
  // Audio buffer for network outages
  private let maxBufferDuration: TimeInterval = 300 // 5 minutes
  
  // Pending queue bookkeeping
  private var lastActiveSessionId: String?
  
  // Audio buffer for network outages
  private var audioBuffer: CircularBuffer<Float>?
  
  // Thread safety
  private let stateLock = NSLock()
  private let bufferLock = NSLock()

  override init() {
    super.init()
    setupAudioSessionNotifications()
    setupCallObserver()
    setupBackgroundNotifications()
    
    // Initialize audio buffer with proper size calculation
    let bufferSize = Int(maxBufferDuration * sampleRate * 2) // Stereo channels
    audioBuffer = CircularBuffer<Float>(capacity: bufferSize)
  }
  
  deinit {
    cleanup()
  }

  func setEventSink(_ sink: FlutterEventSink?) {
    stateLock.lock()
    eventSink = sink
    stateLock.unlock()
  }

  func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    
    do {
      // Configure for background recording with optimal settings
      try session.setCategory(
        .playAndRecord,
        options: [
          .defaultToSpeaker,
          .allowBluetooth,
          .allowBluetoothA2DP,
          .allowAirPlay,
          .mixWithOthers,
          .duckOthers,
          .interruptSpokenAudioAndMixWithOthers
        ]
      )
      
      // Use measurement mode for high-quality recording
      try session.setMode(.measurement)
      
      // Set preferred sample rate and buffer duration
      try session.setPreferredSampleRate(sampleRate)
      try session.setPreferredIOBufferDuration(0.005) // 5ms for low latency
      
      // Store current route for comparison
      currentAudioRoute = session.currentRoute
      
      try session.setActive(true, options: [])
      
      print("AudioManager: Audio session configured - Route: \(session.currentRoute.outputs.first?.portName ?? "Unknown")")
      
    } catch {
      print("AudioManager: Failed to configure audio session: \(error)")
      throw error
    }
  }
  
  // MARK: - Setup Methods
  private func setupAudioSessionNotifications() {
    let notificationCenter = NotificationCenter.default
    
    // Audio session interruption
    notificationCenter.addObserver(
      self,
      selector: #selector(audioSessionInterrupted),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    
    // Audio route change
    notificationCenter.addObserver(
      self,
      selector: #selector(audioRouteChanged),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
    
    // Media services reset
    notificationCenter.addObserver(
      self,
      selector: #selector(mediaServicesReset),
      name: AVAudioSession.mediaServicesWereResetNotification,
      object: nil
    )
  }
  
  private func setupCallObserver() {
    callObserver = CXCallObserver()
    callObserver?.setDelegate(self, queue: nil)
  }
  
  private func setupBackgroundNotifications() {
    let notificationCenter = NotificationCenter.default
    
    notificationCenter.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    
    notificationCenter.addObserver(
      self,
      selector: #selector(appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    
    notificationCenter.addObserver(
      self,
      selector: #selector(backgroundTimeExpiring),
      name: NSNotification.Name("backgroundTimeExpiring"),
      object: nil
    )
    
    notificationCenter.addObserver(
      self,
      selector: #selector(chunkReadyForUpload),
      name: NSNotification.Name("chunkReadyForUpload"),
      object: nil
    )
  }
  
  private func cleanup() {
    stateLock.lock()
    
    // Stop recording if active
    if isRecording {
      stopRecordingInternal()
    }
    
    // Clean up resources
    NotificationCenter.default.removeObserver(self)
    callObserver = nil
    networkMonitor.stopMonitoring()
    
    if backgroundTaskId != .invalid {
      backgroundTaskManager.endBackgroundTask()
      backgroundTaskId = .invalid
    }
    
    // Clean up audio engine
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    
    // Clean up files
    fileWriter = nil
    currentChunkURL = nil
    
    stateLock.unlock()
  }

  func requestPermission(completion: @escaping (Bool) -> Void) {
    AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
      DispatchQueue.main.async {
        completion(granted)
        if granted {
          self?.emitEvent(["type": "permission_granted", "permission": "microphone"])
        } else {
          self?.emitEvent(["type": "permission_denied", "permission": "microphone"])
        }
      }
    }
  }

  func startRecording(sessionId: String, sampleRate: Double = 44100.0, secondsPerChunk: Double = 5.0) throws {
    stateLock.lock()
    defer { stateLock.unlock() }
    
    guard !isRecording else {
      print("AudioManager: Already recording, ignoring start request")
      return
    }

    print("AudioManager: Starting recording session \(sessionId)")
    
    // Store recording parameters
    self.sampleRate = sampleRate
    self.secondsPerChunk = secondsPerChunk
    self.sessionId = sessionId
    self.lastActiveSessionId = sessionId
    self.chunkNumber = 0
    self.currentChunkFrames = 0
    self.framesPerChunk = AVAudioFrameCount(sampleRate * secondsPerChunk)
    self.isPaused = false
    
    do {
      // Configure audio session first
      try configureAudioSession()
      
      // Start background task for continuous recording
      backgroundTaskId = backgroundTaskManager.beginBackgroundTask(name: "AudioRecording")
      
      // Setup audio engine with proper format handling
      let inputNode = audioEngine.inputNode
      inputFormat = inputNode.inputFormat(forBus: 0)
      
      guard let inputFormat = inputFormat else {
        throw NSError(domain: "AudioManager", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Failed to get input format"])
      }
      
      print("AudioManager: Input format - Sample Rate: \(inputFormat.sampleRate), Channels: \(inputFormat.channelCount)")
      
      // Create recording format that matches input
      recordingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: inputFormat.sampleRate,
        channels: inputFormat.channelCount,
        interleaved: false
      )
      
      guard let recordingFormat = recordingFormat else {
        throw NSError(domain: "AudioManager", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Failed to create recording format"])
      }
      
      // Remove any existing tap
      inputNode.removeTap(onBus: 0)
      
      // Install tap with proper buffer size and format matching
      let bufferSize: AVAudioFrameCount = 4096 // Increased buffer size for stability
      
      inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
        guard let self = self else { return }
        
        // Thread-safe state check
        self.stateLock.lock()
        let shouldProcess = self.isRecording && !self.isPaused
        self.stateLock.unlock()
        
        guard shouldProcess else { return }
        
        // Validate buffer
        guard buffer.frameLength > 0, 
              buffer.format.channelCount > 0,
              buffer.floatChannelData != nil else {
          print("AudioManager: Invalid buffer received")
          return
        }
        
        self.processingQueue.async { [weak self] in
          self?.processAudioBuffer(buffer, timestamp: time)
        }
      }
      
      // Start audio engine
      try audioEngine.start()
      
      // Start level monitoring
      startLevelTimer()
      
      // Update state
      isRecording = true
      
      print("AudioManager: Recording started successfully")
      
      // Notify that recording started
      emitEvent(["type": "recording_started", "sessionId": sessionId])
      
    } catch {
      // Cleanup on failure
      isRecording = false
      sessionId = nil
      
      if backgroundTaskId != .invalid {
        backgroundTaskManager.endBackgroundTask()
        backgroundTaskId = .invalid
      }
      
      print("AudioManager: Failed to start recording: \(error)")
      throw error
    }
  }
  
  private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, timestamp: AVAudioTime) {
    // Apply gain and compute levels
    applyGainAndComputeLevels(buffer)
    
    // Store in circular buffer for network outages
    bufferAudioData(buffer)
    
    // Rotate file if needed
    if fileWriter == nil || currentChunkFrames >= framesPerChunk {
      rotateChunkFile()
    }
    
    // Write to file if available
    guard let fileWriter = fileWriter else {
      print("AudioManager: No file writer available")
      return
    }
    
    do {
      try fileWriter.write(from: buffer)
      currentChunkFrames += buffer.frameLength
      
      // Check if chunk is complete
      if currentChunkFrames >= framesPerChunk {
        finishCurrentChunkAndEmit()
      }
    } catch {
      print("AudioManager: Error writing audio data: \(error)")
      // Continue recording even if file write fails
    }
  }

  func pauseRecording() {
    stateLock.lock()
    defer { stateLock.unlock() }
    
    guard isRecording, !isPaused else { return }
    
    isPaused = true
    stopLevelTimer()
    
    print("AudioManager: Recording paused")
    emitEvent(["type": "recording_paused"])
  }

  func resumeRecording() {
    stateLock.lock()
    defer { stateLock.unlock() }
    
    guard isRecording, isPaused else { return }
    
    isPaused = false
    startLevelTimer()
    
    print("AudioManager: Recording resumed")
    emitEvent(["type": "recording_resumed"])
  }

  func stopRecording() {
    stateLock.lock()
    defer { stateLock.unlock() }
    
    stopRecordingInternal()
  }
  
  private func stopRecordingInternal() {
    guard isRecording else { return }
    
    print("AudioManager: Stopping recording session \(sessionId ?? "unknown")")
    
    // Stop audio processing
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    
    // Update state
    isRecording = false
    isPaused = false
    
    // Stop level monitoring
    stopLevelTimer()

    // Flush last chunk
    if fileWriter != nil && currentChunkFrames > 0 {
      finishCurrentChunkAndEmit()
    }
    
    // Clean up file writer
    fileWriter = nil
    currentChunkURL = nil
    
    // End background task
    if backgroundTaskId != .invalid {
      backgroundTaskManager.endBackgroundTask()
      backgroundTaskId = .invalid
    }

    // Emit stop event
    let totalChunks = chunkNumber
    let stoppedSessionId = sessionId ?? ""
    
    emitEvent([
      "type": "recording_stopped", 
      "totalChunks": totalChunks, 
      "sessionId": stoppedSessionId
    ])
    
    // Clear session
    sessionId = nil
    chunkNumber = 0
    currentChunkFrames = 0
  }

  func setGain(_ value: Double) {
    stateLock.lock()
    gain = Float(max(0.1, min(5.0, value)))
    stateLock.unlock()
  }

  func getGain() -> Double { 
    stateLock.lock()
    let currentGain = Double(gain)
    stateLock.unlock()
    return currentGain
  }
  
  // Expose recording state for external access
  var isCurrentlyRecording: Bool { 
    stateLock.lock()
    let recording = isRecording
    stateLock.unlock()
    return recording
  }
  
  var isCurrentlyPaused: Bool { 
    stateLock.lock()
    let paused = isPaused
    stateLock.unlock()
    return paused
  }

  // Pending queue management
  func listPendingSessions() -> [[String: Any]] { 
    return chunkManager.getPendingSessions()
  }
  
  func rescanPending(sessionId: String) { 
    chunkManager.retryFailedChunks(sessionId: sessionId)
  }
  
  func markChunkUploaded(sessionId: String, chunkNumber: Int) { 
    chunkManager.markChunkUploaded(sessionId: sessionId, chunkNumber: chunkNumber)
  }
  
  func getLastActiveSessionId() -> String? { 
    stateLock.lock()
    let lastSession = lastActiveSessionId
    stateLock.unlock()
    return lastSession
  }
  
  func clearLastActiveSession() { 
    stateLock.lock()
    lastActiveSessionId = nil
    stateLock.unlock()
  }

  // MARK: - Helpers
  private func documentsTempURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
    return dir
  }

  private func rotateChunkFile() {
    // Close current file
    fileWriter = nil
    currentChunkFrames = 0
    
    // Create new file
    let fileName = "chunk_\(chunkNumber).wav"
    let url = documentsTempURL().appendingPathComponent(fileName)
    currentChunkURL = url
    
    guard let recordingFormat = recordingFormat else {
      print("AudioManager: No recording format available")
      return
    }
    
    do {
      fileWriter = try AVAudioFile(forWriting: url, settings: recordingFormat.settings)
      print("AudioManager: Created new chunk file: \(fileName)")
    } catch {
      print("AudioManager: Failed to create audio file: \(error)")
      fileWriter = nil
    }
  }

  private func finishCurrentChunkAndEmit() {
    guard let url = currentChunkURL, 
          let sid = sessionId else { 
      print("AudioManager: Cannot finish chunk - missing URL or session ID")
      return 
    }
    
    // Close file
    fileWriter = nil
    let finalFrames = currentChunkFrames
    currentChunkFrames = 0
    
    // Calculate duration
    let duration = Double(finalFrames) / sampleRate
    
    print("AudioManager: Finished chunk \(chunkNumber) with \(finalFrames) frames, duration: \(duration)s")
    
    // Create chunk and add to manager
    let chunk = AudioChunk(
      sessionId: sid,
      chunkNumber: chunkNumber,
      filePath: url.path,
      sampleRate: sampleRate,
      duration: duration
    )
    
    chunkManager.addChunk(chunk)
    
    // Emit event for immediate processing
    emitEvent([
      "type": "chunk_ready",
      "sessionId": sid,
      "chunkNumber": chunkNumber,
      "filePath": url.path,
      "checksum": chunk.checksum,
      "fileSize": chunk.fileSize,
      "duration": duration
    ])

    chunkNumber += 1
    currentChunkURL = nil
  }

  private func startLevelTimer() {
    DispatchQueue.main.async { [weak self] in
      self?.levelTimer?.invalidate()
      self?.levelTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
        guard let self = self else { return }
        
        self.stateLock.lock()
        let rms = self.lastRMS
        let peak = self.lastPeak
        let recording = self.isRecording && !self.isPaused
        self.stateLock.unlock()
        
        if recording {
          self.emitEvent(["type": "audio_level", "rmsDb": rms, "peak": peak])
        }
      }
    }
  }

  private func stopLevelTimer() {
    DispatchQueue.main.async { [weak self] in
      self?.levelTimer?.invalidate()
      self?.levelTimer = nil
    }
  }

  private func applyGainAndComputeLevels(_ buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.floatChannelData else { return }
    
    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    
    // Safety checks
    guard frameLength > 0 && channelCount > 0 else { return }
    
    var peak: Float = 0
    var sumSquares: Float = 0
    let gainValue = gain
    let totalSamples = frameLength * channelCount

    // Process each channel
    for ch in 0..<channelCount {
      let ptr = channelData[ch]
      
      for i in 0..<frameLength {
        // Apply gain with proper bounds checking
        let originalSample = ptr[i]
        let amplifiedSample = originalSample * gainValue
        let clippedSample = max(-1.0, min(1.0, amplifiedSample))
        
        // Write back the processed sample
        ptr[i] = clippedSample
        
        // Calculate levels
        let absValue = abs(clippedSample)
        if absValue > peak {
          peak = absValue
        }
        
        sumSquares += clippedSample * clippedSample
      }
    }
    
    // Calculate RMS with proper handling of edge cases
    let meanSquare = totalSamples > 0 ? sumSquares / Float(totalSamples) : 0.0
    let rms = sqrtf(max(meanSquare, 1e-10)) // Prevent log of zero
    
    // Update levels (thread-safe)
    stateLock.lock()
    lastRMS = 20.0 * log10f(max(rms, 1e-6))
    lastPeak = Int(peak * 32767.0) // Convert to int16 equivalent
    stateLock.unlock()
  }
  
  private func bufferAudioData(_ buffer: AVAudioPCMBuffer) {
    bufferLock.lock()
    defer { bufferLock.unlock() }
    
    guard let channelData = buffer.floatChannelData else { return }
    
    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    
    // Safety check
    guard frameLength > 0 && channelCount > 0 else { return }
    
    // Store interleaved audio data in circular buffer
    for frame in 0..<frameLength {
      for channel in 0..<channelCount {
        let sample = channelData[channel][frame]
        audioBuffer?.write(sample)
      }
    }
  }
  
  private func emitEvent(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(event)
    }
  }
  
  // MARK: - Notification Handlers
  @objc private func audioSessionInterrupted(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
      return
    }
    
    switch type {
    case .began:
      print("AudioManager: Audio session interrupted")
      
      stateLock.lock()
      isAudioSessionInterrupted = true
      wasRecordingBeforeInterruption = isRecording
      stateLock.unlock()
      
      if wasRecordingBeforeInterruption {
        pauseRecording()
        emitEvent(["type": "recording_interrupted", "reason": "audio_session"])
      }
      
    case .ended:
      print("AudioManager: Audio session interruption ended")
      
      stateLock.lock()
      isAudioSessionInterrupted = false
      let shouldResume = wasRecordingBeforeInterruption
      stateLock.unlock()
      
      if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        if options.contains(.shouldResume) && shouldResume {
          // Attempt to resume recording after a short delay
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            do {
              try self?.configureAudioSession()
              self?.resumeRecording()
              self?.emitEvent(["type": "recording_resumed", "reason": "interruption_ended"])
            } catch {
              print("AudioManager: Failed to resume after interruption: \(error)")
              self?.emitEvent(["type": "recording_error", "error": error.localizedDescription])
            }
          }
        }
      }
      
    @unknown default:
      break
    }
  }
  
  @objc private func audioRouteChanged(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
      return
    }
    
    let session = AVAudioSession.sharedInstance()
    let newRoute = session.currentRoute
    
    print("AudioManager: Audio route changed - Reason: \(reason), New route: \(newRoute.outputs.first?.portName ?? "Unknown")")
    
    switch reason {
    case .newDeviceAvailable:
      // New audio device connected (e.g., Bluetooth headset)
      print("AudioManager: New audio device available: \(newRoute.outputs.first?.portName ?? "Unknown")")
      emitEvent([
        "type": "audio_route_changed", 
        "reason": "device_connected", 
        "device": newRoute.outputs.first?.portName ?? "Unknown"
      ])
      
    case .oldDeviceUnavailable:
      // Audio device disconnected
      if let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
        print("AudioManager: Audio device disconnected: \(previousRoute.outputs.first?.portName ?? "Unknown")")
        emitEvent([
          "type": "audio_route_changed", 
          "reason": "device_disconnected", 
          "device": previousRoute.outputs.first?.portName ?? "Unknown"
        ])
      }
      
    case .categoryChange, .override:
      // Route changed due to category or override
      emitEvent([
        "type": "audio_route_changed", 
        "reason": "category_change", 
        "device": newRoute.outputs.first?.portName ?? "Unknown"
      ])
      
    default:
      break
    }
    
    currentAudioRoute = newRoute
  }
  
  @objc private func mediaServicesReset(_ notification: Notification) {
    print("AudioManager: Media services reset")
    
    // Stop current recording
    stateLock.lock()
    let wasRecording = isRecording
    stateLock.unlock()
    
    if wasRecording {
      stopRecording()
      emitEvent(["type": "recording_stopped", "reason": "media_services_reset"])
    }
    
    // Reinitialize audio engine after a delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      do {
        try self?.configureAudioSession()
        self?.emitEvent(["type": "audio_system_recovered"])
      } catch {
        print("AudioManager: Failed to recover audio system: \(error)")
        self?.emitEvent(["type": "audio_system_error", "error": error.localizedDescription])
      }
    }
  }
  
  @objc private func appDidEnterBackground(_ notification: Notification) {
    stateLock.lock()
    let recording = isRecording
    stateLock.unlock()
    
    print("AudioManager: App entered background, recording: \(recording)")
    
    if recording {
      emitEvent(["type": "background_recording_active"])
    }
  }
  
  @objc private func appWillEnterForeground(_ notification: Notification) {
    stateLock.lock()
    let recording = isRecording
    stateLock.unlock()
    
    print("AudioManager: App will enter foreground, recording: \(recording)")
    
    if recording {
      // Verify audio session is still active
      do {
        try configureAudioSession()
        emitEvent(["type": "foreground_recording_resumed"])
      } catch {
        print("AudioManager: Failed to restore audio session: \(error)")
        emitEvent(["type": "recording_error", "error": error.localizedDescription])
      }
    }
  }
  
  @objc private func backgroundTimeExpiring(_ notification: Notification) {
    print("AudioManager: Background time expiring")
    
    stateLock.lock()
    let recording = isRecording
    stateLock.unlock()
    
    if recording {
      emitEvent(["type": "background_time_expiring"])
      
      // Flush current chunk
      if fileWriter != nil && currentChunkFrames > 0 {
        finishCurrentChunkAndEmit()
      }
    }
  }
  
  @objc private func chunkReadyForUpload(_ notification: Notification) {
    guard let userInfo = notification.userInfo else { return }
    
    // Forward chunk ready notification to Flutter
    emitEvent([
      "type": "chunk_upload_ready",
      "sessionId": userInfo["sessionId"] as? String ?? "",
      "chunkNumber": userInfo["chunkNumber"] as? Int ?? 0,
      "filePath": userInfo["filePath"] as? String ?? "",
      "checksum": userInfo["checksum"] as? String ?? "",
      "fileSize": userInfo["fileSize"] as? Int64 ?? 0,
      "retryCount": userInfo["retryCount"] as? Int ?? 0
    ])
  }
}

// MARK: - CXCallObserverDelegate
extension AudioManager: CXCallObserverDelegate {
  func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
    print("AudioManager: Call state changed - Outgoing: \(call.isOutgoing), On hold: \(call.isOnHold), Connected: \(call.hasConnected), Ended: \(call.hasEnded)")
    
    if call.hasConnected && !call.hasEnded {
      // Call started
      print("AudioManager: Phone call started")
      
      stateLock.lock()
      wasRecordingBeforeCall = isRecording
      stateLock.unlock()
      
      if wasRecordingBeforeCall {
        pauseRecording()
        emitEvent(["type": "recording_paused", "reason": "phone_call"])
      }
      
    } else if call.hasEnded {
      // Call ended
      print("AudioManager: Phone call ended")
      
      stateLock.lock()
      let shouldResume = wasRecordingBeforeCall
      wasRecordingBeforeCall = false
      stateLock.unlock()
      
      if shouldResume {
        print("AudioManager: Resuming recording after call")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
          do {
            try self?.configureAudioSession()
            self?.resumeRecording()
            self?.emitEvent(["type": "recording_resumed", "reason": "call_ended"])
          } catch {
            print("AudioManager: Failed to resume recording after call: \(error)")
            self?.emitEvent(["type": "recording_error", "error": error.localizedDescription])
          }
        }
      }
    }
  }
}

// MARK: - CircularBuffer (Thread-Safe Version)
class CircularBuffer<T> {
  private var buffer: [T?]
  private var head = 0
  private var tail = 0
  private var count = 0
  private let capacity: Int
  private let lock = NSLock()
  
  init(capacity: Int) {
    self.capacity = capacity
    self.buffer = Array<T?>(repeating: nil, count: capacity)
  }
  
  func write(_ element: T) {
    lock.lock()
    defer { lock.unlock() }
    
    buffer[tail] = element
    tail = (tail + 1) % capacity
    
    if count < capacity {
      count += 1
    } else {
      head = (head + 1) % capacity
    }
  }
  
  func read() -> T? {
    lock.lock()
    defer { lock.unlock() }
    
    guard count > 0 else { return nil }
    
    let element = buffer[head]
    buffer[head] = nil
    head = (head + 1) % capacity
    count -= 1
    
    return element
  }
  
  func isEmpty() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return count == 0
  }
  
  func isFull() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return count == capacity
  }
  
  func clear() {
    lock.lock()
    defer { lock.unlock() }
    
    for i in 0..<capacity {
      buffer[i] = nil
    }
    head = 0
    tail = 0
    count = 0
  }
  
  func availableSpace() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return capacity - count
  }
  
  func currentCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}