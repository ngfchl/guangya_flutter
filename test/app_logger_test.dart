import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/core/logging/app_logger.dart';

void main() {
  test('application logs include their call site', () {
    AppLogger.clear();

    AppLogger.info('Media', '测试日志来源');

    final entry = AppLogger.entries.value.single;
    expect(entry.scope, 'Media');
    expect(entry.origin, contains('app_logger_test.dart:'));
    expect(entry.text, contains('[媒体库]'));
    expect(entry.text, contains('测试日志来源'));
  });
}
