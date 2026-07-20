import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;

import '../core/storage/storage_manager.dart';
import '../models/cloud_file.dart';
import '../models/media_library.dart';
import '../models/media_navigation.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../providers/watch_history_provider.dart';
import '../models/watch_history.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_loading_indicator.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/media_player_dialog.dart';

export '../models/media_navigation.dart'
    show MediaLibraryBrowseFilter, MediaNavigationState, MediaWorkspaceView;

String _tmdbImageURL(String path, {required String size}) {
  final source = _tmdbDirectImageURL(path, size: size);
  final configured = StorageManager.get<String>(
    StorageKeys.tmdbImageProxy,
  )?.trim();
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
  return path.startsWith('http')
      ? path
      : 'https://image.tmdb.org/t/p/$size$path';
}

String? _parentDirectoryName(String cloudPath) {
  final segments = cloudPath
      .split(RegExp(r'[/\\]+'))
      .where((segment) => segment.isNotEmpty)
      .toList();
  return segments.length < 2 ? null : segments[segments.length - 2];
}

String _parentCloudPath(String cloudPath) {
  final normalized = cloudPath.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index <= 0 ? '' : normalized.substring(0, index);
}

String _mediaRecordKey(MediaLibraryItem item) => '${item.libraryID}:${item.id}';

Widget _tmdbDirectFallback({
  required String path,
  required String size,
  required Widget fallback,
  BoxFit fit = BoxFit.cover,
  double? width,
  double? height,
}) {
  return CachedNetworkImage(
    imageUrl: _tmdbDirectImageURL(path, size: size),
    fit: fit,
    width: width,
    height: height,
    errorWidget: (_, _, _) => fallback,
  );
}

class MediaLibraryPage extends ConsumerStatefulWidget {
  final bool showLibrarySidebar;
  final bool showManagementToolbar;
  final bool showBrowseHeader;
  final bool showHomePanel;
  final MediaLibraryBrowseFilter browseFilter;
  final MediaLibraryBrowseFilter librarySection;
  final String? searchTitle;

  const MediaLibraryPage({
    super.key,
    this.showLibrarySidebar = true,
    this.showManagementToolbar = false,
    this.showBrowseHeader = true,
    this.showHomePanel = false,
    this.browseFilter = MediaLibraryBrowseFilter.all,
    this.librarySection = MediaLibraryBrowseFilter.all,
    this.searchTitle,
  });

  static void showCreateDialog(BuildContext context, WidgetRef ref) {
    _MediaLibraryPageState._showCreateLibraryDialog(context, ref);
  }

  static void showManagementDialog(BuildContext context, WidgetRef ref) {
    showShadDialog(
      context: context,
      builder: (_) => const _MediaLibraryManagementDialog(),
    );
  }

  static void showScanTaskDialog(BuildContext context, WidgetRef ref) {
    showShadDialog(
      context: context,
      builder: (_) => const _MediaLibraryScanTaskDialog(),
    );
  }

  @override
  ConsumerState<MediaLibraryPage> createState() => _MediaLibraryPageState();
}

class _BackupActionsMenu extends StatefulWidget {
  final bool compact;
  final bool disabled;
  final CloudBackupSyncProgress? progress;
  final VoidCallback onExport;
  final VoidCallback onImport;
  final VoidCallback onSyncToCloud;
  final VoidCallback onRestoreFromCloud;

  const _BackupActionsMenu({
    required this.compact,
    required this.disabled,
    required this.progress,
    required this.onExport,
    required this.onImport,
    required this.onSyncToCloud,
    required this.onRestoreFromCloud,
  });

  @override
  State<_BackupActionsMenu> createState() => _BackupActionsMenuState();
}

class _BackupActionsMenuState extends State<_BackupActionsMenu> {
  final _controller = ShadPopoverController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    final active = progress?.isActive == true;
    final percentage = ((progress?.fraction ?? 0) * 100).round();
    final label = active
        ? '${progress!.phase} $percentage%'
        : progress?.error != null
        ? progress!.phase.contains('恢复')
              ? '数据恢复失败'
              : '数据备份失败'
        : '数据备份';
    return ShadPopover(
      controller: _controller,
      popover: (_) => SizedBox(
        width: 220,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (progress?.error?.trim().isNotEmpty == true) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ShadTheme.of(
                    context,
                  ).colorScheme.destructive.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: ShadTheme.of(
                      context,
                    ).colorScheme.destructive.withValues(alpha: 0.34),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${progress!.phase}原因',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: ShadTheme.of(context).colorScheme.destructive,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 96),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          progress.error!,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.35,
                            color: ShadTheme.of(context).colorScheme.foreground,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
            ],
            _item(
              icon: Icons.save_alt_rounded,
              label: '导出数据',
              onPressed: widget.onExport,
            ),
            _item(
              icon: Icons.upload_file_rounded,
              label: '导入数据',
              onPressed: widget.onImport,
            ),
            _item(
              icon: Icons.cloud_upload_rounded,
              label: '同步到云盘',
              onPressed: widget.onSyncToCloud,
            ),
            _item(
              icon: Icons.cloud_download_rounded,
              label: '从云盘恢复',
              onPressed: widget.onRestoreFromCloud,
            ),
          ],
        ),
      ),
      child: ShadButton.outline(
        size: widget.compact ? ShadButtonSize.sm : null,
        onPressed: widget.disabled || active ? null : _controller.toggle,
        leading: active
            ? AppLoadingIndicator(
                value: progress!.fraction,
                size: AppLoadingSize.inline,
                semanticsLabel: '云盘备份进度',
                semanticsValue: '${(progress.fraction * 100).round()}%',
              )
            : const Icon(Icons.storage_rounded, size: 16),
        trailing: const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
        child: Text(label),
      ),
    );
  }

  Widget _item({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) => ShadButton.ghost(
    width: double.infinity,
    mainAxisAlignment: MainAxisAlignment.start,
    leading: Icon(icon, size: 16),
    onPressed: () {
      _controller.hide();
      onPressed();
    },
    child: Text(label),
  );
}

class MediaScanMenu extends StatefulWidget {
  final bool compact;
  final bool iconOnly;
  final bool disabled;
  final VoidCallback onScanUnrecognized;
  final VoidCallback onForceAll;
  final ShadPopoverController? controller;

  const MediaScanMenu({
    super.key,
    required this.compact,
    this.iconOnly = false,
    required this.disabled,
    required this.onScanUnrecognized,
    required this.onForceAll,
    this.controller,
  });

  @override
  State<MediaScanMenu> createState() => MediaScanMenuState();
}

