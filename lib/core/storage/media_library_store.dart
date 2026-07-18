import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../../models/cloud_file.dart';
import '../../models/media_library.dart';

/// SQLite-backed scraped media cache. The schema intentionally matches the
/// macOS client so its backup database can be merged without deserializing
/// large poster/backdrop BLOBs in Dart.
class MediaLibraryStore {
  Database? _database;

  Future<Database> get _db async {
    if (_database != null) return _database!;
    final databasePath = path.join(
      await getDatabasesPath(),
      'media-library.sqlite3',
    );
    _database = await openDatabase(
      databasePath,
      version: 4,
      onCreate: (db, _) async {
        await _createSchema(db);
      },
      onUpgrade: (db, _, _) async {
        await _createSchema(db);
      },
    );
    await _createSchema(_database!);
    return _database!;
  }

  Future<void> initialize() async {
    await _db;
  }

  Future<bool> get isEmpty async {
    final rows = await (await _db).rawQuery(
      'SELECT COUNT(*) AS count FROM media_libraries',
    );
    return (rows.first['count'] as int? ?? 0) == 0;
  }

  Future<List<MediaLibraryDefinition>> libraries() async {
    final db = await _db;
    final rows = await db.query(
      'media_libraries',
      orderBy: 'updated_at DESC, name COLLATE NOCASE',
    );
    final sources = await db.query(
      'media_library_sources',
      orderBy: 'library_id, sort_order',
    );
    final sourcesByLibrary = <String, List<MediaLibrarySource>>{};
    for (final row in sources) {
      final libraryID = row['library_id']?.toString() ?? '';
      sourcesByLibrary
          .putIfAbsent(libraryID, () => [])
          .add(
            MediaLibrarySource(
              id: row['id']?.toString() ?? '',
              rootID: row['root_id']?.toString(),
              path: row['root_path']?.toString() ?? '未配置目录',
            ),
          );
    }
    return rows.map((row) {
      final id = row['id']?.toString() ?? '';
      return MediaLibraryDefinition(
        id: id,
        name: row['name']?.toString() ?? '未命名媒体库',
        sources:
            sourcesByLibrary[id] ??
            [
              MediaLibrarySource(
                id: '$id-legacy',
                rootID: row['root_id']?.toString(),
                path: row['root_path']?.toString() ?? '未配置目录',
              ),
            ],
        kind: MediaLibraryKind.values.firstWhere(
          (kind) => kind.name == row['kind']?.toString(),
          orElse: () => MediaLibraryKind.mixed,
        ),
        recursive: row['recursive'] != 0,
        minimumSizeMB: _asInt(row['minimum_size_mb']) ?? 50,
        updatedAt: _dateFromEpoch(row['updated_at']),
      );
    }).toList();
  }

  Future<List<MediaLibraryItem>> items({String? libraryID}) async {
    final rows = await (await _db).query(
      'media_items',
      columns: _itemMetadataColumns,
      where: libraryID == null ? null : 'library_id = ?',
      whereArgs: libraryID == null ? null : [libraryID],
      orderBy: 'title COLLATE NOCASE',
    );
    return rows.map(_itemFromRow).toList();
  }

