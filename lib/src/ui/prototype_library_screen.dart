import 'package:flutter/material.dart';

import '../audio/audio_service.dart';
import '../enrollment/categories.dart';
import '../enrollment/enrollment_service.dart';
import '../enrollment/environment_manager.dart';
import '../enrollment/prototype.dart';
import '../enrollment/prototype_repository.dart';
import 'enrollment_wizard.dart';

/// Lists enrolled prototypes for the currently selected environment. Entry
/// point to [EnrollmentWizard] for add / edit, and the surface where the user
/// switches the active environment (Phase 2 keeps switching manual).
class PrototypeLibraryScreen extends StatefulWidget {
  const PrototypeLibraryScreen({
    super.key,
    required this.service,
    required this.envManager,
    required this.repo,
    required this.audio,
  });

  final EnrollmentService service;
  final EnvironmentManager envManager;
  final PrototypeRepository repo;
  final AudioService audio;

  @override
  State<PrototypeLibraryScreen> createState() => _PrototypeLibraryScreenState();
}

class _PrototypeLibraryScreenState extends State<PrototypeLibraryScreen> {
  String _env = EnvironmentManager.defaultEnv;
  List<String> _envs = const [];
  List<SoundPrototype> _protos = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    widget.envManager.changes.listen((env) {
      if (mounted && env != _env) {
        setState(() => _env = env);
        _load();
      }
    });
    widget.repo.changes.listen((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final env = await widget.envManager.getActive();
    final envs = await widget.envManager.listKnown();
    final list = await widget.repo.listFor(env);
    if (!mounted) return;
    setState(() {
      _env = env;
      _envs = envs;
      _protos = list;
      _loading = false;
    });
  }

  Future<void> _openWizard({SoundPrototype? existing}) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EnrollmentWizard(
          service: widget.service,
          envManager: widget.envManager,
          repo: widget.repo,
          audio: widget.audio,
          startingPrototype: existing,
        ),
      ),
    );
    _load();
  }

  Future<void> _confirmDelete(SoundPrototype p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete prototype?'),
        content: Text(
          'Removes "${p.label}" and its ${p.samples.length} sample(s) from this environment. '
          'You will need to re-record to restore it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await widget.repo.delete(p.id);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sound library'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.layers),
            tooltip: 'Environment',
            onSelected: (e) async {
              await widget.envManager.setActive(e);
              _load();
            },
            itemBuilder: (_) => [
              for (final e in _envs)
                CheckedPopupMenuItem(
                  value: e,
                  checked: e == _env,
                  child: Text(e),
                ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _protos.isEmpty
              ? _empty(context)
              : ListView.builder(
                  itemCount: _protos.length,
                  itemBuilder: (_, i) {
                    final p = _protos[i];
                    final cat = SoundCategory.fromId(p.category);
                    return ListTile(
                      key: ValueKey('proto.${p.id}'),
                      title: Text(p.label),
                      subtitle: Text(
                        '${cat.label} · ${p.samples.length} sample(s)'
                        '${p.spatialZone != null ? ' · ${p.spatialZone}' : ''}',
                      ),
                      trailing: Wrap(spacing: 4, children: [
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: () => _openWizard(existing: p),
                          tooltip: 'Add more samples',
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _confirmDelete(p),
                          tooltip: 'Delete prototype',
                        ),
                      ]),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Enroll'),
        onPressed: () => _openWizard(),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.graphic_eq, size: 64, color: Colors.black26),
            const SizedBox(height: 12),
            Text(
              'No personal sounds enrolled for "$_env" yet.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tap "Enroll" to teach PRISM your doorbell, smoke alarm, family voices, '
              'and the appliance beeps you want to never miss.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}
