import 'dart:async';

import 'package:flutter_riverpod/legacy.dart';

import '../api/guangya_api.dart';
import '../core/logging/app_logger.dart';
import '../core/storage/file_metadata_cache.dart';
import '../models/cloud_file.dart';
import '../models/organize_action.dart';

enum OrganizePhase { idle, scanning, preview, executing, done }

class OrganizeState {
  final OrganizePhase phase;
  final List<OrganizeAction> actions;
  final List<String> logs;
  final String progressMessage;

  const OrganizeState({
    this.phase = OrganizePhase.idle,
    this.actions = const [],
    this.logs = const [],
    this.progressMessage = '',
  });

  int get moveCount =>
      actions.where((a) => a.type == OrganizeActionType.moveToBase).length;
  int get deleteCount =>
      actions.where((a) => a.type == OrganizeActionType.deleteDuplicate).length;
  int get renameCount => actions
      .where((a) =>
  a.type == OrganizeActionType.renameConflict ||
      a.type == OrganizeActionType.renameBase)
      .length;
  int get cleanCount =>
      actions.where((a) => a.type == OrganizeActionType.cleanDir).length;
  int get totalAffected => moveCount + deleteCount + renameCount;

  OrganizeState copyWith({
    OrganizePhase? phase,
    List<OrganizeAction>? actions,
    List<String>? logs,
    String? progressMessage,
    bool clearProgress = false,
  }) {
    return OrganizeState(
      phase: phase ?? this.phase,
      actions: actions ?? this.actions,
      logs: logs ?? this.logs,
      progressMessage:
      clearProgress ? '' : (progressMessage ?? this.progressMessage),
    );
  }
}

final _dupPattern = RegExp(r'^(.*?)\s*[\(（](\d+)[\)）]\s*$');

class OrganizeNotifier extends StateNotifier<OrganizeState> {
  GuangyaAPI? _api;
  bool _cancelled = false;
  final Map<String, String> _gcidByFileId = {};
  final Map<String, CloudFile> _fileById = {};
  Set<String>? _scopedFolderKeys;

  OrganizeNotifier() : super(const OrganizeState());

  set api(GuangyaAPI value) => _api = value;

  // ═══════════════════════════════════════════════════
  //  公开接口
  // ═══════════════════════════════════════════════════

