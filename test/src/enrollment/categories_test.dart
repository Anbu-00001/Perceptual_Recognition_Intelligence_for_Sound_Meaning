import 'package:flutter_test/flutter_test.dart';
import 'package:prism/src/enrollment/categories.dart';

void main() {
  test('all categories have unique ids and non-empty labels', () {
    final ids = SoundCategory.all.map((c) => c.id).toList();
    expect(ids.toSet().length, ids.length);
    for (final c in SoundCategory.all) {
      expect(c.id, isNotEmpty);
      expect(c.label, isNotEmpty);
      expect(c.minRecommendedSamples, greaterThanOrEqualTo(1));
    }
  });

  test('fromId returns the matching category', () {
    expect(SoundCategory.fromId('doorbell'), SoundCategory.doorbell);
    expect(SoundCategory.fromId('smoke_alarm'), SoundCategory.smokeAlarm);
  });

  test('fromId falls back to custom for unknown ids', () {
    expect(SoundCategory.fromId('no_such_category'), SoundCategory.custom);
    expect(SoundCategory.fromId(''), SoundCategory.custom);
  });
}
