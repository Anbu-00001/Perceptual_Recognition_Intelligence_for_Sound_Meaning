import 'package:flutter/material.dart';

import '../rust/api/audio_stream.dart' show WaveformFrame;

/// Stereo oscilloscope. Renders left in cyan, right in magenta, both centered.
/// Updates whenever the [frame] ValueNotifier changes (driven by the Rust stream).
class WaveformPainter extends CustomPainter {
  WaveformPainter(this.frame);

  final WaveformFrame? frame;

  static const _maxAmp = 32767.0;

  final _leftPaint = Paint()
    ..color = const Color(0xFF24E0E0)
    ..strokeWidth = 1.2
    ..style = PaintingStyle.stroke;

  final _rightPaint = Paint()
    ..color = const Color(0xFFE65BD0)
    ..strokeWidth = 1.2
    ..style = PaintingStyle.stroke;

  final _gridPaint = Paint()
    ..color = const Color(0x33FFFFFF)
    ..strokeWidth = 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    // Centerline + horizontal grid.
    final midY = size.height / 2;
    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), _gridPaint);

    final f = frame;
    if (f == null || f.left.isEmpty || f.right.isEmpty) return;

    final n = f.left.length.clamp(1, 99999);
    final dx = size.width / (n - 1);
    final quarterH = size.height / 4;

    final pathLeft = Path();
    final pathRight = Path();
    for (var i = 0; i < n; i++) {
      final lNorm = f.left[i] / _maxAmp;
      final rNorm = f.right[i] / _maxAmp;
      final x = dx * i;
      final yL = midY - quarterH - lNorm * quarterH;
      final yR = midY + quarterH - rNorm * quarterH;
      if (i == 0) {
        pathLeft.moveTo(x, yL);
        pathRight.moveTo(x, yR);
      } else {
        pathLeft.lineTo(x, yL);
        pathRight.lineTo(x, yR);
      }
    }
    canvas.drawPath(pathLeft, _leftPaint);
    canvas.drawPath(pathRight, _rightPaint);
  }

  @override
  bool shouldRepaint(covariant WaveformPainter old) => old.frame != frame;
}
