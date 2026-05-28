import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // One-time native log init.
    prism_init_logger()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // MethodChannel matches Android's "com.prism/audio_capture".
    let channel = FlutterMethodChannel(
      name: "com.prism/audio_capture",
      binaryMessenger: engineBridge.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "startCapture":
        do {
          try AudioCapture.shared.start()
          ImuCapture.shared.start()
          result(true)
        } catch {
          result(FlutterError(code: "AUDIO_START_FAILED",
                              message: error.localizedDescription, details: nil))
        }
      case "stopCapture":
        AudioCapture.shared.stop()
        ImuCapture.shared.stop()
        result(true)
      case "isCapturing":
        result(AudioCapture.shared.isRunning)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
