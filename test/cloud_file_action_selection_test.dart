import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/cloud_file.dart';
import 'package:guangya_flutter/pages/workspace_page.dart';
import 'package:guangya_flutter/providers/file_provider.dart';

CloudFile cloudFile(String id) =>
    CloudFile(id: id, name: id, isDirectory: false);

void main() {
  test('normalizes the configured default file page size', () {
    expect(normalizeFilePageSize('200'), 200);
    expect(normalizeFilePageSize('35'), 50);
    expect(normalizeFilePageSize(null), 50);
  });

  test('context action uses all selected files when target is selected', () {
    final files = [cloudFile('a'), cloudFile('b'), cloudFile('c')];

    final result = resolveCloudFileActionSelection(
      files: files,
      selectedIDs: {'a', 'c'},
      target: files.first,
    );

    expect(result.map((file) => file.id), ['a', 'c']);
  });

  test('context action uses only target when it is outside selection', () {
    final files = [cloudFile('a'), cloudFile('b'), cloudFile('c')];

    final result = resolveCloudFileActionSelection(
      files: files,
      selectedIDs: {'a', 'c'},
      target: files[1],
    );

    expect(result.map((file) => file.id), ['b']);
  });
}
