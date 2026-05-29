import 'dart:typed_data';
import 'dart:ui' show PictureRecorder;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/rust/api/audio_stream.dart' show WaveformFrame;
import 'package:prism/src/ui/waveform_painter.dart';

void main() {
  group('WaveformPainter', () {
    test('shouldRepaint when frame instance changes', () {
      final a = WaveformPainter(_frame([0]));
      final b = WaveformPainter(_frame([0]));
      expect(b.shouldRepaint(a), isTrue,
          reason: 'different frame instances should trigger repaint');
    });

    test('handles null frame without throwing', () {
      final painter = WaveformPainter(null);
      final size = const Size(400, 200);
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      expect(() => painter.paint(canvas, size), returnsNormally);
    });

    test('handles empty channels without throwing', () {
      final painter = WaveformPainter(WaveformFrame(
        timestampMs: BigInt.zero,
        left: Int16List(0),
        right: Int16List(0),
        peak: 0,
        ringOccupancy: 0,
      ));
      final recorder = PictureRecorder();
      expect(
        () => painter.paint(Canvas(recorder), const Size(100, 50)),
        returnsNormally,
      );
    });

    test('renders without crashing on a realistic frame', () {
      final left = Int16List.fromList(
        List<int>.generate(512, (i) => (i % 64) * 100 - 3200),
      );
      final right = Int16List.fromList(
        List<int>.generate(512, (i) => (i % 32) * -200 + 3200),
      );
      final painter = WaveformPainter(WaveformFrame(
        timestampMs: BigInt.from(1_000),
        left: left,
        right: right,
        peak: 3200,
        ringOccupancy: 4096,
      ));
      final recorder = PictureRecorder();
      expect(
        () => painter.paint(Canvas(recorder), const Size(800, 400)),
        returnsNormally,
      );
    });
  });
}

WaveformFrame _frame(List<int> samples) => WaveformFrame(
      timestampMs: BigInt.zero,
      left: Int16List.fromList(samples),
      right: Int16List.fromList(samples),
      peak: samples.fold<int>(0, (m, v) => v.abs() > m ? v.abs() : m),
      ringOccupancy: 0,
    );
