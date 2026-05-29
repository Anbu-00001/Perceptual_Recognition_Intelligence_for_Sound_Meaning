import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// User-declared "current environment" — what set of personal prototypes is
/// active. Phase 2 ships a manual switcher; Phase 3+ may auto-detect via
/// BSSID / geofence / ambient acoustic fingerprint.
///
/// Multi-environment matters because the same physical sound (e.g. a knock)
/// produces very different recordings at home vs office vs parents' house.
/// Mixing them into one library degrades recall on every site.
class EnvironmentManager {
  EnvironmentManager({SharedPreferences? prefs}) : _seedPrefs = prefs;

  static const String _activeKey = 'prism.env.active';
  static const String _knownKey = 'prism.env.known';
  static const String defaultEnv = 'home';
  static const List<String> _builtIn = <String>[
    'home',
    'office',
    'family',
    'travel',
  ];

  final SharedPreferences? _seedPrefs;
  SharedPreferences? _prefs;

  final _controller = StreamController<String>.broadcast();

  /// Emits whenever the active environment changes.
  Stream<String> get changes => _controller.stream;

  Future<SharedPreferences> _ensure() async {
    return _prefs ??= _seedPrefs ?? await SharedPreferences.getInstance();
  }

  Future<String> getActive() async {
    final p = await _ensure();
    return p.getString(_activeKey) ?? defaultEnv;
  }

  Future<List<String>> listKnown() async {
    final p = await _ensure();
    final stored = p.getStringList(_knownKey) ?? const <String>[];
    final set = <String>{..._builtIn, ...stored};
    return set.toList();
  }

  Future<void> setActive(String name) async {
    final p = await _ensure();
    final norm = _normalize(name);
    await p.setString(_activeKey, norm);
    final known = p.getStringList(_knownKey) ?? <String>[];
    if (!_builtIn.contains(norm) && !known.contains(norm)) {
      known.add(norm);
      await p.setStringList(_knownKey, known);
    }
    _controller.add(norm);
  }

  Future<void> dispose() => _controller.close();

  static String _normalize(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
}
