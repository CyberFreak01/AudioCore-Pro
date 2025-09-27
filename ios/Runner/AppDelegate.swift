import Flutter
import UIKit
import AVFoundation
import BackgroundTasks

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var eventSink: FlutterEventSink?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    print("AppDelegate: Starting application launch")
    print("AppDelegate: Flutter framework available: \(FlutterEngine.self)")
    
    // Register background tasks before anything else
    BackgroundTaskManager.shared.registerBackgroundTasks()
    
    GeneratedPluginRegistrant.register(with: self)
    print("AppDelegate: Plugin registrant registered")
    
    // Initialize Flutter engine first
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    print("AppDelegate: Super application call completed, result: \(result)")
    
    // Add a small delay to ensure Flutter engine is fully initialized
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      self.setupPlatformChannels()
    }
    
    return result
  }
  
  private func setupPlatformChannels() {
    print("AppDelegate: Setting up platform channels")
    
    // Setup platform channels after Flutter is initialized
    guard let controller = window?.rootViewController as? FlutterViewController else {
      print("AppDelegate: Failed to get FlutterViewController")
      print("AppDelegate: Window: \(String(describing: window))")
      print("AppDelegate: RootViewController: \(String(describing: window?.rootViewController))")
      return
    }
    print("AppDelegate: Successfully got FlutterViewController")

    let methodChannel = FlutterMethodChannel(name: "medical_transcription/audio",
                                             binaryMessenger: controller.binaryMessenger)
    methodChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let _ = self else { return }
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "startRecording":
        guard let sessionId = args?["sessionId"] as? String,
              let sampleRate = args?["sampleRate"] as? Double else {
          result(FlutterError(code: "ARG_ERROR", message: "Missing args", details: nil))
          return
        }
        do {
          try AudioManager.shared.startRecording(sessionId: sessionId, sampleRate: sampleRate)
          result(true)
        } catch {
          result(FlutterError(code: "START_ERROR", message: error.localizedDescription, details: nil))
        }
      case "stopRecording":
        AudioManager.shared.stopRecording()
        result(true)
      case "pauseRecording":
        AudioManager.shared.pauseRecording()
        result(true)
      case "resumeRecording":
        AudioManager.shared.resumeRecording()
        result(true)
      case "setGain":
        let gain = args?["gain"] as? Double ?? 1.0
        AudioManager.shared.setGain(gain)
        result(true)
      case "getGain":
        result(AudioManager.shared.getGain())
      case "listPendingSessions":
        result(AudioManager.shared.listPendingSessions())
      case "rescanPending":
        if let sid = args?["sessionId"] as? String { AudioManager.shared.rescanPending(sessionId: sid) }
        result(true)
      case "markChunkUploaded":
        if let sid = args?["sessionId"] as? String, let num = args?["chunkNumber"] as? Int { AudioManager.shared.markChunkUploaded(sessionId: sid, chunkNumber: num) }
        result(true)
      case "getLastActiveSessionId":
        result(AudioManager.shared.getLastActiveSessionId())
      case "clearLastActiveSession":
        AudioManager.shared.clearLastActiveSession()
        result(true)
      case "getNetworkInfo":
        let networkMonitor = NetworkMonitor()
        result(networkMonitor.getNetworkInfo())
      case "retryFailedChunks":
        let sessionId = args?["sessionId"] as? String
        AudioManager.shared.rescanPending(sessionId: sessionId ?? "")
        result(true)
      case "getQueueStats":
        let chunkManager = ChunkManager.shared
        result(chunkManager.getPendingSessions())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(name: "medical_transcription/audio_stream",
                                           binaryMessenger: controller.binaryMessenger)
    eventChannel.setStreamHandler(self)
    AudioManager.shared.setEventSink(self.eventSink)
    
    // Test Flutter engine by calling a simple method
    let testChannel = FlutterMethodChannel(name: "test_channel", binaryMessenger: controller.binaryMessenger)
    testChannel.invokeMethod("test", arguments: nil) { result in
      print("AppDelegate: Flutter engine test result: \(String(describing: result))")
    }
    
    print("AppDelegate: Platform channels setup completed")
  }
}

extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    AudioManager.shared.setEventSink(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    AudioManager.shared.setEventSink(nil)
    return nil
  }
}
