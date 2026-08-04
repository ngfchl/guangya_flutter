import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:easy_refresh/easy_refresh.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;
import 'package:url_launcher/url_launcher.dart';

import '../core/utils/format_bytes.dart';
import '../core/storage/storage_manager.dart';
import '../models/cloud_file.dart';
import '../models/media_library.dart';
import '../models/media_navigation.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../providers/watch_history_provider.dart';
import '../models/watch_history.dart';
import '../utils/media_artwork.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_loading_indicator.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/media_player_dialog.dart';
import '../core/logging/app_logger.dart';

export '../models/media_navigation.dart' show MediaLibraryBrowseFilter, MediaNavigationState, MediaWorkspaceView;
part 'media_library/media_library_detail.dart';
part 'media_library/media_library_backup.dart';
part 'media_library/media_library_shared.dart';
part 'media_library/media_library_filter.dart';


String _tmdbImageURL(String path, {required String size}) {
  final source = _tmdbDirectImageURL(path, size: size);
  final configured = StorageManager.get<String>(StorageKeys.tmdbImageProxy)?.trim();
  if (configured != null && configured.isEmpty) return source;
  final proxy = Uri.tryParse(configured ?? 'https://wsrv.nl');
  if (proxy == null || !proxy.hasScheme || proxy.host.isEmpty) return source;
  return proxy
      .replace(
        path: proxy.path.isEmpty ? '/' : proxy.path,
        queryParameters: {'url': source, 'output': 'webp', 'q': '85'},
      )
      .toString();
}

String _tmdbDirectImageURL(String path, {required String size}) {
  return mediaArtworkDirectURL(path, size: size);
}

String? _parentDirectoryName(String cloudPath) {
  final segments = cloudPath.split(RegExp(r'[/\\]+')).where((segment) => segment.isNotEmpty).toList();
  return segments.length < 2 ? null : segments[segments.length - 2];
}

String _parentCloudPath(String cloudPath) {
  final normalized = cloudPath.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index <= 0 ? '' : normalized.substring(0, index);
}

String _normalizedCloudPath(String value) {
  final parts = value
      .trim()
      .replaceAll('\\', '/')
      .split('/')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  return parts.isEmpty ? '' : '/${parts.join('/')}';
}

String _joinCloudPath(String parent, String name) {
  final root = _normalizedCloudPath(parent);
  return root.isEmpty ? '/$name' : '$root/$name';
}

String _mediaRecordKey(MediaLibraryItem item) => '${item.libraryID}:${item.id}';

class MediaLibraryPage extends ConsumerStatefulWidget {
  final bool showLibrarySidebar;
  final bool showManagementToolbar;
  final bool showBrowseHeader;
  final bool showHomePanel;
  final MediaLibraryBrowseFilter browseFilter;
  final MediaLibraryBrowseFilter librarySection;
  final String? searchTitle;
  final ValueChanged<String>? onOpenLibrary;
  final MediaLibraryFilter libraryFilter;
  final ValueChanged<MediaLibraryFilter>? onLibraryFilterChanged;

  const MediaLibraryPage({
    super.key,
    this.showLibrarySidebar = true,
    this.showManagementToolbar = false,
    this.showBrowseHeader = true,
    this.showHomePanel = false,
    this.browseFilter = MediaLibraryBrowseFilter.all,
    this.librarySection = MediaLibraryBrowseFilter.all,
    this.searchTitle,
    this.onOpenLibrary,
    this.libraryFilter = const MediaLibraryFilter(),
    this.onLibraryFilterChanged,
  });

  static void showCreateDialog(BuildContext context, WidgetRef ref) {
    _MediaLibraryPageState._showCreateLibraryDialog(context, ref);
  }

  static void showManagementDialog(BuildContext context, WidgetRef ref) {
    showShadDialog(context: context, builder: (_) => const _MediaLibraryManagementDialog());
  }

  static void showScanTaskDialog(BuildContext context, WidgetRef ref) {
    showShadDialog(context: context, builder: (_) => const _MediaLibraryScanTaskDialog());
  }

  @override
  ConsumerState<MediaLibraryPage> createState() => _MediaLibraryPageState();
}

class _MediaLibraryPageState extends ConsumerState<MediaLibraryPage> {
  String get _tmdbApiKey => StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
  bool _tmdbSearching = false;
  int _tmdbSearchSerial = 0;
  String? _tmdbError;
  List<Map<String, dynamic>> _tmdbResults = [];
  bool _backupBusy = false;
  final Set<String> _syncingWorkKeys = {};
  final Map<String, Object> _manualMatchOperations = {};
  final Set<String> _manualMatchPreparingResourceKeys = {};
  final Set<String> _manualMatchApplyingResourceKeys = {};
  _MediaWork? _detailWork;
  var _detailSession = 0;
  var _manualMatchSession = 0;
  late MediaLibraryBrowseFilter _wallFilter;
  late final MediaLibraryNotifier _mediaNotifier;
  /// 筛选态列表显示条目数上限，点击「加载更多」追加 50。
  int _filterLimit = 50;
  /// 筛选态加载更多进行中标志，让加载块在加载期间显示 loading 态。
  bool _loadingMoreFilter = false;
  void Function(MediaDetailHeader?) _setDetailHeader = (_) {};
  String? _activeCollectionKey;
  final _searchController = TextEditingController();
  final _contentScrollController = ScrollController();
  double _savedScrollOffset = 0.0;

  Set<String> get _manualMatchBusyResourceKeys => _manualMatchOperations.keys.toSet();

  Set<String> get _manualMatchLoadingResourceKeys => {
    ..._manualMatchPreparingResourceKeys,
    ..._manualMatchApplyingResourceKeys,
  };

  bool _workHasManualMatchOperation(_MediaWork work) =>
      work.resources.any((resource) => _manualMatchOperations.containsKey(_mediaRecordKey(resource)));

  @override
  void initState() {
    super.initState();
    _wallFilter = widget.browseFilter;
    _mediaNotifier = ref.read(mediaLibraryProvider.notifier);
    final detailHeaderNotifier = ref.read(activeMediaDetailHeaderProvider.notifier);
    _setDetailHeader = (value) => detailHeaderNotifier.state = value;
    final api = ref.read(authProvider.notifier).api;
    Future.microtask(() async {
      if (!mounted) return;
      _mediaNotifier.api = api;
      await _mediaNotifier.load();
      if (mounted) {
        await _mediaNotifier.loadContent(
          home: widget.showHomePanel,
          filter: _wallFilter,
          search: widget.searchTitle ?? '',
        );
      }
    });
  }

