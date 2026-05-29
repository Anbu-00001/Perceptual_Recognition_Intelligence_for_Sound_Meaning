import 'dart:typed_data';

import 'package:prism/src/enrollment/caption_generator.dart';
import 'package:prism/src/enrollment/enrollment_service.dart';
import 'package:prism/src/rust/api/enrollment.dart' as rust_enroll;

/// Records every embedding request and returns a deterministic short vector.
/// The vector geometry encodes the input so tests can verify which caption
/// reached the embedder.
class RecordingEmbedder implements DocumentEmbedder {
  final List<String> calls = [];

  @override
  Future<List<double>> embedAsDocument(String text) async {
    calls.add(text);
    // 8-D vector: first slot = text length, rest = char codes mod 7. Stable
    // across runs and unique enough to tell different captions apart.
    final v = List<double>.filled(8, 0.0);
    v[0] = text.length.toDouble();
    for (var i = 0; i < text.length && i < 7; i++) {
      v[1 + i] = (text.codeUnitAt(i) % 7).toDouble();
    }
    return v;
  }
}

class FakeCaptioner implements Captioner {
  FakeCaptioner({this.captionText = 'a fake captured sound'});

  String captionText;
  int warmupCount = 0;
  final List<String?> calls = [];

  @override
  Future<void> warmup() async {
    warmupCount++;
  }

  @override
  Future<String> caption({required Int16List pcm16k, String? userLabelHint}) async {
    calls.add(userLabelHint);
    return captionText;
  }
}

/// Build an analyzer closure that always accepts/rejects with a controlled
/// report payload — lets EnrollmentService tests exercise every branch
/// without touching the Rust DSP.
ClipAnalyzer constantAnalyzer({required bool accepted, rust_enroll.EnrollRejectReason? reason}) {
  return (samples) async => rust_enroll.EnrollClipReport(
        accepted: accepted,
        rejectReason: reason,
        durationMs: 1500,
        peakDbfs: -12,
        rmsDbfs: -18,
        noiseFloorDbfs: -50,
        snrDb: 18,
        activeRatio: 0.7,
        clippingRatio: 0.0,
        zcr: 0.08,
      );
}
