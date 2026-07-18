import 'dart:convert';

class FastTransferEntry {
  final String path;
  final int size;
  final String? md5;
  final String? gcid;

  const FastTransferEntry({
    required this.path,
    required this.size,
    this.md5,
    this.gcid,
  });

  String get name => path.split('/').last;
  String get directoryPath =>
      path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
  Map<String, dynamic> toJson() => {
    'path': path,
    'size': size,
    if (md5 != null) 'etag': md5,
    if (gcid != null) 'gcid': gcid,
  };
}

List<FastTransferEntry> parseFastTransferJSON(String text) {
  final root = jsonDecode(text);
  final raw = root is Map ? root['files'] : root;
  if (raw is! List) throw const FormatException('顶层需要包含 files 数组');
  final entries = <FastTransferEntry>[];
  for (var index = 0; index < raw.length; index++) {
    if (raw[index] is! Map) throw FormatException('第 ${index + 1} 项格式无效');
    final value = Map<String, dynamic>.from(raw[index] as Map);
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
      FastTransferEntry(path: path, size: size, md5: md5, gcid: gcid),
    );
  }
  if (entries.isEmpty) throw const FormatException('files 不能为空');
  return entries;
}
