import Foundation
import AVFoundation

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

  // Level metering
  private var levelTimer: Timer?
  private var lastRMS: Float = 0
  private var lastPeak: Int = 0

  // Chunk buffer
  private var fileWriter: AVAudioFile?
  private var currentChunkURL: URL?

  // Pending queue bookkeeping (placeholders to satisfy Flutter calls)
  private var lastActiveSessionId: String?

  func setEventSink(_ sink: FlutterEventSink?) {
    eventSink = sink
  }

  func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
    try session.setMode(.measurement)
    try session.setActive(true, options: [])
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

    try configureAudioSession()

    self.sessionId = sessionId
    self.lastActiveSessionId = sessionId
    self.chunkNumber = 0
    self.currentChunkFrames = 0
    self.framesPerChunk = AVAudioFrameCount(sampleRate * secondsPerChunk)
    self.isPaused = false

    let input = audioEngine.inputNode
    let format = input.inputFormat(forBus: 0)
    let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: format.channelCount, interleaved: true)!

    let converter = AVAudioConverter(from: format, to: desiredFormat)!

    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, time in
      guard let self = self, self.isRecording, !self.isPaused else { return }

      self.processingQueue.async {
        let frameCapacity = AVAudioFrameCount(self.framesPerChunk - self.currentChunkFrames)
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: buffer.frameLength)!
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
          outStatus.pointee = .haveData
          return buffer
        }
        converter.convert(to: pcmBuffer, error: &error, withInputFrom: inputBlock)
        if let _ = error { return }

        // Apply gain and compute levels
        self.applyGainAndLevels(pcmBuffer)

        // Rotate file if needed
        if self.fileWriter == nil || self.currentChunkFrames >= self.framesPerChunk {
          self.rotateChunkFile()
        }

        do {
          try self.fileWriter?.write(from: pcmBuffer)
          self.currentChunkFrames += pcmBuffer.frameLength
          if self.currentChunkFrames >= self.framesPerChunk {
            self.finishCurrentChunkAndEmit()
          }
        } catch {
          // Ignore write errors for now
        }
      }
    }

    try audioEngine.start()
    startLevelTimer()
    isRecording = true
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
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    isRecording = false
    isPaused = false
    stopLevelTimer()

    // Flush last chunk
    if fileWriter != nil && currentChunkFrames > 0 {
      finishCurrentChunkAndEmit()
    }

    eventSink?(["type": "recording_stopped", "totalChunks": chunkNumber])
    sessionId = nil
  }

  func setGain(_ value: Double) {
    gain = Float(max(0.1, min(5.0, value)))
  }

  func getGain() -> Double { Double(gain) }

  // Pending queue placeholders
  func listPendingSessions() -> [[String: Any]] { return [] }
  func rescanPending(sessionId: String) { /* no-op for now */ }
  func markChunkUploaded(sessionId: String, chunkNumber: Int) { /* no-op for now */ }
  func getLastActiveSessionId() -> String? { return lastActiveSessionId }
  func clearLastActiveSession() { lastActiveSessionId = nil }

  // MARK: - Helpers
  private func documentsTempURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
    return dir
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
    currentChunkFrames = 0

    // Emit event
    eventSink?([
      "type": "chunk_ready",
      "sessionId": sid,
      "chunkNumber": chunkNumber,
      "filePath": url.path
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

  private func applyGainAndLevels(_ buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.int16ChannelData else { return }
    let frameLength = Int(buffer.frameLength)
    var peak: Int16 = 0
    var sumSquares: Float = 0
    let gainValue = gain

    for ch in 0..<Int(buffer.format.channelCount) {
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
    let meanSquare = sumSquares / Float(frameLength)
    let rms = sqrtf(meanSquare)
    lastRMS = 20.0 * log10f(max(rms, 1e-6))
    lastPeak = Int(peak)
  }
}


