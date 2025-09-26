import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var eventSink: FlutterEventSink?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController

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
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(name: "medical_transcription/audio_stream",
                                           binaryMessenger: controller.binaryMessenger)
    eventChannel.setStreamHandler(self)
    AudioManager.shared.setEventSink(self.eventSink)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
