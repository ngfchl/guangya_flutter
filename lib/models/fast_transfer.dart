import 'dart:convert';

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class FastTransferEntry {
  final String id;
  final String path;
  final int size;
  final String? md5;
  final String? gcid;

  const FastTransferEntry({
    required this.id,
    required this.path,
    required this.size,
    this.md5,
    this.gcid,
  });

  factory FastTransferEntry.create({
    required String path,
    required int size,
    String? md5,
    String? gcid,
  }) => FastTransferEntry(
    id: _uuid.v4(),
    path: path,
    size: size,
    md5: md5,
    gcid: gcid,
  );

  String get name => path.split('/').last;
  String get directoryPath =>
      path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'size': size,
    if (md5 != null) 'etag': md5,
    if (gcid != null) 'gcid': gcid,
  };

  factory FastTransferEntry.fromJson(Map<String, dynamic> value) =>
      FastTransferEntry(
        id: value['id']?.toString().trim().isNotEmpty == true
            ? value['id'].toString()
            : _uuid.v4(),
        path: value['path']?.toString() ?? '',
        size: value['size'] is int
            ? value['size'] as int
            : int.tryParse('${value['size']}') ?? 0,
        md5: value['etag']?.toString(),
        gcid: value['gcid']?.toString(),
      );
}

enum FastTransferResultState { imported, skipped, failed, cancelled }

class FastTransferResult {
  final String id;
  final FastTransferEntry entry;
  final FastTransferResultState state;
  final String message;
  final DateTime createdAt;
  final String? taskID;
  final String? targetID;
  final List<String> details;
  final String? retryOf;

  const FastTransferResult({
    required this.id,
    required this.entry,
    required this.state,
    required this.message,
    required this.createdAt,
    this.taskID,
    this.targetID,
    this.details = const [],
    this.retryOf,
  });

  factory FastTransferResult.create({
    required FastTransferEntry entry,
    required FastTransferResultState state,
    required String message,
    String? taskID,
    String? targetID,
    List<String> details = const [],
    String? retryOf,
  }) => FastTransferResult(
    id: _uuid.v4(),
    entry: entry,
    state: state,
    message: message,
    createdAt: DateTime.now(),
    taskID: taskID,
    targetID: targetID,
    details: details,
    retryOf: retryOf,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'entry': entry.toJson(),
    'state': state.name,
    'message': message,
    'createdAt': createdAt.toIso8601String(),
    if (taskID != null) 'taskID': taskID,
    if (targetID != null) 'targetID': targetID,
    'details': details,
    if (retryOf != null) 'retryOf': retryOf,
  };

