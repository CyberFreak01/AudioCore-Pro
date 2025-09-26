import 'package:flutter/services.dart';

class MicService {
  static const MethodChannel _platform = MethodChannel('com.example.mediascribe.micService');

  static Future<void> startMic() async {
    try {
      await _platform.invokeMethod('startMic');
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print("Failed to start mic service: '${e.message}'.");
    }
  }

  static Future<void> stopMic() async {
    try {
      await _platform.invokeMethod('stopMic');
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print("Failed to stop mic service: '${e.message}'.");
    }
  }
}


