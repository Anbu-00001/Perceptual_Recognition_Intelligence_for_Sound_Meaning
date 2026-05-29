import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../audio/audio_service.dart';
import '../enrollment/categories.dart';
import '../enrollment/enrollment_service.dart';
import '../enrollment/environment_manager.dart';
import '../enrollment/prototype.dart';
import '../enrollment/prototype_repository.dart';
import '../rust/api/enrollment.dart' as rust_enroll;
import 'enrollment_record_button.dart';

/// Phase 2 enrollment wizard.
///
/// Steps:
///   1. Pick category
///   2. Set label + environment
///   3. Record N samples one at a time, each evaluated by the Rust gates +
///      Gemma3n caption + EmbeddingGemma vector. Rejected samples don't count
///      against [SoundCategory.minRecommendedSamples] but do consume battery,
///      so we surface the reject reason inline so the user can re-aim the mic.
///   4. Review centroid + save.
class EnrollmentWizard extends StatefulWidget {
  const EnrollmentWizard({
    super.key,
    required this.service,
    required this.envManager,
    required this.repo,
    required this.audio,
    this.startingPrototype,
  });

  final EnrollmentService service;
  final EnvironmentManager envManager;
  final PrototypeRepository repo;
  final AudioService audio;
  final SoundPrototype? startingPrototype;

  @override
  State<EnrollmentWizard> createState() => _EnrollmentWizardState();
}

enum _Step { pickCategory, setLabel, record, review }

class _EnrollmentWizardState extends State<EnrollmentWizard> {
  _Step _step = _Step.pickCategory;
  SoundCategory _category = SoundCategory.doorbell;
  final _labelCtrl = TextEditingController();
  String _environment = EnvironmentManager.defaultEnv;
  String? _spatialZone;

  SoundPrototype? _proto;
  final List<EnrollmentResult> _attempts = [];

