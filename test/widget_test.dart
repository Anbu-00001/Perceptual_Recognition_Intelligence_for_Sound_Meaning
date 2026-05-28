// Phase 0 smoke test for the app shell.
// Phase 1 will add unit tests for the Rust DSP modules via dart:ffi against the host
// (linux/macOS) build of libprism_dsp.so.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:prism/main.dart';

void main() {
  testWidgets('Phase 0 home screen mounts', (tester) async {
    await tester.pumpWidget(const PrismApp());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