  Future<void> scan(String rootId, {String rootPath = ''}) async {
    if (_api == null) return;
    _cancelled = false;
    _gcidByFileId.clear();
    _fileById.clear();
    _scopedFolderKeys = null;
    state = OrganizeState(phase: OrganizePhase.scanning);
    _log('正在从缓存加载目录数据...');

    try {
      // ── 1. 加载所有目录快照 ──
      final snapshots = await FileMetadataCache.allFolderChildrenSnapshots();
      var totalChildren = 0;
      for (final c in snapshots.values) {
        totalChildren += c.length;
      }
      _log('已加载 ${snapshots.length} 个目录，共 $totalChildren 项');

      if (snapshots.isEmpty) {
        _log('缓存为空，请先浏览云盘以建立缓存');
        state = state.copyWith(phase: OrganizePhase.idle);
        return;
      }

      // ── 2. 构建路径映射 (BFS，仅用于日志显示) ──
      final effectiveRoot = rootPath.isEmpty ? '根目录' : rootPath;
      final pathMap = _buildPathMap(snapshots, rootId, effectiveRoot);
      _scopedFolderKeys = rootId.isEmpty ? null : pathMap.keys.map(_folderKey).toSet();
      _log('已构建 ${pathMap.length} 条路径');

      // ── 3. 扫描所有目录，识别重复组 ──
      _log('正在分析重复文件名...');

      // folderId → { baseName → [dup_files] }  (文件)
      // folderId → { baseName → [dup_dirs] }   (文件夹)
      final fileDupGroups = <String, Map<String, List<CloudFile>>>{};
      final dirDupGroups = <String, Map<String, List<CloudFile>>>{};

      var matchCount = 0;

      for (final entry in snapshots.entries) {
        if (_cancelled) return;
        if (!_folderInScope(entry.key)) continue;
        final folderId = _folderKey(entry.key);
        final children = entry.value;

        for (final child in children) {
          _fileById[child.id] = child;
          final dup = _parseDup(child.name, child.isDirectory);
          if (dup == null) continue;
          matchCount++;

          final fullBaseName = '${dup.baseName}${dup.extension}';

          if (child.isDirectory) {
            dirDupGroups
                .putIfAbsent(folderId, () => {})
                .putIfAbsent(dup.baseName, () => [])
                .add(child);
          } else {
            fileDupGroups
                .putIfAbsent(folderId, () => {})
                .putIfAbsent(fullBaseName, () => [])
                .add(child);
          }
        }
      }

      _log('匹配到 $matchCount 个 name(N) 模式的项目');

      if (matchCount == 0) {
        _log('没有找到任何 name(N) 模式的文件或文件夹');
        state = state.copyWith(phase: OrganizePhase.idle);
        return;
      }

      // ── 4. 筛选有效的重复组，收集需要 GCID 的文件 ID ──
      final dupFileIds = <String>{};
      var validGroups = 0;

      // 文件组
      for (final folderEntry in fileDupGroups.entries) {
        final folderId = folderEntry.key;
        final children = snapshots[_unfolderKey(folderId)] ?? [];
        final childNameSet = children.map((c) => c.name).toSet();

        for (final groupEntry in folderEntry.value.entries) {
          final baseName = groupEntry.key; // "report.pdf"
          final dups = groupEntry.value;
          final hasBase = childNameSet.contains(baseName);

          // 单个 dup 且没有原始文件 → 也标记为需要处理
          if (dups.length > 1 || (dups.isNotEmpty && hasBase)) {
            validGroups++;
            for (final d in dups) {
              dupFileIds.add(d.id);
            }
            if (hasBase) {
              try {
                final base =
                children.firstWhere((c) => c.name == baseName && !c.isDirectory);
                dupFileIds.add(base.id);
              } catch (_) {}
            }
          }
        }
      }

      // 文件夹组
      for (final folderEntry in dirDupGroups.entries) {
        final folderId = folderEntry.key;
        final children = snapshots[_unfolderKey(folderId)] ?? [];
        final childNameSet = children.map((c) => c.name).toSet();

        for (final groupEntry in folderEntry.value.entries) {
          final baseName = groupEntry.key; // "Photos"
          final dups = groupEntry.value;
          final hasBase = childNameSet.contains(baseName) &&
              children.any((c) => c.name == baseName && c.isDirectory);

          if (dups.length > 1 || (dups.isNotEmpty && hasBase)) {
            validGroups++;
            if (hasBase) {
              CloudFile? base;
              for (final child in children) {
                if (child.name == baseName && child.isDirectory) {
                  base = child;
                  break;
                }
              }
              if (base != null) _collectDirectoryFileIDs(snapshots, base.id, dupFileIds);
            }
            for (final dup in dups) {
              _collectDirectoryFileIDs(snapshots, dup.id, dupFileIds);
            }
          }
        }
      }

      _log('有效重复组: $validGroups 个，需查询 GCID: ${dupFileIds.length} 个');

      if (validGroups == 0) {
        _log('所有 name(N) 项目都是单个副本且无原始文件，无需处理');
        state = state.copyWith(phase: OrganizePhase.idle);
        return;
      }

      // ── 5. 批量获取 GCID ──
      _log('正在查询 GCID...');
      final gcidMap = await FileMetadataCache.gcidsByFileIDs(dupFileIds);
      _gcidByFileId.addAll(gcidMap);
      _log('已解析 ${gcidMap.length} 个文件的 GCID');

      // ── 6. 生成合并动作 ──
      _log('正在生成合并计划...');

      // 文件动作
      for (final folderEntry in fileDupGroups.entries) {
        if (_cancelled) return;
        final folderId = _unfolderKey(folderEntry.key);
        final children = snapshots[folderId] ?? [];
        final currentPath = _displayPath(folderId, pathMap);

        for (final groupEntry in folderEntry.value.entries) {
          if (_cancelled) return;
          _processFileGroup(
            groupEntry.key,
            groupEntry.value,
            children,
            folderId ?? '',
            currentPath,
          );
        }
      }

      // 文件夹动作
      for (final folderEntry in dirDupGroups.entries) {
        if (_cancelled) return;
        final folderId = _unfolderKey(folderEntry.key);
        final children = snapshots[folderId] ?? [];
        final currentPath = _displayPath(folderId, pathMap);

        for (final groupEntry in folderEntry.value.entries) {
          if (_cancelled) return;
          _processDirGroup(
            groupEntry.key,
            groupEntry.value,
            children,
            folderId ?? '',
            currentPath,
            snapshots,
            pathMap,
          );
        }
      }

      _log('扫描完成: ${state.actions.length} 项操作');
      state = state.copyWith(
        phase:
        state.actions.isEmpty ? OrganizePhase.idle : OrganizePhase.preview,
      );
    } catch (e, st) {
      _log('扫描出错: $e');
      AppLogger.error('Organize', '扫描失败', error: e, stackTrace: st);
      state = state.copyWith(phase: OrganizePhase.idle);
    }
  }

