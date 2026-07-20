import '../models/cloud_file.dart';
import '../models/fast_transfer.dart';

typedef FastTransferListDirectory =
    Future<List<CloudFile>> Function(String? parentID);
typedef FastTransferCreateDirectory =
    Future<String> Function(String? parentID, String name);

class FastTransferPathResolver {
  final FastTransferListDirectory listDirectory;
  final FastTransferCreateDirectory createDirectory;
  final Map<String, Future<String?>> _cache = {};

  FastTransferPathResolver({
    required this.listDirectory,
    required this.createDirectory,
  });

  Future<String?> resolve(
    FastTransferEntry entry, {
    required String? rootID,
    required bool createDirectories,
  }) async {
    var currentID = rootID;
    for (final name
        in entry.directoryPath.split('/').where((part) => part.isNotEmpty)) {
      if (name == '..') throw const FormatException('目录不能包含 ..');
      final parentID = currentID;
      final key = '${parentID ?? '@root'}/$name';
      currentID = await _cache.putIfAbsent(key, () async {
        final children = await listDirectory(parentID);
        final existing = _findDirectory(children, name);
        if (existing != null) return existing.id;
        if (children.any((file) => file.name == name)) {
          throw FormatException('$name 已被同名文件占用');
        }
        if (!createDirectories) {
          throw FormatException('${entry.path} 包含目录，请开启自动创建目录');
        }
        try {
          return await createDirectory(parentID, name);
        } catch (error, stackTrace) {
          final refreshed = await listDirectory(parentID);
          final racedDirectory = _findDirectory(refreshed, name);
          if (racedDirectory != null) return racedDirectory.id;
          Error.throwWithStackTrace(error, stackTrace);
        }
      });
    }
    return currentID;
  }

  CloudFile? _findDirectory(List<CloudFile> files, String name) =>
      files.where((file) => file.name == name && file.isDirectory).firstOrNull;
}
