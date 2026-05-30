// ignore_for_file: avoid_print
//
// Boot-phase profiler. Uses bare `print` (not `developer.log`) so the lines
// show up under `adb logcat *:S flutter:V` without needing `--dart-define`
// log-level plumbing. Cold-start hangs are easier to diagnose when every
// phase prints immediately to the same stream as Flutter's own boot logs.

/// Records phase-by-phase timings during app boot. Diagnoses cold-start
/// regressions like the 60-second hang seen on OPPO A18 / ColorOS 15 after
/// `am force-stop` + relaunch.
class StartupProfiler {
  StartupProfiler() : _t0 = Stopwatch()..start();

  final Stopwatch _t0;
  final List<_Phase> _phases = [];
  int _lastMs = 0;

  void mark(String name) {
    final ms = _t0.elapsedMilliseconds;
    final delta = ms - _lastMs;
    _phases.add(_Phase(name, ms, delta));
    _lastMs = ms;
    print('[PRISM][boot] $name @${ms}ms (+${delta}ms)');
  }

  void dump() {
    print('[PRISM][boot] summary:');
    for (final p in _phases) {
      print('  ${p.name.padRight(28)} @${p.totalMs}ms  +${p.deltaMs}ms');
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
