import 'package:flutter/material.dart';

import 'src/audio/device_profile.dart';
import 'src/diag/startup_profiler.dart';
import 'src/rust/frb_generated.dart';
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

  runApp(PrismApp(
    profiler: profiler,
    deviceProfileFuture: deviceProfileFuture,
  ));
  profiler.mark('run_app_returned');
  profiler.dump();
}

class PrismApp extends StatelessWidget {
  const PrismApp({
    super.key,
    this.profiler,
    this.deviceProfileFuture,
  });

  final StartupProfiler? profiler;
  final Future<DeviceProfile>? deviceProfileFuture;

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
      home: HomeScreen(deviceProfileFuture: deviceProfileFuture),
    );
  }
}
