import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/core/utils/concurrent_map.dart';

void main() {
  test('concurrentMapOrdered bounds work and preserves input order', () async {
    var active = 0;
    var maximumActive = 0;

    final results = await concurrentMapOrdered(
      List.generate(12, (index) => index),
      concurrency: 3,
      action: (value) async {
        active += 1;
        maximumActive = maximumActive < active ? active : maximumActive;
        await Future<void>.delayed(
          Duration(milliseconds: value.isEven ? 8 : 2),
        );
        active -= 1;
        return value * 2;
      },
    );

    expect(maximumActive, 3);
    expect(results, List.generate(12, (index) => index * 2));
  });

  test('concurrentMapOrdered treats non-positive concurrency as one', () async {
    var active = 0;
    var maximumActive = 0;

    await concurrentMapOrdered(
      [1, 2, 3],
      concurrency: 0,
      action: (value) async {
        active += 1;
        maximumActive = maximumActive < active ? active : maximumActive;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        active -= 1;
        return value;
      },
    );

    expect(maximumActive, 1);
  });
}