class MediaScanMenuState extends State<MediaScanMenu> {
  late final _controller = widget.controller ?? ShadPopoverController();

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final trigger = widget.iconOnly
        ? ShadTooltip(
            builder: (_) => const Text('重新扫描'),
            child: ShadButton.ghost(
              width: 38,
              height: 36,
              padding: EdgeInsets.zero,
              onPressed: widget.disabled ? null : _controller.toggle,
              child: const Icon(Icons.refresh_rounded, size: 18),
            ),
          )
        : ShadButton.ghost(
            size: ShadButtonSize.sm,
            onPressed: widget.disabled ? null : _controller.toggle,
            leading: const Icon(Icons.refresh_rounded, size: 16),
            trailing: const Icon(Icons.keyboard_arrow_down_rounded, size: 15),
            child: Text(widget.compact ? '扫描' : '重新扫描'),
          );
    return ShadPopover(
      controller: _controller,
      popover: (_) => SizedBox(
        width: 286,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 7),
                child: Text(
                  '选择重新扫描方式',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: cs.mutedForeground,
                  ),
                ),
              ),
              _option(
                icon: Icons.filter_alt_outlined,
                title: '仅扫描未识别',
                description: '不刷新目录，只识别媒体库中尚未匹配的资源',
                onPressed: widget.onScanUnrecognized,
              ),
              const SizedBox(height: 3),
              _option(
                icon: Icons.restart_alt_rounded,
                title: '强制全部重新识别',
                description: '刷新当前媒体库目录并重新识别全部资源',
                onPressed: widget.onForceAll,
              ),
            ],
          ),
        ),
      ),
      child: trigger,
    );
  }

  Widget _option({
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onPressed,
  }) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadButton.ghost(
      width: double.infinity,
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      mainAxisAlignment: MainAxisAlignment.start,
      leading: Icon(icon, size: 18, color: cs.primary),
      onPressed: () {
        _controller.hide();
        onPressed();
      },
      child: SizedBox(
        width: 218,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaLibraryPageState extends ConsumerState<MediaLibraryPage> {
  String get _tmdbApiKey =>
      StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
  bool _tmdbSearching = false;
  int _tmdbSearchSerial = 0;
  String? _tmdbError;
  List<Map<String, dynamic>> _tmdbResults = [];
  bool _backupBusy = false;
  bool _detailSyncing = false;
  String? _manualMatchPreparingResourceKey;
  String? _manualMatchApplyingResourceKey;
  Object? _manualMatchOperation;
  _MediaWork? _detailWork;
  var _detailSession = 0;
  late MediaLibraryBrowseFilter _wallFilter;
  late final MediaLibraryNotifier _mediaNotifier;
  void Function(MediaDetailHeader?) _setDetailHeader = (_) {};
  String? _activeCollectionKey;
  final _searchController = TextEditingController();

  bool get _manualMatchBusy => _manualMatchOperation != null;

  String? get _manualMatchLoadingResourceKey =>
      _manualMatchPreparingResourceKey ?? _manualMatchApplyingResourceKey;

  @override
  void initState() {
    super.initState();
    _wallFilter = widget.browseFilter;
    _mediaNotifier = ref.read(mediaLibraryProvider.notifier);
    final detailHeaderNotifier = ref.read(
      activeMediaDetailHeaderProvider.notifier,
    );
    _setDetailHeader = (value) => detailHeaderNotifier.state = value;
    final api = ref.read(authProvider.notifier).api;
    Future.microtask(() {
      if (!mounted) return;
      _mediaNotifier.api = api;
      _mediaNotifier.load();
    });
  }

  @override
  void didUpdateWidget(covariant MediaLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final browseFilterChanged = oldWidget.browseFilter != widget.browseFilter;
    final enteredHome = !oldWidget.showHomePanel && widget.showHomePanel;
    if (browseFilterChanged || enteredHome) {
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
        }
      });
    }
  }

  void _openDetail(_MediaWork work) {
    setState(() {
      _detailSession += 1;
      _detailWork = work;
    });
    _setDetailHeader(
      MediaDetailHeader(
        title: work.primary.title,
        mediaKind: work.primary.mediaKind,
        year: work.primary.year,
      ),
    );
  }

  void _closeDetail() {
    setState(() {
      _detailSession += 1;
      _detailWork = null;
    });
    _setDetailHeader(null);
  }

  Future<void> _removeMediaRecords(List<MediaLibraryItem> records) async {
    if (records.isEmpty) return;
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
    final works = _MediaWork.fromItems(
      useGlobalBrowse ? state.allItems : state.items,
    );
    final refreshed = works
        .where((work) => work.key == _detailWork!.key)
        .firstOrNull;
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

  @override
  void dispose() {
    // Provider writes are forbidden while Flutter is unmounting this State.
    // The workspace owns the header lifecycle; it clears the value when the
    // media pane is left.  Do not update Riverpod from dispose.
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(mediaLibraryProvider);
    ref.listen<MediaDetailHeader?>(activeMediaDetailHeaderProvider, (
      previous,
      next,
    ) {
      if (next == null && _detailWork != null) _closeDetail();
    });
    final compact = MediaQuery.sizeOf(context).width < 720;
    ref.listen<MediaLibraryState>(mediaLibraryProvider, (previous, next) {
      final message = next.errorMessage ?? next.statusMessage;
      final previousMessage = previous?.errorMessage ?? previous?.statusMessage;
      final isProgressMessage =
          next.errorMessage == null && message?.startsWith('正在') == true;
      if (message == null ||
          message.isEmpty ||
          message == previousMessage ||
          isProgressMessage) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ShadSonner.maybeOf(context)?.show(
          next.errorMessage == null
              ? ShadToast(
                  title: const Text('媒体库'),
                  description: Text(message),
                  showCloseIconOnlyWhenHovered: false,
                )
              : ShadToast.destructive(
                  title: const Text('媒体库操作失败'),
                  description: Text(message),
                  showCloseIconOnlyWhenHovered: false,
                ),
        );
      });
    });

    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 10 : 18,
        compact ? 10 : 14,
        compact ? 10 : 18,
        compact ? 10 : 18,
      ),
      child: Column(
        children: [
          if (!widget.showManagementToolbar && widget.showBrowseHeader) ...[
            _buildHeader(context, state, compact: compact),
            SizedBox(height: compact ? 8 : 12),
          ],
          if (widget.showManagementToolbar && _detailWork == null) ...[
            _buildToolbar(context, state),
            SizedBox(height: compact ? 8 : 12),
          ],
          Expanded(
            child:
                widget.showLibrarySidebar &&
                    !widget.showManagementToolbar &&
                    !compact
                ? Row(
                    children: [
                      _buildLibraryList(context, state),
                      VerticalDivider(
                        width: 24,
                        color: ShadTheme.of(context).colorScheme.border,
                      ),
                      Expanded(child: _buildMainPanel(context, state)),
                    ],
                  )
                : _buildMainPanel(context, state),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    MediaLibraryState state, {
    required bool compact,
  }) {
    final cs = ShadTheme.of(context).colorScheme;
    final useGlobalStatistics =
        widget.showHomePanel || _wallFilter != MediaLibraryBrowseFilter.all;
    final statistics = useGlobalStatistics
        ? state.globalStatistics
        : state.statistics;
    final library = state.selectedLibrary;
    final title = Row(
      children: [
        Icon(
          Icons.video_library_rounded,
          size: compact ? 22 : 26,
          color: cs.primary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                library?.name ?? '未选择媒体库',
                style: TextStyle(
                  fontSize: compact ? 18 : 21,
                  fontWeight: FontWeight.w700,
                  color: cs.foreground,
                ),
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
      leading: Icon(Icons.search_rounded, size: 16, color: cs.mutedForeground),
      onChanged: (value) =>
          ref.read(mediaLibraryProvider.notifier).setSearchQuery(value),
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [title, const SizedBox(height: 8), search],
      );
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
                  leading: Icon(
                    Icons.search_rounded,
                    size: 16,
                    color: cs.mutedForeground,
                  ),
                  onChanged: (value) => ref
                      .read(mediaLibraryProvider.notifier)
                      .setSearchQuery(value),
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
                if (detailWork == null && widget.showManagementToolbar) ...[
                  _managementActionStrip(context, state, compact: true),
                ],
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
            leading: Icon(
              Icons.search_rounded,
              size: 16,
              color: cs.mutedForeground,
            ),
            onChanged: (value) =>
                ref.read(mediaLibraryProvider.notifier).setSearchQuery(value),
            onSubmitted: _searchTMDB,
          ),
        ),
        const SizedBox(width: 8),
        if (detailWork == null && widget.showManagementToolbar) ...[
          _managementActionStrip(context, state, compact: false),
        ],
      ],
    );
  }

  Widget _managementActionStrip(
    BuildContext context,
    MediaLibraryState state, {
    required bool compact,
  }) {
    final cs = ShadTheme.of(context).colorScheme;
    final actions = <Widget>[
      ShadButton.ghost(
        size: ShadButtonSize.sm,
        onPressed: () => _showCreateLibraryDialog(context, ref),
        leading: const Icon(Icons.add_rounded, size: 16),
        child: const Text('新建媒体库'),
      ),
      ShadTooltip(
        builder: (_) => const Text('查看所有媒体库的刮削任务'),
        child: ShadButton.ghost(
          size: ShadButtonSize.sm,
          onPressed: () => MediaLibraryPage.showScanTaskDialog(context, ref),
          leading: const Icon(Icons.assignment_rounded, size: 16),
          child: Text(
            state.activeScanCount == 0 ? '刮削任务' : '任务 ${state.activeScanCount}',
          ),
        ),
      ),
      _backupActionsMenu(state, compact: true),
      state.isScanning
          ? ShadButton.destructive(
              size: ShadButtonSize.sm,
              onPressed: () =>
                  ref.read(mediaLibraryProvider.notifier).cancelScan(),
              leading: const Icon(Icons.stop_rounded, size: 16),
              child: const Text('停止扫描'),
            )
          : MediaScanMenu(
              compact: compact,
              disabled: state.selectedLibrary == null,
              onScanUnrecognized: () => ref
                  .read(mediaLibraryProvider.notifier)
                  .rescanSelectedLibrary(
                    mode: MediaLibraryScanMode.unrecognizedOnly,
                  ),
              onForceAll: () => ref
                  .read(mediaLibraryProvider.notifier)
                  .rescanSelectedLibrary(mode: MediaLibraryScanMode.forceAll),
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
    final cs = ShadTheme.of(context).colorScheme;
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '媒体库',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: cs.mutedForeground,
            ),
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
                        onTap: () => ref
                            .read(mediaLibraryProvider.notifier)
                            .selectLibrary(library.id),
                        onEdit: () =>
                            _showEditLibraryDialog(context, ref, library),
                        onDelete: () => ref
                            .read(mediaLibraryProvider.notifier)
                            .deleteLibrary(library.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _emptyLibraryHint(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.video_library_outlined,
            size: 42,
            color: cs.mutedForeground,
          ),
          const SizedBox(height: 12),
          Text(
            '暂无媒体库',
            style: TextStyle(fontSize: 14, color: cs.mutedForeground),
          ),
          const SizedBox(height: 10),
          ShadButton.outline(
            onPressed: () =>
                MediaLibraryPage.showManagementDialog(context, ref),
            child: const Text('打开媒体库管理'),
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
    final isCurrentLibraryView =
        !widget.showHomePanel && _wallFilter == MediaLibraryBrowseFilter.all;
    final activeFilter = isCurrentLibraryView
        ? widget.librarySection
        : _wallFilter;
    final useGlobalBrowse =
        widget.showHomePanel ||
        (!isCurrentLibraryView &&
            (_wallFilter == MediaLibraryBrowseFilter.movies ||
                _wallFilter == MediaLibraryBrowseFilter.series ||
                _wallFilter == MediaLibraryBrowseFilter.unmatched));
    final visibleItems = useGlobalBrowse
        ? state.globalVisibleItems
        : state.visibleItems;
    final collections = _MediaCollection.fromItems(visibleItems);
    final activeCollection = collections
        .where((collection) => collection.key == _activeCollectionKey)
        .firstOrNull;
    final filteredItems = switch (activeFilter) {
      MediaLibraryBrowseFilter.all => visibleItems,
      MediaLibraryBrowseFilter.movies =>
        visibleItems
            .where((item) => item.mediaKind == TMDBMediaKind.movie)
            .toList(),
      MediaLibraryBrowseFilter.series =>
        visibleItems
            .where((item) => item.mediaKind == TMDBMediaKind.tv)
            .toList(),
      MediaLibraryBrowseFilter.collections =>
        activeCollection?.resources ?? const [],
      MediaLibraryBrowseFilter.unmatched =>
        visibleItems.where((item) => !item.isMatched).toList(),
    };
    final works = _MediaWork.fromItems(filteredItems);
    if (state.selectedLibrary == null) {
      return _mainEmpty(context, '还没有媒体库', '从云盘根目录或当前目录创建一个媒体库');
    }
    if (_detailWork != null) {
      final detailResourceIDs = _detailWork!.resources
          .map((resource) => resource.id)
          .toSet();
      final current = works
          .where(
            (work) =>
                work.key == _detailWork!.key ||
                work.resources.any(
                  (resource) => detailResourceIDs.contains(resource.id),
                ),
          )
          .firstOrNull;
      final selectedWork = current ?? _detailWork!;
      return Stack(
        children: [
          _MediaDetailPanel(
            work: selectedWork,
            onDownload: (item) =>
                ref.read(fileProvider.notifier).downloadFile(item.file),
            onPlay: (item) => unawaited(
              showMediaPlayerDialog(
                context,
                item.file,
                episodeCandidates: selectedWork.resources
                    .map((resource) => resource.file)
                    .toList(),
              ),
            ),
            onExternalPlay: (item) => showShadDialog(
              context: context,
              builder: (_) => ExternalPlayerDialog(file: item.file),
            ),
            onRecognize: () =>
                unawaited(_refreshAndRecognizeDetail(selectedWork)),
            onManualMatch: (resource) =>
                unawaited(_showManualTMDBMatch(selectedWork, resource)),
            manualMatchBusy: _manualMatchBusy,
            manualMatchLoadingResourceKey: _manualMatchLoadingResourceKey,
            onRemoveRecords: _removeMediaRecords,
            removalDisabled:
                state.isScanning || _detailSyncing || _manualMatchBusy,
          ),
          if (_detailSyncing)
            _detailLoadingOverlay(
              context,
              message: '正在识别并匹配媒体信息',
              onCancel: _detailSyncing
                  ? () => ref
                        .read(mediaLibraryProvider.notifier)
                        .cancelDetailSync()
                  : null,
            ),
        ],
      );
    }
    final showingCollectionOverview =
        activeFilter == MediaLibraryBrowseFilter.collections &&
        activeCollection == null;
    final wallContent =
        widget.showHomePanel && activeFilter == MediaLibraryBrowseFilter.all
        ? _homePanel(context, state)
        : showingCollectionOverview
        ? _collectionOverview(context, collections)
        : works.isEmpty
        ? _mainEmpty(
            context,
            state.isScanning
                ? '正在扫描媒体库'
                : (activeFilter == MediaLibraryBrowseFilter.all
                      ? '没有扫描结果'
                      : '当前筛选没有结果'),
            state.isScanning ? '发现并入库的资源会立即显示在这里' : '点击扫描读取该媒体库下的视频文件',
          )
        : LayoutBuilder(
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
                itemCount: works.length,
                itemBuilder: (context, index) => _MediaPosterTile(
                  work: works[index],
                  onOpen: () => _openDetail(works[index]),
                  onDownload: () => ref
                      .read(fileProvider.notifier)
                      .downloadFile(works[index].primary.file),
                  onRecognize: state.isScanning
                      ? null
                      : () {
                          _openDetail(works[index]);
                          unawaited(_refreshAndRecognizeDetail(works[index]));
                        },
                  onManualMatch: () {
                    _openDetail(works[index]);
                    unawaited(
                      _showManualTMDBMatch(works[index], works[index].primary),
                    );
                  },
                ),
              );
            },
          );
    final content = activeCollection == null
        ? wallContent
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: () => setState(() => _activeCollectionKey = null),
                leading: const Icon(Icons.arrow_back_rounded, size: 16),
                child: Text('返回合集：${activeCollection.name}'),
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
        (
          library: library,
          works: _MediaWork.fromItems(
            visibleItems.where((item) => item.libraryID == library.id),
          ),
        ),
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
      if (entry.completed ||
          item == null ||
          work == null ||
          !seenWorks.add('${item.libraryID}:${work.key}')) {
        continue;
      }
      continuing.add(
        _ContinueWatchingWork(work: work, item: item, entry: entry),
      );
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
                  episodeCandidates: value.work.resources
                      .map((item) => item.file)
                      .toList(),
                ),
              ),
            );
          },
        ),
      ]);
    }
    for (final section in librarySections) {
      if (sections.isNotEmpty) {
        sections.add(SizedBox(height: compact ? 18 : 24));
      }
      sections.add(
        _homeLibrarySection(
          context,
          library: section.library,
          works: section.works,
          compact: compact,
          searchActive: state.searchQuery.trim().isNotEmpty,
        ),
      );
    }
    return ListView(
      primary: false,
      padding: const EdgeInsets.only(bottom: 24),
      children: sections,
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
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: cs.foreground,
              ),
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

  Widget _homeLibrarySection(
    BuildContext context, {
    required MediaLibraryDefinition library,
    required List<_MediaWork> works,
    required bool compact,
    required bool searchActive,
  }) {
    final visibleWorks = works.take(10).toList();
    final count = works.length > visibleWorks.length
        ? '前 ${visibleWorks.length} 个 · 共 ${works.length} 个作品'
        : '${works.length} 个作品';
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
                      style: TextStyle(
                        fontSize: 12,
                        color: ShadTheme.of(
                          context,
                        ).colorScheme.mutedForeground,
                      ),
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
            itemCount: visibleWorks.length,
            itemBuilder: (_, index) => SizedBox(
              width: compact ? 132 : 142,
              child: _MediaPosterTile(
                work: visibleWorks[index],
                onOpen: () => _openDetail(visibleWorks[index]),
                onDownload: () => ref
                    .read(fileProvider.notifier)
                    .downloadFile(visibleWorks[index].primary.file),
                onRecognize: () {
                  _openDetail(visibleWorks[index]);
                  unawaited(_refreshAndRecognizeDetail(visibleWorks[index]));
                },
                onManualMatch: () {
                  _openDetail(visibleWorks[index]);
                  unawaited(
                    _showManualTMDBMatch(
                      visibleWorks[index],
                      visibleWorks[index].primary,
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _collectionOverview(
    BuildContext context,
    List<_MediaCollection> collections,
  ) {
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
                const AppLoadingIndicator(
                  size: AppLoadingSize.compact,
                  semanticsLabel: '正在扫描媒体库',
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.progress.phase,
                        style: TextStyle(color: cs.foreground),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '已发现 ${state.progress.completed} 个视频文件，已入库资源会实时显示。',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _mainEmpty(BuildContext context, String title, String subtitle) {
    final cs = ShadTheme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.movie_creation_outlined,
            size: 56,
            color: cs.mutedForeground,
          ),
          const SizedBox(height: 14),
          Text(title, style: TextStyle(fontSize: 16, color: cs.foreground)),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: cs.mutedForeground),
          ),
        ],
      ),
    );
  }

  Widget _tmdbResultPanel(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    if (_tmdbSearching) {
      return const Center(
        child: AppLoadingIndicator(
          size: AppLoadingSize.page,
          label: '正在搜索 TMDB',
        ),
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
      separatorBuilder: (context, index) =>
          Divider(color: cs.border, height: 1),
      itemBuilder: (context, index) =>
          _buildTMDBResultItem(context, _tmdbResults[index]),
    );
  }

  Widget _buildTMDBResultItem(BuildContext context, Map<String, dynamic> item) {
    final cs = ShadTheme.of(context).colorScheme;
    final title = item['title'] ?? item['name'] ?? '未知';
    final overview = item['overview']?.toString() ?? '';
    final releaseDate =
        item['release_date']?.toString() ??
        item['first_air_date']?.toString() ??
        '';
    final mediaType = item['media_type']?.toString() ?? 'movie';
    final posterPath = item['poster_path'] as String?;
    final year = releaseDate.length >= 4 ? releaseDate.substring(0, 4) : '';

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
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: cs.foreground,
                        ),
                      ),
                    ),
                    ShadBadge(child: Text(mediaType == 'tv' ? '剧集' : '电影')),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  overview.isEmpty ? '暂无简介' : overview,
                  style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
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
        initialRootID: fileState.folderPath.isEmpty
            ? null
            : fileState.folderPath.last.id,
        initialPath: currentPath,
        initialName: fileState.folderPath.isEmpty
            ? '我的影视库'
            : fileState.folderPath.last.name,
      ),
    );
  }

  static void _showEditLibraryDialog(
    BuildContext context,
    WidgetRef ref,
    MediaLibraryDefinition library,
  ) {
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

  Future<void> _exportScrapedData() async {
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择刮削数据导出目录',
    );
    if (directory == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await ref
          .read(mediaLibraryProvider.notifier)
          .exportScrapedData('$directory/media-library.sqlite3');
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
      onSyncToCloud: _syncScrapedDataToCloud,
      onRestoreFromCloud: _syncScrapedDataFromCloud,
    );
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
        ShadSonner.maybeOf(context)?.show(
          const ShadToast(
            title: Text('云盘恢复'),
            description: Text('云盘中没有找到 media-library.sqlite3 备份。'),
          ),
        );
      }
      return;
    }
    final selected = await showShadDialog<CloudFile>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: const Text('从云盘恢复刮削数据'),
        description: const Text('选择一个 SQLite 备份，恢复会合并到当前本地媒体库。'),
        scrollable: false,
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
        child: SizedBox(
          width: (MediaQuery.sizeOf(dialogContext).width - 32)
              .clamp(300.0, 520.0)
              .toDouble(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < backups.length; index++) ...[
                _cloudBackupRestoreRow(dialogContext, backup: backups[index]),
                if (index < backups.length - 1)
                  const ShadSeparator.horizontal(),
              ],
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await notifier.importScrapedDataFromCloud(selected);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Widget _cloudBackupRestoreRow(
    BuildContext context, {
    required CloudFile backup,
  }) {
    final cs = ShadTheme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        decoration: BoxDecoration(
          color: cs.muted.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: cs.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShadButton.ghost(
              width: constraints.maxWidth,
              expands: false,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              leading: Icon(
                Icons.storage_rounded,
                size: 18,
                color: cs.mutedForeground,
              ),
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: cs.mutedForeground,
              ),
              onPressed: () => Navigator.of(context).pop(backup),
              child: Text(
                backup.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.foreground,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(38, 0, 10, 9),
              child: Text(
                '${backup.formattedSize} · ${backup.modifiedAt}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.mutedForeground),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _searchTMDB(String query) async {
    final text = query.trim();
    if (text.isEmpty || _tmdbApiKey.isEmpty) return;
    final serial = ++_tmdbSearchSerial;

    setState(() {
      _tmdbSearching = true;
      _tmdbError = null;
      _tmdbResults = [];
    });

    try {
      final api = ref.read(authProvider.notifier).api;
      final result = await api.tmdbSearch(
        text,
        apiKey: _tmdbApiKey,
        proxyHost: StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
        proxyPort: StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
      );
      final results =
          (result['results'] as List?)
              ?.whereType<Map>()
              .where(
                (item) =>
                    item['media_type'] == 'movie' || item['media_type'] == 'tv',
              )
              .map((item) => Map<String, dynamic>.from(item))
              .toList() ??
          [];
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
    if (_detailSyncing) return;
    final detailSession = _detailSession;
    setState(() => _detailSyncing = true);
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
          directoryName: _parentDirectoryName(
            request.items.first.file.cloudPath,
          ),
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
            await notifier.applyTMDBMatch(
              request.items[index],
              candidate,
              applyManualEpisodeOverride: index == 0,
            );
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
      final refreshed =
          _MediaWork.fromItems(ref.read(mediaLibraryProvider).items)
              .where(
                (work) => work.resources.any(
                  (item) =>
                      selectedIDs.contains(item.id) ||
                      (item.file.gcid != null &&
                          selectedGCIDs.contains(item.file.gcid)) ||
                      selectedParentPaths.contains(
                        _parentCloudPath(item.file.cloudPath),
                      ),
                ),
              )
              .firstOrNull;
      if (refreshed != null) {
        setState(() => _detailWork = refreshed);
      } else if (mounted) {
        _closeDetail();
      }
    } finally {
      if (mounted) setState(() => _detailSyncing = false);
    }
  }

  List<MediaLibraryItem> _recognitionResources(_MediaWork selected) {
    final first = selected.primary;
    final parsed = ParsedMediaName.parse(
      first.file.name,
      directoryName: _parentDirectoryName(first.file.cloudPath),
    );
    if (!parsed.isEpisode) return selected.resources;
    final parentPath = _parentCloudPath(first.file.cloudPath);
    final title = parsed.title.toLowerCase();
    final siblings = ref.read(mediaLibraryProvider).items.where((item) {
      if (_parentCloudPath(item.file.cloudPath) != parentPath) return false;
      final candidate = ParsedMediaName.parse(
        item.file.name,
        directoryName: _parentDirectoryName(item.file.cloudPath),
      );
      return candidate.isEpisode && candidate.title.toLowerCase() == title;
    });
    return {
      for (final item in [...selected.resources, ...siblings]) item.id: item,
    }.values.toList();
  }

  Widget _detailLoadingOverlay(
    BuildContext context, {
    required String message,
    VoidCallback? onCancel,
  }) {
    final cs = ShadTheme.of(context).colorScheme;
    return Positioned.fill(
      child: ColoredBox(
        color: cs.background.withValues(alpha: 0.86),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppLoadingIndicator(size: AppLoadingSize.regular, label: message),
              if (onCancel != null) ...[
                const SizedBox(height: 14),
                ShadButton.destructive(
                  size: ShadButtonSize.sm,
                  onPressed: onCancel,
                  leading: const Icon(Icons.stop_rounded, size: 16),
                  child: const Text('取消'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showManualTMDBMatch(
    _MediaWork work,
    MediaLibraryItem target,
  ) async {
    if (_manualMatchBusy) return;
    final targetKey = _mediaRecordKey(target);
    final operation = Object();
    final detailSession = _detailSession;
    final notifier = ref.read(mediaLibraryProvider.notifier);
    setState(() {
      _manualMatchOperation = operation;
      _manualMatchPreparingResourceKey = targetKey;
    });
    try {
      // Manual matching only needs the selected resource's current filename
      // to initialize the search. Refreshing every resource in a large
      // series here blocks the dialog behind storage writes and a full reload.
      final resources = work.resources;
      if (!mounted ||
          _detailSession != detailSession ||
          _detailWork == null ||
          resources.isEmpty) {
        return;
      }
      setState(() => _manualMatchPreparingResourceKey = null);
      final queryResource =
          resources
              .where(
                (resource) =>
                    resource.libraryID == target.libraryID &&
                    (resource.id == target.id ||
                        (target.file.gcid?.isNotEmpty == true &&
                            resource.file.gcid == target.file.gcid)),
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
      if (candidate == null ||
          !mounted ||
          _detailSession != detailSession ||
          _detailWork == null) {
        return;
      }
      setState(() => _manualMatchApplyingResourceKey = targetKey);
      if (candidate['media_type'] == 'tv') {
        await notifier.applyTMDBMatch(queryResource, candidate);
      } else {
        final orderedResources = [
          queryResource,
          ...resources.where(
            (resource) =>
                _mediaRecordKey(resource) != _mediaRecordKey(queryResource),
          ),
        ];
        for (var index = 0; index < orderedResources.length; index++) {
          await notifier.applyTMDBMatch(
            orderedResources[index],
            candidate,
            applyManualEpisodeOverride: index == 0,
          );
        }
      }
      if (!mounted || _detailSession != detailSession || _detailWork == null) {
        return;
      }
      final resourceIDs = resources.map((item) => item.id).toSet();
      final refreshed =
          _MediaWork.fromItems(ref.read(mediaLibraryProvider).items)
              .where(
                (candidate) => candidate.resources.any(
                  (item) => resourceIDs.contains(item.id),
                ),
              )
              .firstOrNull;
      if (refreshed != null) setState(() => _detailWork = refreshed);
    } finally {
      if (mounted && identical(_manualMatchOperation, operation)) {
        setState(() {
          _manualMatchOperation = null;
          _manualMatchPreparingResourceKey = null;
          _manualMatchApplyingResourceKey = null;
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
      controller.dispose();
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
            Offset((size.width * 0.5).clamp(280.0, size.width - 280.0), 96),
          ),
          popover: (_) => SizedBox(
            width: (size.width - 32).clamp(360.0, 820.0).toDouble(),
            height: (size.height - 140).clamp(420.0, 680.0).toDouble(),
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
  ConsumerState<_MediaLibraryManagementDialog> createState() =>
      _MediaLibraryManagementDialogState();
}

class _MediaLibraryScanTaskDialog extends ConsumerStatefulWidget {
  const _MediaLibraryScanTaskDialog();

  @override
  ConsumerState<_MediaLibraryScanTaskDialog> createState() =>
      _MediaLibraryScanTaskDialogState();
}

class _MediaLibraryScanTaskDialogState
    extends ConsumerState<_MediaLibraryScanTaskDialog> {
  final _expandedTaskIDs = <String>{};
  bool _copiedLogs = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(mediaLibraryProvider);
    final cs = ShadTheme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 32).clamp(340.0, 920.0).toDouble();
    final height = (size.height - 140).clamp(420.0, 700.0).toDouble();
    final tasks = state.scanTasks;
    return ShadDialog(
      title: const Text('刮削任务管理'),
      description: const Text('查看所有媒体库的扫描、识别、入库任务，并管理任务状态。'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  state.hasActiveScans
                      ? Icons.sync_rounded
                      : Icons.check_circle_outline_rounded,
                  size: 18,
                  color: state.hasActiveScans ? cs.primary : cs.mutedForeground,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.activeScanCount == 0
                        ? '当前没有进行中的刮削任务'
                        : '${state.activeScanCount} 个任务进行中',
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
                      onPressed: () => ref
                          .read(mediaLibraryProvider.notifier)
                          .clearFinishedScanTasks(),
                      child: const Icon(
                        Icons.cleaning_services_rounded,
                        size: 16,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: tasks.isEmpty
                  ? _emptyState(context)
                  : ListView.separated(
                      itemCount: tasks.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final task = tasks[index];
                        return _taskRow(context, task);
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
          Text(
            '从任意媒体库标题栏开始扫描后会出现在这里。',
            style: TextStyle(fontSize: 12, color: cs.mutedForeground),
          ),
        ],
      ),
    );
  }

  Widget _taskRow(BuildContext context, MediaLibraryScanTask task) {
    final cs = ShadTheme.of(context).colorScheme;
    final expanded = _expandedTaskIDs.contains(task.id);
    final tint = _taskStatusColor(context, task.status);
    final total = task.progress.total <= 0 ? null : task.progress.total;
    final fraction = total == null || total == 0
        ? null
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
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.mutedForeground,
                          ),
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: _statusPill(context, task.status),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: fraction,
                        minHeight: 6,
                        color: tint,
                        backgroundColor: cs.border.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 68,
                    child: Text(
                      total == null
                          ? '${task.progress.completed}'
                          : '${task.progress.completed}/$total',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.mutedForeground,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
              if (expanded) ...[
                const SizedBox(height: 12),
                if (task.failureReason?.isNotEmpty == true) ...[
                  Text(
                    task.failureReason!,
                    style: TextStyle(fontSize: 12, color: cs.destructive),
                  ),
                  const SizedBox(height: 8),
                ],
                _taskLogs(context, task),
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
          color:
              status == MediaLibraryScanTaskStatus.cancelled ||
                  status == MediaLibraryScanTaskStatus.stopped
              ? cs.mutedForeground
              : tint,
        ),
      ),
    );
  }

  Widget _taskActions(
    BuildContext context,
    MediaLibraryScanTask task,
    bool expanded,
  ) {
    final notifier = ref.read(mediaLibraryProvider.notifier);
    final actions = <Widget>[];
    if (task.status.canPause) {
      actions.add(
        _taskIconButton(
          tooltip: '暂停',
          icon: Icons.pause_rounded,
          onPressed: () => notifier.pauseScanTask(task.id),
        ),
      );
    }
    if (task.status.canResume) {
      actions.add(
        _taskIconButton(
          tooltip: task.status == MediaLibraryScanTaskStatus.failed
              ? '重试'
              : '继续',
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
        icon: expanded
            ? Icons.keyboard_arrow_up_rounded
            : Icons.keyboard_arrow_down_rounded,
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

  Widget _taskLogs(BuildContext context, MediaLibraryScanTask task) {
    final cs = ShadTheme.of(context).colorScheme;
    final logs = task.logs.reversed.toList(growable: false);
    return Container(
      height: 190,
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
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: cs.mutedForeground,
                ),
              ),
              const Spacer(),
              _taskIconButton(
                tooltip: _copiedLogs ? '已复制' : '复制日志',
                icon: _copiedLogs
                    ? Icons.check_rounded
                    : Icons.copy_all_rounded,
                onPressed: logs.isEmpty
                    ? null
                    : () {
                        final text = task.logs
                            .map(
                              (entry) =>
                                  '${_formatLogTime(entry.createdAt)} ${entry.message}',
                            )
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
                    child: Text(
                      '暂无日志',
                      style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                    ),
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
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                entry.message,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: entry.isError
                                      ? cs.destructive
                                      : cs.foreground,
                                ),
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

  Color _taskStatusColor(
    BuildContext context,
    MediaLibraryScanTaskStatus status,
  ) {
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

class _MediaLibraryManagementDialogState
    extends ConsumerState<_MediaLibraryManagementDialog> {
  bool _backupBusy = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(mediaLibraryProvider);
    final cs = ShadTheme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 32).clamp(320.0, 760.0).toDouble();
    final height = (size.height - 160).clamp(360.0, 620.0).toDouble();
    return ShadDialog(
      title: const Text('媒体库管理'),
      description: const Text('集中管理媒体库、目录来源和刮削数据备份。'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            Row(
              children: [
                ShadButton(
                  size: ShadButtonSize.sm,
                  onPressed: () =>
                      _MediaLibraryPageState._showCreateLibraryDialog(
                        context,
                        ref,
                      ),
                  leading: const Icon(Icons.add_rounded, size: 16),
                  child: const Text('新建媒体库'),
                ),
                const SizedBox(width: 8),
                _BackupActionsMenu(
                  compact: true,
                  disabled: _backupBusy || state.hasActiveScans,
                  progress: state.cloudBackupSync,
                  onExport: _exportScrapedData,
                  onImport: _importScrapedData,
                  onSyncToCloud: _syncScrapedDataToCloud,
                  onRestoreFromCloud: _syncScrapedDataFromCloud,
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: state.hasActiveScans
                        ? Text(
                            '${state.activeScanCount} 个刮削任务进行中，备份恢复暂不可用',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.mutedForeground,
                            ),
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
                        final statistics = MediaLibraryStatistics.fromItems(
                          state.allItems.where(
                            (item) => item.libraryID == library.id,
                          ),
                        );
                        final scanning = state.isLibraryScanning(library.id);
                        return _ManagementLibraryRow(
                          library: library,
                          statistics: statistics,
                          selected: library.id == state.selectedLibraryID,
                          disabled: scanning,
                          onSelect: () => ref
                              .read(mediaLibraryProvider.notifier)
                              .selectLibrary(library.id),
                          onEdit: () =>
                              _MediaLibraryPageState._showEditLibraryDialog(
                                context,
                                ref,
                                library,
                              ),
                          onDelete: () => _deleteLibrary(library),
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
          Icon(
            Icons.video_library_outlined,
            size: 44,
            color: cs.mutedForeground,
          ),
          const SizedBox(height: 12),
          Text('暂无媒体库', style: TextStyle(color: cs.foreground)),
          const SizedBox(height: 6),
          Text(
            '点击上方按钮创建第一个媒体库',
            style: TextStyle(fontSize: 12, color: cs.mutedForeground),
          ),
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
    await ref.read(mediaLibraryProvider.notifier).deleteLibrary(library.id);
  }

  Future<void> _exportScrapedData() async {
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择刮削数据导出目录',
    );
    if (directory == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await ref
          .read(mediaLibraryProvider.notifier)
          .exportScrapedData('$directory/media-library.sqlite3');
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
        ShadSonner.maybeOf(context)?.show(
          const ShadToast(
            title: Text('云盘恢复'),
            description: Text('云盘中没有找到 media-library.sqlite3 备份。'),
          ),
        );
      }
      return;
    }
    final selected = await showShadDialog<CloudFile>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: const Text('从云盘恢复刮削数据'),
        description: const Text('选择一个 SQLite 备份，恢复会合并到当前本地媒体库。'),
        scrollable: false,
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
        child: SizedBox(
          width: (MediaQuery.sizeOf(dialogContext).width - 32)
              .clamp(300.0, 520.0)
              .toDouble(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < backups.length; index++) ...[
                _CloudBackupRestoreRow(backup: backups[index]),
                if (index < backups.length - 1)
                  const ShadSeparator.horizontal(),
              ],
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      await notifier.importScrapedDataFromCloud(selected);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }
}

class _ManagementLibraryRow extends StatelessWidget {
  final MediaLibraryDefinition library;
  final MediaLibraryStatistics statistics;
  final bool selected;
  final bool disabled;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ManagementLibraryRow({
    required this.library,
    required this.statistics,
    required this.selected,
    required this.disabled,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: selected
            ? cs.primary.withValues(alpha: 0.08)
            : cs.muted.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: selected ? cs.primary : cs.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            Icon(
              library.kind == MediaLibraryKind.series
                  ? Icons.live_tv_rounded
                  : Icons.smart_display_rounded,
              size: 22,
              color: selected ? cs.primary : cs.mutedForeground,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          library.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: cs.foreground,
                          ),
                        ),
                      ),
                      if (selected) ShadBadge.outline(child: const Text('当前')),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _libraryStatisticsLabel(statistics),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${library.rootPath} · ${library.sources.length} 个目录 · '
                    '${library.recursive ? '递归' : '仅当前目录'} · 最小 ${library.minimumSizeMB} MB',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ShadTooltip(
              builder: (_) => const Text('打开媒体库'),
              child: ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: selected ? null : onSelect,
                child: const Icon(Icons.open_in_new_rounded, size: 16),
              ),
            ),
            ShadTooltip(
              builder: (_) => const Text('编辑媒体库'),
              child: ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: disabled ? null : onEdit,
                child: const Icon(Icons.edit_outlined, size: 16),
              ),
            ),
            ShadTooltip(
              builder: (_) => const Text('删除媒体库'),
              child: ShadButton.destructive(
                size: ShadButtonSize.sm,
                onPressed: disabled ? null : onDelete,
                child: const Icon(Icons.delete_outline_rounded, size: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloudBackupRestoreRow extends StatelessWidget {
  final CloudFile backup;

  const _CloudBackupRestoreRow({required this.backup});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        decoration: BoxDecoration(
          color: cs.muted.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: cs.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShadButton.ghost(
              width: constraints.maxWidth,
              expands: false,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              leading: Icon(
                Icons.storage_rounded,
                size: 18,
                color: cs.mutedForeground,
              ),
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: cs.mutedForeground,
              ),
              onPressed: () => Navigator.of(context).pop(backup),
              child: Text(
                backup.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.foreground,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(38, 0, 10, 9),
              child: Text(
                '${backup.formattedSize} · ${backup.modifiedAt}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.mutedForeground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _libraryStatisticsLabel(MediaLibraryStatistics statistics) {
  final parts = <String>[
    if (statistics.movies > 0) '${statistics.movies} 部电影',
    if (statistics.series > 0) '${statistics.series} 部剧集',
    if (statistics.unmatched > 0) '${statistics.unmatched} 个未识别资源',
    if (statistics.total > 0) '${statistics.total} 个影视条目',
  ];
  return parts.isEmpty ? '暂无影视条目' : parts.join(' · ');
}

class _CreateMediaLibraryDialog extends ConsumerStatefulWidget {
  final String? initialRootID;
  final String initialPath;
  final String initialName;
  final MediaLibraryDefinition? editingLibrary;

  const _CreateMediaLibraryDialog({
    required this.initialRootID,
    required this.initialPath,
    required this.initialName,
    this.editingLibrary,
  });

  @override
  ConsumerState<_CreateMediaLibraryDialog> createState() =>
      _CreateMediaLibraryDialogState();
}

class _CreateMediaLibraryDialogState
    extends ConsumerState<_CreateMediaLibraryDialog> {
  late final TextEditingController _nameController;
  final _minSizeController = TextEditingController(text: '50');
  MediaLibraryKind _kind = MediaLibraryKind.mixed;
  bool _recursive = true;
  bool _isBrowsing = false;
  bool _isLoadingFolders = false;
  String? _folderError;
  late List<MediaLibrarySource> _sources;
  final _browserPath = <CloudFile>[];
  var _folders = <CloudFile>[];

  bool get _isEditing => widget.editingLibrary != null;

  @override
  void initState() {
    super.initState();
    _sources =
        widget.editingLibrary?.sources ??
        [
          MediaLibrarySource(
            id: 'initial-source',
            rootID: widget.initialRootID,
            path: widget.initialPath,
          ),
        ];
    _nameController = TextEditingController(text: widget.initialName);
    if (_isEditing) {
      _kind = widget.editingLibrary!.kind;
      _recursive = widget.editingLibrary!.recursive;
      _minSizeController.text = widget.editingLibrary!.minimumSizeMB.toString();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _minSizeController.dispose();
    super.dispose();
  }

  String get _browserLocation => _browserPath.isEmpty
      ? '云盘根目录'
      : _browserPath.map((folder) => folder.name).join(' / ');

  String? get _browserFolderID =>
      _browserPath.isEmpty ? null : _browserPath.last.id;

  Future<void> _startBrowsing() async {
    setState(() {
      _isBrowsing = true;
      _browserPath.clear();
      _folders = [];
    });
    await _loadFolders();
  }

  Future<void> _loadFolders() async {
    setState(() {
      _isLoadingFolders = true;
      _folderError = null;
    });
    try {
      final response = await ref
          .read(authProvider.notifier)
          .api
          .fsFiles(parentID: _browserFolderID, pageSize: 1000);
      if (mounted) {
        setState(() {
          _folders =
              _extractFiles(response).where((file) => file.isDirectory).toList()
                ..sort(
                  (a, b) =>
                      a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                );
        });
      }
    } catch (error) {
      if (mounted) setState(() => _folderError = error.toString());
    } finally {
      if (mounted) setState(() => _isLoadingFolders = false);
    }
  }

  List<CloudFile> _extractFiles(Map<String, dynamic> value) {
    final files = <CloudFile>[];
    final ids = <String>{};
    void visit(dynamic node) {
      if (node is Map) {
        try {
          final file = CloudFile.fromJson(Map<String, dynamic>.from(node));
          if (ids.add(file.id)) files.add(file);
        } catch (_) {}
        for (final child in node.values) {
          visit(child);
        }
      } else if (node is List) {
        for (final child in node) {
          visit(child);
        }
      }
    }

    visit(value);
    return files;
  }

  void _useBrowserFolder() {
    final rootID = _browserFolderID;
    final rootPath = _browserLocation;
    setState(() {
      if (rootID == null) {
        _sources = [
          MediaLibrarySource(id: 'root-source', rootID: null, path: rootPath),
        ];
      } else if (!_sources.any((source) => source.rootID == rootID)) {
        _sources = [
          ..._sources.where((source) => source.rootID != null),
          MediaLibrarySource(
            id: 'source-${DateTime.now().microsecondsSinceEpoch}',
            rootID: rootID,
            path: rootPath,
          ),
        ];
      }
      if (_nameController.text.trim().isEmpty ||
          _nameController.text == widget.initialName) {
        _nameController.text = _browserPath.isEmpty
            ? '我的影视库'
            : _browserPath.last.name;
      }
      _isBrowsing = false;
    });
  }

  Future<void> _save(BuildContext context) async {
    final notifier = ref.read(mediaLibraryProvider.notifier);
    if (_isEditing) {
      await notifier.updateLibrary(
        widget.editingLibrary!.copyWith(
          name: _nameController.text,
          sources: _sources,
          kind: _kind,
          recursive: _recursive,
          minimumSizeMB: int.tryParse(_minSizeController.text.trim()) ?? 50,
          updatedAt: DateTime.now(),
        ),
      );
    } else {
      await notifier.createLibrary(
        name: _nameController.text,
        rootID: _sources.isEmpty ? null : _sources.first.rootID,
        rootPath: _sources.isEmpty ? '未配置目录' : _sources.first.path,
        sources: _sources,
        kind: _kind,
        recursive: _recursive,
        minimumSizeMB: int.tryParse(_minSizeController.text.trim()) ?? 50,
      );
    }
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadDialog(
      title: Text(_isBrowsing ? '选择云盘文件夹' : (_isEditing ? '管理媒体库' : '创建媒体库')),
      description: Text(
        _isBrowsing ? '进入目标目录后，选择该目录作为媒体库来源。' : '媒体库会从指定目录扫描视频文件。',
      ),
      actions: _isBrowsing
          ? [
              ShadButton.outline(
                onPressed: () => setState(() => _isBrowsing = false),
                child: const Text('返回设置'),
              ),
              ShadButton(
                onPressed: _useBrowserFolder,
                leading: const Icon(Icons.check_rounded, size: 16),
                child: const Text('使用此目录'),
              ),
            ]
          : [
              ShadButton.outline(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              ShadButton(
                onPressed: _sources.isEmpty ? null : () => _save(context),
                leading: const Icon(Icons.add_rounded, size: 16),
                child: Text(_isEditing ? '保存并扫描' : '创建媒体库'),
              ),
            ],
      child: _isBrowsing ? _folderBrowser(cs) : _form(cs),
    );
  }

  Widget _form(ShadColorScheme cs) {
    final width = (MediaQuery.sizeOf(context).width - 32)
        .clamp(280.0, 520.0)
        .toDouble();
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
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
                    Icon(Icons.folder_rounded, color: cs.primary, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '媒体来源 (${_sources.length})',
                      style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                    ),
                    const Spacer(),
                    ShadButton.outline(
                      size: ShadButtonSize.sm,
                      onPressed: _startBrowsing,
                      leading: const Icon(Icons.add_rounded, size: 15),
                      child: const Text('添加目录'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_sources.isEmpty)
                  Text(
                    '请至少添加一个云盘目录',
                    style: TextStyle(fontSize: 12, color: cs.destructive),
                  )
                else
                  for (final source in _sources)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Row(
                        children: [
                          Icon(
                            Icons.folder_outlined,
                            size: 16,
                            color: cs.mutedForeground,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              source.path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: cs.foreground,
                              ),
                            ),
                          ),
                          ShadButton.ghost(
                            size: ShadButtonSize.sm,
                            onPressed: () => setState(
                              () => _sources.removeWhere(
                                (candidate) => candidate.id == source.id,
                              ),
                            ),
                            child: Icon(
                              Icons.remove_circle_outline_rounded,
                              size: 16,
                              color: cs.destructive,
                            ),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          ShadInput(
            controller: _nameController,
            placeholder: const Text('媒体库名称'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ShadSelect<MediaLibraryKind>(
                  initialValue: _kind,
                  placeholder: const Text('媒体类型'),
                  selectedOptionBuilder: (context, value) => Text(value.title),
                  options: [
                    for (final value in MediaLibraryKind.values)
                      ShadOption(value: value, child: Text(value.title)),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _kind = value);
                  },
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 132,
                child: ShadInput(
                  controller: _minSizeController,
                  keyboardType: TextInputType.number,
                  placeholder: const Text('最小 MB'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: ShadCheckbox(
              value: _recursive,
              label: const Text('递归扫描所有子目录'),
              sublabel: const Text('关闭后仅扫描当前目录中的视频文件'),
              onChanged: (value) => setState(() => _recursive = value),
            ),
          ),
        ],
      ),
    );
  }

  Widget _folderBrowser(ShadColorScheme cs) {
    final size = MediaQuery.sizeOf(context);
    return SizedBox(
      width: (size.width - 32).clamp(280.0, 560.0).toDouble(),
      height: (size.height - 250).clamp(280.0, 390.0).toDouble(),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: cs.muted,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                ShadTooltip(
                  builder: (_) => const Text('返回上级目录'),
                  child: ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: _browserPath.isEmpty
                        ? null
                        : () {
                            setState(() => _browserPath.removeLast());
                            _loadFolders();
                          },
                    child: const Icon(Icons.arrow_back_rounded, size: 16),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.folder_rounded, size: 16, color: cs.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _browserLocation,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.foreground),
                  ),
                ),
                ShadTooltip(
                  builder: (_) => const Text('刷新目录'),
                  child: ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: _isLoadingFolders ? null : _loadFolders,
                    child: const Icon(Icons.refresh_rounded, size: 16),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _isLoadingFolders
                ? const Center(
                    child: AppLoadingIndicator(
                      size: AppLoadingSize.page,
                      label: '正在读取云盘目录',
                    ),
                  )
                : _folderError != null
                ? Center(
                    child: Text(
                      _folderError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.destructive),
                    ),
                  )
                : _folders.isEmpty
                ? Center(
                    child: Text(
                      '此目录没有子文件夹',
                      style: TextStyle(color: cs.mutedForeground),
                    ),
                  )
                : ListView.separated(
                    itemCount: _folders.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: cs.border),
                    itemBuilder: (context, index) {
                      final folder = _folders[index];
                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            setState(() => _browserPath.add(folder));
                            _loadFolders();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 11,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.folder_rounded,
                                  size: 19,
                                  color: cs.primary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    folder.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
                                  color: cs.mutedForeground,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
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
        color: selected
            ? cs.primary.withValues(alpha: 0.08)
            : Colors.transparent,
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
                Icon(
                  Icons.video_library_rounded,
                  size: 20,
                  color: selected ? cs.primary : cs.mutedForeground,
                ),
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
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: cs.foreground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${library.kind.title} · ${library.rootPath}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.mutedForeground,
                        ),
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

class _MediaWork {
  final String key;
  final MediaLibraryItem primary;
  final List<MediaLibraryItem> resources;

  const _MediaWork({
    required this.key,
    required this.primary,
    required this.resources,
  });

  static List<_MediaWork> fromItems(Iterable<MediaLibraryItem> items) {
    final grouped = <String, List<MediaLibraryItem>>{};
    for (final item in items) {
      final title = item.title.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9\u4e00-\u9fff]'),
        '',
      );
      final kind = item.mediaKind?.name ?? 'unknown';
      final key = item.tmdbID == null
          ? '$kind:$title:${item.year}'
          : '$kind:tmdb:${item.tmdbID}';
      grouped.putIfAbsent(key, () => []).add(item);
    }
    return grouped.entries.map((entry) {
      final resources = entry.value
        ..sort(
          (a, b) =>
              a.file.name.toLowerCase().compareTo(b.file.name.toLowerCase()),
        );
      final primary = resources.reduce((best, candidate) {
        final bestScore =
            (best.hasChineseAudio ? 2 : 0) +
            (best.hasChineseSubtitle ? 1 : 0) +
            (best.posterPath?.isNotEmpty == true ? 1 : 0);
        final candidateScore =
            (candidate.hasChineseAudio ? 2 : 0) +
            (candidate.hasChineseSubtitle ? 1 : 0) +
            (candidate.posterPath?.isNotEmpty == true ? 1 : 0);
        return candidateScore > bestScore ? candidate : best;
      });
      return _MediaWork(key: entry.key, primary: primary, resources: resources);
    }).toList()..sort(
      (a, b) => a.primary.title.toLowerCase().compareTo(
        b.primary.title.toLowerCase(),
      ),
    );
  }
}

class _MediaCollection {
  final String key;
  final String name;
  final MediaLibraryItem primary;
  final List<MediaLibraryItem> resources;
  final int workCount;

  const _MediaCollection({
    required this.key,
    required this.name,
    required this.primary,
    required this.resources,
    required this.workCount,
  });

  static List<_MediaCollection> fromItems(Iterable<MediaLibraryItem> items) {
    final grouped = <String, List<MediaLibraryItem>>{};
    final names = <String, String>{};
    for (final item in items) {
      final name = item.collectionName?.trim();
      if (name == null || name.isEmpty) continue;
      final key = item.collectionID == null
          ? 'name:${name.toLowerCase()}'
          : 'tmdb:${item.collectionID}';
      grouped.putIfAbsent(key, () => []).add(item);
      names[key] = name;
    }
    return grouped.entries
        .map((entry) {
          final resources = entry.value;
          final works = _MediaWork.fromItems(resources);
          final primary = works.map((work) => work.primary).reduce((
            best,
            candidate,
          ) {
            final bestScore =
                (best.posterPath?.isNotEmpty == true ? 1 : 0) +
                (best.hasChineseAudio ? 1 : 0);
            final candidateScore =
                (candidate.posterPath?.isNotEmpty == true ? 1 : 0) +
                (candidate.hasChineseAudio ? 1 : 0);
            return candidateScore > bestScore ? candidate : best;
          });
          return _MediaCollection(
            key: entry.key,
            name: names[entry.key] ?? '未命名合集',
            primary: primary,
            resources: resources,
            workCount: works.length,
          );
        })
        .where((collection) => collection.workCount >= 2)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }
}

class _MediaCollectionTile extends ConsumerWidget {
  final _MediaCollection collection;
  final VoidCallback onOpen;

  const _MediaCollectionTile({required this.collection, required this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    final item = collection.primary;
    final posterURL = item.posterPath?.isNotEmpty == true
        ? _tmdbImageURL(item.posterPath!, size: 'w342')
        : null;
    return Semantics(
      button: true,
      label: '${collection.name}，${collection.workCount} 部作品',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: cs.muted,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: cs.border),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: posterURL == null
                          ? Center(
                              child: Icon(
                                Icons.collections_bookmark_rounded,
                                color: cs.mutedForeground,
                                size: 34,
                              ),
                            )
                          : CachedNetworkImage(
                              imageUrl: posterURL,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => _tmdbDirectFallback(
                                path: item.posterPath!,
                                size: 'w342',
                                fallback: Center(
                                  child: Icon(
                                    Icons.collections_bookmark_rounded,
                                    color: cs.mutedForeground,
                                    size: 34,
                                  ),
                                ),
                              ),
                            ),
                    ),
                    Positioned(
                      right: 7,
                      bottom: 7,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${collection.workCount} 部',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                collection.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: cs.foreground,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${collection.workCount} 部作品 · 自动合集',
                style: TextStyle(fontSize: 11, color: cs.mutedForeground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContinueWatchingWork {
  final _MediaWork work;
  final MediaLibraryItem item;
  final WatchHistoryEntry entry;

  const _ContinueWatchingWork({
    required this.work,
    required this.item,
    required this.entry,
  });
}

class _ContinueWatchingTile extends StatelessWidget {
  final _ContinueWatchingWork value;
  final VoidCallback onContinue;

  const _ContinueWatchingTile({required this.value, required this.onContinue});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final item = value.work.primary;
    final episode = ParsedMediaName.parse(value.item.file.name);
    final episodeLabel =
        item.mediaKind == TMDBMediaKind.tv && episode.episode != null
        ? '第 ${episode.season ?? 1} 季第 ${episode.episode} 集'
        : '继续观看';
    final percent = (value.entry.progress * 100).round();
    final backdrop = item.backdropPath?.isNotEmpty == true
        ? _tmdbImageURL(item.backdropPath!, size: 'w780')
        : null;
    return Semantics(
      button: true,
      label: '${item.title}，$episodeLabel，已观看 $percent%',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onContinue,
          borderRadius: BorderRadius.circular(7),
          child: SizedBox(
            width: 244,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: cs.muted,
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(color: cs.border),
                        ),
                        child: backdrop == null
                            ? Center(
                                child: Icon(
                                  Icons.play_circle_outline_rounded,
                                  color: cs.mutedForeground,
                                  size: 30,
                                ),
                              )
                            : CachedNetworkImage(
                                imageUrl: backdrop,
                                fit: BoxFit.cover,
                              ),
                      ),
                      Positioned(
                        right: 10,
                        bottom: 10,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.58),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: AppLoadingIndicator(
                              value: value.entry.progress,
                              size: AppLoadingSize.compact,
                              color: Colors.white,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.22,
                              ),
                              semanticsLabel: '观看进度',
                              semanticsValue: '$percent%',
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.foreground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$episodeLabel · 已观看 $percent%',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaPosterTile extends ConsumerWidget {
  final _MediaWork work;
  final VoidCallback onOpen;
  final VoidCallback onDownload;
  final VoidCallback? onRecognize;
  final VoidCallback onManualMatch;

  const _MediaPosterTile({
    required this.work,
    required this.onOpen,
    required this.onDownload,
    this.onRecognize,
    required this.onManualMatch,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    final item = work.primary;
    final isSeries = item.mediaKind == TMDBMediaKind.tv;
    final posterURL = item.posterPath?.isNotEmpty == true
        ? _tmdbImageURL(item.posterPath!, size: 'w342')
        : null;
    return ShadContextMenuRegion(
      tapEnabled: false,
      items: [
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.info, size: 16),
          onPressed: onOpen,
          child: const Text('查看详情'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.download, size: 16),
          onPressed: onDownload,
          child: const Text('打开资源'),
        ),
        const Divider(height: 8),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.sparkles, size: 16),
          onPressed: onRecognize,
          child: const Text('媒体识别'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.listFilter, size: 16),
          onPressed: onManualMatch,
          child: const Text('手动匹配'),
        ),
      ],
      child: Semantics(
        button: true,
        label: '${item.title}，${work.resources.length} 个资源版本',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: cs.muted,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: cs.border),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: posterURL == null
                            ? _posterFallback(cs, isSeries)
                            : CachedNetworkImage(
                                imageUrl: posterURL,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => _tmdbDirectFallback(
                                  path: item.posterPath!,
                                  size: 'w342',
                                  fallback: _posterFallback(cs, isSeries),
                                ),
                              ),
                      ),
                      if (work.resources.length > 1)
                        Positioned(
                          right: 7,
                          bottom: 7,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              isSeries
                                  ? '${work.resources.length} 集'
                                  : '${work.resources.length} 版本',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ShadTooltip(
                  builder: (_) => Text(item.title),
                  child: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: cs.foreground,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${item.year.isEmpty ? '未知年份' : item.year} · ${isSeries ? '剧集' : '电影'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _posterFallback(ShadColorScheme cs, bool isSeries) => Center(
    child: Icon(
      isSeries ? Icons.tv_rounded : Icons.movie_rounded,
      color: cs.mutedForeground,
      size: 34,
    ),
  );
}

class _MediaDetailPanel extends ConsumerStatefulWidget {
  final _MediaWork work;
  final ValueChanged<MediaLibraryItem> onDownload;
  final ValueChanged<MediaLibraryItem> onPlay;
  final ValueChanged<MediaLibraryItem> onExternalPlay;
  final VoidCallback onRecognize;
  final ValueChanged<MediaLibraryItem> onManualMatch;
  final Future<void> Function(List<MediaLibraryItem>) onRemoveRecords;
  final bool manualMatchBusy;
  final String? manualMatchLoadingResourceKey;
  final bool removalDisabled;

  const _MediaDetailPanel({
    required this.work,
    required this.onDownload,
    required this.onPlay,
    required this.onExternalPlay,
    required this.onRecognize,
    required this.onManualMatch,
    required this.onRemoveRecords,
    this.manualMatchBusy = false,
    this.manualMatchLoadingResourceKey,
    this.removalDisabled = false,
  });

  @override
  ConsumerState<_MediaDetailPanel> createState() => _MediaDetailPanelState();
}

class _MediaDetailPanelState extends ConsumerState<_MediaDetailPanel> {
  late MediaLibraryItem _resource = widget.work.primary;
  Map<String, dynamic>? _tmdbDetails;
  Map<String, dynamic>? _episodeDetails;
  int? _loadedTMDBID;
  TMDBMediaKind? _loadedTMDBKind;
  int? _selectedSeason;
  String? _selectedEpisodeID;
  bool _loadingTMDBDetails = false;
  int _tmdbDetailRequestSerial = 0;
  bool _loadingEpisodeDetails = false;
  bool _removingRecords = false;
  bool _initialEpisodeSelectionRequested = false;
  final _backdropController = PageController();
  final _removeMenuController = ShadPopoverController();
  Timer? _backdropTimer;
  var _backdropIndex = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadTMDBDetails);
    Future.microtask(_selectInitialEpisode);
  }

  @override
  void didUpdateWidget(covariant _MediaDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.work.primary.id != widget.work.primary.id) {
      _initialEpisodeSelectionRequested = false;
      _selectedEpisodeID = null;
      _episodeDetails = null;
      Future.microtask(_selectInitialEpisode);
    }
    final updatedResource = widget.work.resources
        .where((item) => item.id == _resource.id)
        .firstOrNull;
    if (updatedResource != null) {
      _resource = updatedResource;
    } else {
      _resource = widget.work.primary;
      if (_selectedEpisodeID != null) {
        _selectedEpisodeID = null;
        _episodeDetails = null;
        _initialEpisodeSelectionRequested = false;
        Future.microtask(_selectInitialEpisode);
      }
    }
    if (widget.work.primary.tmdbID != _loadedTMDBID ||
        widget.work.primary.mediaKind != _loadedTMDBKind) {
      _tmdbDetails = null;
      _selectedSeason = null;
      _selectedEpisodeID = null;
      _episodeDetails = null;
      Future.microtask(_loadTMDBDetails);
    }
  }

  @override
  void dispose() {
    _backdropTimer?.cancel();
    _backdropController.dispose();
    _removeMenuController.dispose();
    super.dispose();
  }

  Future<void> _loadTMDBDetails({bool force = false}) async {
    if (!mounted) return;
    final item = widget.work.primary;
    final tmdbID = item.tmdbID;
    final kind = item.mediaKind;
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (tmdbID == null ||
        kind == null ||
        apiKey.isEmpty ||
        (!force && _loadedTMDBID == tmdbID && _loadedTMDBKind == kind)) {
      return;
    }
    final requestSerial = ++_tmdbDetailRequestSerial;
    setState(() => _loadingTMDBDetails = true);
    try {
      final details = await ref
          .read(authProvider.notifier)
          .api
          .tmdbDetails(
            tmdbID,
            mediaKind: kind == TMDBMediaKind.tv ? 'tv' : 'movie',
            apiKey: apiKey,
            proxyHost:
                StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
            proxyPort:
                StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
          );
      if (mounted &&
          requestSerial == _tmdbDetailRequestSerial &&
          widget.work.primary.tmdbID == tmdbID) {
        setState(() {
          _tmdbDetails = details;
          _loadedTMDBID = tmdbID;
          _loadedTMDBKind = kind;
        });
        _restartBackdropCarousel();
      }
    } catch (_) {
      // Artwork enrichments are optional and should not interrupt playback.
    } finally {
      if (mounted && requestSerial == _tmdbDetailRequestSerial) {
        setState(() => _loadingTMDBDetails = false);
      }
    }
  }

  Future<void> _selectEpisode(MediaLibraryItem resource) async {
    final parsed = ParsedMediaName.parse(
      resource.file.name,
      directoryName: _parentDirectoryName(resource.file.cloudPath),
    );
    setState(() {
      _resource = resource;
      _selectedSeason = parsed.season ?? _selectedSeason ?? 1;
      _selectedEpisodeID = resource.id;
      _episodeDetails = null;
    });
    final tmdbID = widget.work.primary.tmdbID;
    final season = parsed.season;
    final episode = parsed.episode;
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (tmdbID == null || season == null || episode == null || apiKey.isEmpty) {
      return;
    }
    setState(() => _loadingEpisodeDetails = true);
    try {
      final details = await ref
          .read(authProvider.notifier)
          .api
          .tmdbEpisodeDetails(
            tmdbID,
            season: season,
            episode: episode,
            apiKey: apiKey,
            proxyHost:
                StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
            proxyPort:
                StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
          );
      if (mounted && _selectedEpisodeID == resource.id) {
        setState(() => _episodeDetails = details);
      }
    } catch (_) {
      // File metadata remains available when an episode detail request fails.
    } finally {
      if (mounted && _selectedEpisodeID == resource.id) {
        setState(() => _loadingEpisodeDetails = false);
      }
    }
  }

  Future<void> _selectInitialEpisode() async {
    if (_initialEpisodeSelectionRequested ||
        widget.work.primary.mediaKind != TMDBMediaKind.tv) {
      return;
    }
    _initialEpisodeSelectionRequested = true;
    final episodes =
        widget.work.resources
            .map(
              (resource) => (
                resource: resource,
                parsed: ParsedMediaName.parse(
                  resource.file.name,
                  directoryName: _parentDirectoryName(resource.file.cloudPath),
                ),
              ),
            )
            .where((entry) => entry.parsed.episode != null)
            .toList()
          ..sort((left, right) {
            final season = (left.parsed.season ?? 1).compareTo(
              right.parsed.season ?? 1,
            );
            if (season != 0) return season;
            return (left.parsed.episode ?? 0).compareTo(
              right.parsed.episode ?? 0,
            );
          });
    if (episodes.isEmpty) return;
    final historyByID = {
      for (final entry in ref.read(watchHistoryProvider)) entry.fileID: entry,
    };
    final lastPlayed = episodes
        .where((entry) => historyByID.containsKey(entry.resource.id))
        .fold<({MediaLibraryItem resource, ParsedMediaName parsed})?>(null, (
          current,
          entry,
        ) {
          if (current == null) return entry;
          final currentHistory = historyByID[current.resource.id]!;
          final candidateHistory = historyByID[entry.resource.id]!;
          return candidateHistory.updatedAt.isAfter(currentHistory.updatedAt)
              ? entry
              : current;
        });
    await _selectEpisode((lastPlayed ?? episodes.first).resource);
  }

  List<String> _heroBackdropPaths(MediaLibraryItem item) {
    final images = _tmdbDetails?['images'];
    final paths = <String>[
      if (item.backdropPath?.isNotEmpty == true) item.backdropPath!,
      if (_tmdbDetails?['backdrop_path']?.toString().isNotEmpty == true)
        _tmdbDetails!['backdrop_path'].toString(),
      if (images is Map) ..._imagePaths(images['backdrops']),
    ];
    return paths.toSet().take(10).toList();
  }

  void _restartBackdropCarousel() {
    _backdropTimer?.cancel();
    final count = _heroBackdropPaths(widget.work.primary).length;
    if (count < 2) return;
    _backdropIndex = 0;
    if (_backdropController.hasClients) _backdropController.jumpToPage(0);
    _backdropTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted || !_backdropController.hasClients) return;
      _backdropIndex = (_backdropIndex + 1) % count;
      _backdropController.animateToPage(
        _backdropIndex,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final item = widget.work.primary;
    final isSeries = item.mediaKind == TMDBMediaKind.tv;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detailInformation(context, item, isSeries),
                const SizedBox(height: 22),
                if (item.isMatched) ...[
                  _tmdbEnrichment(context, showPosters: false),
                  const SizedBox(height: 22),
                ],
                _resourceList(context, cs),
                if (item.isMatched) ...[
                  const SizedBox(height: 22),
                  _tmdbEnrichment(context, showCast: false),
                ],
                const SizedBox(height: 22),
                _fileInformation(context, item),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _detailInformation(
    BuildContext context,
    MediaLibraryItem item,
    bool isSeries,
  ) {
    final cs = ShadTheme.of(context).colorScheme;
    final posterURL = item.posterPath?.isNotEmpty == true
        ? _tmdbImageURL(item.posterPath!, size: 'w342')
        : null;
    final backdrops = _heroBackdropPaths(item);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        return SizedBox(
          height: compact ? 560 : 370,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (backdrops.isNotEmpty)
                  PageView.builder(
                    controller: _backdropController,
                    itemCount: backdrops.length,
                    onPageChanged: (index) => _backdropIndex = index,
                    itemBuilder: (_, index) => CachedNetworkImage(
                      imageUrl: _tmdbImageURL(backdrops[index], size: 'w1280'),
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => _tmdbDirectFallback(
                        path: backdrops[index],
                        size: 'w1280',
                        fallback: ColoredBox(color: cs.muted),
                      ),
                    ),
                  )
                else
                  ColoredBox(color: cs.muted),
                ColoredBox(color: Colors.black.withValues(alpha: 0.58)),
                Padding(
                  padding: EdgeInsets.all(compact ? 16 : 22),
                  child: Flex(
                    direction: compact ? Axis.vertical : Axis.horizontal,
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: compact
                        ? CrossAxisAlignment.start
                        : CrossAxisAlignment.end,
                    children: [
                      SizedBox(
                        width: compact ? 104 : 150,
                        height: compact ? 156 : 225,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: posterURL == null
                              ? _detailPosterFallback(cs, isSeries)
                              : CachedNetworkImage(
                                  imageUrl: posterURL,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, _, _) => _tmdbDirectFallback(
                                    path: item.posterPath!,
                                    size: 'w342',
                                    fallback: _detailPosterFallback(
                                      cs,
                                      isSeries,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      SizedBox(
                        width: compact ? 0 : 20,
                        height: compact ? 12 : 0,
                      ),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(
                              item.title,
                              style: TextStyle(
                                fontSize: compact ? 23 : 28,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            if (item.originalTitle.isNotEmpty &&
                                item.originalTitle != item.title) ...[
                              const SizedBox(height: 3),
                              SelectableText(
                                item.originalTitle,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.white.withValues(alpha: 0.72),
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                ShadBadge(child: Text(isSeries ? '剧集' : '电影')),
                                if (item.year.isNotEmpty)
                                  ShadBadge.outline(child: Text(item.year)),
                                if (item.hasChineseAudio)
                                  const ShadBadge.outline(child: Text('中文音轨')),
                                if (item.hasChineseSubtitle)
                                  const ShadBadge.outline(child: Text('中文字幕')),
                              ],
                            ),
                            const SizedBox(height: 14),
                            SelectableText(
                              item.overview.isEmpty ? '暂无影视简介。' : item.overview,
                              maxLines: compact ? 3 : 4,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.55,
                                color: Colors.white.withValues(alpha: 0.82),
                              ),
                            ),
                            const SizedBox(height: 14),
                            _mediaActions(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _fileInformation(BuildContext context, MediaLibraryItem item) {
    final cs = ShadTheme.of(context).colorScheme;
    final parsed = ParsedMediaName.parse(
      _resource.file.name,
      directoryName: _parentDirectoryName(_resource.file.cloudPath),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '文件与媒体信息',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: cs.foreground,
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 20,
          runSpacing: 10,
          children: [
            _metadataPill(context, 'TMDB', item.tmdbID?.toString() ?? '未匹配'),
            _metadataPill(context, '资源', '${widget.work.resources.length}'),
            _metadataPill(context, '大小', _resource.file.formattedSize),
            if (parsed.resolution != null)
              _metadataPill(context, '分辨率', parsed.resolution!),
            if (parsed.videoCodec != null)
              _metadataPill(context, '编码', parsed.videoCodec!),
            if (parsed.audio != null)
              _metadataPill(context, '音频', parsed.audio!),
          ],
        ),
        const SizedBox(height: 12),
        _metadataRow(context, '当前文件', _resource.file.name),
        _metadataRow(context, '文件 ID', _resource.file.id),
        _metadataRow(
          context,
          'GCID',
          _resource.file.gcid?.isNotEmpty == true
              ? _resource.file.gcid!
              : '未获取',
        ),
        _metadataRow(context, '云盘位置', _resource.file.cloudPath),
      ],
    );
  }

  bool get _removalBlocked => widget.removalDisabled || _removingRecords;

  bool get _manualMatchLoading =>
      widget.manualMatchLoadingResourceKey == _mediaRecordKey(_resource);

  ParsedMediaName _parsedResource(MediaLibraryItem resource) =>
      ParsedMediaName.parse(
        resource.file.name,
        directoryName: _parentDirectoryName(resource.file.cloudPath),
      );

  List<MediaLibraryItem> _episodeRecords(MediaLibraryItem resource) {
    final parsed = _parsedResource(resource);
    final episode = parsed.episode;
    if (episode == null) return [resource];
    final season = parsed.season ?? 1;
    return widget.work.resources.where((candidate) {
      if (candidate.libraryID != resource.libraryID) return false;
      final candidateParsed = _parsedResource(candidate);
      return (candidateParsed.season ?? 1) == season &&
          candidateParsed.episode == episode;
    }).toList();
  }

  List<MediaLibraryItem> _currentLibraryWorkRecords() => widget.work.resources
      .where((resource) => resource.libraryID == _resource.libraryID)
      .toList();

  MediaLibraryItem? _nextResourceAfterRemoving(Set<String> removedKeys) {
    final ordered = widget.work.resources.toList()
      ..sort((left, right) {
        final leftParsed = _parsedResource(left);
        final rightParsed = _parsedResource(right);
        final season = (leftParsed.season ?? 1).compareTo(
          rightParsed.season ?? 1,
        );
        if (season != 0) return season;
        final episode = (leftParsed.episode ?? 0).compareTo(
          rightParsed.episode ?? 0,
        );
        if (episode != 0) return episode;
        return left.file.name.toLowerCase().compareTo(
          right.file.name.toLowerCase(),
        );
      });
    final currentIndex = ordered.indexWhere(
      (resource) => _mediaRecordKey(resource) == _mediaRecordKey(_resource),
    );
    if (currentIndex < 0) {
      return ordered
          .where((resource) => !removedKeys.contains(_mediaRecordKey(resource)))
          .firstOrNull;
    }
    for (var index = currentIndex + 1; index < ordered.length; index++) {
      if (!removedKeys.contains(_mediaRecordKey(ordered[index]))) {
        return ordered[index];
      }
    }
    for (var index = currentIndex - 1; index >= 0; index--) {
      if (!removedKeys.contains(_mediaRecordKey(ordered[index]))) {
        return ordered[index];
      }
    }
    return null;
  }

  Future<void> _confirmAndRemoveRecords({
    required Iterable<MediaLibraryItem> records,
    required String title,
    required String description,
  }) async {
    if (_removalBlocked) return;
    final unique = <String, MediaLibraryItem>{
      for (final record in records) _mediaRecordKey(record): record,
    }.values.toList();
    if (unique.isEmpty) return;
    _removeMenuController.hide();
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: Text(title),
        description: Text(description),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            leading: const Icon(LucideIcons.trash2, size: 16),
            child: const Text('移除'),
          ),
        ],
        child: const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('只会移除媒体库记录及相关观看历史，不会删除云盘中的实际文件。后续强制扫描时仍可能重新加入。'),
        ),
      ),
    );
    if (confirmed != true || !mounted || _removalBlocked) return;

    final removedKeys = unique.map(_mediaRecordKey).toSet();
    final removesCurrent = removedKeys.contains(_mediaRecordKey(_resource));
    final nextResource = removesCurrent
        ? _nextResourceAfterRemoving(removedKeys)
        : null;
    setState(() => _removingRecords = true);
    try {
      await widget.onRemoveRecords(unique);
    } finally {
      if (mounted) setState(() => _removingRecords = false);
    }
    if (!mounted || !removesCurrent || nextResource == null) return;
    if (widget.work.primary.mediaKind == TMDBMediaKind.tv) {
      await _selectEpisode(nextResource);
    } else {
      setState(() => _resource = nextResource);
    }
  }

  Future<void> _removeResource(MediaLibraryItem resource) =>
      _confirmAndRemoveRecords(
        records: [resource],
        title: '移除当前资源？',
        description: resource.file.name,
      );

  Future<void> _removeEpisode(MediaLibraryItem resource) {
    final parsed = _parsedResource(resource);
    final records = _episodeRecords(resource);
    final season = parsed.season ?? 1;
    final episode = parsed.episode;
    return _confirmAndRemoveRecords(
      records: records,
      title: episode == null ? '移除当前剧集资源？' : '移除第 $season 季第 $episode 集？',
      description: records.length == 1
          ? records.first.file.name
          : '将移除本集的 ${records.length} 个资源版本。',
    );
  }

  Future<void> _removeCurrentLibraryWork() {
    final isSeries = widget.work.primary.mediaKind == TMDBMediaKind.tv;
    final records = _currentLibraryWorkRecords();
    final episodeCount = records
        .map((resource) {
          final parsed = _parsedResource(resource);
          return '${parsed.season ?? 1}:${parsed.episode ?? resource.id}';
        })
        .toSet()
        .length;
    return _confirmAndRemoveRecords(
      records: records,
      title: '从当前媒体库移除「${widget.work.primary.title}」？',
      description: isSeries
          ? '将移除整部剧集的 $episodeCount 集，共 ${records.length} 个资源记录。'
          : '将移除整部电影的 ${records.length} 个资源版本。',
    );
  }

  Widget _mediaActions() {
    final manualMatchLoading = _manualMatchLoading;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ShadButton(
          size: ShadButtonSize.sm,
          onPressed: () => widget.onPlay(_resource),
          leading: const Icon(Icons.play_arrow_rounded, size: 16),
          child: const Text('播放'),
        ),
        ShadButton.outline(
          size: ShadButtonSize.sm,
          onPressed: () => widget.onExternalPlay(_resource),
          leading: const Icon(Icons.launch_rounded, size: 16),
          child: const Text('外部播放'),
        ),
        ShadButton.outline(
          size: ShadButtonSize.sm,
          onPressed: () => widget.onDownload(_resource),
          leading: const Icon(Icons.download_rounded, size: 16),
          child: const Text('下载'),
        ),
        ShadButton.outline(
          size: ShadButtonSize.sm,
          onPressed: widget.onRecognize,
          leading: const Icon(Icons.auto_awesome_rounded, size: 16),
          child: const Text('媒体识别'),
        ),
        ShadButton.outline(
          size: ShadButtonSize.sm,
          onPressed: widget.manualMatchBusy
              ? null
              : () => widget.onManualMatch(_resource),
          leading: manualMatchLoading
              ? const AppLoadingIndicator(
                  size: AppLoadingSize.inline,
                  semanticsLabel: '正在准备手动匹配',
                )
              : const Icon(Icons.manage_search_rounded, size: 16),
          child: Text(manualMatchLoading ? '正在匹配' : '手动匹配'),
        ),
        _removeActionsPopover(),
      ],
    );
  }

  Widget _removeActionsPopover() {
    final cs = ShadTheme.of(context).colorScheme;
    final isSeries = widget.work.primary.mediaKind == TMDBMediaKind.tv;
    final parsed = _parsedResource(_resource);
    final episodeRecords = isSeries ? _episodeRecords(_resource) : const [];
    final libraryRecords = _currentLibraryWorkRecords();
    return ShadPopover(
      controller: _removeMenuController,
      popover: (_) => SizedBox(
        width: 292,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 7),
                child: Text(
                  '管理媒体库记录',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: cs.mutedForeground,
                  ),
                ),
              ),
              _removalMenuItem(
                icon: LucideIcons.fileX,
                title: '移除当前资源',
                description: _resource.file.name,
                onPressed: () => _removeResource(_resource),
              ),
              if (isSeries && parsed.episode != null) ...[
                const SizedBox(height: 3),
                _removalMenuItem(
                  icon: LucideIcons.listX,
                  title: '移除第 ${parsed.season ?? 1} 季第 ${parsed.episode} 集',
                  description: episodeRecords.length > 1
                      ? '包含 ${episodeRecords.length} 个资源版本'
                      : '移除当前单集记录',
                  onPressed: () => _removeEpisode(_resource),
                ),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 5),
                child: ShadSeparator.horizontal(),
              ),
              _removalMenuItem(
                icon: LucideIcons.trash2,
                title: isSeries ? '移除当前媒体库内整部剧集' : '移除当前媒体库内整部电影',
                description: isSeries
                    ? '${libraryRecords.length} 个资源记录'
                    : '${libraryRecords.length} 个资源版本',
                onPressed: _removeCurrentLibraryWork,
              ),
            ],
          ),
        ),
      ),
      child: ShadTooltip(
        builder: (_) => const Text('更多媒体操作'),
        child: ShadButton.outline(
          size: ShadButtonSize.sm,
          onPressed: _removalBlocked ? null : _removeMenuController.toggle,
          leading: _removingRecords
              ? const AppLoadingIndicator(
                  size: AppLoadingSize.inline,
                  semanticsLabel: '正在移除媒体库记录',
                )
              : const Icon(Icons.more_horiz_rounded, size: 16),
          child: Text(_removingRecords ? '正在移除' : '更多'),
        ),
      ),
    );
  }

  Widget _removalMenuItem({
    required IconData icon,
    required String title,
    required String description,
    required Future<void> Function() onPressed,
  }) {
    final cs = ShadTheme.of(context).colorScheme;
    return ShadButton.ghost(
      width: double.infinity,
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      mainAxisAlignment: MainAxisAlignment.start,
      leading: Icon(icon, size: 17, color: cs.destructive),
      onPressed: _removalBlocked
          ? null
          : () {
              _removeMenuController.hide();
              unawaited(onPressed());
            },
      child: SizedBox(
        width: 226,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.destructive,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metadataPill(BuildContext context, String label, String value) {
    final cs = ShadTheme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: TextStyle(fontSize: 12, color: cs.mutedForeground),
        ),
        SelectableText(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: cs.foreground,
          ),
        ),
      ],
    );
  }

  Widget _tmdbEnrichment(
    BuildContext context, {
    bool showPosters = true,
    bool showCast = true,
  }) {
    final cs = ShadTheme.of(context).colorScheme;
    if (_loadingTMDBDetails && _tmdbDetails == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Align(
          alignment: Alignment.centerLeft,
          child: AppLoadingIndicator(
            size: AppLoadingSize.compact,
            label: '正在加载影视资料',
          ),
        ),
      );
    }
    final details = _tmdbDetails;
    if (details == null) return const SizedBox.shrink();
    final images = details['images'] is Map
        ? Map<String, dynamic>.from(details['images'] as Map)
        : const <String, dynamic>{};
    final posters = _imagePaths(images['posters']);
    final credits = details['credits'] is Map
        ? Map<String, dynamic>.from(details['credits'] as Map)
        : const <String, dynamic>{};
    final cast =
        (credits['cast'] as List?)
            ?.whereType<Map>()
            .map((value) => Map<String, dynamic>.from(value))
            .take(12)
            .toList() ??
        const <Map<String, dynamic>>[];
    if ((!showPosters || posters.isEmpty) && (!showCast || cast.isEmpty)) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showPosters && posters.isNotEmpty) ...[
          Text(
            '更多海报',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: cs.foreground,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 160,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: posters.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: _tmdbImageURL(posters[index], size: 'w342'),
                  width: 106,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => _tmdbDirectFallback(
                    path: posters[index],
                    size: 'w342',
                    width: 106,
                    fallback: const SizedBox(width: 106),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
        ],
        if (showCast && cast.isNotEmpty) ...[
          Text(
            '演职员',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: cs.foreground,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: cast.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final person = cast[index];
                final profile = person['profile_path']?.toString();
                return SizedBox(
                  width: 96,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: profile == null || profile.isEmpty
                            ? Container(
                                width: 96,
                                height: 122,
                                color: cs.muted,
                                child: Icon(
                                  Icons.person_rounded,
                                  color: cs.mutedForeground,
                                ),
                              )
                            : CachedNetworkImage(
                                imageUrl: _tmdbImageURL(profile, size: 'w185'),
                                width: 96,
                                height: 122,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => _tmdbDirectFallback(
                                  path: profile,
                                  size: 'w185',
                                  width: 96,
                                  height: 122,
                                  fallback: Container(
                                    width: 96,
                                    height: 122,
                                    color: cs.muted,
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        person['name']?.toString() ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: cs.foreground,
                        ),
                      ),
                      Text(
                        person['character']?.toString() ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: cs.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  List<String> _imagePaths(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((image) => image['file_path']?.toString())
        .whereType<String>()
        .where((path) => path.isNotEmpty)
        .take(12)
        .toList();
  }

  Widget _detailPosterFallback(ShadColorScheme cs, bool isSeries) => Container(
    color: cs.muted,
    child: Center(
      child: Icon(
        isSeries ? Icons.tv_rounded : Icons.movie_rounded,
        color: cs.mutedForeground,
        size: 42,
      ),
    ),
  );

  Widget _metadataRow(BuildContext context, String label, String value) {
    final cs = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: SelectableText(
              label,
              style: TextStyle(fontSize: 12, color: cs.mutedForeground),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(fontSize: 12, color: cs.foreground),
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _resourceList(BuildContext context, ShadColorScheme cs) {
    final isSeries = widget.work.primary.mediaKind == TMDBMediaKind.tv;
    final episodesBySeason = <int, List<MediaLibraryItem>>{};
    if (isSeries) {
      for (final resource in widget.work.resources) {
        final parsed = ParsedMediaName.parse(
          resource.file.name,
          directoryName: _parentDirectoryName(resource.file.cloudPath),
        );
        (episodesBySeason[parsed.season ?? 1] ??= []).add(resource);
      }
      for (final values in episodesBySeason.values) {
        values.sort((a, b) {
          final aEpisode =
              ParsedMediaName.parse(
                a.file.name,
                directoryName: _parentDirectoryName(a.file.cloudPath),
              ).episode ??
              9999;
          final bEpisode =
              ParsedMediaName.parse(
                b.file.name,
                directoryName: _parentDirectoryName(b.file.cloudPath),
              ).episode ??
              9999;
          return aEpisode == bEpisode
              ? a.file.name.compareTo(b.file.name)
              : aEpisode.compareTo(bEpisode);
        });
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isSeries
              ? '剧集 (${widget.work.resources.length} 集)'
              : widget.work.resources.length > 1
              ? '资源版本 (${widget.work.resources.length})'
              : '媒体资源',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: cs.foreground,
          ),
        ),
        const SizedBox(height: 8),
        if (isSeries && episodesBySeason.isNotEmpty) ...[
          _seasonPicker(episodesBySeason, cs),
          const SizedBox(height: 10),
          _episodePicker(
            episodesBySeason[_activeSeason(episodesBySeason)]!,
            cs,
          ),
          _episodeIntroduction(context, cs),
        ] else
          ...widget.work.resources.map(
            (resource) => _resourceTile(resource, cs),
          ),
      ],
    );
  }

  int _activeSeason(Map<int, List<MediaLibraryItem>> episodesBySeason) {
    if (_selectedSeason != null &&
        episodesBySeason.containsKey(_selectedSeason)) {
      return _selectedSeason!;
    }
    return episodesBySeason.keys.reduce((a, b) => a < b ? a : b);
  }

  Widget _seasonPicker(
    Map<int, List<MediaLibraryItem>> episodesBySeason,
    ShadColorScheme cs,
  ) {
    final selectedSeason = _activeSeason(episodesBySeason);
    final seasons = episodesBySeason.keys.toList()..sort();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final season in seasons)
            Padding(
              padding: EdgeInsets.only(right: season == seasons.last ? 0 : 8),
              child: ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: () => setState(() {
                  _selectedSeason = season;
                  _selectedEpisodeID = null;
                  _episodeDetails = null;
                }),
                backgroundColor: season == selectedSeason ? cs.primary : null,
                foregroundColor: season == selectedSeason
                    ? cs.primaryForeground
                    : null,
                child: Text(
                  '第 $season 季 · ${episodesBySeason[season]!.length} 集',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _episodePicker(List<MediaLibraryItem> episodes, ShadColorScheme cs) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final resource in episodes)
          Builder(
            builder: (context) {
              final parsed = ParsedMediaName.parse(
                resource.file.name,
                directoryName: _parentDirectoryName(resource.file.cloudPath),
              );
              final episode = parsed.episode;
              final selected = _selectedEpisodeID == resource.id;
              final label = episode == null
                  ? '未编号'
                  : 'E${episode.toString().padLeft(2, '0')}';
              return ShadContextMenuRegion(
                tapEnabled: false,
                items: [
                  ShadContextMenuItem.inset(
                    leading: Icon(
                      LucideIcons.trash2,
                      size: 16,
                      color: cs.destructive,
                    ),
                    onPressed: _removalBlocked
                        ? null
                        : () => unawaited(_removeEpisode(resource)),
                    child: Text(
                      episode == null ? '移除当前剧集资源' : '移除本集',
                      style: TextStyle(color: cs.destructive),
                    ),
                  ),
                ],
                child: ShadTooltip(
                  builder: (_) =>
                      Text(episode == null ? '未识别集号' : '第 $episode 集'),
                  child: ShadButton.outline(
                    size: ShadButtonSize.sm,
                    width: 58,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    backgroundColor: selected ? cs.primary : null,
                    foregroundColor: selected ? cs.primaryForeground : null,
                    onPressed: () => unawaited(_selectEpisode(resource)),
                    child: SizedBox(
                      width: 50,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(label, maxLines: 1),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _episodeIntroduction(BuildContext context, ShadColorScheme cs) {
    final selected = _selectedEpisodeID == _resource.id;
    if (!selected) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '选择一集查看当前集介绍',
          style: TextStyle(fontSize: 12, color: cs.mutedForeground),
        ),
      );
    }
    if (_loadingEpisodeDetails) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: AppLoadingIndicator(
          size: AppLoadingSize.compact,
          label: '正在加载剧集资料',
        ),
      );
    }
    final parsed = ParsedMediaName.parse(
      _resource.file.name,
      directoryName: _parentDirectoryName(_resource.file.cloudPath),
    );
    final details = _episodeDetails;
    final title = details?['name']?.toString().trim();
    final overview = details?['overview']?.toString().trim();
    final airDate = details?['air_date']?.toString().trim();
    final runtime = details?['runtime'];
    final stillPath = details?['still_path']?.toString();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.muted.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stillPath?.isNotEmpty == true)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: CachedNetworkImage(
                imageUrl: _tmdbImageURL(stillPath!, size: 'w300'),
                width: 128,
                height: 72,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => _tmdbDirectFallback(
                  path: stillPath,
                  size: 'w300',
                  width: 128,
                  height: 72,
                  fallback: Container(color: cs.card),
                ),
              ),
            ),
          if (stillPath?.isNotEmpty == true) const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  title?.isNotEmpty == true
                      ? title!
                      : '第 ${parsed.episode?.toString() ?? '-'} 集',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.foreground,
                  ),
                ),
                const SizedBox(height: 4),
                if (airDate?.isNotEmpty == true || runtime != null)
                  Text(
                    [
                      if (airDate?.isNotEmpty == true) airDate!,
                      if (runtime != null) '$runtime 分钟',
                    ].join(' · '),
                    style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                  ),
                if (overview?.isNotEmpty == true) ...[
                  const SizedBox(height: 6),
                  SelectableText(
                    overview!,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: cs.foreground,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 6),
                  Text(
                    '暂无本集简介',
                    style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                  ),
                ],
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: ShadButton(
                    size: ShadButtonSize.sm,
                    onPressed: () => widget.onPlay(_resource),
                    leading: const Icon(Icons.play_arrow_rounded, size: 16),
                    child: const Text('播放本集'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _resourceTile(
    MediaLibraryItem resource,
    ShadColorScheme cs, {
    int? episode,
  }) {
    final selected = resource.id == _resource.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ShadContextMenuRegion(
        tapEnabled: false,
        items: [
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.play, size: 16),
            onPressed: () => widget.onPlay(resource),
            child: const Text('播放'),
          ),
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.monitorPlay, size: 16),
            onPressed: () => widget.onExternalPlay(resource),
            child: const Text('外部播放器'),
          ),
          ShadContextMenuItem.inset(
            leading: const Icon(LucideIcons.download, size: 16),
            onPressed: () => widget.onDownload(resource),
            child: const Text('下载'),
          ),
          const Divider(height: 8),
          ShadContextMenuItem.inset(
            leading: Icon(LucideIcons.trash2, size: 16, color: cs.destructive),
            onPressed: _removalBlocked
                ? null
                : () => unawaited(_removeResource(resource)),
            child: Text('从媒体库移除此资源', style: TextStyle(color: cs.destructive)),
          ),
        ],
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _selectEpisode(resource),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: selected ? cs.primary.withValues(alpha: 0.10) : cs.card,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: selected ? cs.primary : cs.border),
              ),
              child: Row(
                children: [
                  if (episode != null)
                    SizedBox(
                      width: 38,
                      child: Text(
                        'E${episode.toString().padLeft(2, '0')}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          resource.file.name,
                          maxLines: 2,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: cs.foreground,
                          ),
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          '${resource.file.formattedSize} · ${resource.file.modifiedAt}',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 16,
                      color: cs.primary,
                    ),
                  const SizedBox(width: 10),
                  ShadButton.outline(
                    size: ShadButtonSize.sm,
                    onPressed: () => widget.onPlay(resource),
                    leading: const Icon(Icons.play_arrow_rounded, size: 15),
                    child: const Text('播放'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ManualTMDBMatchDialog extends ConsumerStatefulWidget {
  final String initialQuery;
  final List<Map<String, dynamic>>? initialResults;
  final int? initialYear;
  final String initialMediaKind;
  final int? initialSeason;
  final int? initialEpisode;
  final ValueChanged<Map<String, dynamic>>? onSelected;
  final VoidCallback? onDismiss;
  final bool embedded;

  const _ManualTMDBMatchDialog({
    required this.initialQuery,
    this.initialResults,
    this.initialYear,
    this.initialMediaKind = 'auto',
    this.initialSeason,
    this.initialEpisode,
    this.onSelected,
    this.onDismiss,
    this.embedded = false,
  });

  @override
  ConsumerState<_ManualTMDBMatchDialog> createState() =>
      _ManualTMDBMatchDialogState();
}

class _ManualTMDBMatchDialogState
    extends ConsumerState<_ManualTMDBMatchDialog> {
  late final TextEditingController _queryController;
  late final TextEditingController _yearController;
  late final TextEditingController _seasonController;
  late final TextEditingController _episodeController;
  late String _mediaKind;
  bool _searching = false;
  bool _loadingDetail = false;
  int _searchRequestSerial = 0;
  int _detailRequestSerial = 0;
  String? _error;
  List<Map<String, dynamic>> _results = const [];
  Map<String, dynamic>? _detailCandidate;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.initialQuery);
    _yearController = TextEditingController(
      text: widget.initialYear?.toString() ?? '',
    );
    _seasonController = TextEditingController(
      text: widget.initialSeason?.toString() ?? '1',
    );
    _episodeController = TextEditingController(
      text: widget.initialEpisode?.toString() ?? '1',
    );
    _mediaKind = widget.initialMediaKind;
    if (widget.initialResults != null) {
      _results = widget.initialResults!;
    } else {
      Future.microtask(_search);
    }
  }

  @override
  void dispose() {
    _queryController.dispose();
    _yearController.dispose();
    _seasonController.dispose();
    _episodeController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (!mounted) return;
    final requestSerial = ++_searchRequestSerial;
    final query = _queryController.text.trim();
    final year = int.tryParse(_yearController.text.trim());
    final mediaKind = _mediaKind;
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (query.isEmpty || apiKey.isEmpty) {
      setState(() {
        _results = const [];
        _error = apiKey.isEmpty ? '请先在设置中配置 TMDB API Key。' : null;
      });
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(authProvider.notifier)
          .api
          .tmdbSearch(
            query,
            apiKey: apiKey,
            mediaKind: mediaKind,
            year: year,
            proxyHost:
                StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
            proxyPort:
                StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
          );
      final values =
          (result['results'] as List?)
              ?.whereType<Map>()
              .map(Map<String, dynamic>.from)
              .map((item) {
                // TMDB 的 movie/tv 专用搜索接口不会返回 media_type；
                // 只有 multi 搜索才有该字段。补上用户选择的类型后再用
                // 同一份候选渲染逻辑，避免把所有专用搜索结果过滤为空。
                final type =
                    item['media_type']?.toString() ??
                    (mediaKind == 'movie' || mediaKind == 'tv'
                        ? mediaKind
                        : null);
                if (type == null) return item;
                return {...item, 'media_type': type};
              })
              .where(
                (item) =>
                    item['id'] != null &&
                    (item['media_type'] == 'movie' ||
                        item['media_type'] == 'tv'),
              )
              .toList() ??
          const <Map<String, dynamic>>[];
      if (mounted && requestSerial == _searchRequestSerial) {
        setState(() => _results = values);
      }
    } catch (error) {
      if (mounted && requestSerial == _searchRequestSerial) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && requestSerial == _searchRequestSerial) {
        setState(() => _searching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final detail = _detailCandidate;
    final content = ShadDialog(
      // This dialog is embedded in an OverlayEntry rather than pushed as a
      // route.  ShadDialog's default X calls Navigator.pop, which would pop
      // the workspace route and leave the page blank.  Closing is handled by
      // the explicit 取消/返回 actions and the popover's outside-tap logic.
      closeIcon: const SizedBox.shrink(),
      title: Text(detail == null ? '手动匹配 TMDB' : 'TMDB 详情'),
      description: Text(
        detail == null ? '查看或选中匹配结果后，会应用到该作品的全部资源版本。' : '确认信息无误后使用此匹配项。',
      ),
      actions: detail == null
          ? [
              ShadButton.outline(onPressed: _dismiss, child: const Text('取消')),
              ShadButton(
                onPressed: _searching ? null : _search,
                leading: const Icon(Icons.search_rounded, size: 16),
                child: const Text('搜索'),
              ),
            ]
          : [
              ShadButton.outline(
                onPressed: () => setState(() => _detailCandidate = null),
                leading: const Icon(Icons.arrow_back_rounded, size: 16),
                child: const Text('返回'),
              ),
              ShadButton(
                onPressed: () => _select(detail),
                leading: const Icon(Icons.check_rounded, size: 16),
                child: const Text('使用'),
              ),
            ],
      child: SizedBox(
        width: (viewport.width - 32).clamp(340.0, 800.0).toDouble(),
        height: (viewport.height - 170).clamp(400.0, 640.0).toDouble(),
        child: detail == null
            ? Column(
                children: [
                  _manualMatchField(
                    label: '标题',
                    child: ShadInput(
                      controller: _queryController,
                      placeholder: const Text('输入片名'),
                      onSubmitted: (_) => _search(),
                      leading: Icon(
                        Icons.search_rounded,
                        size: 16,
                        color: cs.mutedForeground,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _matchFilters(cs),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _manualMatchField(
                          label: '季',
                          child: ShadInput(
                            controller: _seasonController,
                            keyboardType: TextInputType.number,
                            placeholder: const Text('例如 1'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _manualMatchField(
                          label: '集',
                          child: ShadInput(
                            controller: _episodeController,
                            keyboardType: TextInputType.number,
                            placeholder: const Text('例如 1'),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _searching
                        ? const Center(
                            child: AppLoadingIndicator(
                              size: AppLoadingSize.page,
                              label: '正在搜索匹配结果',
                            ),
                          )
                        : _error != null
                        ? Center(
                            child: Text(
                              _error!,
                              style: TextStyle(color: cs.destructive),
                            ),
                          )
                        : _results.isEmpty
                        ? Center(
                            child: Text(
                              '没有匹配结果',
                              style: TextStyle(color: cs.mutedForeground),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _results.length,
                            separatorBuilder: (_, _) =>
                                Divider(height: 1, color: cs.border),
                            itemBuilder: (context, index) =>
                                _candidateRow(context, cs, _results[index]),
                          ),
                  ),
                ],
              )
            : _detailContent(cs, detail),
      ),
    );
    return widget.embedded ? content : content;
  }

  Widget _candidateRow(
    BuildContext context,
    ShadColorScheme cs,
    Map<String, dynamic> candidate,
  ) {
    final title = (candidate['title'] ?? candidate['name'] ?? '未知标题')
        .toString();
    final release =
        (candidate['release_date'] ?? candidate['first_air_date'] ?? '')
            .toString();
    final originalTitle =
        (candidate['original_title'] ?? candidate['original_name'] ?? '')
            .toString();
    final mediaType = candidate['media_type'] == 'tv' ? '电视剧' : '电影';
    final tmdbID = candidate['id']?.toString() ?? '';
    final posterPath = candidate['poster_path']?.toString();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => unawaited(_viewDetails(candidate)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 54,
                height: 78,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: posterPath == null || posterPath.isEmpty
                      ? Container(
                          color: cs.muted,
                          child: Icon(
                            Icons.movie_rounded,
                            size: 20,
                            color: cs.mutedForeground,
                          ),
                        )
                      : CachedNetworkImage(
                          imageUrl: _tmdbImageURL(posterPath, size: 'w154'),
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => _tmdbDirectFallback(
                            path: posterPath,
                            size: 'w154',
                            fallback: Container(
                              color: cs.muted,
                              child: Icon(
                                Icons.movie_rounded,
                                size: 20,
                                color: cs.mutedForeground,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.foreground,
                      ),
                    ),
                    const SizedBox(height: 3),
                    if (originalTitle.isNotEmpty && originalTitle != title) ...[
                      const SizedBox(height: 2),
                      Text(
                        originalTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.mutedForeground,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: [
                        ShadBadge.outline(child: Text(mediaType)),
                        ShadBadge.outline(
                          child: Text(
                            release.length >= 4
                                ? release.substring(0, 4)
                                : '未知年份',
                          ),
                        ),
                        if (tmdbID.isNotEmpty)
                          ShadBadge.outline(child: Text('TMDB $tmdbID')),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      candidate['overview']?.toString() ?? '',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: cs.mutedForeground),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 68,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ShadButton.outline(
                      size: ShadButtonSize.sm,
                      onPressed: _loadingDetail
                          ? null
                          : () => unawaited(_viewDetails(candidate)),
                      child: const Text('查看'),
                    ),
                    const SizedBox(height: 6),
                    ShadButton(
                      size: ShadButtonSize.sm,
                      onPressed: () => _select(candidate),
                      child: const Text('选中'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _viewDetails(Map<String, dynamic> candidate) async {
    if (!mounted) return;
    final id = int.tryParse(candidate['id']?.toString() ?? '');
    final type = candidate['media_type']?.toString();
    final mediaKind = type == 'tv'
        ? 'tv'
        : type == 'movie'
        ? 'movie'
        : null;
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (id == null || mediaKind == null || apiKey.isEmpty) {
      setState(() => _error = '无法获取该 TMDB 条目的详细信息');
      return;
    }
    final requestSerial = ++_detailRequestSerial;
    setState(() {
      _loadingDetail = true;
      _error = null;
    });
    try {
      final details = await ref
          .read(authProvider.notifier)
          .api
          .tmdbDetails(
            id,
            mediaKind: mediaKind,
            apiKey: apiKey,
            proxyHost:
                StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
            proxyPort:
                StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
          );
      if (mounted && requestSerial == _detailRequestSerial) {
        setState(
          () =>
              _detailCandidate = {...candidate, ...details, 'media_type': type},
        );
      }
    } catch (error) {
      if (mounted && requestSerial == _detailRequestSerial) {
        setState(() => _error = '获取 TMDB 详情失败：$error');
      }
    } finally {
      if (mounted && requestSerial == _detailRequestSerial) {
        setState(() => _loadingDetail = false);
      }
    }
  }

  Widget _detailContent(ShadColorScheme cs, Map<String, dynamic> detail) {
    final title = (detail['title'] ?? detail['name'] ?? '未知标题').toString();
    final originalTitle =
        (detail['original_title'] ?? detail['original_name'] ?? '').toString();
    final release = (detail['release_date'] ?? detail['first_air_date'] ?? '')
        .toString();
    final mediaType = detail['media_type'] == 'tv' ? '电视剧' : '电影';
    final posterPath = detail['poster_path']?.toString();
    final genres = _detailList(detail['genres'], 'name');
    final cast = _detailList(
      detail['credits'] is Map ? detail['credits']['cast'] : null,
      'name',
      limit: 12,
    );
    final facts = <String, String>{
      '类型': mediaType,
      '上映': release.isEmpty ? '未知' : release,
      '状态': detail['status']?.toString() ?? '未知',
      '时长': _detailRuntime(detail),
      '语言': detail['original_language']?.toString() ?? '未知',
      '评分': detail['vote_average']?.toString() ?? '暂无',
      '投票': detail['vote_count']?.toString() ?? '0',
      'TMDB': detail['id']?.toString() ?? '-',
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.only(right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 138,
                height: 202,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: posterPath == null || posterPath.isEmpty
                      ? Container(
                          color: cs.muted,
                          child: Icon(
                            Icons.movie_rounded,
                            size: 34,
                            color: cs.mutedForeground,
                          ),
                        )
                      : CachedNetworkImage(
                          imageUrl: _tmdbImageURL(posterPath, size: 'w342'),
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => _tmdbDirectFallback(
                            path: posterPath,
                            size: 'w342',
                            fallback: Container(color: cs.muted),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: cs.foreground,
                      ),
                    ),
                    if (originalTitle.isNotEmpty && originalTitle != title) ...[
                      const SizedBox(height: 4),
                      Text(
                        originalTitle,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.mutedForeground,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final fact in facts.entries)
                          ShadBadge.outline(
                            child: Text('${fact.key} ${fact.value}'),
                          ),
                      ],
                    ),
                    if (genres.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        genres.join(' · '),
                        style: TextStyle(fontSize: 13, color: cs.foreground),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if ((detail['tagline']?.toString() ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              detail['tagline'].toString(),
              style: TextStyle(fontSize: 13, color: cs.mutedForeground),
            ),
          ],
          const SizedBox(height: 18),
          Text(
            '剧情简介',
            style: TextStyle(fontWeight: FontWeight.w700, color: cs.foreground),
          ),
          const SizedBox(height: 6),
          Text(
            (detail['overview']?.toString().trim().isNotEmpty == true)
                ? detail['overview'].toString()
                : '暂无剧情简介',
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: cs.mutedForeground,
            ),
          ),
          if (cast.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              '演职员',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: cs.foreground,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              cast.join(' · '),
              style: TextStyle(fontSize: 13, color: cs.mutedForeground),
            ),
          ],
        ],
      ),
    );
  }

  List<String> _detailList(dynamic values, String key, {int limit = 30}) {
    if (values is! List) return const [];
    return values
        .whereType<Map>()
        .map((value) => value[key]?.toString().trim() ?? '')
        .where((value) => value.isNotEmpty)
        .take(limit)
        .toList();
  }

  String _detailRuntime(Map<String, dynamic> detail) {
    final minutes = int.tryParse(detail['runtime']?.toString() ?? '');
    if (minutes != null && minutes > 0) return '$minutes 分钟';
    final episodes = detail['number_of_episodes']?.toString();
    final seasons = detail['number_of_seasons']?.toString();
    if (episodes != null && episodes.isNotEmpty) {
      return '${seasons ?? '?'} 季 · $episodes 集';
    }
    return '未知';
  }

  void _dismiss() {
    if (widget.onDismiss != null) {
      widget.onDismiss!();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _select(Map<String, dynamic> candidate) {
    final value = _selectionFor(candidate);
    if (widget.onSelected != null) {
      widget.onSelected!(value);
    } else {
      Navigator.of(context).pop(value);
    }
  }

  Widget _mediaKindPills(ShadColorScheme cs) {
    const values = [
      ('auto', '自动', Icons.auto_awesome_rounded),
      ('movie', '电影', Icons.movie_outlined),
      ('tv', '电视剧', Icons.live_tv_outlined),
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final option in values)
          ShadButton.outline(
            size: ShadButtonSize.sm,
            backgroundColor: _mediaKind == option.$1 ? cs.primary : null,
            foregroundColor: _mediaKind == option.$1
                ? cs.primaryForeground
                : cs.mutedForeground,
            onPressed: () => setState(() => _mediaKind = option.$1),
            leading: Icon(option.$3, size: 14),
            trailing: _mediaKind == option.$1
                ? const Icon(Icons.check_rounded, size: 14)
                : null,
            child: Text(option.$2),
          ),
      ],
    );
  }

  Widget _matchFilters(ShadColorScheme cs) {
    final yearInput = SizedBox(
      width: 108,
      child: ShadInput(
        controller: _yearController,
        keyboardType: TextInputType.number,
        placeholder: const Text('年份'),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 400) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _mediaKindPills(cs),
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: yearInput),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: _mediaKindPills(cs)),
            const SizedBox(width: 12),
            yearInput,
          ],
        );
      },
    );
  }

  Map<String, dynamic> _selectionFor(Map<String, dynamic> candidate) {
    final selected = Map<String, dynamic>.from(candidate);
    if (_mediaKind != 'auto') selected['media_type'] = _mediaKind;
    final year = int.tryParse(_yearController.text.trim());
    if (year != null) selected['_manualYear'] = year;
    if (_mediaKind != 'movie') {
      final season = int.tryParse(_seasonController.text.trim());
      final episode = int.tryParse(_episodeController.text.trim());
      if (season != null && season > 0) selected['_manualSeason'] = season;
      if (episode != null && episode > 0) selected['_manualEpisode'] = episode;
    }
    return selected;
  }

  Widget _manualMatchField({required String label, required Widget child}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 5),
        child,
      ],
    );
  }
}
