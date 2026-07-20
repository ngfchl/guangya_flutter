import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/core/utils/format_bytes.dart';
import 'package:guangya_flutter/utils/extensions.dart';

void main() {
  test('formats byte sizes with stable units and precision', () {
    expect(FormatBytes.format(-1), '0 B');
    expect(FormatBytes.format(1023), '1023 B');
    expect(FormatBytes.format(1536), '1.5 KB');
    expect(FormatBytes.format(1024 * 1024), '1.0 MB');
    expect(FormatBytes.format(1024 * 1024 * 1024), '1.0 GB');
    expect(FormatBytes.format(1024 * 1024 * 1024 * 1024), '1.00 TB');
  });

  test('legacy integer extension delegates to the shared formatter', () {
    expect(1536.formattedBytes, FormatBytes.format(1536));
  });
}