  Future<void> saveLibraries(List<MediaLibraryDefinition> libraries) async {
    final db = await _db;
    await db.transaction((txn) async {
      for (final library in libraries) {
        await txn.insert('media_libraries', {
          'id': library.id,
          'name': library.name,
          'root_id': library.rootID,
          'root_path': library.rootPath,
          'kind': library.kind.name,
          'recursive': library.recursive ? 1 : 0,
          'minimum_size_mb': library.minimumSizeMB,
          'updated_at': _epoch(library.updatedAt),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.delete(
          'media_library_sources',
          where: 'library_id = ?',
          whereArgs: [library.id],
        );
        for (var index = 0; index < library.sources.length; index++) {
          final source = library.sources[index];
          await txn.insert('media_library_sources', {
            'id': source.id,
            'library_id': library.id,
            'root_id': source.rootID,
            'root_path': source.path,
            'sort_order': index,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }

  Future<void> deleteLibrary(String id) async {
    await (await _db).delete(
      'media_libraries',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> replaceItems(List<MediaLibraryItem> items) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.execute('''
        CREATE TEMP TABLE IF NOT EXISTS desired_media_items (
          library_id TEXT NOT NULL,
          file_id TEXT NOT NULL,
          PRIMARY KEY (library_id, file_id)
        )
      ''');
      await txn.delete('desired_media_items');
      for (final item in items) {
        await txn.insert('desired_media_items', {
          'library_id': item.libraryID,
          'file_id': item.file.id,
        });
        await _upsertItem(txn, item);
      }
      // Metadata updates deliberately omit poster/backdrop. Imported artwork is
      // expensive to rebuild and remains valid while the resource still exists.
      await txn.execute('''
        DELETE FROM media_items
        WHERE NOT EXISTS (
          SELECT 1 FROM desired_media_items desired
          WHERE desired.library_id = media_items.library_id
            AND desired.file_id = media_items.file_id
        )
      ''');
    });
  }

  Future<void> upsertItems(Iterable<MediaLibraryItem> items) async {
    final values = items.toList();
    if (values.isEmpty) return;
    await (await _db).transaction((txn) async {
      for (final item in values) {
        await _upsertItem(txn, item);
      }
    });
  }

  Future<MediaLibraryStorageStats> importBackup(String backupPath) async {
    final db = await _db;
    await db.execute('ATTACH DATABASE ? AS imported_backup', [backupPath]);
    try {
      await db.transaction((txn) async {
        await txn.execute(
          'INSERT OR REPLACE INTO media_libraries SELECT * FROM imported_backup.media_libraries',
        );
        await txn.execute(
          'INSERT OR REPLACE INTO media_library_sources SELECT * FROM imported_backup.media_library_sources',
        );
        final importedColumns = await _tableColumns(
          txn,
          'imported_backup',
          'media_items',
        );
        final importedPosterPath = importedColumns.contains('poster_path')
            ? 'poster_path'
            : 'NULL';
        final importedBackdropPath = importedColumns.contains('backdrop_path')
            ? 'backdrop_path'
            : 'NULL';
        await txn.execute('''
          INSERT OR REPLACE INTO media_items (
            library_id, file_id, resource_path, cloud_name, file_size, gcid,
            file_type, tmdb_id, media_kind, title, original_title,
            release_date, overview, poster_path, backdrop_path, poster, backdrop,
            has_chinese_audio, has_chinese_subtitle, collection_id,
            collection_name, updated_at
          )
          SELECT
            library_id, file_id, resource_path, cloud_name, file_size, gcid,
            file_type, tmdb_id, media_kind, title, original_title,
            release_date, overview, $importedPosterPath, $importedBackdropPath,
            NULL, NULL, has_chinese_audio, has_chinese_subtitle, collection_id,
            collection_name, updated_at
          FROM imported_backup.media_items
        ''');
      });
    } finally {
      await db.execute('DETACH DATABASE imported_backup');
    }
    return optimizeStorage();
  }

  /// TMDB artwork is stored by address.  This removes legacy binary artwork
  /// from imported databases, while retaining every media and scrape record.
  Future<MediaLibraryStorageStats> optimizeStorage() async {
    final db = await _db;
    final before = await _databaseBytes(db.path);
    final removedArtwork = await db.rawUpdate('''UPDATE media_items
         SET poster = NULL, backdrop = NULL
         WHERE poster IS NOT NULL OR backdrop IS NOT NULL''');
    try {
      await db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    } on DatabaseException catch (error) {
      // sqflite_darwin can report the successful checkpoint result as
      // "Code=0 not an error". It is not a failed database optimization.
      final text = error.toString();
      if (!text.contains('Code=0') || !text.contains('not an error')) {
        rethrow;
      }
    }
    await db.execute('PRAGMA optimize');
    await db.execute('VACUUM');
    final after = await _databaseBytes(db.path);
    return MediaLibraryStorageStats(
      beforeBytes: before,
      afterBytes: after,
      removedArtworkCount: removedArtwork,
    );
  }

  Future<void> exportBackupTo(String destinationPath) async {
    final db = await _db;
    await db.execute('PRAGMA wal_checkpoint(FULL)');
    await File(db.path).copy(destinationPath);
  }

  Future<void> cacheFolderChildren(
    String? folderID,
    List<CloudFile> files,
  ) async {
    final db = await _db;
    await db.transaction((txn) async {
      for (final file in files) {
        final gcid = file.gcid?.trim();
        if (gcid == null || gcid.isEmpty) continue;
        await txn.insert('file_index', {
          'file_id': file.id,
          'gcid': gcid,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.insert('gcid_details', {
          'gcid': gcid,
          'file_json': jsonEncode(file.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.insert('folder_children', {
        'folder_id': _folderID(folderID),
        'child_ids': jsonEncode(files.map((file) => file.id).toList()),
        'children_json': jsonEncode(
          files.map((file) => file.toJson()).toList(),
        ),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> cacheFiles(List<CloudFile> files) async {
    final db = await _db;
    await db.transaction((txn) async {
      for (final file in files) {
        final gcid = file.gcid?.trim();
        if (gcid == null || gcid.isEmpty) continue;
        await txn.insert('file_index', {
          'file_id': file.id,
          'gcid': gcid,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.insert('gcid_details', {
          'gcid': gcid,
          'file_json': jsonEncode(file.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> cacheFolderChildrenBatch(
    Map<String?, List<CloudFile>> folders,
  ) async {
    if (folders.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      for (final entry in folders.entries) {
        final files = entry.value;
        for (final file in files) {
          final gcid = file.gcid?.trim();
          if (gcid == null || gcid.isEmpty) continue;
          await txn.insert('file_index', {
            'file_id': file.id,
            'gcid': gcid,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          await txn.insert('gcid_details', {
            'gcid': gcid,
            'file_json': jsonEncode(file.toJson()),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await txn.insert('folder_children', {
          'folder_id': _folderID(entry.key),
          'child_ids': jsonEncode(files.map((file) => file.id).toList()),
          'children_json': jsonEncode(
            files.map((file) => file.toJson()).toList(),
          ),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<CloudFile>?> folderChildren(String? folderID) async {
    final rows = await (await _db).query(
      'folder_children',
      columns: ['children_json'],
      where: 'folder_id = ?',
      whereArgs: [_folderID(folderID)],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      final values = jsonDecode(
        rows.first['children_json']?.toString() ?? '[]',
      );
      if (values is! List) return null;
      return values
          .whereType<Map>()
          .map((value) => CloudFile.fromJson(Map<String, dynamic>.from(value)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<List<CloudFile>> allCachedFolderChildren() async {
    final rows = await (await _db).query(
      'folder_children',
      columns: const ['children_json'],
    );
    final values = <String, CloudFile>{};
    for (final row in rows) {
      try {
        final raw = jsonDecode(row['children_json']?.toString() ?? '[]');
        if (raw is! List) continue;
        for (final value in raw.whereType<Map>()) {
          final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
          values[file.id] = file;
        }
      } catch (_) {
        // Ignore a malformed stale folder row and keep the remaining index.
      }
    }
    return values.values.toList();
  }

  Future<List<CloudFile>?> siblingFiles(String fileID) async {
    final rows = await (await _db).query(
      'folder_children',
      columns: const ['children_json'],
      where: 'child_ids LIKE ?',
      whereArgs: ['%"$fileID"%'],
    );
    for (final row in rows) {
      try {
        final raw = jsonDecode(row['children_json']?.toString() ?? '[]');
        if (raw is! List) continue;
        final files = raw
            .whereType<Map>()
            .map(
              (value) => CloudFile.fromJson(Map<String, dynamic>.from(value)),
            )
            .toList();
        if (files.any((file) => file.id == fileID)) return files;
      } catch (_) {
        // A stale cache row should not prevent looking at the next folder.
      }
    }
    return null;
  }

  Future<CloudFile?> cachedFile(String fileID) async {
    final rows = await (await _db).rawQuery(
      '''SELECT d.file_json FROM file_index i
         JOIN gcid_details d ON d.gcid = i.gcid
         WHERE i.file_id = ? LIMIT 1''',
      [fileID],
    );
    if (rows.isEmpty) return null;
    try {
      final value = jsonDecode(rows.first['file_json']?.toString() ?? '{}');
      return value is Map
          ? CloudFile.fromJson(Map<String, dynamic>.from(value))
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> updateFolderChildren(
    String? folderID, {
    Iterable<String> removeIDs = const [],
    Iterable<CloudFile> addOrReplace = const [],
    bool invalidate = false,
  }) async {
    final db = await _db;
    final key = _folderID(folderID);
    if (invalidate) {
      await db.delete(
        'folder_children',
        where: 'folder_id = ?',
        whereArgs: [key],
      );
      return;
    }
    final existing = await folderChildren(folderID);
    if (existing == null) return;
    final removed = removeIDs.toSet();
    final replacement = {for (final file in addOrReplace) file.id: file};
    final children =
        existing
            .where(
              (file) =>
                  !removed.contains(file.id) &&
                  !replacement.containsKey(file.id),
            )
            .toList()
          ..addAll(replacement.values);
    await cacheFolderChildren(folderID, children);
  }

  Future<void> removeFilesFromAllFolders(Iterable<String> fileIDs) async {
    final ids = fileIDs.toSet();
    if (ids.isEmpty) return;
    final db = await _db;
    final rows = await db.query('folder_children');
    final updates = <String, List<CloudFile>>{};
    for (final row in rows) {
      final folderID = row['folder_id']?.toString();
      if (folderID == null) continue;
      try {
        final raw = jsonDecode(row['children_json']?.toString() ?? '[]');
        if (raw is! List) continue;
        final children = raw
            .whereType<Map>()
            .map(
              (value) => CloudFile.fromJson(Map<String, dynamic>.from(value)),
            )
            .toList();
        final retained = children
            .where((file) => !ids.contains(file.id))
            .toList();
        if (retained.length != children.length) updates[folderID] = retained;
      } catch (_) {}
    }
    if (updates.isEmpty) return;
    await db.transaction((txn) async {
      for (final entry in updates.entries) {
        final retained = entry.value;
        await txn.update(
          'folder_children',
          {
            'child_ids': jsonEncode(retained.map((file) => file.id).toList()),
            'children_json': jsonEncode(
              retained.map((file) => file.toJson()).toList(),
            ),
          },
          where: 'folder_id = ?',
          whereArgs: [entry.key],
        );
      }
    });
  }

  Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS media_libraries (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        root_id TEXT,
        root_path TEXT NOT NULL,
        kind TEXT NOT NULL,
        recursive INTEGER NOT NULL DEFAULT 1,
        updated_at REAL,
        minimum_size_mb INTEGER NOT NULL DEFAULT 50
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS media_library_sources (
        id TEXT PRIMARY KEY NOT NULL,
        library_id TEXT NOT NULL,
        root_id TEXT,
        root_path TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS media_items (
        library_id TEXT NOT NULL,
        file_id TEXT NOT NULL,
        resource_path TEXT NOT NULL,
        cloud_name TEXT NOT NULL,
        file_size INTEGER,
        gcid TEXT,
        file_type INTEGER NOT NULL,
        tmdb_id INTEGER,
        media_kind TEXT,
        title TEXT NOT NULL,
        original_title TEXT NOT NULL,
        release_date TEXT NOT NULL,
        overview TEXT NOT NULL,
        poster_path TEXT,
        backdrop_path TEXT,
        poster BLOB,
        backdrop BLOB,
        has_chinese_audio INTEGER NOT NULL DEFAULT 0,
        has_chinese_subtitle INTEGER NOT NULL DEFAULT 0,
        collection_id INTEGER,
        collection_name TEXT,
        updated_at REAL NOT NULL,
        PRIMARY KEY (library_id, file_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS file_index (
        file_id TEXT PRIMARY KEY NOT NULL,
        gcid TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS gcid_details (
        gcid TEXT PRIMARY KEY NOT NULL,
        file_json TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS folder_children (
        folder_id TEXT PRIMARY KEY NOT NULL,
        child_ids TEXT NOT NULL,
        children_json TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_library_title '
      'ON media_items(library_id, title COLLATE NOCASE)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_tmdb_id '
      'ON media_items(tmdb_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_file_index_gcid ON file_index(gcid)',
    );
    await _ensureColumn(db, 'media_items', 'poster_path', 'TEXT');
    await _ensureColumn(db, 'media_items', 'backdrop_path', 'TEXT');
  }

  MediaLibraryItem _itemFromRow(Map<String, Object?> row) {
    return MediaLibraryItem.fromJson({
      'libraryID': row['library_id'],
      'fileID': row['file_id'],
      'resourcePath': row['resource_path'],
      'cloudName': row['cloud_name'],
      'fileSize': row['file_size'],
      'gcid': row['gcid'],
      'fileType': row['file_type'],
      'tmdbID': row['tmdb_id'],
      'mediaKind': row['media_kind'],
      'title': row['title'],
      'originalTitle': row['original_title'],
      'releaseDate': row['release_date'],
      'overview': row['overview'],
      'posterPath': row['poster_path'],
      'backdropPath': row['backdrop_path'],
      'hasChineseAudio': row['has_chinese_audio'] == 1,
      'hasChineseSubtitle': row['has_chinese_subtitle'] == 1,
      'collectionID': row['collection_id'],
      'collectionName': row['collection_name'],
      'updatedAt': _dateFromEpoch(row['updated_at'])?.toIso8601String(),
    });
  }

  Map<String, Object?> _itemRow(MediaLibraryItem item) => {
    'library_id': item.libraryID,
    'file_id': item.file.id,
    'resource_path': item.file.cloudPath,
    'cloud_name': item.file.name,
    'file_size': item.file.size,
    'gcid': item.file.gcid,
    'file_type': item.file.fileType,
    'tmdb_id': item.tmdbID,
    'media_kind': item.mediaKind?.name,
    'title': item.title,
    'original_title': item.originalTitle,
    'release_date': item.releaseDate,
    'overview': item.overview,
    'poster_path': item.posterPath,
    'backdrop_path': item.backdropPath,
    'has_chinese_audio': item.hasChineseAudio ? 1 : 0,
    'has_chinese_subtitle': item.hasChineseSubtitle ? 1 : 0,
    'collection_id': item.collectionID,
    'collection_name': item.collectionName,
    'updated_at': _epoch(item.updatedAt) ?? 0,
  };

  Future<void> _upsertItem(Transaction txn, MediaLibraryItem item) async {
    final values = _itemRow(item);
    final updated = await txn.update(
      'media_items',
      values,
      where: 'library_id = ? AND file_id = ?',
      whereArgs: [item.libraryID, item.file.id],
    );
    if (updated == 0) {
      await txn.insert('media_items', values);
    }
  }

  static int? _asInt(Object? value) =>
      value is int ? value : int.tryParse('$value');

  static double? _epoch(DateTime? value) =>
      value == null ? null : value.millisecondsSinceEpoch / 1000;

  static DateTime? _dateFromEpoch(Object? value) {
    final seconds = value is num ? value.toDouble() : double.tryParse('$value');
    return seconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  }

  static const _rootFolderID = '@root';
  static const _itemMetadataColumns = [
    'library_id',
    'file_id',
    'resource_path',
    'cloud_name',
    'file_size',
    'gcid',
    'file_type',
    'tmdb_id',
    'media_kind',
    'title',
    'original_title',
    'release_date',
    'overview',
    'poster_path',
    'backdrop_path',
    'has_chinese_audio',
    'has_chinese_subtitle',
    'collection_id',
    'collection_name',
    'updated_at',
  ];
  static String _folderID(String? folderID) => folderID ?? _rootFolderID;

  Future<int> _databaseBytes(String databasePath) async {
    var bytes = 0;
    for (final suffix in const ['', '-wal', '-shm']) {
      final file = File('$databasePath$suffix');
      if (await file.exists()) bytes += await file.length();
    }
    return bytes;
  }

  Future<Set<String>> _tableColumns(
    DatabaseExecutor db,
    String schema,
    String table,
  ) async {
    final rows = await db.rawQuery('PRAGMA $schema.table_info($table)');
    return rows
        .map((row) => row['name']?.toString())
        .whereType<String>()
        .toSet();
  }

  Future<void> _ensureColumn(
    DatabaseExecutor db,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await _tableColumns(db, 'main', table);
    if (!columns.contains(column)) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }
}

class MediaLibraryStorageStats {
  final int beforeBytes;
  final int afterBytes;
  final int removedArtworkCount;

  const MediaLibraryStorageStats({
    required this.beforeBytes,
    required this.afterBytes,
    required this.removedArtworkCount,
  });

  int get reclaimedBytes => (beforeBytes - afterBytes).clamp(0, beforeBytes);
}
