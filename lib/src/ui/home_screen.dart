import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/audio_service.dart';
import '../audio/device_profile.dart';
import '../perm/permission_gate.dart';
import '../rust/api/audio_stream.dart' show WaveformFrame;
import '../rust/api/session.dart' show SessionPaths;
import 'waveform_painter.dart';

/// Phase 0 acceptance UI: one screen, two buttons, live stereo waveform.
/// Recording produces a `session_<ts>.wav` + `imu_<ts>.csv` in app documents directory.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.deviceProfileFuture});

  final Future<DeviceProfile>? deviceProfileFuture;

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
  DeviceProfile? _profile;
  bool _ignoringBatteryOpt = false;
  bool _batteryBannerDismissed = false;

  @override
  void initState() {
    super.initState();
    _sub = _service.waveformStream().listen(
      (f) => _frameNotifier.value = f,
      onError: (e) => setState(() => _error = e.toString()),
    );
    _loadDiagnostics();
  }

  Future<void> _loadDiagnostics() async {
    final f = widget.deviceProfileFuture;
    if (f == null) return;
    final p = await f;
    final battery = await DeviceProfileService.isIgnoringBatteryOpt();
    if (!mounted) return;
    setState(() {
      _profile = p;
      _ignoringBatteryOpt = battery;
    });
  }

  /// Re-pulls the device profile from the native side. Used after startCapture
  /// so the audio-source line shows the source the ladder actually selected
  /// instead of the initial "none" placeholder.
  Future<void> _refreshProfile() async {
    final p = await DeviceProfileService.fetch();
    if (!mounted) return;
    setState(() => _profile = p);
  }

  Future<void> _requestBatteryOpt() async {
    await DeviceProfileService.requestIgnoreBatteryOpt();
    // The system dialog is fire-and-forget; the user may switch back without
    // confirming. Re-check the next time we're foreground (didChangeAppLifecycleState
    // would also work but the home-screen Resume re-check is good enough here).
    Future<void>.delayed(const Duration(seconds: 1), () async {
      if (!mounted) return;
      final v = await DeviceProfileService.isIgnoringBatteryOpt();
      if (mounted) setState(() => _ignoringBatteryOpt = v);
    });
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
        // The audio-source ladder picks at startCapture() time. Re-fetch
        // diagnostics so the UI shows the actual source (not the "none" we
        // had at first launch before any capture had run).
        unawaited(_refreshProfile());
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
              if (_shouldShowBatteryBanner()) _batteryOptBanner(theme),
              if (_capturing && _profile != null) _audioSourceLine(theme),
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

  bool _shouldShowBatteryBanner() {
    final p = _profile;
    if (p == null || _batteryBannerDismissed || _ignoringBatteryOpt) return false;
    return p.isOemAggressive;
  }

  Widget _batteryOptBanner(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.shade900.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber.shade700),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your ${_profile?.manufacturer ?? 'device'} may kill PRISM in the background.',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'Disable battery optimization for PRISM so the foreground mic stays alive '
            'when the screen turns off.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: _requestBatteryOpt,
                child: const Text('Open settings'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _batteryBannerDismissed = true),
                child: const Text('Not now'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _audioSourceLine(ThemeData theme) {
    final p = _profile!;
    final detail = p.hasUnprocessedPath
        ? 'mic source: ${p.audioSource} · best quality available'
        : 'mic source: ${p.audioSource} · device does not expose UNPROCESSED; spatial features degraded';
    final color = p.hasUnprocessedPath
        ? theme.colorScheme.onSurfaceVariant
        : Colors.amber.shade400;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(detail, style: TextStyle(color: color, fontSize: 12)),
    );
  }
}
