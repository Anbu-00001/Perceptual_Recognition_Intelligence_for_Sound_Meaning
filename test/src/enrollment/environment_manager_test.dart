import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/enrollment/environment_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EnvironmentManager mgr;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    mgr = EnvironmentManager(prefs: prefs);
  });

  test('default active environment is "home" when nothing is stored', () async {
    expect(await mgr.getActive(), EnvironmentManager.defaultEnv);
  });

  test('setActive persists and is read back', () async {
    await mgr.setActive('office');
    expect(await mgr.getActive(), 'office');
  });

  test('built-in environments are always listed', () async {
    final known = await mgr.listKnown();
    expect(known, containsAll(['home', 'office', 'family', 'travel']));
  });

  test('custom environments are remembered after setActive', () async {
    await mgr.setActive('Cabin');
    final known = await mgr.listKnown();
    expect(known, contains('cabin'));
  });

  test('changes stream emits on setActive', () async {
    final events = <String>[];
    final sub = mgr.changes.listen(events.add);
    await mgr.setActive('office');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(events, contains('office'));
  });

  test('weird input is normalized to safe id', () async {
    await mgr.setActive('Aunty Pat\'s house');
    final active = await mgr.getActive();
    expect(active, matches(RegExp(r'^[a-z0-9_]+$')));
  });
}
