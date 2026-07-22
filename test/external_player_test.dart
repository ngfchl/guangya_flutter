import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/providers/file_provider.dart';

void main() {
  test('external player lookup excludes apps nested in the current bundle', () {
    final result = preferredExternalPlayerApplicationPath(const [
      '/tmp/guangya.app/Contents/Resources/IINA.app',
      '/Applications/IINA.app',
    ], currentExecutable: '/tmp/guangya.app/Contents/MacOS/guangya');

    expect(result, '/Applications/IINA.app');
  });

  test('external player lookup returns null for only nested app copies', () {
    final result = preferredExternalPlayerApplicationPath(const [
      '/tmp/guangya.app/Contents/Resources/IINA.app',
    ], currentExecutable: '/tmp/guangya.app/Contents/MacOS/guangya');

    expect(result, isNull);
  });
}
