import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/core/http/http_error.dart';

void main() {
  test('parseBusinessCode accepts integer and numeric string values', () {
    expect(parseBusinessCode(200), 200);
    expect(parseBusinessCode('401'), 401);
    expect(parseBusinessCode(null), isNull);
    expect(parseBusinessCode('invalid'), isNull);
  });
}
