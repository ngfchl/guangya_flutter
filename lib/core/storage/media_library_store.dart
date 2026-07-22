import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../logging/app_logger.dart';
import '../utils/format_bytes.dart';
import '../../models/cloud_file.dart';
import '../../models/media_library.dart';
import '../../models/media_navigation.dart';

/// SQLite-backed scraped media cache. The schema intentionally matches the
/// macOS client so its backup database can be merged without deserializing
/// large poster/backdrop BLOBs in Dart.
class MediaLibraryStore {
  static Database? _database;
  static Future<Database>? _openingDatabase;
  bool _mediaItemLocationColumnsReady = false;
  Future<void>? _mediaItemLocationColumnsCheck;

  Future<Database> get _db => _openDatabase();

  Future<Database> _openDatabase() {
    if (_database != null) return Future.value(_database!);
    return _openingDatabase ??= _openDatabaseOnce();
  }

  Future<Database> _openDatabaseOnce() async {
    final databasePath = path.join(
      await getDatabasesPath(),
      'media-library.sqlite3',
    );
    _database = await openDatabase(
      databasePath,
      version: 6,
      onCreate: (db, _) async {
        await _createSchema(db);
      },
      onUpgrade: (db, oldVersion, _) async {
        await _createSchema(db);
        if (oldVersion < 5) {
          await _migrateArtworkBlobSchema(db);
        }
      },
    );
    await _createSchema(_database!);
    try {
      final migration = await _migrateArtworkBlobSchema(_database!);
      await _createSchema(_database!);
      if (migration == null) {
        AppLogger.info('Storage', '刮削数据库检查完成，未发现旧图片二进制缓存');
      } else {
        AppLogger.info(
          'Storage',
          '已迁移 ${migration.rows} 条刮削记录，移除 ${FormatBytes.format(migration.artworkBytes)} 图片二进制缓存',
        );
      }
      await _vacuumIfFragmented(_database!);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Storage',
        '刮削数据库迁移或压缩失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
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
    final db = await _db;
    await _ensureMediaItemLocationColumns(db);
    const pageSize = 200;
    final items = <MediaLibraryItem>[];
    for (var offset = 0; ; offset += pageSize) {
      final rows = await db.query(
        'media_items',
        columns: _itemMetadataColumns,
        where: libraryID == null ? null : 'library_id = ?',
        whereArgs: libraryID == null ? null : [libraryID],
        orderBy: 'title COLLATE NOCASE, library_id, file_id',
        limit: pageSize,
        offset: offset,
      );
      items.addAll(rows.map(_itemFromRow));
      if (rows.length < pageSize) break;
    }
    return items;
  }

  Future<List<MediaLibraryItem>> itemsPage({
    String? libraryID,
    String? mediaKind,
    bool unmatchedOnly = false,
    String search = '',
    int limit = 100,
    int offset = 0,
    MediaLibrarySort sort = MediaLibrarySort.addedAt,
  }) async {
    final db = await _db;
    await _ensureMediaItemLocationColumns(db);
    final where = <String>[];
    final args = <Object?>[];
    if (libraryID != null) {
      where.add('library_id = ?');
      args.add(libraryID);
    }
    if (mediaKind != null) {
      where.add('media_kind = ?');
      args.add(mediaKind);
    }
    if (unmatchedOnly) {
      where.add(
        '(media_kind IS NULL OR (tmdb_id IS NULL AND douban_id IS NULL))',
      );
    }
    final query = search.trim().toLowerCase();
    if (query.isNotEmpty) {
      final prefixed = RegExp(
        r'^(tmdb|imdb|douban|豆瓣)\s*[:：]?\s*(.+)$',
      ).firstMatch(query);
      final source = prefixed?.group(1);
      final id = prefixed?.group(2)?.trim() ?? query;
      if (source == 'tmdb') {
        where.add('CAST(tmdb_id AS TEXT) LIKE ?');
        args.add('%$id%');
      } else if (source == 'imdb') {
        where.add('LOWER(imdb_id) LIKE ?');
        args.add('%$id%');
      } else if (source == 'douban' || source == '豆瓣') {
        where.add('LOWER(douban_id) LIKE ?');
        args.add('%$id%');
      } else {
        where.add('''(
          LOWER(title) LIKE ? OR LOWER(original_title) LIKE ? OR
          LOWER(cloud_name) LIKE ? OR LOWER(resource_path) LIKE ? OR
          CAST(tmdb_id AS TEXT) LIKE ? OR LOWER(imdb_id) LIKE ? OR
          LOWER(douban_id) LIKE ?
        )''');
        args.addAll(List<Object?>.filled(7, '%$query%'));
      }
    }
    final rows = await db.query(
      'media_items',
      columns: _itemMetadataColumns,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: _mediaItemsOrderBy(sort),
      limit: limit.clamp(1, 500),
      offset: offset.clamp(0, 1 << 31),
    );
    return rows.map(_itemFromRow).toList(growable: false);
  }

  String _mediaItemsOrderBy(MediaLibrarySort sort) => switch (sort) {
    MediaLibrarySort.addedAt =>
      'updated_at DESC, title COLLATE NOCASE, library_id, file_id',
    MediaLibrarySort.releaseDate =>
      "release_date IS NULL OR release_date = '', release_date DESC, "
          'title COLLATE NOCASE, library_id, file_id',
    MediaLibrarySort.title =>
      'title COLLATE NOCASE, release_date DESC, library_id, file_id',
    MediaLibrarySort.doubanRating =>
      'douban_rating IS NULL, douban_rating DESC, '
          'title COLLATE NOCASE, library_id, file_id',
    MediaLibrarySort.tmdbRating =>
      'tmdb_rating IS NULL, tmdb_rating DESC, '
          'title COLLATE NOCASE, library_id, file_id',
  };

  Future<List<MediaLibraryItem>> workPreviewPage({
    required String libraryID,
    int limit = 15,
    int offset = 0,
  }) async {
    final db = await _db;
    await _ensureMediaItemLocationColumns(db);
    final rows = await db.rawQuery(
      '''
      WITH keyed_items AS (
        SELECT
          rowid AS item_rowid,
          LOWER(COALESCE(title, cloud_name, '')) AS sort_title,
          COALESCE(media_kind, 'unknown') || ':' || CASE
            WHEN tmdb_id IS NOT NULL THEN 'tmdb:' || tmdb_id
            WHEN douban_id IS NOT NULL AND douban_id != ''
              THEN 'douban:' || douban_id
            ELSE 'title:' || LOWER(REPLACE(REPLACE(
              COALESCE(title, cloud_name, ''), ' ', ''), ',', '')) ||
              ':' || SUBSTR(COALESCE(release_date, ''), 1, 4)
          END AS work_key
        FROM media_items
        WHERE library_id = ?
      ), preview_works AS (
        SELECT
          work_key,
          MIN(item_rowid) AS item_rowid,
          MIN(sort_title) AS sort_title
        FROM keyed_items
        GROUP BY work_key
        ORDER BY sort_title, work_key
        LIMIT ? OFFSET ?
      )
      SELECT media_items.*
      FROM preview_works
      JOIN media_items ON media_items.rowid = preview_works.item_rowid
      ORDER BY preview_works.sort_title, preview_works.work_key
      ''',
      [libraryID, limit.clamp(1, 100), offset.clamp(0, 1 << 31)],
    );
    return rows.map(_itemFromRow).toList(growable: false);
  }

  Future<
    ({
      Map<String, MediaLibraryStatistics> libraries,
      MediaLibraryStatistics global,
    })
  >
  statistics() async {
    final db = await _db;
    final byLibrary = <String, MediaLibraryStatistics>{};

    // Each "work" is identified by: tmdb_id (if set), else douban_id (if set),
    // else lowercased title+year.  We count distinct works per kind per library.
    //
    // SQL approach: use a subquery that assigns a work_key per row, then count
    // distinct work_keys grouped by library_id and media_kind.

    // 1. Per-library statistics
    final libRows = await db.rawQuery('''
      SELECT
        library_id,
        media_kind,
        COUNT(DISTINCT work_key) AS work_count
      FROM (
        SELECT
          library_id,
          media_kind,
          CASE
            WHEN tmdb_id IS NOT NULL THEN 'tmdb:' || tmdb_id
            WHEN douban_id IS NOT NULL AND douban_id != '' THEN 'douban:' || douban_id
            ELSE 'title:' || LOWER(REPLACE(REPLACE(title, ' ', ''), ',', '')) ||
                 ':' || SUBSTR(COALESCE(release_date, ''), 1, 4)
          END AS work_key
        FROM media_items
      )
      GROUP BY library_id, media_kind
    ''');

    // 2. Unmatched per library (no tmdb_id AND no douban_id)
    final unmatchedRows = await db.rawQuery('''
      SELECT
        library_id,
        COUNT(DISTINCT work_key) AS unmatched_count
      FROM (
        SELECT
          library_id,
          CASE
            WHEN tmdb_id IS NOT NULL THEN 'tmdb:' || tmdb_id
            WHEN douban_id IS NOT NULL AND douban_id != '' THEN 'douban:' || douban_id
            ELSE 'title:' || LOWER(REPLACE(REPLACE(title, ' ', ''), ',', '')) ||
                 ':' || SUBSTR(COALESCE(release_date, ''), 1, 4)
          END AS work_key
        FROM media_items
        WHERE tmdb_id IS NULL
          AND (douban_id IS NULL OR douban_id = '')
      )
      GROUP BY library_id
    ''');

    // 3. Collections per library
    final collectionRows = await db.rawQuery('''
      SELECT
        library_id,
        COUNT(DISTINCT CASE
          WHEN collection_id IS NOT NULL AND collection_id != '' THEN collection_id
          WHEN collection_name IS NOT NULL AND collection_name != '' THEN collection_name
        END) AS collection_count
      FROM media_items
      WHERE (collection_id IS NOT NULL AND collection_id != '')
         OR (collection_name IS NOT NULL AND collection_name != '')
      GROUP BY library_id
    ''');

    // Merge per-library results
    final unmatchedMap = <String, int>{};
    for (final row in unmatchedRows) {
      unmatchedMap[row['library_id']?.toString() ?? ''] =
          row['unmatched_count'] as int? ?? 0;
    }
    final collectionMap = <String, int>{};
    for (final row in collectionRows) {
      collectionMap[row['library_id']?.toString() ?? ''] =
          row['collection_count'] as int? ?? 0;
    }

    // Accumulate per-library stats
    for (final row in libRows) {
      final libID = row['library_id']?.toString() ?? '';
      final kind = row['media_kind']?.toString() ?? '';
      final count = row['work_count'] as int? ?? 0;
      final existing = byLibrary[libID] ?? const MediaLibraryStatistics();
      byLibrary[libID] = MediaLibraryStatistics(
        total: existing.total + count,
        movies: existing.movies + (kind == 'movie' ? count : 0),
        series: existing.series + (kind == 'tv' ? count : 0),
        unmatched: unmatchedMap[libID] ?? existing.unmatched,
        collections: collectionMap[libID] ?? existing.collections,
      );
    }

    // Ensure all libraries have an entry (pull IDs directly from DB)
    final allLibIDs = await db.rawQuery('SELECT id FROM media_libraries');
    for (final row in allLibIDs) {
      byLibrary.putIfAbsent(
        row['id']?.toString() ?? '',
        () => const MediaLibraryStatistics(),
      );
    }

    // 4. Global statistics (same queries without library_id filter)
    final globalWorkRows = await db.rawQuery('''
      SELECT
        media_kind,
        COUNT(DISTINCT work_key) AS work_count
      FROM (
        SELECT
          media_kind,
          CASE
            WHEN tmdb_id IS NOT NULL THEN 'tmdb:' || tmdb_id
            WHEN douban_id IS NOT NULL AND douban_id != '' THEN 'douban:' || douban_id
            ELSE 'title:' || LOWER(REPLACE(REPLACE(title, ' ', ''), ',', '')) ||
                 ':' || SUBSTR(COALESCE(release_date, ''), 1, 4)
          END AS work_key
        FROM media_items
      )
      GROUP BY media_kind
    ''');

    final globalUnmatched = await db.rawQuery('''
      SELECT COUNT(DISTINCT work_key) AS cnt
      FROM (
        SELECT
          CASE
            WHEN tmdb_id IS NOT NULL THEN 'tmdb:' || tmdb_id
            WHEN douban_id IS NOT NULL AND douban_id != '' THEN 'douban:' || douban_id
            ELSE 'title:' || LOWER(REPLACE(REPLACE(title, ' ', ''), ',', '')) ||
                 ':' || SUBSTR(COALESCE(release_date, ''), 1, 4)
          END AS work_key
        FROM media_items
        WHERE tmdb_id IS NULL
          AND (douban_id IS NULL OR douban_id = '')
      )
    ''');

    final globalCollections = await db.rawQuery('''
      SELECT COUNT(DISTINCT CASE
        WHEN collection_id IS NOT NULL AND collection_id != '' THEN collection_id
        WHEN collection_name IS NOT NULL AND collection_name != '' THEN collection_name
      END) AS cnt
      FROM media_items
      WHERE (collection_id IS NOT NULL AND collection_id != '')
         OR (collection_name IS NOT NULL AND collection_name != '')
    ''');

    var gMovies = 0;
    var gSeries = 0;
    var gTotal = 0;
    for (final row in globalWorkRows) {
      final kind = row['media_kind']?.toString() ?? '';
      final count = row['work_count'] as int? ?? 0;
      gTotal += count;
      if (kind == 'movie') gMovies += count;
      if (kind == 'tv') gSeries += count;
    }

    final global = MediaLibraryStatistics(
      total: gTotal,
      movies: gMovies,
      series: gSeries,
      unmatched: globalUnmatched.isNotEmpty
          ? (globalUnmatched.first['cnt'] as int? ?? 0)
          : 0,
      collections: globalCollections.isNotEmpty
          ? (globalCollections.first['cnt'] as int? ?? 0)
          : 0,
    );

    return (libraries: byLibrary, global: global);
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
    final db = await _db;
    await db.transaction((txn) async {
      // Older databases were created without enforced foreign keys. Delete
      // dependants explicitly so a removed library cannot reappear with stale
      // sources or leave inaccessible media rows behind.
      await txn.delete('media_items', where: 'library_id = ?', whereArgs: [id]);
      await txn.delete(
        'media_library_sources',
        where: 'library_id = ?',
        whereArgs: [id],
      );
      await txn.delete('media_libraries', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> replaceItems(List<MediaLibraryItem> items) async {
    final uniqueItems = <(String, String), MediaLibraryItem>{
      for (final item in items) (item.libraryID, item.id): item,
    }.values.toList(growable: false);
    final db = await _db;
    await _ensureMediaItemLocationColumns(db);
    await db.transaction((txn) async {
      await txn.execute('''
        CREATE TEMP TABLE IF NOT EXISTS desired_media_items (
          library_id TEXT NOT NULL,
          file_id TEXT NOT NULL,
          PRIMARY KEY (library_id, file_id)
        )
      ''');
      await txn.delete('desired_media_items');
      for (final item in uniqueItems) {
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

  Future<void> replaceLibraryItems(
    String libraryID,
    Iterable<MediaLibraryItem> items,
  ) async {
    final uniqueItems = <String, MediaLibraryItem>{
      for (final item in items)
        if (item.libraryID == libraryID) item.id: item,
    }.values.toList(growable: false);
    final db = await _db;
    await _ensureMediaItemLocationColumns(db);
    await db.transaction((txn) async {
      await txn.execute('''
        CREATE TEMP TABLE IF NOT EXISTS desired_library_media_items (
          file_id TEXT PRIMARY KEY
        )
      ''');
      await txn.delete('desired_library_media_items');
      for (final item in uniqueItems) {
        await txn.insert('desired_library_media_items', {'file_id': item.id});
        await _upsertItem(txn, item);
      }
      await txn.execute(
        '''
        DELETE FROM media_items
        WHERE library_id = ?
          AND NOT EXISTS (
            SELECT 1 FROM desired_library_media_items desired
            WHERE desired.file_id = media_items.file_id
          )
        ''',
        [libraryID],
      );
    });
  }

  Future<int> deleteItems(Iterable<MediaLibraryItem> items) async {
    final values = <(String, String), MediaLibraryItem>{
      for (final item in items) (item.libraryID, item.id): item,
    }.values.toList(growable: false);
    if (values.isEmpty) return 0;

    return (await _db).transaction((txn) async {
      var removed = 0;
      for (final item in values) {
        removed += await txn.delete(
          'media_items',
          where: 'library_id = ? AND file_id = ?',
          whereArgs: [item.libraryID, item.id],
        );
      }
      return removed;
    });
  }

  Future<void> replaceItemsByPreviousIDs(
    Iterable<
      ({String previousLibraryID, String previousFileID, MediaLibraryItem item})
    >
    replacements,
  ) async {
    final values = replacements.toList(growable: false);
    if (values.isEmpty) return;
    final db = await _db;
    await _ensureMediaItemLocationColumns(db);
    await db.transaction((txn) async {
      for (final replacement in values) {
        await txn.delete(
          'media_items',
          where: 'library_id = ? AND file_id = ?',
          whereArgs: [
            replacement.previousLibraryID,
            replacement.previousFileID,
          ],
        );
        if (replacement.previousLibraryID != replacement.item.libraryID ||
            replacement.previousFileID != replacement.item.id) {
          await txn.delete(
            'media_items',
            where: 'library_id = ? AND file_id = ?',
            whereArgs: [replacement.item.libraryID, replacement.item.id],
          );
        }
        await _upsertItem(txn, replacement.item);
      }
    });
  }

  Future<void> upsertItems(Iterable<MediaLibraryItem> items) async {
    final values = items.toList();
    if (values.isEmpty) return;
    final db = await _db;
    await _ensureMediaItemLocationColumns(db);
    await db.transaction((txn) async {
      for (final item in values) {
        await _upsertItem(txn, item);
      }
    });
  }

  Future<MediaLibraryStorageStats> importBackup(String backupPath) async {
    final db = await _db;
    await _ensureMediaItemLocationColumns(db);
    await db.execute('ATTACH DATABASE ? AS imported_backup', [backupPath]);
    try {
      await db.transaction((txn) async {
        await txn.delete('media_items');
        await txn.delete('media_library_sources');
        await txn.delete('media_libraries');
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
        final importedParentID = importedColumns.contains('parent_id')
            ? 'parent_id'
            : 'NULL';
        final importedFullParentIDs =
            importedColumns.contains('full_parent_ids')
            ? 'full_parent_ids'
            : 'NULL';
        final importedDoubanID = importedColumns.contains('douban_id')
            ? 'douban_id'
            : 'NULL';
        final importedImdbID = importedColumns.contains('imdb_id')
            ? 'imdb_id'
            : 'NULL';
        final importedTMDBRating = importedColumns.contains('tmdb_rating')
            ? 'tmdb_rating'
            : 'NULL';
        final importedDoubanRating = importedColumns.contains('douban_rating')
            ? 'douban_rating'
            : 'NULL';
        await txn.execute('''
          INSERT OR REPLACE INTO media_items (
            library_id, file_id, resource_path, cloud_name, file_size, gcid,
            file_type, parent_id, full_parent_ids, tmdb_id, douban_id, imdb_id,
            media_kind,
            title, original_title,
            release_date, overview, poster_path, backdrop_path,
            tmdb_rating, douban_rating,
            has_chinese_audio, has_chinese_subtitle, collection_id,
            collection_name, updated_at
          )
          SELECT
            library_id, file_id, resource_path, cloud_name, file_size, gcid,
            file_type, $importedParentID, $importedFullParentIDs,
            tmdb_id, $importedDoubanID, $importedImdbID,
            media_kind, title, original_title,
            release_date, overview, $importedPosterPath, $importedBackdropPath,
            $importedTMDBRating, $importedDoubanRating,
            has_chinese_audio, has_chinese_subtitle, collection_id,
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
    final migration = await _migrateArtworkBlobSchema(db);
    final removedArtwork = migration?.rows ?? 0;
    await _safePragma(db, 'PRAGMA wal_checkpoint(TRUNCATE)');
    await _safePragma(db, 'PRAGMA optimize');
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
    await _safePragma(db, 'PRAGMA wal_checkpoint(FULL)');
    await File(db.path).copy(destinationPath);
  }

  /// Execute a PRAGMA statement, swallowing sqflite_darwin errors that report
  /// a successful operation as "Code=0 SQLITE_OK" / "not an error".
  Future<void> _safePragma(Database db, String pragma) async {
    try {
      await db.rawQuery(pragma);
    } on DatabaseException catch (error) {
      final text = error.toString();
      if (text.contains('SQLITE_OK') ||
          text.contains('Code=0') ||
          text.contains('not an error')) {
        AppLogger.info('Storage', 'PRAGMA 成功（平台静默报告）：$pragma');
        return;
      }
      rethrow;
    }
  }

  Future<void> cacheFolderChildren(
    String? folderID,
    List<CloudFile> files,
  ) async {
    final db = await _db;
    await db.transaction((txn) async {
      await _removeStaleFolderFileIndex(txn, folderID, files);
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
        await _removeStaleFolderFileIndex(txn, entry.key, files);
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

  /// Removes traversal snapshots and the current file-id mapping. The GCID
  /// detail cache remains available permanently.
  Future<void> clearFolderChildrenIndex() async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('folder_children');
      await txn.delete('file_index');
    });
  }

  Future<Map<String, List<CloudFile>>> liveFilesByGCIDs(
    Iterable<String> values,
  ) async {
    final requested = values.where((value) => value.isNotEmpty).toSet();
    if (requested.isEmpty) return const {};
    final rows = await (await _db).rawQuery(
      '''SELECT i.file_id, i.gcid, d.file_json
         FROM file_index i
         JOIN gcid_details d ON d.gcid = i.gcid''',
    );
    final result = <String, List<CloudFile>>{};
    for (final row in rows) {
      final gcid = row['gcid']?.toString();
      final fileID = row['file_id']?.toString();
      if (gcid == null || fileID == null || !requested.contains(gcid)) {
        continue;
      }
      try {
        final raw = jsonDecode(row['file_json']?.toString() ?? '{}');
        if (raw is! Map) continue;
        final file = CloudFile.fromJson(Map<String, dynamic>.from(raw));
        (result[gcid] ??= []).add(file.copyWith(id: fileID, gcid: gcid));
      } catch (_) {
        // Ignore malformed retained GCID details.
      }
    }
    return result;
  }

  Future<void> removeLiveFileIDs(Iterable<String> values) async {
    final ids = values.where((value) => value.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      for (final id in ids) {
        await txn.delete('file_index', where: 'file_id = ?', whereArgs: [id]);
      }
    });
  }

  Future<void> _removeStaleFolderFileIndex(
    DatabaseExecutor txn,
    String? folderID,
    List<CloudFile> files,
  ) async {
    final rows = await txn.query(
      'folder_children',
      columns: const ['child_ids'],
      where: 'folder_id = ?',
      whereArgs: [_folderID(folderID)],
      limit: 1,
    );
    if (rows.isEmpty) return;
    try {
      final raw = jsonDecode(rows.first['child_ids']?.toString() ?? '[]');
      if (raw is! List) return;
      final current = files.map((file) => file.id).toSet();
      for (final oldID in raw.map((value) => value.toString())) {
        if (current.contains(oldID)) continue;
        await txn.delete(
          'file_index',
          where: 'file_id = ?',
          whereArgs: [oldID],
        );
      }
    } catch (_) {
      // Replacing the folder snapshot repairs malformed index data.
    }
  }

  /// Clears cached snapshots for removed folders and every cached descendant.
  /// File/GCID metadata is retained because it can be reused by fast transfer.
  Future<void> removeFolderChildrenSubtrees(Iterable<String> folderIDs) async {
    final pending = folderIDs.where((id) => id.isNotEmpty).toList();
    if (pending.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      final visited = <String>{};
      for (var index = 0; index < pending.length; index++) {
        final folderID = pending[index];
        if (!visited.add(folderID)) continue;
        final rows = await txn.query(
          'folder_children',
          columns: const ['children_json'],
          where: 'folder_id = ?',
          whereArgs: [_folderID(folderID)],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          try {
            final raw = jsonDecode(
              rows.first['children_json']?.toString() ?? '[]',
            );
            if (raw is List) {
              for (final value in raw.whereType<Map>()) {
                final child = CloudFile.fromJson(
                  Map<String, dynamic>.from(value),
                );
                await txn.delete(
                  'file_index',
                  where: 'file_id = ?',
                  whereArgs: [child.id],
                );
                if (child.isDirectory) pending.add(child.id);
              }
            }
          } catch (_) {
            // A malformed stale snapshot can simply be discarded.
          }
        }
        await txn.delete(
          'folder_children',
          where: 'folder_id = ?',
          whereArgs: [_folderID(folderID)],
        );
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

  /// Returns the folder snapshot that still contains [fileID]. An empty
  /// string represents the cloud root; null means no cached parent exists.
  Future<String?> parentFolderID(String fileID) async {
    final rows = await (await _db).query(
      'folder_children',
      columns: const ['folder_id', 'child_ids'],
      where: 'child_ids LIKE ?',
      whereArgs: ['%"$fileID"%'],
    );
    for (final row in rows) {
      try {
        final raw = jsonDecode(row['child_ids']?.toString() ?? '[]');
        if (raw is! List || !raw.any((value) => value.toString() == fileID)) {
          continue;
        }
        final folderID = row['folder_id']?.toString();
        if (folderID == null) continue;
        return folderID == _rootFolderID ? '' : folderID;
      } catch (_) {
        // Ignore malformed snapshots and continue with the next match.
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
        parent_id TEXT,
        full_parent_ids TEXT,
        tmdb_id INTEGER,
        douban_id TEXT,
        imdb_id TEXT,
        media_kind TEXT,
        title TEXT NOT NULL,
        original_title TEXT NOT NULL,
        release_date TEXT NOT NULL,
        overview TEXT NOT NULL,
        poster_path TEXT,
        backdrop_path TEXT,
        tmdb_rating REAL,
        douban_rating REAL,
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
    await _ensureColumn(db, 'media_items', 'parent_id', 'TEXT');
    await _ensureColumn(db, 'media_items', 'full_parent_ids', 'TEXT');
    await _ensureColumn(db, 'media_items', 'douban_id', 'TEXT');
    await _ensureColumn(db, 'media_items', 'imdb_id', 'TEXT');
    await _ensureColumn(db, 'media_items', 'tmdb_rating', 'REAL');
    await _ensureColumn(db, 'media_items', 'douban_rating', 'REAL');
  }

  Future<({int rows, int artworkBytes})?> _migrateArtworkBlobSchema(
    Database db,
  ) async {
    final columns = await _tableColumns(db, 'main', 'media_items');
    if (!columns.contains('poster') && !columns.contains('backdrop')) {
      return null;
    }
    final posterBytes = columns.contains('poster')
        ? 'COALESCE(SUM(LENGTH(poster)), 0)'
        : '0';
    final backdropBytes = columns.contains('backdrop')
        ? 'COALESCE(SUM(LENGTH(backdrop)), 0)'
        : '0';
    final artworkStats = await db.rawQuery('''
      SELECT
        COUNT(*) AS rows,
        $posterBytes + $backdropBytes AS artwork_bytes
      FROM media_items
    ''');
    final rows = _asInt(artworkStats.firstOrNull?['rows']) ?? 0;
    final artworkBytes =
        _asInt(artworkStats.firstOrNull?['artwork_bytes']) ?? 0;
    final posterPathSource = columns.contains('poster_path')
        ? 'poster_path'
        : 'NULL';
    final backdropPathSource = columns.contains('backdrop_path')
        ? 'backdrop_path'
        : 'NULL';
    final parentIDSource = columns.contains('parent_id') ? 'parent_id' : 'NULL';
    final fullParentIDsSource = columns.contains('full_parent_ids')
        ? 'full_parent_ids'
        : 'NULL';
    final doubanIDSource = columns.contains('douban_id') ? 'douban_id' : 'NULL';
    final imdbIDSource = columns.contains('imdb_id') ? 'imdb_id' : 'NULL';
    final tmdbRatingSource = columns.contains('tmdb_rating')
        ? 'tmdb_rating'
        : 'NULL';
    final doubanRatingSource = columns.contains('douban_rating')
        ? 'douban_rating'
        : 'NULL';
    AppLogger.info(
      'Storage',
      '发现旧图片二进制缓存：$rows 条记录，${FormatBytes.format(artworkBytes)}，正在重建精简表',
    );
    await db.transaction((txn) async {
      await txn.execute('''
        CREATE TABLE media_items_compact (
          library_id TEXT NOT NULL,
          file_id TEXT NOT NULL,
          resource_path TEXT NOT NULL,
          cloud_name TEXT NOT NULL,
          file_size INTEGER,
          gcid TEXT,
          file_type INTEGER NOT NULL,
          parent_id TEXT,
          full_parent_ids TEXT,
          tmdb_id INTEGER,
          douban_id TEXT,
          imdb_id TEXT,
          media_kind TEXT,
          title TEXT NOT NULL,
          original_title TEXT NOT NULL,
          release_date TEXT NOT NULL,
          overview TEXT NOT NULL,
          poster_path TEXT,
          backdrop_path TEXT,
          tmdb_rating REAL,
          douban_rating REAL,
          has_chinese_audio INTEGER NOT NULL DEFAULT 0,
          has_chinese_subtitle INTEGER NOT NULL DEFAULT 0,
          collection_id INTEGER,
          collection_name TEXT,
          updated_at REAL NOT NULL,
          PRIMARY KEY (library_id, file_id),
          FOREIGN KEY (library_id) REFERENCES media_libraries(id) ON DELETE CASCADE
        )
      ''');
      await txn.execute('''
        INSERT INTO media_items_compact (
          library_id, file_id, resource_path, cloud_name, file_size, gcid,
          file_type, parent_id, full_parent_ids, tmdb_id, douban_id, imdb_id,
          media_kind, title,
          original_title, release_date, overview, poster_path, backdrop_path,
          tmdb_rating, douban_rating,
          has_chinese_audio, has_chinese_subtitle, collection_id,
          collection_name, updated_at
        )
        SELECT
          library_id, file_id, resource_path, cloud_name, file_size, gcid,
          file_type, $parentIDSource, $fullParentIDsSource, tmdb_id,
          $doubanIDSource, $imdbIDSource,
          media_kind, title, original_title, release_date, overview,
          $posterPathSource, $backdropPathSource,
          $tmdbRatingSource, $doubanRatingSource, has_chinese_audio,
          has_chinese_subtitle, collection_id, collection_name, updated_at
        FROM media_items
      ''');
      await txn.execute('DROP TABLE media_items');
      await txn.execute(
        'ALTER TABLE media_items_compact RENAME TO media_items',
      );
      await _createMediaItemIndexes(txn);
    });
    return (rows: rows, artworkBytes: artworkBytes);
  }

  Future<void> _vacuumIfFragmented(Database db) async {
    final pageCount = await db.rawQuery('PRAGMA page_count');
    final freeList = await db.rawQuery('PRAGMA freelist_count');
    final pages = _asInt(pageCount.firstOrNull?['page_count']) ?? 0;
    final free = _asInt(freeList.firstOrNull?['freelist_count']) ?? 0;
    if (pages == 0 || free < 1024 || free / pages < 0.2) {
      AppLogger.info('Storage', '刮削数据库无需压缩：共 $pages 页，空闲 $free 页');
      return;
    }
    final before = await _databaseBytes(db.path);
    AppLogger.info(
      'Storage',
      '开始压缩刮削数据库：共 $pages 页，空闲 $free 页，当前 ${FormatBytes.format(before)}',
    );
    try {
      await _safePragma(db, 'PRAGMA wal_checkpoint(TRUNCATE)');
      await db.execute('VACUUM');
      final after = await _databaseBytes(db.path);
      AppLogger.info(
        'Storage',
        '刮削数据库压缩完成：${FormatBytes.format(before)} -> ${FormatBytes.format(after)}，回收 ${FormatBytes.format((before - after).clamp(0, before))}',
      );
    } on DatabaseException catch (error) {
      AppLogger.warning('Storage', '刮削数据库压缩未完成：$error');
    }
  }

  Future<void> _createMediaItemIndexes(DatabaseExecutor db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_library_title '
      'ON media_items(library_id, title COLLATE NOCASE)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_tmdb_id '
      'ON media_items(tmdb_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_gcid ON media_items(gcid)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_collection '
      'ON media_items(library_id, collection_id)',
    );
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
      'parentID': row['parent_id'],
      'fullParentIDs': row['full_parent_ids'],
      'tmdbID': row['tmdb_id'],
      'doubanID': row['douban_id'],
      'imdbID': row['imdb_id'],
      'mediaKind': row['media_kind'],
      'title': row['title'],
      'originalTitle': row['original_title'],
      'releaseDate': row['release_date'],
      'overview': row['overview'],
      'posterPath': row['poster_path'],
      'backdropPath': row['backdrop_path'],
      'tmdbRating': row['tmdb_rating'],
      'doubanRating': row['douban_rating'],
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
    'parent_id': item.file.parentID,
    'full_parent_ids': item.file.fullParentIDs,
    'tmdb_id': item.tmdbID,
    'douban_id': item.doubanID,
    'imdb_id': item.imdbID,
    'media_kind': item.mediaKind?.name,
    'title': item.title,
    'original_title': item.originalTitle,
    'release_date': item.releaseDate,
    'overview': item.overview,
    'poster_path': item.posterPath,
    'backdrop_path': item.backdropPath,
    'tmdb_rating': item.tmdbRating,
    'douban_rating': item.doubanRating,
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
    'parent_id',
    'full_parent_ids',
    'tmdb_id',
    'douban_id',
    'imdb_id',
    'media_kind',
    'title',
    'original_title',
    'release_date',
    'overview',
    'poster_path',
    'backdrop_path',
    'tmdb_rating',
    'douban_rating',
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

  Future<void> _ensureMediaItemLocationColumns(DatabaseExecutor db) async {
    if (_mediaItemLocationColumnsReady) return;
    final pending = _mediaItemLocationColumnsCheck;
    if (pending != null) {
      await pending;
      return;
    }
    final check = () async {
      await _ensureColumn(db, 'media_items', 'parent_id', 'TEXT');
      await _ensureColumn(db, 'media_items', 'full_parent_ids', 'TEXT');
      await _ensureColumn(db, 'media_items', 'tmdb_rating', 'REAL');
      await _ensureColumn(db, 'media_items', 'douban_rating', 'REAL');
      _mediaItemLocationColumnsReady = true;
    }();
    _mediaItemLocationColumnsCheck = check;
    try {
      await check;
    } finally {
      _mediaItemLocationColumnsCheck = null;
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
