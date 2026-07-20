import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/models/fast_transfer.dart';

void main() {
  test('parses MD5 and GCID entries with stable task identities', () {
    final entries = parseFastTransferJSON(
      jsonEncode({
        'files': [
          {
            'path': 'Movies/a.mkv',
            'size': 10,
            'etag': '0123456789abcdef0123456789abcdef',
          },
          {
            'path': 'TV/b.mkv',
            'size': 20,
            'gcid': '0123456789ABCDEF0123456789ABCDEF01234567',
          },
        ],
      }),
    );

    expect(entries, hasLength(2));
    expect(entries.map((entry) => entry.id).toSet(), hasLength(2));
    expect(entries.first.directoryPath, 'Movies');
    expect(entries.last.name, 'b.mkv');
  });

  test('session preserves task and result relationships', () {
    final entry = FastTransferEntry.create(
      path: 'movie.mkv',
      size: 10,
      gcid: '0123456789ABCDEF0123456789ABCDEF01234567',
    );
    final result = FastTransferResult.create(
      entry: entry,
      state: FastTransferResultState.failed,
      message: '失败',
      retryOf: 'previous-result',
    );
    final session = FastTransferSession(
      entries: [entry],
      results: [result],
      targetID: 'folder-id',
      targetName: '目标目录',
    );

    final restored = FastTransferSession.fromJson(session.toJson());
    expect(restored.entries.single.id, entry.id);
    expect(restored.results.single.entry.id, entry.id);
    expect(restored.results.single.retryOf, 'previous-result');
    expect(restored.targetID, 'folder-id');
  });

  test('parses transfer JSON in a background isolate', () async {
    final entries = await compute(
      parseFastTransferJSON,
      jsonEncode({
        'files': [
          {
            'path': 'Movies/background.mkv',
            'size': 10,
            'gcid': '0123456789ABCDEF0123456789ABCDEF01234567',
          },
        ],
      }),
    );

    expect(entries.single.name, 'background.mkv');
  });

  test('parses one transfer object with string size and lowercase GCID', () {
    final entries = parseFastTransferJSON(
      jsonEncode({
        'path': '电影/A Very Good Girl.mkv',
        'size': '4957402546',
        'gcid': 'b0bd6af0c836aa9684cdfd4a79562c1491621391',
      }),
    );

    expect(entries.single.size, 4957402546);
    expect(entries.single.gcid, 'B0BD6AF0C836AA9684CDFD4A79562C1491621391');
  });
}
