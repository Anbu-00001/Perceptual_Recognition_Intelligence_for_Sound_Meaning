import 'package:flutter/material.dart';

import '../rust/api/enrollment.dart' as rust_enroll;

/// Press-and-hold recording button used by the enrollment wizard.
///
/// On press: starts the Rust enrollment recorder.
/// On release: stops it and returns the captured 16 kHz mono PCM via [onRelease].
///
/// Caller is responsible for the higher-level pipeline being active. We don't
/// start the foreground service here — the wizard host does that before
/// pushing this widget.
class EnrollmentRecordButton extends StatefulWidget {
  const EnrollmentRecordButton({
    super.key,
    required this.onCaptured,
    this.maxDurationMs = 4000,
    this.label = 'Hold to record',
  });

  final ValueChanged<List<int>> onCaptured;
  final int maxDurationMs;
  final String label;

  @override
  State<EnrollmentRecordButton> createState() => _EnrollmentRecordButtonState();
}

class _EnrollmentRecordButtonState extends State<EnrollmentRecordButton>
    with SingleTickerProviderStateMixin {
  bool _recording = false;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
    lowerBound: 0.6,
    upperBound: 1.0,
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _start() {
    if (_recording) return;
    rust_enroll.enrollRecorderStart(maxDurationMs: widget.maxDurationMs);
    _pulse.repeat(reverse: true);
    setState(() => _recording = true);
  }

  Future<void> _stop() async {
    if (!_recording) return;
    _pulse.stop();
    _pulse.value = 1.0;
    final pcm = await rust_enroll.enrollRecorderStopTake();
    setState(() => _recording = false);
    widget.onCaptured(pcm);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (_) => _start(),
      onTapUp: (_) => _stop(),
      onTapCancel: () => _stop(),
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          return Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _recording
                  ? Color.lerp(scheme.errorContainer, scheme.error, _pulse.value)
                  : scheme.primaryContainer,
              border: Border.all(
                color: _recording ? scheme.error : scheme.primary,
                width: 3,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              _recording ? 'Recording…' : widget.label,
              key: const Key('enrollment.recordButton.label'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _recording ? scheme.onError : scheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          );
        },
      ),
    );
  }
}
