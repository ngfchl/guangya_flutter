part of '../media_library_page.dart';

class _BackupActionsMenu extends StatefulWidget {
  final bool compact;
  final bool disabled;
  final CloudBackupSyncProgress? progress;
  final VoidCallback onExport;
  final VoidCallback onImport;
  final VoidCallback onExportWorks;
  final VoidCallback onImportWorks;
  final VoidCallback onSyncToCloud;
  final VoidCallback onRestoreFromCloud;
  final VoidCallback? onRefreshScrape;

  const _BackupActionsMenu({
    required this.compact,
    required this.disabled,
    required this.progress,
    required this.onExport,
    required this.onImport,
    required this.onExportWorks,
    required this.onImportWorks,
    required this.onSyncToCloud,
    required this.onRestoreFromCloud,
    this.onRefreshScrape,
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
    final label = active
        ? progress!.phase
        : progress?.error != null
        ? '❌ ${progress!.error!.length > 20 ? '${progress.error!.substring(0, 20)}…' : progress.error}'
        : progress?.phase == '同步完成'
        ? '✅ 备份完成'
        : progress?.phase == '恢复完成'
        ? '✅ 恢复完成'
        : progress?.phase == '导出完成'
        ? '✅ 导出完成'
        : progress?.phase == '导入完成'
        ? '✅ 导入完成'
        : progress?.phase == '导出失败'
        ? '❌ 导出失败'
        : progress?.phase == '导入失败'
        ? '❌ 导入失败'
        : '备份恢复';
    return ShadPopover(
      controller: _controller,
      popover: (_) => RemoteFocusMenu(
        child: SizedBox(
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
                        '失败原因',
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
                            progress?.error ?? '',
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.35,
                              color: ShadTheme.of(
                                context,
                              ).colorScheme.foreground,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
              ],
              if (active && progress!.totalBytes > 0) ...[
                _progressDetail(
                  context,
                  label: '进度',
                  value:
                      '${((progress.fraction) * 100).round()}%'
                      '${progress.bytesPerSecond > 0 ? ' · ${_formatRate(progress.bytesPerSecond)}' : ''}',
                ),
                const SizedBox(height: 6),
              ],
              _item(
                icon: Icons.ios_share_rounded,
                label: '导出刮削数据',
                onPressed: widget.onExportWorks,
              ),
              _item(
                icon: Icons.download_rounded,
                label: '导入刮削数据',
                onPressed: widget.onImportWorks,
              ),
              if (widget.onRefreshScrape != null)
                _item(
                  icon: Icons.sync_rounded,
                  label: '刷新刮削数据',
                  onPressed: widget.onRefreshScrape!,
                ),
              _item(
                icon: Icons.save_alt_rounded,
                label: '导出数据库',
                onPressed: widget.onExport,
              ),
              _item(
                icon: Icons.upload_file_rounded,
                label: '导入数据库',
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
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(label),
        ),
      ),
    );
  }

  String _formatRate(double bytesPerSecond) =>
      '${FormatBytes.format(bytesPerSecond.round())}/s';

  Widget _item({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: RemoteFocusableButton(
      onTap: () {
        _controller.hide();
        onPressed();
      },
      child: ShadButton.ghost(
        width: double.infinity,
        mainAxisAlignment: MainAxisAlignment.start,
        leading: Icon(icon, size: 16),
        onPressed: () {
          _controller.hide();
          onPressed();
        },
        child: Text(label),
      ),
    ),
  );

  Widget _progressDetail(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: cs.mutedForeground),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: cs.foreground,
            ),
          ),
        ],
      ),
    );
  }
}
