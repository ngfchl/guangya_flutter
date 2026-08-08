part of '../media_library_page.dart';

enum _MediaMetadataSource { tmdb, douban }

enum _CloudBackupActionKind { restore, rename, delete }

class _CloudBackupAction {
  final _CloudBackupActionKind kind;
  final CloudFile backup;

  const _CloudBackupAction(this.kind, this.backup);
}

extension on _MediaMetadataSource {
  String get title => this == _MediaMetadataSource.tmdb ? 'TMDB' : '豆瓣';
}

Future<bool> _confirmCloudBackupRestore(
  BuildContext context,
  CloudFile backup,
) async {
  final confirmed = await showShadDialog<bool>(
    context: context,
    builder: (dialogContext) => ShadDialog(
      closeIcon: const SizedBox.shrink(),
      title: const Text('确认下载备份？'),
      description: Text(backup.name),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        ShadButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          leading: const Icon(LucideIcons.download, size: 16),
          child: const Text('下载'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '将从云盘下载所选备份到本地，不会清空当前媒体库数据。'
          '备份大小 ${backup.formattedSize}，时间 ${backup.modifiedAt}。'
          '下载完成后会再询问是否恢复。',
        ),
      ),
    ),
  );
  return confirmed == true;
}

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

class _MediaFolderDestination {
  final MediaLibraryDefinition library;
  final MediaLibrarySource source;
  final String? parentID;
  final String path;

  const _MediaFolderDestination({
    required this.library,
    required this.source,
    required this.parentID,
    required this.path,
  });
}

class _MediaMoveSelection {
  final List<CloudFile> sources;
  final _MediaFolderDestination destination;

  const _MediaMoveSelection({required this.sources, required this.destination});
}

class _MediaMoveDialog extends ConsumerStatefulWidget {
  final List<CloudFile> sources;
  final List<MediaLibraryDefinition> libraries;

  const _MediaMoveDialog({required this.sources, required this.libraries});

  @override
  ConsumerState<_MediaMoveDialog> createState() => _MediaMoveDialogState();
}

class _MediaMoveDialogState extends ConsumerState<_MediaMoveDialog> {
  late MediaLibraryDefinition _library = widget.libraries.first;
  MediaLibrarySource? _librarySource;
  final _folderPath = <CloudFile>[];
  var _folders = <CloudFile>[];
  var _loading = false;
  String? _error;

  _MediaFolderDestination? get _destination {
    final source = _librarySource;
    if (source == null) return null;
    return _MediaFolderDestination(
      library: _library,
      source: source,
      parentID: _folderPath.lastOrNull?.id ?? source.rootID,
      path: _folderPath.fold(
        source.path,
        (path, folder) => _joinCloudPath(path, folder.name),
      ),
    );
  }

  void _selectLibrary(MediaLibraryDefinition library) {
    setState(() {
      _library = library;
      _librarySource = null;
      _folderPath.clear();
      _folders = const [];
      _error = null;
    });
  }

  Future<void> _openSource(MediaLibrarySource source) async {
    setState(() {
      _librarySource = source;
      _folderPath.clear();
    });
    await _loadFolders(source.rootID);
  }

  Future<void> _enterFolder(CloudFile folder) async {
    setState(() => _folderPath.add(folder));
    await _loadFolders(folder.id);
  }

  Future<void> _navigateTo(int index) async {
    final source = _librarySource;
    if (source == null) return;
    setState(() {
      if (index < 0) {
        _folderPath.clear();
      } else {
        _folderPath.removeRange(index + 1, _folderPath.length);
      }
    });
    await _loadFolders(index < 0 ? source.rootID : _folderPath[index].id);
  }

  Future<void> _loadFolders(String? parentID) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ref
          .read(authProvider.notifier)
          .api
          .fsFiles(parentID: parentID, pageSize: 1000);
      if (!mounted) return;
      final files = <String, CloudFile>{};
      void visit(dynamic value) {
        if (value is Map) {
          try {
            final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
            files[file.id] = file;
          } catch (_) {
            // API response envelopes can contain unrelated maps.
          }
          for (final child in value.values) {
            visit(child);
          }
        } else if (value is Iterable && value is! String) {
          for (final child in value) {
            visit(child);
          }
        }
      }