  Future<void> execute() async {
    if (_api == null || state.actions.isEmpty) return;
    _cancelled = false;
    state = state.copyWith(phase: OrganizePhase.executing);

    _log('开始执行...');
    final actions = List<OrganizeAction>.from(state.actions);
    final total = actions.length;

    const concurrency = 6;
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (_cancelled) return;
        final index = nextIndex++;
        if (index >= total) return;
        final action = actions[index];
        state = state.copyWith(
          progressMessage: '[${index + 1}/$total] ${action.sourceName}',
        );
        try {
          await _executeAction(action);
          action.executed = true;
        } catch (e) {
          action.failed = true;
          action.errorMessage = e.toString();
          _log('  失败: ${action.sourceName} — $e');
        }
        state = state.copyWith(actions: List.from(actions));
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));

    final ok = actions.where((a) => a.executed && !a.failed).length;
    _log('执行完成: $ok/$total 成功');
    state = state.copyWith(phase: OrganizePhase.done, clearProgress: true);
  }

  void cancel() => _cancelled = true;

  void reset() {
    _cancelled = true;
    _gcidByFileId.clear();
    _fileById.clear();
    _scopedFolderKeys = null;
    state = const OrganizeState();
  }

  // ═══════════════════════════════════════════════════
  //  路径映射 (仅用于日志显示)
  // ═══════════════════════════════════════════════════

  Map<String, String> _buildPathMap(
      Map<String?, List<CloudFile>> snapshots,
      String rootId,
      String rootPath,
      ) {
    final pathMap = <String, String>{};
    final queue = <(String?, String)>[];
    final visited = <String?>{};

    if (rootId.isEmpty) {
      queue.add((null, rootPath));
    } else {
      pathMap[rootId] = rootPath;
      queue.add((rootId, rootPath));
    }

    while (queue.isNotEmpty) {
      final (folderId, path) = queue.removeAt(0);
      if (!visited.add(folderId)) continue;

      final children = snapshots[folderId];
      if (children == null) continue;

      for (final child in children) {
        if (child.isDirectory && !pathMap.containsKey(child.id)) {
          final childPath = '$path/${child.name}';
          pathMap[child.id] = childPath;
          queue.add((child.id, childPath));
        }
      }
    }

    return pathMap;
  }

  String _displayPath(String? folderId, Map<String, String> pathMap) {
    if (folderId == null || folderId.isEmpty) return '根目录';
    return pathMap[folderId] ?? folderId;
  }

  String _joinPath(String parent, String name) {
    final normalizedParent = parent.trim().replaceAll(RegExp(r'/+$'), '');
    if (normalizedParent.isEmpty) return name;
    return '$normalizedParent/$name';
  }

  // ═══════════════════════════════════════════════════
  //  文件组处理
  // ═══════════════════════════════════════════════════

  void _processFileGroup(
      String baseName, // "report.pdf"
      List<CloudFile> dups,
      List<CloudFile> allChildren,
      String parentId,
      String currentPath,
      ) {
    // 过滤掉不属于当前扫描范围的
    if (!_inScope(parentId)) return;

    dups.sort((a, b) =>
        _parseDup(a.name, false)!.number.compareTo(
            _parseDup(b.name, false)!.number));

    CloudFile? baseFile;
    try {
      baseFile = allChildren.firstWhere(
            (f) => f.name == baseName && !f.isDirectory,
      );
    } catch (_) {}

    List<CloudFile> remaining;

    if (baseFile == null) {
      if (dups.length < 2) return; // 只有一个 dup 且无原始 → 跳过
      // 没有原始文件，第一个 dup 当基准
      final first = dups.first;
      _addAction(OrganizeAction(
        type: OrganizeActionType.renameBase,
        sourceId: first.id,
        sourceName: first.name,
        sourceIsDir: false,
        sourceParentId: parentId,
        sourcePath: _joinPath(currentPath, first.name),
        newFileName: baseName,
        targetPath: _joinPath(currentPath, baseName),
        reason: '$currentPath/${first.name} → $baseName（原始文件不存在）',
      ));
      baseFile = first;
      remaining = dups.sublist(1);
    } else {
      remaining = dups;
    }

    final usedNames = allChildren.map((f) => f.name).toSet();
    final base = baseFile;

    for (final dup in remaining) {
      final gcidA = _gcidByFileId[base.id];
      final gcidB = _gcidByFileId[dup.id];

      if (gcidA != null && gcidB != null && gcidA == gcidB) {
        _addAction(OrganizeAction(
          type: OrganizeActionType.deleteDuplicate,
          sourceId: dup.id,
          sourceName: dup.name,
          sourceIsDir: false,
          sourceParentId: parentId,
          sourcePath: _joinPath(currentPath, dup.name),
          targetPath: '回收站',
          reason: '$currentPath/${dup.name} — GCID 相同，移入回收站',
        ));
      } else {
        final ext = _ext(dup.name);
        final base = _base(dup.name);
        final dupNum = _dupNumber(dup.name);
        final baseNum = _dupNumber(baseFile.name);
        final sameNumber = dupNum != null && baseNum != null && dupNum == baseNum;
        if (sameNumber) {
          final newName = _uniqueName(base, ext, usedNames);
          usedNames.add(newName);
          final note = (gcidA == null || gcidB == null) ? 'GCID 缺失' : 'GCID 不同';
          _addAction(OrganizeAction(
            type: OrganizeActionType.renameConflict,
            sourceId: dup.id,
            sourceName: dup.name,
            sourceIsDir: false,
            sourceParentId: parentId,
            sourcePath: _joinPath(currentPath, dup.name),
            newFileName: newName,
            targetPath: _joinPath(currentPath, newName),
            reason: '$currentPath/${dup.name} — $note，重命名为 $newName',
          ));
        } else {
          _addAction(OrganizeAction(
            type: OrganizeActionType.moveToBase,
            sourceId: dup.id,
            sourceName: dup.name,
            sourceIsDir: false,
            sourceParentId: parentId,
            sourcePath: _joinPath(currentPath, dup.name),
            targetParentId: parentId,
            targetPath: _joinPath(currentPath, dup.name),
            reason: '$currentPath/${dup.name} — 编号不同或缺失，仅移动不重命名',
          ));
        }
      }
    }
  }

  // ═══════════════════════════════════════════════════
  //  文件夹组处理
  // ═══════════════════════════════════════════════════

  void _processDirGroup(
      String baseName,
      List<CloudFile> dups,
      List<CloudFile> allChildren,
      String parentId,
      String currentPath,
      Map<String?, List<CloudFile>> snapshots,
      Map<String, String> pathMap,
      ) {
    if (!_inScope(parentId)) return;

    dups.sort((a, b) =>
        _parseDup(a.name, true)!.number.compareTo(
            _parseDup(b.name, true)!.number));

    CloudFile? baseDir;
    try {
      baseDir = allChildren.firstWhere(
            (f) => f.name == baseName && f.isDirectory,
      );
    } catch (_) {}

    List<CloudFile> remaining;

    if (baseDir == null) {
      if (dups.length < 2) return;
      final first = dups.first;
      _addAction(OrganizeAction(
        type: OrganizeActionType.renameBase,
        sourceId: first.id,
        sourceName: first.name,
        sourceIsDir: true,
        sourceParentId: parentId,
        sourcePath: _joinPath(currentPath, first.name),
        newFileName: baseName,
        targetPath: _joinPath(currentPath, baseName),
        reason: '$currentPath/${first.name} → $baseName（原始目录不存在）',
      ));
      baseDir = first;
      remaining = dups.sublist(1);
    } else {
      remaining = dups;
    }

    final base = baseDir;
    for (final dup in remaining) {
      if (_cancelled) return;
      _mergeDirRecursive(
        base,
        dup,
        snapshots,
        pathMap,
        '$currentPath/${base.name}',
      );
    }
  }

  void _mergeDirRecursive(
      CloudFile baseDir,
      CloudFile dupDir,
      Map<String?, List<CloudFile>> snapshots,
      Map<String, String> pathMap,
      String basePath,
      ) {
    final dupPath = _displayPath(dupDir.id, pathMap);

    final baseChildren = snapshots[baseDir.id] ?? [];
    final dupChildren = snapshots[dupDir.id] ?? [];

    if (dupChildren.isEmpty) {
      _addAction(OrganizeAction(
        type: OrganizeActionType.cleanDir,
        sourceId: dupDir.id,
        sourceName: dupDir.name,
        sourceIsDir: true,
        sourceParentId: dupDir.parentID ?? '',
        sourcePath: dupPath,
        targetPath: '清理空目录',
        reason: '$dupPath/ 为空，直接清理',
      ));
      return;
    }

    final baseByName = <String, CloudFile>{
      for (final c in baseChildren) c.name: c,
    };
    final usedNames = baseChildren.map((f) => f.name).toSet();

    for (final dupChild in dupChildren) {
      if (_cancelled) return;
      final existing = baseByName[dupChild.name];

      if (existing == null) {
        _addAction(OrganizeAction(
          type: OrganizeActionType.moveToBase,
          sourceId: dupChild.id,
          sourceName: dupChild.name,
          sourceIsDir: dupChild.isDirectory,
          sourceParentId: dupDir.id,
          sourcePath: _joinPath(dupPath, dupChild.name),
          targetParentId: baseDir.id,
          targetParentName: basePath,
          targetPath: _joinPath(basePath, dupChild.name),
          reason: '$dupPath/${dupChild.name} → $basePath/',
        ));
      } else if (dupChild.isDirectory && existing.isDirectory) {
        _mergeDirRecursive(
          existing,
          dupChild,
          snapshots,
          pathMap,
          '$basePath/${existing.name}',
        );
      } else if (!dupChild.isDirectory && !existing.isDirectory) {
        final gcidA = _gcidByFileId[existing.id];
        final gcidB = _gcidByFileId[dupChild.id];

        if (gcidA != null && gcidB != null && gcidA == gcidB) {
          _addAction(OrganizeAction(
            type: OrganizeActionType.deleteDuplicate,
            sourceId: dupChild.id,
            sourceName: dupChild.name,
            sourceIsDir: false,
            sourceParentId: dupDir.id,
            sourcePath: _joinPath(dupPath, dupChild.name),
            targetPath: '回收站',
            reason: '$dupPath/${dupChild.name} — 与 $basePath/${dupChild.name} GCID 相同',
          ));
        } else {
          final ext = _ext(dupChild.name);
          final nameBase = _base(dupChild.name);
          final dupNum = _dupNumber(dupChild.name);
          final baseNum = _dupNumber(existing.name);
          final sameNumber = dupNum != null && baseNum != null && dupNum == baseNum;
          if (sameNumber) {
            final newName = _uniqueName(nameBase, ext, usedNames);
            usedNames.add(newName);
            final note = (gcidA == null || gcidB == null) ? 'GCID 缺失' : 'GCID 不同';
            _addAction(OrganizeAction(
              type: OrganizeActionType.renameConflict,
              sourceId: dupChild.id,
              sourceName: dupChild.name,
              sourceIsDir: false,
              sourceParentId: dupDir.id,
              sourcePath: _joinPath(dupPath, dupChild.name),
              targetParentId: baseDir.id,
              targetParentName: basePath,
              newFileName: newName,
              targetPath: _joinPath(basePath, newName),
              reason: '$dupPath/${dupChild.name} — $note，重命名为 $newName 后移入 $basePath/',
            ));
          } else {
            _addAction(OrganizeAction(
              type: OrganizeActionType.moveToBase,
              sourceId: dupChild.id,
              sourceName: dupChild.name,
              sourceIsDir: false,
              sourceParentId: dupDir.id,
              sourcePath: _joinPath(dupPath, dupChild.name),
              targetParentId: baseDir.id,
              targetParentName: basePath,
              targetPath: _joinPath(basePath, dupChild.name),
              reason: '$dupPath/${dupChild.name} — 编号不同或缺失，仅移动不重命名',
            ));
          }
        }
      } else {
        final ext = dupChild.isDirectory ? '' : _ext(dupChild.name);
        final nameBase =
        dupChild.isDirectory ? dupChild.name : _base(dupChild.name);
        final suffix = dupChild.isDirectory ? '__dup_dir' : '__dup_file';
        final newName = '$nameBase$suffix$ext';
        _addAction(OrganizeAction(
          type: OrganizeActionType.renameConflict,
          sourceId: dupChild.id,
          sourceName: dupChild.name,
          sourceIsDir: dupChild.isDirectory,
          sourceParentId: dupDir.id,
          sourcePath: _joinPath(dupPath, dupChild.name),
          targetParentId: baseDir.id,
          targetParentName: basePath,
          newFileName: newName,
          targetPath: _joinPath(basePath, newName),
          reason: '$dupPath/${dupChild.name} — 类型冲突，重命名为 $newName',
        ));
      }
    }

    _addAction(OrganizeAction(
      type: OrganizeActionType.cleanDir,
      sourceId: dupDir.id,
      sourceName: dupDir.name,
      sourceIsDir: true,
      sourceParentId: dupDir.parentID ?? '',
      sourcePath: dupPath,
      targetPath: '清理空目录',
      reason: '$dupPath/ 合并完成，清理空目录',
    ));
  }

  void _collectDirectoryFileIDs(
    Map<String?, List<CloudFile>> snapshots,
    String folderID,
    Set<String> out,
  ) {
    final queue = <String>[folderID];
    final visited = <String>{};
    for (var index = 0; index < queue.length; index++) {
      final id = queue[index];
      if (!visited.add(id)) continue;
      for (final child in snapshots[id] ?? const <CloudFile>[]) {
        if (child.isDirectory) {
          queue.add(child.id);
        } else {
          out.add(child.id);
        }
      }
    }
  }

  // ═══════════════════════════════════════════════════
  //  范围过滤
  // ═══════════════════════════════════════════════════

  bool _inScope(String parentId) {
    return _folderInScope(_cacheParentID(parentId));
  }

  bool _folderInScope(String? folderID) {
    final scoped = _scopedFolderKeys;
    return scoped == null || scoped.contains(_folderKey(folderID));
  }

  // ═══════════════════════════════════════════════════
  //  执行
  // ═══════════════════════════════════════════════════

  Future<void> _executeAction(OrganizeAction action) async {
    switch (action.type) {
      case OrganizeActionType.moveToBase:
        _log('  移动: ${action.sourceName} → ${action.targetParentName ?? ""}/');
        await _api!.fsMove([action.sourceId], parentID: action.targetParentId);
        await _syncMoveCache(action);
        break;

      case OrganizeActionType.renameBase:
        _log('  重命名: ${action.sourceName} → ${action.newFileName}');
        await _api!.fsRename(action.sourceId, action.newFileName!);
        await _syncRenameCache(action);
        break;

      case OrganizeActionType.renameConflict:
        _log('  重命名: ${action.sourceName} → ${action.newFileName}');
        await _api!.fsRename(action.sourceId, action.newFileName!);
        await _syncRenameCache(action);
        if (action.targetParentId != null) {
          _log('  移入: ${action.newFileName} → ${action.targetParentName ?? ""}/');
          await _api!.fsMove([action.sourceId], parentID: action.targetParentId);
          await _syncMoveCache(action);
        }
        break;

      case OrganizeActionType.deleteDuplicate:
        _log('  回收: ${action.sourceName}（GCID 相同）');
        await _api!.fsRecycle([action.sourceId]);
        await _syncDeleteCache(action);
        break;

      case OrganizeActionType.cleanDir:
        _log('  清理: ${action.sourceName}/');
        await _api!.fsDelete([action.sourceId]);
        await _syncDeleteCache(action);
        await FileMetadataCache.removeFolderChildrenSubtrees([action.sourceId]);
        break;
    }
  }

  Future<void> _syncRenameCache(OrganizeAction action) async {
    final file = _fileById[action.sourceId];
    final sourceParentID = _cacheParentID(action.sourceParentId);
    if (file == null || action.newFileName == null) {
      await FileMetadataCache.updateFolderChildren(sourceParentID, invalidate: true);
      return;
    }
    final renamed = file.copyWith(name: action.newFileName);
    _fileById[action.sourceId] = renamed;
    await FileMetadataCache.updateFolderChildren(sourceParentID, addOrReplace: [renamed]);
    await FileMetadataCache.cacheFiles([renamed]);
  }

  Future<void> _syncMoveCache(OrganizeAction action) async {
    final file = _fileById[action.sourceId];
    final sourceParentID = _cacheParentID(action.sourceParentId);
    final targetParentID = _cacheParentID(action.targetParentId);
    if (file == null || action.targetParentId == null) {
      await FileMetadataCache.updateFolderChildren(sourceParentID, invalidate: true);
      if (targetParentID != null) {
        await FileMetadataCache.updateFolderChildren(targetParentID, invalidate: true);
      }
      return;
    }
    final moved = file.copyWith(parentID: targetParentID);
    _fileById[action.sourceId] = moved;
    await FileMetadataCache.updateFolderChildren(sourceParentID, removeIDs: [action.sourceId]);
    await FileMetadataCache.updateFolderChildren(targetParentID, addOrReplace: [moved]);
  }

  Future<void> _syncDeleteCache(OrganizeAction action) async {
    final sourceParentID = _cacheParentID(action.sourceParentId);
    _fileById.remove(action.sourceId);
    await FileMetadataCache.removeFilesFromAllFolders([action.sourceId]);
    await FileMetadataCache.removeLiveFileIDs([action.sourceId]);
    await FileMetadataCache.updateFolderChildren(sourceParentID, removeIDs: [action.sourceId]);
  }

  String? _cacheParentID(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  // ═══════════════════════════════════════════════════
  //  工具
  // ═══════════════════════════════════════════════════

  String _folderKey(String? id) => id ?? '__root__';
  String? _unfolderKey(String key) => key == '__root__' ? null : key;

  void _addAction(OrganizeAction action) {
    state = state.copyWith(actions: [...state.actions, action]);
  }

  void _log(String msg) {
    state = state.copyWith(logs: [...state.logs, msg]);
    AppLogger.debug('Organize', msg);
  }

  ({String baseName, int number, String extension})? _parseDup(
      String name,
      bool isDirectory,
      ) {
    String namePart;
    String extPart;

    if (isDirectory) {
      namePart = name.trim();
      extPart = '';
    } else {
      final dot = name.lastIndexOf('.');
      if (dot <= 0) {
        namePart = name.trim();
        extPart = '';
      } else {
        namePart = name.substring(0, dot).trim();
        extPart = name.substring(dot);
      }
    }

    final m = _dupPattern.firstMatch(namePart);
    if (m == null) return null;
    final baseName = m.group(1)!.trimRight();
    if (baseName.isEmpty) return null;
    final number = int.parse(m.group(2)!);
    if (number < 1 || number > 999) return null;
    return (
      baseName: baseName,
      number: number,
      extension: extPart,
    );
  }

  String _ext(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot) : '';
  }

  String _base(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 从文件名中提取 (N) 编号，没有则返回 null
  int? _dupNumber(String name) {
    final parsed = _parseDup(name, false);
    return parsed?.number;
  }

  String _uniqueName(String base, String ext, Set<String> existing) {
    var n = 1;
    String candidate;
    do {
      candidate = '${base}__dup$n$ext';
      n++;
    } while (existing.contains(candidate));
    return candidate;
  }
}

final organizeProvider =
StateNotifierProvider<OrganizeNotifier, OrganizeState>(
      (ref) => OrganizeNotifier(),
);
