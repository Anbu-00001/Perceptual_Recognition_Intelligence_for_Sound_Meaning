import 'dart:async';

import 'package:flutter/material.dart';

import 'src/audio/device_profile.dart';
import 'src/diag/startup_profiler.dart';
import 'src/rust/frb_generated.dart';
import 'src/spatial/room_zone_repository.dart';
import 'src/ui/home_screen.dart';

Future<void> main() async {
  final profiler = StartupProfiler();
  profiler.mark('main_entered');

  WidgetsFlutterBinding.ensureInitialized();
  profiler.mark('widgets_binding_ready');

  await RustLib.init();
  profiler.mark('rust_lib_init');

  // Device profile is fetched off the critical path — runApp doesn't await it.
  // The home screen consumes the future and shows a banner if needed.
  final deviceProfileFuture = DeviceProfileService.fetch();
  profiler.mark('device_profile_kicked_off');

  // Phase 3: zone repo loads sidecar + pushes prototypes to Rust off the
  // critical path. Without the eager ensureSynced(), the first event
  // after a cold boot misses zone classification until the user opens
  // the enrollment screen — see ADR 0009 for the bug post-mortem.
  final roomZoneRepo = RoomZoneRepository();
  unawaited(roomZoneRepo.ensureSynced());
  profiler.mark('zone_repo_constructed');

  runApp(PrismApp(
    profiler: profiler,
    deviceProfileFuture: deviceProfileFuture,
    roomZoneRepo: roomZoneRepo,
  ));
  profiler.mark('run_app_returned');
  profiler.dump();
}

class PrismApp extends StatelessWidget {
  const PrismApp({
    super.key,
    this.profiler,
    this.deviceProfileFuture,
    this.roomZoneRepo,
  });

  final StartupProfiler? profiler;
  final Future<DeviceProfile>? deviceProfileFuture;
  final RoomZoneRepository? roomZoneRepo;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PRISM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6A4FE5),
          brightness: Brightness.dark,
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 16),
          titleLarge: TextStyle(fontWeight: FontWeight.w600),
        ),
        visualDensity: VisualDensity.standard,
      ),
      home: HomeScreen(
        deviceProfileFuture: deviceProfileFuture,
        roomZoneRepo: roomZoneRepo,
      ),
    );
  }
}
