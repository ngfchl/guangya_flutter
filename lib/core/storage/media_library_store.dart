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
  // 本地 works 标题查询缓存：同一标题（如 24 集同一剧）只查一次 SQL，
  // 大幅减少本地预筛的 DB 往返。键 = normalized|year|mediaKind|limit。
  final Map<String, List<TMDBWork>> _tmdbTitleSearchCache = {};
  final Map<String, List<DoubanWork>> _doubanTitleSearchCache = {};

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
    AppLogger.info('MediaLibrary', '数据库路径：$databasePath');
    _database = await openDatabase(
      databasePath,
      version: 6,
      onConfigure: (db) async {
        // Enforce declared foreign keys (e.g. media_items -> media_libraries
        // ON DELETE CASCADE). Must run before any query on each connection.
        await db.execute('PRAGMA foreign_keys = ON');
        await _safePragma(db, 'PRAGMA journal_mode = WAL');
        await _safePragma(db, 'PRAGMA synchronous = NORMAL');
        await _safePragma(db, 'PRAGMA busy_timeout = 15000');
      },
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
      // The TMDB/Douban migration scans the whole media_items table, so run it
      // only once (or again after new blob-schema migrations) instead of every
      // cold start. Newly-matched items already write directly to the works
      // tables via upsertTMDBWork/upsertDoubanWork.
      final needsWorkMigration =
          migration != null || await _metaFlag('tmdb_douban_migrated') != '1';
      if (needsWorkMigration) {
        final tmdbMigrated = await migrateTMDBDoubanData();
        if (tmdbMigrated > 0) {
          AppLogger.info('Storage', '已迁移 $tmdbMigrated 条 TMDB/豆瓣数据到独立表');
        }
        await _setMetaFlag('tmdb_douban_migrated', '1');
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
      final legacyRootID = row['root_id']?.toString();
      final legacyRootPath = row['root_path']?.toString();
      // Only synthesise a legacy source when the row actually carries a root.
      // Libraries that intentionally have no sources (e.g. the global library,
      // which scans the whole drive) must stay empty, otherwise a phantom
      // "未配置目录" source leaks into scan paths.
      final hasLegacyRoot =
          (legacyRootID != null && legacyRootID.isNotEmpty) ||
          (legacyRootPath != null && legacyRootPath.isNotEmpty);
      return MediaLibraryDefinition(
        id: id,
        name: row['name']?.toString() ?? '未命名媒体库',
        sources:
            sourcesByLibrary[id] ??
            (hasLegacyRoot
                ? [
                    MediaLibrarySource(
                      id: '$id-legacy',
                      rootID: legacyRootID,
                      path: legacyRootPath ?? '云盘根目录',
                    ),
                  ]
                : const <MediaLibrarySource>[]),
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
    return enrichItemsWithWorkDetails(items);
  }

  /// Loads every media row belonging to one work (all episodes / all versions),
  /// regardless of `distinctWorks` pagination.  The work is identified by its
  /// TMDB id, Douban id, or fallback title+year — matching the work_key the
  /// UI uses to group rows.
  Future<List<MediaLibraryItem>> itemsForWork({
    int? tmdbID,
    String? doubanID,
    String? title,
    int? year,
  }) async {
    final db = await _db;
    await _ensureMediaItemLocationColumns(db);
    final where = <String>[];
    final args = <Object?>[];
    if (tmdbID != null && tmdbID != 0) {
      where.add('tmdb_id = ?');
      args.add(tmdbID);
    } else if (doubanID != null && doubanID.isNotEmpty) {
      where.add('douban_id = ?');
      args.add(doubanID);
    } else {
      final normalized = title?.trim() ?? '';
      if (normalized.isNotEmpty) {
        where.add('title = ?');
        args.add(normalized);
      }
      if (year != null && year > 0) {
        where.add("SUBSTR(COALESCE(release_date, ''), 1, 4) = ?");
        args.add('$year');
      }
    }
    if (where.isEmpty) return const [];
    const pageSize = 200;
    final items = <MediaLibraryItem>[];
    for (var offset = 0; ; offset += pageSize) {
      final rows = await db.query(
        'media_items',
        columns: _itemMetadataColumns,
        where: where.join(' AND '),
        whereArgs: args,
        orderBy: 'title COLLATE NOCASE, library_id, file_id',
        limit: pageSize,
        offset: offset,
      );
      items.addAll(rows.map(_itemFromRow));
      if (rows.length < pageSize) break;
    }
    return enrichItemsWithWorkDetails(items);
  }

  Future<void> allItemsBatched({
    required String? libraryID,
    required Future<void> Function(List<MediaLibraryItem> batch) onBatch,
    bool unmatchedOnly = false,
    int batchSize = 200,
  }) async {
    final db = await _db;
    await _ensureMediaItemLocationColumns(db);
    final where = <String>[];
    final args = <Object?>[];
    if (libraryID != null) {
      where.add('library_id = ?');
      args.add(libraryID);
    }
    if (unmatchedOnly) {
      where.add(
        '(tmdb_id IS NULL OR tmdb_id = \'\') AND (douban_id IS NULL OR douban_id = \'\')',
      );
    }
    // keyset 分页：以 (title, library_id, file_id) 为递增游标，替代 OFFSET。
    // 每页从上一页最后一行之后继续读取，避免 OFFSET 逐页全表扫描 + 重复
    // 排序（大数据量下接近 O(N²)），配合
    // idx_media_items_library_title_file 索引整体降到 O(N)。
    String? cursorTitle;
    String? cursorLibraryID;
    String? cursorFileID;
    var firstPage = true;
    while (true) {
      final pageWhere = <String>[...where];
      final pageArgs = <Object?>[...args];
      if (!firstPage) {
        pageWhere.add(
          '(title COLLATE NOCASE > ? OR '
          '(title COLLATE NOCASE = ? AND '
          '(library_id > ? OR (library_id = ? AND file_id > ?))))',
        );
        pageArgs
          ..add(cursorTitle)
          ..add(cursorTitle)
          ..add(cursorLibraryID)
          ..add(cursorLibraryID)
          ..add(cursorFileID);
      }
      final rows = await db.query(
        'media_items',
        columns: _itemMetadataColumns,
        where: pageWhere.isEmpty ? null : pageWhere.join(' AND '),
        whereArgs: pageArgs.isEmpty ? null : pageArgs,
        orderBy: 'title COLLATE NOCASE, library_id, file_id',
        limit: batchSize,
      );
      if (rows.isEmpty) break;
      firstPage = false;
      final batch = rows.map(_itemFromRow).toList();
      if (batch.isNotEmpty) await onBatch(batch);
      if (rows.length < batchSize) break;
      final last = rows.last;
      cursorTitle = last['title']?.toString() ?? '';
      cursorLibraryID = last['library_id']?.toString() ?? '';
      cursorFileID = last['file_id']?.toString() ?? '';
    }
  }

  Future<List<MediaLibraryItem>> itemsPage({
    String? libraryID,
    String? mediaKind,
    bool unmatchedOnly = false,
    String search = '',
    int limit = 100,
    int offset = 0,
    MediaLibrarySort sort = MediaLibrarySort.addedAt,
    MediaSortDirection direction = MediaSortDirection.descending,
    bool distinctWorks = false,
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
    final safeLimit = limit.clamp(1, 500);
    final safeOffset = offset.clamp(0, 1 << 31);
    final rows = distinctWorks
        ? await db.rawQuery(
            '''
            WITH keyed_items AS (
              SELECT
                rowid AS item_rowid,
                COALESCE(media_kind, 'unknown') || ':' || CASE
                  WHEN tmdb_id IS NOT NULL THEN 'tmdb:' || tmdb_id
                  WHEN douban_id IS NOT NULL AND douban_id != ''
                    THEN 'douban:' || douban_id
                  ELSE 'title:' || COALESCE(title, cloud_name, '') ||
                    ':' || SUBSTR(COALESCE(release_date, ''), 1, 4)
                END AS work_key
              FROM media_items
              ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
            ), selected_works AS (
              SELECT work_key, MIN(item_rowid) AS item_rowid
              FROM keyed_items
              GROUP BY work_key
            )
            SELECT media_items.*
            FROM selected_works
            JOIN media_items ON media_items.rowid = selected_works.item_rowid
            ORDER BY ${_mediaItemsOrderBy(sort, direction)}
            LIMIT ? OFFSET ?
            ''',
            [...args, safeLimit, safeOffset],
          )
        : await db.query(
            'media_items',
            columns: _itemMetadataColumns,
            where: where.isEmpty ? null : where.join(' AND '),
            whereArgs: args.isEmpty ? null : args,
            orderBy: _mediaItemsOrderBy(sort, direction),
            limit: safeLimit,
            offset: safeOffset,
          );
    return rows.map(_itemFromRow).toList(growable: false);
  }

  String _mediaItemsOrderBy(
    MediaLibrarySort sort,
    MediaSortDirection direction,
  ) {
    final order = direction == MediaSortDirection.ascending ? 'ASC' : 'DESC';
    return switch (sort) {
      MediaLibrarySort.addedAt =>
        'updated_at $order, title COLLATE NOCASE, library_id, file_id',
      MediaLibrarySort.releaseDate =>
        "release_date IS NULL OR release_date = '', release_date $order, "
            'title COLLATE NOCASE, library_id, file_id',
      MediaLibrarySort.title =>
        'title COLLATE NOCASE $order, release_date DESC, library_id, file_id',
      MediaLibrarySort.doubanRating =>
        'douban_rating IS NULL, douban_rating $order, '
            'title COLLATE NOCASE, library_id, file_id',
      MediaLibrarySort.tmdbRating =>
        'tmdb_rating IS NULL, tmdb_rating $order, '
            'title COLLATE NOCASE, library_id, file_id',
    };
  }

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

  /// Remove all items whose resource_path contains BDMV or VIDEO_TS
  /// (disc internal files) for the given library in a single SQL query.
  Future<int> removeDiscItems(String libraryID) async {
    final db = await _db;
    final removed = await db.delete(
      'media_items',
      where:
          'library_id = ? AND (resource_path LIKE ? OR resource_path LIKE ?)',
      whereArgs: [libraryID, '%/BDMV/%', '%/VIDEO_TS/%'],
    );
    final removedUnmatched = await db.delete(
      'media_items',
      where:
          'library_id = ? AND (tmdb_id IS NULL OR tmdb_id = \'\') '
          'AND (resource_path LIKE ? OR resource_path LIKE ?)',
      whereArgs: [libraryID, '%BDMV%', '%VIDEO_TS%'],
    );
    final removedM2ts = await db.delete(
      'media_items',
      where:
          'library_id = ? AND (cloud_name LIKE ? OR cloud_name LIKE ? '
          'OR cloud_name LIKE ? OR cloud_name LIKE ? OR cloud_name LIKE ?)',
      whereArgs: [libraryID, '%.m2ts', '%.M2TS', '%.vob', '%.VOB', '%.IFO'],
    );
    return removed + removedUnmatched + removedM2ts;
  }

  /// Remove items matching exclusion folder IDs or keywords via SQL.
  Future<int> removeExcludedItems(
    String libraryID,
    Set<String> excludedFolders,
    List<String> excludedKeywords,
  ) async {
    final db = await _db;
    final conditions = <String>[];
    final args = <Object?>[];

    // 排除文件夹：full_parent_ids 包含排除文件夹ID
    if (excludedFolders.isNotEmpty) {
      for (final folderID in excludedFolders) {
        conditions.add('full_parent_ids LIKE ?');
        args.add('%$folderID%');
      }
    }
    // 排除关键词：文件名或路径包含关键词
    if (excludedKeywords.isNotEmpty) {
      for (final kw in excludedKeywords) {
        conditions.add('(cloud_name LIKE ? OR resource_path LIKE ?)');
        args.addAll(['%$kw%', '%$kw%']);
      }
    }
    if (conditions.isEmpty) return 0;

    final where = conditions.map((c) => '($c)').join(' OR ');
    return db.delete(
      'media_items',
      where: 'library_id = ? AND ($where)',
      whereArgs: [libraryID, ...args],
    );
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
      await _cacheResourceMetadata(txn, files);
      await _removeStaleFolderFileIndex(txn, folderID, files);
      final folderKey = _folderID(folderID);
      for (final file in files) {
        final gcid = file.gcid?.trim();
        if (gcid == null || gcid.isEmpty) continue;
        await txn.insert('file_index', {
          'file_id': file.id,
          'gcid': gcid,
          'folder_id': folderKey,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.insert('gcid_details', {
          'gcid': gcid,
          'file_json': jsonEncode(file.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.insert('folder_children', {
        'folder_id': folderKey,
        'child_ids': jsonEncode(files.map((file) => file.id).toList()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> cacheFiles(List<CloudFile> files) async {
    final db = await _db;
    await db.transaction((txn) async {
      await _cacheResourceMetadata(txn, files);
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

  Future<void> cacheResourceMetadata(Iterable<CloudFile> files) async {
    final values = <String, CloudFile>{
      for (final file in files) file.id: file,
    }.values.toList(growable: false);
    if (values.isEmpty) return;
    final db = await _db;
    const batchSize = 500;
    for (var offset = 0; offset < values.length; offset += batchSize) {
      final end = (offset + batchSize).clamp(0, values.length);
      await db.transaction(
        (txn) => _cacheResourceMetadata(txn, values.sublist(offset, end)),
      );
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> cacheFolderChildrenBatch(
    Map<String?, List<CloudFile>> folders,
  ) async {
    if (folders.isEmpty) return;
    final db = await _db;
    final entries = folders.entries.toList(growable: false);
    const folderBatchSize = 100;
    for (var offset = 0; offset < entries.length; offset += folderBatchSize) {
      final end = (offset + folderBatchSize).clamp(0, entries.length);
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final entry in entries.sublist(offset, end)) {
          final files = entry.value;
          await _cacheResourceMetadata(txn, files);
          await _removeStaleFolderFileIndex(txn, entry.key, files);
          final folderKey = _folderID(entry.key);
          for (final file in files) {
            final gcid = file.gcid?.trim();
            if (gcid == null || gcid.isEmpty) continue;
            batch.insert('file_index', {
              'file_id': file.id,
              'gcid': gcid,
              'folder_id': folderKey,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
            batch.insert('gcid_details', {
              'gcid': gcid,
              'file_json': jsonEncode(file.toJson()),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
          batch.insert('folder_children', {
            'folder_id': folderKey,
            'child_ids': jsonEncode(files.map((file) => file.id).toList()),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Removes traversal snapshots and the current file-id mapping. The GCID
  /// detail cache remains available permanently.
  Future<void> clearFolderChildrenIndex() async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('folder_children');
      await txn.delete('file_index');
      await txn.delete('resource_metadata');
    });
  }

  Future<void> _cacheResourceMetadata(
    DatabaseExecutor txn,
    Iterable<CloudFile> files,
  ) async {
    final resources = <String, CloudFile>{};
    for (final file in files) {
      resources[file.id] = file;
    }

    final batch = txn.batch();
    for (final file in resources.values) {
      batch.insert('resource_metadata', {
        'resource_id': file.id,
        'resource_name': file.name,
        'is_directory': file.isDirectory ? 1 : 0,
        'parent_id': file.parentID,
        'full_parent_ids': file.fullParentIDs,
        'cloud_path': file.cloudPath,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
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
        await txn.delete(
          'resource_metadata',
          where: 'resource_id = ?',
          whereArgs: [id],
        );
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
        await txn.delete(
          'resource_metadata',
          where: 'resource_id = ?',
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
        final rows = await txn.rawQuery(
          '''SELECT d.file_json FROM folder_children f
             JOIN file_index i ON i.folder_id = f.folder_id
             JOIN gcid_details d ON d.gcid = i.gcid
             WHERE f.folder_id = ?''',
          [_folderID(folderID)],
        );
        if (rows.isNotEmpty) {
          try {
            for (final row in rows) {
              final value = jsonDecode(row['file_json']?.toString() ?? '{}');
              if (value is! Map) continue;
              final child = CloudFile.fromJson(
                Map<String, dynamic>.from(value),
              );
              await txn.delete(
                'file_index',
                where: 'file_id = ?',
                whereArgs: [child.id],
              );
              await txn.delete(
                'resource_metadata',
                where: 'resource_id = ?',
                whereArgs: [child.id],
              );
              if (child.isDirectory) pending.add(child.id);
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
        await txn.delete(
          'resource_metadata',
          where: 'resource_id = ?',
          whereArgs: [folderID],
        );
      }
    });
  }

  Future<List<CloudFile>?> folderChildren(String? folderID) async {
    final rows = await (await _db).rawQuery(
      '''SELECT d.file_json FROM folder_children f
         JOIN file_index i ON i.folder_id = f.folder_id
         JOIN gcid_details d ON d.gcid = i.gcid
         WHERE f.folder_id = ?''',
      [_folderID(folderID)],
    );
    if (rows.isEmpty) return null;
    try {
      return rows
          .map((row) => jsonDecode(row['file_json']?.toString() ?? '{}'))
          .whereType<Map>()
          .map((value) => CloudFile.fromJson(Map<String, dynamic>.from(value)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Reads one directory snapshot for cleanup scans and repairs false-empty
  /// snapshots with files still present in the reverse GCID index.
  ///
  /// `folder_children` is a parent -> direct children snapshot table, while
  /// `file_index.folder_id` is an independent reverse lookup for files with a
  /// GCID. Merging both prevents an incomplete snapshot from being reported as
  /// an empty directory.
  Future<List<CloudFile>?> folderChildrenForScan(String? folderID) async {
    final snapshot = await folderChildren(folderID);
    if (snapshot == null) return null;
    final folderKey = _folderID(folderID);
    final rows = await (await _db).rawQuery(
      '''SELECT i.file_id, i.gcid, d.file_json
         FROM file_index i
         JOIN gcid_details d ON d.gcid = i.gcid
         WHERE i.folder_id = ?''',
      [folderKey],
    );
    if (rows.isEmpty) return snapshot;

    final merged = <String, CloudFile>{
      for (final file in snapshot) file.id: file,
    };
    for (final row in rows) {
      final fileID = row['file_id']?.toString();
      final gcid = row['gcid']?.toString();
      if (fileID == null || fileID.isEmpty || merged.containsKey(fileID)) {
        continue;
      }
      try {
        final raw = jsonDecode(row['file_json']?.toString() ?? '{}');
        if (raw is! Map) continue;
        final file = CloudFile.fromJson(Map<String, dynamic>.from(raw));
        merged[fileID] = file.copyWith(
          id: fileID,
          gcid: gcid,
          parentID: folderID,
          clearParentID: folderID == null,
        );
      } catch (_) {
        // Ignore malformed retained metadata; the valid snapshot still wins.
      }
    }
    return merged.values.toList(growable: false);
  }

  Future<List<CloudFile>> allCachedFolderChildren() async {
    final result = <CloudFile>[];
    await allCachedFolderChildrenBatched((batch) async {
      result.addAll(batch);
    });
    return result;
  }

  Future<List<CloudFile>> searchCachedDirectories(
    String query, {
    int limit = 200,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];
    final escaped = normalized
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    final rows = await (await _db).query(
      'resource_metadata',
      columns: const [
        'resource_id',
        'resource_name',
        'is_directory',
        'parent_id',
        'full_parent_ids',
        'cloud_path',
      ],
      where:
          "is_directory = 1 AND resource_name LIKE ? ESCAPE '\\' COLLATE NOCASE",
      whereArgs: ['%$escaped%'],
      orderBy: 'LENGTH(resource_name), resource_name COLLATE NOCASE',
      limit: limit.clamp(1, 500),
    );
    final result = <CloudFile>[];
    for (final row in rows) {
      final folder = CloudFile(
        id: row['resource_id']?.toString() ?? '',
        name: row['resource_name']?.toString() ?? '',
        isDirectory: (row['is_directory'] as int?) == 1,
        parentID: row['parent_id']?.toString(),
        fullParentIDs: row['full_parent_ids']?.toString(),
        cloudPath: row['cloud_path']?.toString() ?? '',
      );
      if (folder.isDirectory) result.add(folder);
    }
    return result;
  }

  Future<Map<String?, List<CloudFile>>> allFolderChildrenSnapshots() async {
    final rows = await (await _db).rawQuery(
      '''SELECT f.folder_id, d.file_json FROM folder_children f
         JOIN file_index i ON i.folder_id = f.folder_id
         JOIN gcid_details d ON d.gcid = i.gcid''',
    );
    final byFolder = <String, List<CloudFile>>{};
    for (final row in rows) {
      final storedFolderID = row['folder_id']?.toString();
      if (storedFolderID == null) continue;
      try {
        final value = jsonDecode(row['file_json']?.toString() ?? '{}');
        if (value is! Map) continue;
        final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
        (byFolder.putIfAbsent(storedFolderID, () => [])).add(file);
      } catch (_) {
        // Ignore a malformed stale snapshot; the next index refresh repairs it.
      }
    }
    final result = <String?, List<CloudFile>>{};
    for (final entry in byFolder.entries) {
      final folderID = entry.key == _rootFolderID ? null : entry.key;
      result[folderID] = entry.value;
    }
    return result;
  }

  /// Process all cached folder children in batches to avoid loading everything
  /// into memory at once. [onBatch] is called for each batch of files.
  Future<void> allCachedFolderChildrenBatched(
    Future<void> Function(List<CloudFile> batch) onBatch, {
    int batchSize = 500,
    bool Function()? shouldStop,
  }) async {
    final db = await _db;
    var offset = 0;
    while (true) {
      if (shouldStop?.call() == true) break;
      final rows = await db.rawQuery(
        '''SELECT d.file_json FROM folder_children f
           JOIN file_index i ON i.folder_id = f.folder_id
           JOIN gcid_details d ON d.gcid = i.gcid
           LIMIT ? OFFSET ?''',
        [batchSize, offset],
      );
      if (rows.isEmpty) break;
      offset += rows.length;
      final batch = <CloudFile>{};
      for (final row in rows) {
        try {
          final value = jsonDecode(row['file_json']?.toString() ?? '{}');
          if (value is! Map) continue;
          batch.add(CloudFile.fromJson(Map<String, dynamic>.from(value)));
        } catch (_) {}
      }
      if (batch.isNotEmpty) await onBatch(batch.toList());
    }
  }

  /// Streams directory snapshots while retaining each snapshot's parent ID.
  /// This is used by cleanup scans to build directory ancestry without loading
  /// the complete `folder_children` table into one Dart map.
  Future<void> folderChildrenSnapshotsBatched(
    Future<void> Function(Map<String?, List<CloudFile>> batch) onBatch, {
    int batchSize = 250,
  }) async {
    final db = await _db;
    var offset = 0;
    while (true) {
      final rows = await db.rawQuery(
        '''SELECT f.folder_id, d.file_json FROM folder_children f
           JOIN file_index i ON i.folder_id = f.folder_id
           JOIN gcid_details d ON d.gcid = i.gcid
           LIMIT ? OFFSET ?''',
        [batchSize, offset],
      );
      if (rows.isEmpty) break;
      offset += rows.length;
      final snapshots = <String?, List<CloudFile>>{};
      final byFolder = <String, List<CloudFile>>{};
      for (final row in rows) {
        final storedFolderID = row['folder_id']?.toString();
        if (storedFolderID == null) continue;
        try {
          final value = jsonDecode(row['file_json']?.toString() ?? '{}');
          if (value is! Map) continue;
          final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
          (byFolder.putIfAbsent(storedFolderID, () => [])).add(file);
        } catch (_) {
          // A malformed snapshot is ignored and repaired by the next refresh.
        }
      }
      for (final entry in byFolder.entries) {
        final folderID = entry.key == _rootFolderID ? null : entry.key;
        snapshots[folderID] = entry.value;
      }
      if (snapshots.isNotEmpty) await onBatch(snapshots);
      if (rows.length < batchSize) break;
    }
  }

  Future<Map<String, Set<String>>> fileIdsByLibrary() async {
    final rows = await (await _db).rawQuery(
      'SELECT library_id, file_id FROM media_items',
    );
    final result = <String, Set<String>>{};
    for (final row in rows) {
      final libID = row['library_id']?.toString() ?? '';
      final fileID = row['file_id']?.toString() ?? '';
      if (fileID.isEmpty) continue;
      result.putIfAbsent(libID, () => <String>{}).add(fileID);
    }
    return result;
  }

  /// Stream file IDs by library in batches to avoid loading all into memory.
  /// Uses keyset pagination over the (library_id, file_id) primary key —
  /// OFFSET-based paging is O(N²) on large tables.
  Future<void> fileIdsByLibraryBatched(
    Future<void> Function(String libraryID, Set<String> ids) onBatch, {
    int batchSize = 500,
  }) async {
    final db = await _db;
    final libIds = <String, Set<String>>{};
    String? cursorLibID;
    String? cursorFileID;
    var firstPage = true;
    while (true) {
      final rows = firstPage
          ? await db.rawQuery(
              'SELECT library_id, file_id FROM media_items '
              'ORDER BY library_id, file_id LIMIT ?',
              [batchSize],
            )
          : await db.rawQuery(
              'SELECT library_id, file_id FROM media_items '
              'WHERE (library_id > ? OR (library_id = ? AND file_id > ?)) '
              'ORDER BY library_id, file_id LIMIT ?',
              [cursorLibID, cursorLibID, cursorFileID, batchSize],
            );
      if (rows.isEmpty) break;
      firstPage = false;
      libIds.clear();
      for (final row in rows) {
        final libID = row['library_id']?.toString() ?? '';
        final fileID = row['file_id']?.toString() ?? '';
        if (fileID.isEmpty) continue;
        libIds.putIfAbsent(libID, () => <String>{}).add(fileID);
      }
      for (final entry in libIds.entries) {
        await onBatch(entry.key, entry.value);
      }
      if (rows.length < batchSize) break;
      final last = rows.last;
      cursorLibID = last['library_id']?.toString() ?? '';
      cursorFileID = last['file_id']?.toString() ?? '';
    }
  }

  /// Streams only the file IDs of unmatched media items (keyset paginated).
  /// Unlike [allItemsBatched], it selects just the id columns instead of
  /// deserialising every full row, so collecting 6 万+ unmatched ids on a
  /// global scan is far cheaper.
  Future<void> unmatchedFileIDsBatched(
    Future<void> Function(List<String> ids) onBatch, {
    required String? libraryID,
    int batchSize = 200,
  }) async {
    final db = await _db;
    final where = <String>[];
    final args = <Object?>[];
    if (libraryID != null) {
      where.add('library_id = ?');
      args.add(libraryID);
    }
    where.add(
      '(tmdb_id IS NULL OR tmdb_id = \'\') AND (douban_id IS NULL OR douban_id = \'\')',
    );
    final baseWhere = where.join(' AND ');
    String? cursorTitle;
    String? cursorLibraryID;
    String? cursorFileID;
    var firstPage = true;
    while (true) {
      final pageWhere = <String>[];
      final pageArgs = <Object?>[];
      pageWhere.add(baseWhere);
      pageArgs.addAll(args);
      if (!firstPage) {
        pageWhere.add(
          '(title COLLATE NOCASE > ? OR '
          '(title COLLATE NOCASE = ? AND '
          '(library_id > ? OR (library_id = ? AND file_id > ?))))',
        );
        pageArgs
          ..add(cursorTitle)
          ..add(cursorTitle)
          ..add(cursorLibraryID)
          ..add(cursorLibraryID)
          ..add(cursorFileID);
      }
      final rows = await db.query(
        'media_items',
        columns: const ['file_id', 'title', 'library_id'],
        where: pageWhere.join(' AND '),
        whereArgs: pageArgs,
        orderBy: 'title COLLATE NOCASE, library_id, file_id',
        limit: batchSize,
      );
      if (rows.isEmpty) break;
      firstPage = false;
      final ids = [
        for (final row in rows)
          if ((row['file_id']?.toString() ?? '').isNotEmpty)
            row['file_id']!.toString(),
      ];
      if (ids.isNotEmpty) await onBatch(ids);
      if (rows.length < batchSize) break;
      final last = rows.last;
      cursorTitle = last['title']?.toString() ?? '';
      cursorLibraryID = last['library_id']?.toString() ?? '';
      cursorFileID = last['file_id']?.toString() ?? '';
    }
  }

  Future<Set<String>> fileIdsForLibrary(String libraryId) async {
    final rows = await (await _db).rawQuery(
      'SELECT file_id FROM media_items WHERE library_id = ?',
      [libraryId],
    );
    return rows
        .map((r) => r['file_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  Future<Set<String>> fileIdsExcludingLibrary(String libraryId) async {
    final rows = await (await _db).rawQuery(
      'SELECT file_id FROM media_items WHERE library_id != ?',
      [libraryId],
    );
    return rows
        .map((r) => r['file_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  Future<List<CloudFile>?> siblingFiles(String fileID) async {
    final db = await _db;
    // Fast path: resolve the owning folder via the indexed reverse lookup,
    // then read that single snapshot instead of scanning every folder.
    final indexed = await db.query(
      'file_index',
      columns: const ['folder_id'],
      where: 'file_id = ? AND folder_id IS NOT NULL',
      whereArgs: [fileID],
      limit: 1,
    );
    if (indexed.isNotEmpty) {
      final folderKey = indexed.first['folder_id']?.toString();
      if (folderKey != null) {
        final snapshot = await db.rawQuery(
          '''SELECT d.file_json FROM folder_children f
             JOIN file_index i ON i.folder_id = f.folder_id
             JOIN gcid_details d ON d.gcid = i.gcid
             WHERE f.folder_id = ?''',
          [folderKey],
        );
        if (snapshot.isNotEmpty) {
          try {
            final files = snapshot
                .map((row) => jsonDecode(row['file_json']?.toString() ?? '{}'))
                .whereType<Map>()
                .map((value) => CloudFile.fromJson(Map<String, dynamic>.from(value)))
                .toList();
            if (files.any((file) => file.id == fileID)) return files;
          } catch (_) {
            // Fall through to the legacy scan below.
          }
        }
      }
    }
    // Fallback for legacy rows written before folder_id existed.
    final rows = await db.rawQuery(
      '''SELECT d.file_json FROM folder_children f
         JOIN file_index i ON i.folder_id = f.folder_id
         JOIN gcid_details d ON d.gcid = i.gcid
         WHERE f.child_ids LIKE ?''',
      ['%"$fileID"%'],
    );
    for (final row in rows) {
      try {
        final value = jsonDecode(row['file_json']?.toString() ?? '{}');
        if (value is! Map) continue;
        final files = [CloudFile.fromJson(Map<String, dynamic>.from(value))];
        if (files.any((file) => file.id == fileID)) return files;
      } catch (_) {
        // A stale cache row should not prevent looking at the next folder.
      }
    }
    return null;
  }

  /// Returns cached [CloudFile] snapshots for [fileIDs], looked up through the
  /// folder listings they belong to.
  ///
  /// Unlike [cachedFile] this does not require a gcid, so it also resolves
  /// directories — which is what lets folder child counts survive a restart.
  Future<Map<String, CloudFile>> cachedFilesByIDs(
    Iterable<String> fileIDs,
  ) async {
    final wanted = fileIDs.toSet();
    if (wanted.isEmpty) return const {};
    final db = await _db;
    final result = <String, CloudFile>{};

    // Resolve the owning folders first so only relevant snapshots are decoded.
    final folderIDs = <String>{};
    for (final chunk in _chunked(wanted.toList(), 500)) {
      final rows = await db.rawQuery(
        'SELECT file_id, folder_id FROM file_index '
        'WHERE file_id IN (${chunk.map((_) => '?').join(',')}) '
        'AND folder_id IS NOT NULL',
        chunk,
      );
      for (final row in rows) {
        final folderID = row['folder_id']?.toString();
        if (folderID != null) folderIDs.add(folderID);
      }
    }
    if (folderIDs.isEmpty) return result;

    for (final chunk in _chunked(folderIDs.toList(), 200)) {
      final rows = await db.rawQuery(
        '''SELECT d.file_json FROM folder_children f
           JOIN file_index i ON i.folder_id = f.folder_id
           JOIN gcid_details d ON d.gcid = i.gcid
           WHERE f.folder_id IN (${chunk.map((_) => '?').join(',')})''',
        chunk,
      );
      for (final row in rows) {
        try {
          final value = jsonDecode(row['file_json']?.toString() ?? '{}');
          if (value is! Map) continue;
          final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
          if (wanted.contains(file.id)) result[file.id] = file;
        } catch (_) {
          // A malformed snapshot should not abort the whole lookup.
        }
      }
    }
    return result;
  }

  /// Returns gcid values for the given file IDs from the file_index table.
  Future<Map<String, String>> gcidsByFileIDs(Iterable<String> fileIDs) async {
    final ids = fileIDs.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) return const {};
    final db = await _db;
    final result = <String, String>{};
    for (final chunk in _chunked(ids.toList(), 500)) {
      final rows = await db.rawQuery(
        'SELECT file_id, gcid FROM file_index '
        'WHERE file_id IN (${chunk.map((_) => '?').join(',')})',
        chunk,
      );
      for (final row in rows) {
        final fileId = row['file_id']?.toString();
        final gcid = row['gcid']?.toString();
        if (fileId != null && gcid != null && gcid.isNotEmpty) {
          result[fileId] = gcid;
        }
      }
    }
    return result;
  }

  /// Returns the folder snapshot that still contains [fileID]. An empty
  /// string represents the cloud root; null means no cached parent exists.
  Future<String?> parentFolderID(String fileID) async {
    final db = await _db;
    // Fast path: indexed reverse lookup via file_index.folder_id.
    final indexed = await db.query(
      'file_index',
      columns: const ['folder_id'],
      where: 'file_id = ? AND folder_id IS NOT NULL',
      whereArgs: [fileID],
      limit: 1,
    );
    if (indexed.isNotEmpty) {
      final folderID = indexed.first['folder_id']?.toString();
      if (folderID != null) return folderID == _rootFolderID ? '' : folderID;
    }
    // Fallback for legacy rows written before folder_id existed.
    final rows = await db.query(
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
    final rows = await db.rawQuery(
      '''SELECT f.folder_id, d.file_json FROM folder_children f
         JOIN file_index i ON i.folder_id = f.folder_id
         JOIN gcid_details d ON d.gcid = i.gcid''',
    );
    final byFolder = <String, List<CloudFile>>{};
    for (final row in rows) {
      final folderID = row['folder_id']?.toString();
      if (folderID == null) continue;
      try {
        final value = jsonDecode(row['file_json']?.toString() ?? '{}');
        if (value is! Map) continue;
        final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
        (byFolder.putIfAbsent(folderID, () => [])).add(file);
      } catch (_) {}
    }
    final updates = <String, List<CloudFile>>{};
    for (final entry in byFolder.entries) {
      final retained = entry.value.where((file) => !ids.contains(file.id)).toList();
      if (retained.length != entry.value.length) updates[entry.key] = retained;
    }
    await db.transaction((txn) async {
      for (final entry in updates.entries) {
        final retained = entry.value;
        await txn.update(
          'folder_children',
          {
            'child_ids': jsonEncode(retained.map((file) => file.id).toList()),
          },
          where: 'folder_id = ?',
          whereArgs: [entry.key],
        );
      }
      for (final id in ids) {
        await txn.delete('file_index', where: 'file_id = ?', whereArgs: [id]);
        await txn.delete(
          'resource_metadata',
          where: 'resource_id = ?',
          whereArgs: [id],
        );
      }
    });
  }

  /// Atomically removes [fileIDs] from all folders AND updates the parent
  /// folder's children list in a single database transaction.
  Future<void> removeFilesAllFoldersAndUpdateParent(
    Iterable<String> fileIDs,
    String? parentID,
  ) async {
    final ids = fileIDs.toSet();
    if (ids.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      for (final id in ids) {
        await txn.delete(
          'resource_metadata',
          where: 'resource_id = ?',
          whereArgs: [id],
        );
      }
      // 1. Remove from all folders (same logic as removeFilesFromAllFolders)
      final rows = await txn.rawQuery(
        '''SELECT f.folder_id, d.file_json FROM folder_children f
           JOIN file_index i ON i.folder_id = f.folder_id
           JOIN gcid_details d ON d.gcid = i.gcid''',
      );
      final byFolder = <String, List<CloudFile>>{};
      for (final row in rows) {
        final folderID = row['folder_id']?.toString();
        if (folderID == null) continue;
        try {
          final value = jsonDecode(row['file_json']?.toString() ?? '{}');
          if (value is! Map) continue;
          final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
          (byFolder.putIfAbsent(folderID, () => [])).add(file);
        } catch (_) {}
      }
      for (final entry in byFolder.entries) {
        final retained = entry.value.where((file) => !ids.contains(file.id)).toList();
        if (retained.length != entry.value.length) {
          await txn.update(
            'folder_children',
            {
              'child_ids': jsonEncode(
                retained.map((file) => file.id).toList(),
              ),
            },
            where: 'folder_id = ?',
            whereArgs: [entry.key],
          );
        }
      }

      // 2. Update parent folder children (same logic as updateFolderChildren)
      final parentKey = _folderID(parentID);
      final parentRows = await txn.rawQuery(
        '''SELECT d.file_json FROM folder_children f
           JOIN file_index i ON i.folder_id = f.folder_id
           JOIN gcid_details d ON d.gcid = i.gcid
           WHERE f.folder_id = ?''',
        [parentKey],
      );
      if (parentRows.isNotEmpty) {
        final parentFiles = parentRows
            .map((row) => jsonDecode(row['file_json']?.toString() ?? '{}'))
            .whereType<Map>()
            .map((value) => CloudFile.fromJson(Map<String, dynamic>.from(value)))
            .toList();
        await _updateParentChildrenInTxn(txn, parentKey, parentFiles, ids);
      }
    });
  }

  Future<void> _updateParentChildrenInTxn(
    Transaction txn,
    String parentKey,
    List<CloudFile> existing,
    Set<String> ids,
  ) async {
    final retained = existing.where((file) => !ids.contains(file.id)).toList();
    if (retained.length == existing.length) return;
    await txn.update(
      'folder_children',
      {
        'child_ids': jsonEncode(retained.map((file) => file.id).toList()),
      },
      where: 'folder_id = ?',
      whereArgs: [parentKey],
    );
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
      CREATE TABLE IF NOT EXISTS store_meta (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS file_index (
        file_id TEXT PRIMARY KEY NOT NULL,
        gcid TEXT NOT NULL,
        folder_id TEXT
      )
    ''');
    // Reverse lookup file_id -> folder_id, replacing the O(N) full-table
    // `child_ids LIKE '%"id"%'` scans in parentFolderID / siblingFiles.
    await _ensureColumn(db, 'file_index', 'folder_id', 'TEXT');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_file_index_folder '
      'ON file_index(folder_id)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS gcid_details (
        gcid TEXT PRIMARY KEY NOT NULL,
        file_json TEXT NOT NULL,
        cid TEXT,
        md5 TEXT
      )
    ''');
    // 旧库迁移：给 gcid_details 补 cid/md5 列（秒传探测需要 cid，校验需要 md5）。
    await _ensureColumn(db, 'gcid_details', 'cid', 'TEXT');
    await _ensureColumn(db, 'gcid_details', 'md5', 'TEXT');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS folder_children (
        folder_id TEXT PRIMARY KEY NOT NULL,
        child_ids TEXT NOT NULL
      )
    ''');
    // 旧库迁移：删除 folder_children.children_json（臃肿的完整 CloudFile 数组，
    // 完整文件信息已由 gcid_details 按 file_id 统一存储）。
    // 先查列是否存在再 DROP，避免已迁移状态报 "no such column" 噪音日志。
    if (await _hasColumn(db, 'folder_children', 'children_json')) {
      await db.execute(
        'ALTER TABLE folder_children DROP COLUMN children_json',
      );
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS resource_metadata (
        resource_id TEXT PRIMARY KEY NOT NULL,
        resource_name TEXT NOT NULL,
        is_directory INTEGER NOT NULL,
        parent_id TEXT,
        full_parent_ids TEXT,
        cloud_path TEXT NOT NULL
      )
    ''');
    // 旧库迁移：删除 resource_metadata.resource_json（141MB 臃肿列，
    // 完整 CloudFile 已由 gcid_details 按 gcid 存储或由 resource_metadata
    // 其余字段重建）。
    // 先查列是否存在再 DROP，避免已迁移状态报 "no such column" 噪音日志。
    if (await _hasColumn(db, 'resource_metadata', 'resource_json')) {
      await db.execute(
        'ALTER TABLE resource_metadata DROP COLUMN resource_json',
      );
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_resource_metadata_directory_name '
      'ON resource_metadata(is_directory, resource_name COLLATE NOCASE)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tmdb_works (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tmdb_id INTEGER UNIQUE NOT NULL,
        title TEXT NOT NULL,
        original_title TEXT DEFAULT '',
        media_kind TEXT DEFAULT 'automatic',
        release_date TEXT DEFAULT '',
        overview TEXT DEFAULT '',
        poster_path TEXT,
        backdrop_path TEXT,
        rating REAL,
        imdb_id TEXT,
        genres TEXT DEFAULT '',
        origin_country TEXT DEFAULT '',
        created_at REAL NOT NULL
      )
    ''');
    // 旧库迁移：补 tmdb_works.genres/origin_country 列（筛选维度扩展）
    if (!await _hasColumn(db, 'tmdb_works', 'genres')) {
      await db.execute('ALTER TABLE tmdb_works ADD COLUMN genres TEXT DEFAULT \'\'');
    }
    if (!await _hasColumn(db, 'tmdb_works', 'origin_country')) {
      await db.execute('ALTER TABLE tmdb_works ADD COLUMN origin_country TEXT DEFAULT \'\'');
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tmdb_works_tmdb_id '
      'ON tmdb_works(tmdb_id)',
    );
    // 本地预筛按标题查询 works，NOCASE 索引让精确匹配走索引而非全表扫描
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tmdb_works_title '
      'ON tmdb_works(title COLLATE NOCASE)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS douban_works (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        douban_id TEXT UNIQUE NOT NULL,
        title TEXT NOT NULL,
        original_title TEXT DEFAULT '',
        media_kind TEXT DEFAULT 'automatic',
        release_date TEXT DEFAULT '',
        overview TEXT DEFAULT '',
        poster_path TEXT,
        rating REAL,
        created_at REAL NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_douban_works_douban_id '
      'ON douban_works(douban_id)',
    );
    // 本地预筛按标题查询 works，NOCASE 索引让精确匹配走索引而非全表扫描
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_douban_works_title '
      'ON douban_works(title COLLATE NOCASE)',
    );
    // ── FTS5 全文索引：替代 LIKE '%x%' 全表扫描，支持标题子串匹配。
    // 外部内容表 + 触发器保持与基础表同步；trigram 分词器要求 ≥3 字符，
    // 短查询由调用方回退 LIKE。
    // 只有本地已有 tmdb_works/douban_works 数据时才建——新安装无媒体信息
    // 时建虚拟表既无数据可索也无必要，且部分 SQLite 编译未启用 fts5 会直接崩。
    final tmdbWorksCount = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM tmdb_works'),
    ) ?? 0;
    final doubanWorksCount = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM douban_works'),
    ) ?? 0;
    if (tmdbWorksCount > 0 || doubanWorksCount > 0) {
      await db.execute(
        'CREATE VIRTUAL TABLE IF NOT EXISTS tmdb_works_fts USING fts5('
        "title, original_title, content='tmdb_works', content_rowid='id', "
        "tokenize='trigram')",
      );
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS tmdb_works_fts_ai AFTER INSERT ON tmdb_works BEGIN
          INSERT INTO tmdb_works_fts(rowid, title, original_title)
          VALUES (new.id, new.title, new.original_title);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS tmdb_works_fts_ad AFTER DELETE ON tmdb_works BEGIN
          INSERT INTO tmdb_works_fts(tmdb_works_fts, rowid, title, original_title)
          VALUES ('delete', old.id, old.title, old.original_title);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS tmdb_works_fts_au AFTER UPDATE ON tmdb_works BEGIN
          INSERT INTO tmdb_works_fts(tmdb_works_fts, rowid, title, original_title)
          VALUES ('delete', old.id, old.title, old.original_title);
          INSERT INTO tmdb_works_fts(rowid, title, original_title)
          VALUES (new.id, new.title, new.original_title);
        END
      ''');
      await db.execute(
        'CREATE VIRTUAL TABLE IF NOT EXISTS douban_works_fts USING fts5('
        "title, original_title, content='douban_works', content_rowid='id', "
        "tokenize='trigram')",
      );
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS douban_works_fts_ai AFTER INSERT ON douban_works BEGIN
          INSERT INTO douban_works_fts(rowid, title, original_title)
          VALUES (new.id, new.title, new.original_title);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS douban_works_fts_ad AFTER DELETE ON douban_works BEGIN
          INSERT INTO douban_works_fts(douban_works_fts, rowid, title, original_title)
          VALUES ('delete', old.id, old.title, old.original_title);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS douban_works_fts_au AFTER UPDATE ON douban_works BEGIN
          INSERT INTO douban_works_fts(douban_works_fts, rowid, title, original_title)
          VALUES ('delete', old.id, old.title, old.original_title);
          INSERT INTO douban_works_fts(rowid, title, original_title)
          VALUES (new.id, new.title, new.original_title);
        END
      ''');
      // 首次建库（或旧库无 FTS 标记）时，用 rebuild 命令把已有 works 补进索引。
      // 注意：此处必须用传入的 db 而非 _db——_createSchema 可能在 onCreate/
      // onUpgrade 期间被调用，此时 _database 尚未赋值，_db 会递归打开（死锁）。
      // trigram 分词器需要 SQLite 3.34+，旧环境建表失败时降级为 LIKE 全表扫描。
      try {
        final ftsRows = await db.query(
          'store_meta',
          columns: const ['value'],
          where: 'key = ?',
          whereArgs: const ['works_fts_built_v1'],
          limit: 1,
        );
        if (ftsRows.isEmpty) {
          await db.execute(
            "INSERT INTO tmdb_works_fts(tmdb_works_fts) VALUES ('rebuild')",
          );
          await db.execute(
            "INSERT INTO douban_works_fts(douban_works_fts) VALUES ('rebuild')",
          );
          await db.insert('store_meta', {
            'key': 'works_fts_built_v1',
            'value': '1',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      } catch (error) {
        AppLogger.warning(
          'Storage',
          'FTS5 works 索引重建失败（降级为 LIKE 查询）：$error',
        );
      }
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_library_title '
      'ON media_items(library_id, title COLLATE NOCASE)',
    );
    // keyset 分页索引：allItemsBatched 按 (title, library_id, file_id) 游标续读
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_library_title_file '
      'ON media_items(library_id, title COLLATE NOCASE, file_id)',
    );
    // 未匹配行（无 tmdb/douban id）部分索引：unmatchedFileIDsBatched 只扫
    // 这些行，跳过已匹配行，大幅缩小 keyset 扫描范围。
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_library_title_file_unmatched '
      'ON media_items(library_id, title COLLATE NOCASE, file_id) '
      'WHERE tmdb_id IS NULL AND douban_id IS NULL',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_tmdb_id '
      'ON media_items(tmdb_id)',
    );
    // 筛选态常用 WHERE：library_id + media_kind 复合索引，覆盖电影/剧集/未识别筛选分页。
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_library_kind '
      'ON media_items(library_id, media_kind)',
    );
    // douban_id drives search, statistics work_key grouping and enrichment,
    // but previously had no index (unlike tmdb_id). Partial index keeps it
    // small by skipping the many NULL rows.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_douban_id '
      'ON media_items(douban_id) WHERE douban_id IS NOT NULL',
    );
    // Sort columns exposed by _mediaItemsOrderBy — avoid full-table scans on
    // large libraries when sorting by release date / recency.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_release '
      'ON media_items(release_date)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_updated '
      'ON media_items(updated_at)',
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
    // keyset 分页索引：allItemsBatched 按 (title, library_id, file_id) 游标续读
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_library_title_file '
      'ON media_items(library_id, title COLLATE NOCASE, file_id)',
    );
    // 未匹配行（无 tmdb/douban id）部分索引：unmatchedFileIDsBatched 只扫
    // 这些行，跳过已匹配行，大幅缩小 keyset 扫描范围。
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_library_title_file_unmatched '
      'ON media_items(library_id, title COLLATE NOCASE, file_id) '
      'WHERE tmdb_id IS NULL AND douban_id IS NULL',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_tmdb_id '
      'ON media_items(tmdb_id)',
    );
    // 筛选态常用 WHERE：library_id + media_kind 复合索引，覆盖电影/剧集/未识别筛选分页。
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_library_kind '
      'ON media_items(library_id, media_kind)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_douban_id '
      'ON media_items(douban_id) WHERE douban_id IS NOT NULL',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_release '
      'ON media_items(release_date)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_updated '
      'ON media_items(updated_at)',
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

  /// Reads a persisted one-off flag/marker from store_meta (null if unset).
  Future<String?> _metaFlag(String key) async {
    final db = await _db;
    final rows = await db.query(
      'store_meta',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value']?.toString();
  }

  Future<void> _setMetaFlag(String key, String value) async {
    final db = await _db;
    await db.insert('store_meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Split [values] into chunks of at most [size] to stay under SQLite's
  /// SQLITE_MAX_VARIABLE_NUMBER limit (999 by default) for `IN (...)` queries.
  static Iterable<List<T>> _chunked<T>(List<T> values, int size) sync* {
    for (var i = 0; i < values.length; i += size) {
      yield values.sublist(i, (i + size).clamp(0, values.length));
    }
  }

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

  // ── TMDB Works ──

  /// Searches the local works table by title (exact then fuzzy).
  ///
  /// Returns candidates ordered by relevance: exact title match first, then
  /// original_title match, then LIKE substring. Year and kind are used as
  /// filters when provided, narrowing the result without requiring a network
  /// round-trip.
  Future<List<TMDBWork>> searchTMDBWorksByTitle(
    String title, {
    int? year,
    String? mediaKind,
    int limit = 10,
  }) async {
    final db = await _db;
    final normalized = title.trim().toLowerCase();
    if (normalized.isEmpty) return const [];

    final cacheKey = '$normalized|$year|$mediaKind|$limit';
    final cached = _tmdbTitleSearchCache[cacheKey];
    if (cached != null) return cached;

    // Phase 1: exact match on title or original_title.
    final exactRows = await db.rawQuery(
      '''
      SELECT * FROM tmdb_works
      WHERE (LOWER(title) = ? OR LOWER(original_title) = ?)
      ${mediaKind != null && mediaKind != 'automatic' ? "AND media_kind = ?" : ''}
      ${year != null ? "AND SUBSTR(release_date, 1, 4) = ?" : ''}
      ORDER BY rating DESC NULLS LAST
      LIMIT ?
    ''',
      [
        normalized,
        normalized,
        if (mediaKind != null && mediaKind != 'automatic') mediaKind,
        if (year != null) '$year',
        limit,
      ],
    );
    if (exactRows.isNotEmpty) {
      final result = exactRows.map((r) => TMDBWork.fromJson(r)).toList();
      _tmdbTitleSearchCache[cacheKey] = result;
      return result;
    }

    // Phase 2: fuzzy match. Prefer FTS5 trigram substring search when the
    // query is long enough (≥3 chars); otherwise fall back to LIKE. FTS5
    // may be unavailable on older SQLite builds, so any failure degrades
    // gracefully to the LIKE scan.
    final likePattern = '%$normalized%';
    List<Map<String, Object?>> fuzzyRows;
    if (normalized.runes.length >= 3) {
      try {
        final escaped = normalized.replaceAll('"', '""');
        fuzzyRows = await db.rawQuery(
          '''
          SELECT t.* FROM tmdb_works t
          JOIN (
            SELECT rowid FROM tmdb_works_fts
            WHERE tmdb_works_fts MATCH ?
          ) f ON f.rowid = t.id
          ${mediaKind != null && mediaKind != 'automatic' ? "WHERE t.media_kind = ?" : ''}
          ${year != null ? "${mediaKind != null && mediaKind != 'automatic' ? 'AND' : 'WHERE'} SUBSTR(t.release_date, 1, 4) = ?" : ''}
          ORDER BY
            CASE WHEN LOWER(t.title) = ? THEN 0 ELSE 1 END,
            t.rating DESC NULLS LAST
          LIMIT ?
        ''',
          [
            '"$escaped"',
            if (mediaKind != null && mediaKind != 'automatic') mediaKind,
            if (year != null) '$year',
            normalized,
            limit,
          ],
        );
      } catch (_) {
        fuzzyRows = await db.rawQuery(
          '''
          SELECT * FROM tmdb_works
          WHERE (LOWER(title) LIKE ? OR LOWER(original_title) LIKE ?)
          ${mediaKind != null && mediaKind != 'automatic' ? "AND media_kind = ?" : ''}
          ${year != null ? "AND SUBSTR(release_date, 1, 4) = ?" : ''}
          ORDER BY
            CASE WHEN LOWER(title) = ? THEN 0 ELSE 1 END,
            rating DESC NULLS LAST
          LIMIT ?
        ''',
          [
            likePattern,
            likePattern,
            if (mediaKind != null && mediaKind != 'automatic') mediaKind,
            if (year != null) '$year',
            normalized,
            limit,
          ],
        );
      }
    } else {
      fuzzyRows = await db.rawQuery(
        '''
        SELECT * FROM tmdb_works
        WHERE (LOWER(title) LIKE ? OR LOWER(original_title) LIKE ?)
        ${mediaKind != null && mediaKind != 'automatic' ? "AND media_kind = ?" : ''}
        ${year != null ? "AND SUBSTR(release_date, 1, 4) = ?" : ''}
        ORDER BY
          CASE WHEN LOWER(title) = ? THEN 0 ELSE 1 END,
          rating DESC NULLS LAST
        LIMIT ?
      ''',
        [
          likePattern,
          likePattern,
          if (mediaKind != null && mediaKind != 'automatic') mediaKind,
          if (year != null) '$year',
          normalized,
          limit,
        ],
      );
    }
    final result = fuzzyRows.map((r) => TMDBWork.fromJson(r)).toList();
    _tmdbTitleSearchCache[cacheKey] = result;
    return result;
  }

  Future<TMDBWork?> tmdbWork(int tmdbID) async {
    final rows = await (await _db).query(
      'tmdb_works',
      where: 'tmdb_id = ?',
      whereArgs: [tmdbID],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return TMDBWork.fromJson(rows.first);
  }

  Future<void> upsertTMDBWork(TMDBWork work) async {
    final db = await _db;
    await db.rawInsert(
      '''
      INSERT OR REPLACE INTO tmdb_works
        (tmdb_id, title, original_title, media_kind, release_date,
         overview, poster_path, backdrop_path, rating, imdb_id,
         genres, origin_country, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
      [
        work.tmdbID,
        work.title,
        work.originalTitle,
        work.mediaKind.name,
        work.releaseDate,
        work.overview,
        work.posterPath,
        work.backdropPath,
        work.rating,
        work.imdbID,
        work.genres.join(','),
        work.originCountries.join(','),
        work.createdAt.millisecondsSinceEpoch / 1000.0,
      ],
    );
  }

  Future<List<TMDBWork>> allTMDBWorks() async {
    final rows = await (await _db).query('tmdb_works', orderBy: 'title');
    return rows.map((row) => TMDBWork.fromJson(row)).toList();
  }

  /// Batch variant of [upsertTMDBWork]. One transaction for the whole batch
  /// instead of one per work, which matters during a full-drive scrape.
  Future<void> upsertTMDBWorks(Iterable<TMDBWork> works) async {
    final list = works.toList(growable: false);
    if (list.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final work in list) {
        batch.rawInsert(
          '''
          INSERT OR REPLACE INTO tmdb_works
            (tmdb_id, title, original_title, media_kind, release_date,
             overview, poster_path, backdrop_path, rating, imdb_id,
             genres, origin_country, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
          [
            work.tmdbID,
            work.title,
            work.originalTitle,
            work.mediaKind.name,
            work.releaseDate,
            work.overview,
            work.posterPath,
            work.backdropPath,
            work.rating,
            work.imdbID,
            work.genres.join(','),
            work.originCountries.join(','),
            work.createdAt.millisecondsSinceEpoch / 1000.0,
          ],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Looks up many TMDB works at once, keyed by `tmdb_id`.
  Future<Map<int, TMDBWork>> tmdbWorksByIDs(Iterable<int> ids) async {
    final unique = ids.toSet().toList(growable: false);
    if (unique.isEmpty) return const {};
    final db = await _db;
    final result = <int, TMDBWork>{};
    for (final chunk in _chunked(unique, 500)) {
      final rows = await db.rawQuery(
        'SELECT * FROM tmdb_works WHERE tmdb_id IN '
        '(${chunk.map((_) => '?').join(',')})',
        chunk,
      );
      for (final row in rows) {
        final work = TMDBWork.fromJson(row);
        result[work.tmdbID] = work;
      }
    }
    return result;
  }

  // ── Douban Works ──

  Future<List<DoubanWork>> searchDoubanWorksByTitle(
    String title, {
    int? year,
    String? mediaKind,
    int limit = 10,
  }) async {
    final db = await _db;
    final normalized = title.trim().toLowerCase();
    if (normalized.isEmpty) return const [];

    final cacheKey = '$normalized|$year|$mediaKind|$limit';
    final cached = _doubanTitleSearchCache[cacheKey];
    if (cached != null) return cached;

    final exactRows = await db.rawQuery(
      '''
      SELECT * FROM douban_works
      WHERE (LOWER(title) = ? OR LOWER(original_title) = ?)
      ${mediaKind != null && mediaKind != 'automatic' ? "AND media_kind = ?" : ''}
      ${year != null ? "AND SUBSTR(release_date, 1, 4) = ?" : ''}
      ORDER BY rating DESC NULLS LAST
      LIMIT ?
    ''',
      [
        normalized,
        normalized,
        if (mediaKind != null && mediaKind != 'automatic') mediaKind,
        if (year != null) '$year',
        limit,
      ],
    );
    if (exactRows.isNotEmpty) {
      final result = exactRows.map((r) => DoubanWork.fromJson(r)).toList();
      _doubanTitleSearchCache[cacheKey] = result;
      return result;
    }

    // Phase 2: fuzzy match. Prefer FTS5 trigram substring search when the
    // query is long enough (≥3 chars); otherwise fall back to LIKE. FTS5
    // may be unavailable on older SQLite builds, so any failure degrades
    // gracefully to the LIKE scan.
    final likePattern = '%$normalized%';
    List<Map<String, Object?>> fuzzyRows;
    if (normalized.runes.length >= 3) {
      try {
        final escaped = normalized.replaceAll('"', '""');
        fuzzyRows = await db.rawQuery(
          '''
          SELECT t.* FROM douban_works t
          JOIN (
            SELECT rowid FROM douban_works_fts
            WHERE douban_works_fts MATCH ?
          ) f ON f.rowid = t.id
          ${mediaKind != null && mediaKind != 'automatic' ? "WHERE t.media_kind = ?" : ''}
          ${year != null ? "${mediaKind != null && mediaKind != 'automatic' ? 'AND' : 'WHERE'} SUBSTR(t.release_date, 1, 4) = ?" : ''}
          ORDER BY
            CASE WHEN LOWER(t.title) = ? THEN 0 ELSE 1 END,
            t.rating DESC NULLS LAST
          LIMIT ?
        ''',
          [
            '"$escaped"',
            if (mediaKind != null && mediaKind != 'automatic') mediaKind,
            if (year != null) '$year',
            normalized,
            limit,
          ],
        );
      } catch (_) {
        fuzzyRows = await db.rawQuery(
          '''
          SELECT * FROM douban_works
          WHERE (LOWER(title) LIKE ? OR LOWER(original_title) LIKE ?)
          ${mediaKind != null && mediaKind != 'automatic' ? "AND media_kind = ?" : ''}
          ${year != null ? "AND SUBSTR(release_date, 1, 4) = ?" : ''}
          ORDER BY
            CASE WHEN LOWER(title) = ? THEN 0 ELSE 1 END,
            rating DESC NULLS LAST
          LIMIT ?
        ''',
          [
            likePattern,
            likePattern,
            if (mediaKind != null && mediaKind != 'automatic') mediaKind,
            if (year != null) '$year',
            normalized,
            limit,
          ],
        );
      }
    } else {
      fuzzyRows = await db.rawQuery(
        '''
        SELECT * FROM douban_works
        WHERE (LOWER(title) LIKE ? OR LOWER(original_title) LIKE ?)
        ${mediaKind != null && mediaKind != 'automatic' ? "AND media_kind = ?" : ''}
        ${year != null ? "AND SUBSTR(release_date, 1, 4) = ?" : ''}
        ORDER BY
          CASE WHEN LOWER(title) = ? THEN 0 ELSE 1 END,
          rating DESC NULLS LAST
        LIMIT ?
      ''',
        [
          likePattern,
          likePattern,
          if (mediaKind != null && mediaKind != 'automatic') mediaKind,
          if (year != null) '$year',
          normalized,
          limit,
        ],
      );
    }
    final result = fuzzyRows.map((r) => DoubanWork.fromJson(r)).toList();
    _doubanTitleSearchCache[cacheKey] = result;
    return result;
  }

  Future<DoubanWork?> doubanWork(String doubanID) async {
    final rows = await (await _db).query(
      'douban_works',
      where: 'douban_id = ?',
      whereArgs: [doubanID],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DoubanWork.fromJson(rows.first);
  }

  Future<void> upsertDoubanWork(DoubanWork work) async {
    final db = await _db;
    await db.rawInsert(
      '''
      INSERT OR REPLACE INTO douban_works
        (douban_id, title, original_title, media_kind, release_date,
         overview, poster_path, rating, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
      [
        work.doubanID,
        work.title,
        work.originalTitle,
        work.mediaKind.name,
        work.releaseDate,
        work.overview,
        work.posterPath,
        work.rating,
        work.createdAt.millisecondsSinceEpoch / 1000.0,
      ],
    );
  }

  Future<List<DoubanWork>> allDoubanWorks() async {
    final rows = await (await _db).query('douban_works', orderBy: 'title');
    return rows.map((row) => DoubanWork.fromJson(row)).toList();
  }

  /// Batch variant of [upsertDoubanWork]; see [upsertTMDBWorks].
  Future<void> upsertDoubanWorks(Iterable<DoubanWork> works) async {
    final list = works.toList(growable: false);
    if (list.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final work in list) {
        batch.rawInsert(
          '''
          INSERT OR REPLACE INTO douban_works
            (douban_id, title, original_title, media_kind, release_date,
             overview, poster_path, rating, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
          [
            work.doubanID,
            work.title,
            work.originalTitle,
            work.mediaKind.name,
            work.releaseDate,
            work.overview,
            work.posterPath,
            work.rating,
            work.createdAt.millisecondsSinceEpoch / 1000.0,
          ],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Looks up many Douban works at once, keyed by `douban_id`.
  Future<Map<String, DoubanWork>> doubanWorksByIDs(Iterable<String> ids) async {
    final unique = ids
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (unique.isEmpty) return const {};
    final db = await _db;
    final result = <String, DoubanWork>{};
    for (final chunk in _chunked(unique, 500)) {
      final rows = await db.rawQuery(
        'SELECT * FROM douban_works WHERE douban_id IN '
        '(${chunk.map((_) => '?').join(',')})',
        chunk,
      );
      for (final row in rows) {
        final work = DoubanWork.fromJson(row);
        result[work.doubanID] = work;
      }
    }
    return result;
  }

  /// 导出全部 TMDB/豆瓣 works 为可移植 JSON 字符串。
  /// 格式：{version, exported_at, tmdb_works: [...], douban_works: [...]}，
  /// 每个 work 使用模型的 toJson() 全字段序列化，供 [importWorksJSON] 还原。
  Future<String> exportWorksJSON() async {
    final tmdbWorks = await allTMDBWorks();
    final doubanWorks = await allDoubanWorks();
    return jsonEncode({
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'tmdb_works': tmdbWorks.map((w) => w.toJson()).toList(),
      'douban_works': doubanWorks.map((w) => w.toJson()).toList(),
    });
  }

  /// 从 [exportWorksJSON] 生成的 JSON 字符串恢复 works 数据。
  /// 返回 (tmdb 数, douban 数)；同 tmdb_id/douban_id 以新数据覆盖（去重合并）。
  Future<({int tmdb, int douban})> importWorksJSON(String json) async {
    final data = jsonDecode(json);
    if (data is! Map) return (tmdb: 0, douban: 0);
    final tmdbList = <TMDBWork>[];
    for (final value in (data['tmdb_works'] as List? ?? const [])) {
      if (value is Map) {
        try {
          tmdbList.add(TMDBWork.fromJson(Map<String, dynamic>.from(value)));
        } catch (_) {}
      }
    }
    final doubanList = <DoubanWork>[];
    for (final value in (data['douban_works'] as List? ?? const [])) {
      if (value is Map) {
        try {
          doubanList.add(DoubanWork.fromJson(Map<String, dynamic>.from(value)));
        } catch (_) {}
      }
    }
    await upsertTMDBWorks(tmdbList);
    await upsertDoubanWorks(doubanList);
    clearWorksSearchCache();
    return (tmdb: tmdbList.length, douban: doubanList.length);
  }

  /// 清空本地 works 标题查询缓存（导入/写入 works 后调用，避免命中旧数据）。
  void clearWorksSearchCache() {
    _tmdbTitleSearchCache.clear();
    _doubanTitleSearchCache.clear();
  }

  /// 从 TMDB/豆瓣独立表加载详情，附加到 media items 上
  Future<List<MediaLibraryItem>> enrichItemsWithWorkDetails(
    List<MediaLibraryItem> items,
  ) async {
    if (items.isEmpty) return items;
    final tmdbIds = <int>{};
    final doubanIds = <String>{};
    for (final item in items) {
      if (item.tmdbID != null) tmdbIds.add(item.tmdbID!);
      if (item.doubanID != null && item.doubanID!.isNotEmpty) {
        doubanIds.add(item.doubanID!);
      }
    }
    if (tmdbIds.isEmpty && doubanIds.isEmpty) return items;

    final db = await _db;
    final tmdbMap = <int, TMDBWork>{};
    for (final chunk in _chunked(tmdbIds.toList(), 500)) {
      final rows = await db.rawQuery(
        'SELECT * FROM tmdb_works WHERE tmdb_id IN '
        '(${chunk.map((_) => '?').join(',')})',
        chunk,
      );
      for (final row in rows) {
        final work = TMDBWork.fromJson(row);
        tmdbMap[work.tmdbID] = work;
      }
    }
    final doubanMap = <String, DoubanWork>{};
    for (final chunk in _chunked(doubanIds.toList(), 500)) {
      final rows = await db.rawQuery(
        'SELECT * FROM douban_works WHERE douban_id IN '
        '(${chunk.map((_) => '?').join(',')})',
        chunk,
      );
      for (final row in rows) {
        final work = DoubanWork.fromJson(row);
        doubanMap[work.doubanID] = work;
      }
    }

    return items.map((item) {
      final tmdbWork = item.tmdbID != null ? tmdbMap[item.tmdbID] : null;
      final doubanWork = item.doubanID != null
          ? doubanMap[item.doubanID!]
          : null;
      if (tmdbWork == null && doubanWork == null) return item;
      // Priority: TMDB first, then Douban (only when a douban id exists),
      // finally the item's own value. Empty strings are treated as absent so a
      // partially-filled TMDB row still falls back to Douban field-by-field.
      String pickText(String? tmdb, String? douban, String fallback) {
        if (tmdb != null && tmdb.trim().isNotEmpty) return tmdb;
        if (douban != null && douban.trim().isNotEmpty) return douban;
        return fallback;
      }

      String? pickNullableText(String? tmdb, String? douban, String? fallback) {
        if (tmdb != null && tmdb.trim().isNotEmpty) return tmdb;
        if (douban != null && douban.trim().isNotEmpty) return douban;
        return fallback;
      }

      return item.copyWith(
        title: pickText(tmdbWork?.title, doubanWork?.title, item.title),
        originalTitle: pickText(
          tmdbWork?.originalTitle,
          doubanWork?.originalTitle,
          item.originalTitle,
        ),
        mediaKind:
            tmdbWork?.mediaKind ?? doubanWork?.mediaKind ?? item.mediaKind,
        releaseDate: pickText(
          tmdbWork?.releaseDate,
          doubanWork?.releaseDate,
          item.releaseDate,
        ),
        overview: pickText(
          tmdbWork?.overview,
          doubanWork?.overview,
          item.overview,
        ),
        posterPath: pickNullableText(
          tmdbWork?.posterPath,
          doubanWork?.posterPath,
          item.posterPath,
        ),
        backdropPath: pickNullableText(
          tmdbWork?.backdropPath,
          null,
          item.backdropPath,
        ),
        tmdbRating: tmdbWork?.rating ?? item.tmdbRating,
        doubanRating: doubanWork?.rating ?? item.doubanRating,
        imdbID: pickNullableText(tmdbWork?.imdbID, null, item.imdbID),
      );
    }).toList();
  }

  // ── Migration: 将 media_items 中的 TMDB/豆瓣数据迁移到独立表 ──

  Future<int> migrateTMDBDoubanData() async {
    final db = await _db;
    var migrated = 0;

    // 迁移 TMDB 数据
    final tmdbRows = await db.rawQuery('''
      SELECT DISTINCT tmdb_id, title, original_title, media_kind,
             release_date, overview, poster_path, backdrop_path,
             tmdb_rating, imdb_id
      FROM media_items
      WHERE tmdb_id IS NOT NULL AND tmdb_id != 0
    ''');
    for (final row in tmdbRows) {
      final tmdbID = row['tmdb_id'] as int? ?? 0;
      if (tmdbID == 0) continue;
      final existing = await tmdbWork(tmdbID);
      if (existing != null) continue;
      await upsertTMDBWork(
        TMDBWork(
          id: 0,
          tmdbID: tmdbID,
          title: row['title']?.toString() ?? '',
          originalTitle: row['original_title']?.toString() ?? '',
          mediaKind: _parseMediaKindStr(row['media_kind']?.toString()),
          releaseDate: row['release_date']?.toString() ?? '',
          overview: row['overview']?.toString() ?? '',
          posterPath: row['poster_path']?.toString(),
          backdropPath: row['backdrop_path']?.toString(),
          rating: row['tmdb_rating'] as double?,
          imdbID: row['imdb_id']?.toString(),
          createdAt: DateTime.now(),
        ),
      );
      migrated += 1;
    }

    // 迁移豆瓣数据
    final doubanRows = await db.rawQuery('''
      SELECT DISTINCT douban_id, title, original_title, media_kind,
             release_date, overview, poster_path, douban_rating
      FROM media_items
      WHERE douban_id IS NOT NULL AND douban_id != ''
    ''');
    for (final row in doubanRows) {
      final doubanID = row['douban_id']?.toString() ?? '';
      if (doubanID.isEmpty) continue;
      final existing = await doubanWork(doubanID);
      if (existing != null) continue;
      await upsertDoubanWork(
        DoubanWork(
          id: 0,
          doubanID: doubanID,
          title: row['title']?.toString() ?? '',
          originalTitle: row['original_title']?.toString() ?? '',
          mediaKind: _parseMediaKindStr(row['media_kind']?.toString()),
          releaseDate: row['release_date']?.toString() ?? '',
          overview: row['overview']?.toString() ?? '',
          posterPath: row['poster_path']?.toString(),
          rating: row['douban_rating'] as double?,
          createdAt: DateTime.now(),
        ),
      );
      migrated += 1;
    }

    return migrated;
  }

  TMDBMediaKind _parseMediaKindStr(String? value) {
    return TMDBMediaKind.values.firstWhere(
      (e) => e.name == value,
      orElse: () => TMDBMediaKind.automatic,
    );
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

  /// 旧库迁移用：判断 [table] 是否还有 [column] 列，避免已迁移状态报
  /// "no such column" 噪音日志。
  Future<bool> _hasColumn(
    DatabaseExecutor db,
    String table,
    String column,
  ) async {
    final columns = await _tableColumns(db, 'main', table);
    return columns.contains(column);
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
