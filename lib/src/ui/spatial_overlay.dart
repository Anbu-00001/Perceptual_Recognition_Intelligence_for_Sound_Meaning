import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../rust/api/dsp_pipeline.dart' show DspEvent, Zone;

/// Phase 3 — directional + room indicator that sits on top of the live
/// waveform.
///
/// Two layers:
///   1. **Angle indicator** (top half) — an arc with a needle at the
///      Kalman-smoothed angle. Needle fades when no fresh measurement
///      arrives (i.e., on mono-replicated devices it stays neutral).
///   2. **Zone chip** (bottom strip) — last classified room label when
///      confidence crossed the floor. Empty otherwise.
///
/// Driven by a `ValueListenable<DspEvent?>` so the parent doesn't need
/// to rebuild the whole screen at event rate.
class SpatialOverlay extends StatelessWidget {
  const SpatialOverlay({
    super.key,
    required this.event,
    this.height = 100,
  });

  final DspEvent? event;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = event;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: CustomPaint(
              painter: _AnglePainter(
                angleDeg: e?.smoothedAngleDeg ?? 0.0,
                confidence: e?.smoothedAngleConfidence ?? 0.0,
                rawZone: e?.zone ?? Zone.unknown,
                isMonoReplicated: (e?.spatialConfidence ?? 0.0) == 0.0 &&
                    (e?.zone ?? Zone.unknown) == Zone.unknown,
                accent: theme.colorScheme.primary,
                muted: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
              ),
            ),
          ),
          const SizedBox(height: 4),
          _ZoneChip(event: e, theme: theme),
        ],
      ),
    );
  }
}

class _ZoneChip extends StatelessWidget {
  const _ZoneChip({required this.event, required this.theme});
  final DspEvent? event;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final label = event?.zoneLabel ?? '';
    final conf = event?.zoneConfidence ?? 0.0;
    final hasZone = label.isNotEmpty && conf > 0;
    return Align(
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: hasZone
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          hasZone
              ? 'room: $label · ${(conf * 100).toStringAsFixed(0)}%'
              : 'room: unknown · enroll rooms to identify',
          style: theme.textTheme.bodySmall?.copyWith(
            color: hasZone
                ? theme.colorScheme.onPrimaryContainer
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _AnglePainter extends CustomPainter {
  _AnglePainter({
    required this.angleDeg,
    required this.confidence,
    required this.rawZone,
    required this.isMonoReplicated,
    required this.accent,
    required this.muted,
  });

  final double angleDeg;
  final double confidence;
  final Zone rawZone;
  final bool isMonoReplicated;
  final Color accent;
  final Color muted;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final center = Offset(w / 2, h);
    final r = math.min(w / 2 - 8, h - 8);

    // Background arc.
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = muted;
    final rect = Rect.fromCircle(center: center, radius: r);
    canvas.drawArc(rect, math.pi, math.pi, false, arcPaint);

    // Tick marks at -90, -45, 0, +45, +90.
    final tickPaint = Paint()..color = muted..strokeWidth = 1.5;
    for (final t in const [-90.0, -45.0, 0.0, 45.0, 90.0]) {
      final rad = (t - 90) * math.pi / 180;
      final p1 = Offset(center.dx + (r - 6) * math.cos(rad),
          center.dy + (r - 6) * math.sin(rad));
      final p2 = Offset(center.dx + r * math.cos(rad),
          center.dy + r * math.sin(rad));
      canvas.drawLine(p1, p2, tickPaint);
    }

    if (isMonoReplicated) {
      // Single-mic device: cannot localize. Draw nothing else; the chip
      // already explains.
      return;
    }

    if (confidence <= 0.01) {
      return; // no fresh measurement yet, no needle
    }

    // Needle.
    final clamped = angleDeg.clamp(-90.0, 90.0);
    final rad = (clamped - 90) * math.pi / 180;
    final needleEnd = Offset(
      center.dx + r * math.cos(rad),
      center.dy + r * math.sin(rad),
    );
    final needlePaint = Paint()
      ..color = accent.withValues(alpha: 0.4 + 0.6 * confidence)
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, needleEnd, needlePaint);

    // Confidence arc (small wedge of uncertainty).
    final uncertaintyDeg = (1.0 - confidence) * 45.0;
    if (uncertaintyDeg > 1.0) {
      final wedge = Paint()
        ..color = accent.withValues(alpha: 0.12)
        ..style = PaintingStyle.fill;
      final path = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(
          rect,
          (clamped - 90 - uncertaintyDeg) * math.pi / 180,
          2 * uncertaintyDeg * math.pi / 180,
          false,
        )
        ..close();
      canvas.drawPath(path, wedge);
    }
  }

  @override
  bool shouldRepaint(covariant _AnglePainter old) =>
      old.angleDeg != angleDeg ||
      old.confidence != confidence ||
      old.rawZone != rawZone ||
      old.isMonoReplicated != isMonoReplicated;
}
