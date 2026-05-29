import 'package:flutter/services.dart';

/// Memory + manufacturer tier surfaced by the Kotlin `captureDiagnostics` call.
/// Drives several conditional behaviors:
///
/// | Tier             | Skip DeepSeek | Slow-path min interval | Ring history |
/// |------------------|---------------|------------------------|--------------|
/// | low              | yes           | 8 s                    | 1.5 s        |
/// | low_borderline   | yes           | 5 s                    | 2 s          |
/// | mid              | no            | 3 s                    | 4 s          |
/// | high             | no            | 2 s                    | 4 s          |
///
/// `low_borderline` is calibrated against the OPPO A18 (4 GB phys / 4 GB virtual).
/// On that hardware Gemma3n E2B at INT4 fits (~1.5 GB) but DeepSeek would push
/// the app over the HansManager kill threshold.
enum MemoryTier {
  low,
  lowBorderline,
  mid,
  high;

  static MemoryTier fromString(String? s) => switch (s) {
        'low' => MemoryTier.low,
        'low_borderline' => MemoryTier.lowBorderline,
        'mid' => MemoryTier.mid,
        'high' => MemoryTier.high,
        _ => MemoryTier.mid,
      };

  bool get skipDeepSeek =>
      this == MemoryTier.low || this == MemoryTier.lowBorderline;

  Duration get minSlowPathInterval => switch (this) {
        MemoryTier.low => const Duration(seconds: 8),
        MemoryTier.lowBorderline => const Duration(seconds: 5),
        MemoryTier.mid => const Duration(seconds: 3),
        MemoryTier.high => const Duration(seconds: 2),
      };

  /// Seconds of audio kept in the Rust rolling history. The actual ring is
  /// fixed at 4 s today but this is the budget callers reading
  /// `take_event_audio_16k` should respect on low-tier devices.
  double get historySeconds => switch (this) {
        MemoryTier.low => 1.5,
        MemoryTier.lowBorderline => 2.0,
        _ => 4.0,
      };
}

class DeviceProfile {
  const DeviceProfile({
    required this.audioSource,
    required this.manufacturer,
    required this.model,
    required this.androidSdk,
    required this.totalMemMb,
    required this.availMemMb,
    required this.memoryTier,
    required this.lowMemory,
    required this.isOemAggressive,
  });

  final String audioSource;
  final String manufacturer;
  final String model;
  final int androidSdk;
  final int totalMemMb;
  final int availMemMb;
  final MemoryTier memoryTier;
  final bool lowMemory;
  final bool isOemAggressive;

  /// True iff we got an unprocessed pre-AGC path — required for high-quality
  /// MFCC and any spatial work. On budget phones this is almost never true.
  bool get hasUnprocessedPath => audioSource == 'UNPROCESSED';

  /// Hint to the UI: "your phone needs the battery-opt opt-out OR it will
  /// kill us when the screen turns off." dontkillmyapp.com's manufacturer
  /// allow-list.
  bool get needsBatteryOptDialog => isOemAggressive;

  static const DeviceProfile unknown = DeviceProfile(
    audioSource: 'none',
    manufacturer: 'unknown',
    model: 'unknown',
    androidSdk: 0,
    totalMemMb: 0,
    availMemMb: 0,
    memoryTier: MemoryTier.mid,
    lowMemory: false,
    isOemAggressive: false,
  );

  factory DeviceProfile.fromMap(Map<dynamic, dynamic> m) {
    return DeviceProfile(
      audioSource: (m['audioSource'] as String?) ?? 'none',
      manufacturer: (m['manufacturer'] as String?) ?? 'unknown',
      model: (m['model'] as String?) ?? 'unknown',
      androidSdk: (m['androidSdk'] as num?)?.toInt() ?? 0,
      totalMemMb: (m['totalMemMb'] as num?)?.toInt() ?? 0,
      availMemMb: (m['availMemMb'] as num?)?.toInt() ?? 0,
      memoryTier: MemoryTier.fromString(m['memoryTier'] as String?),
      lowMemory: (m['lowMemory'] as bool?) ?? false,
      isOemAggressive: (m['isOemAggressive'] as bool?) ?? false,
    );
  }

  @override
  String toString() => 'DeviceProfile($manufacturer $model, '
      'sdk=$androidSdk, mem=$totalMemMb MB ($memoryTier), '
      'audio=$audioSource, aggressive=$isOemAggressive)';
}

/// Native bridge for diagnostics + battery-opt opt-out.
class DeviceProfileService {
  static const _channel = MethodChannel('com.prism/audio_capture');

  static Future<DeviceProfile> fetch() async {
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>('captureDiagnostics');
      if (m == null) return DeviceProfile.unknown;
      return DeviceProfile.fromMap(m);
    } catch (_) {
      return DeviceProfile.unknown;
    }
  }

  static Future<bool> isIgnoringBatteryOpt() async {
    try {
      final v = await _channel.invokeMethod<bool>('isIgnoringBatteryOpt');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Fires the OS dialog asking the user to whitelist PRISM. Caller should
  /// only invoke this after explaining *why* — Play Store policy flags
  /// silent requests on apps that don't justify the exemption.
  static Future<bool> requestIgnoreBatteryOpt() async {
    try {
      final v = await _channel.invokeMethod<bool>('requestIgnoreBatteryOpt');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }
}
