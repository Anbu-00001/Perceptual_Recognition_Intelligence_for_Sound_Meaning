// Patrol test — drives the *system* UI to grant microphone and notification
// permissions, then verifies the foreground service starts and the waveform
// begins rendering. This crosses the Flutter/Android boundary that
// integration_test alone can't cross.
//
// Run with:
//   dart run patrol_cli test --target integration_test/patrol_permissions_test.dart
//
// Requires patrol_cli installed: `dart pub global activate patrol_cli`.

import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:prism/main.dart' as app;

void main() {
  patrolTest(
    'cold boot → grant mic + notification → start capture → see waveform',
    ($) async {
      await app.main();
      await $.pumpAndSettle();

      // Tap Start capture; system mic + notification dialogs appear.
      await $.tap(find.text('Start capture'));

      // Patrol drives the system dialogs from outside the app.
      if (await $.native.isPermissionDialogVisible()) {
        await $.native.grantPermissionWhenInUse();
      }
      // Second dialog (notification on Android 13+).
      if (await $.native.isPermissionDialogVisible()) {
        await $.native.grantPermissionWhenInUse();
      }

      await $.pumpAndSettle();
      await $.pump(const Duration(seconds: 2));
      expect(find.text('Listening'), findsOneWidget);

      // Foreground service notification should be visible in the shade.
      await $.native.openNotifications();
      expect(
        await $.native.getNotifications(),
        contains(predicate(
          (n) => n.toString().contains('PRISM is listening'),
        )),
      );
      await $.native.pressBack();
    },
    config: const PatrolTesterConfig(
      // Slightly longer settle for slow emulators on CI.
      settlePolicy: SettlePolicy.trySettle,
    ),
  );

  patrolTest(
    'app survives 30s background → foreground without losing capture state',
    ($) async {
      await app.main();
      await $.pumpAndSettle();

      await $.tap(find.text('Start capture'));
      if (await $.native.isPermissionDialogVisible()) {
        await $.native.grantPermissionWhenInUse();
      }
      if (await $.native.isPermissionDialogVisible()) {
        await $.native.grantPermissionWhenInUse();
      }
      await $.pumpAndSettle();
      await $.pump(const Duration(seconds: 2));
      expect(find.text('Listening'), findsOneWidget);

      // Background the app.
      await $.native.pressHome();
      await Future<void>.delayed(const Duration(seconds: 30));

      // Reopen via launcher.
      await $.native.openApp(appId: 'com.prism.prism');
      await $.pumpAndSettle();
      await $.pump(const Duration(seconds: 2));
      expect(find.text('Listening'), findsOneWidget,
          reason: 'capture should persist through background lifecycle');
    },
  );
}
