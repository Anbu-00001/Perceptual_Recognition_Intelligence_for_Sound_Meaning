import 'package:flutter/material.dart';

import 'src/rust/frb_generated.dart';
import 'src/ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize the Rust runtime. This loads the cdylib and sets up the FRB dispatch.
  await RustLib.init();
  runApp(const PrismApp());
}

class PrismApp extends StatelessWidget {
  const PrismApp({super.key});

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
        // Accessibility defaults: high contrast, generous tap targets.
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 16),
          titleLarge: TextStyle(fontWeight: FontWeight.w600),
        ),
        visualDensity: VisualDensity.standard,
      ),
      home: const HomeScreen(),
    );
  }
}
