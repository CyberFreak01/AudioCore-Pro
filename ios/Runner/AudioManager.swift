import Foundation
import AVFoundation
import CallKit
import MediaPlayer

class AudioManager: NSObject {
  static let shared = AudioManager()

  private let audioEngine = AVAudioEngine()
  private let processingQueue = DispatchQueue(label: "AudioManager.processing")
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
  private var lastRMS: Float = 0
  private var lastPeak: Int = 0

  // Chunk buffer
  private var fileWriter: AVAudioFile?
  private var currentChunkURL: URL?

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

  override init() {
    super.init()
    setupAudioSessionNotifications()
    setupCallObserver()
    setupBackgroundNotifications()
    
    // Initialize audio buffer
    let bufferSize = Int(maxBufferDuration * sampleRate)
    audioBuffer = CircularBuffer<Float>(capacity: bufferSize)
  }
  
  deinit {
    cleanup()
  }

  func setEventSink(_ sink: FlutterEventSink?) {
    eventSink = sink
  }

  func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    
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
    NotificationCenter.default.removeObserver(self)
    callObserver = nil
    networkMonitor.stopMonitoring()
    
    if backgroundTaskId != .invalid {
      backgroundTaskManager.endBackgroundTask()
    }
  }

  func requestPermission(completion: @escaping (Bool) -> Void) {
    AVAudioSession.sharedInstance().requestRecordPermission { granted in
      completion(granted)
      if granted {
        self.eventSink?(["type": "permission_granted", "permission": "microphone"]) 
      }
    }
  }

  func startRecording(sessionId: String, sampleRate: Double = 44100.0, secondsPerChunk: Double = 5.0) throws {
    if isRecording { return }

    // Store recording parameters
    self.sampleRate = sampleRate
    self.secondsPerChunk = secondsPerChunk
    
    try configureAudioSession()

    self.sessionId = sessionId
    self.lastActiveSessionId = sessionId
    self.chunkNumber = 0
    self.currentChunkFrames = 0
    self.framesPerChunk = AVAudioFrameCount(sampleRate * secondsPerChunk)
    self.isPaused = false
    
    // Start background task for continuous recording
    backgroundTaskId = backgroundTaskManager.beginBackgroundTask(name: "AudioRecording")

    let input = audioEngine.inputNode
    let format = input.inputFormat(forBus: 0)
    
    // Use the input format directly to avoid conversion issues
    let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, 
                                       sampleRate: format.sampleRate, 
                                       channels: format.channelCount, 
                                       interleaved: false)!

    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
      guard let self = self, self.isRecording, !self.isPaused else { return }

      self.processingQueue.async {
        // Work directly with the input buffer to avoid conversion issues
        guard buffer.frameLength > 0 else {
          print("AudioManager: Input buffer has no frames")
          return
        }

        // Apply gain and compute levels directly on input buffer
        self.applyGainAndLevelsFloat(buffer)
        
        // Store in circular buffer for network outages
        self.bufferAudioDataFloat(buffer)

        // Rotate file if needed
        if self.fileWriter == nil || self.currentChunkFrames >= self.framesPerChunk {
          self.rotateChunkFileFloat(format: recordingFormat)
        }

        do {
          try self.fileWriter?.write(from: buffer)
          self.currentChunkFrames += buffer.frameLength
          if self.currentChunkFrames >= self.framesPerChunk {
            self.finishCurrentChunkAndEmit()
          }
        } catch {
          print("AudioManager: Error writing audio data: \(error)")
          // Continue recording even if file write fails
        }
      }
    }

    try audioEngine.start()
    startLevelTimer()
    isRecording = true
    
    print("AudioManager: Started recording session \(sessionId) at \(sampleRate)Hz")
    
    // Notify that recording started
    eventSink?(["type": "recording_started", "sessionId": sessionId])
  }

  func pauseRecording() {
    guard isRecording, !isPaused else { return }
    isPaused = true
    stopLevelTimer()
  }

  func resumeRecording() {
    guard isRecording, isPaused else { return }
    isPaused = false
    startLevelTimer()
  }

  func stopRecording() {
    guard isRecording else { return }
    
    print("AudioManager: Stopping recording session \(sessionId ?? "unknown")")
    
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    isRecording = false
    isPaused = false
    stopLevelTimer()

    // Flush last chunk
    if fileWriter != nil && currentChunkFrames > 0 {
      finishCurrentChunkAndEmit()
    }
    
    // End background task
    if backgroundTaskId != .invalid {
      backgroundTaskManager.endBackgroundTask()
      backgroundTaskId = .invalid
    }

    eventSink?(["type": "recording_stopped", "totalChunks": chunkNumber, "sessionId": sessionId ?? ""])
    sessionId = nil
  }

  func setGain(_ value: Double) {
    gain = Float(max(0.1, min(5.0, value)))
  }

  func getGain() -> Double { Double(gain) }
  
  // Expose recording state for external access
  var isCurrentlyRecording: Bool { return isRecording }
  var isCurrentlyPaused: Bool { return isPaused }

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
  
  func getLastActiveSessionId() -> String? { return lastActiveSessionId }
  func clearLastActiveSession() { lastActiveSessionId = nil }

  // MARK: - Helpers
  private func documentsTempURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
    return dir
  }

  private func rotateChunkFileFloat(format: AVAudioFormat) {
    fileWriter = nil
    currentChunkFrames = 0
    let fileName = "chunk_\(chunkNumber).wav"
    let url = documentsTempURL().appendingPathComponent(fileName)
    currentChunkURL = url
    do {
      fileWriter = try AVAudioFile(forWriting: url, settings: format.settings)
    } catch {
      print("AudioManager: Failed to create audio file: \(error)")
      fileWriter = nil
    }
  }
  
  private func rotateChunkFile() {
    fileWriter = nil
    currentChunkFrames = 0
    let fileName = "chunk_\(chunkNumber).wav"
    let url = documentsTempURL().appendingPathComponent(fileName)
    currentChunkURL = url
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true)!
    do {
      fileWriter = try AVAudioFile(forWriting: url, settings: format.settings)
    } catch {
      fileWriter = nil
    }
  }

  private func finishCurrentChunkAndEmit() {
    guard let url = currentChunkURL, let sid = sessionId else { return }
    
    // Close file
    fileWriter = nil
    let finalFrames = currentChunkFrames
    currentChunkFrames = 0
    
    // Calculate duration
    let duration = Double(finalFrames) / sampleRate
    
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
    eventSink?([
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
    DispatchQueue.main.async {
      self.levelTimer?.invalidate()
      self.levelTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
        guard let self = self else { return }
        self.eventSink?(["type": "audio_level", "rmsDb": self.lastRMS, "peak": self.lastPeak])
      }
    }
  }

  private func stopLevelTimer() {
    DispatchQueue.main.async {
      self.levelTimer?.invalidate()
      self.levelTimer = nil
    }
  }

  private func applyGainAndLevelsFloat(_ buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.floatChannelData else { return }
    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    
    // Safety check - ensure we don't exceed buffer capacity
    guard frameLength > 0 && channelCount > 0 else { return }
    
    var peak: Float = 0
    var sumSquares: Float = 0
    let gainValue = gain

    for ch in 0..<channelCount {
      let ptr = channelData[ch]
      for i in 0..<frameLength {
        let sample = ptr[i] * gainValue
        let clipped = max(-1.0, min(1.0, sample))
        ptr[i] = clipped
        let absVal = abs(clipped)
        if absVal > peak { peak = absVal }
        sumSquares += clipped * clipped
      }
    }
    
    // Avoid division by zero
    let meanSquare = frameLength > 0 ? sumSquares / Float(frameLength * channelCount) : 0
    let rms = sqrtf(meanSquare)
    lastRMS = 20.0 * log10f(max(rms, 1e-6))
    lastPeak = Int(peak * 32767.0) // Convert to int16 equivalent for display
  }
  
  private func applyGainAndLevels(_ buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.int16ChannelData else { return }
    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    
    // Safety check - ensure we don't exceed buffer capacity
    guard frameLength > 0 && channelCount > 0 else { return }
    
    var peak: Int16 = 0
    var sumSquares: Float = 0
    let gainValue = gain

    for ch in 0..<channelCount {
      let ptr = channelData[ch]
      for i in 0..<frameLength {
        let sample = Float(ptr[i]) * gainValue
        let clipped = max(-32768.0, min(32767.0, sample))
        let s16 = Int16(clipped)
        ptr[i] = s16
        let absVal = abs(s16)
        if absVal > peak { peak = absVal }
        let norm = Float(s16) / 32768.0
        sumSquares += norm * norm
      }
    }
    
    // Avoid division by zero
    let meanSquare = frameLength > 0 ? sumSquares / Float(frameLength * channelCount) : 0
    let rms = sqrtf(meanSquare)
    lastRMS = 20.0 * log10f(max(rms, 1e-6))
    lastPeak = Int(peak)
  }
  
  private func bufferAudioDataFloat(_ buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.floatChannelData else { return }
    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    
    // Safety check - ensure we have valid data
    guard frameLength > 0 && channelCount > 0 else { return }
    
    // Store interleaved audio data in circular buffer
    for frame in 0..<frameLength {
      for channel in 0..<channelCount {
        let sample = channelData[channel][frame]
        audioBuffer?.write(sample)
      }
    }
  }
  
  private func bufferAudioData(_ buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.floatChannelData else { return }
    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    
    // Safety check - ensure we have valid data
    guard frameLength > 0 && channelCount > 0 else { return }
    
    // Store interleaved audio data in circular buffer
    for frame in 0..<frameLength {
      for channel in 0..<channelCount {
        let sample = channelData[channel][frame]
        audioBuffer?.write(sample)
      }
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
      isAudioSessionInterrupted = true
      wasRecordingBeforeInterruption = isRecording
      
      if isRecording {
        pauseRecording()
        eventSink?(["type": "recording_interrupted", "reason": "audio_session"])
      }
      
    case .ended:
      print("AudioManager: Audio session interruption ended")
      isAudioSessionInterrupted = false
      
      if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        if options.contains(.shouldResume) && wasRecordingBeforeInterruption {
          // Attempt to resume recording
          do {
            try configureAudioSession()
            resumeRecording()
            eventSink?(["type": "recording_resumed", "reason": "interruption_ended"])
          } catch {
            print("AudioManager: Failed to resume after interruption: \(error)")
            eventSink?(["type": "recording_error", "error": error.localizedDescription])
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
      eventSink?(["type": "audio_route_changed", "reason": "device_connected", "device": newRoute.outputs.first?.portName ?? "Unknown"])
      
    case .oldDeviceUnavailable:
      // Audio device disconnected
      if let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
        print("AudioManager: Audio device disconnected: \(previousRoute.outputs.first?.portName ?? "Unknown")")
        eventSink?(["type": "audio_route_changed", "reason": "device_disconnected", "device": previousRoute.outputs.first?.portName ?? "Unknown"])
      }
      
    case .categoryChange, .override:
      // Route changed due to category or override
      eventSink?(["type": "audio_route_changed", "reason": "category_change", "device": newRoute.outputs.first?.portName ?? "Unknown"])
      
    default:
      break
    }
    
    currentAudioRoute = newRoute
  }
  
  @objc private func mediaServicesReset(_ notification: Notification) {
    print("AudioManager: Media services reset")
    
    // Stop current recording
    if isRecording {
      stopRecording()
      eventSink?(["type": "recording_stopped", "reason": "media_services_reset"])
    }
    
    // Reinitialize audio engine
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      do {
        try self.configureAudioSession()
        self.eventSink?(["type": "audio_system_recovered"])
      } catch {
        print("AudioManager: Failed to recover audio system: \(error)")
        self.eventSink?(["type": "audio_system_error", "error": error.localizedDescription])
      }
    }
  }
  
  @objc private func appDidEnterBackground(_ notification: Notification) {
    print("AudioManager: App entered background, recording: \(isRecording)")
    
    if isRecording {
      // Continue recording in background
      eventSink?(["type": "background_recording_active"])
    }
  }
  
  @objc private func appWillEnterForeground(_ notification: Notification) {
    print("AudioManager: App will enter foreground, recording: \(isRecording)")
    
    if isRecording {
      // Verify audio session is still active
      do {
        try configureAudioSession()
        eventSink?(["type": "foreground_recording_resumed"])
      } catch {
        print("AudioManager: Failed to restore audio session: \(error)")
        eventSink?(["type": "recording_error", "error": error.localizedDescription])
      }
    }
  }
  
  @objc private func backgroundTimeExpiring(_ notification: Notification) {
    print("AudioManager: Background time expiring")
    
    if isRecording {
      // Save current state and prepare for termination
      eventSink?(["type": "background_time_expiring"])
      
      // Flush current chunk
      if fileWriter != nil && currentChunkFrames > 0 {
        finishCurrentChunkAndEmit()
      }
    }
  }
  
  @objc private func chunkReadyForUpload(_ notification: Notification) {
    guard let userInfo = notification.userInfo else { return }
    
    // Forward chunk ready notification to Flutter
    eventSink?([
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
    print("AudioManager: Call state changed - Active: \(call.isOutgoing), On hold: \(call.isOnHold), Ended: \(call.hasEnded)")
    
    if call.hasConnected && !call.hasEnded {
      // Call started
      print("AudioManager: Phone call started")
      wasRecordingBeforeCall = isRecording
      
      if isRecording {
        pauseRecording()
        eventSink?(["type": "recording_paused", "reason": "phone_call"])
      }
      
    } else if call.hasEnded && wasRecordingBeforeCall {
      // Call ended, resume recording if it was active before
      print("AudioManager: Phone call ended, resuming recording")
      
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        do {
          try self.configureAudioSession()
          self.resumeRecording()
          self.eventSink?(["type": "recording_resumed", "reason": "call_ended"])
        } catch {
          print("AudioManager: Failed to resume recording after call: \(error)")
          self.eventSink?(["type": "recording_error", "error": error.localizedDescription])
        }
      }
      
      wasRecordingBeforeCall = false
    }
  }
}

// MARK: - CircularBuffer
class CircularBuffer<T> {
  private var buffer: [T?]
  private var head = 0
  private var tail = 0
  private var count = 0
  private let capacity: Int
  
  init(capacity: Int) {
    self.capacity = capacity
    self.buffer = Array<T?>(repeating: nil, count: capacity)
  }
  
  func write(_ element: T) {
    buffer[tail] = element
    tail = (tail + 1) % capacity
    
    if count < capacity {
      count += 1
    } else {
      head = (head + 1) % capacity
    }
  }
  
  func read() -> T? {
    guard count > 0 else { return nil }
    
    let element = buffer[head]
    buffer[head] = nil
    head = (head + 1) % capacity
    count -= 1
    
    return element
  }
  
  func isEmpty() -> Bool {
    return count == 0
  }
  
  func isFull() -> Bool {
    return count == capacity
  }
  
  func clear() {
    for i in 0..<capacity {
      buffer[i] = nil
    }
    head = 0
    tail = 0
    count = 0
  }
}


