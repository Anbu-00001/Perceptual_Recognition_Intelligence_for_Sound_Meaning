import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../rust/api/enrollment.dart' as rust_enroll;
import '../spatial/room_zone.dart';
import '../spatial/room_zone_repository.dart';
import '../spatial/zone_enrollment_service.dart';

/// Phase 3 — full-screen wizard that records ~30 s of ambient, computes
/// the room fingerprint via Rust, and persists a [RoomZone].
///
/// Caller MUST have capture already started before pushing this screen
/// (foreground service alive + AudioRecord open). The recorder is a tap
/// onto the live audio pipeline, not a fresh open of the mic.
class ZoneEnrollmentScreen extends StatefulWidget {
  const ZoneEnrollmentScreen({
    super.key,
    required this.repo,
    required this.environment,
    this.service,
  });

  final RoomZoneRepository repo;
  final String environment;
  final ZoneEnrollmentService? service;

  @override
  State<ZoneEnrollmentScreen> createState() => _ZoneEnrollmentScreenState();
}

class _ZoneEnrollmentScreenState extends State<ZoneEnrollmentScreen> {
  late final ZoneEnrollmentService _service =
      widget.service ?? ZoneEnrollmentService(repo: widget.repo);
  final _labelController = TextEditingController();
  static const int _captureSeconds = 30;
  Timer? _timer;
  int _elapsed = 0;
  bool _recording = false;
  String? _status;
  RoomZone? _enrolled;

  @override
  void dispose() {
    _timer?.cancel();
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_recording) return;
    final label = _labelController.text.trim();
    if (label.isEmpty) {
      setState(() => _status = 'Enter a label first (e.g. "Kitchen").');
      return;
    }
    rust_enroll.enrollRecorderStart(maxDurationMs: _captureSeconds * 1000 + 500);
    setState(() {
      _recording = true;
      _elapsed = 0;
      _status = null;
      _enrolled = null;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      setState(() => _elapsed += 1);
      if (_elapsed >= _captureSeconds) {
        await _finish();
      }
    });
  }

  Future<void> _finish() async {
    _timer?.cancel();
    if (!_recording) return;
    final pcm = await rust_enroll.enrollRecorderStopTake();
    if (!mounted) return;
    setState(() => _recording = false);

    final result = await _service.enrollZone(
      pcm16k: Int16List.fromList(pcm),
      label: _labelController.text.trim(),
      environment: widget.environment,
    );

    if (!mounted) return;
    switch (result) {
      case ZoneEnrollmentSuccess(:final zone):
        setState(() {
          _enrolled = zone;
          _status = 'Saved "${zone.label}" '
              '(${zone.sampleSeconds}s, env=${zone.environment}).';
        });
      case ZoneEnrollmentTooShort(:final actualSeconds, :final requiredSeconds):
        setState(() => _status =
            'Recording was only ${actualSeconds}s; need at least ${requiredSeconds}s.');
      case ZoneEnrollmentInvalidLabel():
        setState(() => _status = 'Label was empty after trimming.');
      case ZoneEnrollmentFeatureFailed():
        setState(() => _status = 'Could not compute room fingerprint.');
    }
  }

  Future<void> _cancel() async {
    _timer?.cancel();
    if (_recording) {
      await rust_enroll.enrollRecorderStopTake();
    }
    setState(() {
      _recording = false;
      _elapsed = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = _captureSeconds == 0 ? 0.0 : _elapsed / _captureSeconds;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Enroll a room'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Pick a quiet moment in the room. The phone listens for '
              '${_captureSeconds}s, then turns the room into a fingerprint '
              'so later events can be tagged with the room they happened in.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _labelController,
              enabled: !_recording,
              decoration: const InputDecoration(
                labelText: 'Room name',
                hintText: 'Kitchen, Living room, Bedroom…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  SizedBox(
                    width: 160,
                    height: 160,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 160,
                          height: 160,
                          child: CircularProgressIndicator(
                            value: _recording ? progress : 0.0,
                            strokeWidth: 6,
                            backgroundColor:
                                theme.colorScheme.surfaceContainerHighest,
                          ),
                        ),
                        Text(
                          _recording
                              ? '${_captureSeconds - _elapsed}s'
                              : 'Ready',
                          style: theme.textTheme.headlineSmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton.tonal(
                        onPressed: _recording ? _cancel : _start,
                        child: Text(_recording ? 'Cancel' : 'Start 30s capture'),
                      ),
                      const SizedBox(width: 12),
                      if (_recording)
                        FilledButton(
                          onPressed: _finish,
                          child: const Text('Stop early'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            if (_status != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _enrolled != null
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _status!,
                  style: TextStyle(
                    color: _enrolled != null
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            const Spacer(),
            FutureBuilder<List<RoomZone>>(
              future: widget.repo.listFor(widget.environment),
              builder: (context, snap) {
                final zones = snap.data ?? const [];
                return Text(
                  zones.isEmpty
                      ? 'No rooms enrolled yet for environment '
                          '"${widget.environment}".'
                      : 'Enrolled in "${widget.environment}": '
                          '${zones.map((z) => z.label).join(", ")}',
                  style: theme.textTheme.bodySmall,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
