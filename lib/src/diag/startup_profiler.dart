import 'dart:developer' as developer;

/// Records phase-by-phase timings during app boot and emits them via
/// `developer.log` (visible in `adb logcat -s flutter`). Used to diagnose
/// cold-start regressions like the 60-second hang seen on OPPO A18 / ColorOS 15
/// after `am force-stop` + relaunch.
///
/// Usage:
/// ```dart
/// final p = StartupProfiler();
/// p.mark('main_entered');
/// await RustLib.init();
/// p.mark('rust_lib_init');
/// runApp(...);
/// p.mark('run_app');
/// p.dump();
/// ```
class StartupProfiler {
  StartupProfiler() : _t0 = Stopwatch()..start();

  final Stopwatch _t0;
  final List<_Phase> _phases = [];
  int _lastMs = 0;

  void mark(String name) {
    final ms = _t0.elapsedMilliseconds;
    _phases.add(_Phase(name, ms, ms - _lastMs));
    _lastMs = ms;
    developer.log('[PRISM][boot] $name @${ms}ms (+${ms - _lastMs}ms)',
        name: 'PRISM');
  }

  void dump() {
    developer.log('[PRISM][boot] summary:', name: 'PRISM');
    for (final p in _phases) {
      developer.log('  ${p.name.padRight(28)} @${p.totalMs}ms  +${p.deltaMs}ms',
          name: 'PRISM');
    }
  }

  int get totalMs => _t0.elapsedMilliseconds;
}

class _Phase {
  _Phase(this.name, this.totalMs, this.deltaMs);
  final String name;
  final int totalMs;
  final int deltaMs;
}
