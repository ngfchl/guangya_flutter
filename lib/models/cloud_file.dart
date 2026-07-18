import 'package:intl/intl.dart';

/// Cloud file model representing a file or folder in the cloud drive.
class CloudFile {
  static const supportedVideoExtensions = {
    'mp4',
    'm4v',
    'mkv',
    'mov',
    'avi',
    'ts',
    'm2ts',
    'mts',
    'webm',
    'flv',
    'f4v',
    'wmv',
    'asf',
    'mpg',
    'mpeg',
    'vob',
    'iso',
    'rm',
    'rmvb',
    '3gp',
    'ogv',
  };

  final String id;
  final String name;
  final bool isDirectory;
  final int? size;
  final String? gcid;
  final int? subDirectoryCount;
  final int? subFileCount;
  final String modifiedAt;
  final String cloudPath;
  final int fileType;

  const CloudFile({
    required this.id,
    required this.name,
    required this.isDirectory,
    this.size,
    this.gcid,
    this.subDirectoryCount,
    this.subFileCount,
    this.modifiedAt = '',
    this.cloudPath = '',
    this.fileType = 0,
  });

  bool get isVideo {
    if (isDirectory) return false;
    if (fileType == 2) return true;
    final ext = name.split('.').last.toLowerCase();
    return supportedVideoExtensions.contains(ext);
  }

  bool get isImage => fileType == 1;
  bool get isAudio => fileType == 3;
  bool get isDocument => fileType == 4;

  String get icon {
    if (isDirectory) return 'folder';
    if (isVideo) return 'movie';
    switch (fileType) {
      case 1:
        return 'image';
      case 2:
        return 'movie';
      case 3:
        return 'music_note';
      case 4:
        return 'description';
      case 5:
      case 9:
        return 'archive';
      default:
        return 'insert_drive_file';
    }
  }

  String get typeName {
    if (isDirectory) return '文件夹';
    if (isVideo) return '视频';
    const names = {1: '图片', 2: '视频', 3: '音频', 4: '文档', 5: '压缩包', 9: 'BT种子'};
    return names[fileType] ?? '文件';
  }

  String get formattedSize {
    if (size == null) return '--';
    return _formatBytes(size!);
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  factory CloudFile.fromJson(Map<String, dynamic> json) {
    final name =
        json['name'] ??
        json['fileName'] ??
        json['file_name'] ??
        json['resName'] ??
        json['res_name'] ??
        json['dirName'] ??
        json['dir_name'] ??
        '';
    final id = _extractId(json);
    if (id.isEmpty) throw FormatException('Missing file ID');

    final resourceType = _extractInt(json, ['resType']);
    final type = _extractInt(json, ['fileType', 'type']) ?? 0;

    bool isDir;
    final explicitDir = json['isDir'] ?? json['dir'] ?? json['directoryType'];
    if (explicitDir != null) {
      isDir = _truthyDirectoryFlag(explicitDir);
    } else if (resourceType != null) {
      isDir = resourceType == 2;
    } else {
      isDir =
          type == 0 && (json['dirName'] != null || json['children'] != null);
    }

    int? fileSize = _extractIntDeep(json, [
      'size',
      'fileSize',
      'resSize',
      'totalSize',
      'dirSize',
      'folderSize',
    ]);
    if (isDir && fileSize == null) fileSize = 0;
    final epoch = _extractIntDeep(json, ['utime', 'ctime']);

    return CloudFile(
      id: id,
      name: name.toString(),
      isDirectory: isDir,
      size: fileSize,
      gcid: _extractStringDeep(json, ['gcid', 'gcId', 'gcidValue', 'hash']),
      subDirectoryCount: _extractIntDeep(json, ['subDirCount']),
      subFileCount: _extractIntDeep(json, ['subFileCount']),
      modifiedAt:
          json['updateTime']?.toString() ??
          json['updatedAt']?.toString() ??
          json['modifyTime']?.toString() ??
          json['createTime']?.toString() ??
          (epoch == null ? null : _formatEpoch(epoch)) ??
          '',
      cloudPath:
          _extractString(json, ['location', 'path', 'fullPath']) ??
          name.toString(),
      fileType: type,
    );
  }

  static String _extractId(Map<String, dynamic> json) {
    for (final key in ['fileId', 'file_id', 'resId', 'res_id', 'fid', 'id']) {
      final v = json[key];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return '';
  }

  static String? _extractString(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final v = json[key];
      if (v != null) return v.toString();
    }
    return null;
  }

  static int? _extractInt(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final v = json[key];
      final value = _toInt(v);
      if (value != null) return value;
    }
    return null;
  }

  static String? _extractStringDeep(
    Map<String, dynamic> json,
    List<String> keys,
  ) {
    final direct = _extractString(json, keys);
    if (direct != null && direct.isNotEmpty) return direct;
    for (final entry in json.entries) {
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        final found = _extractStringDeep(value, keys);
        if (found != null && found.isNotEmpty) return found;
      } else if (value is List) {
        for (final item in value) {
          if (item is Map<String, dynamic>) {
            final found = _extractStringDeep(item, keys);
            if (found != null && found.isNotEmpty) return found;
          }
        }
      }
    }
    return null;
  }

  static int? _extractIntDeep(Map<String, dynamic> json, List<String> keys) {
    final direct = _extractInt(json, keys);
    if (direct != null) return direct;
    for (final entry in json.entries) {
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        final found = _extractIntDeep(value, keys);
        if (found != null) return found;
      } else if (value is List) {
        for (final item in value) {
          if (item is Map<String, dynamic>) {
            final found = _extractIntDeep(item, keys);
            if (found != null) return found;
          }
        }
      }
    }
    return null;
  }

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.toInt();
    return int.tryParse(value.toString());
  }

  static bool _truthyDirectoryFlag(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value == 1;
    final text = value.toString().toLowerCase();
    return text == '1' || text == 'true' || text == 'folder' || text == 'dir';
  }

  static String _formatEpoch(int epoch) {
    final seconds = epoch > 9999999999 ? epoch ~/ 1000 : epoch;
    return DateFormat(
      'yyyy-MM-dd HH:mm',
    ).format(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CloudFile && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