  factory FastTransferResult.fromJson(Map<String, dynamic> value) {
    final state = FastTransferResultState.values.firstWhere(
      (candidate) => candidate.name == value['state']?.toString(),
      orElse: () => FastTransferResultState.failed,
    );
    return FastTransferResult(
      id: value['id']?.toString().trim().isNotEmpty == true
          ? value['id'].toString()
          : _uuid.v4(),
      entry: FastTransferEntry.fromJson(
        Map<String, dynamic>.from(value['entry'] as Map),
      ),
      state: state,
      message: value['message']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(value['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      taskID: value['taskID']?.toString(),
      targetID: value['targetID']?.toString(),
      details:
          (value['details'] as List?)
              ?.map((detail) => detail.toString())
              .toList(growable: false) ??
          const [],
      retryOf: value['retryOf']?.toString(),
    );
  }
}

class FastTransferProgress {
  final int total;
  final int imported;
  final int skipped;
  final int failed;
  final int cancelled;
  final Set<String> activeEntryIDs;

  const FastTransferProgress({
    this.total = 0,
    this.imported = 0,
    this.skipped = 0,
    this.failed = 0,
    this.cancelled = 0,
    this.activeEntryIDs = const {},
  });

  int get processed => imported + skipped + failed + cancelled;
  double get fraction => total == 0 ? 0 : processed / total;
}

class FastTransferSession {
  final List<FastTransferEntry> entries;
  final List<FastTransferResult> results;
  final String? targetID;
  final String targetName;

  const FastTransferSession({
    this.entries = const [],
    this.results = const [],
    this.targetID,
    this.targetName = '云盘根目录',
  });

  Map<String, dynamic> toJson() => {
    'entries': entries.map((entry) => entry.toJson()).toList(),
    'results': results.map((result) => result.toJson()).toList(),
    'targetID': targetID,
    'targetName': targetName,
  };

  factory FastTransferSession.fromJson(
    Map<String, dynamic> value,
  ) => FastTransferSession(
    entries:
        (value['entries'] as List?)
            ?.whereType<Map>()
            .map(
              (entry) =>
                  FastTransferEntry.fromJson(Map<String, dynamic>.from(entry)),
            )
            .toList(growable: false) ??
        const [],
    results:
        (value['results'] as List?)
            ?.whereType<Map>()
            .map(
              (result) => FastTransferResult.fromJson(
                Map<String, dynamic>.from(result),
              ),
            )
            .toList(growable: false) ??
        const [],
    targetID: value['targetID']?.toString(),
    targetName: value['targetName']?.toString() ?? '云盘根目录',
  );
}

/// Metadata extracted from a fast-transfer JSON file (may be null if absent).
class FastTransferMeta {
  final int? totalFilesCount;
  final int? totalSize;
  final String? formattedTotalSize;
  final int? generatedAt;
  final int? scannedFoldersCount;

  const FastTransferMeta({
    this.totalFilesCount,
    this.totalSize,
    this.formattedTotalSize,
    this.generatedAt,
    this.scannedFoldersCount,
  });

  factory FastTransferMeta.fromMap(Map<String, dynamic> root) {
    return FastTransferMeta(
      totalFilesCount: root['totalFilesCount'] as int?,
      totalSize: root['totalSize'] as int?,
      formattedTotalSize: root['formattedTotalSize']?.toString(),
      generatedAt: root['generatedAt'] as int?,
      scannedFoldersCount: root['scannedFoldersCount'] as int?,
    );
  }

  bool get isEmpty =>
      totalFilesCount == null &&
      totalSize == null &&
      formattedTotalSize == null &&
      generatedAt == null &&
      scannedFoldersCount == null;
}

/// Result of parsing a fast-transfer JSON string.
class FastTransferParseResult {
  final List<FastTransferEntry> entries;
  final FastTransferMeta? meta;

  const FastTransferParseResult(this.entries, [this.meta]);
}

List<FastTransferEntry> parseFastTransferJSON(String text) {
  return parseFastTransferJSONWithMeta(text).entries;
}

FastTransferParseResult parseFastTransferJSONWithMeta(String text) {
  final root = jsonDecode(text);
  final Map<String, dynamic>? rootMap =
      root is Map ? Map<String, dynamic>.from(root) : null;
  final raw = rootMap != null && rootMap.containsKey('files')
      ? rootMap['files']
      : root;
  final meta = rootMap != null ? FastTransferMeta.fromMap(rootMap) : null;
  final values = raw is List
      ? raw
      : raw is Map
      ? [raw]
      : throw const FormatException('JSON 需要是单个秒传对象、数组或包含 files 数组');
  final entries = <FastTransferEntry>[];
  for (var index = 0; index < values.length; index++) {
    if (values[index] is! Map) {
      throw FormatException('第 ${index + 1} 项格式无效');
    }
    final value = Map<String, dynamic>.from(values[index] as Map);
    final path = (value['path'] ?? value['filePath'] ?? value['name'] ?? '')
        .toString()
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^/+'), '');
    final size = value['size'] is int
        ? value['size'] as int
        : int.tryParse('${value['size'] ?? value['fileSize'] ?? ''}');
    final md5 = (value['etag'] ?? value['eTag'] ?? value['md5'])
        ?.toString()
        .toLowerCase();
    final gcid = (value['gcid'] ?? value['gcId'])?.toString().toUpperCase();
    if (path.isEmpty ||
        path.split('/').contains('..') ||
        size == null ||
        size < 0 ||
        ((md5 == null || !RegExp(r'^[a-f0-9]{32}$').hasMatch(md5)) &&
            (gcid == null || !RegExp(r'^[A-F0-9]{40}$').hasMatch(gcid)))) {
      throw FormatException('第 ${index + 1} 项缺少有效 path、size 或 MD5/GCID');
    }
    entries.add(
      FastTransferEntry.create(path: path, size: size, md5: md5, gcid: gcid),
    );
  }
  if (entries.isEmpty) throw const FormatException('files 不能为空');
  return FastTransferParseResult(entries, meta);
}
