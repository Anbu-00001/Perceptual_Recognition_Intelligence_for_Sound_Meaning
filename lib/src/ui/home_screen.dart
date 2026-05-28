import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/audio_service.dart';
import '../perm/permission_gate.dart';
import '../rust/api/audio_stream.dart' show WaveformFrame;
import '../rust/api/session.dart' show SessionPaths;
import 'waveform_painter.dart';

/// Phase 0 acceptance UI: one screen, two buttons, live stereo waveform.
/// Recording produces a `session_<ts>.wav` + `imu_<ts>.csv` in app documents directory.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _service = AudioService();
  final _perms = PermissionGate();
  final _frameNotifier = ValueNotifier<WaveformFrame?>(null);

  StreamSubscription<WaveformFrame>? _sub;
  bool _capturing = false;
  bool _recording = false;
  SessionPaths? _lastSession;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = _service.waveformStream().listen(
      (f) => _frameNotifier.value = f,
      onError: (e) => setState(() => _error = e.toString()),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _frameNotifier.dispose();
    super.dispose();
  }

  Future<void> _toggleCapture() async {
    setState(() => _error = null);
    try {
      if (_capturing) {
        if (_recording) {
          await _toggleSession();
        }
        await _service.stopCapture();
      } else {
        final granted = await _perms.ensureCaptureGranted();
        if (!granted) {
          setState(() => _error = 'Microphone or notification permission denied.');
          return;
        }
        await _service.startCapture();
      }
      setState(() => _capturing = !_capturing);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _toggleSession() async {
    setState(() => _error = null);
    try {
      if (_recording) {
        final paths = await _service.stopSession();
        setState(() {
          _lastSession = paths;
          _recording = false;
        });
      } else {
        if (!_capturing) {
          setState(() => _error = 'Start capture before recording.');
          return;
        }
        final paths = await _service.startSession();
        setState(() {
          _lastSession = paths;
          _recording = true;
        });
      }
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('PRISM · Phase 0'),
        actions: [
          if (_capturing)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Icon(Icons.fiber_manual_record, color: Colors.redAccent),
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _capturing ? 'Listening' : 'Idle',
                style: theme.textTheme.headlineMedium,
                semanticsLabel: _capturing
                    ? 'Capture is active. Live waveform visible.'
                    : 'Capture is idle.',
              ),
              const SizedBox(height: 8),
              Text(
                'Stereo · 48 kHz · 16-bit',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF111114),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF222226)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: RepaintBoundary(
                      child: ValueListenableBuilder<WaveformFrame?>(
                        valueListenable: _frameNotifier,
                        builder: (_, frame, child) {
                          return CustomPaint(
                            painter: WaveformPainter(frame),
                            size: Size.infinite,
                            child: child,
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _legend(),
              const SizedBox(height: 16),
              if (_error != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              if (_lastSession != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'WAV: ${_lastSession!.wavPath}\nIMU: ${_lastSession!.imuPath}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: _toggleCapture,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                      child: Text(_capturing ? 'Stop capture' : 'Start capture'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _capturing ? _toggleSession : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                      child: Text(_recording ? 'Stop recording' : 'Record session'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legend() {
    return Row(
      children: [
        _swatch(const Color(0xFF24E0E0), 'Left'),
        const SizedBox(width: 16),
        _swatch(const Color(0xFFE65BD0), 'Right'),
      ],
    );
  }

  Widget _swatch(Color c, String label) {
    return Row(
      children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(
          color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }
}
