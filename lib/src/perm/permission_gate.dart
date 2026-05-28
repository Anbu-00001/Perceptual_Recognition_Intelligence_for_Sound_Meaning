import 'package:permission_handler/permission_handler.dart';

/// Resolves the runtime permissions Phase 0 needs:
///   - microphone (RECORD_AUDIO / NSMicrophoneUsageDescription)
///   - notification (Android 13+ POST_NOTIFICATIONS / iOS UNUserNotification)
///   - motion sensors are zero-permission on Android; iOS uses NSMotionUsageDescription
///     which is a plist string, not a runtime grant.
class PermissionGate {
  Future<bool> ensureCaptureGranted() async {
    final mic = await Permission.microphone.request();
    final note = await Permission.notification.request();
    return mic.isGranted && note.isGranted;
  }

  Future<bool> get isMicGranted async => Permission.microphone.isGranted;
  Future<bool> get isNotificationGranted async => Permission.notification.isGranted;
}
