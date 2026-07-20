import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/core/utils/json_deep.dart';

void main() {
  test('finds values through nested maps and lists', () {
    final value = {
      'data': [
        {
          'payload': {'fileId': '42', 'enabled': '1'},
        },
      ],
    };

    expect(JsonDeep.findString(value, ['fileId']), '42');
    expect(JsonDeep.findInt(value, ['fileId']), 42);
    expect(JsonDeep.findBool(value, ['enabled']), isTrue);
  });

  test('continues after an invalid matching value', () {
    final value = {
      'size': 'unknown',
      'nested': {'size': '2048'},
    };

    expect(JsonDeep.findInt(value, ['size']), 2048);
  });

  test('finds maps and arrays without assuming string-keyed input', () {
    final value = <dynamic, dynamic>{
      'wrapper': {
        'metadata': {'id': 7},
        'children': [1, 2, 3],
      },
    };

    expect(JsonDeep.findMap(value, ['metadata']), {'id': 7});
    expect(JsonDeep.findArray(value, ['children']), [1, 2, 3]);
  });
}
