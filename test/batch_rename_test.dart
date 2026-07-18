import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/batch_rename.dart';
import 'package:guangya_flutter/models/cloud_file.dart';

CloudFile _file(String id, String name, {String folder = '/媒体'}) => CloudFile(
  id: id,
  name: name,
  isDirectory: false,
  cloudPath: '$folder/$name',
);

void main() {
  const collapseNames = BatchRenameRule(
    id: 'collapse',
    kind: BatchRenameRuleKind.regex,
    pattern: r'\d+',
  );

  test('rejects rule-generated names that collide in one folder', () {
    final previews = buildRenamePreviews(
      [_file('1', 'Episode 01.mkv'), _file('2', 'Episode 02.mkv')],
      [collapseNames],
      preserveExtension: true,
    );

    expect(previews.every((item) => item.error != null), isTrue);
    expect(previews.first.error, contains('同名'));
  });

  test('adds stable indexes for rule-generated duplicate names', () {
    final previews = buildRenamePreviews(
      [_file('1', 'Episode 01.mkv'), _file('2', 'Episode 02.mkv')],
      [collapseNames],
      preserveExtension: true,
      conflictStrategy: BatchRenameConflictStrategy.appendIndex,
    );

    expect(previews.map((item) => item.newName), [
      'Episode .mkv',
      'Episode  (2).mkv',
    ]);
    expect(previews.every((item) => item.applicable), isTrue);
  });

  test('allows the same generated name in separate cloud directories', () {
    final previews = buildRenamePreviews(
      [
        _file('1', 'Episode 01.mkv', folder: '/电视剧/第一季'),
        _file('2', 'Episode 02.mkv', folder: '/电视剧/第二季'),
      ],
      [collapseNames],
      preserveExtension: true,
    );

    expect(previews.map((item) => item.newName), [
      'Episode .mkv',
      'Episode .mkv',
    ]);
    expect(previews.every((item) => item.applicable), isTrue);
  });

  test(
    'uses parent IDs for collision scope when display paths are incomplete',
    () {
      final previews = buildRenamePreviews(
        [
          _file('1', 'Episode 01.mkv').copyWith(parentID: 'folder-a'),
          _file('2', 'Episode 02.mkv').copyWith(parentID: 'folder-b'),
        ],
        [collapseNames],
        preserveExtension: true,
      );

      expect(previews.every((item) => item.applicable), isTrue);
    },
  );
}
