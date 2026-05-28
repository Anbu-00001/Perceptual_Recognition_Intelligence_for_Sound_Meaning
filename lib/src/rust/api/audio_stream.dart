// HAND-WRITTEN STUB — replaced by `./scripts/codegen.sh`.
//
// Mirrors the Rust API in rust/src/api/audio_stream.rs so the Dart compiler is happy
// before codegen has run. Codegen overwrites this with the real FRB bindings.

/// Mirror of `rust::api::audio_stream::WaveformFrame`.
class WaveformFrame {
  WaveformFrame({
    required this.timestampMs,
    required this.left,
    required this.right,
    required this.peak,
    required this.ringOccupancy,
  });

  final int timestampMs;
  final List<int> left;
  final List<int> right;
  final int peak;
  final int ringOccupancy;
}

/// Returns the most recently buffered waveform frame, or null if no audio is buffered.
/// Dart drives the cadence with `Timer.periodic(33ms)`.
WaveformFrame? nextWaveformFrame() => null;

int ringOccupancy() => 0;