  @override
  void didUpdateWidget(covariant MediaLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final browseFilterChanged = oldWidget.browseFilter != widget.browseFilter;
    final enteredHome = !oldWidget.showHomePanel && widget.showHomePanel;
    final externalSearchChanged = oldWidget.searchTitle != widget.searchTitle;
    if (browseFilterChanged || enteredHome || externalSearchChanged) {
      _wallFilter = widget.browseFilter;
      _activeCollectionKey = null;
      _detailWork = null;
      _detailSession += 1;
      final detailSession = _detailSession;
      // didUpdateWidget runs during the parent's build. Defer the provider
      // write until that build has completed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _detailSession == detailSession) {
          _setDetailHeader(null);
          unawaited(
            _mediaNotifier.loadContent(
              home: widget.showHomePanel,
              filter: _wallFilter,
              search: widget.searchTitle ?? '',
            ),
          );
        }
      });
    }
  }

  Future<void> _openDetail(_MediaWork work) async {
    // 保存当前滚动位置，返回时恢复
    final currentScroll = _contentScrollController.hasClients ? _contentScrollController.offset : 0.0;
    // 网格中的 work 来自 distinctWorks 去重后的 allItems，只含 1 集；
    // 打开详情前从 store 全量加载该作品的所有资源（全部剧集/版本）。
    var fullWork = work;
    try {
      final primary = work.primary;
      final all = await ref
          .read(mediaLibraryProvider.notifier)
          .itemsForWork(
            tmdbID: primary.tmdbID,
            doubanID: primary.doubanID,
            title: primary.tmdbID == null && primary.doubanID == null ? primary.title : null,
            year: primary.tmdbID == null && primary.doubanID == null
                ? int.tryParse(primary.releaseDate.isNotEmpty ? primary.releaseDate.substring(0, 4) : '')
                : null,
          );
      if (all.isNotEmpty) {
        final byID = {for (final item in all) item.id: item};
        final merged = <MediaLibraryItem>[];
        final seen = <String>{};
        for (final item in [...all, ...work.resources]) {
          if (seen.add(item.id)) merged.add(item);
        }
        fullWork = _MediaWork(
          key: work.key,
          primary: byID[work.primary.id] ?? work.primary,
          resources: merged..sort((a, b) => a.file.name.toLowerCase().compareTo(b.file.name.toLowerCase())),
        );
      }
    } catch (_) {
      // Store read failure falls back to the grid's (possibly partial) work.
    }
    if (!mounted) return;
    setState(() {
      _detailSession += 1;
      _detailWork = fullWork;
      _savedScrollOffset = currentScroll;
    });
    _setDetailHeader(
      MediaDetailHeader(
        title: fullWork.primary.title,
        mediaKind: fullWork.primary.mediaKind,
        year: fullWork.primary.year,
      ),
    );
  }

  void _closeDetail() {
    setState(() {
      _detailSession += 1;
      _detailWork = null;
    });
    _setDetailHeader(null);
    // 返回列表后恢复滚动位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_contentScrollController.hasClients && _savedScrollOffset > 0) {
        _contentScrollController.jumpTo(_savedScrollOffset);
      }
    });
  }

  /// Re-derive the currently open detail work from a fresh items list. Called
  /// when the provider items change (e.g. a manual match wrote a tmdb/douban id
  /// and its background enrichment finished) so the detail page reflects the
  /// latest scraped metadata without a manual reopen.
  ///
  /// Matching is done by the resource file ids the detail currently shows,
  /// because a successful match changes the work key (an unmatched title-keyed
  /// work becomes tmdb/douban-keyed) and a rename can change file names.
  void _syncOpenDetailWithItems(List<MediaLibraryItem> items) {
    final current = _detailWork;
    if (current == null) return;
    final resourceIDs = current.resources.map((item) => item.id).toSet();
    if (resourceIDs.isEmpty) return;
    final works = _MediaWork.fromItems(items);
    // Prefer the work that still owns any of the tracked resource ids.
    final refreshed = works.where((work) => work.resources.any((item) => resourceIDs.contains(item.id))).firstOrNull;
    if (refreshed == null) return;
    // Skip redundant rebuilds when nothing observable changed.
    final before = current.primary;
    final after = refreshed.primary;
    String resourceSignature(_MediaWork work) => work.resources.map((item) => '${item.id}|${item.file.name}').join(',');
    final unchanged =
        refreshed.key == current.key &&
        after.tmdbID == before.tmdbID &&
        after.doubanID == before.doubanID &&
        after.title == before.title &&
        after.posterPath == before.posterPath &&
        after.overview == before.overview &&
        resourceSignature(refreshed) == resourceSignature(current);
    if (unchanged) return;
    setState(() => _detailWork = refreshed);
    _setDetailHeader(
      MediaDetailHeader(
        title: refreshed.primary.title,
        mediaKind: refreshed.primary.mediaKind,
        year: refreshed.primary.year,
      ),
    );
  }

  Future<void> _removeMediaRecords(List<MediaLibraryItem> records) async {
    if (records.isEmpty) return;
    AppLogger.info('Media', '[媒体库页面-移除记录] 请求移除 ${records.length} 条记录');
    try {
      await _mediaNotifier.removeMediaRecords(records);
    } catch (_) {
      return;
    }
    if (!mounted || _detailWork == null) return;

    final state = ref.read(mediaLibraryProvider);
    final useGlobalBrowse =
        widget.showHomePanel ||
        _wallFilter == MediaLibraryBrowseFilter.movies ||
        _wallFilter == MediaLibraryBrowseFilter.series ||
        _wallFilter == MediaLibraryBrowseFilter.unmatched;
    final works = _MediaWork.fromItems(useGlobalBrowse ? state.allItems : state.items);
    final refreshed = works.where((work) => work.key == _detailWork!.key).firstOrNull;
    if (refreshed == null) {
      _closeDetail();
      return;
    }

    setState(() => _detailWork = refreshed);
    _setDetailHeader(
      MediaDetailHeader(
        title: refreshed.primary.title,
        mediaKind: refreshed.primary.mediaKind,
        year: refreshed.primary.year,
      ),
    );
  }

  Future<bool> _deleteMediaFiles(List<MediaLibraryItem> records) async {
    final files = <String, CloudFile>{
      for (final record in records) record.file.id: record.file,
    }.values.toList(growable: false);
    if (files.isEmpty) return false;
    AppLogger.info('Media', '[媒体库页面-删除文件] 请求删除 ${files.length} 个云盘文件，对应 ${records.length} 条媒体记录');
    for (final f in files) {
      AppLogger.info('Media', '[媒体库页面-删除文件] 待删除文件：${f.name}，路径=${f.cloudPath}，ID=${f.id}');
    }
    final deleted = await ref.read(fileProvider.notifier).deleteFiles(files);
    AppLogger.info('Media', '[媒体库页面-删除文件] 云盘文件删除结果：$deleted');
    if (!deleted) return false;

    final fileIDs = files.map((file) => file.id).toSet();
    final allReferences = ref
        .read(mediaLibraryProvider)
        .allItems
        .where((item) => fileIDs.contains(item.file.id))
        .toList(growable: false);
    await _removeMediaRecords(allReferences.isEmpty ? records : allReferences);
    return true;
  }

  Future<void> _renameMediaFile(MediaLibraryItem item) async {
    final controller = TextEditingController(text: item.file.name);
    final newName = await showShadDialog<String>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: const Text('重命名文件'),
        description: Text(item.file.cloudPath),
        actions: [
          ShadButton.outline(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('取消')),
          ShadButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            leading: const Icon(LucideIcons.filePenLine, size: 16),
            child: const Text('重命名'),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: ShadInput(
            controller: controller,
            autofocus: true,
            placeholder: const Text('输入完整文件名'),
            onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
          ),
        ),
      ),
    );
    controller.dispose();
    if (!mounted || newName == null || newName == item.file.name) return;
    if (newName.isEmpty || newName.contains('/') || newName.contains('\\') || newName.contains('\u0000')) {
      ShadToaster.maybeOf(context)?.show(
        const ShadToast(
          title: Text('文件名无效'),
          description: Text('文件名不能为空，也不能包含路径分隔符。'),
          showCloseIconOnlyWhenHovered: false,
        ),
      );
      return;
    }

    try {
      await ref.read(authProvider.notifier).api.fsRename(item.file.id, newName);
      await _mediaNotifier.synchronizeRenamedFiles([item.file.copyWith(name: newName)]);
      if (!mounted) return;
      ShadToaster.maybeOf(
        context,
      )?.show(ShadToast(title: const Text('重命名完成'), description: Text(newName), showCloseIconOnlyWhenHovered: false));
    } catch (error) {
      if (!mounted) return;
      ShadToaster.maybeOf(context)?.show(
        ShadToast.destructive(
          title: const Text('重命名失败'),
          description: Text(error.toString()),
          showCloseIconOnlyWhenHovered: false,
        ),
      );
    }
  }

  Future<void> _moveCloudResource(MediaLibraryItem item) async {
    final libraries = ref
        .read(mediaLibraryProvider)
        .libraries
        .where((library) => library.sources.isNotEmpty)
        .toList(growable: false);
    if (libraries.isEmpty) return;
    final selection = await showShadDialog<_MediaMoveSelection>(
      context: context,
      builder: (_) => _MediaMoveDialog(sources: [item.file], libraries: libraries),
    );
    if (!mounted || selection == null) return;
    final destination = selection.destination;
    final sourceParent = item.file.parentID?.trim();
    final targetParent = destination.parentID?.trim();
    if ((sourceParent?.isEmpty ?? true ? null : sourceParent) ==
        (targetParent?.isEmpty ?? true ? null : targetParent)) {
      ShadToaster.maybeOf(context)?.show(
        const ShadToast(title: Text('移动文件'), description: Text('不能移动至相同目录'), showCloseIconOnlyWhenHovered: false),
      );
      return;
    }

    try {
      await ref.read(authProvider.notifier).api.fsMove([item.file.id], parentID: destination.parentID);
      final destinationPath = _joinCloudPath(destination.path, item.file.name);
      final movedFile = item.file.copyWith(
        cloudPath: destinationPath,
        parentID: destination.parentID,
        clearParentID: destination.parentID == null,
        clearFullParentIDs: true,
      );
      await _mediaNotifier.relocateMediaItemAsUnmatched(item, destination.library.id, movedFile);
      if (mounted) _closeDetail();
      if (!mounted) return;
      ShadToaster.maybeOf(context)?.show(
        ShadToast(
          title: const Text('文件移动完成'),
          description: Text(destination.path.isEmpty ? '云盘根目录' : destination.path),
          showCloseIconOnlyWhenHovered: false,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ShadToaster.maybeOf(context)?.show(
        ShadToast.destructive(
          title: const Text('文件移动失败'),
          description: Text(error.toString()),
          showCloseIconOnlyWhenHovered: false,
        ),
      );
    }
  }

  Future<void> _moveMediaFile(MediaLibraryItem item) async {
    final state = ref.read(mediaLibraryProvider);
    final library = state.libraries.where((value) => value.id == item.libraryID).firstOrNull;
    if (library == null) return;
    final destinationLibraries = state.libraries
        .where((candidate) => candidate.id != item.libraryID && candidate.sources.isNotEmpty)
        .toList(growable: false);
    if (destinationLibraries.isEmpty) {
      ShadToaster.maybeOf(context)?.show(
        const ShadToast(
          title: Text('没有可用的目标媒体库'),
          description: Text('请先为另一个媒体库配置至少一个资源目录。'),
          showCloseIconOnlyWhenHovered: false,
        ),
      );
      return;
    }
    final work = _MediaWork.fromItems(state.allItems)
        .where((candidate) => candidate.resources.any((resource) => _mediaRecordKey(resource) == _mediaRecordKey(item)))
        .firstOrNull;
    final associated = (work?.resources ?? [item])
        .where((resource) => resource.libraryID == item.libraryID)
        .toList(growable: false);
    final nodes = <String, CloudFile>{};
    final recordsByNode = <String, List<MediaLibraryItem>>{};
    for (final resource in associated) {
      final source = _mediaSourceForItem(library, resource);
      if (source == null) continue;
      final levels = await _loadMediaMoveSources(resource, source);
      final node = levels.last;
      nodes[node.id] = node;
      (recordsByNode[node.id] ??= []).add(resource);
    }
    if (!mounted) return;
    if (nodes.isEmpty) {
      ShadToaster.maybeOf(context)?.show(
        const ShadToast.destructive(
          title: Text('无法确定关联文件'),
          description: Text('没有找到可移动的媒体文件或文件夹。'),
          showCloseIconOnlyWhenHovered: false,
        ),
      );
      return;
    }
    final selection = await showShadDialog<_MediaMoveSelection>(
      context: context,
      builder: (_) => _MediaMoveDialog(sources: nodes.values.toList(growable: false), libraries: destinationLibraries),
    );
    if (!mounted || selection == null) return;
    final destination = selection.destination;
    final targetRootPath = _normalizedCloudPath(destination.path);
    final invalidTarget = nodes.values.any((node) {
      final path = _normalizedCloudPath(node.cloudPath);
      return path.isNotEmpty && (targetRootPath == path || targetRootPath.startsWith('$path/'));
    });
    if (invalidTarget) {
      ShadToaster.maybeOf(context)?.show(
        const ShadToast.destructive(
          title: Text('无法移动'),
          description: Text('目标媒体目录不能位于所选文件夹内部。'),
          showCloseIconOnlyWhenHovered: false,
        ),
      );
      return;
    }

    try {
      await ref
          .read(authProvider.notifier)
          .api
          .fsMove(nodes.keys.toList(growable: false), parentID: destination.parentID);
      for (final node in nodes.values) {
        final movedRootPath = _normalizedCloudPath(node.cloudPath);
        var records = movedRootPath.isEmpty
            ? <MediaLibraryItem>[]
            : state.allItems
                  .where((record) {
                    if (record.libraryID != item.libraryID) return false;
                    final path = _normalizedCloudPath(record.file.cloudPath);
                    return path == movedRootPath || path.startsWith('$movedRootPath/');
                  })
                  .toList(growable: false);
        if (records.isEmpty) records = recordsByNode[node.id] ?? const [];
        if (records.isEmpty) continue;
        if (movedRootPath.isEmpty) {
          for (final record in records) {
            final recordPath = _normalizedCloudPath(record.file.cloudPath);
            await _mediaNotifier.transferMediaRecords(
              [record],
              targetLibraryID: destination.library.id,
              sourceRootPath: recordPath,
              destinationRootPath: _joinCloudPath(_joinCloudPath(destination.path, node.name), record.file.name),
              movedNodeID: node.id,
              targetParentID: destination.parentID,
            );
          }
          continue;
        }
        await _mediaNotifier.transferMediaRecords(
          records,
          targetLibraryID: destination.library.id,
          sourceRootPath: movedRootPath,
          destinationRootPath: _joinCloudPath(destination.path, node.name),
          movedNodeID: node.id,
          targetParentID: destination.parentID,
        );
      }
      if (!mounted) return;
      _closeDetail();
      ShadToaster.maybeOf(context)?.show(
        ShadToast(
          title: const Text('移动完成'),
          description: Text(
            '${nodes.length} 个文件或文件夹 → ${destination.library.name} / '
            '${destination.path}',
          ),
          showCloseIconOnlyWhenHovered: false,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ShadToaster.maybeOf(context)?.show(
        ShadToast.destructive(
          title: const Text('移动失败'),
          description: Text(error.toString()),
          showCloseIconOnlyWhenHovered: false,
        ),
      );
    }
  }

  MediaLibrarySource? _mediaSourceForItem(MediaLibraryDefinition library, MediaLibraryItem item) {
    final itemPath = _normalizedCloudPath(item.file.cloudPath);
    final matching = library.sources.where((source) {
      final root = _normalizedCloudPath(source.path);
      return itemPath == root || itemPath.startsWith('$root/');
    }).toList()..sort((left, right) => right.path.length.compareTo(left.path.length));
    final ancestorIDs = RegExp(
      r'[A-Za-z0-9][A-Za-z0-9_-]*',
    ).allMatches(item.file.fullParentIDs ?? '').map((match) => match.group(0)).whereType<String>().toSet();
    return matching.firstOrNull ??
        library.sources.where((source) {
          final rootID = source.rootID?.trim();
          return rootID != null &&
              rootID.isNotEmpty &&
              (item.file.parentID?.trim() == rootID || ancestorIDs.contains(rootID));
        }).firstOrNull ??
        (library.sources.length == 1 ? library.sources.first : null);
  }

  Future<List<CloudFile>> _loadMediaMoveSources(MediaLibraryItem item, MediaLibrarySource librarySource) async {
    final values = <CloudFile>[item.file];
    var parentID = item.file.parentID?.trim();
    var parentPath = _parentCloudPath(item.file.cloudPath);
    final rootID = librarySource.rootID?.trim();
    final visited = <String>{item.id};
    while (parentID != null && parentID.isNotEmpty && parentID != rootID && visited.add(parentID)) {
      try {
        final detail = await ref.read(authProvider.notifier).api.fsDetail(parentID);
        final folder = _cloudFileFromResponse(detail, parentID);
        if (folder == null || !folder.isDirectory) break;
        values.add(folder.copyWith(cloudPath: parentPath));
        parentID = mediaParentIDFromMetadata(folder)?.trim();
        parentPath = _parentCloudPath(parentPath);
      } catch (error) {
        AppLogger.warning('Media', '读取可移动父目录失败：$parentID，$error');
        break;
      }
    }
    return values;
  }

  CloudFile? _cloudFileFromResponse(dynamic value, String expectedID) {
    if (value is Map) {
      try {
        final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
        if (file.id == expectedID) return file;
      } catch (_) {
        // Detail responses can contain envelope maps around the file object.
      }
      for (final child in value.values) {
        final file = _cloudFileFromResponse(child, expectedID);
        if (file != null) return file;
      }
    } else if (value is Iterable && value is! String) {
      for (final child in value) {
        final file = _cloudFileFromResponse(child, expectedID);
        if (file != null) return file;
      }
    }
    return null;
  }

  Future<void> _clearMediaMetadata(_MediaWork work, _MediaMetadataSource source) async {
    final records = work.resources.where((item) {
      return source == _MediaMetadataSource.tmdb ? item.tmdbID != null : item.doubanID?.trim().isNotEmpty == true;
    }).toList();
    if (records.isEmpty) return;
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: Text('清理 ${source.title} 信息？'),
        description: Text(work.primary.title),
        actions: [
          ShadButton.outline(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          ShadButton.destructive(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            leading: const Icon(Icons.link_off_rounded, size: 16),
            child: const Text('清理信息'),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '将从 ${records.length} 个资源记录中删除 ${source.title} 关联。'
            '若没有其他识别来源，条目会恢复为基于文件名的未匹配状态。',
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final resourceIDs = records.map((item) => item.id).toSet();
    try {
      await _mediaNotifier.clearMediaMetadata(
        records,
        clearTMDB: source == _MediaMetadataSource.tmdb,
        clearDouban: source == _MediaMetadataSource.douban,
      );
    } catch (error) {
      if (!mounted) return;
      ShadToaster.maybeOf(context)?.show(
        ShadToast.destructive(
          title: Text('清理 ${source.title} 信息失败'),
          description: Text(error.toString()),
          showCloseIconOnlyWhenHovered: false,
        ),
      );
      return;
    }
    if (!mounted) return;

    final refreshed = _MediaWork.fromItems(
      ref.read(mediaLibraryProvider).allItems,
    ).where((candidate) => candidate.resources.any((item) => resourceIDs.contains(item.id))).firstOrNull;
    if (refreshed == null) {
      _closeDetail();
      return;
    }
    setState(() => _detailWork = refreshed);
    _setDetailHeader(
      MediaDetailHeader(
        title: refreshed.primary.title,
        mediaKind: refreshed.primary.mediaKind,
        year: refreshed.primary.year,
      ),
    );
    ShadToaster.maybeOf(context)?.show(
      ShadToast(
        title: Text('已清理 ${source.title} 信息'),
        description: Text(refreshed.primary.title),
        showCloseIconOnlyWhenHovered: false,
      ),
    );
  }

  @override
  void dispose() {
    // Provider writes are forbidden while Flutter is unmounting this State.
    // The workspace owns the header lifecycle; it clears the value when the
    // media pane is left.  Do not update Riverpod from dispose.
    _searchController.dispose();
    _contentScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(mediaLibraryProvider);
    if (widget.showHomePanel && !state.isLoading && state.allItems.isEmpty && state.globalStatistics.total > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_mediaNotifier.loadContent(home: true, filter: MediaLibraryBrowseFilter.all));
        }
      });
    }
    ref.listen<MediaDetailHeader?>(activeMediaDetailHeaderProvider, (previous, next) {
      if (next == null && _detailWork != null) _closeDetail();
    });
    final compact = MediaQuery.sizeOf(context).width < 720;
    ref.listen<MediaLibraryState>(mediaLibraryProvider, (previous, next) {
      // Keep an open detail page in sync with metadata written in the
      // background (e.g. after a manual match wrote a tmdb/douban id and its
      // enrichment finished).
      if (_detailWork != null &&
          (previous == null ||
              !identical(previous.items, next.items) ||
              !identical(previous.allItems, next.allItems))) {
        final useGlobalBrowse =
            widget.showHomePanel ||
            _wallFilter == MediaLibraryBrowseFilter.movies ||
            _wallFilter == MediaLibraryBrowseFilter.series ||
            _wallFilter == MediaLibraryBrowseFilter.unmatched;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _syncOpenDetailWithItems(useGlobalBrowse ? next.allItems : next.items);
        });
      }
      final message = next.errorMessage ?? next.statusMessage;
      final previousMessage = previous?.errorMessage ?? previous?.statusMessage;
      final isProgressMessage = next.errorMessage == null && message?.startsWith('正在') == true;
      if (message == null || message.isEmpty || message == previousMessage || isProgressMessage) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ShadToaster.maybeOf(context)?.show(
          next.errorMessage == null
              ? ShadToast(title: const Text('媒体库'), description: Text(message), showCloseIconOnlyWhenHovered: false)
              : ShadToast.destructive(
                  title: const Text('媒体库操作失败'),
                  description: Text(message),
                  showCloseIconOnlyWhenHovered: false,
                ),
        );
      });
    });

    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 10 : 18, compact ? 10 : 14, compact ? 10 : 18, compact ? 10 : 18),
      child: Column(
        children: [
          if (!widget.showManagementToolbar && widget.showBrowseHeader) ...[
            _buildHeader(context, state, compact: compact),
            SizedBox(height: compact ? 8 : 12),
          ],
          Expanded(
            child: widget.showLibrarySidebar && !widget.showManagementToolbar && !compact && !_hideLibrarySection(state)
                ? Row(
                    children: [
                      _buildLibraryList(context, state),
                      VerticalDivider(width: 24, color: ShadTheme.of(context).colorScheme.border),
                      Expanded(child: _buildMainPanel(context, state)),
                    ],
                  )
                : _buildMainPanel(context, state),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterToolbar(BuildContext context, MediaLibraryState state, {required bool compact}) {
    final cs = ShadTheme.of(context).colorScheme;
    final activeCount = widget.libraryFilter.kinds.length +
        widget.libraryFilter.genres.length +
        widget.libraryFilter.resolutions.length +
        widget.libraryFilter.countries.length +
        widget.libraryFilter.decades.length +
        widget.libraryFilter.matchStates.length +
        widget.libraryFilter.watchedStates.length;
    final visibleItems = state.globalVisibleItems;
    final filtered = widget.libraryFilter.isActive
        ? visibleItems.where((item) => widget.libraryFilter.matches(item, skipKinds: true)).toList()
        : visibleItems;
    final totalCount = visibleItems.length;
    final resultCount = filtered.length;
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 6 : 8),
      child: Row(
        children: [
          ShadTooltip(
            builder: (_) => const Text('筛选影视库'),
            child: ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: () => widget.onLibraryFilterChanged?.call(widget.libraryFilter),
              leading: Icon(
                Icons.filter_alt_rounded,
                size: 16,
                color: widget.libraryFilter.isActive ? cs.primary : cs.foreground,
              ),
              child: const Text('筛选'),
            ),
          ),
          if (widget.libraryFilter.isActive) ...[
            const SizedBox(width: 4),
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: () => widget.onLibraryFilterChanged?.call(const MediaLibraryFilter()),
              leading: Icon(Icons.filter_alt_off_rounded, size: 16, color: cs.mutedForeground),
              child: const Text('清除'),
            ),
          ],
          const Spacer(),
          Text(
            widget.libraryFilter.isActive
                ? '筛选结果 $resultCount / $totalCount 项'
                : '共 $totalCount 项',
            style: TextStyle(fontSize: 12, color: cs.mutedForeground),
          ),
          if (activeCount > 0)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$activeCount',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: cs.primary),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, MediaLibraryState state, {required bool compact}) {
    final cs = ShadTheme.of(context).colorScheme;
    final useGlobalStatistics = widget.showHomePanel || _wallFilter != MediaLibraryBrowseFilter.all;
    final statistics = useGlobalStatistics ? state.globalStatistics : state.statistics;
    final library = state.selectedLibrary;
    final title = Row(
      children: [
        Icon(Icons.video_library_rounded, size: compact ? 22 : 26, color: cs.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                library?.name ?? '未选择媒体库',
                style: TextStyle(fontSize: compact ? 18 : 21, fontWeight: FontWeight.w700, color: cs.foreground),
              ),
              Text(
                _libraryStatisticsLabel(statistics),
                style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
    final search = ShadInput(
      controller: _searchController,
      placeholder: const Text('搜索影视库或匹配 TMDB…'),
      placeholderStyle: TextStyle(color: cs.mutedForeground, fontSize: 13),
      style: TextStyle(color: cs.foreground, fontSize: 13),
      leading: Icon(Icons.search_rounded, size: 16, color: cs.mutedForeground),
      onChanged: (value) => ref.read(mediaLibraryProvider.notifier).setSearchQuery(value),
      onSubmitted: _searchTMDB,
    );
    if (_detailWork != null) {
      return SizedBox(
        height: compact ? 42 : 46,
        child: Row(
          children: [
            ShadTooltip(
              builder: (_) => const Text('返回影视库'),
              child: ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: _closeDetail,
                child: const Icon(Icons.arrow_back_rounded, size: 18),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(child: title),
          ],
        ),
      );
    }
    if (compact) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const SizedBox(height: 8), search]);
    }
    return Row(
      children: [
        Expanded(child: title),
        const SizedBox(width: 20),
        SizedBox(width: 400, child: search),
      ],
    );
  }


  Widget _buildToolbar(BuildContext context, MediaLibraryState state) {
    final cs = ShadTheme.of(context).colorScheme;
    final detailWork = _detailWork;
    final compact = MediaQuery.sizeOf(context).width < 720;
    if (compact) {
      return Column(
        children: [
          Row(
            children: [
              if (detailWork != null) ...[
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: _closeDetail,
                  child: const Icon(Icons.arrow_back_rounded, size: 18),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: ShadInput(
                  controller: _searchController,
                  placeholder: const Text('搜索影视库或匹配 TMDB…'),
                  placeholderStyle: TextStyle(color: cs.mutedForeground, fontSize: 13),
                  style: TextStyle(color: cs.foreground, fontSize: 13),
                  leading: Icon(Icons.search_rounded, size: 16, color: cs.mutedForeground),
                  onChanged: (value) => ref.read(mediaLibraryProvider.notifier).setSearchQuery(value),
                  onSubmitted: _searchTMDB,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (detailWork == null) ...[
                  _managementActionStrip(context, state, compact: true),
                ],
                if (detailWork == null)
                  ShadTooltip(
                    builder: (_) => const Text('筛选影视库'),
                    child: ShadButton.ghost(
                      size: ShadButtonSize.sm,
                      onPressed: () => widget.onLibraryFilterChanged?.call(widget.libraryFilter),
                      leading: Icon(
                        Icons.filter_alt_rounded,
                        size: 16,
                        color: widget.libraryFilter.isActive ? cs.primary : cs.foreground,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        if (detailWork != null) ...[
          ShadButton.ghost(
            size: ShadButtonSize.sm,
            onPressed: _closeDetail,
            child: const Icon(Icons.arrow_back_rounded, size: 18),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: ShadInput(
            controller: _searchController,
            placeholder: const Text('搜索影视库或匹配 TMDB…'),
            placeholderStyle: TextStyle(color: cs.mutedForeground, fontSize: 13),
            style: TextStyle(color: cs.foreground, fontSize: 13),
            leading: Icon(Icons.search_rounded, size: 16, color: cs.mutedForeground),
            onChanged: (value) => ref.read(mediaLibraryProvider.notifier).setSearchQuery(value),
            onSubmitted: _searchTMDB,
          ),
        ),
        const SizedBox(width: 8),
        if (detailWork == null) ...[
          _managementActionStrip(context, state, compact: false),
        ],
        if (detailWork == null) ...[
          const SizedBox(width: 4),
          ShadTooltip(
            builder: (_) => const Text('筛选影视库'),
            child: ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: () => widget.onLibraryFilterChanged?.call(widget.libraryFilter),
              leading: Icon(
                Icons.filter_alt_rounded,
                size: 16,
                color: widget.libraryFilter.isActive ? cs.primary : cs.foreground,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFilterPanel(BuildContext context, MediaLibraryState state, {required bool compact}) {
    final visibleItems = state.globalVisibleItems;
    final availableGenres = <String>{};
    final availableCountries = <String>{};
    final hasWatchHistory = state.globalVisibleItems.any((item) =>
        (item.tmdbID != null && item.tmdbID != 0) ||
        (item.doubanID != null && item.doubanID!.isNotEmpty));
    for (final item in visibleItems) {
      availableGenres.addAll(item.genres);
      availableCountries.addAll(item.originCountries);
    }
    final watchedKeys = hasWatchHistory ? const <String>{'watched', 'unwatched'} : const <String>{};
    return MediaLibraryFilterPanel(
      filter: widget.libraryFilter,
      availableGenres: availableGenres,
      availableCountries: availableCountries,
      availableWatchedKeys: watchedKeys,
      onFilter: (next) => widget.onLibraryFilterChanged?.call(next),
      onCollapse: () => widget.onLibraryFilterChanged?.call(widget.libraryFilter),
    );
  }

  Widget _managementActionStrip(BuildContext context, MediaLibraryState state, {required bool compact}) {
    final cs = ShadTheme.of(context).colorScheme;
    final actions = <Widget>[
      ShadButton.ghost(
        size: ShadButtonSize.sm,
        onPressed: () => _showCreateLibraryDialog(context, ref),
        leading: const Icon(Icons.add_rounded, size: 16),
        child: const Text('新建'),
      ),
      ShadTooltip(
        builder: (_) => const Text('查看所有媒体库的刮削任务'),
        child: ShadButton.ghost(
          size: ShadButtonSize.sm,
          onPressed: () => MediaLibraryPage.showScanTaskDialog(context, ref),
          leading: const Icon(Icons.assignment_rounded, size: 16),
          child: Text(state.activeScanCount == 0 ? '刮削任务' : '任务 ${state.activeScanCount}'),
        ),
      ),
      _backupActionsMenu(state, compact: true),
      ShadTooltip(
        builder: (_) => const Text('筛选影视库'),
        child: ShadButton.ghost(
          size: ShadButtonSize.sm,
          onPressed: () => widget.onLibraryFilterChanged?.call(widget.libraryFilter),
          leading: Icon(
            Icons.filter_alt_rounded,
            size: 16,
            color: widget.libraryFilter.isActive ? cs.primary : cs.foreground,
          ),
          child: const Text('筛选'),
        ),
      ),
      state.isScanning
          ? ShadButton.destructive(
              size: ShadButtonSize.sm,
              onPressed: () => ref.read(mediaLibraryProvider.notifier).cancelScan(),
              leading: const Icon(Icons.stop_rounded, size: 16),
              child: const Text('停止扫描'),
            )
          : MediaScanMenu(
              compact: compact,
              disabled: state.selectedLibrary == null,
              onScanUnrecognized: () => ref
                  .read(mediaLibraryProvider.notifier)
                  .rescanSelectedLibrary(mode: MediaLibraryScanMode.unrecognizedOnly),
              onScanUnindexed: () => ref
                  .read(mediaLibraryProvider.notifier)
                  .rescanSelectedLibrary(mode: MediaLibraryScanMode.unindexedOnly),
              onForceAll: () =>
                  ref.read(mediaLibraryProvider.notifier).rescanSelectedLibrary(mode: MediaLibraryScanMode.forceAll),
            ),
    ];
    final content = compact
        ? Wrap(spacing: 4, runSpacing: 4, children: actions)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < actions.length; index++) ...[
                if (index > 0) const SizedBox(width: 4),
                actions[index],
              ],
            ],
          );
    return Container(
      width: compact ? double.infinity : null,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cs.muted.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.border),
      ),
      child: content,
    );
  }

  Widget _buildLibraryList(BuildContext context, MediaLibraryState state) {
    if (_hideLibrarySection(state)) return const SizedBox.shrink();
    final cs = ShadTheme.of(context).colorScheme;
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '媒体库',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cs.mutedForeground),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: state.libraries.isEmpty
                ? _emptyLibraryHint(context)
                : ListView.builder(
                    itemCount: state.libraries.length,
                    itemBuilder: (context, index) {
                      final library = state.libraries[index];
                      final selected = library.id == state.selectedLibrary?.id;
                      return _LibraryRow(
                        library: library,
                        selected: selected,
                        onTap: () => ref.read(mediaLibraryProvider.notifier).selectLibrary(library.id),
                        onEdit: () => _showEditLibraryDialog(context, ref, library),
                        onDelete: () => _deleteSidebarLibrary(library),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  static bool _hideLibrarySection(MediaLibraryState state) {
    if (state.libraries.isEmpty) return true;
    if (state.libraries.length == 1 && state.libraries.first.id == globalMediaLibraryID) {
      return true;
    }
    return false;
  }

  Widget _emptyLibraryHint(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.video_library_outlined, size: 42, color: cs.mutedForeground),
          const SizedBox(height: 12),
          Text('暂无媒体库', style: TextStyle(fontSize: 14, color: cs.mutedForeground)),
          const SizedBox(height: 10),
          ShadButton.outline(
            onPressed: () => MediaLibraryPage.showManagementDialog(context, ref),
            child: const Text('管理'),
          ),
        ],
      ),
    );
  }

  Widget _buildMainPanel(BuildContext context, MediaLibraryState state) {
    if (state.isLoading) {
      return const Center(
        child: AppLoadingIndicator(size: AppLoadingSize.page, label: '正在加载媒体库'),
      );
    }
    if (_tmdbSearching || _tmdbResults.isNotEmpty || _tmdbError != null) {
      return _tmdbResultPanel(context);
    }
    final externalSearchQuery = widget.searchTitle?.trim().toLowerCase() ?? '';
    final hasExternalSearch = externalSearchQuery.isNotEmpty;
    final isCurrentLibraryView =
        !hasExternalSearch && !widget.showHomePanel && _wallFilter == MediaLibraryBrowseFilter.all;
    final activeFilter = hasExternalSearch
        ? MediaLibraryBrowseFilter.all
        : isCurrentLibraryView
        ? widget.librarySection
        : _wallFilter;
    final useGlobalBrowse =
        hasExternalSearch ||
        widget.showHomePanel ||
        (!isCurrentLibraryView &&
            (_wallFilter == MediaLibraryBrowseFilter.movies ||
                _wallFilter == MediaLibraryBrowseFilter.series ||
                _wallFilter == MediaLibraryBrowseFilter.unmatched));
    final visibleItems = hasExternalSearch
        ? state.allItems.where((item) => item.matchesSearch(externalSearchQuery)).toList()
        : useGlobalBrowse
        ? state.globalVisibleItems
        : state.visibleItems;
    final collections = _MediaCollection.fromItems(visibleItems);
    final activeCollection = collections.where((collection) => collection.key == _activeCollectionKey).firstOrNull;
    final filteredItems = switch (activeFilter) {
      MediaLibraryBrowseFilter.all => visibleItems,
      MediaLibraryBrowseFilter.movies => visibleItems.where((item) => item.mediaKind == TMDBMediaKind.movie).toList(),
      MediaLibraryBrowseFilter.series => visibleItems.where((item) => item.mediaKind == TMDBMediaKind.tv).toList(),
      MediaLibraryBrowseFilter.collections => activeCollection?.resources ?? const [],
      MediaLibraryBrowseFilter.unmatched => visibleItems.where((item) => !item.isMatched).toList(),
    };
    // 顶部筛选面板的 7 维度过滤（影视分类已由 activeFilter 预筛，这里跳过 kinds 维度）
    final panelFiltered = widget.libraryFilter.isActive
        ? filteredItems.where((item) => widget.libraryFilter.matches(item, skipKinds: true)).toList()
        : filteredItems;
    final allWorks = _MediaWork.fromItems(panelFiltered);
    // 筛选态分批显示：默认前 50 条，点击「加载更多」追加下 50 条。
    final works = widget.libraryFilter.isActive && allWorks.length > _filterLimit
        ? allWorks.sublist(0, _filterLimit)
        : allWorks;
    final hasMoreFiltered = widget.libraryFilter.isActive && allWorks.length > works.length;
    // 加载更多已在 setState 后通过新 _filterLimit 把下一批纳入 works，重置加载态让块在加载完后消失。
    if (_loadingMoreFilter && !hasMoreFiltered) _loadingMoreFilter = false;
    if (state.selectedLibrary == null) {
      return _mainEmpty(context, '还没有媒体库', '从云盘根目录或当前目录创建一个媒体库');
    }
    if (_detailWork != null) {
      final detailResourceIDs = _detailWork!.resources.map((resource) => resource.id).toSet();
      final current = works
          .where(
            (work) =>
                work.key == _detailWork!.key ||
                work.resources.any((resource) => detailResourceIDs.contains(resource.id)),
          )
          .firstOrNull;
      final selectedWork = current ?? _detailWork!;
      return Stack(
        children: [
          _MediaDetailPanel(
            key: ValueKey('media-detail:${selectedWork.key}'),
            work: selectedWork,
            onDownload: (item) => ref.read(fileProvider.notifier).downloadFile(item.file),
            onPlay: (item) => unawaited(
              showMediaPlayerDialog(
                context,
                item.file,
                episodeCandidates: selectedWork.resources.map((resource) => resource.file).toList(),
                mediaKind: selectedWork.primary.mediaKind,
              ),
            ),
            onExternalPlay: (item) => showShadDialog(
              context: context,
              builder: (_) => ExternalPlayerDialog(file: item.file),
            ),
            onRecognize: () => unawaited(_refreshAndRecognizeDetail(selectedWork)),
            onManualMatch: (resource) => unawaited(_showManualTMDBMatch(selectedWork, resource)),
            onRefreshDetail: () => unawaited(_refreshDetailData(selectedWork)),
            onRefreshScrape: () => unawaited(_refreshCurrentScrape(selectedWork)),
            onRenameFile: _renameMediaFile,
            onMoveMediaResource: _moveMediaFile,
            onMoveCloudFile: _moveCloudResource,
            onClearMetadata: (source) => _clearMediaMetadata(selectedWork, source),
            manualMatchBusyResourceKeys: _manualMatchBusyResourceKeys,
            manualMatchLoadingResourceKeys: _manualMatchLoadingResourceKeys,
            onRemoveRecords: _removeMediaRecords,
            onDeleteFiles: _deleteMediaFiles,
            removalDisabled:
                state.isScanning ||
                _syncingWorkKeys.contains(selectedWork.key) ||
                _workHasManualMatchOperation(selectedWork),
            recognizing: _syncingWorkKeys.contains(selectedWork.key),
          ),
        ],
      );
    }
    final showingCollectionOverview = activeFilter == MediaLibraryBrowseFilter.collections && activeCollection == null;
    final wallContent = widget.showHomePanel && activeFilter == MediaLibraryBrowseFilter.all
        ? _homePanel(context, state)
        : showingCollectionOverview
        ? _collectionOverview(context, collections)
        : works.isEmpty && !widget.libraryFilter.isActive
        ? _mainEmpty(
            context,
            hasExternalSearch
                ? '没有匹配的影视资源'
                : state.isScanning
                ? '正在扫描媒体库'
                : (activeFilter == MediaLibraryBrowseFilter.all ? '没有扫描结果' : '当前筛选没有结果'),
            hasExternalSearch
                ? '尝试其他片名、文件名或路径关键词'
                : state.isScanning
                ? '发现并入库的资源会立即显示在这里'
                : '点击扫描读取该媒体库下的视频文件',
          )
        : ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: const {
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
                PointerDeviceKind.trackpad,
              },
            ),
            child: EasyRefresh.builder(
              header: ClassicHeader(
                dragText: '下拉刷新',
                armedText: '释放刷新',
                readyText: '正在刷新…',
                processingText: '正在刷新…',
                processedText: '刷新完成',
                noMoreText: '没有更多',
                failedText: '刷新失败',
              ),
              footer: const ClassicFooter(),
              onRefresh: () async {
                await _mediaNotifier.loadContent(
                  home: widget.showHomePanel,
                  filter: _wallFilter,
                  search: widget.searchTitle ?? '',
                  reset: true,
                  force: true,
                );
              },
              onLoad: state.hasMoreContent && !state.isLoadingMore ? _mediaNotifier.loadNextContentPage : null,
              childBuilder: (context, physics) => NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  final isVertical = axisDirectionToAxis(notification.metrics.axisDirection) == Axis.vertical;
                  if (notification.depth == 0 &&
                      isVertical &&
                      notification.metrics.extentAfter < 480 &&
                      state.hasMoreContent &&
                      !state.isLoadingMore) {
                    unawaited(_mediaNotifier.loadNextContentPage());
                  }
                  return false;
                },
                child: SingleChildScrollView(
                  controller: _contentScrollController,
                  physics: physics,
                  padding: const EdgeInsets.only(bottom: 16),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = MediaQuery.sizeOf(context).width < 720;
                      final spacing = compact ? 10.0 : 14.0;
                      // 列数按可用宽度算，非 compact 也撑满：每列目标 158（卡片 142 + 间距余量）。
                      final targetCardWidth = compact ? 130.0 : 158.0;
                      final columns = (constraints.maxWidth ~/ (targetCardWidth + spacing)).clamp(2, 12);
                      final cardWidth = (constraints.maxWidth - spacing * (columns - 1)) / columns;
                      final cardHeight = cardWidth / 0.52;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            spacing: spacing,
                            runSpacing: compact ? 14 : 18,
                            children: [
                              for (final work in works)
                                SizedBox(
                                  width: cardWidth,
                                  height: cardHeight,
                                  child: _MediaPosterTile(
                                    work: work,
                                    onOpen: () => _openDetail(work),
                                    onDownload: () => ref.read(fileProvider.notifier).downloadFile(work.primary.file),
                                    onRecognize: state.isScanning
                                        ? null
                                        : () => unawaited(_refreshAndRecognizeDetail(work)),
                                    onManualMatch: () => unawaited(_showManualTMDBMatch(work, work.primary)),
                                  ),
                                ),
                              if (hasMoreFiltered || _loadingMoreFilter)
                                SizedBox(
                                  width: cardWidth,
                                  height: cardHeight,
                                  child: _MediaPosterLoadingTile(
                                    isLoading: _loadingMoreFilter,
                                    posterURL: _randomPosterFromWorks(works),
                                    onLoadMore: () => setState(() {
                                      _loadingMoreFilter = true;
                                      _filterLimit += 50;
                                    }),
                                  ),
                                ),
                            ],
                          ),
                          if (state.isLoadingMore)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 20),
                              child: Center(child: AppLoadingIndicator(size: AppLoadingSize.inline)),
                            ),
                        ],
                      );
                    },
                  ), // LayoutBuilder
                ), // SingleChildScrollView
              ), // NotificationListener
            ), // EasyRefresh
          ); // ScrollConfiguration – end of wallContent statement
    final content = activeCollection == null
        ? wallContent
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: () => setState(() => _activeCollectionKey = null),
                leading: const Icon(Icons.arrow_back_rounded, size: 16),
                child: Text('返回合集'),
              ),
              const SizedBox(height: 8),
              Expanded(child: wallContent),
            ],
          );
    if (!state.isScanning) return content;
    return Column(
      children: [
        _scanProgress(context, state),
        const SizedBox(height: 10),
        Expanded(child: content),
      ],
    );
  }

  Widget _homePanel(BuildContext context, MediaLibraryState state) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final visibleItems = state.globalVisibleItems;
    final librarySections = [
      for (final library in state.libraries)
        (library: library, works: _MediaWork.fromItems(visibleItems.where((item) => item.libraryID == library.id))),
    ];
    final works = [for (final section in librarySections) ...section.works];
    final history = ref.watch(watchHistoryProvider);
    final itemByID = {
      for (final work in works)
        for (final item in work.resources) item.id: item,
    };
    final workByItemID = {
      for (final work in works)
        for (final item in work.resources) item.id: work,
    };
    final continuing = <_ContinueWatchingWork>[];
    final seenWorks = <String>{};
    for (final entry in history) {
      final item = itemByID[entry.fileID];
      final work = item == null ? null : workByItemID[item.id];
      if (entry.completed || item == null || work == null || !seenWorks.add('${item.libraryID}:${work.key}')) {
        continue;
      }
      continuing.add(_ContinueWatchingWork(work: work, item: item, entry: entry));
    }
    final visibleContinuing = continuing.take(10).toList(growable: false);
    final sections = <Widget>[];
    if (visibleContinuing.isNotEmpty) {
      sections.addAll([
        _homeSectionTitle(context, '继续观看', '${visibleContinuing.length} 项'),
        _horizontalHomeTrack(
          context,
          height: compact ? 170 : 178,
          itemCount: visibleContinuing.length,
          itemBuilder: (_, index) {
            final value = visibleContinuing[index];
            return _ContinueWatchingTile(
              value: value,
              onContinue: () => unawaited(
                showMediaPlayerDialog(
                  context,
                  value.item.file,
                  episodeCandidates: value.work.resources.map((item) => item.file).toList(),
                  mediaKind: value.work.primary.mediaKind,
                ),
              ),
            );
          },
        ),
      ]);
    }
    // 电影 / 剧集分区（使用各自独立加载的预览数据）
    final movieWorks = _MediaWork.fromItems(state.moviePreviewItems);
    final seriesWorks = _MediaWork.fromItems(state.seriesPreviewItems);
    final hasMovieSection = movieWorks.isNotEmpty;
    final hasSeriesSection = seriesWorks.isNotEmpty;
    // 电影 / 剧集分区
    if (hasMovieSection) {
      if (sections.isNotEmpty) sections.add(SizedBox(height: compact ? 18 : 24));
      sections.add(_homeSectionWithIcon(context, '电影', Icons.movie_rounded, movieWorks, compact));
    }
    if (hasSeriesSection) {
      if (sections.isNotEmpty) sections.add(SizedBox(height: compact ? 18 : 24));
      sections.add(_homeSectionWithIcon(context, '剧集', Icons.live_tv_rounded, seriesWorks, compact));
    }
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.trackpad,
        },
      ),
      child: EasyRefresh.builder(
        header: const ClassicHeader(),
        onRefresh: () =>
            _mediaNotifier.loadContent(home: true, filter: MediaLibraryBrowseFilter.all, reset: true, force: true),
        childBuilder: (context, physics) =>
            ListView(primary: false, physics: physics, padding: const EdgeInsets.only(bottom: 24), children: sections),
      ),
    );
  }

  Widget _horizontalHomeTrack(
    BuildContext context, {
    required double height,
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
  }) {
    return SizedBox(
      height: height,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: const {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
            PointerDeviceKind.trackpad,
          },
        ),
        child: ListView.separated(
          primary: false,
          scrollDirection: Axis.horizontal,
          itemCount: itemCount,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: itemBuilder,
        ),
      ),
    );
  }

  Widget _homeSectionTitle(BuildContext context, String title, String count) {
    final cs = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: cs.foreground),
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              count,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: 12, color: cs.mutedForeground),
            ),
          ),
        ],
      ),
    );
  }

  Widget _homeSectionWithIcon(BuildContext context, String label, IconData icon, List<_MediaWork> works, bool compact) {
    final maxItems = StorageManager.configuredMediaHomePreviewCount;
    final visible = works.take(maxItems).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Icon(icon, size: 17),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(fontSize: compact ? 16 : 17, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text('${works.length} 部', style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        _horizontalHomeTrack(
          context,
          height: compact ? 252 : 272,
          itemCount: visible.length + 1,
          itemBuilder: (_, index) {
            if (index == visible.length) {
              final filter = label == '电影' ? MediaLibraryBrowseFilter.movies : MediaLibraryBrowseFilter.series;
              // 从当前列表中取一张随机海报
              final posterPaths = visible
                  .map((w) => w.primary.posterPath)
                  .whereType<String>()
                  .where((p) => p.isNotEmpty)
                  .toList();
              final randomPoster = posterPaths.isEmpty ? null : posterPaths[index % posterPaths.length];
              return SizedBox(
                width: compact ? 132 : 142,
                child: _HomeSectionEntryTile(
                  label: '查看全部',
                  count: works.length,
                  icon: icon,
                  compact: compact,
                  posterPath: randomPoster,
                  onTap: () {
                    setState(() => _wallFilter = filter);
                    unawaited(_mediaNotifier.loadContent(home: false, filter: filter, reset: true, force: true));
                  },
                ),
              );
            }
            final work = visible[index];
            return SizedBox(
              width: compact ? 132 : 142,
              child: _MediaPosterTile(
                work: work,
                onOpen: () => _openDetail(work),
                onDownload: () => ref.read(fileProvider.notifier).downloadFile(work.primary.file),
                onRecognize: () => unawaited(_refreshAndRecognizeDetail(work)),
                onManualMatch: () => unawaited(_showManualTMDBMatch(work, work.primary)),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _homeLibrarySection(
    BuildContext context, {
    required MediaLibraryDefinition library,
    required List<_MediaWork> works,
    required int totalWorks,
    required bool compact,
    required bool searchActive,
  }) {
    final visibleWorks = works;
    final posterPaths = visibleWorks
        .map((work) => work.primary.posterPath)
        .whereType<String>()
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    final posterIndex = library.id.codeUnits.fold<int>(0, (value, codeUnit) => (value * 31 + codeUnit) & 0x7fffffff);
    final entryPosterPath = posterPaths.isEmpty ? null : posterPaths[posterIndex % posterPaths.length];
    final count = searchActive ? '${works.length} 个匹配作品' : '$totalWorks 个作品';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _homeSectionTitle(context, library.name, count),
        if (visibleWorks.isEmpty)
          SizedBox(
            height: compact ? 72 : 84,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Icon(
                    Icons.video_library_outlined,
                    size: compact ? 22 : 24,
                    color: ShadTheme.of(context).colorScheme.mutedForeground,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      searchActive ? '当前搜索在此媒体库中没有结果' : '此媒体库暂无资源',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: ShadTheme.of(context).colorScheme.mutedForeground),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          _horizontalHomeTrack(
            context,
            height: compact ? 252 : 272,
            itemCount: visibleWorks.length + 1,
            itemBuilder: (_, index) {
              if (index == visibleWorks.length) {
                return _HomeLibraryEntryTile(
                  library: library,
                  posterPath: entryPosterPath,
                  width: compact ? 132 : 142,
                  onOpen: () async {
                    if (widget.onOpenLibrary != null) {
                      widget.onOpenLibrary!(library.id);
                    } else {
                      await _mediaNotifier.selectLibrary(library.id);
                    }
                  },
                );
              }
              final work = visibleWorks[index];
              return SizedBox(
                width: compact ? 132 : 142,
                child: _MediaPosterTile(
                  work: work,
                  onOpen: () => _openDetail(work),
                  onDownload: () => ref.read(fileProvider.notifier).downloadFile(work.primary.file),
                  onRecognize: () => unawaited(_refreshAndRecognizeDetail(work)),
                  onManualMatch: () => unawaited(_showManualTMDBMatch(work, work.primary)),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _collectionOverview(BuildContext context, List<_MediaCollection> collections) {
    if (collections.isEmpty) {
      return _mainEmpty(context, '没有自动合集', '已匹配合集信息的电影会显示在这里');
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 154).floor().clamp(2, 7);
        return GridView.builder(
          padding: const EdgeInsets.only(bottom: 10),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 18,
            crossAxisSpacing: 14,
            childAspectRatio: 0.52,
          ),
          itemCount: collections.length,
          itemBuilder: (context, index) => _MediaCollectionTile(
            collection: collections[index],
            onOpen: () => setState(() {
              _activeCollectionKey = collections[index].key;
              _detailWork = null;
              _detailSession += 1;
            }),
          ),
        );
      },
    );
  }

  Widget _scanProgress(BuildContext context, MediaLibraryState state) {
    final cs = ShadTheme.of(context).colorScheme;
    return Semantics(
      label: '媒体扫描进度：${state.progress.phase}，已处理 ${state.progress.completed} 项',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cs.muted,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const AppLoadingIndicator(size: AppLoadingSize.compact, semanticsLabel: '正在扫描媒体库'),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(state.progress.phase, style: TextStyle(color: cs.foreground)),
                      const SizedBox(height: 2),
                      Text('已入库资源会实时显示。', style: TextStyle(fontSize: 12, color: cs.mutedForeground)),
                    ],
                  ),
                ),
              ],
            ),
            if (state.progress.hasStats) ...[const SizedBox(height: 10), _scanStatsRow(context, state.progress)],
            if (state.progress.fraction != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: state.progress.fraction,
                  minHeight: 4,
                  backgroundColor: cs.border,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Compact statistics strip shown above the progress bar.
  Widget _scanStatsRow(BuildContext context, MediaLibraryScanProgress p) {
    final entries = <({String label, int value})>[
      (label: '已有文件', value: p.scanned),
      (label: '入库文件', value: p.completed),
      (label: '待识别', value: p.pending),
      (label: '已识别', value: p.matched),
      (label: '未匹配', value: p.unmatched),
      (label: '已跳过', value: p.skipped),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [for (final entry in entries) _scanStatChip(context, entry.label, entry.value)],
    );
  }

  Widget _scanStatChip(BuildContext context, String label, int value) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: cs.mutedForeground)),
          const SizedBox(width: 6),
          Text(
            '$value',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.foreground),
          ),
        ],
      ),
    );
  }

  Widget _mainEmpty(BuildContext context, String title, String subtitle) {
    final cs = ShadTheme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.movie_creation_outlined, size: 56, color: cs.mutedForeground),
          const SizedBox(height: 14),
          Text(title, style: TextStyle(fontSize: 16, color: cs.foreground)),
          const SizedBox(height: 6),
          Text(subtitle, style: TextStyle(fontSize: 12, color: cs.mutedForeground)),
        ],
      ),
    );
  }

  Widget _tmdbResultPanel(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    if (_tmdbSearching) {
      return const Center(
        child: AppLoadingIndicator(size: AppLoadingSize.page, label: '正在搜索 TMDB'),
      );
    }
    if (_tmdbError != null) {
      return _mainEmpty(context, 'TMDB 请求失败', _tmdbError!);
    }
    if (_tmdbResults.isEmpty) {
      return _mainEmpty(context, '没有 TMDB 结果', '换一个片名继续搜索');
    }
    return ListView.separated(
      itemCount: _tmdbResults.length,
      separatorBuilder: (context, index) => Divider(color: cs.border, height: 1),
      itemBuilder: (context, index) => _buildTMDBResultItem(context, _tmdbResults[index]),
    );
  }

  Widget _buildTMDBResultItem(BuildContext context, Map<String, dynamic> item) {
    final cs = ShadTheme.of(context).colorScheme;
    final title = item['title'] ?? item['name'] ?? '未知';
    final originalTitle = item['original_title']?.toString() ?? item['original_name']?.toString() ?? '';
    final overview = item['overview']?.toString() ?? '';
    final releaseDate = item['release_date']?.toString() ?? item['first_air_date']?.toString() ?? '';
    final mediaType = item['media_type']?.toString() ?? 'movie';
    final posterPath = item['poster_path'] as String?;
    final year = releaseDate.length >= 4 ? releaseDate.substring(0, 4) : '';
    final originCountry = item['origin_country'] ?? item['original_language'];
    final countryStr = originCountry is List ? originCountry.join('/') : originCountry?.toString() ?? '';
    final isTV = mediaType == 'tv';
    // 详情中可能包含的额外信息（从 search 结果中有限可用）
    final seasons = item['number_of_seasons'];
    final episodes = item['number_of_episodes'];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: posterPath == null
                ? _posterPlaceholder(context, 74, 110)
                : CachedNetworkImage(
                    imageUrl: _tmdbImageURL(posterPath, size: 'w200'),
                    width: 74,
                    height: 110,
                    fit: BoxFit.cover,
                    errorWidget: (context, url, error) => _tmdbDirectFallback(
                      path: posterPath,
                      size: 'w200',
                      width: 74,
                      height: 110,
                      fallback: _posterPlaceholder(context, 74, 110),
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        year.isEmpty ? title.toString() : '$title ($year)',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.foreground),
                      ),
                    ),
                    ShadBadge(child: Text(isTV ? '剧集' : '电影')),
                  ],
                ),
                if (originalTitle.isNotEmpty && originalTitle != title) ...[
                  const SizedBox(height: 2),
                  Text(
                    originalTitle,
                    style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (year.isNotEmpty) _infoBadge(cs, '${year}年'),
                    if (countryStr.isNotEmpty) _infoBadge(cs, countryStr),
                    if (isTV) _infoBadge(cs, '剧集'),
                    if (seasons != null) _infoBadge(cs, '$seasons 季'),
                    if (episodes != null) _infoBadge(cs, '$episodes 集'),
                  ],
                ),
                if (overview.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    overview,
                    style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoBadge(ShadColorScheme cs, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: cs.muted, borderRadius: BorderRadius.circular(4)),
      child: Text(text, style: TextStyle(fontSize: 11, color: cs.mutedForeground)),
    );
  }

  Widget _posterPlaceholder(BuildContext context, double width, double height) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      color: cs.muted,
      child: Icon(Icons.movie_rounded, color: cs.mutedForeground),
    );
  }

  static void _showCreateLibraryDialog(BuildContext context, WidgetRef ref) {
    final fileState = ref.read(fileProvider);
    final currentPath = fileState.folderPath.isEmpty
        ? '云盘根目录'
        : fileState.folderPath.map((file) => file.name).join(' / ');
    showShadDialog(
      context: context,
      builder: (ctx) => _CreateMediaLibraryDialog(
        initialRootID: fileState.folderPath.isEmpty ? null : fileState.folderPath.last.id,
        initialPath: currentPath,
        initialName: fileState.folderPath.isEmpty ? '我的影视库' : fileState.folderPath.last.name,
      ),
    );
  }

  static void _showEditLibraryDialog(BuildContext context, WidgetRef ref, MediaLibraryDefinition library) {
    showShadDialog(
      context: context,
      builder: (_) => _CreateMediaLibraryDialog(
        initialRootID: library.rootID,
        initialPath: library.rootPath,
        initialName: library.name,
        editingLibrary: library,
      ),
    );
  }

  Future<void> _deleteSidebarLibrary(MediaLibraryDefinition library) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除媒体库',
      content: '将删除「${library.name}」的媒体库记录和本地刮削数据，不会删除云盘文件。',
      confirmText: '删除',
    );
    if (!confirmed || !mounted) return;
    AppLogger.info('Media', '[媒体库侧边栏-删除] 确认删除「${library.name}」，ID=${library.id}');
    try {
      await ref.read(mediaLibraryProvider.notifier).deleteLibrary(library.id);
    } catch (error) {
      AppLogger.warning('Media', '[媒体库侧边栏-删除] 删除失败：$error');
    }
  }

  Future<void> _exportScrapedData() async {
    final directory = await FilePicker.getDirectoryPath(dialogTitle: '选择刮削数据导出目录');
    if (directory == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await ref.read(mediaLibraryProvider.notifier).exportScrapedData('$directory/media-library.sqlite3');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _importScrapedData() async {
    final backup = await FilePicker.pickFile(
      dialogTitle: '导入影视缓存与刮削数据',
      type: FileType.custom,
      allowedExtensions: const ['sqlite3', 'sqlite', 'db'],
    );
    final path = backup?.path;
    if (path == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await ref.read(mediaLibraryProvider.notifier).importScrapedData(path);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _syncScrapedDataToCloud() async {
    setState(() => _backupBusy = true);
    try {
      await ref.read(mediaLibraryProvider.notifier).exportScrapedDataToCloud();
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Widget _backupActionsMenu(MediaLibraryState state, {bool compact = false}) {
    return _BackupActionsMenu(
      compact: compact,
      disabled: _backupBusy || state.hasActiveScans,
      progress: state.cloudBackupSync,
      onExport: _exportScrapedData,
      onImport: _importScrapedData,
      onExportWorks: _exportWorksData,
      onImportWorks: _importWorksData,
      onSyncToCloud: _syncScrapedDataToCloud,
      onRestoreFromCloud: _syncScrapedDataFromCloud,
      onRefreshScrape: _backupBusy || state.hasActiveScans ? null : _refreshScrapedData,
    );
  }

  Future<void> _refreshScrapedData() async {
    if (!mounted) return;
    setState(() => _backupBusy = true);
    try {
      final count = await ref.read(mediaLibraryProvider.notifier).refreshScrapedData();
      if (!mounted) return;
      ShadToaster.of(context).show(
        ShadToast(
          title: const Text('刷新刮削数据'),
          description: Text(count > 0 ? '已刷新 $count 条刮削数据' : '没有可刷新的条目（需先识别并带 TMDB ID）'),
        ),
      );
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _exportWorksData() async {
    final directory = await FilePicker.getDirectoryPath(dialogTitle: '选择刮削数据导出目录');
    if (directory == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-').substring(0, 19);
      await ref.read(mediaLibraryProvider.notifier).exportWorksData('$directory/works-export-$stamp.json');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _importWorksData() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: '选择刮削数据 JSON 文件',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final path = picked?.path;
    if (path == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await ref.read(mediaLibraryProvider.notifier).importWorksData(path);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _syncScrapedDataFromCloud() async {
    final notifier = ref.read(mediaLibraryProvider.notifier);
    setState(() => _backupBusy = true);
    List<CloudFile> backups;
    try {
      backups = await notifier.cloudScrapedBackups();
    } catch (_) {
      return;
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
    if (!mounted || backups.isEmpty) {
      if (mounted && backups.isEmpty) {
        ShadToaster.maybeOf(
          context,
        )?.show(const ShadToast(title: Text('云盘恢复'), description: Text('云盘中没有找到 media-library.sqlite3 备份。')));
      }
      return;
    }
    CloudFile? selected;
    while (selected == null) {
      if (!mounted) return;
      final action = await showShadDialog<_CloudBackupAction>(
        context: context,
        builder: (dialogContext) => ShadDialog(
          title: Text('从云盘恢复（${backups.length} 个备份）'),
          description: const Text('选择备份恢复，也可重命名或删除。'),
          scrollable: false,
          actions: [ShadButton.outline(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('取消'))],
          child: SizedBox(
            width: (MediaQuery.sizeOf(dialogContext).width - 32).clamp(300.0, 560.0).toDouble(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < backups.length; index++) ...[
                  _cloudBackupRestoreRow(dialogContext, backup: backups[index], index: index + 1),
                  if (index < backups.length - 1) const ShadSeparator.horizontal(),
                ],
              ],
            ),
          ),
        ),
      );
      if (action == null || !mounted) return;
      switch (action.kind) {
        case _CloudBackupActionKind.restore:
          selected = action.backup;
        case _CloudBackupActionKind.rename:
          await _renameCloudBackup(action.backup);
          backups = await notifier.cloudScrapedBackups();
        case _CloudBackupActionKind.delete:
          await _deleteCloudBackup(action.backup);
          backups = await notifier.cloudScrapedBackups();
      }
      if (backups.isEmpty && selected == null) return;
    }
    if (!mounted) return;
    final confirmed = await _confirmCloudBackupRestore(context, selected);
    if (!confirmed || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await notifier.importScrapedDataFromCloud(selected);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
    // 第一步下载完成后，弹窗确认是否覆盖本地数据（会清空）。
    if (!mounted || !notifier.hasPendingBackup) return;
    final apply = await _confirmApplyDownloadedBackup(context, selected.name);
    if (!apply || !mounted) {
      await notifier.discardDownloadedBackup();
      return;
    }
    setState(() => _backupBusy = true);
    try {
      await notifier.applyDownloadedBackup();
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<bool> _confirmApplyDownloadedBackup(
    BuildContext context,
    String backupName,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => ShadDialog.alert(
        title: const Text('确认恢复备份'),
        description: Text(
          '备份「$backupName」已下载完成。恢复将用其覆盖本地数据库，'
          '当前本地刮削数据会被清空。是否继续？',
        ),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('放弃'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Widget _cloudBackupRestoreRow(BuildContext context, {required CloudFile backup, int? index}) {
    final cs = ShadTheme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        decoration: BoxDecoration(
          color: cs.muted.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.border.withValues(alpha: 0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(width: 6),
                if (index != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, right: 2),
                    child: Text(
                      '$index',
                      style: TextStyle(fontSize: 11, color: cs.mutedForeground, fontWeight: FontWeight.w500),
                    ),
                  ),
                Expanded(
                  child: ShadButton.ghost(
                    expands: false,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    leading: Icon(Icons.dataset_rounded, size: 18, color: cs.primary),
                    onPressed: () =>
                        Navigator.of(context).pop(_CloudBackupAction(_CloudBackupActionKind.restore, backup)),
                    child: Text(
                      backup.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.foreground),
                    ),
                  ),
                ),
                ShadTooltip(
                  builder: (_) => const Text('重命名'),
                  child: ShadButton.ghost(
                    width: 32,
                    height: 32,
                    padding: EdgeInsets.zero,
                    onPressed: () =>
                        Navigator.of(context).pop(_CloudBackupAction(_CloudBackupActionKind.rename, backup)),
                    child: Icon(LucideIcons.pencil, size: 14, color: cs.mutedForeground),
                  ),
                ),
                ShadTooltip(
                  builder: (_) => const Text('删除'),
                  child: ShadButton.ghost(
                    width: 32,
                    height: 32,
                    padding: EdgeInsets.zero,
                    foregroundColor: cs.destructive,
                    onPressed: () =>
                        Navigator.of(context).pop(_CloudBackupAction(_CloudBackupActionKind.delete, backup)),
                    child: const Icon(LucideIcons.trash2, size: 14),
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(index != null ? 42 : 32, 0, 12, 8),
              child: Row(
                children: [
                  Text(
                    backup.formattedSize,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: cs.mutedForeground),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      backup.modifiedAt,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _renameCloudBackup(CloudFile backup) async {
    final controller = TextEditingController(text: backup.name);
    final value = await showShadDialog<String>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: const Text('重命名备份'),
        description: Text(backup.formattedSize),
        actions: [
          ShadButton.outline(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('取消')),
          ShadButton(onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()), child: const Text('保存')),
        ],
        child: ShadInput(controller: controller, autofocus: true),
      ),
    );
    controller.dispose();
    if (!mounted || value == null || value == backup.name) return;
    var name = value.trim();
    if (name.isEmpty || name.contains('/') || name.contains('\\')) return;
    if (!name.toLowerCase().endsWith('.sqlite3')) name = '$name.sqlite3';
    try {
      await ref.read(mediaLibraryProvider.notifier).renameCloudScrapedBackup(backup, name);
    } catch (error) {
      if (!mounted) return;
      ShadToaster.maybeOf(
        context,
      )?.show(ShadToast.destructive(title: const Text('重命名失败'), description: Text(error.toString())));
    }
  }

  Future<void> _deleteCloudBackup(CloudFile backup) async {
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: const Text('删除云盘备份？'),
        description: Text(backup.name),
        actions: [
          ShadButton.outline(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          ShadButton.destructive(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            leading: const Icon(LucideIcons.trash2, size: 16),
            child: const Text('删除'),
          ),
        ],
        child: const Text('删除后无法通过该备份恢复。'),
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(mediaLibraryProvider.notifier).deleteCloudScrapedBackup(backup);
    } catch (error) {
      if (!mounted) return;
      ShadToaster.maybeOf(
        context,
      )?.show(ShadToast.destructive(title: const Text('删除失败'), description: Text(error.toString())));
    }
  }

  Future<void> _searchTMDB(String query) async {
    final text = query.trim();
    if (text.isEmpty) return;
    final serial = ++_tmdbSearchSerial;

    setState(() {
      _tmdbSearching = true;
      _tmdbError = null;
      _tmdbResults = [];
    });

    try {
      final api = ref.read(authProvider.notifier).api;
      var results = <Map<String, dynamic>>[];
      if (_tmdbApiKey.isNotEmpty) {
        final result = await api.tmdbSearch(
          text,
          apiKey: _tmdbApiKey,
          proxyHost: StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
          proxyPort: StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
        );
        results =
            (result['results'] as List?)
                ?.whereType<Map>()
                .where((item) => item['media_type'] == 'movie' || item['media_type'] == 'tv')
                .map((item) => Map<String, dynamic>.from(item))
                .toList() ??
            [];
      }
      if (results.isEmpty) {
        final doubanResult = await api.doubanSearch(text);
        final items = doubanResult['items'];
        if (items is List) {
          results = items
              .whereType<Map>()
              .map((raw) {
                final target = raw['target'];
                if (target is! Map) return null;
                final candidate = Map<String, dynamic>.from(target);
                final cardSubtitle = (candidate['card_subtitle'] ?? '').toString();
                final type = cardSubtitle.contains('集') ? 'tv' : 'movie';
                candidate['media_type'] = type;
                candidate['id'] = candidate['id']?.toString();
                candidate['_source'] = 'douban';
                final yearStr = candidate['year']?.toString() ?? '';
                if (yearStr.length >= 4) {
                  candidate['release_date'] = '$yearStr-01-01';
                }
                candidate['poster_path'] = doubanPosterPath(candidate);
                candidate['overview'] = cardSubtitle;
                final rating = candidate['rating'];
                if (rating is Map) {
                  candidate['vote_average'] = rating['value'];
                  candidate['vote_count'] = rating['count'];
                }
                return candidate;
              })
              .whereType<Map<String, dynamic>>()
              .toList();
        }
      }
      if (!mounted || serial != _tmdbSearchSerial) return;
      setState(() {
        _tmdbResults = results;
        _tmdbSearching = false;
      });
    } catch (e) {
      if (!mounted || serial != _tmdbSearchSerial) return;
      setState(() {
        _tmdbError = e.toString();
        _tmdbSearching = false;
      });
    }
  }

  Future<void> _refreshAndRecognizeDetail(_MediaWork selected) async {
    if (!_syncingWorkKeys.add(selected.key)) return;
    final detailSession = _detailSession;
    setState(() {});
    try {
      final notifier = ref.read(mediaLibraryProvider.notifier);
      final resources = _recognitionResources(selected);
      final pendingMatches = await notifier.refreshAndRecognizeItems(resources);
      final groupedMatches = <String, MediaTMDBMatchRequest>{};
      for (final request in pendingMatches) {
        final first = request.items.first;
        final parsed = ParsedMediaName.parse(
          first.file.name,
          directoryName: _parentDirectoryName(first.file.cloudPath),
        );
        final key =
            '${first.libraryID}:${_parentCloudPath(first.file.cloudPath)}:'
            '${parsed.title.toLowerCase()}:${first.mediaKind?.name ?? 'auto'}';
        final existing = groupedMatches[key];
        groupedMatches[key] = MediaTMDBMatchRequest(
          items: [...?existing?.items, ...request.items],
          candidates: existing?.candidates ?? request.candidates,
        );
      }
      for (final request in groupedMatches.values) {
        if (!mounted) return;
        final parsed = ParsedMediaName.parse(
          request.items.first.file.name,
          directoryName: _parentDirectoryName(request.items.first.file.cloudPath),
        );
        final candidate = await _showManualMatchPopover(
          initialQuery: request.items.first.title,
          initialResults: request.candidates,
          initialSeason: parsed.season,
          initialEpisode: parsed.episode,
        );
        if (candidate == null) continue;
        if (candidate['media_type'] == 'tv') {
          await notifier.applyTMDBMatch(request.items.first, candidate);
        } else {
          for (var index = 0; index < request.items.length; index++) {
            await notifier.applyTMDBMatch(request.items[index], candidate, applyManualEpisodeOverride: index == 0);
          }
        }
      }
      if (!mounted || _detailWork == null || _detailSession != detailSession) {
        return;
      }
      final selectedIDs = resources.map((item) => item.id).toSet();
      final selectedGCIDs = resources
          .map((item) => item.file.gcid)
          .whereType<String>()
          .where((value) => value.isNotEmpty)
          .toSet();
      final selectedParentPaths = resources
          .map((item) => _parentCloudPath(item.file.cloudPath))
          .where((value) => value.isNotEmpty)
          .toSet();
      final selectedPaths = resources.map((item) => item.file.cloudPath).where((value) => value.isNotEmpty).toSet();
      final refreshedWorks = _MediaWork.fromItems(ref.read(mediaLibraryProvider).allItems);
      int matchScore(_MediaWork work) {
        var score = 0;
        for (final item in work.resources) {
          if (selectedIDs.contains(item.id)) score = math.max(score, 400);
          final gcid = item.file.gcid;
          if (gcid != null && selectedGCIDs.contains(gcid)) {
            score = math.max(score, 300);
          }
          if (selectedPaths.contains(item.file.cloudPath)) {
            score = math.max(score, 200);
          }
          if (selectedParentPaths.contains(_parentCloudPath(item.file.cloudPath))) {
            score = math.max(score, 100);
          }
        }
        return score;
      }

      final ranked =
          refreshedWorks.map((work) => (work: work, score: matchScore(work))).where((entry) => entry.score > 0).toList()
            ..sort((left, right) => right.score.compareTo(left.score));
      final refreshed = ranked.firstOrNull?.work;
      if (refreshed != null) {
        setState(() => _detailWork = refreshed);
        _setDetailHeader(
          MediaDetailHeader(
            title: refreshed.primary.title,
            mediaKind: refreshed.primary.mediaKind,
            year: refreshed.primary.year,
          ),
        );
      } else if (mounted) {
        _closeDetail();
      }
    } finally {
      if (mounted) {
        setState(() => _syncingWorkKeys.remove(selected.key));
      }
    }
  }

  List<MediaLibraryItem> _recognitionResources(_MediaWork selected) {
    final first = selected.primary;
    final parsed = ParsedMediaName.parse(first.file.name, directoryName: _parentDirectoryName(first.file.cloudPath));
    if (!parsed.isEpisode) return selected.resources;
    final parentPath = _parentCloudPath(first.file.cloudPath);
    final title = parsed.title.toLowerCase();
    final siblings = ref.read(mediaLibraryProvider).items.where((item) {
      if (_parentCloudPath(item.file.cloudPath) != parentPath) return false;
      final candidate = ParsedMediaName.parse(item.file.name, directoryName: _parentDirectoryName(item.file.cloudPath));
      return candidate.isEpisode && candidate.title.toLowerCase() == title;
    });
    return {
      for (final item in [...selected.resources, ...siblings]) item.id: item,
    }.values.toList();
  }

  Future<void> _refreshDetailData(_MediaWork work) async {
    if (_detailWork == null) return;
    // 从 provider 重新读取最新数据
    final refreshedWorks = _MediaWork.fromItems(ref.read(mediaLibraryProvider).allItems);
    final matched = refreshedWorks
        .where((w) => w.key == work.key || w.resources.any((r) => work.resources.any((wr) => wr.id == r.id)))
        .firstOrNull;
    if (matched != null && mounted) {
      setState(() => _detailWork = matched);
    }
  }

  Future<void> _refreshCurrentScrape(_MediaWork work) async {
    final ok = await ref.read(mediaLibraryProvider.notifier).refreshScrapedDataForItem(work.primary);
    if (!mounted) return;
    if (ok) {
      await _refreshDetailData(work);
    }
    ShadToaster.of(context).show(
      ShadToast(
        title: const Text('刷新刮削数据'),
        description: Text(ok ? '已刷新当前条目刮削数据' : '刷新失败（需先识别并带 TMDB ID）'),
      ),
    );
  }

  Future<void> _showManualTMDBMatch(_MediaWork work, MediaLibraryItem target) async {
    final targetKey = _mediaRecordKey(target);
    if (_manualMatchOperations.containsKey(targetKey)) return;
    final operation = Object();
    final detailSession = _detailSession;
    final matchSession = ++_manualMatchSession;
    final notifier = ref.read(mediaLibraryProvider.notifier);
    setState(() {
      _manualMatchOperations[targetKey] = operation;
      _manualMatchPreparingResourceKeys.add(targetKey);
    });
    try {
      // Manual matching only needs the selected resource's current filename
      // to initialize the search. Refreshing every resource in a large
      // series here blocks the dialog behind storage writes and a full reload.
      final resources = work.resources;
      // Works from the list too: do not require an open detail page. Only bail
      // if this invocation was superseded (session changed) or has no targets.
      if (!mounted || _detailSession != detailSession || resources.isEmpty) {
        return;
      }
      setState(() => _manualMatchPreparingResourceKeys.remove(targetKey));
      final queryResource =
          resources
              .where(
                (resource) =>
                    resource.libraryID == target.libraryID &&
                    (resource.id == target.id ||
                        (target.file.gcid?.isNotEmpty == true && resource.file.gcid == target.file.gcid)),
              )
              .firstOrNull ??
          target;
      final parsed = ParsedMediaName.parse(
        queryResource.file.name,
        directoryName: _parentDirectoryName(queryResource.file.cloudPath),
      );
      final candidate = await _showManualMatchPopover(
        initialQuery: parsed.title,
        initialYear: parsed.year,
        initialMediaKind: parsed.isEpisode || parsed.season != null
            ? 'tv'
            : switch (queryResource.mediaKind) {
                TMDBMediaKind.movie => 'movie',
                TMDBMediaKind.tv => 'tv',
                TMDBMediaKind.automatic || null => 'auto',
              },
        initialSeason: parsed.season,
        initialEpisode: parsed.episode,
      );
      if (candidate == null || !mounted || _detailSession != detailSession || matchSession != _manualMatchSession) {
        AppLogger.info('Media', '[手动匹配] 用户取消：${target.file.name}');
        return;
      }
      final source = candidate['_source']?.toString() ?? 'tmdb';
      final candidateTitle = (candidate['title'] ?? candidate['name'] ?? '').toString();
      final candidateID = candidate['id']?.toString() ?? '';
      AppLogger.info(
        'Media',
        '[手动匹配] 用户选中：${target.file.name} -> '
            '"$candidateTitle" (id=$candidateID, 来源=$source)',
      );
      setState(() => _manualMatchApplyingResourceKeys.add(targetKey));
      if (candidate['media_type'] == 'tv') {
        // 主资源和同文件夹其他剧集全部不等待后台处理
        unawaited(notifier.applyTMDBMatch(queryResource, candidate));
        final parentPath = _parentCloudPath(queryResource.file.cloudPath);
        if (parentPath.isNotEmpty) {
          final siblings = ref
              .read(mediaLibraryProvider)
              .allItems
              .where((item) => item.id != queryResource.id && _parentCloudPath(item.file.cloudPath) == parentPath);
          for (final sibling in siblings) {
            unawaited(notifier.applyTMDBMatch(sibling, candidate));
          }
        }
        // 触发异步刷新，不等待后台处理
        if (_detailWork != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _refreshDetailData(work);
          });
        }
      } else {
        // 主资源同步匹配，版本循环后台执行避免逐个await卡loading
        await notifier.applyTMDBMatch(queryResource, candidate);
        final siblings = resources.where((resource) => _mediaRecordKey(resource) != _mediaRecordKey(queryResource));
        for (final sibling in siblings) {
          unawaited(notifier.applyTMDBMatch(sibling, candidate));
        }
      }
      if (!mounted || _detailSession != detailSession || matchSession != _manualMatchSession) {
        return;
      }
      // Only update the open detail page if one is actually open; when invoked
      // from the list, the grid refreshes itself via the provider watch.
      if (_detailWork != null) {
        final resourceIDs = resources.map((item) => item.id).toSet();
        final refreshed = _MediaWork.fromItems(
          ref.read(mediaLibraryProvider).items,
        ).where((candidate) => candidate.resources.any((item) => resourceIDs.contains(item.id))).firstOrNull;
        if (refreshed != null) setState(() => _detailWork = refreshed);
      }
    } finally {
      if (mounted && identical(_manualMatchOperations[targetKey], operation)) {
        setState(() {
          _manualMatchOperations.remove(targetKey);
          _manualMatchPreparingResourceKeys.remove(targetKey);
          _manualMatchApplyingResourceKeys.remove(targetKey);
        });
      }
    }
  }

  Future<Map<String, dynamic>?> _showManualMatchPopover({
    required String initialQuery,
    List<Map<String, dynamic>>? initialResults,
    int? initialYear,
    String initialMediaKind = 'auto',
    int? initialSeason,
    int? initialEpisode,
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    final controller = ShadPopoverController();
    final completer = Completer<Map<String, dynamic>?>();
    late final OverlayEntry entry;
    late final VoidCallback onVisibilityChanged;
    void close([Map<String, dynamic>? value]) {
      if (!completer.isCompleted) completer.complete(value);
      controller.removeListener(onVisibilityChanged);
      Future.microtask(() => controller.dispose());
      entry.remove();
    }

    onVisibilityChanged = () {
      if (!controller.isOpen) close();
    };

    final size = MediaQuery.sizeOf(context);
    entry = OverlayEntry(
      builder: (overlayContext) => Positioned(
        left: 0,
        top: 0,
        child: ShadPopover(
          controller: controller,
          closeOnTapOutside: true,
          padding: EdgeInsets.zero,
          decoration: ShadDecoration.none,
          shadows: const [],
          anchor: ShadGlobalAnchor(
            Offset(
              size.width <= 560
                  ? (size.width / 2).clamp(0.0, size.width)
                  : (size.width * 0.5).clamp(280.0, size.width - 280.0),
              96,
            ),
          ),
          popover: (_) => SizedBox(
            width: size.width <= 480 ? (size.width - 12) : (size.width * 0.65).clamp(520.0, 960.0).toDouble(),
            height: size.height <= 560 ? (size.height - 80) : (size.height - 140).clamp(420.0, 680.0).toDouble(),
            child: _ManualTMDBMatchDialog(
              initialQuery: initialQuery,
              initialResults: initialResults,
              initialYear: initialYear,
              initialMediaKind: initialMediaKind,
              initialSeason: initialSeason,
              initialEpisode: initialEpisode,
              onSelected: close,
              onDismiss: close,
              embedded: true,
            ),
          ),
          child: const SizedBox(width: 1, height: 1),
        ),
      ),
    );
    controller.addListener(onVisibilityChanged);
    overlay.insert(entry);
    controller.show();
    return completer.future;
  }
}

class _MediaLibraryManagementDialog extends ConsumerStatefulWidget {
  const _MediaLibraryManagementDialog();

  @override
  ConsumerState<_MediaLibraryManagementDialog> createState() => _MediaLibraryManagementDialogState();
}

class _MediaLibraryScanTaskDialog extends ConsumerStatefulWidget {
  const _MediaLibraryScanTaskDialog();

  @override
  ConsumerState<_MediaLibraryScanTaskDialog> createState() => _MediaLibraryScanTaskDialogState();
}

class _MediaLibraryScanTaskDialogState extends ConsumerState<_MediaLibraryScanTaskDialog> {
  final _expandedTaskIDs = <String>{};
  bool _copiedLogs = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(mediaLibraryProvider);
    final cs = ShadTheme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 32).clamp(340.0, 1000.0).toDouble();
    final height = (size.height - 64).clamp(360.0, size.height).toDouble();
    final tasks = state.scanTasks;
    return ShadDialog(
      title: const Text('刮削任务管理'),
      description: const Text('查看所有媒体库的扫描、识别、入库任务，并管理任务状态。'),
      actions: [ShadButton.outline(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭'))],
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  state.hasActiveScans ? Icons.sync_rounded : Icons.check_circle_outline_rounded,
                  size: 18,
                  color: state.hasActiveScans ? cs.primary : cs.mutedForeground,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.activeScanCount == 0 ? '当前没有进行中的刮削任务' : '${state.activeScanCount} 个任务进行中',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: cs.mutedForeground),
                  ),
                ),
                if (tasks.any((task) => !task.isActive))
                  ShadTooltip(
                    builder: (_) => const Text('清理已结束任务'),
                    child: ShadButton.outline(
                      width: 38,
                      height: 34,
                      padding: EdgeInsets.zero,
                      onPressed: () => ref.read(mediaLibraryProvider.notifier).clearFinishedScanTasks(),
                      child: const Icon(Icons.cleaning_services_rounded, size: 16),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: tasks.isEmpty
                  ? _emptyState(context)
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final expandedLogHeight = (constraints.maxHeight - 138)
                            .clamp(240.0, constraints.maxHeight)
                            .toDouble();
                        return ListView.separated(
                          itemCount: tasks.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final task = tasks[index];
                            return _taskRow(context, task, expandedLogHeight: expandedLogHeight);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.assignment_outlined, size: 48, color: cs.mutedForeground),
          const SizedBox(height: 12),
          Text('暂无刮削任务', style: TextStyle(color: cs.foreground)),
          const SizedBox(height: 4),
          Text('从任意媒体库标题栏开始扫描后会出现在这里。', style: TextStyle(fontSize: 12, color: cs.mutedForeground)),
        ],
      ),
    );
  }

  Widget _taskRow(BuildContext context, MediaLibraryScanTask task, {required double expandedLogHeight}) {
    final cs = ShadTheme.of(context).colorScheme;
    final expanded = _expandedTaskIDs.contains(task.id);
    final tint = _taskStatusColor(context, task.status);
    final total = task.progress.total <= 0 ? null : task.progress.total;
    final isTerminal =
        task.status == MediaLibraryScanTaskStatus.stopped ||
        task.status == MediaLibraryScanTaskStatus.cancelled ||
        task.status == MediaLibraryScanTaskStatus.completed ||
        task.status == MediaLibraryScanTaskStatus.failed;
    final fraction = total == null || total == 0
        ? (isTerminal ? 0.0 : null)
        : task.progress.completed >= total
        ? 1.0
        : (task.progress.completed / total).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 620;
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.muted.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: cs.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(_taskStatusIcon(task.status), size: 20, color: tint),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.libraryName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${task.mode.title} · ${task.progress.phase.isEmpty ? task.status.title : task.progress.phase}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                        ),
                      ],
                    ),
                  ),
                  if (!narrow) ...[
                    const SizedBox(width: 12),
                    _statusPill(context, task.status),
                    const SizedBox(width: 8),
                  ],
                  _taskActions(context, task, expanded),
                ],
              ),
              if (narrow) ...[
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerLeft, child: _statusPill(context, task.status)),
              ],
              const SizedBox(height: 10),
              if (total != null && total > 0) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.progress.completed > 0
                            ? '已完成 ${task.progress.completed}/$total · 匹配 ${task.progress.matched} · 未识别 ${task.progress.unmatched}'
                            : '扫描 ${task.progress.scanned} 个文件 · 入库 $total · 待识别 ${task.progress.pending}',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.mutedForeground,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ] else if (task.progress.scanned > 0 || task.progress.completed > 0) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.progress.completed > 0
                            ? '已完成 ${task.progress.completed} · 匹配 ${task.progress.matched} · 未识别 ${task.progress.unmatched}'
                            : '扫描 ${task.progress.scanned} 个文件',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.mutedForeground,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 6,
                  color: tint,
                  backgroundColor: cs.border.withValues(alpha: 0.55),
                ),
              ),
              if (expanded) ...[
                const SizedBox(height: 12),
                if (task.failureReason?.isNotEmpty == true) ...[
                  Text(task.failureReason!, style: TextStyle(fontSize: 12, color: cs.destructive)),
                  const SizedBox(height: 8),
                ],
                _taskLogs(context, task, height: expandedLogHeight),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _statusPill(BuildContext context, MediaLibraryScanTaskStatus status) {
    final cs = ShadTheme.of(context).colorScheme;
    final tint = _taskStatusColor(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tint.withValues(alpha: 0.28)),
      ),
      child: Text(
        status.title,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: status == MediaLibraryScanTaskStatus.cancelled || status == MediaLibraryScanTaskStatus.stopped
              ? cs.mutedForeground
              : tint,
        ),
      ),
    );
  }

  Widget _taskActions(BuildContext context, MediaLibraryScanTask task, bool expanded) {
    final notifier = ref.read(mediaLibraryProvider.notifier);
    final actions = <Widget>[];
    if (task.status.canPause) {
      actions.add(
        _taskIconButton(tooltip: '暂停', icon: Icons.pause_rounded, onPressed: () => notifier.pauseScanTask(task.id)),
      );
    }
    if (task.status.canResume) {
      actions.add(
        _taskIconButton(
          tooltip: task.status == MediaLibraryScanTaskStatus.failed ? '重试' : '继续',
          icon: Icons.play_arrow_rounded,
          onPressed: () => unawaited(notifier.resumeScanTask(task.id)),
        ),
      );
    }
    if (task.status.canStop) {
      actions.add(
        _taskIconButton(
          tooltip: '停止',
          icon: Icons.stop_rounded,
          destructive: true,
          onPressed: () => notifier.stopScanTask(task.id),
        ),
      );
    }
    if (task.isActive) {
      actions.add(
        _taskIconButton(
          tooltip: '取消',
          icon: Icons.close_rounded,
          destructive: true,
          onPressed: () => notifier.cancelScanTask(task.id),
        ),
      );
    } else {
      actions.add(
        _taskIconButton(
          tooltip: '移除记录',
          icon: Icons.delete_outline_rounded,
          destructive: true,
          onPressed: () => notifier.removeScanTask(task.id),
        ),
      );
    }
    actions.add(
      _taskIconButton(
        tooltip: expanded ? '收起日志' : '查看实时日志',
        icon: expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
        onPressed: () {
          setState(() {
            if (expanded) {
              _expandedTaskIDs.remove(task.id);
            } else {
              _expandedTaskIDs.add(task.id);
            }
          });
        },
      ),
    );
    return Wrap(spacing: 4, runSpacing: 4, children: actions);
  }

  Widget _taskIconButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool destructive = false,
  }) {
    return ShadTooltip(
      builder: (_) => Text(tooltip),
      child: destructive
          ? ShadButton.destructive(
              width: 34,
              height: 32,
              padding: EdgeInsets.zero,
              onPressed: onPressed,
              child: Icon(icon, size: 16),
            )
          : ShadButton.outline(
              width: 34,
              height: 32,
              padding: EdgeInsets.zero,
              onPressed: onPressed,
              child: Icon(icon, size: 16),
            ),
    );
  }

  Widget _taskLogs(BuildContext context, MediaLibraryScanTask task, {required double height}) {
    final cs = ShadTheme.of(context).colorScheme;
    final logs = task.logs.reversed.toList(growable: false);
    return Container(
      height: height,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.background.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: cs.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                '实时日志',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cs.mutedForeground),
              ),
              const Spacer(),
              _taskIconButton(
                tooltip: _copiedLogs ? '已复制' : '复制日志',
                icon: _copiedLogs ? Icons.check_rounded : Icons.copy_all_rounded,
                onPressed: logs.isEmpty
                    ? null
                    : () {
                        final text = task.logs
                            .map((entry) => '${_formatLogTime(entry.createdAt)} ${entry.message}')
                            .join('\n');
                        Clipboard.setData(ClipboardData(text: text));
                        setState(() => _copiedLogs = true);
                        Future<void>.delayed(const Duration(seconds: 1), () {
                          if (mounted) setState(() => _copiedLogs = false);
                        });
                      },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: logs.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text('暂无日志', style: TextStyle(fontSize: 12, color: cs.mutedForeground)),
                  )
                : ListView.builder(
                    itemCount: logs.length,
                    itemBuilder: (context, index) {
                      final entry = logs[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 64,
                              child: Text(
                                _formatLogTime(entry.createdAt),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.mutedForeground,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                entry.message,
                                style: TextStyle(fontSize: 12, color: entry.isError ? cs.destructive : cs.foreground),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  IconData _taskStatusIcon(MediaLibraryScanTaskStatus status) {
    switch (status) {
      case MediaLibraryScanTaskStatus.queued:
        return Icons.schedule_rounded;
      case MediaLibraryScanTaskStatus.running:
        return Icons.sync_rounded;
      case MediaLibraryScanTaskStatus.paused:
        return Icons.pause_circle_outline_rounded;
      case MediaLibraryScanTaskStatus.stopping:
        return Icons.stop_circle_outlined;
      case MediaLibraryScanTaskStatus.stopped:
        return Icons.stop_circle_outlined;
      case MediaLibraryScanTaskStatus.cancelling:
        return Icons.cancel_outlined;
      case MediaLibraryScanTaskStatus.cancelled:
        return Icons.cancel_outlined;
      case MediaLibraryScanTaskStatus.completed:
        return Icons.check_circle_outline_rounded;
      case MediaLibraryScanTaskStatus.failed:
        return Icons.error_outline_rounded;
    }
  }

  Color _taskStatusColor(BuildContext context, MediaLibraryScanTaskStatus status) {
    final cs = ShadTheme.of(context).colorScheme;
    switch (status) {
      case MediaLibraryScanTaskStatus.running:
        return cs.primary;
      case MediaLibraryScanTaskStatus.paused:
        return Colors.amber.shade700;
      case MediaLibraryScanTaskStatus.completed:
        return Colors.green.shade600;
      case MediaLibraryScanTaskStatus.failed:
        return cs.destructive;
      case MediaLibraryScanTaskStatus.stopping:
      case MediaLibraryScanTaskStatus.cancelling:
        return Colors.orange.shade700;
      case MediaLibraryScanTaskStatus.queued:
      case MediaLibraryScanTaskStatus.stopped:
      case MediaLibraryScanTaskStatus.cancelled:
        return cs.mutedForeground;
    }
  }

  String _formatLogTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
  }
}

class _MediaLibraryManagementDialogState extends ConsumerState<_MediaLibraryManagementDialog> {
  bool _backupBusy = false;
  final _clearingLibraryIDs = <String>{};
  bool _clearingAllLibraries = false;

  Future<void> _refreshScrapedData() async {
    if (!mounted) return;
    setState(() => _backupBusy = true);
    try {
      final count = await ref.read(mediaLibraryProvider.notifier).refreshScrapedData();
      if (!mounted) return;
      ShadToaster.of(context).show(
        ShadToast(
          title: const Text('刷新刮削数据'),
          description: Text(count > 0 ? '已刷新 $count 条刮削数据' : '没有可刷新的条目（需先识别并带 TMDB ID）'),
        ),
      );
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(mediaLibraryProvider);
    final cs = ShadTheme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 32).clamp(320.0, 1000.0).toDouble();
    final height = (size.height - 160).clamp(360.0, 620.0).toDouble();
    return ShadDialog(
      title: const Text('媒体库管理'),
      description: const Text('集中管理媒体库、目录来源和刮削数据备份。'),
      actions: [ShadButton.outline(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭'))],
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            Row(
              children: [
                ShadButton(
                  size: ShadButtonSize.sm,
                  onPressed: () => _MediaLibraryPageState._showCreateLibraryDialog(context, ref),
                  leading: const Icon(Icons.add_rounded, size: 16),
                  child: const Text('新建'),
                ),
                const SizedBox(width: 8),
                _BackupActionsMenu(
                  compact: true,
                  disabled: _backupBusy || state.hasActiveScans,
                  progress: state.cloudBackupSync,
                  onExport: _exportScrapedData,
                  onImport: _importScrapedData,
                  onExportWorks: _exportWorksData,
                  onImportWorks: _importWorksData,
                  onSyncToCloud: _syncScrapedDataToCloud,
                  onRestoreFromCloud: _syncScrapedDataFromCloud,
                  onRefreshScrape: _backupBusy || state.hasActiveScans ? null : _refreshScrapedData,
                ),
                const SizedBox(width: 8),
                ShadTooltip(
                  builder: (_) => const Text('清理所有媒体库'),
                  child: ShadButton.destructive(
                    size: ShadButtonSize.sm,
                    onPressed: _backupBusy || state.hasActiveScans || state.libraries.isEmpty
                        ? null
                        : _clearAllLibraries,
                    leading: _clearingAllLibraries
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.delete_sweep_rounded, size: 16),
                    child: Text(_clearingAllLibraries ? '清理中' : '清理'),
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: state.hasActiveScans
                        ? Text(
                            '${state.activeScanCount} 个刮削任务进行中，备份恢复暂不可用',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: state.libraries.isEmpty
                  ? _emptyState(context)
                  : ListView.separated(
                      itemCount: state.libraries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final library = state.libraries[index];
                        final statistics = state.libraryStatistics[library.id] ?? const MediaLibraryStatistics();
                        final scanning = state.isLibraryScanning(library.id);
                        return _ManagementLibraryRow(
                          library: library,
                          statistics: statistics,
                          selected: library.id == state.selectedLibraryID,
                          disabled: scanning || _backupBusy,
                          clearing: _clearingLibraryIDs.contains(library.id),
                          onSelect: () => ref.read(mediaLibraryProvider.notifier).selectLibrary(library.id),
                          onEdit: () => _MediaLibraryPageState._showEditLibraryDialog(context, ref, library),
                          onDelete: () => _deleteLibrary(library),
                          onClear: () => _clearLibrary(library),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.video_library_outlined, size: 44, color: cs.mutedForeground),
          const SizedBox(height: 12),
          Text('暂无媒体库', style: TextStyle(color: cs.foreground)),
          const SizedBox(height: 6),
          Text('点击上方按钮创建第一个媒体库', style: TextStyle(fontSize: 12, color: cs.mutedForeground)),
        ],
      ),
    );
  }

  Future<void> _deleteLibrary(MediaLibraryDefinition library) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除媒体库',
      content: '将删除「${library.name}」的媒体库记录和本地刮削数据，不会删除云盘文件。',
      confirmText: '删除',
    );
    if (!confirmed || !mounted) return;
    setState(() => _backupBusy = true);
    AppLogger.info('Media', '[媒体库页面-删除媒体库] 确认删除「${library.name}」，ID=${library.id}');
    try {
      await ref.read(mediaLibraryProvider.notifier).deleteLibrary(library.id);
    } catch (error) {
      AppLogger.warning('Media', '[媒体库页面-删除媒体库] 删除失败：$error');
      if (mounted) {
        showShadDialog(
          context: context,
          builder: (_) => ShadDialog(
            title: const Text('删除失败'),
            description: Text('删除媒体库「${library.name}」时出错：$error'),
            actions: [ShadButton(onPressed: () => Navigator.of(context).pop(), child: const Text('确定'))],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _clearLibrary(MediaLibraryDefinition library) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '清空媒体库',
      content: '将清空「${library.name}」的所有影视记录和刮削数据，媒体库目录配置保留。之后可重新扫描。',
      confirmText: '清空',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _backupBusy = true;
      _clearingLibraryIDs.add(library.id);
    });
    AppLogger.info('Media', '[媒体库页面-清空媒体库] 确认清空「${library.name}」，ID=${library.id}');
    try {
      await ref.read(mediaLibraryProvider.notifier).clearLibrary(library.id);
    } finally {
      if (mounted) {
        setState(() {
          _backupBusy = false;
          _clearingLibraryIDs.remove(library.id);
        });
      }
    }
  }

  Future<void> _clearAllLibraries() async {
    final libs = ref.read(mediaLibraryProvider).libraries;
    final count = libs.length;
    if (count == 0) return;
    final confirmed = await showConfirmDialog(
      context,
      title: '清理所有媒体库',
      content:
          '将清空全部 $count 个媒体库的所有影视记录和刮削数据，'
          '媒体库目录配置保留。之后可重新扫描。',
      confirmText: '全部清空',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _backupBusy = true;
      _clearingAllLibraries = true;
    });
    AppLogger.info('Media', '[媒体库页面-清空所有] 确认清空 $count 个媒体库');
    try {
      for (final library in libs) {
        if (!mounted) return;
        await ref.read(mediaLibraryProvider.notifier).clearLibrary(library.id);
      }
    } finally {
      if (mounted) {
        setState(() {
          _backupBusy = false;
          _clearingAllLibraries = false;
        });
      }
    }
  }

  Future<void> _exportScrapedData() async {
    final directory = await FilePicker.getDirectoryPath(dialogTitle: '选择刮削数据导出目录');
    if (directory == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await ref.read(mediaLibraryProvider.notifier).exportScrapedData('$directory/media-library.sqlite3');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _importScrapedData() async {
    final backup = await FilePicker.pickFile(
      dialogTitle: '导入影视缓存与刮削数据',
      type: FileType.custom,
      allowedExtensions: const ['sqlite3', 'sqlite', 'db'],
    );
    final path = backup?.path;
    if (path == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await ref.read(mediaLibraryProvider.notifier).importScrapedData(path);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _syncScrapedDataToCloud() async {
    setState(() => _backupBusy = true);
    try {
      await ref.read(mediaLibraryProvider.notifier).exportScrapedDataToCloud();
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _syncScrapedDataFromCloud() async {
    final notifier = ref.read(mediaLibraryProvider.notifier);
    setState(() => _backupBusy = true);
    List<CloudFile> backups;
    try {
      backups = await notifier.cloudScrapedBackups();
    } catch (_) {
      return;
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
    if (!mounted || backups.isEmpty) {
      if (mounted && backups.isEmpty) {
        ShadToaster.maybeOf(
          context,
        )?.show(const ShadToast(title: Text('云盘恢复'), description: Text('云盘中没有找到 media-library.sqlite3 备份。')));
      }
      return;
    }
    final selected = await showShadDialog<CloudFile>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: const Text('从云盘恢复刮削数据'),
        description: const Text('选择一个 SQLite 备份，恢复会覆盖当前本地媒体库。'),
        scrollable: false,
        actions: [ShadButton.outline(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('取消'))],
        child: SizedBox(
          width: (MediaQuery.sizeOf(dialogContext).width - 32).clamp(300.0, 520.0).toDouble(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < backups.length; index++) ...[
                _CloudBackupRestoreRow(backup: backups[index]),
                if (index < backups.length - 1) const ShadSeparator.horizontal(),
              ],
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final confirmed = await _confirmCloudBackupRestore(context, selected);
    if (!confirmed || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await notifier.importScrapedDataFromCloud(selected);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
    // 第一步下载完成后，弹窗确认是否覆盖本地数据（会清空）。
    if (!mounted || !notifier.hasPendingBackup) return;
    final apply = await _confirmApplyDownloadedBackup(context, selected.name);
    if (!apply || !mounted) {
      await notifier.discardDownloadedBackup();
      return;
    }
    setState(() => _backupBusy = true);
    try {
      await notifier.applyDownloadedBackup();
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<bool> _confirmApplyDownloadedBackup(
    BuildContext context,
    String backupName,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => ShadDialog.alert(
        title: const Text('确认恢复备份'),
        description: Text(
          '备份「$backupName」已下载完成。恢复将用其覆盖本地数据库，'
          '当前本地刮削数据会被清空。是否继续？',
        ),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('放弃'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _exportWorksData() async {
    final directory = await FilePicker.getDirectoryPath(dialogTitle: '选择刮削数据导出目录');
    if (directory == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-').substring(0, 19);
      await ref.read(mediaLibraryProvider.notifier).exportWorksData('$directory/works-export-$stamp.json');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _importWorksData() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: '选择刮削数据 JSON 文件',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final path = picked?.path;
    if (path == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await ref.read(mediaLibraryProvider.notifier).importWorksData(path);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }
}

class _LibraryRow extends StatelessWidget {
  final MediaLibraryDefinition library;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _LibraryRow({
    required this.library,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: selected ? cs.primary.withValues(alpha: 0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: selected ? cs.primary : cs.border),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
            child: Row(
              children: [
                Icon(Icons.video_library_rounded, size: 20, color: selected ? cs.primary : cs.mutedForeground),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        library.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          color: cs.foreground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${library.kind.title} · ${library.rootPath}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                      ),
                    ],
                  ),
                ),
                ShadTooltip(
                  builder: (_) => const Text('管理媒体库'),
                  child: ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: onEdit,
                    child: const Icon(Icons.edit_outlined, size: 15),
                  ),
                ),
                ShadTooltip(
                  builder: (_) => const Text('删除媒体库'),
                  child: ShadButton.destructive(
                    size: ShadButtonSize.sm,
                    onPressed: onDelete,
                    child: const Icon(Icons.delete_outline_rounded, size: 15),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

