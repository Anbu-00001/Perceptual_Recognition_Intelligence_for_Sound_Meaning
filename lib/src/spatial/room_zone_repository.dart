import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../rust/api/zone.dart' as rust_zone;
import 'room_zone.dart';

/// Persists [RoomZone] centroids in a sidecar JSON and keeps the Rust
/// classifier's active prototype table in sync.
///
/// Sidecar pattern (matches Phase 2 `PrototypeRepository`):
///   - sidecar is source of truth
///   - Rust table is regenerable; re-pushed on every change
///   - changes broadcast for UI rebuilds
///
/// Filtered by environment: when the user is in "home", only zones tagged
/// `home` are pushed to Rust so the bedroom doesn't get classified as
/// "office" when the user is at the office. Environment switching =
/// re-push.
class RoomZoneRepository {
  RoomZoneRepository({
    String? overrideDirectory,
    rust_zone.ZonePrototypeDto Function(RoomZone)? toDto,
    void Function(List<rust_zone.ZonePrototypeDto>)? pushPrototypes,
  })  : _overrideDir = overrideDirectory,
        _toDto = toDto ?? _defaultToDto,
        _pushPrototypes = pushPrototypes ?? _defaultPush;

  final String? _overrideDir;
  final rust_zone.ZonePrototypeDto Function(RoomZone) _toDto;
  final void Function(List<rust_zone.ZonePrototypeDto>) _pushPrototypes;

  static const String _fileName = 'room_zones.json';

  final Map<String, RoomZone> _byId = {};
  bool _loaded = false;
  String _activeEnvironment = 'home';
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;
  String get activeEnvironment => _activeEnvironment;

  /// Eagerly load the sidecar + push the active prototype set to Rust.
  /// Called by `main.dart` off the critical path so the very first event
  /// after a cold boot already sees the user's enrolled rooms, even if
  /// nothing has touched the repository yet.
  Future<void> ensureSynced() async {
    await _ensureLoaded();
  }

  static rust_zone.ZonePrototypeDto _defaultToDto(RoomZone z) =>
      rust_zone.ZonePrototypeDto(id: z.id, label: z.label, centroid: z.centroid);

  static void _defaultPush(List<rust_zone.ZonePrototypeDto> dtos) {
    rust_zone.zoneSetPrototypes(items: dtos);
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final file = await _file();
    if (await file.exists()) {
      final text = await file.readAsString();
      if (text.isNotEmpty) {
        final raw = jsonDecode(text);
        if (raw is List) {
          for (final entry in raw) {
            if (entry is Map<String, dynamic>) {
              try {
                final z = RoomZone.fromJson(entry);
                _byId[z.id] = z;
              } catch (_) {
                // Skip malformed entries rather than dying on boot.
              }
            }
          }
        }
      }
    }
    _loaded = true;
    _syncRust();
  }

  /// Drop everything and read from disk again. Used in tests; also a
  /// recovery path if the user wipes their sidecar via OS file picker.
  Future<void> reload() async {
    _loaded = false;
    _byId.clear();
    await _ensureLoaded();
    _changes.add(null);
  }

  Future<List<RoomZone>> listAll() async {
    await _ensureLoaded();
    final out = _byId.values.toList();
    out.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return out;
  }

  Future<List<RoomZone>> listFor(String environment) async {
    final all = await listAll();
    return all.where((z) => z.environment == environment).toList();
  }

  Future<RoomZone?> getById(String id) async {
    await _ensureLoaded();
    return _byId[id];
  }

  /// Insert or replace a zone. The Rust prototype table is re-pushed so
  /// the classifier picks up the change on the next event.
  Future<void> upsert(RoomZone zone) async {
    await _ensureLoaded();
    _byId[zone.id] = zone;
    await _persistSidecar();
    _syncRust();
    _changes.add(null);
  }

  Future<void> delete(String zoneId) async {
    await _ensureLoaded();
    if (!_byId.containsKey(zoneId)) return;
    _byId.remove(zoneId);
    await _persistSidecar();
    _syncRust();
    _changes.add(null);
  }

  /// Filter the active prototypes pushed to Rust. Other zones stay in the
  /// sidecar — they're not gone, just not in the running classifier set.
  Future<void> setActiveEnvironment(String env) async {
    await _ensureLoaded();
    if (env == _activeEnvironment) return;
    _activeEnvironment = env;
    _syncRust();
    _changes.add(null);
  }

  void _syncRust() {
    final active = _byId.values
        .where((z) => z.environment == _activeEnvironment)
        .map(_toDto)
        .toList();
    _pushPrototypes(active);
  }

  Future<void> _persistSidecar() async {
    final file = await _file();
    final data = _byId.values.map((z) => z.toJson()).toList();
    await file.writeAsString(jsonEncode(data));
  }

  Future<File> _file() async {
    final override = _overrideDir;
    final dir = override != null
        ? Directory(override)
        : await getApplicationDocumentsDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/$_fileName');
  }
}
