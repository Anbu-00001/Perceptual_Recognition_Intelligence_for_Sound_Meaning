import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../rust/api/audio_stream.dart' as rust_stream;
import '../rust/api/session.dart' as rust_session;

/// Lifecycle of native audio + IMU capture.
///
/// The MethodChannel "com.prism/audio_capture" is implemented by:
///   - Android: [AudioCapturePlugin] (Kotlin) → AudioCaptureService + ImuCapture
///   - iOS:     AppDelegate.swift → AudioCapture.shared + ImuCapture.shared
///
/// Audio frames are NOT sent through this channel — they flow native -> Rust ring buffer.
/// Dart polls Rust at 30 fps for decimated visualization frames (Phase 0). Phase 1
/// upgrades this to a true Rust→Dart stream via flutter_rust_bridge `StreamSink`.
class AudioService {
  AudioService();

  static const _channel = MethodChannel('com.prism/audio_capture');

  /// 30 fps visualization stream. Internally polls Rust on a Timer.
  /// Use [WaveformPainter] to render. Dispose by cancelling the subscription.
  Stream<rust_stream.WaveformFrame> waveformStream() {
    late StreamController<rust_stream.WaveformFrame> ctrl;
    Timer? timer;
    void tick(Timer _) {
      final frame = rust_stream.nextWaveformFrame();
      if (frame != null) ctrl.add(frame);
    }
    ctrl = StreamController<rust_stream.WaveformFrame>(
      onListen: () => timer = Timer.periodic(
        const Duration(milliseconds: 33),
        tick,
      ),
      onCancel: () async => timer?.cancel(),
    );
    return ctrl.stream;
  }

  Future<bool> startCapture() async {
    final ok = await _channel.invokeMethod<bool>('startCapture');
    return ok ?? false;
  }

  Future<bool> stopCapture() async {
    final ok = await _channel.invokeMethod<bool>('stopCapture');
    return ok ?? false;
  }

  Future<bool> isCapturing() async {
    final ok = await _channel.invokeMethod<bool>('isCapturing');
    return ok ?? false;
  }

  /// Starts a session — opens the `.wav` + `.csv` files in Rust.
  /// Returns the on-disk paths.
  Future<rust_session.SessionPaths> startSession() async {
    final docs = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    return rust_session.startSession(documentsDir: docs.path, tsLabel: ts);
  }

  /// Closes session files, flushes IMU CSV, finalizes WAV.
  Future<rust_session.SessionPaths> stopSession() async {
    return rust_session.stopSession();
  }

  /// Documents directory shortcut for the acceptance UI.
  Future<Directory> documentsDir() => getApplicationDocumentsDirectory();
}