  bool _busy = false;
  String? _busyText;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final p = widget.startingPrototype;
    final env = await widget.envManager.getActive();
    setState(() {
      _environment = env;
      if (p != null) {
        _proto = p;
        _category = SoundCategory.fromId(p.category);
        _labelCtrl.text = p.label;
        _environment = p.environment;
        _spatialZone = p.spatialZone;
        _step = _Step.record;
      } else {
        _labelCtrl.text = _category.suggestedLabel;
      }
    });
    // Make sure the native capture pipeline is on so the recorder tap fills.
    final running = await widget.audio.isCapturing();
    if (!running) {
      await widget.audio.startCapture();
    }
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Enroll a sound'),
        actions: [
          if (_step == _Step.record && _proto != null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() => _step = _Step.review),
              child: const Text('Done'),
            ),
        ],
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: switch (_step) {
            _Step.pickCategory => _pickCategory(),
            _Step.setLabel => _setLabel(),
            _Step.record => _record(),
            _Step.review => _review(),
          },
        ),
      ),
    );
  }

  Widget _pickCategory() => ListView(
        key: const ValueKey(_Step.pickCategory),
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'What kind of sound is this?',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          ...SoundCategory.all.map((c) => Card(
                child: ListTile(
                  title: Text(c.label),
                  subtitle: Text(c.description),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    setState(() {
                      _category = c;
                      if (_labelCtrl.text.isEmpty) {
                        _labelCtrl.text = c.suggestedLabel;
                      }
                      _step = _Step.setLabel;
                    });
                  },
                ),
              )),
        ],
      );

  Widget _setLabel() {
    return Padding(
      key: const ValueKey(_Step.setLabel),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Label this ${_category.label.toLowerCase()}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _labelCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Label',
              helperText: 'Short, distinctive — e.g. "Front door knock"',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _environment,
            decoration: const InputDecoration(
              labelText: 'Environment',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'home', child: Text('Home')),
              DropdownMenuItem(value: 'office', child: Text('Office')),
              DropdownMenuItem(value: 'family', child: Text('Family / parents')),
              DropdownMenuItem(value: 'travel', child: Text('Travel / other')),
            ],
            onChanged: (v) => setState(() => _environment = v ?? _environment),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String?>(
            initialValue: _spatialZone,
            decoration: const InputDecoration(
              labelText: 'Spatial zone (optional)',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: null, child: Text('—')),
              DropdownMenuItem(value: 'entryway', child: Text('Entryway')),
              DropdownMenuItem(value: 'kitchen', child: Text('Kitchen')),
              DropdownMenuItem(value: 'bedroom', child: Text('Bedroom')),
              DropdownMenuItem(value: 'living', child: Text('Living room')),
              DropdownMenuItem(value: 'other', child: Text('Other')),
            ],
            onChanged: (v) => setState(() => _spatialZone = v),
          ),
          const Spacer(),
          FilledButton.icon(
            icon: const Icon(Icons.mic),
            label: const Text('Continue to recording'),
            onPressed: _labelCtrl.text.trim().isEmpty
                ? null
                : () => setState(() => _step = _Step.record),
          ),
        ],
      ),
    );
  }

  Widget _record() {
    final acceptedCount =
        _proto?.samples.length ?? _attempts.where((r) => r.accepted).length;
    final target = _category.minRecommendedSamples;
    final lastResult = _attempts.isEmpty ? null : _attempts.last;

    return Padding(
      key: const ValueKey(_Step.record),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(
            'Recording sample ${acceptedCount + 1} of $target',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            '"${_labelCtrl.text}" · ${_category.label} · $_environment',
            style: const TextStyle(color: Colors.black54),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: (acceptedCount / target).clamp(0.0, 1.0),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: Center(
              child: _busy
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(_busyText ?? 'Working…'),
                      ],
                    )
                  : EnrollmentRecordButton(onCaptured: _onCaptured),
            ),
          ),
          if (lastResult != null) _resultCard(lastResult),
          const SizedBox(height: 8),
          if (acceptedCount >= target)
            FilledButton(
              onPressed: _busy ? null : () => setState(() => _step = _Step.review),
              child: const Text('Review & save'),
            ),
        ],
      ),
    );
  }

  Widget _review() {
    final p = _proto;
    return Padding(
      key: const ValueKey(_Step.review),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Saved!',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          if (p != null) ...[
            _kv('Label', p.label),
            _kv('Category', _category.label),
            _kv('Environment', p.environment),
            if (p.spatialZone != null) _kv('Spatial zone', p.spatialZone!),
            _kv('Samples kept', '${p.samples.length}'),
            _kv('Vector dim', '${p.centroid.length}'),
            const SizedBox(height: 12),
            const Text('Recent captions:', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            ...p.samples.take(5).map((s) => Text('· ${s.caption}', style: const TextStyle(fontSize: 13))),
          ],
          const Spacer(),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(p),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(EnrollmentResult r) {
    final color = r.accepted ? Colors.green.shade100 : Colors.red.shade100;
    final icon = r.accepted ? Icons.check_circle : Icons.error_outline;
    final headline = r.accepted
        ? 'Captured ✓'
        : 'Rejected: ${_rejectMessage(r)}';
    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18),
              const SizedBox(width: 6),
              Text(headline, style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 6),
            if (r.caption != null) Text('caption: ${r.caption}', style: const TextStyle(fontSize: 12)),
            Text(
              'snr=${r.report.snrDb.toStringAsFixed(1)} dB · '
              'peak=${r.report.peakDbfs.toStringAsFixed(1)} dBFS · '
              'active=${(r.report.activeRatio * 100).toStringAsFixed(0)}% · '
              'clip=${(r.report.clippingRatio * 100).toStringAsFixed(2)}%',
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  String _rejectMessage(EnrollmentResult r) {
    if (r.outcome != EnrollmentOutcome.rejected) {
      return switch (r.outcome) {
        EnrollmentOutcome.failedCaption => 'caption failed — try again',
        EnrollmentOutcome.failedEmbedding => 'embedding failed — try again',
        EnrollmentOutcome.failedRepo => r.error ?? 'save failed',
        _ => 'unknown',
      };
    }
    return switch (r.report.rejectReason) {
      rust_enroll.EnrollRejectReason.tooShort => 'too short — hold longer',
      rust_enroll.EnrollRejectReason.tooLong => 'too long — release sooner',
      rust_enroll.EnrollRejectReason.tooQuiet => 'too quiet — move closer or louder',
      rust_enroll.EnrollRejectReason.tooNoisy => 'too noisy — quieter background',
      rust_enroll.EnrollRejectReason.clipping => 'too loud — move farther',
      rust_enroll.EnrollRejectReason.noSignal => 'no signal — sound not detected',
      _ => 'unrecognized clip',
    };
  }

  Future<void> _onCaptured(List<int> pcm) async {
    if (pcm.isEmpty) return;
    setState(() {
      _busy = true;
      _busyText = 'Analyzing…';
    });
    try {
      final result = await widget.service.ingestSample(
        prototypeId: _proto?.id,
        pcm16k: Int16List.fromList(pcm),
        category: _category,
        label: _labelCtrl.text,
        environment: _environment,
        spatialZone: _spatialZone,
      );
      setState(() {
        _attempts.add(result);
        if (result.accepted && result.prototype != null) {
          _proto = result.prototype;
        }
      });
    } finally {
      setState(() {
        _busy = false;
        _busyText = null;
      });
    }
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 110, child: Text(k, style: const TextStyle(color: Colors.black54))),
            Expanded(child: Text(v)),
          ],
        ),
      );
}
