import 'package:intl/intl.dart';

import '../core/utils/format_bytes.dart';

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

  static const supportedAudioExtensions = {
    'mp3',
    'm4a',
    'aac',
    'flac',
    'wav',
    'ogg',
    'oga',
    'opus',
    'wma',
    'ape',
    'alac',
    'amr',
    'aiff',
    'aif',
    'mka',
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

  /// Stable parent directory ID from the cloud API, used for directory-scoped
  /// operations even when the API omits a full display path.
  final String? parentID;
  final String? fullParentIDs;
  final int fileType;

  // Share-specific fields (fileType == 8)
  final String? originalFileId; // underlying file ID in the share record
  final String? shareID;
  final String? shareCode;
  final String? shareUrl;
  final bool? shareIsDirectory;
  final int? downloadCount;

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
    this.parentID,
    this.fullParentIDs,
    this.fileType = 0,
    this.originalFileId,
    this.shareID,
    this.shareCode,
    this.shareUrl,
    this.shareIsDirectory,
    this.downloadCount,
  });

  bool get isVideo {
    if (isDirectory) return false;
    if (fileType == 2) return true;
    final ext = name.split('.').last.toLowerCase();
    return supportedVideoExtensions.contains(ext);
  }

  bool get isIso => !isDirectory && name.toLowerCase().endsWith('.iso');

  bool get isPlayableVideo => isVideo && !isIso;

  bool get isImage => fileType == 1;
  bool get isAudio {
    if (isDirectory) return false;
    if (fileType == 3) return true;
    final ext = name.split('.').last.toLowerCase();
    return supportedAudioExtensions.contains(ext);
  }

  bool get isDocument => fileType == 4;
  bool get isShareRecord => fileType == 8;
  String get shareKindName => shareIsDirectory == true ? '文件夹分享' : '文件分享';

  String get icon {
    if (isDirectory) return 'folder';
    if (isVideo) return 'movie';
    if (isAudio) return 'music_note';
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
      case 8:
        return 'share';
      default:
        return 'insert_drive_file';
    }
  }

  String get typeName {
    if (isDirectory) return '文件夹';
    if (isVideo) return '视频';
    if (isAudio) return '音频';
    const names = {1: '图片', 2: '视频', 4: '文档', 5: '压缩包', 8: '分享', 9: 'BT种子'};
    return names[fileType] ?? '文件';
  }

  String get formattedSize {
    if (size == null) return '--';
    return FormatBytes.format(size!);
  }

  /// Finder 列表中目录名称下方显示的子项统计。
  String? get directoryContentSummary {
    if (!isDirectory) return null;
    final counts = <String>[];
    if (subDirectoryCount != null) {
      counts.add(
        '${NumberFormat.decimalPattern('zh_CN').format(subDirectoryCount)} 个文件夹',
      );
    }
    if (subFileCount != null) {
      counts.add(
        '${NumberFormat.decimalPattern('zh_CN').format(subFileCount)} 个文件',
      );
    }
    return counts.isEmpty ? '文件夹' : '文件夹 · ${counts.join('，')}';
  }

  CloudFile copyWith({
    String? id,
    String? name,
    bool? isDirectory,
    int? size,
    bool clearSize = false,
    String? gcid,
    int? subDirectoryCount,
    int? subFileCount,
    String? modifiedAt,
    String? cloudPath,
    String? parentID,
    bool clearParentID = false,
    String? fullParentIDs,
    bool clearFullParentIDs = false,
    int? fileType,
    String? originalFileId,
    String? shareID,
    String? shareCode,
    String? shareUrl,
    bool? shareIsDirectory,
    int? downloadCount,
  }) {
    return CloudFile(
      id: id ?? this.id,
      name: name ?? this.name,
      isDirectory: isDirectory ?? this.isDirectory,
      size: clearSize ? null : (size ?? this.size),
      gcid: gcid ?? this.gcid,
      subDirectoryCount: subDirectoryCount ?? this.subDirectoryCount,
      subFileCount: subFileCount ?? this.subFileCount,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      cloudPath: cloudPath ?? this.cloudPath,
      parentID: clearParentID ? null : (parentID ?? this.parentID),
      fullParentIDs: clearFullParentIDs
          ? null
          : (fullParentIDs ?? this.fullParentIDs),
      fileType: fileType ?? this.fileType,
      originalFileId: originalFileId ?? this.originalFileId,
      shareID: shareID ?? this.shareID,
      shareCode: shareCode ?? this.shareCode,
      shareUrl: shareUrl ?? this.shareUrl,
      shareIsDirectory: shareIsDirectory ?? this.shareIsDirectory,
      downloadCount: downloadCount ?? this.downloadCount,
    );
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
        json['title'] ??
        '';
    final rawShareUrl = _extractString(json, [
      'shareUrl',
      'share_url',
      'link',
      'url',
    ]);
    final shareID =
        _extractString(json, ['shareId', 'share_id']) ??
        _shareIDFromUrl(rawShareUrl);
    final persistedType = _extractInt(json, ['fileType', 'type']);
    final isShareRecord =
        shareID?.isNotEmpty == true ||
        persistedType == 8 ||
        rawShareUrl?.isNotEmpty == true;
    // delete_share expects the numeric list-record id. The public shareId is
    // retained separately for links and share-content APIs.
    final id = isShareRecord
        ? (_extractString(json, ['id']) ?? shareID ?? '')
        : _extractId(json);
    if (id.isEmpty) throw FormatException('Missing file ID');

    final resourceType = _extractInt(json, ['resType']);
    final type = isShareRecord ? 8 : persistedType ?? 0;
    final shareIsDirectory = isShareRecord
        ? (resourceType == null
              ? _extractBool(json, [
                  'shareIsDirectory',
                  'share_is_directory',
                  'isMultiFileShare',
                  'is_multi_file_share',
                ])
              : resourceType == 2)
        : null;

    bool isDir;
    if (isShareRecord) {
      isDir = false;
    } else {
      final explicitDir = json['isDir'] ?? json['dir'] ?? json['directoryType'];
      if (explicitDir != null) {
        isDir = _truthyDirectoryFlag(explicitDir);
      } else if (resourceType != null) {
        isDir = resourceType == 2;
      } else {
        isDir =
            type == 0 && (json['dirName'] != null || json['children'] != null);
      }
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
      subDirectoryCount: _extractIntDeep(json, [
        'subDirCount',
        'subDirectoryCount',
        'directoryCount',
        'dirCount',
      ]),
      subFileCount: _extractIntDeep(json, [
        'subFileCount',
        'subFileNum',
        'fileCount',
      ]),
      modifiedAt:
          _formatTimestamp(json, [
            'updateTime',
            'updatedAt',
            'modifyTime',
            'createTime',
          ]) ??
          (epoch == null ? null : _formatEpoch(epoch)) ??
          '',
      cloudPath:
          _extractString(json, ['location', 'path', 'fullPath']) ??
          name.toString(),
      parentID: _extractString(json, ['parentId', 'parent_id', 'parentID']),
      fullParentIDs: _extractString(json, [
        'fullParentIds',
        'fullParentIDs',
        'full_parent_ids',
      ]),
      fileType: type,
      originalFileId: isShareRecord
          ? _extractString(json, ['fileId', 'file_id'])
          : null,
      shareID: isShareRecord ? shareID : null,
      shareCode: isShareRecord
          ? (_extractString(json, ['shareCode', 'share_code', 'code']) ??
                _shareCodeFromUrl(rawShareUrl))
          : null,
      shareUrl: isShareRecord ? rawShareUrl : null,
      shareIsDirectory: shareIsDirectory,
      downloadCount: isShareRecord
          ? _extractIntDeep(json, [
              'downloadCount',
              'download_count',
              'downloads',
            ])
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'isDir': isDirectory,
    'size': size,
    'gcid': gcid,
    'subDirCount': subDirectoryCount,
    'subFileCount': subFileCount,
    'updateTime': modifiedAt,
    'path': cloudPath,
    'parentId': parentID,
    'fullParentIds': fullParentIDs,
    'fileType': fileType,
    if (originalFileId != null) 'fileId': originalFileId,
    if (shareID != null) 'shareId': shareID,
    if (shareCode != null) 'shareCode': shareCode,
    if (shareUrl != null) 'shareUrl': shareUrl,
    if (shareIsDirectory != null) 'shareIsDirectory': shareIsDirectory,
    if (downloadCount != null) 'downloadCount': downloadCount,
  };

  static String _extractId(Map<String, dynamic> json) {
    for (final key in [
      'fileId',
      'file_id',
      'resId',
      'res_id',
      'shareId',
      'share_id',
      'fid',
      'id',
    ]) {
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

  static bool? _extractBool(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final v = json[key];
      if (v == null) continue;
      if (v is bool) return v;
      if (v is num) return v != 0;
      final text = v.toString().trim().toLowerCase();
      if (text == 'true' || text == '1') return true;
      if (text == 'false' || text == '0') return false;
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

  static String? _shareIDFromUrl(String? value) {
    if (value == null || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    final shareIndex = uri.pathSegments.indexOf('s');
    if (shareIndex < 0 || shareIndex + 1 >= uri.pathSegments.length) {
      return null;
    }
    final shareID = uri.pathSegments[shareIndex + 1].trim();
    return shareID.isEmpty ? null : shareID;
  }

  static String? _shareCodeFromUrl(String? value) {
    if (value == null || value.isEmpty) return null;
    final code = Uri.tryParse(value)?.queryParameters['code']?.trim();
    return code == null || code.isEmpty ? null : code;
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

  /// Extract a timestamp field from JSON and format it. Handles both epoch
  /// numbers (int/double) and pre-formatted date strings.
  static String? _formatTimestamp(
    Map<String, dynamic> json,
    List<String> keys,
  ) {
    for (final key in keys) {
      final v = json[key];
      if (v == null) continue;
      if (v is num) return _formatEpoch(v.toInt());
      final s = v.toString().trim();
      if (s.isEmpty) continue;
      // Try parsing as epoch number (pure digits)
      final parsed = int.tryParse(s);
      if (parsed != null) return _formatEpoch(parsed);
      // Already a formatted string like "2024-07-22 10:30:00"
      return s;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CloudFile && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