      visit(response);
      setState(() {
        _folders = files.values.where((file) => file.isDirectory).toList()
          ..sort(
            (left, right) =>
                left.name.toLowerCase().compareTo(right.name.toLowerCase()),
          );
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final destination = _destination;
    return ShadDialog(
      closeIcon: const SizedBox.shrink(),
      title: const Text('移动到'),
      description: Text('移动 ${widget.sources.length} 个文件或文件夹'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ShadButton(
          onPressed: destination == null || _loading
              ? null
              : () => Navigator.of(context).pop(
                  _MediaMoveSelection(
                    sources: widget.sources,
                    destination: destination,
                  ),
                ),
          leading: const Icon(Icons.drive_file_move_rounded, size: 16),
          child: const Text('确认移动'),
        ),
      ],
      child: SizedBox(
        width: (size.width - 32).clamp(300.0, 560.0).toDouble(),
        height: (size.height - 250).clamp(300.0, 430.0).toDouble(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '目标媒体库',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: cs.mutedForeground,
              ),
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final library in widget.libraries)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ShadButton.outline(
                        size: ShadButtonSize.sm,
                        backgroundColor: library.id == _library.id
                            ? cs.primary
                            : null,
                        foregroundColor: library.id == _library.id
                            ? cs.primaryForeground
                            : null,
                        onPressed: () => _selectLibrary(library),
                        child: Text(library.name),
                      ),
                    ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: ShadSeparator.horizontal(),
            ),
            Expanded(child: _folderBrowser(context)),
          ],
        ),
      ),
    );
  }

  Widget _folderBrowser(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final source = _librarySource;
    if (source == null) {
      return ListView.separated(
        itemCount: _library.sources.length,
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (context, index) {
          final value = _library.sources[index];
          return _folderRow(
            context,
            title: value.path,
            subtitle: '媒体库根文件夹',
            onTap: () => unawaited(_openSource(value)),
          );
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: () => setState(() {
                _librarySource = null;
                _folderPath.clear();
                _folders = const [];
              }),
              child: const Text('资源目录'),
            ),
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: () => unawaited(_navigateTo(-1)),
              child: Text(source.path),
            ),
            for (var index = 0; index < _folderPath.length; index++)
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: () => unawaited(_navigateTo(index)),
                child: Text(_folderPath[index].name),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: _loading
              ? const Center(
                  child: AppLoadingIndicator(
                    size: AppLoadingSize.compact,
                    label: '正在读取文件夹',
                  ),
                )
              : _error != null
              ? Center(
                  child: Text(_error!, style: TextStyle(color: cs.destructive)),
                )
              : _folders.isEmpty
              ? Center(
                  child: Text(
                    '当前文件夹没有下级目录，可直接移动到这里',
                    style: TextStyle(color: cs.mutedForeground),
                  ),
                )
              : ListView.separated(
                  itemCount: _folders.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    final folder = _folders[index];
                    return _folderRow(
                      context,
                      title: folder.name,
                      subtitle: '点击进入下级目录',
                      onTap: () => unawaited(_enterFolder(folder)),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _folderRow(
    BuildContext context, {
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: ListTile(
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        leading: const Icon(Icons.folder_rounded, size: 18),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 1),
        trailing: const Icon(Icons.chevron_right_rounded, size: 18),
        onTap: onTap,
      ),
    );
  }
}

class _CloudMoveDestination {
  final String? parentID;
  final String path;
  final Set<String> ancestorIDs;

  const _CloudMoveDestination({
    required this.parentID,
    required this.path,
    required this.ancestorIDs,
  });
}

class _CloudMoveDestinationPicker extends ConsumerStatefulWidget {
  const _CloudMoveDestinationPicker();

  @override
  ConsumerState<_CloudMoveDestinationPicker> createState() =>
      _CloudMoveDestinationPickerState();
}

class _CloudMoveDestinationPickerState
    extends ConsumerState<_CloudMoveDestinationPicker> {
  final _path = <CloudFile>[];
  var _folders = <CloudFile>[];
  CloudFile? _selected;
  var _loading = false;
  String? _error;

  String get _currentPath =>
      _path.isEmpty ? '' : '/${_path.map((item) => item.name).join('/')}';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ref
          .read(authProvider.notifier)
          .api
          .fsFiles(
            parentID: _path.isEmpty ? null : _path.last.id,
            pageSize: 1000,
          );
      if (!mounted) return;
      final files = <String, CloudFile>{};
      void visit(dynamic value) {
        if (value is Map) {
          try {
            final file = CloudFile.fromJson(Map<String, dynamic>.from(value));
            files[file.id] = file;
          } catch (_) {
            // API envelopes and unrelated nested objects are expected.
          }
          for (final child in value.values) {
            visit(child);
          }
        } else if (value is Iterable && value is! String) {
          for (final child in value) {
            visit(child);
          }
        }
      }

      visit(response);
      setState(() {
        _folders = files.values.where((file) => file.isDirectory).toList()
          ..sort(
            (left, right) =>
                left.name.toLowerCase().compareTo(right.name.toLowerCase()),
          );
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _enter(CloudFile folder) {
    setState(() {
      _path.add(folder);
      _selected = null;
    });
    unawaited(_load());
  }

  void _selectDestination() {
    final selected = _selected;
    Navigator.of(context).pop(
      _CloudMoveDestination(
        parentID: selected?.id ?? (_path.isEmpty ? null : _path.last.id),
        path: selected == null
            ? _currentPath
            : _joinCloudPath(_currentPath, selected.name),
        ancestorIDs: {
          for (final folder in _path) folder.id,
          if (selected != null) selected.id,
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    return ShadDialog(
      closeIcon: const SizedBox.shrink(),
      title: const Text('移动文件到'),
      description: Text(
        '目标文件夹：${_selected?.name ?? (_path.lastOrNull?.name ?? '云盘根目录')}',
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ShadButton(
          onPressed: _loading ? null : _selectDestination,
          child: const Text('移动到这里'),
        ),
      ],
      child: SizedBox(
        width: (size.width - 32).clamp(300.0, 440.0).toDouble(),
        height: (size.height - 250).clamp(280.0, 340.0).toDouble(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: _path.isEmpty
                      ? null
                      : () {
                          setState(() {
                            _path.clear();
                            _selected = null;
                          });
                          unawaited(_load());
                        },
                  child: const Text('根目录'),
                ),
                for (var index = 0; index < _path.length; index++)
                  ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: () {
                      setState(() {
                        _path.removeRange(index + 1, _path.length);
                        _selected = null;
                      });
                      unawaited(_load());
                    },
                    child: Text(_path[index].name),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(
                      child: AppLoadingIndicator(
                        size: AppLoadingSize.compact,
                        label: '正在读取文件夹',
                      ),
                    )
                  : _error != null
                  ? Center(
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.destructive),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _folders.length,
                      itemBuilder: (context, index) {
                        final folder = _folders[index];
                        final active = _selected?.id == folder.id;
                        return ListTile(
                          dense: true,
                          selected: active,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          leading: const Icon(Icons.folder_rounded, size: 18),
                          title: Text(
                            folder.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => setState(() => _selected = folder),
                          trailing: IconButton(
                            tooltip: '进入目录',
                            onPressed: () => _enter(folder),
                            icon: const Icon(
                              Icons.chevron_right_rounded,
                              size: 18,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class MediaScanMenu extends StatefulWidget {
  final bool compact;
  final bool iconOnly;
  final bool disabled;
  final VoidCallback onScanUnrecognized;
  final VoidCallback onScanUnindexed;
  final VoidCallback onForceAll;
  final ShadPopoverController? controller;

  const MediaScanMenu({
    super.key,
    required this.compact,
    this.iconOnly = false,
    required this.disabled,
    required this.onScanUnrecognized,
    required this.onScanUnindexed,
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
    final triggerDisabled = widget.disabled;
    final trigger = widget.iconOnly
        ? ShadTooltip(
            builder: (_) => const Text('重新扫描'),
            child: ShadButton.ghost(
              width: 38,
              height: 36,
              padding: EdgeInsets.zero,
              onPressed: triggerDisabled ? null : _controller.toggle,
              child: const Icon(Icons.refresh_rounded, size: 18),
            ),
          )
        : ShadButton.ghost(
            size: ShadButtonSize.sm,
            onPressed: triggerDisabled ? null : _controller.toggle,
            leading: const Icon(Icons.refresh_rounded, size: 16),
            trailing: const Icon(Icons.keyboard_arrow_down_rounded, size: 15),
            child: Text(widget.compact ? '扫描' : '重新扫描'),
          );
    return ShadPopover(
      controller: _controller,
      popover: (_) => RemoteFocusMenu(
        child: SizedBox(
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
                  onPressed: widget.disabled ? null : widget.onScanUnrecognized,
                ),
                const SizedBox(height: 3),
                _option(
                  icon: Icons.library_add_outlined,
                  title: '扫描未入库',
                  description: '扫描数据源，仅识别新增的文件/文件夹',
                  onPressed: widget.disabled ? null : widget.onScanUnindexed,
                ),
                const SizedBox(height: 3),
                _option(
                  icon: Icons.restart_alt_rounded,
                  title: '强制全部重新识别',
                  description: '刷新当前媒体库目录并重新识别全部资源',
                  onPressed: widget.disabled ? null : widget.onForceAll,
                ),
              ],
            ),
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
    required VoidCallback? onPressed,
  }) {
    final cs = ShadTheme.of(context).colorScheme;
    return RemoteFocusableButton(
      onTap: onPressed == null
          ? null
          : () {
              _controller.hide();
              onPressed();
            },
      enabled: onPressed != null,
      child: ShadButton.ghost(
        width: double.infinity,
        height: 58,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        mainAxisAlignment: MainAxisAlignment.start,
        leading: Icon(
          icon,
          size: 18,
          color: onPressed == null ? cs.mutedForeground : cs.primary,
        ),
        onPressed: onPressed == null
            ? null
            : () {
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
      ),
    );
  }
}

class _ManagementLibraryRow extends ConsumerWidget {
  final MediaLibraryDefinition library;
  final MediaLibraryStatistics statistics;
  final bool selected;
  final bool disabled;
  final bool clearing;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onClear;

  const _ManagementLibraryRow({
    required this.library,
    required this.statistics,
    required this.selected,
    required this.disabled,
    required this.clearing,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            MediaScanMenu(
              compact: true,
              iconOnly: true,
              disabled: disabled,
              onScanUnrecognized: () => ref
                  .read(mediaLibraryProvider.notifier)
                  .scanLibrary(library.id),
              onScanUnindexed: () => ref
                  .read(mediaLibraryProvider.notifier)
                  .scanLibrary(
                    library.id,
                    mode: MediaLibraryScanMode.unindexedOnly,
                  ),
              onForceAll: () => ref
                  .read(mediaLibraryProvider.notifier)
                  .scanLibrary(library.id, mode: MediaLibraryScanMode.forceAll),
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
              builder: (_) => const Text('清空媒体库'),
              child: ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: disabled ? null : onClear,
                child: clearing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cleaning_services_rounded, size: 16),
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
      closeIcon: const SizedBox.shrink(),
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
                child: const Text('使用目录'),
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
              label: const Text('递归扫描'),
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
      final key = item.tmdbID != null
          ? '$kind:tmdb:${item.tmdbID}'
          : item.doubanID != null
          ? '$kind:douban:${item.doubanID}'
          : '$kind:$title:${item.year}';
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
    final backdropPath = mediaBackdropPath(item);
    final backdrop = backdropPath != null
        ? _tmdbImageURL(backdropPath, size: 'w780')
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

class _HomeSectionEntryTile extends StatelessWidget {
  final String label;
  final int count;
  final IconData icon;
  final bool compact;
  final String? posterPath;
  final VoidCallback onTap;

  const _HomeSectionEntryTile({
    required this.label,
    required this.count,
    required this.icon,
    required this.compact,
    this.posterPath,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final width = compact ? 132.0 : 142.0;
    final hasPoster = posterPath?.isNotEmpty == true;
    return Semantics(
      button: true,
      label: '$label，共 $count 部',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: width,
          decoration: BoxDecoration(
            color: cs.muted.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.border),
            image: hasPoster
                ? DecorationImage(
                    image: CachedNetworkImageProvider(
                      _tmdbImageURL(posterPath!, size: 'w200'),
                    ),
                    fit: BoxFit.cover,
                    colorFilter: ColorFilter.mode(
                      Colors.black.withValues(alpha: 0.55),
                      BlendMode.darken,
                    ),
                  )
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!hasPoster) ...[
                Icon(icon, size: 28, color: cs.mutedForeground),
                const SizedBox(height: 8),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: hasPoster ? Colors.white : cs.mutedForeground,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '共 $count 部',
                style: TextStyle(
                  fontSize: 12,
                  color: hasPoster
                      ? Colors.white.withValues(alpha: 0.8)
                      : cs.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeLibraryEntryTile extends StatelessWidget {
  final MediaLibraryDefinition library;
  final String? posterPath;
  final double width;
  final VoidCallback onOpen;

  const _HomeLibraryEntryTile({
    required this.library,
    required this.posterPath,
    required this.width,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final posterURL = posterPath == null
        ? null
        : _tmdbImageURL(posterPath!, size: 'w342');
    return Semantics(
      button: true,
      label: '进入${library.name}',
      child: SizedBox(
        width: width,
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
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: cs.muted,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: cs.border),
                        ),
                        child: posterURL == null
                            ? Center(
                                child: Icon(
                                  Icons.video_library_rounded,
                                  size: 34,
                                  color: cs.mutedForeground,
                                ),
                              )
                            : CachedNetworkImage(
                                imageUrl: posterURL,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => _tmdbDirectFallback(
                                  path: posterPath!,
                                  size: 'w342',
                                  fallback: Center(
                                    child: Icon(
                                      Icons.video_library_rounded,
                                      size: 34,
                                      color: cs.mutedForeground,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      Positioned(
                        right: 7,
                        bottom: 7,
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black.withValues(alpha: 0.72),
                          ),
                          child: const Icon(
                            Icons.arrow_forward_rounded,
                            size: 17,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  library.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.foreground,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '进入媒体库',
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

class _MediaPosterTile extends StatefulWidget {
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
  State<_MediaPosterTile> createState() => _MediaPosterTileState();
}

class _MediaPosterTileState extends State<_MediaPosterTile> {
  final _focused = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _focused.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final item = widget.work.primary;
    final isSeries = item.mediaKind == TMDBMediaKind.tv;
    final posterURL = item.posterPath?.isNotEmpty == true
        ? _tmdbImageURL(item.posterPath!, size: 'w342')
        : null;
    return _MediaPosterTileFocusNotifier(
      focused: _focused,
      child: ShadContextMenuRegion(
      tapEnabled: false,
      items: [
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.info, size: 16),
          onPressed: widget.onOpen,
          child: const Text('查看详情'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.download, size: 16),
          onPressed: widget.onDownload,
          child: const Text('打开资源'),
        ),
        const Divider(height: 8),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.sparkles, size: 16),
          onPressed: widget.onRecognize,
          child: const Text('媒体识别'),
        ),
        ShadContextMenuItem.inset(
          leading: const Icon(LucideIcons.listFilter, size: 16),
          onPressed: widget.onManualMatch,
          child: const Text('手动匹配'),
        ),
      ],
      child: Semantics(
        button: true,
        label: '${item.title}，${widget.work.resources.length} 个资源版本',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onOpen,
            borderRadius: BorderRadius.circular(6),
            onFocusChange: (v) => _focused.value = v,
            focusColor: cs.primary.withValues(alpha: 0.12),
            highlightColor: cs.primary.withValues(alpha: 0.06),
            hoverColor: cs.primary.withValues(alpha: 0.04),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ValueListenableBuilder<bool>(
                        valueListenable: _focused,
                        builder: (context, focused, _) => Container(
                          decoration: BoxDecoration(
                            color: cs.muted,
                            borderRadius: BorderRadius.circular(6),
                            // 焦点态（遥控器选中）用主题色外框，否则默认 border。
                            border: Border.all(
                              color: focused ? cs.primary : cs.border,
                              width: focused ? 2.0 : 1.0,
                            ),
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
                      ),
                      if (widget.work.resources.length > 1)
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
                                  ? '${widget.work.resources.length} 集'
                                  : '${widget.work.resources.length} 版本',
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

/// Inherited notifier exposing whether the enclosing [_MediaPosterTile] is
/// focused (remote-selected). Descendants use it to render the themed border.
class _MediaPosterTileFocusNotifier extends InheritedNotifier<ValueNotifier<bool>> {
  const _MediaPosterTileFocusNotifier({
    required ValueNotifier<bool> focused,
    required super.child,
  }) : super(notifier: focused);

  static ValueNotifier<bool> of(BuildContext context) {
    final w = context
        .dependOnInheritedWidgetOfExactType<_MediaPosterTileFocusNotifier>();
    return w?.notifier ?? ValueNotifier<bool>(false);
  }
}

/// 从当前显示的 works 随机抽一张海报 URL（无海报返回 null）。
String? _randomPosterFromWorks(List<_MediaWork> works) {
  final withPoster = works
      .where((w) => w.primary.posterPath?.isNotEmpty == true)
      .toList();
  if (withPoster.isEmpty) return null;
  withPoster.shuffle();
  return _tmdbImageURL(withPoster.first.primary.posterPath!, size: 'w342');
}

/// 列表尾部的加载更多块：默认态显示「加载更多」可点击，点击后变 loading 并触发加载。
/// 背景图由外部传入（从当前显示项目中随机抽取一张海报），叠加半透明遮罩+loading/加载更多态。
class _MediaPosterLoadingTile extends StatefulWidget {
  final bool isLoading;
  final String? posterURL;
  final VoidCallback? onLoadMore;

  const _MediaPosterLoadingTile({
    this.isLoading = false,
    this.posterURL,
    this.onLoadMore,
  });

  @override
  State<_MediaPosterLoadingTile> createState() =>
      _MediaPosterLoadingTileState();
}

class _MediaPosterLoadingTileState extends State<_MediaPosterLoadingTile> {
  bool _busy = false;

  Future<void> _trigger() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      widget.onLoadMore?.call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final loading = widget.isLoading || _busy;
    final posterURL = widget.posterURL;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: loading ? null : _trigger,
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
                  child: posterURL == null || posterURL.isEmpty
                      ? Center(
                          child: loading
                              ? const AppLoadingIndicator(
                                  size: AppLoadingSize.inline,
                                )
                              : Icon(
                                  Icons.expand_more_rounded,
                                  color: cs.mutedForeground,
                                  size: 34,
                                ),
                        )
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            CachedNetworkImage(
                              imageUrl: posterURL,
                              fit: BoxFit.cover,
                              placeholder: (_, _) => Center(
                                child: Icon(
                                  Icons.expand_more_rounded,
                                  color: cs.mutedForeground,
                                  size: 34,
                                ),
                              ),
                              errorWidget: (_, _, _) => Center(
                                child: Icon(
                                  Icons.expand_more_rounded,
                                  color: cs.mutedForeground,
                                  size: 34,
                                ),
                              ),
                            ),
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(
                                  alpha: loading ? 0.56 : 0.34,
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                            Center(
                              child: loading
                                  ? const AppLoadingIndicator(
                                      size: AppLoadingSize.inline,
                                    )
                                  : Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: 0.56,
                                        ),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.expand_more_rounded,
                                            color: Colors.white,
                                            size: 16,
                                          ),
                                          SizedBox(width: 4),
                                          Text(
                                            '加载更多',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            loading ? '正在加载' : '加载更多',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: cs.foreground,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            loading ? '请稍候…' : '点击追加下一批',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: cs.mutedForeground),
          ),
        ],
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
  late final TextEditingController _idController;
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
    _idController = TextEditingController();
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
    _idController.dispose();
    super.dispose();
  }

  Future<void> _loadDirectTMDB() async {
    final id = int.tryParse(_idController.text.trim());
    if (id == null || id <= 0) {
      setState(() => _error = '请输入有效的 TMDB ID');
      return;
    }
    if (_mediaKind != 'movie' && _mediaKind != 'tv') {
      setState(() => _error = '使用 TMDB ID 时请先选择电影或电视剧');
      return;
    }
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (apiKey.isEmpty) {
      setState(() => _error = '请先在设置中配置 TMDB API Key');
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
            mediaKind: _mediaKind,
            apiKey: apiKey,
            proxyHost:
                StorageManager.get<String>(StorageKeys.tmdbProxyHost) ?? '',
            proxyPort:
                StorageManager.get<String>(StorageKeys.tmdbProxyPort) ?? '',
          );
      if (!mounted || requestSerial != _detailRequestSerial) return;
      setState(() {
        _detailCandidate = {
          ...details,
          'id': id,
          'media_type': _mediaKind,
          '_source': 'tmdb',
        };
      });
    } catch (error) {
      if (mounted && requestSerial == _detailRequestSerial) {
        setState(() => _error = '获取 TMDB ID $id 失败：$error');
      }
    } finally {
      if (mounted && requestSerial == _detailRequestSerial) {
        setState(() => _loadingDetail = false);
      }
    }
  }

  Future<void> _loadDirectDouban() async {
    final id = _idController.text.trim();
    if (!RegExp(r'^\d+$').hasMatch(id)) {
      setState(() => _error = '请输入有效的豆瓣 ID');
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
          .doubanDetails(id);
      if (!mounted || requestSerial != _detailRequestSerial) return;
      final episodeText =
          (details['episodes_count'] ?? details['episodes_info'] ?? '')
              .toString();
      final episodes =
          int.tryParse(episodeText) ??
          int.tryParse(RegExp(r'\d+').firstMatch(episodeText)?.group(0) ?? '');
      final doubanType = (details['subtype'] ?? details['type'] ?? '')
          .toString()
          .toLowerCase();
      final inferredKind = _mediaKind == 'movie' || _mediaKind == 'tv'
          ? _mediaKind
          : ((episodes != null && episodes > 1) ||
                doubanType == 'tv' ||
                doubanType.contains('电视剧'))
          ? 'tv'
          : 'movie';
      final year = details['year']?.toString() ?? '';
      final rating = details['rating'];
      setState(() {
        _detailCandidate = {
          ...details,
          'id': id,
          'media_type': inferredKind,
          '_source': 'douban',
          if (year.length >= 4) 'release_date': '${year.substring(0, 4)}-01-01',
          'poster_path': doubanPosterPath(details),
          'overview':
              details['intro']?.toString() ??
              details['card_subtitle']?.toString() ??
              '',
          if (rating is Map) 'vote_average': rating['value'],
          if (rating is Map) 'vote_count': rating['count'],
        };
      });
    } catch (error) {
      if (mounted && requestSerial == _detailRequestSerial) {
        setState(() => _error = '获取豆瓣 ID $id 失败：$error');
      }
    } finally {
      if (mounted && requestSerial == _detailRequestSerial) {
        setState(() => _loadingDetail = false);
      }
    }
  }

  Future<void> _search() async {
    if (!mounted) return;
    final requestSerial = ++_searchRequestSerial;
    final query = _queryController.text.trim();
    final year = int.tryParse(_yearController.text.trim());
    final mediaKind = _mediaKind;
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
      });
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    var tmdbResults = const <Map<String, dynamic>>[];
    var doubanResults = const <Map<String, dynamic>>[];
    if (apiKey.isNotEmpty) {
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
        tmdbResults =
            (result['results'] as List?)
                ?.whereType<Map>()
                .map(Map<String, dynamic>.from)
                .map((item) {
                  final type =
                      item['media_type']?.toString() ??
                      (mediaKind == 'movie' || mediaKind == 'tv'
                          ? mediaKind
                          : null);
                  if (type == null) return item;
                  return {...item, 'media_type': type, '_source': 'tmdb'};
                })
                .where(
                  (item) =>
                      item['id'] != null &&
                      (item['media_type'] == 'movie' ||
                          item['media_type'] == 'tv'),
                )
                .toList() ??
            const <Map<String, dynamic>>[];
      } catch (error) {
        if (mounted && requestSerial == _searchRequestSerial) {
          _error = 'TMDB: $error';
        }
      }
    }
    try {
      doubanResults = await _doubanSearchFallback(query, mediaKind);
    } catch (_) {}
    final merged = <Map<String, dynamic>>[];
    final seenIDs = <String>{};
    for (final item in tmdbResults) {
      final id = item['id']?.toString() ?? '';
      if (id.isNotEmpty) seenIDs.add('tmdb:$id');
      merged.add(item);
    }
    for (final item in doubanResults) {
      final id = item['id']?.toString() ?? '';
      if (id.isNotEmpty && seenIDs.contains('douban:$id')) continue;
      merged.add(item);
    }
    if (mounted && requestSerial == _searchRequestSerial) {
      setState(() {
        _results = merged;
        _searching = false;
      });
    }
  }

  Future<List<Map<String, dynamic>>> _doubanSearchFallback(
    String query,
    String mediaKind,
  ) async {
    try {
      final api = ref.read(authProvider.notifier).api;
      final result = await api.doubanSearch(query);
      final items = result['items'];
      if (items is! List || items.isEmpty) return const [];
      return items
          .whereType<Map>()
          .map((raw) {
            final target = raw['target'];
            if (target is! Map) return null;
            final candidate = Map<String, dynamic>.from(target);
            final cardSubtitle = (candidate['card_subtitle'] ?? '').toString();
            final type = cardSubtitle.contains('集') ? 'tv' : 'movie';
            if (mediaKind != 'auto' && type != mediaKind) return null;
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
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final detail = _detailCandidate;
    final content = ShadDialog(
      closeIcon: const SizedBox.shrink(),
      // This dialog is embedded in an OverlayEntry rather than pushed as a
      // route.  ShadDialog's default X calls Navigator.pop, which would pop
      // the workspace route and leave the page blank.  Closing is handled by
      // the explicit 取消/返回 actions and the popover's outside-tap logic.
      title: Text(detail == null ? '手动匹配' : '匹配详情'),
      description: Text(
        detail == null ? '查看或选中匹配结果后，会应用到该作品的全部资源版本。' : '确认信息无误后使用此匹配项。',
      ),
      actions: detail == null
          ? [
              ShadButton.outline(onPressed: _dismiss, child: const Text('取消')),
              ShadButton(
                onPressed: _searching || _loadingDetail ? null : _search,
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
                  _directIDMatchFields(cs),
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
                    child: _searching || _loadingDetail
                        ? const Center(
                            child: AppLoadingIndicator(
                              size: AppLoadingSize.page,
                              label: '正在加载匹配信息',
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
                      runSpacing: 4,
                      children: [
                        ShadBadge.outline(child: Text(mediaType)),
                        ShadBadge.outline(
                          child: Text(
                            release.length >= 4
                                ? release.substring(0, 4)
                                : '未知年份',
                          ),
                        ),
                        if (candidate['origin_country'] is List
                            ? (candidate['origin_country'] as List).isNotEmpty
                            : (candidate['original_language']
                                      ?.toString()
                                      .isNotEmpty ==
                                  true)) ...[
                          ShadBadge.outline(
                            child: Text(
                              candidate['origin_country'] is List
                                  ? (candidate['origin_country'] as List).join(
                                      '/',
                                    )
                                  : (candidate['original_language']
                                            ?.toString() ??
                                        ''),
                            ),
                          ),
                        ],
                        if (candidate['media_type'] == 'tv') ...[
                          if (candidate['number_of_seasons'] != null)
                            ShadBadge.outline(
                              child: Text(
                                '${candidate['number_of_seasons']} 季',
                              ),
                            ),
                          if (candidate['number_of_episodes'] != null)
                            ShadBadge.outline(
                              child: Text(
                                '${candidate['number_of_episodes']} 集',
                              ),
                            ),
                        ],
                        if (candidate['_source'] == 'douban')
                          ShadBadge(
                            backgroundColor: const Color(
                              0xFF22A559,
                            ).withValues(alpha: 0.12),
                            child: const Text(
                              '豆瓣',
                              style: TextStyle(
                                color: Color(0xFF22A559),
                                fontSize: 11,
                              ),
                            ),
                          )
                        else if (tmdbID.isNotEmpty)
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
                width: 80,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ShadButton(
                      size: ShadButtonSize.sm,
                      onPressed: _loadingDetail
                          ? null
                          : () => unawaited(_viewDetails(candidate)),
                      leading: const Icon(Icons.info_outline_rounded, size: 14),
                      child: const Text('详情'),
                    ),
                    const SizedBox(height: 4),
                    ShadButton(
                      size: ShadButtonSize.sm,
                      onPressed: () => _select(candidate),
                      leading: const Icon(
                        Icons.check_circle_outline_rounded,
                        size: 14,
                      ),
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
    final source = candidate['_source']?.toString();
    if (source == 'douban') {
      setState(() => _detailCandidate = candidate);
      return;
    }
    final id = int.tryParse(candidate['id']?.toString() ?? '');
    final type = candidate['media_type']?.toString();
    final mediaKind = type == 'tv'
        ? 'tv'
        : type == 'movie'
        ? 'movie'
        : null;
    final apiKey = StorageManager.get<String>(StorageKeys.tmdbApiKey) ?? '';
    if (id == null || mediaKind == null || apiKey.isEmpty) {
      setState(() => _detailCandidate = candidate);
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
    final sourceName = detail['_source'] == 'douban' ? '豆瓣' : 'TMDB';
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
      sourceName: detail['id']?.toString() ?? '-',
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
        onSubmitted: (_) => _search(),
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

  Widget _directIDMatchFields(ShadColorScheme cs) {
    return _manualMatchField(
      label: 'ID 直达',
      child: Row(
        children: [
          Expanded(
            child: ShadInput(
              controller: _idController,
              placeholder: const Text('输入 TMDB / 豆瓣 ID'),
              onSubmitted: (_) => unawaited(_loadDirectTMDB()),
            ),
          ),
          const SizedBox(width: 6),
          ShadButton.outline(
            size: ShadButtonSize.sm,
            onPressed: _loadingDetail
                ? null
                : () => unawaited(_loadDirectTMDB()),
            child: const Text('TMDB'),
          ),
          const SizedBox(width: 4),
          ShadButton.outline(
            size: ShadButtonSize.sm,
            onPressed: _loadingDetail
                ? null
                : () => unawaited(_loadDirectDouban()),
            child: const Text('豆瓣'),
          ),
        ],
      ),
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
